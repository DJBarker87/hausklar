"""Morning briefing generation service.

Aggregates data from calendar events, tasks, birthdays, medicine, and dog
activities to produce a structured briefing and a WhatsApp-friendly text message.
"""

import asyncio
from contextlib import suppress
from datetime import datetime, time, timedelta, timezone

from app.database import database_lease
from app.services.birthdays import FAMILY_TIMEZONE, next_birthday_parts
from app.services.calendar_recurrence import expand_calendar_rows
from app.services.weather import get_weather_summary


async def generate_briefing_for_family(family_id: str) -> dict:
    """Read family data, release SQLite, then await the external forecast."""
    weather_task = asyncio.create_task(get_weather_summary())
    try:
        async with database_lease() as db:
            briefing = await generate_briefing(
                db,
                include_weather=False,
                family_id=family_id,
            )
        weather = await weather_task
    except BaseException:
        weather_task.cancel()
        with suppress(asyncio.CancelledError):
            await weather_task
        raise
    briefing["weather"] = weather
    briefing["message"] = _format_whatsapp_message(
        briefing["date"],
        briefing["calendar_events"],
        briefing["tasks_due"],
        briefing["upcoming_birthdays"],
        briefing["medicine_today"],
        briefing["dog_status"],
        weather,
    )
    return briefing


