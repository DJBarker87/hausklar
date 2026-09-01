"""Tests for the briefing module (service + router)."""

import uuid
from datetime import date, datetime, timedelta, timezone

import aiosqlite

from app.services.briefing import generate_briefing


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _today_str() -> str:
    return date.today().isoformat()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


async def _insert_calendar_event(db_path: str, title: str, start_time: str, end_time: str, **kwargs):
    """Insert a calendar event directly into the database."""
    event_id = str(uuid.uuid4())
    now = _now_iso()
    all_day = int(kwargs.get("all_day", 0))
    location = kwargs.get("location")
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO calendar_events (id, title, start_time, end_time, all_day, location,
                                         created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (event_id, title, start_time, end_time, all_day, location, now, now),
        )
        await db.commit()
    return event_id


async def _insert_task(db_path: str, title: str, due_date: str, **kwargs):
    """Insert a task directly into the database."""
    task_id = str(uuid.uuid4())
    now = _now_iso()
    assigned_to = kwargs.get("assigned_to")
    category = kwargs.get("category", "other")
    completed_at = kwargs.get("completed_at")
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO tasks (id, title, due_date, assigned_to, category, completed_at,
                               created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (task_id, title, due_date, assigned_to, category, completed_at, now, now),
        )
        await db.commit()
    return task_id


async def _insert_birthday(db_path: str, person_name: str, date_of_birth: str, **kwargs):
    """Insert a birthday directly into the database."""
    bday_id = str(uuid.uuid4())
    now = _now_iso()
    relationship = kwargs.get("relationship", "friend")
    reminder_days_before = kwargs.get("reminder_days_before", 7)
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO birthdays (id, person_name, date_of_birth, relationship,
                                   reminder_days_before, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                bday_id,
                person_name,
                date_of_birth,
                relationship,
                reminder_days_before,
                now,
                now,
            ),
        )
        await db.commit()
    return bday_id


async def _insert_dog_activity(db_path: str, activity_type: str, started_at: str, **kwargs):
    """Insert a dog activity directly into the database."""
    activity_id = str(uuid.uuid4())
    now = _now_iso()
    done_by = kwargs.get("done_by")
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO dog_activities (id, activity_type, started_at, done_by,
                                        created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (activity_id, activity_type, started_at, done_by, now, now),
        )
        await db.commit()
    return activity_id


async def _insert_child(db_path: str, name: str, date_of_birth: str) -> str:
    """Insert a child directly into the database."""
    child_id = str(uuid.uuid4())
    now = _now_iso()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            (child_id, name, date_of_birth, now, now),
        )
        await db.commit()
    return child_id


async def _insert_medicine_type(db_path: str, name: str, child_id: str) -> str:
    """Insert a medicine type directly into the database."""
    type_id = str(uuid.uuid4())
    now = _now_iso()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO medicine_types (id, name, child_id, min_hours_between_doses, max_doses_24h,
                                        created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (type_id, name, child_id, 4.0, 4, now, now),
        )
        await db.commit()
    return type_id


async def _insert_medicine_dose(db_path: str, medicine_type_id: str, child_id: str, given_at: str) -> str:
    """Insert a medicine dose directly into the database."""
    dose_id = str(uuid.uuid4())
    now = _now_iso()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO medicine_doses (id, medicine_type_id, child_id, given_at, given_by,
                                        created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (dose_id, medicine_type_id, child_id, given_at, "test-user", now, now),
        )
        await db.commit()
    return dose_id


async def _get_db_connection(db_path: str):
    """Get an aiosqlite connection with row factory set."""
    db = await aiosqlite.connect(db_path)
    db.row_factory = aiosqlite.Row
    return db


# ---------------------------------------------------------------------------
# Tests — briefing includes calendar events for today
# ---------------------------------------------------------------------------


