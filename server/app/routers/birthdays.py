import re
import uuid
from datetime import date, datetime, time, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.birthday import (
    BirthdayCreate,
    BirthdayImportDraft,
    BirthdayImportPreviewRequest,
    BirthdayImportPreviewResponse,
    BirthdayPreparationEventCreate,
    BirthdayPreparationLinkedItem,
    BirthdayPreparationResponse,
    BirthdayPreparationTaskCreate,
    BirthdayPreparationUpdate,
    BirthdayResponse,
    BirthdayUpdate,
)
from app.models.calendar import CalendarEventCreate
from app.models.task import TaskCreate
from app.services.birthdays import (
    FAMILY_TIMEZONE,
    current_age,
    family_today,
    next_birthday_parts,
    turning_age,
)
from app.services.create_records import create_or_replay_calendar_event, create_or_replay_task
from app.services.record_history import save_history

router = APIRouter()

_MONTHS = {
    name: index
    for index, names in enumerate(
        (
            ("january", "jan"),
            ("february", "feb"),
            ("march", "mar"),
            ("april", "apr"),
            ("may",),
            ("june", "jun"),
            ("july", "jul"),
            ("august", "aug"),
            ("september", "sep", "sept"),
            ("october", "oct"),
            ("november", "nov"),
            ("december", "dec"),
        ),
        start=1,
    )
    for name in names
}


def _birthday_parts(row: dict) -> tuple[int | None, int, int]:
    if row.get("birth_month") and row.get("birth_day"):
        return row.get("birth_year"), int(row["birth_month"]), int(row["birth_day"])
    legacy = date.fromisoformat(row["date_of_birth"])
    return legacy.year, legacy.month, legacy.day


def _row_to_response(row: dict) -> BirthdayResponse:
    """Convert a database row into a BirthdayResponse with computed fields."""
    data = dict(row)
    today = family_today()
    birth_year, birth_month, birth_day = _birthday_parts(data)

    data["birth_month"] = birth_month
    data["birth_day"] = birth_day
    data["year_known"] = birth_year is not None
    if birth_year is not None:
        dob = date(birth_year, birth_month, birth_day)
        data["date_of_birth"] = dob.isoformat()
        data["age"] = current_age(dob, today)
        data["turning_age"] = turning_age(dob, today)
    else:
        data["date_of_birth"] = None
        data["age"] = None
        data["turning_age"] = None
    nb = next_birthday_parts(birth_month, birth_day, today)
    data["next_birthday"] = nb.isoformat()
    data["days_until"] = (nb - today).days
    data["preparation_due"] = data["days_until"] <= data["reminder_days_before"]

    return BirthdayResponse(**data)


async def _find_duplicate(
    db,
    *,
    family_id: str,
    person_name: str,
    birth_month: int,
    birth_day: int,
    excluding_id: str | None = None,
):
    query = (
        "SELECT id FROM birthdays WHERE family_id = ? AND deleted_at IS NULL "
        "AND lower(trim(person_name)) = lower(trim(?)) "
        "AND birth_month = ? AND birth_day = ?"
    )
    params: list = [family_id, person_name, birth_month, birth_day]
    if excluding_id:
        query += " AND id != ?"
        params.append(excluding_id)
    cursor = await db.execute(query, params)
    return await cursor.fetchone()


def _normalised_birth_values(
    date_of_birth: str | None, birth_month: int | None, birth_day: int | None
) -> tuple[str, int | None, int, int]:
    if date_of_birth:
        parsed = date.fromisoformat(date_of_birth)
        return parsed.isoformat(), parsed.year, parsed.month, parsed.day
    if birth_month is None or birth_day is None:
        raise HTTPException(status_code=422, detail="Add the birthday's month and day")
    try:
        date(2000, birth_month, birth_day)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="That birthday date does not exist") from exc
    # The legacy column remains non-null during the backwards-compatible migration.
    return f"2000-{birth_month:02d}-{birth_day:02d}", None, birth_month, birth_day


def _parse_import_date(raw: str) -> tuple[str | None, int, int] | None:
    value = raw.strip().rstrip(".")
    for pattern in ("%Y-%m-%d", "%d/%m/%Y", "%d.%m.%Y"):
        try:
            parsed = datetime.strptime(value, pattern).date()
        except ValueError:
            continue
        if parsed <= family_today():
            return parsed.isoformat(), parsed.month, parsed.day
        return None
    for pattern in ("%d/%m", "%d.%m"):
        try:
            parsed = datetime.strptime(value, pattern).date()
        except ValueError:
            continue
        return None, parsed.month, parsed.day

    words = re.sub(r"[,]", " ", value.lower()).split()
    if len(words) in {2, 3}:
        month_index = next((index for index, word in enumerate(words) if word in _MONTHS), None)
        if month_index is not None:
            other = [word for index, word in enumerate(words) if index != month_index]
            try:
                day = int(other[0].rstrip("stndrdth"))
                year = int(other[1]) if len(other) == 2 else None
                probe = date(year or 2000, _MONTHS[words[month_index]], day)
            except (ValueError, IndexError):
                return None
            if year is not None and probe > family_today():
                return None
            return (probe.isoformat() if year is not None else None, probe.month, probe.day)
    return None


