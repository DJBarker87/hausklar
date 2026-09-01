"""Action-first owner-private Fitness responses for everyday client screens."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.fitness_experience import (
    FitnessCoachNudge,
    FitnessExperienceAction,
    FitnessExperienceSession,
    FitnessOverviewFact,
    FitnessOverviewResponse,
    FitnessSafetyAdjustment,
    FitnessTodayCardResponse,
    FitnessTodayNutrition,
)
from app.models.fitness_next_action import FitnessNextAction
from app.services.fitness import nutrition, planning, workspace
from app.services.fitness.next_action import next_action_for_user


ACTIVE_PLAN_STATUSES = {"accepted", "scheduled", "in_progress"}


@dataclass(frozen=True)
class _ExperienceContext:
    day: date
    settings: dict
    plans: list[dict]
    active_activity: dict | None
    has_completed_activity: bool


def _as_utc(value: str | None) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _zone(settings: dict) -> ZoneInfo:
    try:
        return ZoneInfo(settings["timezone"])
    except (KeyError, ValueError, ZoneInfoNotFoundError):
        return ZoneInfo("Europe/London")


def _plan_occurs_on_day(
    plan: dict,
    *,
    day: date,
    zone: ZoneInfo,
    day_start_utc: datetime,
    day_end_utc: datetime,
) -> bool:
    if plan.get("scheduled_date") == day.isoformat():
        return True
    scheduled = _as_utc(plan.get("scheduled_start_utc"))
    if scheduled is not None and scheduled.astimezone(zone).date() == day:
        return True
    window_start = _as_utc(plan.get("time_window_start_utc"))
    window_end = _as_utc(plan.get("time_window_end_utc"))
    if window_start is not None and window_end is not None:
        return window_start < day_end_utc and window_end > day_start_utc
    if window_start is not None:
        return window_start.astimezone(zone).date() == day
    if window_end is not None:
        return window_end.astimezone(zone).date() == day
    return False


async def _context_for_user(db, *, user: dict, requested_day: date | None) -> _ExperienceContext:
    settings = await planning.ensure_settings(db, user=user)
    zone = _zone(settings)
    day = requested_day or datetime.now(timezone.utc).astimezone(zone).date()
    local_start = datetime.combine(day, time.min, tzinfo=zone)
    local_end = local_start + timedelta(days=1)
    day_start_utc = local_start.astimezone(timezone.utc)
    day_end_utc = local_end.astimezone(timezone.utc)
    # The compact surfaces need only the small session header for this day.
    # Hydrating every historical plan (including exercises, sets, goals and
    # gear) made Overview cost grow with the owner's entire training history.
    # Bound the candidate set in SQLite, then retain the timezone-aware Python
    # predicate as the source of truth for edge cases around local midnight.
    plan_rows = await (
        await db.execute(
            "SELECT id, title, sport_key, status, scheduled_start_utc, scheduled_date, "
            "time_window_start_utc, time_window_end_utc, expected_duration_s, movable, "
            "completion_activity_id FROM health_planned_sessions "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
            "AND status IN ('accepted','scheduled','in_progress') AND ("
            "scheduled_date = ? OR "
            "(scheduled_start_utc IS NOT NULL AND datetime(scheduled_start_utc) >= datetime(?) "
            "AND datetime(scheduled_start_utc) < datetime(?)) OR "
            "(time_window_start_utc IS NOT NULL AND time_window_end_utc IS NOT NULL "
            "AND datetime(time_window_start_utc) < datetime(?) "
            "AND datetime(time_window_end_utc) > datetime(?)) OR "
            "(time_window_start_utc IS NOT NULL AND time_window_end_utc IS NULL "
            "AND datetime(time_window_start_utc) >= datetime(?) "
            "AND datetime(time_window_start_utc) < datetime(?)) OR "
            "(time_window_start_utc IS NULL AND time_window_end_utc IS NOT NULL "
            "AND datetime(time_window_end_utc) >= datetime(?) "
            "AND datetime(time_window_end_utc) < datetime(?))) "
            "ORDER BY COALESCE(scheduled_start_utc, scheduled_date, time_window_start_utc), "
            "created_at LIMIT 50",
            (
                user["family_id"],
                user["id"],
                day.isoformat(),
                day_start_utc.isoformat(),
                day_end_utc.isoformat(),
                day_end_utc.isoformat(),
                day_start_utc.isoformat(),
                day_start_utc.isoformat(),
                day_end_utc.isoformat(),
                day_start_utc.isoformat(),
                day_end_utc.isoformat(),
            ),
        )
    ).fetchall()
    plans = [
        dict(row)
        for row in plan_rows
        if _plan_occurs_on_day(
            dict(row),
            day=day,
            zone=zone,
            day_start_utc=day_start_utc,
            day_end_utc=day_end_utc,
        )
    ]
    activity_context_row = await (
        await db.execute(
            "WITH active AS ("
            "SELECT id, title, sport_key, status, planned_session_id, started_at_utc "
            "FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
            "AND status = 'in_progress' AND deleted_at IS NULL "
            "ORDER BY started_at_utc DESC LIMIT 1"
            ") SELECT active.id, active.title, active.sport_key, active.status, "
            "active.planned_session_id, active.started_at_utc, "
            "EXISTS(SELECT 1 FROM health_activities completed "
            "WHERE completed.family_id = ? AND completed.owner_user_id = ? "
            "AND completed.deleted_at IS NULL "
            "AND completed.status IN ('completed','partially_completed') AND ("
            "completed.local_calendar_date = ? OR (completed.local_calendar_date IS NULL "
            "AND datetime(completed.started_at_utc) >= datetime(?) "
            "AND datetime(completed.started_at_utc) < datetime(?)))) "
            "AS has_completed_activity "
            "FROM (SELECT 1) seed LEFT JOIN active ON 1 = 1",
            (
                user["family_id"],
                user["id"],
                user["family_id"],
                user["id"],
                day.isoformat(),
                day_start_utc.isoformat(),
                day_end_utc.isoformat(),
            ),
        )
    ).fetchone()
    activity_context = dict(activity_context_row)
    has_completed_activity = bool(activity_context.pop("has_completed_activity"))
    active_activity = activity_context if activity_context.get("id") is not None else None
    if active_activity is not None:
        from app.services.fitness.strength import close_expired_strength_sessions

        closed = await close_expired_strength_sessions(
            db,
            user=user,
            candidate_rows=[active_activity],
        )
        if closed:
            plans = [plan for plan in plans if plan.get("completion_activity_id") not in closed]
            active_activity = None
    if day != datetime.now(timezone.utc).astimezone(zone).date():
        active_activity = None
    return _ExperienceContext(
        day=day,
        settings=settings,
        plans=plans,
        active_activity=active_activity,
        has_completed_activity=has_completed_activity,
    )


def _minutes(seconds: object) -> int | None:
    if seconds is None:
        return None
    return max(0, round(float(seconds) / 60))


def _session(context: _ExperienceContext) -> FitnessExperienceSession | None:
    if context.active_activity is not None:
        activity = context.active_activity
        return FitnessExperienceSession(
            id=activity["id"],
            kind="active_activity",
            title=activity["title"],
            sport_key=activity["sport_key"],
            status="in_progress",
            starts_at=activity.get("started_at_utc"),
            scheduled_date=context.day,
            duration_minutes=None,
            movable=False,
        )
    if not context.plans:
        return None
    plan = context.plans[0]
    return FitnessExperienceSession(
        id=plan["id"],
        kind="planned_session",
        title=plan["title"],
        sport_key=plan["sport_key"],
        status=plan["status"],
        starts_at=plan.get("scheduled_start_utc") or plan.get("time_window_start_utc"),
        scheduled_date=plan.get("scheduled_date") or context.day,
        duration_minutes=_minutes(plan.get("expected_duration_s")),
        movable=bool(plan.get("movable")),
    )


def _session_actions(
    session: FitnessExperienceSession | None,
) -> tuple[FitnessExperienceAction | None, FitnessExperienceAction | None]:
    if session is None:
        return None, None
    if session.kind == "active_activity":
        return (
            FitnessExperienceAction(
                kind="resume_activity",
                label="Resume",
                destination="plan",
                target_id=session.id,
            ),
            None,
        )
    # HausKlar has a real in-app start flow for strength. Other sports open the
    # exact accepted session; labelling that action "Start" would promise a
    # tracker the clients do not provide.
    primary_kind = (
        "start_session"
        if session.sport_key == "strength" and session.status != "in_progress"
        else "open_session"
    )
    primary = FitnessExperienceAction(
        kind=primary_kind,
        label="Open" if primary_kind == "open_session" else "Start",
        destination="plan",
        target_id=session.id,
    )
    secondary = (
        FitnessExperienceAction(
            kind="move_session",
            label="Move",
            destination="plan",
            target_id=session.id,
        )
        if session.movable
        else None
    )
    return primary, secondary


def _consumer_action(action) -> FitnessExperienceAction:
    mapped = {
        "open_body_issue": ("open_body_issue", "log"),
        "record_readiness": ("record_readiness", "log"),
        "open_recovery": ("open_recovery", "progress"),
        "open_coach": ("open_coach", "coach"),
        "open_planned_session": ("open_session", "plan"),
        "open_today": ("open_overview", "overview"),
    }
    kind, destination = mapped[action.kind]
    return FitnessExperienceAction(
        kind=kind,
        label=action.label,
        destination=destination,
        target_id=action.target if action.target != "today" else None,
    )


def _quick_actions(
    *,
    session: FitnessExperienceSession | None,
    next_action: FitnessNextAction,
    outcome: str,
) -> list[FitnessExperienceAction]:
    actions: list[FitnessExperienceAction] = []
    if session is not None and next_action.action.kind == "record_readiness":
        actions.append(_consumer_action(next_action.action))
    if outcome == "Support my weight":
        actions.append(
            FitnessExperienceAction(
                kind="log_food",
                label="Log food",
                destination="log",
            )
        )
    return actions


async def _outcome_for_user(db, *, user: dict) -> str:
    onboarding = await (
        await db.execute(
            "SELECT main_outcome FROM health_onboarding_profiles "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
            "AND main_outcome IS NOT NULL ORDER BY updated_at DESC LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if onboarding is not None:
        return onboarding["main_outcome"]

    goal = await (
        await db.execute(
            "SELECT goal_type, metric_key FROM health_goals "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
            "AND status = 'active' ORDER BY priority DESC, updated_at DESC LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if goal is not None:
        goal_type = str(goal["goal_type"] or "").lower()
        metric_key = str(goal["metric_key"] or "").lower()
        if "strength" in goal_type or "strength" in metric_key:
            return "Build strength"
        if "run" in goal_type or "run" in metric_key:
            return "Run further"
        if "energy" in goal_type or "sleep" in metric_key or goal_type == "wellbeing":
            return "Improve energy"
        if goal_type == "body" or "weight" in metric_key:
            return "Support my weight"
    # The neutral fallback is movement consistency. It must never expose diet
    # or weight merely because those records happen to exist.
    return "Move consistently"


async def _completed_activity_summary(
    db,
    *,
    user: dict,
    start_utc: datetime,
    end_utc: datetime,
    sport_key: str | None = None,
) -> dict:
    sport_clause = " AND sport_key = ?" if sport_key else ""
    params: tuple = (
        user["family_id"],
        user["id"],
        start_utc.isoformat(),
        end_utc.isoformat(),
    )
    if sport_key:
        params = (*params, sport_key)
    row = await (
        await db.execute(
            "SELECT COUNT(*) AS sessions, "
            "COUNT(DISTINCT COALESCE(local_calendar_date, date(started_at_utc))) AS active_days, "
            "COALESCE(SUM(distance_m), 0) AS distance_m FROM health_activities "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
            "AND status IN ('completed','partially_completed') "
            "AND datetime(started_at_utc) >= datetime(?) "
            "AND datetime(started_at_utc) < datetime(?)" + sport_clause,
            params,
        )
    ).fetchone()
    return dict(row)


def _session_count(count: int, noun: str = "session") -> str:
    return f"{count} {noun if count == 1 else noun + 's'} this week"


async def _focus_for_user(
    db,
    *,
    user: dict,
    context: _ExperienceContext,
    outcome: str,
) -> FitnessOverviewFact:
    zone = _zone(context.settings)
    week_start = context.day - timedelta(days=context.day.weekday())
    local_start = datetime.combine(week_start, time.min, tzinfo=zone)
    start_utc = local_start.astimezone(timezone.utc)
    end_utc = (local_start + timedelta(days=7)).astimezone(timezone.utc)

    if outcome == "Build strength":
        summary = await _completed_activity_summary(
            db,
            user=user,
            start_utc=start_utc,
            end_utc=end_utc,
            sport_key="strength",
        )
        return FitnessOverviewFact(
            outcome=outcome,
            label="Strength this week",
            value=_session_count(int(summary["sessions"]), "session"),
            detail="A simple view of the work supporting your strength goal.",
            destination="progress",
        )

    if outcome == "Run further":
        summary = await _completed_activity_summary(
            db,
            user=user,
            start_utc=start_utc,
            end_utc=end_utc,
            sport_key="running",
        )
        distance_km = float(summary["distance_m"] or 0) / 1_000
        value = (
            f"{distance_km:.1f} km this week"
            if distance_km > 0
            else _session_count(int(summary["sessions"]), "run")
        )
        return FitnessOverviewFact(
            outcome=outcome,
            label="Running this week",
            value=value,
            detail="Distance appears when a completed run includes it.",
            destination="progress",
        )

    if outcome == "Improve energy":
        sleep = await (
            await db.execute(
                "SELECT AVG(duration_s) AS average_s, COUNT(*) AS nights "
                "FROM health_sleep_sessions WHERE family_id = ? AND owner_user_id = ? "
                "AND deleted_at IS NULL AND datetime(sleep_start_utc) >= datetime(?) "
                "AND datetime(sleep_start_utc) < datetime(?)",
                (
                    user["family_id"],
                    user["id"],
                    (end_utc - timedelta(days=7)).isoformat(),
                    end_utc.isoformat(),
                ),
            )
        ).fetchone()
        if sleep is not None and int(sleep["nights"] or 0) > 0:
            minutes = round(float(sleep["average_s"] or 0) / 60)
            value = f"{minutes // 60}h {minutes % 60:02d}m average sleep"
            detail = f"Across {int(sleep['nights'])} recent night{'s' if int(sleep['nights']) != 1 else ''}."
        else:
            summary = await _completed_activity_summary(
                db,
                user=user,
                start_utc=start_utc,
                end_utc=end_utc,
            )
            value = _session_count(int(summary["active_days"]), "active day")
            detail = "Sleep will appear here after a connected source provides it."
        return FitnessOverviewFact(
            outcome=outcome,
            label="Energy support",
            value=value,
            detail=detail,
            destination="progress",
        )

    if outcome == "Support my weight":
        measurement = await (
            await db.execute(
                "SELECT value, unit_key FROM health_body_measurements "
                "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
                "AND metric_key = 'body.weight' AND canonical_state = 'canonical' "
                "ORDER BY measured_at_utc DESC LIMIT 1",
                (user["family_id"], user["id"]),
            )
        ).fetchone()
        if measurement is not None:
            value = f"{float(measurement['value']):g} {measurement['unit_key']}"
            label = "Latest weight"
            detail = "Shown because supporting your weight is your chosen outcome."
        else:
            summary = await _completed_activity_summary(
                db,
                user=user,
                start_utc=start_utc,
                end_utc=end_utc,
            )
            value = _session_count(int(summary["active_days"]), "active day")
            label = "Movement this week"
            detail = "A gentle starting point for your chosen outcome."
        return FitnessOverviewFact(
            outcome=outcome,
            label=label,
            value=value,
            detail=detail,
            destination="progress",
        )

    summary = await _completed_activity_summary(
        db,
        user=user,
        start_utc=start_utc,
        end_utc=end_utc,
    )
    return FitnessOverviewFact(
        outcome=outcome,
        label="Movement this week",
        value=_session_count(int(summary["active_days"]), "active day"),
        detail="A calm measure of consistency across the week.",
        destination="progress",
    )


async def overview_for_user(
    db,
    *,
    user: dict,
    day: date | None = None,
) -> FitnessOverviewResponse:
    context = await _context_for_user(db, user=user, requested_day=day)
    session = _session(context)
    primary_action, secondary_action = _session_actions(session)
    next_action = await next_action_for_user(
        db,
        user=user,
        day=context.day,
        settings_row=context.settings,
        planned_sessions=context.plans,
    )
    outcome = await _outcome_for_user(db, user=user)
    focus = await _focus_for_user(
        db,
        user=user,
        context=context,
        outcome=outcome,
    )
    if primary_action is None:
        primary_action = _consumer_action(next_action.action)
        if primary_action.kind == "open_overview":
            primary_action = FitnessExperienceAction(
                kind="create_session",
                label="Plan a session",
                destination="plan",
            )

    coach_nudge = None
    if session is None and next_action.action.kind == "open_coach":
        coach_nudge = FitnessCoachNudge(
            title=next_action.title,
            message=next_action.body,
            action=_consumer_action(next_action.action),
        )

    safety_adjustment = None
    if (
        session is not None
        and next_action.action.kind == "open_body_issue"
        and next_action.urgency in {"attention", "urgent"}
    ):
        safety_adjustment = FitnessSafetyAdjustment(
            title=next_action.title,
            message=next_action.body,
            action=_consumer_action(next_action.action),
        )

    return FitnessOverviewResponse(
        date=context.day,
        focus=focus,
        session=session,
        primary_action=primary_action,
        secondary_action=secondary_action,
        quick_actions=_quick_actions(
            session=session,
            next_action=next_action,
            outcome=outcome,
        ),
        coach_nudge=coach_nudge,
        safety_adjustment=safety_adjustment,
    )


async def today_card_for_user(
    db,
    *,
    user: dict,
    day: date | None = None,
) -> FitnessTodayCardResponse:
    preference = await workspace.get_workspace(db, user=user, persist=False)
    if not preference["enabled"]:
        return FitnessTodayCardResponse(
            date=day or datetime.now(timezone.utc).astimezone(ZoneInfo("Europe/London")).date()
        )
    context = await _context_for_user(db, user=user, requested_day=day)
    session = _session(context)
    primary_action, secondary_action = _session_actions(session)
    local_today = datetime.now(timezone.utc).astimezone(_zone(context.settings)).date()
    if (
        context.day == local_today
        and session is None
        and not context.has_completed_activity
    ):
        primary_action = FitnessExperienceAction(
            kind="start_strength",
            label="Start workout",
            destination="plan",
        )
    nutrition_summary = None
    if preference["show_nutrition_today"]:
        diary = await nutrition.list_food_log(db, user=user, nutrition_date=context.day)
        known = diary["known_subtotals"]
        targets = diary["targets"]
        completeness = diary["nutrient_completeness"]
        nutrition_summary = FitnessTodayNutrition(
            calories_kcal=float(known.get("calories_kcal") or 0),
            calorie_target_kcal=targets.get("calories_kcal"),
            protein_g=float(known.get("protein_g") or 0),
            protein_target_g=targets.get("protein_g"),
            entry_count=len(diary["entries"]),
            calories_complete=completeness.get("calories_kcal", 1.0) == 1.0,
            protein_complete=completeness.get("protein_g", 1.0) == 1.0,
        )
    return FitnessTodayCardResponse(
        date=context.day,
        has_completed_activity_today=context.has_completed_activity,
        session=session,
        primary_action=primary_action,
        secondary_action=secondary_action,
        nutrition=nutrition_summary,
    )
