"""Compact family snapshot for widgets and quick-glance surfaces."""

import json

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.services.calendar_recurrence import expand_calendar_rows
from app.services.medicine import evaluate_dose_safety
from app.services.photos import photo_memories

_MAX_SOURCE_EVENTS = 200
_MAX_EVENTS = 10
_MAX_TASKS = 10

_DOG_CARE_DEFAULTS = {
    "name": "Dog",
    "breakfast_window_start": "07:00",
    "breakfast_window_end": "09:00",
    "walk_window_start": "10:00",
    "walk_window_end": "14:00",
    "dinner_window_start": "17:00",
    "dinner_window_end": "19:00",
}


def _zone(timezone_name: str) -> ZoneInfo:
    try:
        return ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("Europe/London")


async def medicine_glance(
    db,
    *,
    family_id: str,
    now: datetime | None = None,
) -> list[dict]:
    """Return only medicine items needing quick family context.

    This is shared by the compact widget glance and the full Today aggregate
    so the latter does not repeat the calendar, task, meal, and photo work.
    """
    reference = now or datetime.now(timezone.utc)
    recent_cutoff = (reference - timedelta(hours=24)).isoformat()
    rows = await (
        await db.execute(
            """
            SELECT mt.id, mt.child_id, mt.name, mt.min_hours_between_doses,
                   mt.max_doses_24h, c.name AS child_name,
                   MAX(md.given_at) AS last_given_at
            FROM illnesses i
            JOIN children c ON c.id = i.child_id
              AND c.family_id = i.family_id AND c.deleted_at IS NULL
            JOIN medicine_types mt ON mt.child_id = i.child_id
              AND mt.family_id = i.family_id AND mt.deleted_at IS NULL
            JOIN medicine_doses md ON md.medicine_type_id = mt.id
              AND md.child_id = mt.child_id AND md.family_id = mt.family_id
              AND md.deleted_at IS NULL AND md.given_at >= ?
            WHERE i.family_id = ? AND i.deleted_at IS NULL AND i.ended_at IS NULL
            GROUP BY mt.id, mt.child_id, mt.name, mt.min_hours_between_doses,
                     mt.max_doses_24h, c.name
            ORDER BY c.name, mt.name, mt.id
            """,
            (recent_cutoff, family_id),
        )
    ).fetchall()
    if not rows:
        return []

    medicine_type_ids = [str(row["id"]) for row in rows]
    placeholders = ",".join("?" for _ in medicine_type_ids)
    dose_rows = await (
        await db.execute(
            "SELECT medicine_type_id, child_id, given_at FROM medicine_doses "
            f"WHERE family_id = ? AND medicine_type_id IN ({placeholders}) "
            "AND deleted_at IS NULL ORDER BY medicine_type_id, given_at",
            (family_id, *medicine_type_ids),
        )
    ).fetchall()
    dose_times: dict[tuple[str, str], list[str]] = {}
    for dose in dose_rows:
        dose_times.setdefault(
            (str(dose["medicine_type_id"]), str(dose["child_id"])), []
        ).append(str(dose["given_at"]))

    medicine: list[dict] = []
    for row in rows:
        is_safe, warnings = evaluate_dose_safety(
            min_hours_between_doses=row["min_hours_between_doses"],
            max_doses_24h=row["max_doses_24h"],
            existing_given_at=dose_times.get(
                (str(row["id"]), str(row["child_id"])), []
            ),
            given_at=reference,
        )
        next_safe_at = max(
            (warning.next_safe_at for warning in warnings if warning.next_safe_at),
            default=None,
        )
        medicine.append(
            {
                "child_id": row["child_id"],
                "child_name": row["child_name"],
                "medicine_type_id": row["id"],
                "medicine_name": row["name"],
                "next_safe_at": next_safe_at,
                "is_safe_now": is_safe,
                "last_given_at": row["last_given_at"],
            }
        )
    return medicine


async def active_naps_glance(db, *, family_id: str) -> list[dict]:
    """Return the small set of naps that still need a parent's attention."""
    cursor = await db.execute(
        """
        SELECT n.id, n.child_id, c.name AS child_name, n.started_at, n.sleep_type
        FROM naps n
        JOIN children c
          ON c.id = n.child_id
         AND c.family_id = n.family_id
         AND c.deleted_at IS NULL
        WHERE n.family_id = ?
          AND n.deleted_at IS NULL
          AND n.ended_at IS NULL
          AND n.sleep_type = 'nap'
        ORDER BY julianday(n.started_at), n.id
        LIMIT 4
        """,
        (family_id,),
    )
    return [dict(row) for row in await cursor.fetchall()]


def _dog_care_state(
    *,
    completed: bool,
    local_now: datetime,
    start_value: str,
    end_value: str,
) -> str:
    if completed:
        return "done"
    try:
        start = datetime.strptime(start_value, "%H:%M").time()
        end = datetime.strptime(end_value, "%H:%M").time()
    except (TypeError, ValueError):
        return "upcoming"
    current = local_now.timetz().replace(tzinfo=None)
    if current < start:
        return "upcoming"
    if current <= end:
        return "due"
    return "overdue"


