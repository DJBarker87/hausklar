"""Term-aware planner handoffs: shared information, never check-off work."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import HTTPException

from app.models.routine import (
    HandoffOccurrenceResponse,
    HandoffOccurrenceUpdate,
    HandoffScheduleItemResponse,
    HandoffScheduleResponse,
    HandoffScheduleUpdate,
)
from app.services.family_people import family_person_type
from app.services.conflicts import higher_priority_recent_edit
from app.services.record_history import save_history
from app.services.term_status import is_person_in_term


MAX_RANGE_DAYS = 400


def _schedule_response(rows) -> HandoffScheduleResponse:
    items: list[HandoffScheduleItemResponse] = []
    for row in rows:
        values = dict(row)
        if values["kind"] == "pickup":
            # Keep older iOS builds decodable while the stored pickup has no
            # adult owner. Those builds already use this value as a lane ID.
            values["owner_user_id"] = values["term_person_id"]
        items.append(HandoffScheduleItemResponse(**values))
    return HandoffScheduleResponse(items=items)


async def list_schedule(db, *, family_id: str) -> HandoffScheduleResponse:
    rows = await (
        await db.execute(
            "SELECT * FROM term_time_handoffs WHERE family_id = ? "
            "AND deleted_at IS NULL ORDER BY weekday, kind, term_person_id",
            (family_id,),
        )
    ).fetchall()
    return _schedule_response(rows)


async def _require_adult(db, *, family_id: str, user_id: str) -> None:
    row = await (
        await db.execute(
            "SELECT 1 FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (user_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=422, detail="Handoff person must be an adult in this family")


def _stored_owner_user_id(item) -> str | None:
    """Only work departures carry adult ownership in storage."""
    return item.term_person_id if item.kind.value == "work_departure" else None


async def replace_schedule(
    db,
    *,
    current_user: dict,
    body: HandoffScheduleUpdate,
) -> HandoffScheduleResponse:
    family_id = current_user["family_id"]
    for item in body.items:
        person_type = await family_person_type(db, family_id, item.term_person_id)
        if not person_type:
            raise HTTPException(status_code=422, detail="Term calendar is not in this family")
        if item.kind.value == "pickup":
            if person_type != "child":
                raise HTTPException(status_code=422, detail="Pickup must follow a child's term")
            continue
        if person_type != "user" or (
            item.owner_user_id is not None
            and item.term_person_id != item.owner_user_id
        ):
            raise HTTPException(
                status_code=422,
                detail="Leaving work must follow that adult's own term",
            )
        await _require_adult(db, family_id=family_id, user_id=item.term_person_id)

    now = datetime.now(timezone.utc).isoformat()
    incoming_timestamp = body.client_timestamp or now
    await db.execute("BEGIN IMMEDIATE")
    try:
        existing_rows = await (
            await db.execute(
                "SELECT * FROM term_time_handoffs WHERE family_id = ? AND deleted_at IS NULL",
                (family_id,),
            )
        ).fetchall()
        existing = {
            (row["kind"], row["weekday"], row["term_person_id"]): row
            for row in existing_rows
        }
        requested = {
            (item.kind.value, item.weekday, item.term_person_id): item
            for item in body.items
        }

        for identity, row in existing.items():
            if identity in requested:
                continue
            if await higher_priority_recent_edit(
                db,
                existing=row,
                current_user=current_user,
                incoming_timestamp=incoming_timestamp,
            ):
                continue
            await save_history(
                db,
                "term_time_handoffs",
                row["id"],
                current_user["id"],
                family_id=family_id,
            )
            await db.execute(
                "UPDATE term_time_handoffs SET deleted_at = ?, updated_at = ?, "
                "updated_by = ?, client_id = ?, client_timestamp = ? WHERE id = ?",
                (
                    now,
                    now,
                    current_user["id"],
                    body.client_id,
                    incoming_timestamp,
                    row["id"],
                ),
            )

        for identity, item in requested.items():
            row = existing.get(identity)
            stored_owner_user_id = _stored_owner_user_id(item)
            if row is None:
                await db.execute(
                    """
                    INSERT INTO term_time_handoffs
                        (id, kind, weekday, time_of_day, term_person_id,
                         owner_user_id, family_id, created_at, updated_at,
                         created_by, updated_by, client_id, client_timestamp)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        item.kind.value,
                        item.weekday,
                        item.time_of_day,
                        item.term_person_id,
                        stored_owner_user_id,
                        family_id,
                        now,
                        now,
                        current_user["id"],
                        current_user["id"],
                        body.client_id,
                        incoming_timestamp,
                    ),
                )
                continue
            unchanged = (
                row["time_of_day"] == item.time_of_day
                and row["term_person_id"] == item.term_person_id
                and row["owner_user_id"] == stored_owner_user_id
            )
            if unchanged or await higher_priority_recent_edit(
                db,
                existing=row,
                current_user=current_user,
                incoming_timestamp=incoming_timestamp,
            ):
                continue
            await save_history(
                db,
                "term_time_handoffs",
                row["id"],
                current_user["id"],
                family_id=family_id,
            )
            await db.execute(
                """
                UPDATE term_time_handoffs
                SET time_of_day = ?, term_person_id = ?, owner_user_id = ?,
                    updated_at = ?, updated_by = ?, client_id = ?, client_timestamp = ?
                WHERE id = ? AND family_id = ?
                """,
                (
                    item.time_of_day,
                    item.term_person_id,
                    stored_owner_user_id,
                    now,
                    current_user["id"],
                    body.client_id,
                    incoming_timestamp,
                    row["id"],
                    family_id,
                ),
            )
        await db.commit()
    except BaseException:
        await db.rollback()
        raise
    return await list_schedule(db, family_id=family_id)


