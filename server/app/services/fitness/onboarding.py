"""Owner-private first-run setup with a deterministic preview/confirm boundary."""

import hashlib
import json
import uuid
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from dateutil.rrule import rrulestr

from app.models.fitness import GoalPayload, PlannedSessionPayload
from app.models.fitness_onboarding import (
    OnboardingConfirmRequest,
    OnboardingDraftUpdate,
    OnboardingPreviewRequest,
)
from app.services.calendar_recurrence import exception_keys_for_series, occurrence_key
from app.services.fitness.common import (
    FitnessConflictError,
    decoded_row,
    insert_owned,
    new_id,
    now_iso,
    owned_row,
    update_owned,
)
from app.services.fitness.planning import upsert_goal, upsert_planned_session
from app.services.idempotency import serialized_create


JSON_FIELDS = {
    "availability_json",
    "activities_json",
    "equipment_json",
    "food_preferences_json",
    "source_connections_json",
    "preview_json",
    "session_ids_json",
}
DAY_INDEX = {
    "Monday": 0,
    "Tuesday": 1,
    "Wednesday": 2,
    "Thursday": 3,
    "Friday": 4,
    "Saturday": 5,
    "Sunday": 6,
}
TIME_OPTIONS = {
    "Morning": (time(7), time(8), time(9)),
    "Lunchtime": (time(12), time(13)),
    "Evening": (time(17, 30), time(18, 30), time(19, 30)),
    "Flexible": (time(9), time(12, 30), time(18)),
}
ACTIVITY_DETAILS = {
    "Walking": ("walking", "Comfortable walk"),
    "Running": ("running", "Easy run"),
    "Strength": ("strength", "Full-body strength"),
    "Cycling": ("cycling", "Comfortable ride"),
    "Swimming": ("swimming", "Steady swim"),
    "Mobility": ("mobility", "Mobility session"),
}
OUTCOME_GOALS = {
    "Feel fitter": ("fitness", "activity.sessions_per_week", "Build a steady fitness habit"),
    "Build strength": ("strength", "strength.sessions_per_week", "Build strength consistently"),
    "Run further": ("running", "running.sessions_per_week", "Run consistently each week"),
    "Improve energy": ("wellbeing", "activity.sessions_per_week", "Move regularly for more energy"),
    "Support my weight": (
        "body",
        "activity.sessions_per_week",
        "Build a sustainable movement habit",
    ),
    "Move consistently": ("fitness", "activity.sessions_per_week", "Move consistently each week"),
}
EXISTING_FITNESS_DATA_TABLES = (
    "health_activities",
    "health_goals",
    "health_planned_sessions",
    "health_training_phases",
    "health_workout_definitions",
    "health_foods",
    "health_recipes",
    "health_food_log_entries",
    "health_body_measurements",
    "health_sleep_sessions",
    "health_recovery_observations",
    "health_body_issue_observations",
    "health_gear_items",
    "health_exercises",
    "health_training_programmes",
)


