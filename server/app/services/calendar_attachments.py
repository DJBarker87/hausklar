"""Compatibility-safe many-document links for calendar events."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from app.models.calendar import CalendarEventAttachmentInput
from app.services.record_history import save_history

ATTACHMENT_ROLES = {"ticket", "booking", "school_letter", "insurance", "other"}


def _role_value(value) -> str:
    role = getattr(value, "value", value) or "other"
    if role not in ATTACHMENT_ROLES:
        raise ValueError("Calendar attachment type is invalid")
    return role


def normalise_attachment_specs(
    attachments: list[CalendarEventAttachmentInput] | None,
    *,
    source_document_id: str | None = None,
) -> list[tuple[str, str]]:
    """Normalise ordered attachment input while retaining the legacy primary link."""
    specs: list[tuple[str, str]] = []
    seen: set[str] = set()
    for attachment in attachments or []:
        document_id = str(attachment.document_id)
        if document_id in seen:
            raise ValueError("The same document cannot be attached twice")
        seen.add(document_id)
        specs.append((document_id, _role_value(attachment.role)))
    if source_document_id and source_document_id not in seen:
        specs.insert(0, (source_document_id, "other"))
    return specs


def creation_attachment_specs(body) -> list[tuple[str, str]]:
    if body.attachments is None:
        return (
            [(body.source_document_id, "other")]
            if body.source_document_id is not None
            else []
        )
    return normalise_attachment_specs(
        body.attachments,
        source_document_id=body.source_document_id,
    )


async def stored_attachment_specs(
    db,
    *,
    event_id: str,
    family_id: str,
    legacy_source_document_id: str | None = None,
) -> list[tuple[str, str]]:
    rows = await (
        await db.execute(
            """
            SELECT document_id, role
            FROM calendar_event_documents
            WHERE event_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY position, created_at, id
            """,
            (event_id, family_id),
        )
    ).fetchall()
    specs = [(row["document_id"], row["role"]) for row in rows]
    if not specs and legacy_source_document_id:
        specs = [(legacy_source_document_id, "other")]
    return specs


async def attachment_specs_for_update(
    db,
    *,
    event: dict,
    body,
    family_id: str,
) -> list[tuple[str, str]] | None:
    """Translate new and legacy partial updates without losing hidden attachments."""
    fields = body.model_fields_set
    if "attachments" in fields:
        return normalise_attachment_specs(
            body.attachments,
            source_document_id=(
                body.source_document_id if "source_document_id" in fields else None
            ),
        )
    if "source_document_id" not in fields:
        return None

    current = await stored_attachment_specs(
        db,
        event_id=event["id"],
        family_id=family_id,
        legacy_source_document_id=event.get("source_document_id"),
    )
    old_primary = event.get("source_document_id")
    new_primary = body.source_document_id
    remaining = [(doc_id, role) for doc_id, role in current if doc_id != old_primary]
    if new_primary is None:
        return remaining
    return [(new_primary, next((r for d, r in current if d == new_primary), "other"))] + [
        (doc_id, role) for doc_id, role in remaining if doc_id != new_primary
    ]


async def validate_attachment_specs(
    db,
    *,
    specs: list[tuple[str, str]],
    family_id: str,
) -> None:
    if len(specs) > 20:
        raise ValueError("A calendar event can have at most 20 attachments")
    document_ids = [document_id for document_id, _role in specs]
    if len(set(document_ids)) != len(document_ids):
        raise ValueError("The same document cannot be attached twice")
    if not document_ids:
        return
    placeholders = ",".join("?" for _ in document_ids)
    rows = await (
        await db.execute(
            f"""
            SELECT id FROM documents
            WHERE family_id = ? AND deleted_at IS NULL
              AND id IN ({placeholders})
            """,
            (family_id, *document_ids),
        )
    ).fetchall()
    if {row["id"] for row in rows} != set(document_ids):
        raise ValueError("Attached document is not available to this family")


async def replace_event_attachments(
    db,
    *,
    event_id: str,
    family_id: str,
    user_id: str,
    specs: list[tuple[str, str]],
    client_id: str | None = None,
    client_timestamp: str | None = None,
    validate: bool = True,
) -> None:
    """Replace the active ordered relation set with history-backed soft deletes."""
    if validate:
        await validate_attachment_specs(db, specs=specs, family_id=family_id)
    now = datetime.now(timezone.utc).isoformat()
    active_rows = await (
        await db.execute(
            """
            SELECT * FROM calendar_event_documents
            WHERE event_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY position, created_at, id
            """,
            (event_id, family_id),
        )
    ).fetchall()
    active_by_document = {row["document_id"]: dict(row) for row in active_rows}
    desired_ids = {document_id for document_id, _role in specs}

    for row in active_by_document.values():
        if row["document_id"] in desired_ids:
            continue
        await save_history(
            db,
            "calendar_event_documents",
            row["id"],
            user_id,
            family_id=family_id,
        )
        await db.execute(
            "UPDATE calendar_event_documents SET deleted_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (now, now, row["id"], family_id),
        )

    for position, (document_id, role) in enumerate(specs):
        existing = active_by_document.get(document_id)
        if existing is None:
            await db.execute(
                """
                INSERT INTO calendar_event_documents
                    (id, event_id, document_id, role, position, family_id,
                     created_at, updated_at, created_by, client_id, client_timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    event_id,
                    document_id,
                    role,
                    position,
                    family_id,
                    now,
                    now,
                    user_id,
                    client_id,
                    client_timestamp,
                ),
            )
            continue
        if existing["role"] == role and existing["position"] == position:
            continue
        await save_history(
            db,
            "calendar_event_documents",
            existing["id"],
            user_id,
            family_id=family_id,
        )
        await db.execute(
            """
            UPDATE calendar_event_documents
            SET role = ?, position = ?, updated_at = ?, client_id = ?, client_timestamp = ?
            WHERE id = ? AND family_id = ?
            """,
            (
                role,
                position,
                now,
                client_id,
                client_timestamp,
                existing["id"],
                family_id,
            ),
        )