async def generate_briefing(
    db,
    *,
    include_weather: bool = True,
    family_id: str | None = None,
    now: datetime | None = None,
) -> dict:
    """Generate today's morning briefing.

    Args:
        db: An aiosqlite database connection.
        include_weather: Whether to fetch live weather data (disable in tests).
        family_id: Scope data to this family (multi-tenancy).

    Returns a dict with sections: calendar, tasks, birthdays, medicine, dog,
    weather, and a formatted message string.
    """
    now_utc = now or datetime.now(timezone.utc)
    if now_utc.tzinfo is None:
        now_utc = now_utc.replace(tzinfo=timezone.utc)
    now_utc = now_utc.astimezone(timezone.utc)
    today = now_utc.astimezone(FAMILY_TIMEZONE).date()
    today_str = today.isoformat()  # e.g. "2026-02-08"
    local_day_start = datetime.combine(today, time.min, tzinfo=FAMILY_TIMEZONE)
    local_day_end = local_day_start + timedelta(days=1)
    day_start = local_day_start.astimezone(timezone.utc).isoformat()
    day_end = local_day_end.astimezone(timezone.utc).isoformat()
    weather_task = asyncio.create_task(get_weather_summary()) if include_weather else None

    family_filter = ""
    family_params: tuple = ()
    if family_id:
        family_filter = " AND family_id = ?"
        family_params = (family_id,)

    # ------------------------------------------------------------------
    # 1. Calendar events today
    # ------------------------------------------------------------------
    coarse_start = (local_day_start - timedelta(days=1)).date().isoformat()
    coarse_end = (local_day_end + timedelta(days=1)).date().isoformat()
    cursor = await db.execute(
        f"""
        SELECT ce.id, ce.title, ce.start_time, ce.end_time, ce.all_day,
               ce.location, ce.recurrence_rule, ce.family_id
        FROM calendar_events ce
        WHERE ce.deleted_at IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM calendar_events replacement
              WHERE replacement.overridden_event_id = ce.id
                AND replacement.family_id = ce.family_id
                AND replacement.deleted_at IS NULL
          )
          AND (
              ce.recurrence_rule IS NOT NULL
              OR (
                  substr(ce.start_time, 1, 10) < ?
                  AND substr(COALESCE(ce.end_time, ce.start_time), 1, 10) >= ?
              )
          )
          {" AND ce.family_id = ?" if family_id else ""}
        ORDER BY ce.start_time ASC
        LIMIT 500
        """,
        (coarse_end, coarse_start) + family_params,
    )
    rows = [dict(row) for row in await cursor.fetchall()]
    grouped_rows: dict[str, list[dict]] = {}
    for row in rows:
        grouped_rows.setdefault(row.get("family_id") or "", []).append(row)
    expanded = []
    for row_family_id, family_rows in grouped_rows.items():
        expanded.extend(
            await expand_calendar_rows(
                db,
                family_id=row_family_id,
                rows=family_rows,
                range_start=local_day_start,
                range_end=local_day_end,
                max_occurrences_per_series=50,
            )
        )
    expanded.sort(key=lambda occurrence: occurrence.start)
    calendar_events = [
        {
            "title": occurrence.row["title"],
            "start_time": occurrence.start_value,
            "end_time": occurrence.end_value,
            "all_day": occurrence.all_day,
            "location": occurrence.row.get("location"),
        }
        for occurrence in expanded
    ]

    # ------------------------------------------------------------------
    # 2. Tasks due today + overdue (incomplete, due_date <= today)
    # ------------------------------------------------------------------
    cursor = await db.execute(
        f"""
        SELECT title, due_date, assigned_to, category
        FROM tasks
        WHERE deleted_at IS NULL
          AND completed_at IS NULL
          AND due_date IS NOT NULL
          AND due_date <= ?
          AND (actionable_from IS NULL OR actionable_from <= ?)
          {family_filter}
        ORDER BY due_date ASC
        """,
        (today_str, now_utc.isoformat()) + family_params,
    )
    rows = await cursor.fetchall()
    tasks_due = [dict(row) for row in rows]

    # ------------------------------------------------------------------
    # 3. Upcoming birthdays within 7 days
    # ------------------------------------------------------------------
    cursor = await db.execute(
        f"SELECT person_name, date_of_birth, birth_year, birth_month, birth_day, "
        f"relationship, reminder_days_before "
        f"FROM birthdays WHERE deleted_at IS NULL{family_filter}",
        family_params,
    )
    rows = await cursor.fetchall()
    upcoming_birthdays = []
    for row in rows:
        data = dict(row)
        legacy = datetime.fromisoformat(data["date_of_birth"]).date()
        birth_month = int(data.get("birth_month") or legacy.month)
        birth_day = int(data.get("birth_day") or legacy.day)
        birth_year = data.get("birth_year")
        this_year_bday = next_birthday_parts(birth_month, birth_day, today)
        days_until = (this_year_bday - today).days
        reminder_days = max(0, int(data.get("reminder_days_before") or 0))
        if days_until <= reminder_days:
            data["days_until"] = days_until
            data["turning_age"] = (
                this_year_bday.year - int(birth_year) if birth_year is not None else None
            )
            upcoming_birthdays.append(data)
    upcoming_birthdays.sort(key=lambda b: b["days_until"])

    # ------------------------------------------------------------------
    # 4. Medicine — recent doses today + medicine types for context
    # ------------------------------------------------------------------
    cursor = await db.execute(
        f"""
        SELECT md.given_at, md.child_id,
               COALESCE(mt.name, md.medicine_name, 'Unknown') AS medicine_name,
               c.name AS child_name
        FROM medicine_doses md
        LEFT JOIN medicine_types mt ON md.medicine_type_id = mt.id
        LEFT JOIN children c ON md.child_id = c.id
        WHERE md.deleted_at IS NULL
          AND julianday(md.given_at) >= julianday(?)
          AND julianday(md.given_at) < julianday(?)
          {" AND md.family_id = ?" if family_id else ""}
        ORDER BY md.given_at DESC
        """,
        (day_start, day_end) + family_params,
    )
    rows = await cursor.fetchall()
    medicine_today = [dict(row) for row in rows]

    # Also get active medicine types so we know what's expected
    cursor = await db.execute(
        f"""
        SELECT mt.name, mt.child_id, c.name AS child_name
        FROM medicine_types mt
        LEFT JOIN children c ON mt.child_id = c.id
        WHERE mt.deleted_at IS NULL
          {" AND mt.family_id = ?" if family_id else ""}
        """,
        family_params,
    )
    rows = await cursor.fetchall()
    active_medicines = [dict(row) for row in rows]

    # ------------------------------------------------------------------
    # 5. Dog status — walked/fed yesterday?
    # ------------------------------------------------------------------
    yesterday_start = (local_day_start - timedelta(days=1)).astimezone(timezone.utc).isoformat()
    tomorrow_start = local_day_end.astimezone(timezone.utc).isoformat()

    cursor = await db.execute(
        f"""
        SELECT activity_type, started_at, done_by
        FROM dog_activities
        WHERE deleted_at IS NULL
          AND julianday(started_at) >= julianday(?)
          AND julianday(started_at) < julianday(?)
          {family_filter}
        ORDER BY started_at DESC
        """,
        (yesterday_start, day_start) + family_params,
    )
    rows = await cursor.fetchall()
    yesterday_dog = [dict(row) for row in rows]

    walked_yesterday = any(a["activity_type"] == "walk" for a in yesterday_dog)
    feed_types = {"feed", "feed_breakfast", "feed_dinner"}
    fed_yesterday = any(a["activity_type"] in feed_types for a in yesterday_dog)

    # Also check today
    cursor = await db.execute(
        f"""
        SELECT activity_type, started_at, done_by
        FROM dog_activities
        WHERE deleted_at IS NULL
          AND julianday(started_at) >= julianday(?)
          AND julianday(started_at) < julianday(?)
          {family_filter}
        ORDER BY started_at DESC
        """,
        (day_start, tomorrow_start) + family_params,
    )
    rows = await cursor.fetchall()
    today_dog = [dict(row) for row in rows]

    walked_today = any(a["activity_type"] == "walk" for a in today_dog)
    fed_today = any(a["activity_type"] in feed_types for a in today_dog)

    dog_status = {
        "walked_yesterday": walked_yesterday,
        "fed_yesterday": fed_yesterday,
        "walked_today": walked_today,
        "fed_today": fed_today,
    }

    # ------------------------------------------------------------------
    # 6. Weather
    # ------------------------------------------------------------------
    weather = await weather_task if weather_task is not None else None

    # ------------------------------------------------------------------
    # Build structured briefing
    # ------------------------------------------------------------------
    briefing = {
        "date": today_str,
        "generated_at": now_utc.isoformat(),
        "calendar_events": calendar_events,
        "tasks_due": tasks_due,
        "upcoming_birthdays": upcoming_birthdays,
        "medicine_today": medicine_today,
        "active_medicines": active_medicines,
        "dog_status": dog_status,
        "weather": weather,
        "message": _format_whatsapp_message(
            today_str,
            calendar_events,
            tasks_due,
            upcoming_birthdays,
            medicine_today,
            dog_status,
            weather,
        ),
    }

    return briefing


