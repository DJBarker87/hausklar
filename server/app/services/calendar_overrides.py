"""Lifecycle helpers for editable copies of read-only calendar events."""

from __future__ import annotations

from collections.abc import Collection

from app.services.record_history import save_history


async def soft_delete_overrides_for_sources(
    db,
    source_event_ids: Collection[str],
    *,
    family_id: str,
    actor_id: str,
    now: str,
) -> int:
    """Soft-delete active overrides whose source events are being removed.

    Overrides deliberately live outside the imported calendar source so that a
    refresh cannot overwrite a family's correction. That also means their
    lifecycle must be handled explicitly when the source event disappears.
    """
    source_ids = list(dict.fromkeys(source_event_ids))
    if not source_ids:
        return 0

    placeholders = ",".join("?" for _ in source_ids)
    cursor = await db.execute(
        f"""
        SELECT id FROM calendar_events
        WHERE family_id = ? AND deleted_at IS NULL
          AND overridden_event_id IN ({placeholders})
        """,
        (family_id, *source_ids),
    )
    overrides = await cursor.fetchall()
    for override in overrides:
        await save_history(
            db,
            "calendar_events",
            override["id"],
            actor_id,
            family_id=family_id,
        )
    if overrides:
        override_ids = [row["id"] for row in overrides]
        override_placeholders = ",".join("?" for _ in override_ids)
        await db.execute(
            f"""
            UPDATE calendar_events
            SET deleted_at = ?, updated_at = ?
            WHERE family_id = ? AND deleted_at IS NULL
              AND id IN ({override_placeholders})
            """,
            (now, now, family_id, *override_ids),
        )
    return len(overrides)
