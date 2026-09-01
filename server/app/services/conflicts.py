"""Household edit-priority helpers shared by calm coordination features."""

from __future__ import annotations

from datetime import datetime, timezone


def parsed_client_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


async def higher_priority_recent_edit(
    db,
    *,
    existing,
    current_user: dict,
    incoming_timestamp: str | None,
) -> bool:
    """Apply HausKlar's five-minute Morgan-wins conflict rule."""
    incoming = parsed_client_time(incoming_timestamp)
    prior = parsed_client_time(existing["client_timestamp"])
    updater = existing["updated_by"] or existing["created_by"]
    if incoming is None or prior is None or updater == current_user["id"]:
        return False
    if abs((incoming - prior).total_seconds()) > 300:
        return False
    row = await (
        await db.execute(
            "SELECT priority FROM users WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (updater, current_user["family_id"]),
        )
    ).fetchone()
    return row is not None and int(row["priority"] or 0) > int(
        current_user.get("priority") or 0
    )