async def copy_event_attachments(
    db,
    *,
    source_event_id: str,
    target_event_id: str,
    family_id: str,
    user_id: str,
    legacy_source_document_id: str | None = None,
) -> None:
    specs = await stored_attachment_specs(
        db,
        event_id=source_event_id,
        family_id=family_id,
        legacy_source_document_id=legacy_source_document_id,
    )
    await replace_event_attachments(
        db,
        event_id=target_event_id,
        family_id=family_id,
        user_id=user_id,
        specs=specs,
        validate=False,
    )


async def soft_delete_event_attachments(
    db,
    *,
    event_id: str,
    family_id: str,
    user_id: str,
    now: str | None = None,
) -> None:
    deleted_at = now or datetime.now(timezone.utc).isoformat()
    rows = await (
        await db.execute(
            "SELECT id FROM calendar_event_documents "
            "WHERE event_id = ? AND family_id = ? AND deleted_at IS NULL",
            (event_id, family_id),
        )
    ).fetchall()
    for row in rows:
        await save_history(
            db,
            "calendar_event_documents",
            row["id"],
            user_id,
            family_id=family_id,
        )
    if rows:
        await db.execute(
            "UPDATE calendar_event_documents SET deleted_at = ?, updated_at = ? "
            "WHERE event_id = ? AND family_id = ? AND deleted_at IS NULL",
            (deleted_at, deleted_at, event_id, family_id),
        )
async def attachments_for_event_rows(
    db,
    *,
    rows: list[dict],
    family_id: str,
) -> dict[str, list[dict]]:
    """Batch materialise attachment responses, with a legacy fallback."""
    event_ids = list(dict.fromkeys(row["id"] for row in rows if row.get("id")))
    result: dict[str, list[dict]] = {event_id: [] for event_id in event_ids}
    if not event_ids:
        return result
    placeholders = ",".join("?" for _ in event_ids)
    relation_rows = await (
        await db.execute(
            f"""
            SELECT ced.id AS relation_id, ced.event_id, ced.role, ced.position,
                   d.id, d.title, d.original_filename, d.media_type, d.file_size
            FROM calendar_event_documents ced
            JOIN documents d ON d.id = ced.document_id
                AND d.family_id = ced.family_id AND d.deleted_at IS NULL
            WHERE ced.family_id = ? AND ced.deleted_at IS NULL
              AND ced.event_id IN ({placeholders})
            ORDER BY ced.event_id, ced.position, ced.created_at, ced.id
            """,
            (family_id, *event_ids),
        )
    ).fetchall()
    for row in relation_rows:
        result[row["event_id"]].append(
            {
                "relation_id": row["relation_id"],
                "role": row["role"],
                "position": row["position"],
                "id": row["id"],
                "title": row["title"],
                "original_filename": row["original_filename"],
                "media_type": row["media_type"],
                "file_size": row["file_size"],
                "download_url": f"/api/documents/{row['id']}/content",
            }
        )

    missing_legacy = [
        row
        for row in rows
        if row.get("source_document_id") and not result.get(row["id"])
    ]
    legacy_document_ids = list(
        dict.fromkeys(str(row["source_document_id"]) for row in missing_legacy)
    )
    documents: dict[str, dict] = {}
    if legacy_document_ids:
        legacy_placeholders = ",".join("?" for _ in legacy_document_ids)
        document_rows = await (
            await db.execute(
                "SELECT id, title, original_filename, media_type, file_size "
                "FROM documents WHERE family_id = ? AND deleted_at IS NULL "
                f"AND id IN ({legacy_placeholders})",
                (family_id, *legacy_document_ids),
            )
        ).fetchall()
        documents = {str(row["id"]): dict(row) for row in document_rows}
    for event in missing_legacy:
        document_id = str(event["source_document_id"])
        document = documents.get(document_id)
        if document is None:
            continue
        result[event["id"]] = [
            {
                "relation_id": f"legacy:{event['id']}:{document_id}",
                "role": "other",
                "position": 0,
                "id": document["id"],
                "title": document["title"],
                "original_filename": document["original_filename"],
                "media_type": document["media_type"],
                "file_size": document["file_size"],
                "download_url": f"/api/documents/{document_id}/content",
            }
        ]
    return result
