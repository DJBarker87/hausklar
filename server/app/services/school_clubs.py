"""Term-time school-club rules and their calendar projections."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import HTTPException

from app.models.calendar import CalendarEventResponse
from app.models.managed_projection import ManagedSource
from app.models.school_club import (
    SchoolClubCancellation,
    SchoolClubCancellationResponse,
    SchoolClubCreate,
    SchoolClubResponse,
    SchoolClubUpdate,
)
from app.services.conflicts import higher_priority_recent_edit
from app.services.family_people import family_child_exists
from app.services.record_history import save_history
from app.services.term_status import is_person_in_term


CLUB_ZONE = ZoneInfo("Europe/London")
MAX_RANGE_DAYS = 400
_CLUB_COLOURS = ("#2563EB", "#0F766E", "#7C3AED", "#B45309", "#BE123C")


@dataclass(frozen=True)
class ClubOccurrence:
    club_id: str
    child_id: str
    local_date: date
    title: str
    start_time: str
    end_time: str
    cancelled: bool


def _colour(identifier: str) -> str:
    return _CLUB_COLOURS[uuid.UUID(identifier).int % len(_CLUB_COLOURS)]


def _local_today() -> date:
    return datetime.now(CLUB_ZONE).date()


def _response(row) -> SchoolClubResponse:
    return SchoolClubResponse(**dict(row))


async def _club_row(db, *, family_id: str, club_id: str):
    return await (
        await db.execute(
            "SELECT sc.*, c.name AS child_name FROM school_clubs sc "
            "JOIN children c ON c.id = sc.child_id AND c.family_id = sc.family_id "
            "AND c.deleted_at IS NULL WHERE sc.id = ? AND sc.family_id = ? "
            "AND sc.deleted_at IS NULL",
            (club_id, family_id),
        )
    ).fetchone()


async def list_clubs(db, *, family_id: str) -> list[SchoolClubResponse]:
    rows = await (
        await db.execute(
            "SELECT sc.*, c.name AS child_name FROM school_clubs sc "
            "JOIN children c ON c.id = sc.child_id AND c.family_id = sc.family_id "
            "AND c.deleted_at IS NULL WHERE sc.family_id = ? AND sc.deleted_at IS NULL "
            "ORDER BY c.name COLLATE NOCASE, sc.weekday, sc.start_time, sc.name COLLATE NOCASE",
            (family_id,),
        )
    ).fetchall()
    return [_response(row) for row in rows]


async def create_club(
    db,
    *,
    current_user: dict,
    body: SchoolClubCreate,
) -> SchoolClubResponse:
    family_id = current_user["family_id"]
    if not await family_child_exists(db, family_id, body.child_id):
        raise HTTPException(status_code=422, detail="Club child is not in this family")
    club_id = str(body.id)
    existing = await _club_row(db, family_id=family_id, club_id=club_id)
    if existing is not None:
        return _response(existing)
    now = datetime.now(timezone.utc).isoformat()
    active_from = body.active_from or _local_today().isoformat()
    await db.execute(
        """
        INSERT INTO school_clubs (
            id, name, child_id, weekday, start_time, end_time, active_from,
            active_until, location, color, family_id, created_at, updated_at,
            created_by, updated_by, client_id, client_timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            club_id,
            body.name.strip(),
            body.child_id,
            body.weekday,
            body.start_time,
            body.end_time,
            active_from,
            body.active_until,
            body.location.strip() if body.location and body.location.strip() else None,
            _colour(club_id),
            family_id,
            now,
            now,
            current_user["id"],
            current_user["id"],
            body.client_id,
            body.client_timestamp or now,
        ),
    )
    await db.commit()
    row = await _club_row(db, family_id=family_id, club_id=club_id)
    assert row is not None
    return _response(row)


