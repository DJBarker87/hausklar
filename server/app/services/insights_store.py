"""Shared storage + dedup for family insights (School Brain and Second Brain)."""

import uuid
from datetime import datetime, timezone


async def store_insights(db, *, family_id: str, findings: list[dict], created_by: str) -> list[dict]:
    """Insert new findings, skipping duplicates of active insights. Commits."""
    inserted: list[dict] = []
    for finding in findings:
        cursor = await db.execute(
            """SELECT 1 FROM family_insights
               WHERE family_id = ? AND status = 'active' AND deleted_at IS NULL
                 AND kind = ? AND target_date IS ? AND LOWER(message) = LOWER(?)""",
            (family_id, finding["kind"], finding.get("target_date"), finding["message"]),
        )
        if await cursor.fetchone():
            continue
        insight_id = str(uuid.uuid4())
        created = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """INSERT INTO family_insights
               (id, kind, message, detail, target_date, source_document_id, status,
                family_id, created_at, updated_at, created_by, client_id)
               VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?)""",
            (
                insight_id,
                finding["kind"],
                finding["message"],
                finding.get("detail"),
                finding.get("target_date"),
                finding.get("source_document_id"),
                family_id,
                created,
                created,
                created_by,
                created_by,
            ),
        )
        inserted.append({"id": insight_id, **finding, "created_at": created})
    await db.commit()
    return inserted