async def dog_care_glance(
    db,
    *,
    family_id: str,
    local_now: datetime,
) -> dict | None:
    """Return today's dog-care state without copying activity history into glance."""
    profile_cursor = await db.execute(
        """
        SELECT name, breakfast_window_start, breakfast_window_end,
               walk_window_start, walk_window_end,
               dinner_window_start, dinner_window_end
        FROM dog_profiles
        WHERE family_id = ? AND deleted_at IS NULL
        LIMIT 1
        """,
        (family_id,),
    )
    profile_row = await profile_cursor.fetchone()
    profile = _DOG_CARE_DEFAULTS | (dict(profile_row) if profile_row else {})

    local_day_start = datetime.combine(
        local_now.date(), datetime.min.time(), tzinfo=local_now.tzinfo
    )
    day_start = local_day_start.astimezone(timezone.utc)
    day_end = (local_day_start + timedelta(days=1)).astimezone(timezone.utc)
    activity_cursor = await db.execute(
        """
        SELECT activity_type,
               MAX(CASE
                     WHEN julianday(started_at) >= julianday(?)
                      AND julianday(started_at) < julianday(?)
                      AND (activity_type != 'walk' OR is_active = 0)
                     THEN 1 ELSE 0
                   END) AS occurred_today
        FROM dog_activities
        WHERE family_id = ?
          AND deleted_at IS NULL
          AND activity_type IN ('walk', 'feed_breakfast', 'feed_dinner')
        GROUP BY activity_type
        """,
        (day_start.isoformat(), day_end.isoformat(), family_id),
    )
    activity_rows = await activity_cursor.fetchall()
    if profile_row is None and not activity_rows:
        return None
    completed = {
        row["activity_type"]: bool(row["occurred_today"])
        for row in activity_rows
    }

    active_cursor = await db.execute(
        """
        SELECT id
        FROM dog_activities
        WHERE family_id = ? AND deleted_at IS NULL
          AND activity_type = 'walk' AND is_active = 1
        ORDER BY julianday(started_at) DESC
        LIMIT 1
        """,
        (family_id,),
    )
    active_walk = await active_cursor.fetchone()

    def state(label: str, activity_type: str) -> str:
        return _dog_care_state(
            completed=completed.get(activity_type, False),
            local_now=local_now,
            start_value=profile[f"{label}_window_start"],
            end_value=profile[f"{label}_window_end"],
        )

    return {
        "dog_name": profile["name"],
        "active_walk_id": active_walk["id"] if active_walk else None,
        "breakfast_state": state("breakfast", "feed_breakfast"),
        "walk_state": state("walk", "walk"),
        "dinner_state": state("dinner", "feed_dinner"),
    }


async def star_chart_glance(db, *, family_id: str) -> dict | None:
    """Return one active chart for a safe, review-first ambient entry point."""
    cursor = await db.execute(
        """
        SELECT sc.id AS chart_id, sc.child_id, c.name AS child_name, sc.title,
               sc.grid_rows * sc.grid_columns AS total_cells,
               COUNT(s.id) AS stars_count
        FROM star_charts sc
        JOIN children c
          ON c.id = sc.child_id
         AND c.family_id = sc.family_id
         AND c.deleted_at IS NULL
        LEFT JOIN star_chart_stars s
          ON s.chart_id = sc.id
         AND s.family_id = sc.family_id
         AND s.deleted_at IS NULL
        WHERE sc.family_id = ?
          AND sc.deleted_at IS NULL
          AND sc.completed_at IS NULL
        GROUP BY sc.id, sc.child_id, c.name, sc.title,
                 sc.grid_rows, sc.grid_columns
        ORDER BY COALESCE(MAX(s.awarded_at), sc.updated_at, sc.created_at) DESC,
                 sc.id
        LIMIT 1
        """,
        (family_id,),
    )
    row = await cursor.fetchone()
    return dict(row) if row else None


