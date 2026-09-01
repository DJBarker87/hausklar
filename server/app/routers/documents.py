import json
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile, status
from fastapi.responses import FileResponse
from pydantic import ValidationError

from app.auth import get_current_user
from app.config import settings
from app.database import database_lease, documents_fts_available, get_db
from app.models.document import (
    CaptureSuggestionCreate,
    CaptureSuggestionResponse,
    CaptureSuggestionUpdate,
    DocumentBatchFileRequest,
    DocumentBatchFileResponse,
    DocumentPersonResponse,
    DocumentInboxAddressResponse,
    DocumentResponse,
    DocumentStatsResponse,
    DocumentUpdate,
    LinkedEventResponse,
    LinkedTaskResponse,
    SuggestionResolutionResponse,
)
from app.services.documents import (
    DocumentStorageError,
    family_document_storage_bytes,
    promote_staged_upload,
    remove_new_upload,
    remove_staged_upload,
    remove_stored_document,
    resolve_storage_key,
    stage_upload,
)
from app.services.hermes import extract_capture_suggestions
from app.services.ai_consent import require_ai_consent
from app.middleware.rate_limit import reserve_persistent_attempts
from app.services.record_history import save_history

router = APIRouter()

DOCUMENT_SOURCES = {"scan", "photo", "file", "text", "share"}
DOCUMENT_CATEGORIES = {
    "school",
    "medical",
    "childcare",
    "identity",
    "finance",
    "activities",
    "household",
    "other",
}
DOCUMENT_STATUSES = {"inbox", "filed", "archived", "failed"}

# A document's bytes are removed when it is deleted, so every family record
# that points at those bytes must be detached in the same transaction. Keep
# this an explicit allowlist: table names must never come from request data.
DOCUMENT_REFERENCE_TABLES = (
    "calendar_events",
    "tasks",
    "renewals",
    "family_insights",
    "facility_schedule_versions",
)


def _parse_json_list(value: str, label: str) -> list:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=422, detail=f"{label} must be valid JSON") from exc
    if not isinstance(parsed, list):
        raise HTTPException(status_code=422, detail=f"{label} must be a JSON array")
    return parsed


async def _family_people(db, family_id: str, person_ids: list[str]) -> list[dict[str, str]]:
    unique_ids = list(dict.fromkeys(person_ids))
    if not unique_ids:
        return []
    if len(unique_ids) > 20:
        raise HTTPException(status_code=422, detail="A document can be filed for at most 20 people")

    placeholders = ", ".join("?" for _ in unique_ids)
    cursor = await db.execute(
        f"""
        SELECT id, name, 'user' AS person_type
        FROM users
        WHERE id IN ({placeholders}) AND family_id = ? AND deleted_at IS NULL
        UNION ALL
        SELECT id, name, 'child' AS person_type
        FROM children
        WHERE id IN ({placeholders}) AND family_id = ? AND deleted_at IS NULL
        """,
        [*unique_ids, family_id, *unique_ids, family_id],
    )
    by_id = {
        row[0]: {"id": row[0], "name": row[1], "person_type": row[2]}
        for row in await cursor.fetchall()
    }
    if len(by_id) != len(unique_ids):
        raise HTTPException(status_code=422, detail="One or more selected people are invalid")
    return [by_id[person_id] for person_id in unique_ids]


async def _people_for_documents(
    db, document_ids: list[str]
) -> dict[str, list[DocumentPersonResponse]]:
    result = {document_id: [] for document_id in document_ids}
    if not document_ids:
        return result
    placeholders = ", ".join("?" for _ in document_ids)
    cursor = await db.execute(
        f"""
        SELECT dp.document_id, dp.id, dp.person_id, dp.person_type,
               CASE dp.person_type WHEN 'user' THEN u.name ELSE c.name END AS person_name
        FROM document_people dp
        LEFT JOIN users u ON dp.person_type = 'user' AND u.id = dp.person_id
        LEFT JOIN children c ON dp.person_type = 'child' AND c.id = dp.person_id
        WHERE dp.document_id IN ({placeholders}) AND dp.deleted_at IS NULL
        ORDER BY dp.created_at
        """,
        document_ids,
    )
    for row in await cursor.fetchall():
        result[row[0]].append(
            DocumentPersonResponse(
                id=row[1],
                person_id=row[2],
                person_type=row[3],
                person_name=row[4] or "Unknown",
            )
        )
    return result


async def _suggestions_for_documents(
    db,
    document_ids: list[str],
    *,
    pending_only: bool,
) -> dict[str, list[CaptureSuggestionResponse]]:
    result = {document_id: [] for document_id in document_ids}
    if not document_ids:
        return result
    placeholders = ", ".join("?" for _ in document_ids)
    query = f"""
        SELECT s.*,
               COALESCE(u.name, c.name) AS assigned_to_name,
               t.completed_at AS result_completed_at,
               CASE
                   WHEN s.status = 'pending' THEN 'pending'
                   WHEN s.status = 'dismissed' THEN 'dismissed'
                   WHEN s.kind = 'task' AND t.id IS NULL THEN 'unavailable'
                   WHEN s.kind = 'task' AND t.completed_at IS NULL THEN 'open'
                   WHEN s.kind = 'task' THEN 'completed'
                   WHEN s.kind = 'event' AND e.id IS NOT NULL THEN 'scheduled'
                   ELSE 'unavailable'
               END AS result_status
        FROM capture_suggestions s
        LEFT JOIN users u ON u.id = s.assigned_to
        LEFT JOIN children c ON c.id = s.assigned_to
        LEFT JOIN tasks t ON s.kind = 'task' AND t.id = s.result_id AND t.deleted_at IS NULL
        LEFT JOIN calendar_events e
               ON s.kind = 'event' AND e.id = s.result_id AND e.deleted_at IS NULL
        WHERE s.document_id IN ({placeholders}) AND s.deleted_at IS NULL
    """
    params: list = list(document_ids)
    if pending_only:
        query += " AND s.status = 'pending'"
    query += " ORDER BY s.created_at"
    cursor = await db.execute(query, params)
    for row in await cursor.fetchall():
        data = dict(row)
        result[data["document_id"]].append(
            CaptureSuggestionResponse(
                id=data["id"],
                document_id=data["document_id"],
                kind=data["kind"],
                title=data["title"],
                details=data["details"],
                start_time=data["start_time"],
                end_time=data["end_time"],
                due_date=data["due_date"],
                all_day=bool(data["all_day"]),
                assigned_to=data["assigned_to"],
                assigned_to_name=data["assigned_to_name"],
                confidence=data["confidence"],
                source_text=data["source_text"],
                status=data["status"],
                result_id=data["result_id"],
                result_status=data["result_status"],
                result_completed_at=data["result_completed_at"],
                created_at=data["created_at"],
                updated_at=data["updated_at"],
            )
        )
    return result


