import asyncio
import json
import uuid
from datetime import date as date_type, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status

from app.auth import get_current_user
from app.database import get_db
from app.models.routine import (
    ActiveRoutineResponse,
    HandoffOccurrenceResponse,
    HandoffOccurrenceUpdate,
    HandoffScheduleResponse,
    HandoffScheduleUpdate,
    HolidayDateCreate,
    HolidayDateResponse,
    RoutineItemCreate,
    RoutineItemDuplicate,
    RoutineItemResponse,
    RoutineItemUpdate,
    TermDateCreate,
    TermDateResponse,
    TermDateUpdate,
    TermOverrideResponse,
    TermOverrideSet,
    TermStatusEntry,
    TermStatusResponse,
)
from app.services.record_history import save_history
from app.services.family_people import family_person_type
from app.services.term_calendar import (
    reconcile_term_boundary_events,
    suppress_overlapping_scraped_terms,
)
from app.services.term_status import get_people_with_routine_or_terms, is_person_in_term
from app.services import handoffs
from app.middleware.rate_limit import RateLimiter, extract_client_ip
from app.services.host_integrations import require_host_integration_admin

router = APIRouter()
MAX_ACTIVE_RANGE_DAYS = 400
MAX_ACTIVE_ROUTINE_ITEMS = 500
MAX_ACTIVE_ROUTINE_RESULTS = 5_000
scraper_limiter = RateLimiter(max_attempts=2, window_seconds=3_600)
scraper_lock = asyncio.Lock()


def _require_admin(current_user: dict) -> None:
    require_host_integration_admin(current_user)


def _reserve_scraper_request(request: Request, current_user: dict, name: str) -> None:
    _require_admin(current_user)
    key = f"scraper:{name}:{current_user['id']}:{extract_client_ip(request)}"
    scraper_limiter.ensure_allowed(
        key,  # gitleaks:allow
        detail_prefix="Too many schedule refresh requests",
    )
    scraper_limiter.record_failure(key)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _item_row_to_response(row: dict) -> RoutineItemResponse:
    data = dict(row)
    raw = data.get("days_of_week")
    if raw and isinstance(raw, str):
        data["days_of_week"] = json.loads(raw)
    elif not raw:
        data["days_of_week"] = []
    return RoutineItemResponse(**data)


def _term_row_to_response(row: dict) -> TermDateResponse:
    data = dict(row)
    data["is_imported"] = data.get("created_by") == "term-scraper"
    data["is_overridden"] = bool(data.get("user_overridden", 0))
    return TermDateResponse(**data)


async def _person_name(db, family_id: str, person_id: str) -> str:
    """Look up name from users or children table."""
    cursor = await db.execute(
        "SELECT name FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (person_id, family_id),
    )
    row = await cursor.fetchone()
    if row:
        return row["name"]
    cursor = await db.execute(
        "SELECT name FROM children WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (person_id, family_id),
    )
    row = await cursor.fetchone()
    if row:
        return row["name"]
    return "Unknown"


async def _prep_template_exists(db, family_id: str, template_id: str | None) -> bool:
    if template_id is None:
        return True
    row = await (
        await db.execute(
            "SELECT 1 FROM event_prep_templates WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL AND enabled = 1",
            (template_id, family_id),
        )
    ).fetchone()
    return row is not None


# ---------------------------------------------------------------------------
# Routine Items CRUD
# ---------------------------------------------------------------------------