async def family_glance(db, *, family_id: str, timezone_name: str) -> dict:
    zone = _zone(timezone_name)
    now = datetime.now(timezone.utc)
    local_now = now.astimezone(zone)
    today = local_now.date()
    day_start = datetime.combine(today, datetime.min.time(), tzinfo=zone)
    tomorrow_start = day_start + timedelta(days=1)
    window_end = day_start + timedelta(days=2)

    # Widen the SQL bounds by a day either side: stored times mix "Z"/offset/
    # naive forms, so a coarse string prefilter can't be exact. The zone-aware
    # Python windowing in _expand_occurrences does the precise filtering.
    sql_lower = (day_start - timedelta(days=1)).date().isoformat()
    sql_upper = (window_end + timedelta(days=1)).date().isoformat()
    cursor = await db.execute(
        """
        SELECT id, title, start_time, all_day, recurrence_rule, assigned_to,
               family_member_ids
        FROM calendar_events
        WHERE family_id = ? AND deleted_at IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM calendar_events replacement
              WHERE replacement.overridden_event_id = calendar_events.id
                AND replacement.family_id = calendar_events.family_id
                AND replacement.deleted_at IS NULL
          )
          AND (
              (start_time >= ? AND start_time < ?)
              OR (recurrence_rule IS NOT NULL AND start_time < ?)
          )
        ORDER BY start_time
        LIMIT ?
        """,
        (
            family_id,
            sql_lower,
            sql_upper,
            sql_upper,
            _MAX_SOURCE_EVENTS,
        ),
    )
    event_rows = [dict(row) for row in await cursor.fetchall()]
    expanded_events = await expand_calendar_rows(
        db,
        family_id=family_id,
        rows=event_rows,
        range_start=day_start,
        range_end=window_end,
        max_occurrences_per_series=10,
    )
    occurrences_by_event: dict[str, list] = {}
    for occurrence in expanded_events:
        occurrences_by_event.setdefault(occurrence.row["id"], []).append(occurrence)

    cursor = await db.execute(
        """
        SELECT id, name FROM users WHERE family_id = ? AND deleted_at IS NULL
        UNION ALL
        SELECT id, name FROM children WHERE family_id = ? AND deleted_at IS NULL
        """,
        (family_id, family_id),
    )
    names = {row["id"]: row["name"] for row in await cursor.fetchall()}

    today_events: list[dict] = []
    tomorrow_events: list[dict] = []
    for row in event_rows:
        participant_ids = []
        if row["assigned_to"]:
            participant_ids.append(row["assigned_to"])
        try:
            stored_ids = json.loads(row["family_member_ids"] or "[]")
        except (TypeError, json.JSONDecodeError):
            stored_ids = []
        participant_ids.extend(
            person_id for person_id in stored_ids
            if isinstance(person_id, str) and person_id not in participant_ids
        )
        participant_names = [names[person_id] for person_id in participant_ids if person_id in names]
        all_day = bool(row["all_day"]) or len(row["start_time"]) == 10
        for expanded in occurrences_by_event.get(row["id"], []):
            occurrence = expanded.start.astimezone(zone)
            item = {
                "id": (
                    f"{row['id']}::{expanded.key}"
                    if expanded.generated
                    else row["id"]
                ),
                "title": row["title"],
                "start_time": occurrence.date().isoformat() if all_day else occurrence.isoformat(),
                "all_day": all_day,
                "person_name": " & ".join(participant_names) or None,
            }
            if occurrence < tomorrow_start:
                today_events.append(item)
            else:
                tomorrow_events.append(item)
    today_events.sort(key=lambda item: item["start_time"])
    tomorrow_events.sort(key=lambda item: item["start_time"])

    cursor = await db.execute(
        """
        SELECT id, title, due_date
        FROM tasks
        WHERE family_id = ? AND deleted_at IS NULL AND completed_at IS NULL
          AND due_date IS NOT NULL AND due_date < ?
        ORDER BY due_date
        LIMIT ?
        """,
        (family_id, tomorrow_start.date().isoformat(), _MAX_TASKS),
    )
    tasks_due = [
        {"id": row["id"], "title": row["title"], "due_date": row["due_date"][:10]}
        for row in await cursor.fetchall()
    ]

    cursor = await db.execute(
        """
        SELECT COALESCE(m.name, mp.notes) AS title
        FROM meal_plans mp
        LEFT JOIN meals m ON m.id = mp.meal_id AND m.deleted_at IS NULL
        WHERE mp.family_id = ? AND mp.deleted_at IS NULL
          AND mp.date = ? AND mp.meal_type = 'dinner'
        LIMIT 1
        """,
        (family_id, today.isoformat()),
    )
    dinner_row = await cursor.fetchone()
    dinner = {"title": dinner_row["title"]} if dinner_row and dinner_row["title"] else None

    medicine = await medicine_glance(db, family_id=family_id, now=now)
    active_naps = await active_naps_glance(db, family_id=family_id)
    dog_care = await dog_care_glance(
        db,
        family_id=family_id,
        local_now=local_now,
    )
    star_chart = await star_chart_glance(db, family_id=family_id)

    memories = await photo_memories(timezone_name=timezone_name)
    memory = None
    if memories:
        memory = {key: memories[0][key] for key in ("asset_id", "taken_at", "years_ago")}

    return {
        "generated_at": now.isoformat(),
        "date": today.isoformat(),
        "events": today_events[:_MAX_EVENTS],
        "tasks_due": tasks_due,
        "dinner": dinner,
        "medicine": medicine,
        "active_naps": active_naps,
        "dog_care": dog_care,
        "star_chart": star_chart,
        "memory": memory,
        "tomorrow": {
            "first_event": tomorrow_events[0] if tomorrow_events else None,
            "event_count": len(tomorrow_events),
        },
    }