def _json_hash(value: dict) -> str:
    payload = json.dumps(value, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()


def _decoded_profile(row) -> dict:
    return decoded_row(row, json_fields=JSON_FIELDS)


def _draft_values(data: dict) -> dict:
    return {
        "main_outcome": data.get("main_outcome"),
        "availability": data.get("availability", []),
        "activities": data.get("activities", []),
        "equipment": data.get("equipment", []),
        "food_preferences": data.get("food_preferences", []),
        "source_connections": data.get("source_connections", []),
        "coach_style": data.get("coach_style"),
        "use_family_calendar": bool(data.get("use_family_calendar")),
        "use_household_meals": bool(data.get("use_household_meals")),
        "use_weather": bool(data.get("use_weather")),
        "memory_enabled": bool(data.get("memory_enabled")),
    }


def _profile_response(row) -> dict:
    data = _decoded_profile(row)
    preview_record = data.get("preview")
    preview = preview_record.get("week") if preview_record else None
    confirmation = None
    if data["status"] == "complete":
        confirmation = {
            "completed_at": data["confirmed_at"],
            "goal_id": data["goal_id"],
            "session_ids": data.get("session_ids", []),
        }
    return {
        "id": data["id"],
        "status": data["status"],
        **_draft_values(data),
        "preview": preview,
        "confirmation": confirmation,
    }


async def _owner_has_existing_fitness_data(db, *, user: dict) -> bool:
    """Treat prior Fitness use as established, including retained tombstones."""
    for table in EXISTING_FITNESS_DATA_TABLES:
        row = await (
            await db.execute(
                f"SELECT 1 FROM {table} WHERE family_id = ? AND owner_user_id = ? LIMIT 1",
                (user["family_id"], user["id"]),
            )
        ).fetchone()
        if row is not None:
            return True
    return False


async def ensure_profile(db, *, user: dict):
    row = await (
        await db.execute(
            "SELECT * FROM health_onboarding_profiles WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is not None:
        return row
    async with serialized_create(db):
        row = await (
            await db.execute(
                "SELECT * FROM health_onboarding_profiles WHERE family_id = ? "
                "AND owner_user_id = ? AND deleted_at IS NULL",
                (user["family_id"], user["id"]),
            )
        ).fetchone()
        if row is None:
            profile_id = new_id()
            initial_status = (
                "skipped" if await _owner_has_existing_fitness_data(db, user=user) else "draft"
            )
            await insert_owned(
                db,
                table="health_onboarding_profiles",
                record_id=profile_id,
                values={
                    "status": initial_status,
                    "availability_json": [],
                    "activities_json": [],
                    "equipment_json": [],
                    "food_preferences_json": [],
                    "source_connections_json": [],
                    "use_family_calendar": False,
                    "use_household_meals": False,
                    "use_weather": False,
                    "memory_enabled": False,
                    "session_ids_json": [],
                    "revision": 1,
                },
                user=user,
            )
            row = await owned_row(
                db,
                table="health_onboarding_profiles",
                record_id=profile_id,
                user=user,
            )
    return row


async def get_profile(db, *, user: dict) -> dict:
    return _profile_response(await ensure_profile(db, user=user))


async def save_draft(db, *, user: dict, body: OnboardingDraftUpdate) -> dict:
    row = await ensure_profile(db, user=user)
    if row["status"] == "complete":
        raise FitnessConflictError("Fitness setup is already complete")
    submitted = body.model_dump(
        exclude_unset=True,
        exclude={"client_id", "client_timestamp"},
    )
    values: dict = {}
    for key, value in submitted.items():
        target = (
            f"{key}_json"
            if key
            in {
                "availability",
                "activities",
                "equipment",
                "food_preferences",
                "source_connections",
            }
            else key
        )
        values[target] = value
    if values or row["status"] == "skipped":
        values.update(
            {
                "status": "draft",
                "preview_id": None,
                "preview_json": None,
                "preview_hash": None,
                "previewed_at": None,
            }
        )
        await update_owned(
            db,
            table="health_onboarding_profiles",
            record_id=row["id"],
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    return _profile_response(
        await owned_row(
            db,
            table="health_onboarding_profiles",
            record_id=row["id"],
            user=user,
        )
    )


async def skip_setup(db, *, user: dict) -> dict:
    row = await ensure_profile(db, user=user)
    if row["status"] == "complete":
        raise FitnessConflictError("Fitness setup is already complete")
    if row["status"] == "draft":
        await update_owned(
            db,
            table="health_onboarding_profiles",
            record_id=row["id"],
            values={
                "status": "skipped",
                "preview_id": None,
                "preview_json": None,
                "preview_hash": None,
                "previewed_at": None,
            },
            user=user,
        )
        row = await owned_row(
            db,
            table="health_onboarding_profiles",
            record_id=row["id"],
            user=user,
        )
    return _profile_response(row)


def _as_local_datetime(value: str, zone: ZoneInfo) -> datetime:
    if len(value) == 10:
        return datetime.combine(date.fromisoformat(value), time.min, tzinfo=zone)
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=zone)
    return parsed.astimezone(zone)


async def _family_calendar_intervals(
    db,
    *,
    family_id: str,
    range_start: datetime,
    range_end: datetime,
) -> list[tuple[datetime, datetime]]:
    rows = await (
        await db.execute(
            "SELECT id, start_time, end_time, all_day, recurrence_rule FROM calendar_events ce "
            "WHERE ce.family_id = ? AND ce.deleted_at IS NULL AND NOT EXISTS ("
            "SELECT 1 FROM calendar_events replacement "
            "WHERE replacement.overridden_event_id = ce.id "
            "AND replacement.family_id = ce.family_id AND replacement.deleted_at IS NULL)",
            (family_id,),
        )
    ).fetchall()
    excluded_occurrences = await exception_keys_for_series(
        db,
        family_id=family_id,
        series_ids=[row["id"] for row in rows if row["recurrence_rule"]],
    )
    zone = range_start.tzinfo
    intervals: list[tuple[datetime, datetime]] = []
    for row in rows:
        try:
            event_start = _as_local_datetime(row["start_time"], zone)
            if row["end_time"]:
                event_end = _as_local_datetime(row["end_time"], zone)
            elif row["all_day"] or len(row["start_time"]) == 10:
                event_end = event_start + timedelta(days=1)
            else:
                event_end = event_start + timedelta(hours=1)
            duration = max(event_end - event_start, timedelta(minutes=1))
            if row["recurrence_rule"]:
                rule = rrulestr(row["recurrence_rule"], dtstart=event_start)
                occurrences = rule.between(range_start - duration, range_end, inc=True)
            else:
                occurrences = [event_start]
            for occurrence in occurrences:
                all_day = bool(row["all_day"]) or len(row["start_time"]) == 10
                if (
                    row["recurrence_rule"]
                    and occurrence_key(occurrence, all_day=all_day)
                    in excluded_occurrences.get(row["id"], set())
                ):
                    continue
                occurrence = occurrence.astimezone(zone)
                occurrence_end = occurrence + duration
                if occurrence < range_end and occurrence_end > range_start:
                    intervals.append((occurrence, occurrence_end))
        except (TypeError, ValueError):
            continue
    return intervals


def _overlaps(
    start: datetime,
    end: datetime,
    intervals: list[tuple[datetime, datetime]],
) -> bool:
    return any(
        start < occupied_end and end > occupied_start for occupied_start, occupied_end in intervals
    )


def _week_start(requested: date | None) -> date:
    if requested is not None:
        return requested - timedelta(days=requested.weekday())
    today = date.today()
    days_until_monday = (7 - today.weekday()) % 7
    return today + timedelta(days=days_until_monday)


def _default_availability() -> list[dict]:
    return [
        {"day": "Monday", "time_of_day": "Morning", "duration_minutes": 30},
        {"day": "Wednesday", "time_of_day": "Evening", "duration_minutes": 30},
        {"day": "Saturday", "time_of_day": "Morning", "duration_minutes": 45},
    ]


def _default_activity(main_outcome: str | None) -> str:
    if main_outcome == "Build strength":
        return "Strength"
    if main_outcome == "Run further":
        return "Running"
    return "Walking"


async def preview_week(
    db,
    *,
    user: dict,
    body: OnboardingPreviewRequest,
) -> dict:
    row = await ensure_profile(db, user=user)
    if row["status"] == "complete":
        raise FitnessConflictError("Fitness setup is already complete")
    if row["status"] == "skipped":
        raise FitnessConflictError("Resume Fitness setup before previewing a week")
    data = _decoded_profile(row)
    draft = _draft_values(data)
    start_day = _week_start(body.week_start)
    settings = await (
        await db.execute(
            "SELECT timezone FROM health_user_settings WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    timezone_name = settings["timezone"] if settings else "Europe/London"
    try:
        zone = ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError:
        zone = ZoneInfo("Europe/London")
        timezone_name = "Europe/London"
    range_start = datetime.combine(start_day, time.min, tzinfo=zone)
    range_end = range_start + timedelta(days=7)
    occupied = (
        await _family_calendar_intervals(
            db,
            family_id=user["family_id"],
            range_start=range_start,
            range_end=range_end,
        )
        if draft["use_family_calendar"]
        else []
    )
    availability = draft["availability"] or _default_availability()
    availability = sorted(availability, key=lambda item: DAY_INDEX[item["day"]])[:3]
    activities = draft["activities"] or [_default_activity(draft["main_outcome"])]
    sessions: list[dict] = []
    public_sessions: list[dict] = []
    scheduled_intervals = list(occupied)
    for index, slot in enumerate(availability):
        session_day = start_day + timedelta(days=DAY_INDEX[slot["day"]])
        duration = int(slot["duration_minutes"])
        options = TIME_OPTIONS[slot["time_of_day"]]
        selected_start = None
        shifted = False
        for option_index, start_time in enumerate(options):
            candidate = datetime.combine(session_day, start_time, tzinfo=zone)
            candidate_end = candidate + timedelta(minutes=duration)
            if not _overlaps(candidate, candidate_end, scheduled_intervals):
                selected_start = candidate
                shifted = option_index > 0
                break
        if selected_start is None:
            for hour in range(6, 22):
                candidate = datetime.combine(session_day, time(hour), tzinfo=zone)
                candidate_end = candidate + timedelta(minutes=duration)
                if not _overlaps(candidate, candidate_end, scheduled_intervals):
                    selected_start = candidate
                    shifted = True
                    break
        if selected_start is None:
            continue
        activity = activities[index % len(activities)]
        sport_key, title = ACTIVITY_DETAILS[activity]
        reason = (
            "Fits around your family calendar."
            if shifted and draft["use_family_calendar"]
            else f"Matches your {slot['time_of_day'].lower()} availability."
        )
        public = {
            "day": slot["day"],
            "date": session_day.isoformat(),
            "start_time": selected_start.strftime("%H:%M"),
            "activity": activity,
            "title": title,
            "duration_minutes": duration,
            "reason": reason,
        }
        public_sessions.append(public)
        sessions.append(
            {
                **public,
                "sport_key": sport_key,
                "scheduled_start_utc": selected_start.astimezone(timezone.utc).isoformat(),
                "local_timezone": timezone_name,
            }
        )
        scheduled_intervals.append((selected_start, selected_start + timedelta(minutes=duration)))
    preview_id = str(
        uuid.uuid5(
            uuid.NAMESPACE_URL,
            "hausklar:onboarding:"
            + row["id"]
            + ":"
            + _json_hash(
                {
                    "draft": draft,
                    "week_start": start_day.isoformat(),
                    "sessions": public_sessions,
                }
            ),
        )
    )
    for index, session in enumerate(sessions):
        session["id"] = str(
            uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"hausklar:onboarding:{row['id']}:{preview_id}:session:{index}",
            )
        )
    outcome = draft["main_outcome"] or "Move consistently"
    goal_type, metric_key, goal_name = OUTCOME_GOALS[outcome]
    goal_id = str(
        uuid.uuid5(
            uuid.NAMESPACE_URL,
            f"hausklar:onboarding:{row['id']}:{preview_id}:goal",
        )
    )
    week = {
        "preview_id": preview_id,
        "week_start": start_day.isoformat(),
        "summary": f"A realistic first week with {len(sessions)} session{'s' if len(sessions) != 1 else ''}.",
        "sessions": public_sessions,
    }
    internal = {
        "draft_hash": _json_hash(draft),
        "week": week,
        "goal": {
            "id": goal_id,
            "goal_type": goal_type,
            "metric_key": metric_key,
            "name": goal_name,
            "target_value": len(sessions),
        },
        "sessions": sessions,
    }
    await update_owned(
        db,
        table="health_onboarding_profiles",
        record_id=row["id"],
        values={
            "preview_id": preview_id,
            "preview_json": internal,
            "preview_hash": _json_hash(internal),
            "previewed_at": now_iso(),
        },
        user=user,
    )
    return week


async def _validate_preview_calendar(db, *, user: dict, profile: dict, preview: dict) -> None:
    if not profile["use_family_calendar"]:
        return
    sessions = preview["sessions"]
    if not sessions:
        return
    zone = ZoneInfo(sessions[0]["local_timezone"])
    week_start = datetime.combine(
        date.fromisoformat(preview["week"]["week_start"]), time.min, tzinfo=zone
    )
    intervals = await _family_calendar_intervals(
        db,
        family_id=user["family_id"],
        range_start=week_start,
        range_end=week_start + timedelta(days=7),
    )
    for session in sessions:
        start = datetime.fromisoformat(session["scheduled_start_utc"]).astimezone(zone)
        end = start + timedelta(minutes=int(session["duration_minutes"]))
        if _overlaps(start, end, intervals):
            raise FitnessConflictError("Your calendar changed. Preview the week again")


def _confirm_response(row) -> dict:
    data = _decoded_profile(row)
    return {
        "status": "complete",
        "completed_at": data["confirmed_at"],
        "goal_id": data["goal_id"],
        "session_ids": data["session_ids"],
        "week": data["preview"]["week"],
    }


async def confirm_week(
    db,
    *,
    user: dict,
    body: OnboardingConfirmRequest,
) -> dict:
    profile_row = await ensure_profile(db, user=user)
    async with serialized_create(db):
        profile_row = await owned_row(
            db,
            table="health_onboarding_profiles",
            record_id=profile_row["id"],
            user=user,
        )
        profile = _decoded_profile(profile_row)
        if profile["status"] == "complete":
            if profile["preview_id"] != str(body.preview_id):
                raise FitnessConflictError("That setup preview is no longer current")
            return _confirm_response(profile_row)
        preview = profile.get("preview")
        if not preview or profile["preview_id"] != str(body.preview_id):
            raise FitnessConflictError("Preview the week before confirming it")
        if _json_hash(preview) != profile["preview_hash"]:
            raise FitnessConflictError("That setup preview is no longer valid")
        if preview["draft_hash"] != _json_hash(_draft_values(profile)):
            raise FitnessConflictError("Your setup changed. Preview the week again")
        await _validate_preview_calendar(
            db,
            user=user,
            profile=profile,
            preview=preview,
        )
        goal = preview["goal"]
        week_start = date.fromisoformat(preview["week"]["week_start"])
        await upsert_goal(
            db,
            user=user,
            record_id=goal["id"],
            body=GoalPayload(
                id=goal["id"],
                goal_type=goal["goal_type"],
                metric_key=goal["metric_key"],
                name=goal["name"],
                starts_on=week_start,
                target_date=week_start + timedelta(weeks=12),
                target_value=goal["target_value"],
                unit_key="sessions per week",
                priority=10,
                status="active",
            ),
        )
        session_ids: list[str] = []
        for session in preview["sessions"]:
            session_ids.append(session["id"])
            await upsert_planned_session(
                db,
                user=user,
                record_id=session["id"],
                body=PlannedSessionPayload(
                    id=session["id"],
                    sport_key=session["sport_key"],
                    title=session["title"],
                    local_timezone=session["local_timezone"],
                    status="accepted",
                    session_source="user",
                    scheduled_start_utc=session["scheduled_start_utc"],
                    expected_duration_s=int(session["duration_minutes"]) * 60,
                    priority=10,
                    movable=True,
                    visibility="private",
                    reason_for_placement=session["reason"],
                    goal_links=[{"goal_id": goal["id"], "role": "primary"}],
                ),
            )
        confirmed_at = now_iso()
        await update_owned(
            db,
            table="health_onboarding_profiles",
            record_id=profile["id"],
            values={
                "status": "complete",
                "confirmed_at": confirmed_at,
                "goal_id": goal["id"],
                "session_ids_json": session_ids,
            },
            user=user,
        )
        completed = await owned_row(
            db,
            table="health_onboarding_profiles",
            record_id=profile["id"],
            user=user,
        )
    return _confirm_response(completed)