@router.get("/items", response_model=list[RoutineItemResponse])
async def list_items(
    person_id: str | None = Query(None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = "SELECT * FROM routine_items WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]
    if person_id:
        query += " AND person_id = ?"
        params.append(person_id)
    query += " ORDER BY sort_order ASC, name ASC"
    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_item_row_to_response(row) for row in rows]


@router.post("/items", response_model=RoutineItemResponse, status_code=status.HTTP_201_CREATED)
async def create_item(
    body: RoutineItemCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if not await family_person_type(db, current_user["family_id"], body.person_id):
        raise HTTPException(status_code=400, detail="Routine person is not in this family")
    if not await _prep_template_exists(
        db, current_user["family_id"], body.prep_template_id
    ):
        raise HTTPException(status_code=400, detail="Packing list is not available")
    item_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO routine_items
            (id, person_id, name, color, days_of_week, sort_order,
             time_of_day, location, preparation_note, prep_template_id,
             reminder_minutes, calendar_projection, term_only, family_id,
             created_at, updated_at, created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            item_id,
            body.person_id,
            body.name,
            body.color,
            json.dumps(body.days_of_week),
            body.sort_order,
            body.time_of_day,
            body.location,
            body.preparation_note,
            body.prep_template_id,
            body.reminder_minutes,
            int(body.calendar_projection),
            int(body.term_only),
            current_user["family_id"],
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )
    await db.commit()
    cursor = await db.execute("SELECT * FROM routine_items WHERE id = ?", (item_id,))
    row = await cursor.fetchone()
    return _item_row_to_response(row)


@router.put("/items/{item_id}", response_model=RoutineItemResponse)
async def update_item(
    item_id: str,
    body: RoutineItemUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM routine_items WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (item_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Routine item not found")

    await save_history(
        db,
        "routine_items",
        item_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    updates: dict = {}
    update_data = body.model_dump(exclude_unset=True)
    if "prep_template_id" in update_data and not await _prep_template_exists(
        db, current_user["family_id"], update_data["prep_template_id"]
    ):
        raise HTTPException(status_code=400, detail="Packing list is not available")
    for field, value in update_data.items():
        if field == "days_of_week" and value is not None:
            updates[field] = json.dumps(value)
        elif field in {"calendar_projection", "term_only"} and value is not None:
            updates[field] = int(value)
        else:
            updates[field] = value

    if not updates:
        return _item_row_to_response(existing)

    now = datetime.now(timezone.utc).isoformat()
    updates["updated_at"] = now
    set_clause = ", ".join(f"{col} = ?" for col in updates)
    values = list(updates.values()) + [item_id, current_user["family_id"]]
    await db.execute(
        f"UPDATE routine_items SET {set_clause} WHERE id = ? AND family_id = ?", values
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM routine_items WHERE id = ?", (item_id,))
    row = await cursor.fetchone()
    return _item_row_to_response(row)


@router.delete("/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_item(
    item_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM routine_items WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (item_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Routine item not found")
    await save_history(
        db,
        "routine_items",
        item_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE routine_items SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, item_id, current_user["family_id"]),
    )
    await db.commit()


@router.post(
    "/items/{item_id}/duplicate",
    response_model=RoutineItemResponse,
    status_code=status.HTTP_201_CREATED,
)
async def duplicate_item(
    item_id: str,
    body: RoutineItemDuplicate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    family_id = current_user["family_id"]
    source = await (
        await db.execute(
            "SELECT * FROM routine_items WHERE id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (item_id, family_id),
        )
    ).fetchone()
    if not source:
        raise HTTPException(status_code=404, detail="Routine item not found")
    if body.target_person_id == source["person_id"]:
        raise HTTPException(status_code=400, detail="Choose another family member")
    if not await family_person_type(db, family_id, body.target_person_id):
        raise HTTPException(status_code=400, detail="Routine person is not in this family")

    order_row = await (
        await db.execute(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order FROM routine_items "
            "WHERE family_id = ? AND person_id = ? AND deleted_at IS NULL",
            (family_id, body.target_person_id),
        )
    ).fetchone()
    duplicate_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """INSERT INTO routine_items
           (id, person_id, name, color, days_of_week, sort_order,
            time_of_day, location, preparation_note, prep_template_id,
            reminder_minutes, calendar_projection, term_only, family_id,
            created_at, updated_at, created_by, client_id)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            duplicate_id,
            body.target_person_id,
            source["name"],
            source["color"],
            source["days_of_week"],
            order_row["next_order"],
            source["time_of_day"],
            source["location"],
            source["preparation_note"],
            source["prep_template_id"],
            source["reminder_minutes"],
            source["calendar_projection"],
            source["term_only"],
            family_id,
            now,
            now,
            current_user["id"],
            f"routine-copy:{item_id}:{body.target_person_id}:{duplicate_id}",
        ),
    )
    await db.commit()
    row = await (
        await db.execute("SELECT * FROM routine_items WHERE id = ?", (duplicate_id,))
    ).fetchone()
    return _item_row_to_response(row)


# ---------------------------------------------------------------------------
# Term Dates CRUD
# ---------------------------------------------------------------------------


@router.get("/terms", response_model=list[TermDateResponse])
async def list_terms(
    person_id: str | None = Query(None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = "SELECT * FROM term_dates WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]
    if person_id:
        query += " AND person_id = ?"
        params.append(person_id)
    query += " ORDER BY start_date ASC"
    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_term_row_to_response(row) for row in rows]


@router.post("/terms", response_model=TermDateResponse, status_code=status.HTTP_201_CREATED)
async def create_term(
    body: TermDateCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if not await family_person_type(db, current_user["family_id"], body.person_id):
        raise HTTPException(status_code=400, detail="Term person is not in this family")
    term_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO term_dates
            (id, person_id, label, start_date, end_date, family_id,
             created_at, updated_at, created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            term_id,
            body.person_id,
            body.label,
            body.start_date,
            body.end_date,
            current_user["family_id"],
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )
    await suppress_overlapping_scraped_terms(
        db,
        family_id=current_user["family_id"],
        person_id=body.person_id,
        start_date=body.start_date,
        end_date=body.end_date,
        actor_id=current_user["id"],
        exclude_term_id=term_id,
    )
    await reconcile_term_boundary_events(
        db,
        family_id=current_user["family_id"],
        person_ids=[body.person_id],
        actor_id=current_user["id"],
    )
    await db.commit()
    cursor = await db.execute("SELECT * FROM term_dates WHERE id = ?", (term_id,))
    row = await cursor.fetchone()
    return _term_row_to_response(row)


@router.put("/terms/{term_id}", response_model=TermDateResponse)
async def update_term(
    term_id: str,
    body: TermDateUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM term_dates WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (term_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Term date not found")

    await save_history(
        db,
        "term_dates",
        term_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    updates: dict = {}
    update_data = body.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        updates[field] = value

    if existing["created_by"] == "term-scraper" and any(
        field in update_data for field in ("label", "start_date", "end_date")
    ):
        updates["user_overridden"] = 1

    if not updates:
        if existing["created_by"] != "term-scraper":
            await suppress_overlapping_scraped_terms(
                db,
                family_id=current_user["family_id"],
                person_id=existing["person_id"],
                start_date=existing["start_date"],
                end_date=existing["end_date"],
                actor_id=current_user["id"],
                exclude_term_id=term_id,
            )
        await reconcile_term_boundary_events(
            db,
            family_id=current_user["family_id"],
            person_ids=[existing["person_id"]],
            actor_id=current_user["id"],
        )
        await db.commit()
        return _term_row_to_response(existing)

    candidate_start = updates.get("start_date", existing["start_date"])
    candidate_end = updates.get("end_date", existing["end_date"])
    if candidate_end < candidate_start:
        raise HTTPException(
            status_code=400,
            detail="Term end date must be on or after its start date",
        )

    now = datetime.now(timezone.utc).isoformat()
    updates["updated_at"] = now
    set_clause = ", ".join(f"{col} = ?" for col in updates)
    values = list(updates.values()) + [term_id, current_user["family_id"]]
    await db.execute(f"UPDATE term_dates SET {set_clause} WHERE id = ? AND family_id = ?", values)
    if existing["created_by"] != "term-scraper" or updates.get("user_overridden") == 1:
        await suppress_overlapping_scraped_terms(
            db,
            family_id=current_user["family_id"],
            person_id=existing["person_id"],
            start_date=candidate_start,
            end_date=candidate_end,
            actor_id=current_user["id"],
            exclude_term_id=term_id,
        )
    await reconcile_term_boundary_events(
        db,
        family_id=current_user["family_id"],
        person_ids=[existing["person_id"]],
        actor_id=current_user["id"],
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM term_dates WHERE id = ?", (term_id,))
    row = await cursor.fetchone()
    return _term_row_to_response(row)


@router.delete("/terms/{term_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_term(
    term_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM term_dates WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (term_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Term date not found")
    await save_history(
        db,
        "term_dates",
        term_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE term_dates SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, term_id, current_user["family_id"]),
    )
    await reconcile_term_boundary_events(
        db,
        term_ids=[term_id],
        actor_id=current_user["id"],
    )
    await db.commit()


# ---------------------------------------------------------------------------
# Term Override
# ---------------------------------------------------------------------------


@router.get("/override/{person_id}", response_model=TermOverrideResponse)
async def get_override(
    person_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM routine_term_overrides WHERE person_id = ? AND deleted_at IS NULL "
        "AND family_id = ? AND (expires_on IS NULL OR expires_on >= ?)",
        (person_id, current_user["family_id"], date_type.today().isoformat()),
    )
    row = await cursor.fetchone()
    if row:
        mode = "force_on" if row["is_active"] else "force_off"
    else:
        mode = "auto"
    return TermOverrideResponse(
        person_id=person_id,
        mode=mode,
        expires_on=row["expires_on"] if row else None,
    )


@router.put("/override/{person_id}", response_model=TermOverrideResponse)
async def set_override(
    person_id: str,
    body: TermOverrideSet,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if not await family_person_type(db, current_user["family_id"], person_id):
        raise HTTPException(status_code=404, detail="Family member not found")
    cursor = await db.execute(
        "SELECT * FROM routine_term_overrides WHERE person_id = ? AND deleted_at IS NULL AND family_id = ?",
        (person_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    now = datetime.now(timezone.utc).isoformat()

    if existing:
        await save_history(
            db,
            "routine_term_overrides",
            existing["id"],
            current_user["id"],
            family_id=current_user["family_id"],
        )
        await db.execute(
            "UPDATE routine_term_overrides SET is_active = ?, expires_on = ?, "
            "updated_at = ? WHERE id = ?",
            (int(body.is_active), body.expires_on, now, existing["id"]),
        )
    else:
        override_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO routine_term_overrides
                (id, person_id, is_active, expires_on, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                override_id,
                person_id,
                int(body.is_active),
                body.expires_on,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
            ),
        )
    await db.commit()

    mode = "force_on" if body.is_active else "force_off"
    return TermOverrideResponse(
        person_id=person_id,
        mode=mode,
        expires_on=body.expires_on,
    )


@router.delete("/override/{person_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_override(
    person_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM routine_term_overrides WHERE person_id = ? AND deleted_at IS NULL AND family_id = ?",
        (person_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Override not found")
    await save_history(
        db,
        "routine_term_overrides",
        existing["id"],
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE routine_term_overrides SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, existing["id"], current_user["family_id"]),
    )
    await db.commit()


# ---------------------------------------------------------------------------
# Holiday Dates CRUD
# ---------------------------------------------------------------------------


def _holiday_row_to_response(row: dict) -> HolidayDateResponse:
    return HolidayDateResponse(**dict(row))


@router.get("/holidays", response_model=list[HolidayDateResponse])
async def list_holidays(
    person_id: str | None = Query(None),
    year: int | None = Query(None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = "SELECT * FROM holiday_dates WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]
    if person_id:
        query += " AND person_id = ?"
        params.append(person_id)
    if year:
        query += " AND date >= ? AND date <= ?"
        params.append(f"{year}-01-01")
        params.append(f"{year}-12-31")
    query += " ORDER BY date ASC"
    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_holiday_row_to_response(row) for row in rows]


@router.post("/holidays", response_model=HolidayDateResponse, status_code=status.HTTP_201_CREATED)
async def create_holiday(
    body: HolidayDateCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if not await family_person_type(db, current_user["family_id"], body.person_id):
        raise HTTPException(status_code=400, detail="Holiday person is not in this family")
    holiday_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO holiday_dates
            (id, person_id, date, label, family_id, created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            holiday_id,
            body.person_id,
            body.date,
            body.label,
            current_user["family_id"],
            now,
            now,
            current_user["id"],
        ),
    )
    await db.commit()
    cursor = await db.execute("SELECT * FROM holiday_dates WHERE id = ?", (holiday_id,))
    row = await cursor.fetchone()
    return _holiday_row_to_response(row)


@router.delete("/holidays/{holiday_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_holiday(
    holiday_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM holiday_dates WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (holiday_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Holiday date not found")
    await save_history(
        db,
        "holiday_dates",
        holiday_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE holiday_dates SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, holiday_id, current_user["family_id"]),
    )
    await db.commit()


# ---------------------------------------------------------------------------
# Term Status
# ---------------------------------------------------------------------------


@router.get("/term-status", response_model=TermStatusResponse)
async def get_term_status(
    date: str = Query(..., description="YYYY-MM-DD"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    check_date_obj = date_type.fromisoformat(date)

    person_ids = await get_people_with_routine_or_terms(db, current_user["family_id"])

    statuses: list[TermStatusEntry] = []
    for pid in sorted(person_ids):
        in_term = await is_person_in_term(db, current_user["family_id"], pid, check_date_obj)
        statuses.append(TermStatusEntry(person_id=pid, in_term=in_term))

    all_same = len(set(s.in_term for s in statuses)) <= 1
    return TermStatusResponse(statuses=statuses, all_same=all_same)


# ---------------------------------------------------------------------------
# Term Refresh (scraper trigger)
# ---------------------------------------------------------------------------


@router.post("/swimming/refresh")
async def refresh_swimming(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """Manually trigger swimming lesson scraping from configured swimming provider."""
    _reserve_scraper_request(request, current_user, "swimming")
    if scraper_lock.locked():
        raise HTTPException(status_code=409, detail="A schedule refresh is already running")

    from app.services.swimming_scraper import refresh_swimming_lessons

    async with scraper_lock:
        result = await refresh_swimming_lessons(family_id=current_user["family_id"])
    return result


@router.post("/terms/refresh")
async def refresh_terms(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    _reserve_scraper_request(request, current_user, "terms")
    if scraper_lock.locked():
        raise HTTPException(status_code=409, detail="A schedule refresh is already running")
    from app.services.term_scraper import refresh_all_terms_for_family

    async with scraper_lock:
        result = await refresh_all_terms_for_family(family_id=current_user["family_id"])
    return result


# ---------------------------------------------------------------------------
# Term-time handoffs
# ---------------------------------------------------------------------------


def _handoff_date(value: str) -> date_type:
    try:
        parsed = date_type.fromisoformat(value)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Handoff date is invalid") from exc
    if parsed.isoformat() != value:
        raise HTTPException(status_code=400, detail="Handoff date is invalid")
    return parsed


@router.get("/handoffs/schedule", response_model=HandoffScheduleResponse)
async def get_handoff_schedule(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await handoffs.list_schedule(db, family_id=current_user["family_id"])


@router.put("/handoffs/schedule", response_model=HandoffScheduleResponse)
async def set_handoff_schedule(
    body: HandoffScheduleUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await handoffs.replace_schedule(db, current_user=current_user, body=body)


@router.get("/handoffs", response_model=list[HandoffOccurrenceResponse])
async def get_handoff_occurrences(
    start: str = Query(...),
    end: str = Query(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await handoffs.occurrences(
        db,
        family_id=current_user["family_id"],
        start=_handoff_date(start),
        end=_handoff_date(end),
    )


@router.put(
    "/handoffs/{handoff_id}/dates/{occurrence_date}",
    response_model=HandoffOccurrenceResponse | None,
)
async def set_handoff_occurrence(
    handoff_id: str,
    occurrence_date: str,
    body: HandoffOccurrenceUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await handoffs.set_occurrence_override(
        db,
        current_user=current_user,
        handoff_id=handoff_id,
        occurrence_date=_handoff_date(occurrence_date),
        body=body,
    )


@router.delete(
    "/handoffs/{handoff_id}/dates/{occurrence_date}",
    response_model=HandoffOccurrenceResponse | None,
)
async def clear_handoff_occurrence(
    handoff_id: str,
    occurrence_date: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await handoffs.clear_occurrence_override(
        db,
        current_user=current_user,
        handoff_id=handoff_id,
        occurrence_date=_handoff_date(occurrence_date),
    )


# ---------------------------------------------------------------------------
# Active Routines (calendar integration)
# ---------------------------------------------------------------------------


@router.get("/active", response_model=list[ActiveRoutineResponse])
async def get_active_routines(
    start: str = Query(...),
    end: str = Query(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        start_date = date_type.fromisoformat(start)
        end_date = date_type.fromisoformat(end)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Routine range is invalid") from exc
    if end_date < start_date:
        raise HTTPException(status_code=400, detail="Routine end must not be before start")
    if (end_date - start_date).days > MAX_ACTIVE_RANGE_DAYS:
        raise HTTPException(status_code=400, detail="Routine range cannot exceed 400 days")

    # Fetch all non-deleted routine items
    cursor = await db.execute(
        "SELECT * FROM routine_items WHERE deleted_at IS NULL AND family_id = ? "
        "ORDER BY sort_order ASC, name ASC LIMIT ?",
        (current_user["family_id"], MAX_ACTIVE_ROUTINE_ITEMS),
    )
    items = [dict(row) for row in await cursor.fetchall()]

    # Cache person names and active status per person per date
    name_cache: dict[str, str] = {}
    active_cache: dict[tuple[str, date_type], bool] = {}

    results: list[ActiveRoutineResponse] = []
    current = start_date
    while current <= end_date:
        day_of_week = current.weekday()  # 0=Monday, 6=Sunday — matches our schema
        for item in items:
            if not bool(item.get("calendar_projection", 1)):
                continue
            days = (
                json.loads(item["days_of_week"])
                if isinstance(item["days_of_week"], str)
                else item["days_of_week"]
            )
            if day_of_week not in days:
                continue

            pid = item["person_id"]

            # Check active status (cached per person per date)
            if bool(item.get("term_only", 1)):
                cache_key = (pid, current)
                if cache_key not in active_cache:
                    active_cache[cache_key] = await is_person_in_term(
                        db, current_user["family_id"], pid, current
                    )
                if not active_cache[cache_key]:
                    continue

            # Get person name (cached)
            if pid not in name_cache:
                name_cache[pid] = await _person_name(db, current_user["family_id"], pid)

            results.append(
                ActiveRoutineResponse(
                    routine_item_id=item["id"],
                    person_id=pid,
                    person_name=name_cache[pid],
                    name=item["name"],
                    color=item["color"],
                    date=current.isoformat(),
                    time_of_day=item.get("time_of_day"),
                    location=item.get("location"),
                    preparation_note=item.get("preparation_note"),
                    prep_template_id=item.get("prep_template_id"),
                    reminder_minutes=item.get("reminder_minutes"),
                )
            )
            if len(results) >= MAX_ACTIVE_ROUTINE_RESULTS:
                return results
        current += timedelta(days=1)

    return results
