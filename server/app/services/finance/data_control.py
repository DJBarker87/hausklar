"""Bounded owner-visible Finance export and mutation history."""

from __future__ import annotations

import json
import re
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.models.finance_data_control import (
    FinanceHistoryEntryResponse,
    FinanceHistoryPageResponse,
)
from app.services.documents import DocumentStorageError, resolve_storage_key
from app.services.finance.foundation import resolve_finance_scope_spaces

_EXPORT_FETCH_SIZE = 500
_MAX_EXPORT_ROWS = 250_000
_MAX_RECORD_BYTES = 512 * 1024 * 1024
_MAX_EVIDENCE_FILES = 2_000
_MAX_EVIDENCE_BYTES = 512 * 1024 * 1024
_TABLE_NAME = re.compile(r"^finance_[a-z0-9_]+$")

# These rows contain ephemeral model drafts or private cross-space provenance,
# rather than owner-visible financial records.
_EXCLUDED_EXPORT_TABLES = {
    "finance_capture_drafts",
    "finance_share_actions",
    "finance_share_copy_links",
}
_SECRET_EXPORT_FIELDS = {
    "callback_state_hash",
    "encrypted_provider_secret_ref",
    "sync_lease_token",
    "sync_lease_expires_at",
    "confirmation_digest",
    "storage_key",
}
_SECRET_EXPORT_FIELD_PARTS = (
    "credential",
    "password",
    "private_key",
    "secret",
    "seed_phrase",
    "token",
)
_AUDIT_HIDDEN_PARTS = (
    "authentication",
    "credential",
    "evidence",
    "provider",
    "raw_",
    "secret",
    "source_ref",
    "storage",
    "token",
)
_AUDIT_HIDDEN_FIELDS = {
    "account_id",
    "client_id",
    "client_timestamp",
    "created_by",
    "family_id",
    "member_user_id",
    "owner_user_id",
    "space_id",
    "user_id",
}
_HISTORY_OWNER_FIELDS = (
    "owner_user_id",
    "member_user_id",
    "creator_user_id",
    "user_id",
)


class FinanceExportTooLargeError(ValueError):
    """The export must be split before it can be generated safely."""


def _json_value(value: Any) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


def _export_row(row) -> dict[str, Any]:
    result = dict(row)
    for key in list(result):
        if key in _SECRET_EXPORT_FIELDS or any(
            part in key.casefold() for part in _SECRET_EXPORT_FIELD_PARTS
        ):
            result.pop(key, None)
            continue
        if key.endswith("_json") and isinstance(result[key], str):
            result[key.removesuffix("_json")] = _json_value(result.pop(key))
    return result


def _audit_values(serialized: str) -> dict[str, Any]:
    try:
        source = json.loads(serialized)
    except (TypeError, json.JSONDecodeError):
        return {}
    result: dict[str, Any] = {}
    for key, value in source.items():
        lowered = key.casefold()
        if key in _AUDIT_HIDDEN_FIELDS or key.endswith(("_id", "_json")):
            continue
        if any(part in lowered for part in _AUDIT_HIDDEN_PARTS):
            continue
        if value is None or isinstance(value, (str, int, bool)):
            result[key] = value
    return result


def _history_owner_filter(alias: str = "history") -> tuple[str, tuple[str, ...]]:
    """Keep shared history plus rows owned by the adult requesting it."""
    clauses = "".join(
        f" AND (json_extract({alias}.previous_values, '$.{field}') IS NULL"
        f" OR json_extract({alias}.previous_values, '$.{field}') = ?)"
        for field in _HISTORY_OWNER_FIELDS
    )
    return clauses, _HISTORY_OWNER_FIELDS


