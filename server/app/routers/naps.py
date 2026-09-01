import json
import uuid
from datetime import date as calendar_date
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.nap import NapEndRequest, NapResponse, NapStartRequest, NapUpdateRequest
from app.services.family_people import family_child_exists

router = APIRouter()
DEFAULT_FAMILY_TIMEZONE = "Europe/London"


def _local_day_utc_bounds(day_value: str, timezone_name: str) -> tuple[str, str]:
    """Return the UTC half-open interval for one family-local calendar day."""
    try:
        day = calendar_date.fromisoformat(day_value)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="Date must use YYYY-MM-DD") from exc
    if day.isoformat() != day_value:
        raise HTTPException(status_code=422, detail="Date must use YYYY-MM-DD")
    try:
        zone = ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=422, detail="Unknown timezone") from exc

    local_start = datetime.combine(day, time.min, tzinfo=zone)
    local_end = local_start + timedelta(days=1)
    return (
        local_start.astimezone(timezone.utc).isoformat(),
        local_end.astimezone(timezone.utc).isoformat(),
    )


def _calc_duration_minutes(started_at: str, ended_at: str | None) -> float | None:
    """Return the nap duration in minutes, or None if still active."""
    if ended_at is None:
        return None
    start = datetime.fromisoformat(started_at)
    end = datetime.fromisoformat(ended_at)
    delta = (end - start).total_seconds() / 60.0
    return round(delta, 2)


def _parse_timestamp(value: str) -> datetime:
    """Parse an API timestamp for ordering checks, treating a missing zone as UTC."""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="Invalid date or time") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _row_to_response(row: dict) -> NapResponse:
    """Convert a database row dict to a NapResponse with calculated duration."""
    duration = _calc_duration_minutes(row["started_at"], row.get("ended_at"))
    return NapResponse(**row, duration_minutes=duration)