def _split_import_line(line: str) -> tuple[str, str] | None:
    for delimiter in ("\t", ";", " | ", " — ", " – ", ","):
        if delimiter in line:
            name, raw_date = line.rsplit(delimiter, 1)
            if name.strip() and raw_date.strip():
                return name.strip(), raw_date.strip()
    match = re.match(
        r"^(.+?)\s+(\d{4}-\d{2}-\d{2}|\d{1,2}[/.]\d{1,2}(?:[/.]\d{4})?|"
        r"\d{1,2}(?:st|nd|rd|th)?\s+[A-Za-z]+(?:\s+\d{4})?|"
        r"[A-Za-z]+\s+\d{1,2}(?:st|nd|rd|th)?(?:\s+\d{4})?)$",
        line.strip(),
    )
    return (match.group(1).strip(), match.group(2).strip()) if match else None


async def _birthday_row(db, birthday_id: str, family_id: str):
    cursor = await db.execute(
        "SELECT * FROM birthdays WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (birthday_id, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Birthday not found")
    return row


async def _preparation_response(db, birthday_row) -> BirthdayPreparationResponse:
    birthday = _row_to_response(birthday_row)
    occurrence_year = date.fromisoformat(birthday.next_birthday).year
    cursor = await db.execute(
        "SELECT * FROM birthday_preparations WHERE family_id = ? AND birthday_id = ? "
        "AND occurrence_year = ? AND deleted_at IS NULL",
        (birthday_row["family_id"], birthday.id, occurrence_year),
    )
    preparation = await cursor.fetchone()

    cursor = await db.execute(
        """
        SELECT l.record_type, l.record_id,
               CASE l.record_type WHEN 'task' THEN t.title ELSE e.title END AS title,
               CASE l.record_type WHEN 'task' THEN (t.completed_at IS NOT NULL) ELSE 0 END AS completed
        FROM birthday_preparation_links l
        LEFT JOIN tasks t ON l.record_type = 'task' AND t.id = l.record_id
            AND t.family_id = l.family_id AND t.deleted_at IS NULL
        LEFT JOIN calendar_events e ON l.record_type = 'calendar_event' AND e.id = l.record_id
            AND e.family_id = l.family_id AND e.deleted_at IS NULL
        WHERE l.family_id = ? AND l.birthday_id = ? AND l.occurrence_year = ?
          AND l.deleted_at IS NULL
          AND ((l.record_type = 'task' AND t.id IS NOT NULL)
               OR (l.record_type = 'calendar_event' AND e.id IS NOT NULL))
        ORDER BY l.created_at
        """,
        (birthday_row["family_id"], birthday.id, occurrence_year),
    )
    links = [dict(row) for row in await cursor.fetchall()]
    tasks = [
        BirthdayPreparationLinkedItem(
            id=item["record_id"], title=item["title"], completed=bool(item["completed"])
        )
        for item in links
        if item["record_type"] == "task"
    ]
    calendar_item = next(
        (item for item in links if item["record_type"] == "calendar_event"), None
    )

    gifts_total = 0
    gifts_remaining = 0
    columns = {
        row[1] for row in await (await db.execute("PRAGMA table_info(present_ideas)")).fetchall()
    }
    if "birthday_id" in columns:
        cursor = await db.execute(
            "SELECT COUNT(*) AS total, "
            "SUM(CASE WHEN status = 'given' THEN 0 ELSE 1 END) AS remaining "
            "FROM present_ideas WHERE family_id = ? AND birthday_id = ? AND deleted_at IS NULL",
            (birthday_row["family_id"], birthday.id),
        )
        gift_counts = await cursor.fetchone()
        gifts_total = int(gift_counts["total"] or 0)
        gifts_remaining = int(gift_counts["remaining"] or 0)

    return BirthdayPreparationResponse(
        birthday=birthday,
        occurrence_year=occurrence_year,
        card_status=preparation["card_status"] if preparation else "not_started",
        card_message=preparation["card_message"] if preparation else None,
        celebration_status=(
            preparation["celebration_status"] if preparation else "not_started"
        ),
        notes=preparation["notes"] if preparation else None,
        tasks=tasks,
        calendar_event=(
            BirthdayPreparationLinkedItem(
                id=calendar_item["record_id"], title=calendar_item["title"]
            )
            if calendar_item
            else None
        ),
        gifts_total=gifts_total,
        gifts_remaining=gifts_remaining,
    )