async def list_finance_history(
    db,
    *,
    user: dict,
    scope: str,
    offset: int,
    limit: int,
) -> FinanceHistoryPageResponse:
    """Page history only after the caller's spaces are bound and filtered."""
    space_ids = await resolve_finance_scope_spaces(db, user=user, scope=scope)
    placeholders = ",".join("?" for _ in space_ids)
    owner_sql, owner_fields = _history_owner_filter()
    rows = await (
        await db.execute(
            f"""
            SELECT history.id, history.table_name, history.record_id,
                   history.previous_values, history.changed_at,
                   history.changed_by, actor.name AS changed_by_name
            FROM record_history history
            LEFT JOIN users actor
              ON actor.id = history.changed_by AND actor.family_id = history.family_id
            WHERE history.family_id = ?
              AND history.table_name GLOB 'finance_*'
              AND json_valid(history.previous_values)
              AND json_extract(history.previous_values, '$.space_id')
                    IN ({placeholders})
              {owner_sql}
            ORDER BY history.changed_at DESC, history.id DESC
            LIMIT ? OFFSET ?
            """,
            (
                user["family_id"],
                *space_ids,
                *(user["id"] for _ in owner_fields),
                limit + 1,
                offset,
            ),
        )
    ).fetchall()
    visible = rows[:limit]
    return FinanceHistoryPageResponse(
        scope=scope,
        offset=offset,
        limit=limit,
        has_more=len(rows) > limit,
        items=[
            FinanceHistoryEntryResponse(
                id=row["id"],
                record_type=row["table_name"].removeprefix("finance_"),
                record_id=row["record_id"],
                changed_at=row["changed_at"],
                changed_by_name=row["changed_by_name"],
                changed_by_current_user=row["changed_by"] == user["id"],
                previous_values=_audit_values(row["previous_values"]),
            )
            for row in visible
        ],
    )


async def _exportable_space_tables(db) -> list[tuple[str, set[str]]]:
    rows = await (
        await db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name LIKE 'finance_%' ORDER BY name"
        )
    ).fetchall()
    result: list[tuple[str, set[str]]] = []
    for row in rows:
        table = row["name"]
        if table in _EXCLUDED_EXPORT_TABLES or not _TABLE_NAME.fullmatch(table):
            continue
        columns = {
            column["name"]
            for column in await (await db.execute(f'PRAGMA table_info("{table}")')).fetchall()
        }
        if {"space_id", "family_id"}.issubset(columns):
            result.append((table, columns))
    return result


def _owner_filter(
    columns: set[str], *, household_space_ids: tuple[str, ...]
) -> tuple[str, list[str]]:
    for field in ("owner_user_id", "member_user_id", "creator_user_id", "user_id"):
        if field not in columns:
            continue
        if field == "owner_user_id":
            household_placeholders = ",".join("?" for _ in household_space_ids)
            return (
                f" AND ({field} = ? OR ({field} IS NULL "
                f"AND space_id IN ({household_placeholders})))",
                ["user", *household_space_ids],
            )
        return f" AND {field} = ?", ["user"]
    return "", []