async def _save_history(
    db,
    record_id: str,
    previous: dict,
    changed_by: str | None,
    *,
    family_id: str,
) -> None:
    """Insert a snapshot of the previous values into record_history."""
    await db.execute(
        """
        INSERT INTO record_history (
            id, table_name, record_id, previous_values, changed_by, changed_at, family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            "naps",
            record_id,
            json.dumps(previous),
            changed_by,
            datetime.now(timezone.utc).isoformat(),
            family_id,
        ),
    )


@router.get("/", response_model=list[NapResponse])
async def list_naps(
    child_id: str | None = None,
    date: str | None = None,
    sleep_type: str | None = None,
    timezone_name: str = Query(
        DEFAULT_FAMILY_TIMEZONE,
        alias="timezone",
        min_length=1,
        max_length=100,
    ),
    offset: int = 0,
    limit: int = 50,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List naps with optional filters. Excludes soft-deleted records."""
    query = "SELECT * FROM naps WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]

    if child_id is not None:
        query += " AND child_id = ?"
        params.append(child_id)

    if sleep_type is not None:
        query += " AND sleep_type = ?"
        params.append(sleep_type)

    if date is not None:
        # A sleep belongs to a local day when any part of it overlaps that day.
        # This includes a bedtime begun the previous evening and ended after
        # midnight, while retaining a half-open boundary at the next midnight.
        day_start, day_end = _local_day_utc_bounds(date, timezone_name)
        query += (
            " AND julianday(started_at) < julianday(?)"
            " AND (ended_at IS NULL OR julianday(ended_at) > julianday(?))"
        )
        params.extend([day_end, day_start])

    query += " ORDER BY started_at DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_row_to_response(dict(row)) for row in rows]


@router.get("/active", response_model=list[NapResponse])
async def active_naps(
    sleep_type: str | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List naps that are currently active (no ended_at, not deleted)."""
    query = "SELECT * FROM naps WHERE ended_at IS NULL AND deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]

    if sleep_type is not None:
        query += " AND sleep_type = ?"
        params.append(sleep_type)

    query += " ORDER BY started_at DESC"
    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_row_to_response(dict(row)) for row in rows]


@router.post("/start", response_model=NapResponse, status_code=status.HTTP_201_CREATED)
async def start_nap(
    body: NapStartRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Start a new nap. If started_at is not provided, defaults to current UTC time."""
    if not await family_child_exists(db, current_user["family_id"], body.child_id):
        raise HTTPException(status_code=400, detail="Child is not in this family")
    now = datetime.now(timezone.utc).isoformat()
    started_at = body.started_at or now
    nap_id = body.id or str(uuid.uuid4())

    cursor = await db.execute("SELECT * FROM naps WHERE id = ?", (nap_id,))
    existing = await cursor.fetchone()
    if existing is not None:
        row = dict(existing)
        exact_replay = (
            row["family_id"] == current_user["family_id"]
            and row["child_id"] == body.child_id
            and row["started_at"] == started_at
            and row["location"] == body.location
            and row["notes"] == body.notes
            and row["sleep_type"] == body.sleep_type
            and row["deleted_at"] is None
        )
        if not exact_replay:
            raise HTTPException(status_code=409, detail="Nap operation ID was already used")
        return _row_to_response(row)

    await db.execute(
        """
        INSERT INTO naps (
            id, child_id, started_at, location, notes, sleep_type,
            created_at, updated_at, created_by, client_id, client_timestamp, family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            nap_id,
            body.child_id,
            started_at,
            body.location,
            body.notes,
            body.sleep_type,
            now,
            now,
            current_user["id"],
            body.client_id or body.id,
            body.client_timestamp,
            current_user["family_id"],
        ),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM naps WHERE id = ?", (nap_id,))
    row = await cursor.fetchone()
    return _row_to_response(dict(row))


@router.patch("/{nap_id}/end", response_model=NapResponse)
async def end_nap(
    nap_id: str,
    body: NapEndRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """End an active nap. Sets ended_at. Saves history before modifying."""
    cursor = await db.execute(
        "SELECT * FROM naps WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (nap_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Nap not found")

    # Save history before modifying
    await _save_history(
        db,
        nap_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    ended_at = body.ended_at or now
    if _parse_timestamp(ended_at) < _parse_timestamp(existing["started_at"]):
        raise HTTPException(status_code=400, detail="End time cannot be before start time")

    await db.execute(
        "UPDATE naps SET ended_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (ended_at, now, nap_id, current_user["family_id"]),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM naps WHERE id = ?", (nap_id,))
    row = await cursor.fetchone()
    return _row_to_response(dict(row))


@router.patch("/{nap_id}", response_model=NapResponse)
async def update_nap(
    nap_id: str,
    body: NapUpdateRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update a nap (e.g. edit start time). Recalculates duration if nap has ended."""
    cursor = await db.execute(
        "SELECT * FROM naps WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (nap_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Nap not found")

    # Save history before modifying
    await _save_history(
        db,
        nap_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    updates: dict[str, str | None] = {"updated_at": now}

    if body.started_at is not None:
        updates["started_at"] = body.started_at
    if body.clear_ended_at:
        updates["ended_at"] = None
    elif body.ended_at is not None:
        updates["ended_at"] = body.ended_at
    if body.clear_location:
        updates["location"] = None
    elif body.location is not None:
        updates["location"] = body.location.strip() or None
    if body.clear_notes:
        updates["notes"] = None
    elif body.notes is not None:
        updates["notes"] = body.notes.strip() or None

    effective_start = updates.get("started_at", existing["started_at"])
    effective_end = updates.get("ended_at", existing["ended_at"])
    if effective_end is not None and _parse_timestamp(effective_end) < _parse_timestamp(effective_start):
        raise HTTPException(status_code=400, detail="End time cannot be before start time")

    set_clause = ", ".join(f"{col} = ?" for col in updates)
    values = list(updates.values()) + [nap_id, current_user["family_id"]]
    await db.execute(f"UPDATE naps SET {set_clause} WHERE id = ? AND family_id = ?", values)
    await db.commit()

    cursor = await db.execute("SELECT * FROM naps WHERE id = ?", (nap_id,))
    row = await cursor.fetchone()
    return _row_to_response(dict(row))


@router.post("/{nap_id}/restore", response_model=NapResponse)
async def restore_nap(
    nap_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Restore a recently archived sleep record."""
    cursor = await db.execute(
        "SELECT * FROM naps WHERE id = ? AND deleted_at IS NOT NULL AND family_id = ?",
        (nap_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Sleep record not found")

    await _save_history(
        db,
        nap_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE naps SET deleted_at = NULL, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, nap_id, current_user["family_id"]),
    )
    await db.commit()
    cursor = await db.execute("SELECT * FROM naps WHERE id = ?", (nap_id,))
    return _row_to_response(dict(await cursor.fetchone()))


@router.delete("/{nap_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_nap(
    nap_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a nap by setting deleted_at. Saves history before modifying."""
    cursor = await db.execute(
        "SELECT * FROM naps WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (nap_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Nap not found")

    # Save history before modifying
    await _save_history(
        db,
        nap_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE naps SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, nap_id, current_user["family_id"]),
    )
    await db.commit()