async def occurrences(
    db,
    *,
    family_id: str,
    start: date,
    end: date,
) -> list[HandoffOccurrenceResponse]:
    if end < start:
        raise HTTPException(status_code=400, detail="Handoff end must not be before start")
    if (end - start).days > MAX_RANGE_DAYS:
        raise HTTPException(status_code=400, detail="Handoff range cannot exceed 400 days")
    handoffs = await (
        await db.execute(
            "SELECT * FROM term_time_handoffs WHERE family_id = ? "
            "AND deleted_at IS NULL ORDER BY weekday, time_of_day, kind",
            (family_id,),
        )
    ).fetchall()
    overrides = await (
        await db.execute(
            "SELECT * FROM term_time_handoff_overrides WHERE family_id = ? "
            "AND occurrence_date >= ? AND occurrence_date <= ? AND deleted_at IS NULL",
            (family_id, start.isoformat(), end.isoformat()),
        )
    ).fetchall()
    override_map = {
        (row["handoff_id"], row["occurrence_date"]): row for row in overrides
    }
    owner_names: dict[str, str] = {}
    term_person_names: dict[str, str] = {}
    term_cache: dict[tuple[str, date], bool] = {}
    result: list[HandoffOccurrenceResponse] = []
    current = start
    while current <= end:
        current_text = current.isoformat()
        for handoff in handoffs:
            if handoff["weekday"] != current.weekday():
                continue
            term_key = (handoff["term_person_id"], current)
            if term_key not in term_cache:
                term_cache[term_key] = await is_person_in_term(
                    db,
                    family_id,
                    handoff["term_person_id"],
                    current,
                )
            if not term_cache[term_key]:
                continue
            override = override_map.get((handoff["id"], current_text))
            if override is not None and bool(override["is_cancelled"]):
                continue
            term_person_id = handoff["term_person_id"]
            if term_person_id not in term_person_names:
                person = await (
                    await db.execute(
                        "SELECT name FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL "
                        "UNION ALL SELECT name FROM children WHERE id = ? AND family_id = ? "
                        "AND deleted_at IS NULL",
                        (term_person_id, family_id, term_person_id, family_id),
                    )
                ).fetchone()
                if person is None:
                    continue
                term_person_names[term_person_id] = person["name"]
            kind = handoff["kind"]
            if kind == "pickup":
                # Compatibility fields point to the child so old clients keep
                # decoding and draw the correct lane. No pickup adult is stored.
                owner_id = term_person_id
                owner_name = term_person_names[term_person_id]
                label = f"{owner_name} pickup"
            else:
                owner_id = (
                    override["owner_user_id"]
                    if override and override["owner_user_id"]
                    else handoff["owner_user_id"]
                )
                if not owner_id:
                    continue
                if owner_id not in owner_names:
                    owner = await (
                        await db.execute(
                            "SELECT name FROM users WHERE id = ? AND family_id = ? "
                            "AND deleted_at IS NULL",
                            (owner_id, family_id),
                        )
                    ).fetchone()
                    if owner is None:
                        continue
                    owner_names[owner_id] = owner["name"]
                owner_name = owner_names[owner_id]
                label = f"{owner_name} leaves work"
            result.append(
                HandoffOccurrenceResponse(
                    id=(override["id"] if override else f"{handoff['id']}:{current_text}"),
                    handoff_id=handoff["id"],
                    kind=kind,
                    date=current_text,
                    time_of_day=(override["time_of_day"] if override else handoff["time_of_day"]),
                    term_person_id=handoff["term_person_id"],
                    term_person_name=term_person_names[term_person_id],
                    owner_user_id=owner_id,
                    owner_name=owner_name,
                    label=label,
                    is_override=override is not None,
                )
            )
        current += timedelta(days=1)
    result.sort(key=lambda item: (item.date, item.time_of_day, item.kind.value))
    return result