async def build_finance_export(db, *, user: dict):
    """Build a ZIP from bounded, pre-authorised queries and stream it afterwards."""
    active_space_ids = await resolve_finance_scope_spaces(
        db, user=user, scope="mine"
    )
    personal_space_id, household_space_id = active_space_ids
    space_rows = await (
        await db.execute(
            """
            SELECT * FROM finance_spaces
            WHERE family_id = ?
              AND ((kind = 'personal' AND owner_user_id = ?)
                   OR (kind = 'household' AND owner_user_id IS NULL))
            ORDER BY created_at, id
            """,
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    space_ids = tuple(row["id"] for row in space_rows)
    household_space_ids = tuple(
        row["id"] for row in space_rows if row["kind"] == "household"
    )
    placeholders = ",".join("?" for _ in space_ids)
    output = tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024, mode="w+b")
    row_counts: dict[str, int] = {}
    total_rows = 0
    record_bytes = 0
    evidence_files: list[dict[str, Any]] = []
    missing_evidence_ids: list[str] = []
    try:
        with zipfile.ZipFile(output, mode="w", compression=zipfile.ZIP_STORED) as archive:
            for table, columns in await _exportable_space_tables(db):
                owner_sql, owner_values = _owner_filter(
                    columns, household_space_ids=household_space_ids
                )
                parameters: list[Any] = [user["family_id"], *space_ids]
                parameters.extend(
                    user["id"] if marker == "user" else marker
                    for marker in owner_values
                )
                cursor = await db.execute(
                    f'SELECT * FROM "{table}" WHERE family_id = ? '
                    f"AND space_id IN ({placeholders}){owner_sql} ORDER BY created_at, id",
                    parameters,
                )
                count = 0
                with archive.open(f"records/{table}.ndjson", "w") as target:
                    while batch := await cursor.fetchmany(_EXPORT_FETCH_SIZE):
                        total_rows += len(batch)
                        count += len(batch)
                        if total_rows > _MAX_EXPORT_ROWS:
                            raise FinanceExportTooLargeError(
                                "Finance export exceeds the 250,000-record safety limit"
                            )
                        for row in batch:
                            exported = _export_row(row)
                            encoded = (
                                json.dumps(exported, ensure_ascii=False) + "\n"
                            ).encode()
                            record_bytes += len(encoded)
                            if record_bytes > _MAX_RECORD_BYTES:
                                raise FinanceExportTooLargeError(
                                    "Finance export exceeds the 512 MB record safety limit"
                                )
                            target.write(encoded)
                            if table == "finance_purchase_source_files":
                                evidence_files.append(dict(row))
                row_counts[table] = count

            history_cursor = await db.execute(
                f"""
                SELECT history.id, history.table_name, history.record_id,
                       history.previous_values, history.changed_at,
                       history.changed_by, actor.name AS changed_by_name
                FROM record_history history
                LEFT JOIN users actor
                  ON actor.id = history.changed_by
                 AND actor.family_id = history.family_id
                WHERE history.family_id = ?
                  AND history.table_name GLOB 'finance_*'
                  AND json_valid(history.previous_values)
                  AND json_extract(history.previous_values, '$.space_id')
                        IN ({placeholders})
                  {_history_owner_filter()[0]}
                ORDER BY history.changed_at, history.id
                """,
                (
                    user["family_id"],
                    *space_ids,
                    *(user["id"] for _ in _HISTORY_OWNER_FIELDS),
                ),
            )
            history_count = 0
            with archive.open("records/finance_history.ndjson", "w") as target:
                while batch := await history_cursor.fetchmany(_EXPORT_FETCH_SIZE):
                    total_rows += len(batch)
                    history_count += len(batch)
                    if total_rows > _MAX_EXPORT_ROWS:
                        raise FinanceExportTooLargeError(
                            "Finance export exceeds the 250,000-record safety limit"
                        )
                    for row in batch:
                        encoded = (
                            json.dumps(
                                {
                                    "id": row["id"],
                                    "record_type": row["table_name"].removeprefix(
                                        "finance_"
                                    ),
                                    "record_id": row["record_id"],
                                    "changed_at": row["changed_at"],
                                    "changed_by_name": row["changed_by_name"],
                                    "changed_by_current_user": (
                                        row["changed_by"] == user["id"]
                                    ),
                                    "previous_values": _audit_values(
                                        row["previous_values"]
                                    ),
                                },
                                ensure_ascii=False,
                            )
                            + "\n"
                        ).encode()
                        record_bytes += len(encoded)
                        if record_bytes > _MAX_RECORD_BYTES:
                            raise FinanceExportTooLargeError(
                                "Finance export exceeds the 512 MB record safety limit"
                            )
                        target.write(encoded)
            row_counts["finance_history"] = history_count

            # Shared-line copies contain a new household source and no handle to
            # the owner's private original. Only files whose own row is already
            # in an authorised space can reach this loop.
            stored_files = [
                row
                for row in evidence_files
                if row["storage_status"] == "STORED" and row["storage_key"]
            ]
            total_evidence_bytes = sum(int(row["byte_size"]) for row in stored_files)
            if len(stored_files) > _MAX_EVIDENCE_FILES:
                raise FinanceExportTooLargeError(
                    "Finance export exceeds the 2,000-evidence-file safety limit"
                )
            if total_evidence_bytes > _MAX_EVIDENCE_BYTES:
                raise FinanceExportTooLargeError(
                    "Finance export exceeds the 512 MB evidence safety limit"
                )
            for row in stored_files:
                try:
                    source = resolve_storage_key(row["storage_key"])
                except DocumentStorageError:
                    missing_evidence_ids.append(row["id"])
                    continue
                if not source.is_file():
                    missing_evidence_ids.append(row["id"])
                    continue
                basename = Path(row["filename"]).name.replace("..", ".")
                safe_name = re.sub(r"[^A-Za-z0-9._-]+", "-", basename)[:160]
                safe_name = safe_name.strip(".-") or "evidence.bin"
                archive.write(source, f"evidence/{row['id']}-{safe_name}")

            special_queries = {
                "finance_spaces": (
                    "SELECT * FROM finance_spaces WHERE id IN ("
                    f"{placeholders}) AND family_id = ? ORDER BY created_at, id",
                    (*space_ids, user["family_id"]),
                ),
                "finance_settings": (
                    "SELECT * FROM finance_settings WHERE family_id = ? "
                    "ORDER BY created_at, id",
                    (user["family_id"],),
                ),
                "finance_projection_preferences": (
                    "SELECT * FROM finance_projection_preferences "
                    "WHERE family_id = ? AND user_id = ? ORDER BY created_at, id",
                    (user["family_id"], user["id"]),
                ),
                "finance_commitment_occurrences": (
                    "SELECT occurrence.* FROM finance_commitment_occurrences occurrence "
                    "JOIN finance_commitments commitment "
                    "ON commitment.id = occurrence.commitment_id "
                    "AND commitment.family_id = occurrence.family_id "
                    f"WHERE occurrence.family_id = ? AND commitment.space_id IN ({placeholders}) "
                    "ORDER BY occurrence.created_at, occurrence.id",
                    (user["family_id"], *space_ids),
                ),
            }
            for table, (sql, parameters) in special_queries.items():
                cursor = await db.execute(sql, parameters)
                count = 0
                with archive.open(f"records/{table}.ndjson", "w") as target:
                    while batch := await cursor.fetchmany(_EXPORT_FETCH_SIZE):
                        total_rows += len(batch)
                        count += len(batch)
                        if total_rows > _MAX_EXPORT_ROWS:
                            raise FinanceExportTooLargeError(
                                "Finance export exceeds the 250,000-record safety limit"
                            )
                        for row in batch:
                            encoded = (
                                json.dumps(_export_row(row), ensure_ascii=False) + "\n"
                            ).encode()
                            record_bytes += len(encoded)
                            if record_bytes > _MAX_RECORD_BYTES:
                                raise FinanceExportTooLargeError(
                                    "Finance export exceeds the 512 MB record safety limit"
                                )
                            target.write(encoded)
                row_counts[table] = count
            archive.writestr(
                "manifest.json",
                json.dumps(
                    {
                        "format": "hausklar-finance-export-v1",
                        "exported_at": datetime.now(timezone.utc).isoformat(),
                        "scope": "current adult personal plus household",
                        "space_kinds": ["personal", "household"],
                        "table_row_counts": row_counts,
                        "included_evidence_file_ids": [
                            row["id"]
                            for row in stored_files
                            if row["id"] not in missing_evidence_ids
                        ],
                        "missing_evidence_file_ids": missing_evidence_ids,
                        "includes_soft_deleted_records": True,
                        "excluded": [
                            "provider credentials and sync leases",
                            "other adults' personal spaces",
                            "other adults' owner-specific views, reports, drafts and consents",
                            "internal share provenance",
                            "private source evidence behind household copy records",
                        ],
                        "personal_space_id": personal_space_id,
                        "household_space_id": household_space_id,
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
            )
        output.seek(0)
        return output
    except BaseException:
        output.close()
        raise