async def _link_preparation_record(
    db,
    *,
    birthday_id: str,
    occurrence_year: int,
    record_type: str,
    record_id: str,
    user: dict,
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO birthday_preparation_links
            (id, birthday_id, occurrence_year, record_type, record_id, family_id,
             created_at, updated_at, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT DO NOTHING
        """,
        (
            str(uuid.uuid4()),
            birthday_id,
            occurrence_year,
            record_type,
            record_id,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )
    await db.commit()


@router.get("/", response_model=list[BirthdayResponse])
async def list_birthdays(
    upcoming_days: int | None = Query(None, ge=0),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List birthdays, optionally filtered to those within upcoming_days."""
    cursor = await db.execute(
        "SELECT * FROM birthdays WHERE deleted_at IS NULL AND family_id = ?",
        (current_user["family_id"],),
    )
    rows = await cursor.fetchall()

    results = [_row_to_response(row) for row in rows]

    # Filter by upcoming_days if provided
    if upcoming_days is not None:
        results = [r for r in results if r.days_until <= upcoming_days]

    # Order by next occurrence (soonest first)
    results.sort(key=lambda r: r.days_until)

    # Apply pagination
    return results[offset : offset + limit]


@router.post("/", response_model=BirthdayResponse, status_code=status.HTTP_201_CREATED)
async def create_birthday(
    body: BirthdayCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a new birthday entry."""
    if body.client_id:
        cursor = await db.execute(
            "SELECT * FROM birthdays WHERE family_id = ? AND client_id = ? AND deleted_at IS NULL",
            (current_user["family_id"], body.client_id),
        )
        existing = await cursor.fetchone()
        if existing:
            return _row_to_response(existing)

    stored_date, birth_year, birth_month, birth_day = _normalised_birth_values(
        body.date_of_birth, body.birth_month, body.birth_day
    )
    if not body.allow_duplicate and await _find_duplicate(
        db,
        family_id=current_user["family_id"],
        person_name=body.person_name,
        birth_month=birth_month,
        birth_day=birth_day,
    ):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"{body.person_name} already has a birthday on this date",
        )
    birthday_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    await db.execute(
        """
        INSERT INTO birthdays
            (id, person_name, date_of_birth, birth_year, birth_month, birth_day,
             relationship, reminder_days_before,
             created_at, updated_at, created_by, client_id, client_timestamp, family_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            birthday_id,
            body.person_name,
            stored_date,
            birth_year,
            birth_month,
            birth_day,
            body.relationship,
            body.reminder_days_before,
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
            current_user["family_id"],
        ),
    )
    await db.commit()

    cursor = await db.execute(
        "SELECT * FROM birthdays WHERE id = ? AND family_id = ?",
        (birthday_id, current_user["family_id"]),
    )
    row = await cursor.fetchone()
    return _row_to_response(row)


@router.get("/{birthday_id}/preparation", response_model=BirthdayPreparationResponse)
async def get_birthday_preparation(
    birthday_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _birthday_row(db, birthday_id, current_user["family_id"])
    return await _preparation_response(db, row)


@router.put("/{birthday_id}/preparation", response_model=BirthdayPreparationResponse)
async def update_birthday_preparation(
    birthday_id: str,
    body: BirthdayPreparationUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    birthday_row = await _birthday_row(db, birthday_id, current_user["family_id"])
    birthday = _row_to_response(birthday_row)
    occurrence_year = date.fromisoformat(birthday.next_birthday).year
    updates = body.model_dump(exclude_unset=True)
    for field in ("card_message", "notes"):
        if field in updates and updates[field] is not None:
            updates[field] = updates[field].strip() or None
    if not updates:
        return await _preparation_response(db, birthday_row)

    cursor = await db.execute(
        "SELECT * FROM birthday_preparations WHERE family_id = ? AND birthday_id = ? "
        "AND occurrence_year = ? AND deleted_at IS NULL",
        (current_user["family_id"], birthday_id, occurrence_year),
    )
    existing = await cursor.fetchone()
    now = datetime.now(timezone.utc).isoformat()
    if existing:
        await save_history(
            db,
            "birthday_preparations",
            existing["id"],
            current_user["id"],
            family_id=current_user["family_id"],
        )
        set_clause = ", ".join(f"{field} = ?" for field in updates)
        await db.execute(
            f"UPDATE birthday_preparations SET {set_clause}, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            [*updates.values(), now, existing["id"], current_user["family_id"]],
        )
    else:
        values = {
            "card_status": "not_started",
            "card_message": None,
            "celebration_status": "not_started",
            "notes": None,
            **updates,
        }
        await db.execute(
            """
            INSERT INTO birthday_preparations
                (id, birthday_id, occurrence_year, card_status, card_message,
                 celebration_status, notes, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                birthday_id,
                occurrence_year,
                values["card_status"],
                values["card_message"],
                values["celebration_status"],
                values["notes"],
                current_user["family_id"],
                now,
                now,
                current_user["id"],
            ),
        )
    await db.commit()
    return await _preparation_response(db, birthday_row)


@router.post("/{birthday_id}/preparation/task", response_model=BirthdayPreparationResponse)
async def create_birthday_preparation_task(
    birthday_id: str,
    body: BirthdayPreparationTaskCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    birthday_row = await _birthday_row(db, birthday_id, current_user["family_id"])
    birthday = _row_to_response(birthday_row)
    next_date = date.fromisoformat(birthday.next_birthday)
    due_date = min(next_date, next_date - timedelta(days=body.due_days_before))
    due_at = datetime.combine(due_date, time(hour=18), tzinfo=FAMILY_TIMEZONE).isoformat()
    task_id = str(uuid.uuid4())
    try:
        await create_or_replay_task(
            db,
            TaskCreate(
                id=task_id,
                title=body.title.strip(),
                assigned_to=body.assigned_to,
                due_date=due_at,
                category="admin",
                priority=2,
                client_id=f"birthday-{birthday_id}-{task_id}",
            ),
            record_id=task_id,
            user=current_user,
            client_id=f"birthday-{birthday_id}-{task_id}",
            client_timestamp=None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    occurrence_year = next_date.year
    await _link_preparation_record(
        db,
        birthday_id=birthday_id,
        occurrence_year=occurrence_year,
        record_type="task",
        record_id=task_id,
        user=current_user,
    )
    return await _preparation_response(db, birthday_row)


@router.post("/{birthday_id}/preparation/event", response_model=BirthdayPreparationResponse)
async def create_birthday_preparation_event(
    birthday_id: str,
    body: BirthdayPreparationEventCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    birthday_row = await _birthday_row(db, birthday_id, current_user["family_id"])
    birthday = _row_to_response(birthday_row)
    next_date = date.fromisoformat(birthday.next_birthday)
    starts_at = datetime.combine(next_date, time.min, tzinfo=FAMILY_TIMEZONE)
    event_id = str(uuid.uuid4())
    title = body.title.strip() if body.title and body.title.strip() else f"{birthday.person_name}'s birthday"
    try:
        await create_or_replay_calendar_event(
            db,
            CalendarEventCreate(
                id=event_id,
                title=title,
                start_time=starts_at.isoformat(),
                end_time=(starts_at + timedelta(days=1)).isoformat(),
                all_day=True,
                location=body.location.strip() if body.location and body.location.strip() else None,
                event_type="birthday",
                client_id=f"birthday-{birthday_id}-{event_id}",
            ),
            record_id=event_id,
            user=current_user,
            client_id=f"birthday-{birthday_id}-{event_id}",
            client_timestamp=None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    await _link_preparation_record(
        db,
        birthday_id=birthday_id,
        occurrence_year=next_date.year,
        record_type="calendar_event",
        record_id=event_id,
        user=current_user,
    )
    return await _preparation_response(db, birthday_row)


@router.put("/{birthday_id}", response_model=BirthdayResponse)
async def update_birthday(
    birthday_id: str,
    body: BirthdayUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update an existing birthday. Saves previous values to record_history."""
    cursor = await db.execute(
        "SELECT * FROM birthdays WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (birthday_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Birthday not found",
        )

    # Record history before modifying
    await save_history(
        db,
        "birthdays",
        birthday_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    updates = body.model_dump(exclude_unset=True)
    allow_duplicate = bool(updates.pop("allow_duplicate", False))
    if not updates:
        return _row_to_response(existing)

    current = dict(existing)
    effective_name = updates.get("person_name", current["person_name"])
    current_year, current_month, current_day = _birthday_parts(current)
    date_was_supplied = "date_of_birth" in body.model_fields_set
    month_was_supplied = "birth_month" in body.model_fields_set
    day_was_supplied = "birth_day" in body.model_fields_set
    if date_was_supplied:
        supplied_month = updates.get("birth_month") if month_was_supplied else current_month
        supplied_day = updates.get("birth_day") if day_was_supplied else current_day
        stored_date, birth_year, birth_month, birth_day = _normalised_birth_values(
            updates.get("date_of_birth"), supplied_month, supplied_day
        )
        updates.update(
            date_of_birth=stored_date,
            birth_year=birth_year,
            birth_month=birth_month,
            birth_day=birth_day,
        )
    elif month_was_supplied or day_was_supplied:
        birth_month = updates.get("birth_month", current_month)
        birth_day = updates.get("birth_day", current_day)
        if birth_month is None or birth_day is None:
            raise HTTPException(status_code=422, detail="Birth month and day must be supplied together")
        try:
            probe = date(current_year or 2000, birth_month, birth_day)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail="That birthday date does not exist") from exc
        updates["birth_month"] = birth_month
        updates["birth_day"] = birth_day
        updates["date_of_birth"] = probe.isoformat()
        birth_year = current_year
    else:
        birth_year, birth_month, birth_day = current_year, current_month, current_day

    if not allow_duplicate and await _find_duplicate(
        db,
        family_id=current_user["family_id"],
        person_name=effective_name,
        birth_month=birth_month,
        birth_day=birth_day,
        excluding_id=birthday_id,
    ):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"{effective_name} already has a birthday on this date",
        )

    now = datetime.now(timezone.utc).isoformat()
    updates["updated_at"] = now

    set_clause = ", ".join(f"{col} = ?" for col in updates)
    values = list(updates.values()) + [birthday_id, current_user["family_id"]]

    await db.execute(
        f"UPDATE birthdays SET {set_clause} WHERE id = ? AND family_id = ?",
        values,
    )
    await db.commit()

    cursor = await db.execute(
        "SELECT * FROM birthdays WHERE id = ? AND family_id = ?",
        (birthday_id, current_user["family_id"]),
    )
    row = await cursor.fetchone()
    return _row_to_response(row)


@router.delete("/{birthday_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_birthday(
    birthday_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a birthday by setting deleted_at."""
    cursor = await db.execute(
        "SELECT * FROM birthdays WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (birthday_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Birthday not found",
        )

    # Record history before deleting
    await save_history(
        db,
        "birthdays",
        birthday_id,
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE birthdays SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, birthday_id, current_user["family_id"]),
    )
    await db.commit()


@router.post("/{birthday_id}/restore", response_model=BirthdayResponse)
async def restore_birthday(
    birthday_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM birthdays WHERE id = ? AND deleted_at IS NOT NULL AND family_id = ?",
        (birthday_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Removed birthday not found")
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db, "birthdays", birthday_id, current_user["id"], family_id=current_user["family_id"]
    )
    await db.execute(
        "UPDATE birthdays SET deleted_at = NULL, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, birthday_id, current_user["family_id"]),
    )
    await db.commit()
    cursor = await db.execute(
        "SELECT * FROM birthdays WHERE id = ? AND family_id = ?",
        (birthday_id, current_user["family_id"]),
    )
    return _row_to_response(await cursor.fetchone())


@router.post("/import-preview", response_model=BirthdayImportPreviewResponse)
async def preview_birthday_import(
    body: BirthdayImportPreviewRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    drafts: list[BirthdayImportDraft] = []
    for line_number, source in enumerate(body.text.splitlines(), start=1):
        source = source.strip()
        if not source:
            continue
        split = _split_import_line(source)
        if not split:
            drafts.append(
                BirthdayImportDraft(
                    line_number=line_number,
                    source_line=source,
                    issue="Use one line per person, for example ‘Grandma, 15 June 1955’",
                )
            )
            continue
        person_name, raw_date = split
        parsed = _parse_import_date(raw_date)
        if not parsed:
            drafts.append(
                BirthdayImportDraft(
                    line_number=line_number,
                    source_line=source,
                    person_name=person_name,
                    issue="Check the date",
                )
            )
            continue
        date_of_birth, birth_month, birth_day = parsed
        duplicate = await _find_duplicate(
            db,
            family_id=current_user["family_id"],
            person_name=person_name,
            birth_month=birth_month,
            birth_day=birth_day,
        )
        drafts.append(
            BirthdayImportDraft(
                line_number=line_number,
                source_line=source,
                person_name=person_name,
                date_of_birth=date_of_birth,
                birth_month=birth_month,
                birth_day=birth_day,
                duplicate_id=duplicate["id"] if duplicate else None,
            )
        )
    return BirthdayImportPreviewResponse(drafts=drafts)