def _format_whatsapp_message(
    today_str: str,
    calendar_events: list[dict],
    tasks_due: list[dict],
    upcoming_birthdays: list[dict],
    medicine_today: list[dict],
    dog_status: dict,
    weather: dict | None,
) -> str:
    """Format the briefing as a plain-text WhatsApp message."""
    lines: list[str] = []
    lines.append(f"Good morning! Here's your briefing for {today_str}:")
    lines.append("")

    # Weather
    if weather:
        lines.append(f"WEATHER: {weather['description'].title()}")
        lines.append(f"High {weather['temp_high']}C / Low {weather['temp_low']}C")
        lines.append(f"Rain chance: {weather['rain_chance']}%")
        lines.append("")

    # Calendar
    if calendar_events:
        lines.append(f"CALENDAR ({len(calendar_events)} events):")
        for evt in calendar_events:
            if evt.get("all_day"):
                time_str = "All day"
            else:
                # Extract time from ISO timestamp
                try:
                    start_dt = datetime.fromisoformat(evt["start_time"])
                    time_str = start_dt.strftime("%H:%M")
                except (ValueError, KeyError):
                    time_str = evt.get("start_time", "?")
            location_str = f" @ {evt['location']}" if evt.get("location") else ""
            lines.append(f"  - {time_str} {evt['title']}{location_str}")
        lines.append("")

    # Tasks
    if tasks_due:
        overdue = [t for t in tasks_due if t.get("due_date") and t["due_date"] < today_str]
        today_tasks = [t for t in tasks_due if t.get("due_date") == today_str]

        if today_tasks:
            lines.append(f"TASKS DUE TODAY ({len(today_tasks)}):")
            for t in today_tasks:
                lines.append(f"  - {t['title']}")

        if overdue:
            lines.append(f"OVERDUE TASKS ({len(overdue)}):")
            for t in overdue:
                lines.append(f"  - {t['title']} (due {t['due_date']})")

        lines.append("")

    # Birthdays
    if upcoming_birthdays:
        lines.append("BIRTHDAYS:")
        for b in upcoming_birthdays:
            age = f" turns {b['turning_age']}" if b.get("turning_age") is not None else ""
            if b["days_until"] == 0:
                lines.append(f"  - TODAY! {b['person_name']}{age}")
            else:
                lines.append(
                    f"  - {b['person_name']}{age} in {b['days_until']} days"
                )
        lines.append("")

    # Dog
    dog_notes = []
    if not dog_status["walked_yesterday"]:
        dog_notes.append("NOT walked yesterday")
    if not dog_status["fed_yesterday"]:
        dog_notes.append("NOT fed yesterday")
    if dog_status["walked_today"]:
        dog_notes.append("Already walked today")
    if dog_status["fed_today"]:
        dog_notes.append("Already fed today")

    if dog_notes:
        lines.append("DOG:")
        for note in dog_notes:
            lines.append(f"  - {note}")
        lines.append("")

    # Medicine
    if medicine_today:
        lines.append(f"MEDICINE GIVEN TODAY ({len(medicine_today)}):")
        for m in medicine_today:
            child = m.get("child_name") or "unknown"
            try:
                given_dt = datetime.fromisoformat(m["given_at"])
                time_str = given_dt.strftime("%H:%M")
            except (ValueError, KeyError):
                time_str = "?"
            lines.append(f"  - {m['medicine_name']} for {child} at {time_str}")
        lines.append("")

    # If nothing at all
    if not calendar_events and not tasks_due and not upcoming_birthdays and not medicine_today:
        lines.append("Nothing special on the agenda today. Enjoy your day!")
        lines.append("")

    return "\n".join(lines).strip()