async def _records_for_documents(
    db,
    document_ids: list[str],
) -> tuple[dict[str, list[LinkedEventResponse]], dict[str, list[LinkedTaskResponse]]]:
    """Batch reverse links so document pages reflect links made from any client."""
    events = {document_id: [] for document_id in document_ids}
    tasks = {document_id: [] for document_id in document_ids}
    if not document_ids:
        return events, tasks
    placeholders = ", ".join("?" for _ in document_ids)

    event_rows = await (
        await db.execute(
            f"""
            SELECT DISTINCT ced.document_id AS source_document_id,
                   e.id, e.title, e.start_time, e.end_time, e.all_day
            FROM calendar_event_documents ced
            JOIN calendar_events e ON e.id = ced.event_id
                AND e.family_id = ced.family_id AND e.deleted_at IS NULL
            JOIN documents d ON d.id = ced.document_id
                AND d.family_id = ced.family_id AND d.deleted_at IS NULL
            WHERE ced.document_id IN ({placeholders})
              AND ced.deleted_at IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM calendar_events replacement
                  WHERE replacement.overridden_event_id = e.id
                    AND replacement.family_id = e.family_id
                    AND replacement.deleted_at IS NULL
              )
            UNION
            SELECT e.source_document_id, e.id, e.title, e.start_time,
                   e.end_time, e.all_day
            FROM calendar_events e
            JOIN documents d ON d.id = e.source_document_id
                AND d.family_id = e.family_id AND d.deleted_at IS NULL
            WHERE e.source_document_id IN ({placeholders})
              AND e.deleted_at IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM calendar_events replacement
                  WHERE replacement.overridden_event_id = e.id
                    AND replacement.family_id = e.family_id
                    AND replacement.deleted_at IS NULL
              )
              AND NOT EXISTS (
                  SELECT 1 FROM calendar_event_documents ced
                  WHERE ced.event_id = e.id AND ced.family_id = e.family_id
                    AND ced.document_id = e.source_document_id
                    AND ced.deleted_at IS NULL
              )
            ORDER BY start_time
            """,
            [*document_ids, *document_ids],
        )
    ).fetchall()
    for row in event_rows:
        events[row["source_document_id"]].append(
            LinkedEventResponse(
                id=row["id"],
                title=row["title"],
                start_time=row["start_time"],
                end_time=row["end_time"],
                all_day=bool(row["all_day"]),
            )
        )

    task_rows = await (
        await db.execute(
            f"""
            SELECT t.source_document_id, t.id, t.title, t.due_date, t.completed_at
            FROM tasks t
            JOIN documents d ON d.id = t.source_document_id
                AND d.family_id = t.family_id AND d.deleted_at IS NULL
            WHERE t.source_document_id IN ({placeholders})
              AND t.deleted_at IS NULL
            ORDER BY t.completed_at IS NOT NULL, t.due_date, t.created_at DESC
            """,
            document_ids,
        )
    ).fetchall()
    for row in task_rows:
        tasks[row["source_document_id"]].append(
            LinkedTaskResponse(
                id=row["id"],
                title=row["title"],
                due_date=row["due_date"],
                completed_at=row["completed_at"],
            )
        )
    return events, tasks