async def set_occurrence_override(
    db,
    *,
    current_user: dict,
    handoff_id: str,
    occurrence_date: date,
    body: HandoffOccurrenceUpdate,
) -> HandoffOccurrenceResponse | None:
    family_id = current_user["family_id"]
    handoff = await (
        await db.execute(
            "SELECT * FROM term_time_handoffs WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (handoff_id, family_id),
        )
    ).fetchone()
    if handoff is None:
        raise HTTPException(status_code=404, detail="Handoff not found")
    if occurrence_date.weekday() != handoff["weekday"]:
        raise HTTPException(status_code=422, detail="That handoff does not occur on this date")
    stored_owner_user_id: str | None = None
    if handoff["kind"] == "work_departure":
        if body.owner_user_id not in (None, handoff["term_person_id"]):
            raise HTTPException(
                status_code=422,
                detail="A work departure stays with that adult",
            )
        stored_owner_user_id = handoff["term_person_id"]
        await _require_adult(
            db,
            family_id=family_id,
            user_id=stored_owner_user_id,
        )
    elif body.owner_user_id is not None:
        # Accepted only for backwards compatibility. Pickup responsibility is
        # intentionally never persisted.
        stored_owner_user_id = None
    if handoff["kind"] == "work_departure" and not stored_owner_user_id:
        raise HTTPException(
            status_code=422,
            detail="A work departure stays with that adult",
        )
    now = datetime.now(timezone.utc).isoformat()
    incoming_timestamp = body.client_timestamp or now
    await db.execute("BEGIN IMMEDIATE")
    try:
        existing = await (
            await db.execute(
                "SELECT * FROM term_time_handoff_overrides WHERE family_id = ? "
                "AND handoff_id = ? AND occurrence_date = ? AND deleted_at IS NULL",
                (family_id, handoff_id, occurrence_date.isoformat()),
            )
        ).fetchone()
        if existing is None:
            await db.execute(
                """
                INSERT INTO term_time_handoff_overrides
                    (id, handoff_id, occurrence_date, time_of_day, owner_user_id,
                     is_cancelled, family_id, created_at, updated_at, created_by,
                     updated_by, client_id, client_timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    handoff_id,
                    occurrence_date.isoformat(),
                    body.time_of_day,
                    stored_owner_user_id,
                    int(body.is_cancelled),
                    family_id,
                    now,
                    now,
                    current_user["id"],
                    current_user["id"],
                    body.client_id,
                    incoming_timestamp,
                ),
            )
        elif not await higher_priority_recent_edit(
            db,
            existing=existing,
            current_user=current_user,
            incoming_timestamp=incoming_timestamp,
        ):
            await save_history(
                db,
                "term_time_handoff_overrides",
                existing["id"],
                current_user["id"],
                family_id=family_id,
            )
            await db.execute(
                """
                UPDATE term_time_handoff_overrides
                SET time_of_day = ?, owner_user_id = ?, is_cancelled = ?,
                    updated_at = ?, updated_by = ?, client_id = ?, client_timestamp = ?
                WHERE id = ? AND family_id = ?
                """,
                (
                    body.time_of_day,
                    stored_owner_user_id,
                    int(body.is_cancelled),
                    now,
                    current_user["id"],
                    body.client_id,
                    incoming_timestamp,
                    existing["id"],
                    family_id,
                ),
            )
        await db.commit()
    except BaseException:
        await db.rollback()
        raise
    projected = await occurrences(
        db,
        family_id=family_id,
        start=occurrence_date,
        end=occurrence_date,
    )
    return next((item for item in projected if item.handoff_id == handoff_id), None)


async def clear_occurrence_override(
    db,
    *,
    current_user: dict,
    handoff_id: str,
    occurrence_date: date,
) -> HandoffOccurrenceResponse | None:
    family_id = current_user["family_id"]
    existing = await (
        await db.execute(
            "SELECT * FROM term_time_handoff_overrides WHERE family_id = ? "
            "AND handoff_id = ? AND occurrence_date = ? AND deleted_at IS NULL",
            (family_id, handoff_id, occurrence_date.isoformat()),
        )
    ).fetchone()
    if existing is None:
        raise HTTPException(status_code=404, detail="Daily change not found")
    now = datetime.now(timezone.utc).isoformat()
    if await higher_priority_recent_edit(
        db,
        existing=existing,
        current_user=current_user,
        incoming_timestamp=now,
    ):
        projected = await occurrences(
            db,
            family_id=family_id,
            start=occurrence_date,
            end=occurrence_date,
        )
        return next((item for item in projected if item.handoff_id == handoff_id), None)
    await save_history(
        db,
        "term_time_handoff_overrides",
        existing["id"],
        current_user["id"],
        family_id=family_id,
    )
    await db.execute(
        "UPDATE term_time_handoff_overrides SET deleted_at = ?, updated_at = ?, "
        "updated_by = ? WHERE id = ? AND family_id = ?",
        (now, now, current_user["id"], existing["id"], family_id),
    )
    await db.commit()
    projected = await occurrences(
        db,
        family_id=family_id,
        start=occurrence_date,
        end=occurrence_date,
    )
    return next((item for item in projected if item.handoff_id == handoff_id), None)