async def update_club(
    db,
    *,
    current_user: dict,
    club_id: str,
    body: SchoolClubUpdate,
) -> SchoolClubResponse:
    family_id = current_user["family_id"]
    existing = await _club_row(db, family_id=family_id, club_id=club_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Club not found")
    values = body.model_dump(exclude_unset=True)
    incoming_timestamp = values.pop("client_timestamp", None)
    client_id = values.pop("client_id", None)
    child_id = values.get("child_id", existing["child_id"])
    if not await family_child_exists(db, family_id, child_id):
        raise HTTPException(status_code=422, detail="Club child is not in this family")
    start_time = values.get("start_time", existing["start_time"])
    end_time = values.get("end_time", existing["end_time"])
    if end_time <= start_time:
        raise HTTPException(status_code=422, detail="Club end time must be later than its start time")
    active_from = values.get("active_from", existing["active_from"])
    active_until = values.get("active_until", existing["active_until"])
    if active_until is not None and active_until < active_from:
        raise HTTPException(status_code=422, detail="Club end date must not be before its start date")
    now = datetime.now(timezone.utc).isoformat()
    incoming_timestamp = incoming_timestamp or now
    if await higher_priority_recent_edit(
        db,
        existing=existing,
        current_user=current_user,
        incoming_timestamp=incoming_timestamp,
    ):
        return _response(existing)
    if "name" in values:
        values["name"] = values["name"].strip()
    if "location" in values:
        location = values["location"]
        values["location"] = location.strip() or None if location else None
    if values:
        await save_history(
            db,
            "school_clubs",
            club_id,
            current_user["id"],
            family_id=family_id,
        )
        values.update(
            updated_at=now,
            updated_by=current_user["id"],
            client_id=client_id,
            client_timestamp=incoming_timestamp,
        )
        clause = ", ".join(f"{field} = ?" for field in values)
        await db.execute(
            f"UPDATE school_clubs SET {clause} WHERE id = ? AND family_id = ?",
            (*values.values(), club_id, family_id),
        )
        await db.commit()
    row = await _club_row(db, family_id=family_id, club_id=club_id)
    assert row is not None
    return _response(row)


async def delete_club(db, *, current_user: dict, club_id: str) -> None:
    family_id = current_user["family_id"]
    existing = await _club_row(db, family_id=family_id, club_id=club_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Club not found")
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db,
        "school_clubs",
        club_id,
        current_user["id"],
        family_id=family_id,
    )
    await db.execute(
        "UPDATE school_clubs SET deleted_at = ?, updated_at = ?, updated_by = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, current_user["id"], club_id, family_id),
    )
    await db.commit()


async def occurrence_records(
    db,
    *,
    family_id: str,
    start: date,
    end: date,
) -> list[ClubOccurrence]:
    if end < start or (end - start).days > MAX_RANGE_DAYS:
        raise ValueError("Club date range must cover between 1 and 400 days")
    clubs = await (
        await db.execute(
            "SELECT * FROM school_clubs WHERE family_id = ? AND deleted_at IS NULL "
            "AND active_from <= ? AND (active_until IS NULL OR active_until >= ?) "
            "ORDER BY weekday, start_time, id",
            (family_id, end.isoformat(), start.isoformat()),
        )
    ).fetchall()
    exceptions = await (
        await db.execute(
            "SELECT club_id, occurrence_date FROM school_club_exceptions "
            "WHERE family_id = ? AND occurrence_date >= ? AND occurrence_date <= ? "
            "AND deleted_at IS NULL",
            (family_id, start.isoformat(), end.isoformat()),
        )
    ).fetchall()
    cancelled = {(row["club_id"], row["occurrence_date"]) for row in exceptions}
    term_cache: dict[tuple[str, date], bool] = {}
    result: list[ClubOccurrence] = []
    current = start
    while current <= end:
        current_text = current.isoformat()
        for club in clubs:
            if club["weekday"] != current.weekday():
                continue
            if current_text < club["active_from"] or (
                club["active_until"] is not None and current_text > club["active_until"]
            ):
                continue
            term_key = (club["child_id"], current)
            if term_key not in term_cache:
                term_cache[term_key] = await is_person_in_term(
                    db, family_id, club["child_id"], current
                )
            if not term_cache[term_key]:
                continue
            result.append(
                ClubOccurrence(
                    club_id=club["id"],
                    child_id=club["child_id"],
                    local_date=current,
                    title=club["name"],
                    start_time=club["start_time"],
                    end_time=club["end_time"],
                    cancelled=(club["id"], current_text) in cancelled,
                )
            )
        current += timedelta(days=1)
    return result


async def cancel_occurrence(
    db,
    *,
    current_user: dict,
    club_id: str,
    occurrence_date: date,
    body: SchoolClubCancellation,
) -> SchoolClubCancellationResponse:
    family_id = current_user["family_id"]
    club = await _club_row(db, family_id=family_id, club_id=club_id)
    if club is None:
        raise HTTPException(status_code=404, detail="Club not found")
    candidates = await occurrence_records(
        db, family_id=family_id, start=occurrence_date, end=occurrence_date
    )
    if not any(item.club_id == club_id for item in candidates):
        raise HTTPException(status_code=422, detail="That club does not run on this date")
    now = datetime.now(timezone.utc).isoformat()
    incoming_timestamp = body.client_timestamp or now
    existing = await (
        await db.execute(
            "SELECT * FROM school_club_exceptions WHERE family_id = ? AND club_id = ? "
            "AND occurrence_date = ? AND deleted_at IS NULL",
            (family_id, club_id, occurrence_date.isoformat()),
        )
    ).fetchone()
    if existing is None:
        await db.execute(
            """
            INSERT INTO school_club_exceptions (
                id, club_id, occurrence_date, status, family_id, created_at,
                updated_at, created_by, updated_by, client_id, client_timestamp
            ) VALUES (?, ?, ?, 'cancelled', ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                club_id,
                occurrence_date.isoformat(),
                family_id,
                now,
                now,
                current_user["id"],
                current_user["id"],
                body.client_id,
                incoming_timestamp,
            ),
        )
        await db.commit()
    return SchoolClubCancellationResponse(
        club_id=club_id,
        occurrence_date=occurrence_date.isoformat(),
        cancelled=True,
    )


async def restore_occurrence(
    db,
    *,
    current_user: dict,
    club_id: str,
    occurrence_date: date,
) -> SchoolClubCancellationResponse:
    family_id = current_user["family_id"]
    existing = await (
        await db.execute(
            "SELECT * FROM school_club_exceptions WHERE family_id = ? AND club_id = ? "
            "AND occurrence_date = ? AND deleted_at IS NULL",
            (family_id, club_id, occurrence_date.isoformat()),
        )
    ).fetchone()
    if existing is None:
        raise HTTPException(status_code=404, detail="Club cancellation not found")
    now = datetime.now(timezone.utc).isoformat()
    if not await higher_priority_recent_edit(
        db,
        existing=existing,
        current_user=current_user,
        incoming_timestamp=now,
    ):
        await save_history(
            db,
            "school_club_exceptions",
            existing["id"],
            current_user["id"],
            family_id=family_id,
        )
        await db.execute(
            "UPDATE school_club_exceptions SET deleted_at = ?, updated_at = ?, "
            "updated_by = ? WHERE id = ? AND family_id = ?",
            (now, now, current_user["id"], existing["id"], family_id),
        )
        await db.commit()
    remaining = await (
        await db.execute(
            "SELECT 1 FROM school_club_exceptions WHERE id = ? AND deleted_at IS NULL",
            (existing["id"],),
        )
    ).fetchone()
    return SchoolClubCancellationResponse(
        club_id=club_id,
        occurrence_date=occurrence_date.isoformat(),
        cancelled=remaining is not None,
    )


def _calendar_bounds(range_start: datetime, range_end: datetime) -> tuple[date, date]:
    start = range_start.astimezone(CLUB_ZONE).date()
    end = (range_end - timedelta(microseconds=1)).astimezone(CLUB_ZONE).date()
    return start, end


def _local_datetime(day: date, value: str) -> datetime:
    return datetime.combine(day, time.fromisoformat(value), tzinfo=CLUB_ZONE)


async def calendar_projections(
    db,
    *,
    family_id: str,
    range_start: datetime,
    range_end: datetime,
) -> list[CalendarEventResponse]:
    start, end = _calendar_bounds(range_start, range_end)
    occurrences = await occurrence_records(
        db, family_id=family_id, start=start, end=end
    )
    club_ids = {item.club_id for item in occurrences}
    if not club_ids:
        return []
    placeholders = ",".join("?" for _ in club_ids)
    rows = await (
        await db.execute(
            "SELECT * FROM school_clubs WHERE family_id = ? AND id IN ("
            + placeholders
            + ")",
            (family_id, *club_ids),
        )
    ).fetchall()
    clubs = {row["id"]: row for row in rows}
    result: list[CalendarEventResponse] = []
    for item in occurrences:
        club = clubs[item.club_id]
        title = f"{item.title} cancelled" if item.cancelled else item.title
        result.append(
            CalendarEventResponse(
                id=f"school-club:{item.club_id}:{item.local_date.isoformat()}",
                title=title,
                description=None,
                start_time=_local_datetime(item.local_date, item.start_time).isoformat(),
                end_time=_local_datetime(item.local_date, item.end_time).isoformat(),
                all_day=False,
                location=club["location"],
                family_member_ids=[item.child_id],
                event_type=("school_club_cancelled" if item.cancelled else "school_club"),
                series_id=item.club_id,
                is_generated_occurrence=True,
                source_name="Clubs",
                source_color=club["color"],
                read_only=True,
                created_at=club["created_at"],
                updated_at=club["updated_at"],
                created_by=club["created_by"],
                managed_source=ManagedSource(
                    kind="school_club",
                    source_id=item.club_id,
                    deep_link=f"/calendar?club={item.club_id}",
                    label="Clubs",
                ),
            )
        )
    return result