async def _detach_document_references(
    db,
    *,
    document_id: str,
    family_id: str,
    changed_by: str,
    now: str,
) -> None:
    """Detach every record before the document's original bytes disappear."""
    relation_rows = await (
        await db.execute(
            """
            SELECT * FROM calendar_event_documents
            WHERE document_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (document_id, family_id),
        )
    ).fetchall()
    affected_event_ids = {row["event_id"] for row in relation_rows}
    legacy_event_rows = await (
        await db.execute(
            "SELECT id FROM calendar_events WHERE source_document_id = ? AND family_id = ?",
            (document_id, family_id),
        )
    ).fetchall()
    affected_event_ids.update(row["id"] for row in legacy_event_rows)
    for row in relation_rows:
        await save_history(
            db,
            "calendar_event_documents",
            row["id"],
            changed_by,
            family_id=family_id,
        )
    if relation_rows:
        await db.execute(
            "UPDATE calendar_event_documents SET deleted_at = ?, updated_at = ? "
            "WHERE document_id = ? AND family_id = ? AND deleted_at IS NULL",
            (now, now, document_id, family_id),
        )
    for event_id in affected_event_ids:
        await save_history(
            db,
            "calendar_events",
            event_id,
            changed_by,
            family_id=family_id,
        )
        next_attachment = await (
            await db.execute(
                """
                SELECT document_id FROM calendar_event_documents
                WHERE event_id = ? AND family_id = ? AND deleted_at IS NULL
                ORDER BY position, created_at, id LIMIT 1
                """,
                (event_id, family_id),
            )
        ).fetchone()
        await db.execute(
            "UPDATE calendar_events SET source_document_id = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (
                next_attachment["document_id"] if next_attachment else None,
                now,
                event_id,
                family_id,
            ),
        )

    for table_name in DOCUMENT_REFERENCE_TABLES:
        if table_name == "calendar_events":
            continue
        rows = await (
            await db.execute(
                f"SELECT id FROM {table_name} WHERE source_document_id = ? AND family_id = ?",
                (document_id, family_id),
            )
        ).fetchall()
        for row in rows:
            await save_history(
                db,
                table_name,
                row["id"],
                changed_by,
                family_id=family_id,
            )
        if rows:
            await db.execute(
                f"UPDATE {table_name} SET source_document_id = NULL, updated_at = ? "
                "WHERE source_document_id = ? AND family_id = ?",
                (now, document_id, family_id),
            )

    # A commitment remains useful after its source file is deliberately removed,
    # but it must not retain a dangling attachment or fail to serialize. Preserve
    # a provenance tombstone and detach embedded event/task document links.
    commitment_source_rows = await (
        await db.execute(
            "SELECT id, commitment_id FROM family_commitment_sources "
            "WHERE document_id = ? AND family_id = ? AND deleted_at IS NULL",
            (document_id, family_id),
        )
    ).fetchall()
    for row in commitment_source_rows:
        await save_history(
            db,
            "family_commitment_sources",
            row["id"],
            changed_by,
            family_id=family_id,
        )
    if commitment_source_rows:
        await db.execute(
            """UPDATE family_commitment_sources
               SET kind = 'manual', document_id = NULL, source_url = NULL,
                   provider_reference = NULL,
                   label = COALESCE(NULLIF(label, ''), 'Deleted source document'),
                   updated_at = ?, client_id = NULL, client_timestamp = NULL
               WHERE document_id = ? AND family_id = ? AND deleted_at IS NULL""",
            (now, document_id, family_id),
        )

    source_commitment_ids = {row["commitment_id"] for row in commitment_source_rows}
    commitment_rows = await (
        await db.execute(
            "SELECT id, plan_json FROM family_commitments "
            "WHERE family_id = ? AND deleted_at IS NULL",
            (family_id,),
        )
    ).fetchall()
    for row in commitment_rows:
        try:
            plan = json.loads(row["plan_json"])
        except (TypeError, json.JSONDecodeError):
            continue
        changed = False
        for event in plan.get("events", []):
            document_ids = event.get("document_ids")
            if isinstance(document_ids, list) and document_id in document_ids:
                event["document_ids"] = [item for item in document_ids if item != document_id]
                changed = True
        for task in plan.get("tasks", []):
            if task.get("document_id") == document_id:
                task["document_id"] = None
                changed = True
        if not changed and row["id"] not in source_commitment_ids:
            continue
        await save_history(
            db,
            "family_commitments",
            row["id"],
            changed_by,
            family_id=family_id,
        )
        await db.execute(
            "UPDATE family_commitments SET plan_json = ?, dedupe_key = NULL, "
            "revision = revision + 1, updated_at = ?, updated_by = ? "
            "WHERE id = ? AND family_id = ?",
            (
                json.dumps(plan, ensure_ascii=False, separators=(",", ":")),
                now,
                changed_by,
                row["id"],
                family_id,
            ),
        )


async def _build_document_responses(
    db,
    rows,
    *,
    include_text: bool,
    pending_suggestions_only: bool,
    include_links: bool = True,
) -> list[DocumentResponse]:
    row_data = [dict(row) for row in rows]
    document_ids = [row["id"] for row in row_data]
    people = await _people_for_documents(db, document_ids)
    suggestions = await _suggestions_for_documents(
        db,
        document_ids,
        pending_only=pending_suggestions_only,
    )
    if include_links:
        linked_events, linked_tasks = await _records_for_documents(db, document_ids)
    else:
        linked_events = {document_id: [] for document_id in document_ids}
        linked_tasks = {document_id: [] for document_id in document_ids}

    responses: list[DocumentResponse] = []
    for row in row_data:
        document_suggestions = suggestions[row["id"]]
        pending_suggestion_count = sum(
            suggestion.status == "pending" for suggestion in document_suggestions
        )
        category_confidence = row.get("category_confidence")
        document_date_confidence = row.get("document_date_confidence")
        ready_for_batch_filing = (
            row["status"] == "inbox"
            and pending_suggestion_count == 0
            and (category_confidence is None or category_confidence >= 0.8)
            and (document_date_confidence is None or document_date_confidence >= 0.8)
        )
        responses.append(
            DocumentResponse(
                id=row["id"],
                title=row["title"],
                original_filename=row["original_filename"],
                media_type=row["media_type"],
                file_size=row["file_size"],
                sha256=row["sha256"],
                source=row["source"],
                category=row["category"],
                category_confidence=category_confidence,
                status=row["status"],
                document_date=row["document_date"],
                document_date_confidence=document_date_confidence,
                page_count=row["page_count"],
                extracted_text=row["extracted_text"] if include_text else None,
                notes=row["notes"],
                processor=row["processor"],
                people=people[row["id"]],
                suggestions=document_suggestions,
                linked_events=linked_events[row["id"]],
                linked_tasks=linked_tasks[row["id"]],
                pending_suggestion_count=pending_suggestion_count,
                ready_for_batch_filing=ready_for_batch_filing,
                download_url=f"/api/documents/{row['id']}/content",
                created_at=row["created_at"],
                updated_at=row["updated_at"],
                created_by=row["created_by"],
            )
        )
    return responses


async def _document_row(db, document_id: str, family_id: str):
    cursor = await db.execute(
        "SELECT * FROM documents WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (document_id, family_id),
    )
    row = await cursor.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Document not found")
    return row


async def _insert_people(
    db, document_id: str, people: list[dict[str, str]], current_user: dict
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    if people:
        await db.executemany(
            """
            INSERT INTO document_people (
                id, document_id, person_id, person_type, family_id,
                created_at, updated_at, created_by, client_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    str(uuid.uuid4()),
                    document_id,
                    person["id"],
                    person["person_type"],
                    current_user["family_id"],
                    now,
                    now,
                    current_user["id"],
                    None,
                )
                for person in people
            ],
        )


