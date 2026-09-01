"""Cheap, exact invalidation watermark for persisted Finance coaching reports."""

import hashlib
import json
import re


_SAFE_TABLE = re.compile(r"^finance_[a-z0-9_]+$")
_EXCLUDED_TABLES = {
    "finance_ai_consents",
    "finance_coaching_reports",
}
_REPORT_INPUT_VERSION = "finance-coaching-report-v1"
_revision_tables: tuple[tuple[str, bool], ...] | None = None


async def _discover_revision_tables(db) -> tuple[tuple[str, bool], ...]:
    global _revision_tables
    if _revision_tables is not None:
        return _revision_tables
    rows = await (
        await db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name LIKE 'finance_%' ORDER BY name"
        )
    ).fetchall()
    discovered: list[tuple[str, bool]] = []
    for row in rows:
        name = row["name"]
        if name in _EXCLUDED_TABLES or not _SAFE_TABLE.fullmatch(name):
            continue
        columns = {
            column["name"]
            for column in await (await db.execute(f'PRAGMA table_info("{name}")')).fetchall()
        }
        if {"family_id", "updated_at"} <= columns:
            discovered.append((name, "space_id" in columns))
    _revision_tables = tuple(discovered)
    return _revision_tables


async def finance_space_watermark(db, *, family_id: str, space_id: str) -> str:
    """Hash per-table update markers without loading any Finance records."""
    tables = await _discover_revision_tables(db)
    statements: list[str] = []
    parameters: list[object] = []
    for name, has_space in tables:
        statements.append(
            f"SELECT ? AS table_name, COALESCE(MAX(updated_at), '') AS latest, "
            f'COUNT(*) AS records FROM "{name}" WHERE family_id = ?'
            + (" AND space_id = ?" if has_space else "")
        )
        parameters.extend((name, family_id))
        if has_space:
            parameters.append(space_id)
    if not statements:
        empty = json.dumps(
            {"report_input_version": _REPORT_INPUT_VERSION, "tables": []},
            separators=(",", ":"),
            ensure_ascii=True,
        )
        return hashlib.sha256(empty.encode("utf-8")).hexdigest()
    rows = await (await db.execute(" UNION ALL ".join(statements), parameters)).fetchall()
    canonical = json.dumps(
        {
            "report_input_version": _REPORT_INPUT_VERSION,
            "tables": [
                (row["table_name"], row["latest"], row["records"]) for row in rows
            ],
        },
        separators=(",", ":"),
        ensure_ascii=True,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