async def test_briefing_includes_calendar_events(initialized_db):
    """Briefing should include calendar events happening today."""
    today = _today_str()
    await _insert_calendar_event(
        initialized_db,
        title="Team standup",
        start_time=f"{today}T09:00:00Z",
        end_time=f"{today}T09:30:00Z",
        location="Zoom",
    )
    await _insert_calendar_event(
        initialized_db,
        title="Dentist",
        start_time=f"{today}T14:00:00Z",
        end_time=f"{today}T15:00:00Z",
    )
    # Event on a different day — should NOT appear
    tomorrow = (date.today() + timedelta(days=1)).isoformat()
    await _insert_calendar_event(
        initialized_db,
        title="Tomorrow event",
        start_time=f"{tomorrow}T10:00:00Z",
        end_time=f"{tomorrow}T11:00:00Z",
    )

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    titles = [e["title"] for e in briefing["calendar_events"]]
    assert "Team standup" in titles
    assert "Dentist" in titles
    assert "Tomorrow event" not in titles
    assert briefing["date"] == today


async def test_briefing_respects_recurring_cancellations_and_replacements(
    client, adult_a_headers, adult_a_user, initialized_db
):
    reference = datetime(2026, 8, 9, 9, 0, tzinfo=timezone.utc)
    cancelled_series = await client.post(
        "/api/calendar/",
        json={
            "title": "Cancelled Sunday club",
            "start_time": "2026-08-02",
            "all_day": True,
            "recurrence_rule": "FREQ=WEEKLY;COUNT=2",
        },
        headers=adult_a_headers,
    )
    moved_series = await client.post(
        "/api/calendar/",
        json={
            "title": "Original Sunday lunch",
            "start_time": "2026-08-02",
            "all_day": True,
            "recurrence_rule": "FREQ=WEEKLY;COUNT=2",
        },
        headers=adult_a_headers,
    )
    assert cancelled_series.status_code == moved_series.status_code == 201
    cancelled = await client.post(
        f"/api/calendar/{cancelled_series.json()['id']}/occurrences/delete",
        json={"scope": "only_this", "occurrence_start": "2026-08-09"},
        headers=adult_a_headers,
    )
    replaced = await client.patch(
        f"/api/calendar/{moved_series.json()['id']}/occurrences",
        json={
            "scope": "only_this",
            "occurrence_start": "2026-08-09",
            "updates": {"title": "Lunch moved to the garden"},
        },
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 204
    assert replaced.status_code == 200

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(
            db,
            include_weather=False,
            family_id=adult_a_user["family_id"],
            now=reference,
        )
    finally:
        await db.close()

    titles = {event["title"] for event in briefing["calendar_events"]}
    assert "Cancelled Sunday club" not in titles
    assert "Original Sunday lunch" not in titles
    assert "Lunch moved to the garden" in titles


# ---------------------------------------------------------------------------
# Tests — briefing includes tasks due today
# ---------------------------------------------------------------------------


async def test_briefing_includes_tasks_due_today(initialized_db):
    """Briefing should include incomplete tasks due today."""
    today = _today_str()
    await _insert_task(initialized_db, title="Take bins out", due_date=today, category="bins")
    await _insert_task(initialized_db, title="Buy milk", due_date=today, category="shopping")

    # Completed task — should NOT appear
    await _insert_task(
        initialized_db,
        title="Completed task",
        due_date=today,
        completed_at=_now_iso(),
    )

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    task_titles = [t["title"] for t in briefing["tasks_due"]]
    assert "Take bins out" in task_titles
    assert "Buy milk" in task_titles
    assert "Completed task" not in task_titles


# ---------------------------------------------------------------------------
# Tests — briefing includes overdue tasks
# ---------------------------------------------------------------------------


async def test_briefing_includes_overdue_tasks(initialized_db):
    """Briefing should include tasks with a due_date before today that are incomplete."""
    yesterday = (date.today() - timedelta(days=1)).isoformat()
    await _insert_task(initialized_db, title="Overdue task", due_date=yesterday)

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    task_titles = [t["title"] for t in briefing["tasks_due"]]
    assert "Overdue task" in task_titles


# ---------------------------------------------------------------------------
# Tests — briefing includes upcoming birthdays
# ---------------------------------------------------------------------------


async def test_briefing_includes_upcoming_birthdays(initialized_db):
    """Briefing should include birthdays within the next 7 days."""
    today = date.today()

    # Birthday in 3 days
    soon_date = today + timedelta(days=3)
    soon_dob = soon_date.replace(year=soon_date.year - 30)
    await _insert_birthday(initialized_db, "Alice", soon_dob.isoformat(), relationship="family")

    # Birthday in 60 days — should NOT appear
    far_date = today + timedelta(days=60)
    far_dob = far_date.replace(year=far_date.year - 25)
    await _insert_birthday(initialized_db, "Bob", far_dob.isoformat(), relationship="friend")

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    names = [b["person_name"] for b in briefing["upcoming_birthdays"]]
    assert "Alice" in names
    assert "Bob" not in names


async def test_briefing_honours_each_birthday_reminder_lead_time(initialized_db):
    reference = datetime(2026, 1, 10, 9, 0, tzinfo=timezone.utc)
    await _insert_birthday(
        initialized_db,
        "Long lead",
        "1990-01-20",
        reminder_days_before=14,
    )
    await _insert_birthday(
        initialized_db,
        "Short lead",
        "1990-01-15",
        reminder_days_before=3,
    )

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(
            db,
            include_weather=False,
            now=reference,
        )
    finally:
        await db.close()

    names = {birthday["person_name"] for birthday in briefing["upcoming_birthdays"]}
    assert "Long lead" in names
    assert "Short lead" not in names


async def test_briefing_survives_leap_day_birthday(initialized_db):
    """A 29 Feb birthday must not crash the briefing in a non-leap year."""
    await _insert_birthday(initialized_db, "Leapling", "2000-02-29", relationship="family")

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    # It should simply produce a briefing without raising ValueError.
    assert "upcoming_birthdays" in briefing


async def test_briefing_includes_birthday_today(initialized_db):
    """Briefing should include a birthday that is today (days_until = 0)."""
    today = date.today()
    today_dob = today.replace(year=today.year - 40)
    await _insert_birthday(initialized_db, "Charlie", today_dob.isoformat(), relationship="family")

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    names = [b["person_name"] for b in briefing["upcoming_birthdays"]]
    assert "Charlie" in names
    charlie = next(b for b in briefing["upcoming_birthdays"] if b["person_name"] == "Charlie")
    assert charlie["days_until"] == 0


# ---------------------------------------------------------------------------
# Tests — briefing generates formatted WhatsApp message
# ---------------------------------------------------------------------------


async def test_briefing_generates_whatsapp_message(initialized_db):
    """Briefing should include a 'message' field with formatted text."""
    today = _today_str()
    await _insert_calendar_event(
        initialized_db,
        title="Morning meeting",
        start_time=f"{today}T08:00:00Z",
        end_time=f"{today}T09:00:00Z",
    )
    await _insert_task(initialized_db, title="Call plumber", due_date=today)

    # Birthday in 2 days
    soon_date = date.today() + timedelta(days=2)
    soon_dob = soon_date.replace(year=soon_date.year - 10)
    await _insert_birthday(initialized_db, "Eve", soon_dob.isoformat())

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    msg = briefing["message"]
    assert isinstance(msg, str)
    assert len(msg) > 0
    assert today in msg
    assert "Morning meeting" in msg
    assert "Call plumber" in msg
    assert "Eve" in msg
    assert "CALENDAR" in msg
    assert "TASKS" in msg
    assert "BIRTHDAYS" in msg


async def test_briefing_message_includes_dog_warnings(initialized_db):
    """WhatsApp message should warn if the dog was NOT walked/fed yesterday."""
    # Insert NO dog activities for yesterday — so warnings should appear
    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    msg = briefing["message"]
    assert "NOT walked yesterday" in msg
    assert "NOT fed yesterday" in msg


# ---------------------------------------------------------------------------
# Tests — empty briefing
# ---------------------------------------------------------------------------


async def test_empty_briefing(initialized_db):
    """When there are no events, tasks, birthdays, etc., briefing still works."""
    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    assert briefing["date"] == _today_str()
    assert briefing["calendar_events"] == []
    assert briefing["tasks_due"] == []
    assert briefing["upcoming_birthdays"] == []
    assert briefing["medicine_today"] == []
    assert briefing["weather"] is None
    assert isinstance(briefing["message"], str)
    assert len(briefing["message"]) > 0
    assert "Nothing special on the agenda" in briefing["message"]


# ---------------------------------------------------------------------------
# Tests — medicine in briefing
# ---------------------------------------------------------------------------


async def test_briefing_includes_medicine_today(initialized_db):
    """Briefing should include medicine doses given today."""
    today = _today_str()

    child_id = await _insert_child(initialized_db, "Test Child", "2020-01-01")
    med_type_id = await _insert_medicine_type(initialized_db, "Calpol", child_id)
    await _insert_medicine_dose(
        initialized_db, med_type_id, child_id, f"{today}T08:00:00Z"
    )

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    assert len(briefing["medicine_today"]) == 1
    assert briefing["medicine_today"][0]["medicine_name"] == "Calpol"
    assert briefing["medicine_today"][0]["child_name"] == "Test Child"

    # Check message includes medicine info
    msg = briefing["message"]
    assert "Calpol" in msg
    assert "MEDICINE" in msg


# ---------------------------------------------------------------------------
# Tests — dog status in briefing
# ---------------------------------------------------------------------------


async def test_briefing_dog_status_with_activities(initialized_db):
    """Briefing should reflect dog activities from yesterday."""
    yesterday = (date.today() - timedelta(days=1)).isoformat()
    await _insert_dog_activity(initialized_db, "walk", f"{yesterday}T07:00:00Z")
    await _insert_dog_activity(initialized_db, "feed", f"{yesterday}T08:00:00Z")

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(db, include_weather=False)
    finally:
        await db.close()

    assert briefing["dog_status"]["walked_yesterday"] is True
    assert briefing["dog_status"]["fed_yesterday"] is True

    # Message should NOT contain "NOT walked" warnings
    msg = briefing["message"]
    assert "NOT walked yesterday" not in msg
    assert "NOT fed yesterday" not in msg


async def test_briefing_uses_family_day_and_specific_feed_activity_types(initialized_db):
    reference = datetime(2026, 7, 11, 23, 30, tzinfo=timezone.utc)  # 00:30 BST
    await _insert_dog_activity(
        initialized_db,
        "feed_breakfast",
        "2026-07-11T22:30:00+00:00",  # 23:30 on the previous local day
    )
    await _insert_dog_activity(
        initialized_db,
        "feed_dinner",
        "2026-07-11T23:15:00+00:00",  # 00:15 on the current local day
    )

    db = await _get_db_connection(initialized_db)
    try:
        briefing = await generate_briefing(
            db,
            include_weather=False,
            now=reference,
        )
    finally:
        await db.close()

    assert briefing["date"] == "2026-07-12"
    assert briefing["dog_status"]["fed_yesterday"] is True
    assert briefing["dog_status"]["fed_today"] is True


# ---------------------------------------------------------------------------
# Tests — API endpoints (via HTTP client)
# ---------------------------------------------------------------------------


async def test_get_briefing_endpoint(client, adult_a_user, adult_a_headers):
    """GET /api/briefing/today should return a briefing object."""
    resp = await client.get("/api/briefing/today", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert "date" in data
    assert "calendar_events" in data
    assert "tasks_due" in data
    assert "upcoming_birthdays" in data
    assert "message" in data
    assert data["date"] == _today_str()


async def test_briefing_requires_auth(client):
    """GET /api/briefing/today without auth returns 401 or 403."""
    resp = await client.get("/api/briefing/today")
    assert resp.status_code in (401, 403)


async def test_weather_endpoint_returns_only_forecast(client, adult_a_headers, monkeypatch):
    async def forecast():
        return {
            "description": "light rain",
            "temp_high": 18.0,
            "temp_low": 11.5,
            "rain_chance": 40,
        }

    monkeypatch.setattr("app.routers.briefing.get_weather_summary", forecast)
    resp = await client.get("/api/briefing/weather", headers=adult_a_headers)

    assert resp.status_code == 200
    assert resp.json() == {"weather": await forecast()}


async def test_send_briefing_requires_auth(client):
    """POST /api/briefing/send without auth returns 401 or 403."""
    resp = await client.post("/api/briefing/send")
    assert resp.status_code in (401, 403)


async def test_send_briefing_allows_another_household_admin(client, other_family_headers):
    response = await client.post(
        "/api/briefing/send",
        headers=other_family_headers,
    )

    assert response.status_code == 200