async def _insert_suggestions(
    db,
    document_id: str,
    suggestions: list[CaptureSuggestionCreate],
    current_user: dict,
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    if suggestions:
        await db.executemany(
            """
            INSERT INTO capture_suggestions (
                id, document_id, kind, title, details, start_time, end_time,
                due_date, all_day, assigned_to, confidence, source_text, status,
                family_id, created_at, updated_at, created_by, client_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?)
            """,
            [
                (
                    suggestion.id or str(uuid.uuid4()),
                    document_id,
                    suggestion.kind,
                    suggestion.title,
                    suggestion.details,
                    suggestion.start_time,
                    suggestion.end_time,
                    suggestion.due_date,
                    int(suggestion.all_day),
                    suggestion.assigned_to,
                    suggestion.confidence,
                    suggestion.source_text,
                    current_user["family_id"],
                    now,
                    now,
                    current_user["id"],
                    None,
                )
                for suggestion in suggestions
            ],
        )


@router.post("/", response_model=DocumentResponse, status_code=status.HTTP_201_CREATED)
async def upload_document(
    file: UploadFile = File(...),
    document_id: str | None = Form(None, max_length=64),
    title: str = Form(..., min_length=1, max_length=300),
    source: str = Form("file"),
    category: str = Form("other"),
    document_date: str | None = Form(None, max_length=64),
    page_count: int = Form(1, ge=1, le=500),
    extracted_text: str | None = Form(None, max_length=150_000),
    notes: str | None = Form(None, max_length=10_000),
    person_ids: str = Form("[]", max_length=10_000),
    suggestions: str = Form("[]", max_length=100_000),
    use_hermes: bool = Form(False),
    current_user: dict = Depends(get_current_user),
):
    """Store a document and its proposed calendar/task actions in the family inbox."""
    if document_id is not None:
        try:
            document_id = str(uuid.UUID(document_id))
        except (ValueError, AttributeError) as exc:
            raise HTTPException(status_code=422, detail="document_id must be a UUID") from exc
    else:
        document_id = str(uuid.uuid4())
    if source not in DOCUMENT_SOURCES:
        raise HTTPException(status_code=422, detail="Invalid document source")
    if category not in DOCUMENT_CATEGORIES:
        raise HTTPException(status_code=422, detail="Invalid document category")
    if use_hermes:
        require_ai_consent(current_user)

    storage_key: str | None = None
    staged_path = None
    try:
        # Reserve the durable limit before reading/hashing the request body. Exact-ID
        # replays consume an attempt too, so they cannot bypass upload rate controls.
        async with database_lease() as db:
            await reserve_persistent_attempts(
                db,
                [
                    (
                        f"document-upload:{current_user['family_id']}",
                        settings.document_upload_rate_limit_requests,
                        3_600,
                    )
                ],
                detail_prefix="Too many document uploads",
            )
        staged_path, filename, media_type, inspected_size, inspected_sha256 = await stage_upload(
            file
        )

        # A client-generated document ID is the upload's idempotency key. A retry
        # after a committed-but-unacknowledged response returns the existing row;
        # reusing the key for different bytes (or from another family) is rejected.
        async with database_lease() as db:
            cursor = await db.execute("SELECT * FROM documents WHERE id = ?", (document_id,))
            existing = await cursor.fetchone()
            if existing is not None:
                if (
                    existing["family_id"] != current_user["family_id"]
                    or existing["deleted_at"] is not None
                    or existing["sha256"] != inspected_sha256
                    or existing["file_size"] != inspected_size
                    or existing["original_filename"] != filename
                    or existing["media_type"] != media_type
                ):
                    raise HTTPException(status_code=409, detail="Document ID is already in use")
                return (
                    await _build_document_responses(
                        db,
                        [existing],
                        include_text=True,
                        pending_suggestions_only=False,
                    )
                )[0]

        parsed_person_ids = _parse_json_list(person_ids, "person_ids")
        if not all(isinstance(person_id, str) for person_id in parsed_person_ids):
            raise HTTPException(status_code=422, detail="person_ids must contain strings")
        async with database_lease() as db:
            people = await _family_people(db, current_user["family_id"], parsed_person_ids)

        raw_suggestions = _parse_json_list(suggestions, "suggestions")
        try:
            device_suggestions = [
                CaptureSuggestionCreate.model_validate(item) for item in raw_suggestions
            ]
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.errors()) from exc

        member_ids = {person["id"] for person in people}
        device_suggestions = [
            suggestion.model_copy(
                update={"assigned_to": None}
                if suggestion.assigned_to and suggestion.assigned_to not in member_ids
                else {}
            )
            for suggestion in device_suggestions[:50]
        ]

        final_suggestions = device_suggestions
        processor = "device" if device_suggestions else "fallback"
        if use_hermes and extracted_text:
            hermes_suggestions = await extract_capture_suggestions(
                title=title,
                text=extracted_text,
                people=people,
            )
            if hermes_suggestions is not None:
                final_suggestions = [
                    suggestion.model_copy(
                        update={"assigned_to": None}
                        if suggestion.assigned_to and suggestion.assigned_to not in member_ids
                        else {}
                    )
                    for suggestion in hermes_suggestions
                ]
                processor = "hermes"

        now = datetime.now(timezone.utc).isoformat()
        async with database_lease() as db:
            # Serialize only the final existence/quota check, atomic promotion and
            # metadata insert. The expensive upload read happened before this lock.
            await db.execute("BEGIN IMMEDIATE")
            cursor = await db.execute("SELECT * FROM documents WHERE id = ?", (document_id,))
            existing = await cursor.fetchone()
            if existing is not None:
                if (
                    existing["family_id"] != current_user["family_id"]
                    or existing["deleted_at"] is not None
                    or existing["sha256"] != inspected_sha256
                    or existing["file_size"] != inspected_size
                    or existing["original_filename"] != filename
                    or existing["media_type"] != media_type
                ):
                    raise HTTPException(status_code=409, detail="Document ID is already in use")
                response = (
                    await _build_document_responses(
                        db,
                        [existing],
                        include_text=True,
                        pending_suggestions_only=False,
                    )
                )[0]
                await db.commit()
                return response

            existing_storage = await family_document_storage_bytes(
                db,
                family_id=current_user["family_id"],
            )
            if existing_storage + inspected_size > settings.document_family_quota_bytes:
                raise HTTPException(
                    status_code=413,
                    detail="Family document storage quota exceeded",
                )

            storage_key = await promote_staged_upload(
                staged_path,
                family_id=current_user["family_id"],
                document_id=document_id,
                filename=filename,
            )
            staged_path = None

            await db.execute(
                """
                INSERT INTO documents (
                    id, title, original_filename, media_type, storage_key, file_size,
                    sha256, source, category, status, document_date, page_count,
                    extracted_text, notes, processor, family_id, created_at, updated_at,
                    created_by, client_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'inbox', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    document_id,
                    title.strip(),
                    filename,
                    media_type,
                    storage_key,
                    inspected_size,
                    inspected_sha256,
                    source,
                    category,
                    document_date,
                    page_count,
                    extracted_text,
                    notes,
                    processor,
                    current_user["family_id"],
                    now,
                    now,
                    current_user["id"],
                    None,
                ),
            )
            await _insert_people(db, document_id, people, current_user)
            await _insert_suggestions(db, document_id, final_suggestions, current_user)
            row = await _document_row(db, document_id, current_user["family_id"])
            response = (
                await _build_document_responses(
                    db,
                    [row],
                    include_text=True,
                    pending_suggestions_only=False,
                )
            )[0]
            await db.commit()
    except DocumentStorageError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    except BaseException:
        if storage_key:
            await remove_new_upload(storage_key)
        raise
    finally:
        await remove_staged_upload(staged_path)
        await file.close()

    return response


@router.get("/", response_model=list[DocumentResponse])
async def list_documents(
    person_id: str | None = None,
    status_filter: str | None = Query(None, alias="status"),
    category: str | None = None,
    search: str | None = Query(None, max_length=200),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if status_filter and status_filter not in DOCUMENT_STATUSES:
        raise HTTPException(status_code=422, detail="Invalid document status")
    if category and category not in DOCUMENT_CATEGORIES:
        raise HTTPException(status_code=422, detail="Invalid document category")

    query = "SELECT d.* FROM documents d WHERE d.family_id = ? AND d.deleted_at IS NULL"
    params: list = [current_user["family_id"]]
    if person_id:
        query += (
            " AND EXISTS (SELECT 1 FROM document_people dp "
            "WHERE dp.document_id = d.id AND dp.person_id = ? AND dp.deleted_at IS NULL)"
        )
        params.append(person_id)
    if status_filter:
        query += " AND d.status = ?"
        params.append(status_filter)
    else:
        query += " AND d.status != 'archived'"
    if category:
        query += " AND d.category = ?"
        params.append(category)
    if search and search.strip():
        phrase = search.strip().replace('"', " ").strip()
        if phrase and await documents_fts_available(db):
            query += " AND d.rowid IN (SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?)"
            params.append(f'"{phrase}"*')
        else:
            term = f"%{search.strip().lower()}%"
            query += " AND (LOWER(d.title) LIKE ? OR LOWER(COALESCE(d.extracted_text, '')) LIKE ?)"
            params.extend([term, term])
    if status_filter == "inbox":
        query += (
            " ORDER BY EXISTS (SELECT 1 FROM capture_suggestions pending "
            "WHERE pending.document_id = d.id AND pending.family_id = d.family_id "
            "AND pending.status = 'pending' AND pending.deleted_at IS NULL) DESC, "
            "COALESCE(d.document_date, d.created_at) DESC, d.created_at DESC"
        )
    else:
        query += " ORDER BY COALESCE(d.document_date, d.created_at) DESC, d.created_at DESC"
    query += " LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return await _build_document_responses(
        db,
        rows,
        include_text=False,
        # List payloads power the unresolved-action queue. Resolved actions stay
        # available on the document detail without cluttering every row.
        pending_suggestions_only=True,
        include_links=False,
    )


@router.get("/stats", response_model=DocumentStatsResponse)
async def document_stats(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        """
        SELECT COUNT(*) AS total,
               SUM(CASE WHEN status = 'inbox' THEN 1 ELSE 0 END) AS inbox,
               COALESCE((
                   SELECT SUM(stored.file_size)
                   FROM documents stored
                   WHERE stored.family_id = ? AND stored.deleted_at IS NULL
               ), 0) AS storage_bytes
        FROM documents
        WHERE family_id = ? AND deleted_at IS NULL AND status != 'archived'
        """,
        (current_user["family_id"], current_user["family_id"]),
    )
    row = await cursor.fetchone()
    cursor = await db.execute(
        "SELECT COUNT(*) FROM capture_suggestions "
        "WHERE family_id = ? AND status = 'pending' AND deleted_at IS NULL",
        (current_user["family_id"],),
    )
    pending = (await cursor.fetchone())[0]
    cursor = await db.execute(
        """
        SELECT dp.person_id, COUNT(DISTINCT dp.document_id)
        FROM document_people dp
        JOIN documents d ON d.id = dp.document_id
        WHERE dp.family_id = ? AND dp.deleted_at IS NULL
          AND d.deleted_at IS NULL AND d.status != 'archived'
        GROUP BY dp.person_id
        """,
        (current_user["family_id"],),
    )
    return DocumentStatsResponse(
        total_documents=row[0] or 0,
        inbox_documents=row[1] or 0,
        pending_suggestions=pending,
        storage_bytes=row[2] or 0,
        storage_quota_bytes=settings.document_family_quota_bytes,
        by_person={person_row[0]: person_row[1] for person_row in await cursor.fetchall()},
    )


@router.post("/file-ready", response_model=DocumentBatchFileResponse)
async def file_ready_documents(
    body: DocumentBatchFileRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """File only inbox documents whose inferred metadata is safe for a batch."""
    placeholders = ",".join("?" for _ in body.document_ids)
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            f"""
            SELECT id FROM documents
            WHERE id IN ({placeholders}) AND family_id = ? AND deleted_at IS NULL
              AND status = 'inbox'
              AND (category_confidence IS NULL OR category_confidence >= 0.8)
              AND (document_date_confidence IS NULL OR document_date_confidence >= 0.8)
              AND NOT EXISTS (
                  SELECT 1 FROM capture_suggestions pending
                  WHERE pending.document_id = documents.id
                    AND pending.family_id = documents.family_id
                    AND pending.status = 'pending'
                    AND pending.deleted_at IS NULL
              )
            """,
            [*body.document_ids, current_user["family_id"]],
        )
        eligible = {row["id"] for row in await cursor.fetchall()}
        filed_ids = [document_id for document_id in body.document_ids if document_id in eligible]
        skipped_ids = [
            document_id for document_id in body.document_ids if document_id not in eligible
        ]
        now = datetime.now(timezone.utc).isoformat()
        for document_id in filed_ids:
            await save_history(
                db,
                "documents",
                document_id,
                current_user["id"],
                family_id=current_user["family_id"],
            )
        if filed_ids:
            filed_placeholders = ",".join("?" for _ in filed_ids)
            await db.execute(
                f"UPDATE documents SET status = 'filed', updated_at = ? "
                f"WHERE id IN ({filed_placeholders}) AND family_id = ? AND status = 'inbox'",
                [now, *filed_ids, current_user["family_id"]],
            )
        await db.commit()
        return DocumentBatchFileResponse(filed_ids=filed_ids, skipped_ids=skipped_ids)
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


@router.get("/email-address", response_model=DocumentInboxAddressResponse)
async def document_email_address(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return the family's private forwarding address when inbound mail is configured."""
    domain = settings.resend_inbound_domain.strip().lower().lstrip("@")
    if not domain:
        return DocumentInboxAddressResponse(configured=False)

    now = datetime.now(timezone.utc).isoformat()
    preferred = settings.resend_inbound_address.strip().lower()
    if current_user["family_id"] != settings.production_family_id:
        preferred = ""
    if preferred and not preferred.endswith(f"@{domain}"):
        preferred = ""

    await db.execute("BEGIN IMMEDIATE")
    try:
        if preferred:
            cursor = await db.execute(
                "SELECT family_id FROM document_inbox_addresses WHERE LOWER(address) = ?",
                (preferred,),
            )
            owner = await cursor.fetchone()
            if owner and owner[0] != current_user["family_id"]:
                raise HTTPException(
                    status_code=409,
                    detail="The configured document inbox address is unavailable",
                )
            await db.execute(
                "UPDATE document_inbox_addresses "
                "SET enabled = 0, deleted_at = COALESCE(deleted_at, ?), updated_at = ? "
                "WHERE family_id = ? AND LOWER(address) != ? AND deleted_at IS NULL",
                (now, now, current_user["family_id"], preferred),
            )
            if not owner:
                await db.execute(
                    """
                    INSERT INTO document_inbox_addresses (
                        id, address, enabled, family_id, created_at, updated_at, created_by
                    ) VALUES (?, ?, 1, ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        preferred,
                        current_user["family_id"],
                        now,
                        now,
                        current_user["id"],
                    ),
                )
            await db.execute(
                "UPDATE document_inbox_addresses "
                "SET enabled = 1, deleted_at = NULL, updated_at = ? "
                "WHERE family_id = ? AND LOWER(address) = ?",
                (now, current_user["family_id"], preferred),
            )
            await db.commit()
            return DocumentInboxAddressResponse(configured=True, address=preferred)

        cursor = await db.execute(
            "SELECT address FROM document_inbox_addresses "
            "WHERE family_id = ? AND enabled = 1 AND deleted_at IS NULL "
            "ORDER BY created_at LIMIT 1",
            (current_user["family_id"],),
        )
        row = await cursor.fetchone()
        if row:
            await db.commit()
            return DocumentInboxAddressResponse(configured=True, address=row[0])

        address = f"family-{uuid.uuid4().hex[:20]}@{domain}"
        await db.execute(
            """
            INSERT INTO document_inbox_addresses (
                id, address, enabled, family_id, created_at, updated_at, created_by
            ) VALUES (?, ?, 1, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                address,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
            ),
        )
        await db.commit()
        return DocumentInboxAddressResponse(configured=True, address=address)
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


@router.get("/{document_id}", response_model=DocumentResponse)
async def get_document(
    document_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _document_row(db, document_id, current_user["family_id"])
    return (
        await _build_document_responses(
            db,
            [row],
            include_text=True,
            pending_suggestions_only=False,
        )
    )[0]


@router.get("/{document_id}/content")
async def download_document(
    document_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _document_row(db, document_id, current_user["family_id"])
    path = resolve_storage_key(row["storage_key"])
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Document file is unavailable")
    return FileResponse(
        path,
        media_type=row["media_type"],
        filename=row["original_filename"],
        content_disposition_type="inline",
    )


@router.patch("/{document_id}", response_model=DocumentResponse)
async def update_document(
    document_id: str,
    body: DocumentUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await db.execute("BEGIN IMMEDIATE")
    try:
        await _document_row(db, document_id, current_user["family_id"])
        updates = body.model_dump(exclude_unset=True, exclude={"person_ids"})
        if "title" in updates:
            updates["title"] = updates["title"].strip()
        if "category" in updates:
            updates["category_confidence"] = None
        if "document_date" in updates:
            updates["document_date_confidence"] = None
        now = datetime.now(timezone.utc).isoformat()
        await save_history(
            db,
            "documents",
            document_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        if updates:
            set_clause = ", ".join(f"{field} = ?" for field in updates)
            await db.execute(
                f"UPDATE documents SET {set_clause}, updated_at = ? "
                "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                [*updates.values(), now, document_id, current_user["family_id"]],
            )

        if body.person_ids is not None:
            people = await _family_people(db, current_user["family_id"], body.person_ids)
            await db.execute(
                "UPDATE document_people SET deleted_at = ?, updated_at = ? "
                "WHERE document_id = ? AND family_id = ? AND deleted_at IS NULL",
                (now, now, document_id, current_user["family_id"]),
            )
            await _insert_people(db, document_id, people, current_user)

        row = await _document_row(db, document_id, current_user["family_id"])
        response = (
            await _build_document_responses(
                db,
                [row],
                include_text=True,
                pending_suggestions_only=False,
            )
        )[0]
        await db.commit()
        return response
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


@router.delete("/{document_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_document(
    document_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    # Reserve the writer before reading references. This fences concurrent direct
    # event/task attachment edits until deletion and detachment are both committed.
    await db.execute("BEGIN IMMEDIATE")
    try:
        document = await _document_row(db, document_id, current_user["family_id"])
        storage_key = document["storage_key"]
        now = datetime.now(timezone.utc).isoformat()
        await save_history(
            db,
            "documents",
            document_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        await _detach_document_references(
            db,
            document_id=document_id,
            family_id=current_user["family_id"],
            changed_by=current_user["id"],
            now=now,
        )
        await db.execute(
            "UPDATE documents SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (now, now, document_id, current_user["family_id"]),
        )
        await db.execute(
            "UPDATE document_people SET deleted_at = ?, updated_at = ? "
            "WHERE document_id = ? AND family_id = ? AND deleted_at IS NULL",
            (now, now, document_id, current_user["family_id"]),
        )
        await db.execute(
            "UPDATE capture_suggestions SET deleted_at = ?, updated_at = ? "
            "WHERE document_id = ? AND family_id = ? AND deleted_at IS NULL",
            (now, now, document_id, current_user["family_id"]),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    await remove_stored_document(storage_key)


async def _suggestion_row(db, document_id: str, suggestion_id: str, family_id: str):
    cursor = await db.execute(
        """
        SELECT s.*, d.title AS document_title
        FROM capture_suggestions s
        JOIN documents d ON d.id = s.document_id
        WHERE s.id = ? AND s.document_id = ? AND s.family_id = ?
          AND s.deleted_at IS NULL AND d.deleted_at IS NULL
        """,
        (suggestion_id, document_id, family_id),
    )
    row = await cursor.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Capture suggestion not found")
    return row


async def _auto_file_document(db, document_id: str, family_id: str, now: str) -> None:
    cursor = await db.execute(
        "SELECT COUNT(*) FROM capture_suggestions "
        "WHERE document_id = ? AND family_id = ? AND status = 'pending' AND deleted_at IS NULL",
        (document_id, family_id),
    )
    if (await cursor.fetchone())[0] == 0:
        await db.execute(
            "UPDATE documents SET status = 'filed', updated_at = ? "
            "WHERE id = ? AND family_id = ? AND status = 'inbox'",
            (now, document_id, family_id),
        )


@router.patch(
    "/{document_id}/suggestions/{suggestion_id}", response_model=CaptureSuggestionResponse
)
async def update_suggestion(
    document_id: str,
    suggestion_id: str,
    body: CaptureSuggestionUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await db.execute("BEGIN IMMEDIATE")
    try:
        await _suggestion_row(db, document_id, suggestion_id, current_user["family_id"])
        updates = body.model_dump(exclude_unset=True)
        if not updates:
            raise HTTPException(status_code=422, detail="No suggestion changes supplied")
        if updates.get("assigned_to"):
            await _family_people(db, current_user["family_id"], [updates["assigned_to"]])
        now = datetime.now(timezone.utc).isoformat()
        await save_history(
            db,
            "capture_suggestions",
            suggestion_id,
            current_user["id"],
            family_id=current_user["family_id"],
        )
        set_clause = ", ".join(f"{field} = ?" for field in updates)
        if "all_day" in updates:
            updates["all_day"] = int(updates["all_day"])
        await db.execute(
            f"UPDATE capture_suggestions SET {set_clause}, updated_at = ? "
            "WHERE id = ? AND document_id = ? AND family_id = ? AND deleted_at IS NULL",
            [*updates.values(), now, suggestion_id, document_id, current_user["family_id"]],
        )
        suggestions = await _suggestions_for_documents(db, [document_id], pending_only=False)
        response = next(item for item in suggestions[document_id] if item.id == suggestion_id)
        await db.commit()
        return response
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


@router.post(
    "/{document_id}/suggestions",
    response_model=CaptureSuggestionResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_suggestion(
    document_id: str,
    body: CaptureSuggestionCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Add a manually reviewed action to an existing document."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        await _document_row(db, document_id, current_user["family_id"])
        if body.assigned_to:
            await _family_people(db, current_user["family_id"], [body.assigned_to])

        suggestion = body.model_copy(update={"id": body.id or str(uuid.uuid4())})
        await _insert_suggestions(db, document_id, [suggestion], current_user)
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            "UPDATE documents SET status = 'inbox', updated_at = ? "
            "WHERE id = ? AND family_id = ? AND status = 'filed' AND deleted_at IS NULL",
            (now, document_id, current_user["family_id"]),
        )

        suggestions = await _suggestions_for_documents(db, [document_id], pending_only=False)
        response = next(item for item in suggestions[document_id] if item.id == suggestion.id)
        await db.commit()
        return response
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


@router.post(
    "/{document_id}/suggestions/{suggestion_id}/accept",
    response_model=SuggestionResolutionResponse,
)
async def accept_suggestion(
    document_id: str,
    suggestion_id: str,
    body: CaptureSuggestionUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await db.execute("BEGIN IMMEDIATE")
    row = await _suggestion_row(db, document_id, suggestion_id, current_user["family_id"])
    if row["status"] != "pending":
        raise HTTPException(status_code=409, detail="Capture suggestion has already been resolved")

    merged = dict(row)
    merged.update(body.model_dump(exclude_unset=True))
    try:
        validated = CaptureSuggestionCreate.model_validate(merged)
    except ValidationError as exc:
        raise HTTPException(status_code=422, detail=exc.errors()) from exc

    assigned_person = None
    if validated.assigned_to:
        assigned_person = (
            await _family_people(db, current_user["family_id"], [validated.assigned_to])
        )[0]

    now = datetime.now(timezone.utc).isoformat()
    result_id = str(uuid.uuid4())
    await save_history(
        db,
        "capture_suggestions",
        suggestion_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    claim = await db.execute(
        "UPDATE capture_suggestions SET result_id = ?, updated_at = ? "
        "WHERE id = ? AND document_id = ? AND family_id = ? "
        "AND status = 'pending' AND result_id IS NULL AND deleted_at IS NULL",
        (
            result_id,
            now,
            suggestion_id,
            document_id,
            current_user["family_id"],
        ),
    )
    if claim.rowcount != 1:
        await db.rollback()
        raise HTTPException(status_code=409, detail="Capture suggestion has already been resolved")

    await _materialise_suggestion(
        db,
        validated=validated,
        assigned_person=assigned_person,
        suggestion_id=suggestion_id,
        document_id=document_id,
        result_id=result_id,
        current_user=current_user,
        now=now,
    )
    await _auto_file_document(db, document_id, current_user["family_id"], now)
    await db.commit()
    return SuggestionResolutionResponse(
        suggestion_id=suggestion_id,
        status="accepted",
        result_type=validated.kind,
        result_id=result_id,
    )


async def _materialise_suggestion(
    db,
    *,
    validated: CaptureSuggestionCreate,
    assigned_person: dict | None,
    suggestion_id: str,
    document_id: str,
    result_id: str,
    current_user: dict,
    now: str,
) -> None:
    """Create the event or task for a claimed suggestion and mark it accepted."""
    if validated.kind == "event":
        await db.execute(
            """
            INSERT INTO calendar_events (
                id, title, description, start_time, end_time, all_day,
                assigned_to, family_member_ids, source_document_id, family_id,
                created_at, updated_at, created_by
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                result_id,
                validated.title,
                validated.details,
                validated.start_time,
                validated.end_time,
                int(validated.all_day),
                validated.assigned_to,
                json.dumps([validated.assigned_to]) if validated.assigned_to else None,
                document_id,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
            ),
        )
    else:
        await db.execute(
            """
            INSERT INTO tasks (
                id, title, description, assigned_to, due_date, category,
                priority, source_document_id, family_id, created_at, updated_at, created_by
            ) VALUES (?, ?, ?, ?, ?, 'admin', 2, ?, ?, ?, ?, ?)
            """,
            (
                result_id,
                validated.title,
                validated.details,
                validated.assigned_to,
                validated.due_date,
                document_id,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
            ),
        )
        if assigned_person:
            await db.execute(
                """
                INSERT INTO task_assignments (
                    id, task_id, assignee_id, assignee_type, family_id,
                    created_at, updated_at, created_by
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    result_id,
                    assigned_person["id"],
                    assigned_person["person_type"],
                    current_user["family_id"],
                    now,
                    now,
                    current_user["id"],
                ),
            )

    await db.execute(
        """
        UPDATE capture_suggestions
        SET kind = ?, title = ?, details = ?, start_time = ?, end_time = ?,
            due_date = ?, all_day = ?, assigned_to = ?, status = 'accepted',
            result_id = ?, updated_at = ?
        WHERE id = ? AND document_id = ? AND family_id = ?
            AND status = 'pending' AND result_id = ? AND deleted_at IS NULL
        """,
        (
            validated.kind,
            validated.title,
            validated.details,
            validated.start_time,
            validated.end_time,
            validated.due_date,
            int(validated.all_day),
            validated.assigned_to,
            result_id,
            now,
            suggestion_id,
            document_id,
            current_user["family_id"],
            result_id,
        ),
    )


@router.post("/{document_id}/suggestions/accept-all")
async def accept_all_suggestions(
    document_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Accept every pending suggestion on a document in one confirmation."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        await _document_row(db, document_id, current_user["family_id"])
        cursor = await db.execute(
            """
            SELECT * FROM capture_suggestions
            WHERE document_id = ? AND family_id = ? AND status = 'pending'
              AND result_id IS NULL AND deleted_at IS NULL
            ORDER BY created_at, id
            """,
            (document_id, current_user["family_id"]),
        )
        rows = [dict(row) for row in await cursor.fetchall()]

        now = datetime.now(timezone.utc).isoformat()
        accepted: list[dict] = []
        skipped: list[dict] = []
        for row in rows:
            try:
                validated = CaptureSuggestionCreate.model_validate(row)
            except ValidationError:
                skipped.append(
                    {
                        "suggestion_id": row["id"],
                        "reason": "The suggestion is missing a valid date or title",
                    }
                )
                continue
            assigned_person = None
            if validated.assigned_to:
                try:
                    assigned_person = (
                        await _family_people(db, current_user["family_id"], [validated.assigned_to])
                    )[0]
                except HTTPException:
                    skipped.append(
                        {
                            "suggestion_id": row["id"],
                            "reason": "The assigned family member no longer exists",
                        }
                    )
                    continue
            result_id = str(uuid.uuid4())
            await save_history(
                db,
                "capture_suggestions",
                row["id"],
                current_user["id"],
                family_id=current_user["family_id"],
            )
            claim = await db.execute(
                "UPDATE capture_suggestions SET result_id = ?, updated_at = ? "
                "WHERE id = ? AND document_id = ? AND family_id = ? "
                "AND status = 'pending' AND result_id IS NULL AND deleted_at IS NULL",
                (result_id, now, row["id"], document_id, current_user["family_id"]),
            )
            if claim.rowcount != 1:
                skipped.append(
                    {
                        "suggestion_id": row["id"],
                        "reason": "The suggestion was already resolved",
                    }
                )
                continue
            await _materialise_suggestion(
                db,
                validated=validated,
                assigned_person=assigned_person,
                suggestion_id=row["id"],
                document_id=document_id,
                result_id=result_id,
                current_user=current_user,
                now=now,
            )
            accepted.append(
                {
                    "suggestion_id": row["id"],
                    "result_type": validated.kind,
                    "result_id": result_id,
                }
            )
        if accepted:
            await _auto_file_document(db, document_id, current_user["family_id"], now)
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return {"accepted": accepted, "skipped": skipped}


@router.post(
    "/{document_id}/suggestions/{suggestion_id}/dismiss",
    response_model=SuggestionResolutionResponse,
)
async def dismiss_suggestion(
    document_id: str,
    suggestion_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await db.execute("BEGIN IMMEDIATE")
    row = await _suggestion_row(db, document_id, suggestion_id, current_user["family_id"])
    if row["status"] != "pending":
        raise HTTPException(status_code=409, detail="Capture suggestion has already been resolved")
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db,
        "capture_suggestions",
        suggestion_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    resolution = await db.execute(
        "UPDATE capture_suggestions SET status = 'dismissed', updated_at = ? "
        "WHERE id = ? AND document_id = ? AND family_id = ? "
        "AND status = 'pending' AND result_id IS NULL AND deleted_at IS NULL",
        (now, suggestion_id, document_id, current_user["family_id"]),
    )
    if resolution.rowcount != 1:
        await db.rollback()
        raise HTTPException(status_code=409, detail="Capture suggestion has already been resolved")
    await _auto_file_document(db, document_id, current_user["family_id"], now)
    await db.commit()
    return SuggestionResolutionResponse(suggestion_id=suggestion_id, status="dismissed")
