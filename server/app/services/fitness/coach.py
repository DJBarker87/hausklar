"""Owner-scoped evidence, inert drafts, and confirmed Fitness Coach writes."""

from __future__ import annotations

import json
import re
from datetime import date, datetime, timedelta, timezone
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from dateutil.rrule import rrulestr
from pydantic import ValidationError

from app.config import settings
from app.models.calendar import CalendarEventCreate
from app.models.fitness import (
    GoalPatch,
    PlannedExercisePayload,
    PlannedSessionGoalLinkPayload,
    PlannedSessionPayload,
    WorkoutDefinitionPayload,
    WorkoutVersionPayload,
)
from app.models.fitness_analysis import (
    AnalysisDateRange,
    AnalysisQueryPayload,
    SavedAnalysisChartPayload,
)
from app.models.fitness_coach import (
    PROPOSAL_PAYLOAD_MODELS,
    CoachCalendarChangePayload,
    CoachChartPayload,
    CoachContextPreferencesResponse,
    CoachContextPreferencesUpdate,
    CoachConversationCreate,
    CoachConversationDetail,
    CoachConversationResponse,
    CoachEvidence,
    CoachFamilyCalendarEventPayload,
    CoachFamilyTaskPayload,
    CoachFitnessReminderPayload,
    CoachGoalAdjustmentPayload,
    CoachMessageRequest,
    CoachMemoryClearResponse,
    CoachMemoryCreate,
    CoachMemoryPatch,
    CoachMemoryResponse,
    CoachMemorySettingResponse,
    CoachNutritionChangePayload,
    CoachPlannedMealLogPayload,
    CoachProposalDecision,
    CoachProposalDestination,
    CoachProposalUndoDecision,
    CoachRecommendationFeedback,
    CoachRunWorkoutPayload,
    CoachShoppingListPayload,
    CoachStrengthWorkoutPayload,
    CoachTrainingWeekPayload,
)
from app.models.fitness_household_meals import PlannedMealLogRequest
from app.models.meal import ShoppingItemCreate
from app.models.task import TaskCreate
from app.services.create_records import (
    create_or_replay_calendar_event,
    create_or_replay_shopping_item,
    create_or_replay_task,
)
from app.services.calendar_recurrence import exception_keys_for_series, occurrence_key
from app.services.fitness import (
    activities as fitness_activities,
    analysis,
    household_meals,
    nutrition,
    onboarding,
    planning,
    run_plans,
    templates,
)
from app.services.fitness.common import (
    FitnessConflictError,
    FitnessNotFoundError,
    decoded_row,
    insert_owned,
    json_text,
    new_id,
    now_iso,
    owned_row,
    save_owned_rows_history,
    soft_delete_owned,
    update_owned,
    validate_owned_reference,
)
from app.services.fitness.strength import resolve_exercise_id, resolve_setup_id
from app.services.family_people import family_person_type
from app.services.record_history import save_history
from app.services.weather import get_weather_summary
from app.services.facilities import weights_room_availability


PROPOSAL_KINDS = set(PROPOSAL_PAYLOAD_MODELS)
MAX_EVIDENCE_ITEMS = 12
MAX_FAMILY_CALENDAR_ROWS = 500
MAX_FAMILY_CALENDAR_OCCURRENCES = 40
MAX_RECENT_ACTIVITY_ROWS = 20
MAX_DETAILED_RECENT_ACTIVITY_ROWS = 3
MAX_ACTIVITY_SPLITS_PER_DETAIL = 50
MAX_ACTIVITY_ANALYSES_PER_DETAIL = 15


async def _rows(db, query: str, params: tuple = ()) -> list[dict]:
    return [dict(row) for row in await (await db.execute(query, params)).fetchall()]


def _reference(body: CoachMessageRequest) -> tuple[datetime, date]:
    try:
        zone = ZoneInfo(body.timezone)
    except ZoneInfoNotFoundError:
        zone = ZoneInfo("Europe/London")
    try:
        parsed = datetime.fromisoformat((body.client_now or "").replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=zone)
        reference = parsed.astimezone(zone)
    except ValueError:
        reference = datetime.now(timezone.utc).astimezone(zone)
    return reference, reference.date()


def _bundle(
    *,
    identifier: str,
    kind: str,
    label: str,
    summary: str,
    facts: Any,
    source_ids: list[str],
    start: date | None = None,
    end: date | None = None,
    sample_size: int | None = None,
    completeness: float | None = None,
) -> dict:
    public = CoachEvidence(
        id=identifier,
        kind=kind,
        label=label,
        summary=summary,
        period={"start": start.isoformat(), "end": end.isoformat()} if start and end else None,
        sample_size=sample_size,
        completeness=completeness,
        source_ids=source_ids[:50],
    ).model_dump(mode="json", exclude_none=True)
    return {"public": public, "facts": facts}


async def _goals_and_phase(db, *, user: dict, today: date) -> dict | None:
    goals = await _rows(
        db,
        "SELECT id, goal_type, metric_key, name, current_value, target_value, unit_key, "
        "starts_on, target_date, priority FROM health_goals WHERE family_id = ? "
        "AND owner_user_id = ? AND status = 'active' AND deleted_at IS NULL "
        "ORDER BY priority DESC, target_date LIMIT 10",
        (user["family_id"], user["id"]),
    )
    phases = await _rows(
        db,
        "SELECT id, phase_type, name, starts_on, ends_on, running_priorities_json, "
        "strength_priorities_json, accepted_tradeoffs_json FROM health_training_phases "
        "WHERE family_id = ? AND owner_user_id = ? AND active = 1 AND starts_on <= ? "
        "AND (ends_on IS NULL OR ends_on >= ?) AND deleted_at IS NULL "
        "ORDER BY starts_on DESC LIMIT 1",
        (user["family_id"], user["id"], today.isoformat(), today.isoformat()),
    )
    if not goals and not phases:
        return None
    for phase in phases:
        for key in (
            "running_priorities_json",
            "strength_priorities_json",
            "accepted_tradeoffs_json",
        ):
            try:
                phase[key.removesuffix("_json")] = json.loads(phase.pop(key) or "[]")
            except json.JSONDecodeError:
                phase[key.removesuffix("_json")] = []
    return _bundle(
        identifier="active-goals-phase",
        kind="goals_phase",
        label="Active goals and phase",
        summary=f"{len(goals)} active goals and {len(phases)} current training phase.",
        facts={"goals": goals, "active_phase": phases[0] if phases else None},
        source_ids=[item["id"] for item in goals + phases],
        sample_size=len(goals) + len(phases),
        completeness=1.0,
    )


async def _schedule(db, *, user: dict, today: date) -> dict | None:
    end = today + timedelta(days=14)
    plans = await _rows(
        db,
        "SELECT id, sport_key, title, status, scheduled_start_utc, scheduled_date, "
        "time_window_start_utc, time_window_end_utc, expected_duration_s, "
        "expected_distance_m, movable, workout_version_id FROM health_planned_sessions "
        "WHERE family_id = ? AND owner_user_id = ? AND status IN "
        "('proposed','accepted','scheduled','in_progress') AND deleted_at IS NULL "
        "AND COALESCE(scheduled_date, substr(scheduled_start_utc,1,10), "
        "substr(time_window_start_utc,1,10), ?) BETWEEN ? AND ? "
        "ORDER BY COALESCE(scheduled_start_utc, scheduled_date, time_window_start_utc) LIMIT 20",
        (
            user["family_id"],
            user["id"],
            today.isoformat(),
            today.isoformat(),
            end.isoformat(),
        ),
    )
    if not plans:
        return None
    executable = [
        plan for plan in plans if plan["status"] in {"accepted", "scheduled", "in_progress"}
    ]
    proposed = [plan for plan in plans if plan["status"] == "proposed"]
    return _bundle(
        identifier="training-schedule",
        kind="calendar",
        label="Training schedule and proposed drafts",
        summary=(
            f"{len(executable)} accepted, scheduled or in-progress sessions and "
            f"{len(proposed)} proposed review-only drafts in the next fortnight."
        ),
        facts={
            "planned_sessions": plans,
            "executable_sessions": executable,
            "proposed_review_only": proposed,
        },
        source_ids=[item["id"] for item in plans],
        start=today,
        end=end,
        sample_size=len(plans),
        completeness=1.0,
    )


async def _plan_outcomes(db, *, user: dict, today: date) -> dict | None:
    """Bounded planned-versus-completed evidence for explicit Coach requests."""
    start = today - timedelta(days=83)
    rows = await _rows(
        db,
        "SELECT p.id AS planned_session_id, p.title AS planned_title, "
        "p.sport_key, p.scheduled_start_utc, p.scheduled_date, "
        "p.expected_duration_s, p.expected_distance_m, p.completion_state, "
        "a.id AS activity_id, a.title AS activity_title, a.started_at_utc, "
        "a.timer_duration_s AS completed_duration_s, "
        "a.distance_m AS completed_distance_m, l.match_method, l.confidence, "
        "l.user_confirmed, l.explanation AS match_explanation "
        "FROM health_planned_sessions p JOIN health_plan_activity_links l "
        "ON l.planned_session_id = p.id AND l.family_id = p.family_id "
        "AND l.owner_user_id = p.owner_user_id AND l.active = 1 "
        "AND l.deleted_at IS NULL JOIN health_activities a ON a.id = l.activity_id "
        "AND a.family_id = p.family_id AND a.owner_user_id = p.owner_user_id "
        "AND a.deleted_at IS NULL WHERE p.family_id = ? AND p.owner_user_id = ? "
        "AND p.deleted_at IS NULL AND COALESCE(p.scheduled_date, "
        "substr(p.scheduled_start_utc,1,10), substr(a.started_at_utc,1,10)) "
        "BETWEEN ? AND ? ORDER BY a.started_at_utc DESC LIMIT 12",
        (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
    )
    if not rows:
        return None
    for item in rows:
        item["user_confirmed"] = bool(item["user_confirmed"])
        ratios = []
        if item["expected_distance_m"] and item["completed_distance_m"]:
            ratios.append(
                float(item["completed_distance_m"])
                / float(item["expected_distance_m"])
            )
        if item["expected_duration_s"] and item["completed_duration_s"]:
            ratios.append(
                float(item["completed_duration_s"])
                / float(item["expected_duration_s"])
            )
        overall = sum(ratios) / len(ratios) if ratios else None
        item["adherence"] = {
            "status": (
                "complete"
                if overall is not None and 0.9 <= overall <= 1.1
                else "partial"
            ),
            "algorithm_version": "coach-plan-outcome-v1",
            "completed_distance_m": item["completed_distance_m"],
            "planned_distance_m": item["expected_distance_m"],
            "completed_duration_s": item["completed_duration_s"],
            "planned_duration_s": item["expected_duration_s"],
            "explanation": item["completion_state"],
        }
    complete = sum(item["adherence"].get("status") == "complete" for item in rows)
    return _bundle(
        identifier="plan-outcomes",
        kind="plan_outcomes",
        label="Planned session outcomes",
        summary=(
            f"{len(rows)} recent planned sessions matched to completed activity; "
            f"{complete} met the saved duration or distance closely."
        ),
        facts={"plan_outcomes": rows},
        source_ids=[
            identifier
            for item in rows
            for identifier in (item["planned_session_id"], item["activity_id"])
        ],
        start=start,
        end=today,
        sample_size=len(rows),
        completeness=1.0,
    )


async def _cycle_context(db, *, user: dict, today: date) -> dict | None:
    """Return only the authenticated adult's bounded cycle history."""
    rows = await _rows(
        db,
        "SELECT cs.id AS settings_id, cs.cycle_length_days, "
        "cs.show_period_starts, cs.show_predicted_period, "
        "cs.show_estimated_ovulation, cs.share_period_starts_with_adults, "
        "cs.share_predicted_period_with_adults, "
        "cs.share_estimated_ovulation_with_adults, "
        "ps.id AS period_id, ps.started_on "
        "FROM health_cycle_settings cs "
        "LEFT JOIN health_cycle_period_starts ps ON ps.family_id = cs.family_id "
        "AND ps.owner_user_id = cs.owner_user_id AND ps.deleted_at IS NULL "
        "WHERE cs.family_id = ? AND cs.owner_user_id = ? AND cs.deleted_at IS NULL "
        "ORDER BY ps.started_on DESC LIMIT 24",
        (user["family_id"], user["id"]),
    )
    if not rows:
        return None
    first = rows[0]
    settings = {
        key: first[key]
        for key in (
            "cycle_length_days",
            "show_period_starts",
            "show_predicted_period",
            "show_estimated_ovulation",
            "share_period_starts_with_adults",
            "share_predicted_period_with_adults",
            "share_estimated_ovulation_with_adults",
        )
    }
    for key in tuple(settings):
        if key != "cycle_length_days":
            settings[key] = bool(settings[key])
    period_starts = [
        {"id": item["period_id"], "started_on": item["started_on"]}
        for item in rows
        if item["period_id"]
    ]
    oldest = (
        date.fromisoformat(period_starts[-1]["started_on"])
        if period_starts
        else today
    )
    return _bundle(
        identifier="owner-cycle-history",
        kind="cycle",
        label="Owner-private cycle history",
        summary=(
            f"{len(period_starts)} recorded period starts for the authenticated adult; "
            "this is private factual context, not medical advice."
        ),
        facts={"settings": settings, "period_starts": period_starts},
        source_ids=[
            first["settings_id"],
            *[item["id"] for item in period_starts],
        ],
        start=oldest,
        end=today,
        sample_size=len(period_starts),
        completeness=1.0,
    )


async def _nutrition(db, *, user: dict, today: date) -> dict | None:
    start = today - timedelta(days=13)
    totals = await (
        await db.execute(
            "SELECT COUNT(*) AS entries, COUNT(calories_kcal) AS calories_present, "
            "COUNT(protein_g) AS protein_present, COUNT(fibre_g) AS fibre_present, "
            "SUM(calories_kcal) AS calories, SUM(protein_g) AS protein, "
            "SUM(fibre_g) AS fibre, COUNT(DISTINCT nutrition_date) AS logged_days "
            "FROM health_food_log_entries WHERE family_id = ? AND owner_user_id = ? "
            "AND nutrition_date BETWEEN ? AND ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
        )
    ).fetchone()
    entries = int(totals["entries"] or 0)
    if not entries:
        return None
    contributors = await _rows(
        db,
        "SELECT COALESCE(f.id, r.id, 'unknown') AS id, "
        "COALESCE(f.name, r.name, 'Unknown item') AS name, COUNT(*) AS entries, "
        "SUM(l.calories_kcal) AS known_calories_kcal, "
        "SUM(l.protein_g) AS known_protein_g "
        "FROM health_food_log_entries l "
        "LEFT JOIN health_food_versions fv ON fv.id = l.food_version_id "
        "AND fv.family_id = l.family_id "
        "LEFT JOIN health_foods f ON f.id = fv.food_id AND f.family_id = l.family_id "
        "AND (f.owner_user_id = l.owner_user_id OR f.household_shared = 1) "
        "AND f.deleted_at IS NULL "
        "LEFT JOIN health_recipe_versions rv ON rv.id = l.recipe_version_id "
        "AND rv.family_id = l.family_id "
        "LEFT JOIN health_recipes r ON r.id = rv.recipe_id AND r.family_id = l.family_id "
        "AND (r.owner_user_id = l.owner_user_id OR r.household_shared = 1) "
        "AND r.deleted_at IS NULL "
        "WHERE l.family_id = ? AND l.owner_user_id = ? AND l.nutrition_date BETWEEN ? AND ? "
        "AND l.deleted_at IS NULL GROUP BY COALESCE(f.id,r.id,'unknown') "
        "ORDER BY SUM(l.calories_kcal) DESC LIMIT 8",
        (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
    )
    completeness = (
        min(
            int(totals["calories_present"] or 0),
            int(totals["protein_present"] or 0),
        )
        / entries
    )
    calories_complete = int(totals["calories_present"] or 0) == entries
    protein_complete = int(totals["protein_present"] or 0) == entries
    fibre_complete = int(totals["fibre_present"] or 0) == entries
    facts = {
        "period_totals": {
            "calories_kcal": totals["calories"] if calories_complete else None,
            "protein_g": totals["protein"] if protein_complete else None,
            "fibre_g": totals["fibre"] if fibre_complete else None,
            "known_calories_kcal": totals["calories"],
            "known_protein_g": totals["protein"],
            "known_fibre_g": totals["fibre"],
            "calories_complete": calories_complete,
            "protein_complete": protein_complete,
            "fibre_complete": fibre_complete,
            "logged_days": totals["logged_days"],
            "entries": entries,
        },
        "top_contributors": contributors,
    }
    return _bundle(
        identifier="nutrition-summary",
        kind="nutrition",
        label="Nutrition summary and contributors",
        summary=(
            f"{entries} private diary entries across {int(totals['logged_days'] or 0)} "
            "days; missing nutrients remain missing."
        ),
        facts=facts,
        source_ids=[item["id"] for item in contributors if item["id"] != "unknown"],
        start=start,
        end=today,
        sample_size=entries,
        completeness=completeness,
    )


async def _body_recovery(db, *, user: dict, today: date) -> dict | None:
    start = today - timedelta(days=27)
    weights = await _rows(
        db,
        "SELECT id, substr(measured_at_utc,1,10) AS date, value, measurement_quality "
        "FROM health_body_measurements WHERE family_id = ? AND owner_user_id = ? "
        "AND metric_key = 'body.weight_kg' AND canonical_state = 'canonical' "
        "AND deleted_at IS NULL AND substr(measured_at_utc,1,10) BETWEEN ? AND ? "
        "ORDER BY measured_at_utc DESC LIMIT 20",
        (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
    )
    sleep = await _rows(
        db,
        "SELECT id, substr(sleep_end_utc,1,10) AS date, duration_s, source_quality "
        "FROM health_sleep_sessions WHERE family_id = ? AND owner_user_id = ? "
        "AND deleted_at IS NULL AND substr(sleep_end_utc,1,10) BETWEEN ? AND ? "
        "ORDER BY sleep_end_utc DESC LIMIT 20",
        (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
    )
    recovery = await _rows(
        db,
        "SELECT id, metric_key, substr(observed_at_utc,1,10) AS date, value_number, "
        "unit_key, source_quality FROM health_recovery_observations WHERE family_id = ? "
        "AND owner_user_id = ? AND deleted_at IS NULL "
        "AND substr(observed_at_utc,1,10) BETWEEN ? AND ? "
        "ORDER BY observed_at_utc DESC LIMIT 30",
        (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
    )
    readiness = await _rows(
        db,
        "SELECT id, activity_id, substr(captured_at_utc,1,10) AS date, readiness_1_5, "
        "energy_1_5, soreness_1_5, motivation_1_5 FROM health_session_checkins "
        "WHERE family_id = ? AND owner_user_id = ? AND timing = 'pre' "
        "AND capture_quality = 'contemporaneous' AND captured_before_activity_start = 1 "
        "AND deleted_at IS NULL AND substr(captured_at_utc,1,10) BETWEEN ? AND ? "
        "ORDER BY captured_at_utc DESC LIMIT 20",
        (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
    )
    records = weights + sleep + recovery + readiness
    if not records:
        return None
    return _bundle(
        identifier="body-recovery-readiness",
        kind="recovery",
        label="Weight, sleep, recovery and pre-session readiness",
        summary=(
            f"{len(weights)} canonical weights, {len(sleep)} sleep sessions, "
            f"{len(recovery)} recovery observations and {len(readiness)} "
            "contemporaneous pre-session check-ins."
        ),
        facts={
            "canonical_weights": weights,
            "sleep": sleep,
            "recovery": recovery,
            "contemporaneous_readiness": readiness,
        },
        source_ids=[item["id"] for item in records],
        start=start,
        end=today,
        sample_size=len(records),
        completeness=1.0,
    )


async def _body_issues(db, *, user: dict, today: date) -> dict | None:
    start = today - timedelta(days=60)
    issues = await _rows(
        db,
        "SELECT id, activity_id, session_exercise_id, substr(observed_at_utc,1,10) AS date, "
        "timing, issue_type_key, body_location_key, side, severity_0_10, "
        "changed_session, session_change_key, trend_key, status "
        "FROM health_body_issue_observations WHERE family_id = ? AND owner_user_id = ? "
        "AND deleted_at IS NULL AND (status = 'active' OR changed_session = 1) "
        "AND substr(observed_at_utc,1,10) BETWEEN ? AND ? "
        "ORDER BY observed_at_utc DESC LIMIT 12",
        (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
    )
    if not issues:
        return None
    return _bundle(
        identifier="current-body-issues",
        kind="body_issue",
        label="Current body-issue observations",
        summary=f"{len(issues)} recent structured observations; these are not diagnoses.",
        facts={"observations": issues},
        source_ids=[item["id"] for item in issues],
        start=start,
        end=today,
        sample_size=len(issues),
        completeness=1.0,
    )


async def _activities_and_gear(
    db,
    *,
    user: dict,
    today: date,
    recent_limit: int = MAX_RECENT_ACTIVITY_ROWS,
    detailed_limit: int = MAX_DETAILED_RECENT_ACTIVITY_ROWS,
    focus_activity_ids: list[str] | None = None,
) -> dict | None:
    fallback_start = today - timedelta(days=83)
    activity_select = (
        "SELECT id, sport_key, sub_sport_key, title, started_at_utc, ended_at_utc, "
        "local_timezone, COALESCE(local_calendar_date, substr(started_at_utc,1,10)) AS date, "
        "elapsed_duration_s, timer_duration_s, moving_duration_s, distance_m, energy_kcal, "
        "workout_classification, session_rpe, perceived_performance, measurement_quality, "
        "phase_id, planned_session_id, matched_plan_key, notes "
        "FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
        "AND status = 'completed' AND deleted_at IS NULL "
    )
    bounded_recent_limit = min(max(recent_limit, 1), MAX_RECENT_ACTIVITY_ROWS)
    requested_focus_ids = list(dict.fromkeys(focus_activity_ids or []))
    focus_rows: list[dict] = []
    if requested_focus_ids:
        placeholders = ",".join("?" for _ in requested_focus_ids)
        focus_rows = await _rows(
            db,
            activity_select
            + f"AND id IN ({placeholders}) ORDER BY started_at_utc DESC",
            (user["family_id"], user["id"], *requested_focus_ids),
        )

    proximity_ids: list[str] = []
    if focus_rows:
        anchor = focus_rows[0]["started_at_utc"]
        # Explicit activity review is anchored to the selected session rather
        # than "now". This keeps older sessions alongside their nearest
        # training neighbours while retaining the same bounded row limit.
        activities = await _rows(
            db,
            activity_select
            + "ORDER BY ABS(julianday(started_at_utc) - julianday(?)), "
            "started_at_utc DESC LIMIT ?",
            (user["family_id"], user["id"], anchor, bounded_recent_limit),
        )
        proximity_ids = [item["id"] for item in activities]
        activities.sort(key=lambda item: item["started_at_utc"], reverse=True)
    else:
        activities = await _rows(
            db,
            activity_select
            + "AND substr(started_at_utc,1,10) <= ? "
            "ORDER BY started_at_utc DESC LIMIT ?",
            (
                user["family_id"],
                user["id"],
                today.isoformat(),
                bounded_recent_limit,
            ),
        )
    for activity in activities:
        activity["title"] = activity["title"][:300]
        activity["notes"] = activity["notes"][:500] if activity["notes"] else None
        activity["detail_level"] = "summary"
    gear = await _rows(
        db,
        "SELECT g.id, g.name, g.gear_type_key, g.default_for_sport_key, "
        "g.active, g.retired_at, "
        "COUNT(DISTINCT l.activity_id) AS activity_count, SUM(a.distance_m) AS distance_m "
        "FROM health_gear_items g LEFT JOIN health_activity_gear_links l ON l.gear_id = g.id "
        "AND l.family_id = g.family_id AND l.owner_user_id = g.owner_user_id "
        "AND l.deleted_at IS NULL LEFT JOIN health_activities a ON a.id = l.activity_id "
        "AND a.family_id = g.family_id AND a.owner_user_id = g.owner_user_id "
        "AND a.deleted_at IS NULL WHERE g.family_id = ? AND g.owner_user_id = ? "
        "AND g.deleted_at IS NULL GROUP BY g.id ORDER BY MAX(a.started_at_utc) DESC LIMIT 20",
        (user["family_id"], user["id"]),
    )
    if not activities and not gear:
        return None
    sensor_session_count = 0
    split_count = 0
    detail_ids: list[str] = []
    if activities:
        bounded_detail_limit = min(
            max(detailed_limit, 1), MAX_DETAILED_RECENT_ACTIVITY_ROWS
        )
        available_ids = {item["id"] for item in activities}
        focused_ids = [
            item["id"] for item in focus_rows if item["id"] in available_ids
        ]
        detail_candidates = focused_ids + [
            identifier
            for identifier in (proximity_ids or [item["id"] for item in activities])
            if identifier not in focused_ids
        ]
        detail_ids = detail_candidates[:bounded_detail_limit]
        placeholders = ",".join("?" for _ in detail_ids)
        scoped = (user["family_id"], user["id"], *detail_ids)
        metrics = await _rows(
            db,
            "SELECT activity_id, metric_key, value_number, unit_key, quality "
            "FROM health_activity_summary_metrics WHERE family_id = ? "
            f"AND owner_user_id = ? AND activity_id IN ({placeholders}) "
            "AND metric_key IN ('speed.average_mps','speed.maximum_mps',"
            "'running.average_pace_s_per_km',"
            "'heart_rate.average_bpm','heart_rate.maximum_bpm',"
            "'cadence.average_spm','power.average_w','power.maximum_w',"
            "'elevation.gain_m','elevation.minimum_m','elevation.maximum_m') "
            "AND deleted_at IS NULL "
            "ORDER BY activity_id, metric_key",
            scoped,
        )
        intervals: list[dict] = []
        findings: list[dict] = []
        for activity_id in detail_ids:
            interval_candidates = await _rows(
                db,
                "SELECT activity_id, sequence, interval_kind, label, start_offset_ms, "
                "end_offset_ms, start_distance_m, end_distance_m, metrics_json "
                "FROM health_activity_intervals WHERE family_id = ? AND owner_user_id = ? "
                "AND activity_id = ? AND interval_kind IN ('source_lap','kilometre_split') "
                "AND deleted_at IS NULL ORDER BY sequence, start_offset_ms LIMIT 120",
                (user["family_id"], user["id"], activity_id),
            )
            kilometre_splits = [
                item
                for item in interval_candidates
                if item["interval_kind"] == "kilometre_split"
            ]
            selected_intervals = kilometre_splits or [
                item
                for item in interval_candidates
                if item["interval_kind"] == "source_lap"
            ]
            intervals.extend(selected_intervals[:MAX_ACTIVITY_SPLITS_PER_DETAIL])
            findings.extend(
                await _rows(
                    db,
                    "SELECT activity_id, analysis_key, status, result_json "
                    "FROM health_activity_analysis_results WHERE family_id = ? "
                    "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL "
                    "ORDER BY analysis_key LIMIT ?",
                    (
                        user["family_id"],
                        user["id"],
                        activity_id,
                        MAX_ACTIVITY_ANALYSES_PER_DETAIL,
                    ),
                )
            )
        available = await _rows(
            db,
            "SELECT DISTINCT activity_id, metric_key FROM health_activity_metric_index "
            "WHERE family_id = ? AND owner_user_id = ? "
            f"AND activity_id IN ({placeholders}) AND deleted_at IS NULL "
            "ORDER BY activity_id, metric_key",
            scoped,
        )
        for interval in intervals:
            try:
                interval["metrics"] = json.loads(interval.pop("metrics_json") or "{}")
            except (TypeError, json.JSONDecodeError):
                interval["metrics"] = {}
        for finding in findings:
            try:
                finding["result"] = json.loads(finding.pop("result_json") or "{}")
            except (TypeError, json.JSONDecodeError):
                finding["result"] = {}
        for activity in activities:
            identifier = activity["id"]
            if identifier not in detail_ids:
                continue
            activity["detail_level"] = "detailed"
            activity["summary_metrics"] = [
                {key: value for key, value in item.items() if key != "activity_id"}
                for item in metrics
                if item["activity_id"] == identifier
            ]
            activity["available_sample_metric_keys"] = [
                item["metric_key"] for item in available if item["activity_id"] == identifier
            ]
            activity["laps_and_splits"] = [
                {key: value for key, value in item.items() if key != "activity_id"}
                for item in intervals
                if item["activity_id"] == identifier
            ]
            activity["analysis_findings"] = [
                {key: value for key, value in item.items() if key != "activity_id"}
                for item in findings
                if item["activity_id"] == identifier
            ]
            if activity["available_sample_metric_keys"]:
                sensor_session_count += 1
            split_count += len(activity["laps_and_splits"])
    automatic_comparison = None
    if focus_rows:
        automatic_comparison = await fitness_activities.previous_similar_run(
            db,
            user=user,
            activity_id=focus_rows[0]["id"],
        )
    return _bundle(
        identifier="recent-activities-gear",
        kind="activity",
        label=(
            "Focused activity and surrounding training"
            if focus_rows
            else "Recent activities and gear use"
        ),
        summary=(
            f"{len(activities)} completed activities and {len(gear)} owner-private gear records; "
            f"{'the selected activity and its nearest sessions' if focus_rows else f'the newest {len(detail_ids)} activities'} "
            "include bounded detail with "
            f"{sensor_session_count} sampled sessions and {split_count} laps or splits."
        ),
        facts={
            "activity_detail_scope": {
                "ordered_newest_first": True,
                "focus_activity_ids": [item["id"] for item in focus_rows],
                "selection": (
                    "nearest_to_focused_activity" if focus_rows else "most_recent"
                ),
                "detailed_activity_count": len(detail_ids),
                "older_activity_count": max(0, len(activities) - len(detail_ids)),
                "note": (
                    "Detailed rows contain saved summaries, selected laps or kilometre splits, "
                    "and calculated analysis; older rows retain compact activity facts."
                ),
            },
            "recent_activities": activities,
            "automatic_previous_similar_run": automatic_comparison,
            "gear_usage": gear,
        },
        source_ids=[item["id"] for item in activities + gear],
        start=(
            min(date.fromisoformat(item["date"]) for item in activities)
            if activities
            else fallback_start
        ),
        end=(
            max(date.fromisoformat(item["date"]) for item in activities)
            if focus_rows and activities
            else today
        ),
        sample_size=len(activities),
        completeness=1.0,
    )


async def _strength_context(db, *, user: dict, today: date) -> dict | None:
    library = await _rows(
        db,
        "SELECT e.id, e.name, e.movement_pattern_key, e.measurement_mode, "
        "e.load_entry_mode, e.rep_count_mode, s.id AS setup_id, s.name AS setup_name, "
        "s.location, COALESCE(s.load_entry_mode,e.load_entry_mode) AS setup_load_mode "
        "FROM health_exercises e JOIN health_exercise_setups s ON s.exercise_id = e.id "
        "AND s.family_id = e.family_id AND s.owner_user_id = e.owner_user_id "
        "AND s.active = 1 AND s.deleted_at IS NULL WHERE e.family_id = ? "
        "AND e.owner_user_id = ? AND e.active = 1 AND e.merged_into_exercise_id IS NULL "
        "AND e.deleted_at IS NULL ORDER BY e.favourite DESC, e.name, s.is_default DESC LIMIT 40",
        (user["family_id"], user["id"]),
    )
    start = today - timedelta(days=83)
    progress = await _rows(
        db,
        "SELECT e.id AS exercise_id, e.name AS exercise_name, setup.id AS setup_id, "
        "setup.name AS setup_name, COUNT(DISTINCT g.id) AS logical_sets, "
        "MAX(c.normalized_external_load_kg) AS observed_load_kg, MAX(a.started_at_utc) AS latest_at "
        "FROM health_strength_set_groups g JOIN health_strength_session_exercises se "
        "ON se.id = g.session_exercise_id AND se.family_id = g.family_id "
        "AND se.owner_user_id = g.owner_user_id AND se.deleted_at IS NULL "
        "JOIN health_activities a ON a.id = g.activity_id AND a.family_id = g.family_id "
        "AND a.owner_user_id = g.owner_user_id AND a.deleted_at IS NULL "
        "JOIN health_exercises e ON e.id = se.exercise_id AND e.family_id = g.family_id "
        "AND e.owner_user_id = g.owner_user_id AND e.deleted_at IS NULL "
        "JOIN health_exercise_setups setup ON setup.id = se.exercise_setup_id "
        "AND setup.family_id = g.family_id AND setup.owner_user_id = g.owner_user_id "
        "AND setup.deleted_at IS NULL LEFT JOIN health_strength_sets c ON c.set_group_id = g.id "
        "AND c.family_id = g.family_id AND c.owner_user_id = g.owner_user_id "
        "AND c.component_status IN ('completed','partial') AND c.deleted_at IS NULL "
        "WHERE g.family_id = ? AND g.owner_user_id = ? AND g.status IN ('completed','partial') "
        "AND g.training_role IN ('working','backoff','test') AND g.deleted_at IS NULL "
        "AND substr(a.started_at_utc,1,10) BETWEEN ? AND ? GROUP BY e.id, setup.id "
        "ORDER BY MAX(a.started_at_utc) DESC LIMIT 30",
        (user["family_id"], user["id"], start.isoformat(), today.isoformat()),
    )
    if not library and not progress:
        return None
    return _bundle(
        identifier="strength-library-progress",
        kind="strength",
        label="Canonical strength library and observed progress",
        summary=f"{len(library)} compatible exercise/setup choices and {len(progress)} recent progress rows.",
        facts={"canonical_library": library, "observed_progress": progress},
        source_ids=[item["id"] for item in library] + [item["exercise_id"] for item in progress],
        start=start,
        end=today,
        sample_size=len(progress),
        completeness=1.0,
    )


async def _prior_recommendations(db, *, user: dict) -> dict | None:
    items = await _rows(
        db,
        "SELECT id, recommendation_type, recommendation_text, expected_effect_json, "
        "status, user_feedback, followed_state, outcome_review, created_at "
        "FROM health_coach_recommendations WHERE family_id = ? AND owner_user_id = ? "
        "AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 12",
        (user["family_id"], user["id"]),
    )
    if not items:
        return None
    for item in items:
        raw = item.pop("expected_effect_json", None)
        try:
            item["expected_effect"] = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            item["expected_effect"] = None
    return _bundle(
        identifier="recommendation-history",
        kind="recommendation_history",
        label="Prior recommendation feedback",
        summary=f"{len(items)} prior recommendations with recorded responses where available.",
        facts={"recommendations": items},
        source_ids=[item["id"] for item in items],
        sample_size=len(items),
        completeness=sum(item["user_feedback"] is not None for item in items) / len(items),
    )


async def build_owner_read_snapshot(db, *, user: dict, today: date) -> list[dict]:
    """Return compact owner-private Fitness facts for another explicit AI surface."""
    candidates = [
        await _goals_and_phase(db, user=user, today=today),
        await _schedule(db, user=user, today=today),
        await _nutrition(db, user=user, today=today),
        await _body_recovery(db, user=user, today=today),
        await _cycle_context(db, user=user, today=today),
        await _body_issues(db, user=user, today=today),
        await _activities_and_gear(
            db,
            user=user,
            today=today,
            recent_limit=12,
            detailed_limit=1,
        ),
        await _plan_outcomes(db, user=user, today=today),
        await _strength_context(db, user=user, today=today),
        await _prior_recommendations(db, user=user),
    ]
    return [
        {**item["public"], "facts": item["facts"]}
        for item in candidates
        if item is not None
    ]


async def _selected_context(db, *, user: dict, identifiers: list[str]) -> dict | None:
    if not identifiers:
        return None
    placeholders = ",".join("?" for _ in identifiers)
    scoped = (user["family_id"], user["id"], *identifiers)
    activities = await _rows(
        db,
        "SELECT id, sport_key, title, started_at_utc, timer_duration_s, distance_m, "
        f"workout_classification FROM health_activities WHERE family_id = ? "
        f"AND owner_user_id = ? AND id IN ({placeholders}) AND deleted_at IS NULL",
        scoped,
    )
    goals = await _rows(
        db,
        "SELECT id, goal_type, metric_key, name, current_value, target_value, unit_key, "
        f"target_date, status FROM health_goals WHERE family_id = ? AND owner_user_id = ? "
        f"AND id IN ({placeholders}) AND deleted_at IS NULL",
        scoped,
    )
    plans = await _rows(
        db,
        "SELECT id, sport_key, title, status, scheduled_start_utc, scheduled_date, "
        f"expected_duration_s, expected_distance_m FROM health_planned_sessions "
        f"WHERE family_id = ? AND owner_user_id = ? AND id IN ({placeholders}) "
        "AND deleted_at IS NULL",
        scoped,
    )
    exercises = await _rows(
        db,
        "SELECT id, name, movement_pattern_key, measurement_mode, load_entry_mode "
        f"FROM health_exercises WHERE family_id = ? AND owner_user_id = ? "
        f"AND id IN ({placeholders}) AND deleted_at IS NULL",
        scoped,
    )
    records = activities + goals + plans + exercises
    if not records:
        return None
    return _bundle(
        identifier="selected-context",
        kind="selected_records",
        label="Selected Fitness records",
        summary=f"{len(records)} explicitly selected owner-private records.",
        facts={
            "activities": activities,
            "goals": goals,
            "planned_sessions": plans,
            "exercises": exercises,
        },
        source_ids=[item["id"] for item in records],
        sample_size=len(records),
        completeness=len(records) / len(identifiers),
    )


async def _controlled_analysis(
    db, *, user: dict, body: CoachMessageRequest, today: date
) -> dict | None:
    text = body.message.lower()
    if body.intent == "strength_plan" or "strength" in text or "lift" in text:
        measure, dimension, chart = "strength.observed_load_kg", "exercise", "table"
    elif "weight" in text:
        measure, dimension, chart = "body.weight_trend_kg", "week", "line"
    elif "protein" in text:
        measure, dimension, chart = "nutrition.protein_g", "week", "bar"
    elif "calorie" in text or "nutrition" in text or "food" in text:
        measure, dimension, chart = "nutrition.calories_kcal", "week", "bar"
    elif "sleep" in text or "recovery" in text:
        measure, dimension, chart = "sleep.duration_s", "week", "range_band"
    else:
        measure, dimension, chart = "running.distance_m", "week", "bar"
    query = AnalysisQueryPayload(
        measure_key=measure,
        dimension_key=dimension,
        chart_type_key=chart,
        date_range=AnalysisDateRange(start=today - timedelta(days=83), end=today),
        max_points=30,
    )
    result = await analysis.execute_query(db, user=user, body=query)
    if result["status"] == "empty":
        return None
    points = [
        point for series in result.get("series", [])[:2] for point in series.get("points", [])[:30]
    ]
    return _bundle(
        identifier=f"analysis:{measure}",
        kind="analysis",
        label=result["title"],
        summary=result.get("summary") or result["limitations"][0],
        facts={
            "measure_key": measure,
            "dimension_key": dimension,
            "status": result["status"],
            "metadata": result["metadata"],
            "points": points,
            "limitations": result["limitations"],
        },
        source_ids=[],
        start=query.date_range.start,
        end=query.date_range.end,
        sample_size=result["metadata"]["sample_size"],
        completeness=1 - result["metadata"].get("missing_rate", 0),
    )


def _context_preferences_from_row(row) -> CoachContextPreferencesResponse:
    return CoachContextPreferencesResponse(
        family_calendar=bool(row["use_family_calendar"]) if row else False,
        household_meals=bool(row["use_household_meals"]) if row else False,
        weather=bool(row["use_weather"]) if row else False,
    )


async def _read_context_preferences(db, *, user: dict) -> CoachContextPreferencesResponse:
    row = await (
        await db.execute(
            "SELECT use_family_calendar, use_household_meals, use_weather "
            "FROM health_onboarding_profiles WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    return _context_preferences_from_row(row)


async def context_preferences(db, *, user: dict) -> CoachContextPreferencesResponse:
    return await _read_context_preferences(db, user=user)


async def update_context_preferences(
    db,
    *,
    user: dict,
    body: CoachContextPreferencesUpdate,
) -> CoachContextPreferencesResponse:
    row = await onboarding.ensure_profile(db, user=user)
    mapping = {
        "family_calendar": "use_family_calendar",
        "household_meals": "use_household_meals",
        "weather": "use_weather",
    }
    values = {
        mapping[key]: value
        for key, value in body.model_dump(exclude_unset=True).items()
        if value is not None
    }
    await update_owned(
        db,
        table="health_onboarding_profiles",
        record_id=row["id"],
        values=values,
        user=user,
        record_sync_change=False,
    )
    return await _read_context_preferences(db, user=user)


async def list_fitness_reminders(db, *, user: dict) -> list[dict]:
    rows = await _rows(
        db,
        "SELECT id, title, remind_at_utc, notes, planned_session_id, status "
        "FROM health_fitness_reminders WHERE family_id = ? AND owner_user_id = ? "
        "AND deleted_at IS NULL ORDER BY remind_at_utc, created_at LIMIT 100",
        (user["family_id"], user["id"]),
    )
    return rows


async def delete_fitness_reminder(db, *, user: dict, reminder_id: str) -> None:
    await soft_delete_owned(
        db,
        table="health_fitness_reminders",
        record_id=reminder_id,
        user=user,
        record_sync_change=False,
    )


def _calendar_datetime(value: str, zone: ZoneInfo) -> datetime:
    if len(value) == 10:
        return datetime.combine(date.fromisoformat(value), datetime.min.time(), zone)
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=zone)
    return parsed.astimezone(zone)


def _calendar_occurrences(
    recurrence_rule: str | None,
    *,
    start: datetime,
    duration: timedelta,
    window_start: datetime,
    window_end: datetime,
) -> list[datetime]:
    if not recurrence_rule:
        return [start]
    rule = rrulestr(recurrence_rule, dtstart=start)
    occurrences: list[datetime] = []
    occurrence = rule.after(window_start - duration, inc=True)
    while (
        occurrence is not None
        and occurrence < window_end
        and len(occurrences) < MAX_FAMILY_CALENDAR_OCCURRENCES
    ):
        if occurrence.tzinfo is None:
            occurrence = occurrence.replace(tzinfo=start.tzinfo)
        occurrences.append(occurrence)
        next_occurrence = rule.after(occurrence, inc=False)
        if next_occurrence is not None and next_occurrence <= occurrence:
            break
        occurrence = next_occurrence
    return occurrences


async def _family_calendar_context(
    db,
    *,
    user: dict,
    reference: datetime,
) -> dict | None:
    range_end = reference + timedelta(days=7)
    rows = await _rows(
        db,
        "SELECT id, title, start_time, end_time, all_day, recurrence_rule, location "
        "FROM calendar_events ce WHERE ce.family_id = ? AND ce.deleted_at IS NULL "
        "AND NOT EXISTS (SELECT 1 FROM calendar_events replacement "
        "WHERE replacement.overridden_event_id = ce.id "
        "AND replacement.family_id = ce.family_id "
        "AND replacement.deleted_at IS NULL) "
        "AND (ce.recurrence_rule IS NOT NULL OR (substr(ce.start_time,1,10) <= ? "
        "AND substr(COALESCE(ce.end_time, ce.start_time),1,10) >= ?)) "
        "ORDER BY CASE WHEN ce.recurrence_rule IS NULL THEN 1 ELSE 0 END, "
        "CASE WHEN ce.recurrence_rule IS NOT NULL THEN ce.updated_at END DESC, "
        "ce.start_time LIMIT ?",
        (
            user["family_id"],
            range_end.date().isoformat(),
            reference.date().isoformat(),
            MAX_FAMILY_CALENDAR_ROWS,
        ),
    )
    excluded_occurrences = await exception_keys_for_series(
        db,
        family_id=user["family_id"],
        series_ids=[row["id"] for row in rows if row["recurrence_rule"]],
    )
    events: list[dict] = []
    for row in rows:
        try:
            start = _calendar_datetime(row["start_time"], reference.tzinfo)
            if row["end_time"]:
                end = _calendar_datetime(row["end_time"], reference.tzinfo)
            elif row["all_day"] or len(row["start_time"]) == 10:
                end = start + timedelta(days=1)
            else:
                end = start + timedelta(hours=1)
            duration = max(end - start, timedelta(minutes=1))
            occurrences = _calendar_occurrences(
                row["recurrence_rule"],
                start=start,
                duration=duration,
                window_start=reference,
                window_end=range_end,
            )
        except (OverflowError, TypeError, ValueError):
            continue
        for occurrence in occurrences:
            all_day = bool(row["all_day"]) or len(row["start_time"]) == 10
            key = occurrence_key(occurrence, all_day=all_day)
            if (
                row["recurrence_rule"]
                and key in excluded_occurrences.get(row["id"], set())
            ):
                continue
            occurrence = occurrence.astimezone(reference.tzinfo)
            occurrence_end = occurrence + duration
            if occurrence >= range_end or occurrence_end <= reference:
                continue
            events.append(
                {
                    "id": f"{row['id']}::{key}" if row["recurrence_rule"] else row["id"],
                    "title": row["title"],
                    "start_time": occurrence.isoformat(),
                    "end_time": occurrence_end.isoformat(),
                    "all_day": bool(row["all_day"]),
                    "location": row["location"],
                    "family_visible": True,
                }
            )
        if len(events) > MAX_FAMILY_CALENDAR_OCCURRENCES * 2:
            events.sort(key=lambda item: (item["start_time"], item["title"], item["id"]))
            events = events[:MAX_FAMILY_CALENDAR_OCCURRENCES]
    events.sort(key=lambda item: (item["start_time"], item["title"], item["id"]))
    events = events[:MAX_FAMILY_CALENDAR_OCCURRENCES]
    if not events:
        return None
    return _bundle(
        identifier="family-calendar:next-seven-days",
        kind="family_calendar",
        label="Family calendar",
        summary=f"{len(events)} family commitments in the next seven days.",
        facts={"events": events},
        source_ids=list(dict.fromkeys(item["id"] for item in events)),
        start=reference.date(),
        end=range_end.date(),
        sample_size=len(events),
    )


async def _weights_room_context(db, *, user: dict, today: date) -> dict | None:
    end = today + timedelta(days=13)
    availability = await weights_room_availability(
        db,
        user=user,
        start=today,
        end=end,
    )
    if not availability.relevant or not availability.days:
        return None
    days = [
        {
            "date": item.date.isoformat(),
            "status": item.weights_room_status,
            "opening_times": [window.model_dump() for window in item.weights_room],
        }
        for item in availability.days
    ]
    open_days = sum(bool(item["opening_times"]) for item in days)
    return _bundle(
        identifier="example_school-weights-room:next-fourteen-days",
        kind="facility_availability",
        label="Example School weights-room opening times",
        summary=f"{open_days} open days in the next fourteen days.",
        facts={
            "facility": "Example School weights room",
            "days": days,
            "data_through": availability.current_to.isoformat()
            if availability.current_to
            else None,
        },
        source_ids=[availability.source_document_id]
        if availability.source_document_id
        else [],
        start=today,
        end=end,
        sample_size=len(days),
        completeness=len(days) / 14,
    )


async def _household_meal_context(
    db,
    *,
    user: dict,
    today: date,
) -> dict | None:
    end = today + timedelta(days=6)
    rows = await _rows(
        db,
        "SELECT mp.id AS meal_plan_id, mp.date, mp.meal_type, mp.notes, "
        "m.name AS meal_name, l.id AS link_id, l.recipe_version_id, "
        "v.servings, v.finished_weight_g, r.name AS recipe_name, "
        "CASE WHEN own_log.id IS NULL THEN 0 ELSE 1 END AS already_logged "
        "FROM meal_plans mp JOIN meals m ON m.id = mp.meal_id "
        "AND m.family_id = mp.family_id AND m.deleted_at IS NULL "
        "LEFT JOIN health_household_meal_recipe_links l ON l.meal_id = mp.meal_id "
        "AND l.family_id = mp.family_id AND l.deleted_at IS NULL "
        "LEFT JOIN health_recipe_versions v ON v.id = l.recipe_version_id "
        "AND v.family_id = l.family_id AND v.deleted_at IS NULL "
        "LEFT JOIN health_recipes r ON r.id = v.recipe_id "
        "AND r.family_id = v.family_id AND r.owner_user_id = v.owner_user_id "
        "AND r.deleted_at IS NULL AND r.active = 1 AND r.household_shared = 1 "
        "LEFT JOIN health_food_log_entries own_log ON own_log.source_meal_plan_id = mp.id "
        "AND own_log.family_id = mp.family_id AND own_log.owner_user_id = ? "
        "AND own_log.deleted_at IS NULL "
        "WHERE mp.family_id = ? AND mp.date BETWEEN ? AND ? "
        "AND mp.deleted_at IS NULL ORDER BY mp.date, "
        "CASE mp.meal_type WHEN 'breakfast' THEN 1 WHEN 'lunch' THEN 2 ELSE 3 END, "
        "m.name LIMIT 40",
        (user["id"], user["family_id"], today.isoformat(), end.isoformat()),
    )
    if not rows:
        return None
    meals = []
    for row in rows:
        linked = bool(row["link_id"] and row["recipe_version_id"] and row["recipe_name"])
        if linked and row["servings"] and float(row["servings"]) > 0:
            suggested_portion, suggested_unit = 1.0, "serving"
        elif linked and row["finished_weight_g"] and float(row["finished_weight_g"]) > 0:
            suggested_portion, suggested_unit = 100.0, "g"
        else:
            suggested_portion, suggested_unit = None, None
        meals.append(
            {
                "meal_plan_id": row["meal_plan_id"],
                "date": row["date"],
                "meal_type": row["meal_type"],
                "meal_name": row["meal_name"][:300],
                "notes": row["notes"][:500] if row["notes"] else None,
                "link_id": row["link_id"] if linked else None,
                "recipe_version_id": row["recipe_version_id"] if linked else None,
                "recipe_name": row["recipe_name"][:300] if linked else None,
                "suggested_portion": suggested_portion,
                "suggested_unit": suggested_unit,
                "already_logged_by_you": bool(row["already_logged"]),
            }
        )
    return _bundle(
        identifier="household-meals:next-seven-days",
        kind="household_meals",
        label="Household meal plan",
        summary=f"{len(meals)} planned household meals in the next seven days.",
        facts={"meals": meals},
        source_ids=[item["meal_plan_id"] for item in meals],
        start=today,
        end=end,
        sample_size=len(meals),
    )


async def _weather_context() -> dict | None:
    weather = await get_weather_summary()
    if not weather:
        return None
    description = str(weather.get("description") or "Weather for the next day.")[:500]
    facts = {
        "description": description,
        "temp_high": weather.get("temp_high"),
        "temp_low": weather.get("temp_low"),
        "rain_chance": weather.get("rain_chance"),
    }
    return _bundle(
        identifier="weather:next-day",
        kind="weather",
        label="Relevant weather",
        summary=description,
        facts=facts,
        source_ids=[],
    )


async def build_evidence(db, *, user: dict, body: CoachMessageRequest) -> list[dict]:
    """Build only bounded, calculated, owner-private context for this explicit request."""
    reference, today = _reference(body)
    text = body.message.lower()
    # An explicit Fitness Coach message authorises one bounded, owner-private
    # Fitness baseline. Keywords may add a controlled analysis, but they must
    # never decide whether the Coach can see the user's core Fitness records.
    # Write safety remains separately enforced by typed, confirm-only proposals.
    domains: set[str] = {
        "goals",
        "schedule",
        "nutrition",
        "recovery",
        "cycle",
        "issues",
        "activities",
        "plan_outcomes",
        "strength",
        "prior",
    }
    if body.intent == "morning":
        domains.update(
            {"goals", "schedule", "nutrition", "recovery", "issues", "weights_room"}
        )
    elif body.intent == "post_workout":
        domains.update(
            {
                "goals",
                "schedule",
                "nutrition",
                "recovery",
                "issues",
                "activities",
                "plan_outcomes",
                "strength",
                "analysis",
            }
        )
    elif body.intent == "evening":
        domains.update({"schedule", "nutrition", "recovery", "issues", "activities"})
    elif body.intent == "weekly":
        domains.update(
            {
                "goals",
                "schedule",
                "nutrition",
                "recovery",
                "issues",
                "activities",
                "plan_outcomes",
                "strength",
                "analysis",
                "weights_room",
            }
        )
    elif body.intent == "run_plan":
        domains.update({"goals", "schedule", "recovery", "issues", "activities", "analysis"})
    elif body.intent == "strength_plan":
        domains.update(
            {
                "goals",
                "schedule",
                "recovery",
                "issues",
                "activities",
                "strength",
                "analysis",
                "weights_room",
            }
        )
    else:
        keyword_domains = {
            "nutrition": ("food", "meal", "calorie", "protein", "fibre", "diet"),
            "recovery": ("weight", "sleep", "recovery", "readiness", "hrv", "heart rate"),
            "issues": ("pain", "injury", "sore", "tight", "body issue"),
            "activities": (
                "run",
                "running",
                "pace",
                "activity",
                "gear",
                "shoe",
                "strava",
                "race",
                "5k",
                "10k",
                "marathon",
                "half marathon",
                "personal best",
                "pb",
                "split",
                "tempo",
                "interval",
            ),
            "strength": ("strength", "lift", "exercise", "set", "squat", "deadlift"),
            "goals": ("goal", "target", "phase", "progress"),
            "schedule": ("today", "calendar", "schedule", "plan", "week"),
            "weights_room": ("weights room", "weight room", "gym", "wtr"),
        }
        matched_domains = {
            domain
            for domain, words in keyword_domains.items()
            if any(word in text for word in words)
        }
        if matched_domains.intersection({"nutrition", "recovery", "activities", "strength"}):
            domains.add("analysis")
    if any(word in text for word in ("food", "meal", "calorie", "protein", "fibre")):
        domains.add("nutrition")

    builders = {
        "family_calendar": lambda: _family_calendar_context(db, user=user, reference=reference),
        "weights_room": lambda: _weights_room_context(db, user=user, today=today),
        "household_meals": lambda: _household_meal_context(db, user=user, today=today),
        "weather": _weather_context,
        "goals": lambda: _goals_and_phase(db, user=user, today=today),
        "schedule": lambda: _schedule(db, user=user, today=today),
        "nutrition": lambda: _nutrition(db, user=user, today=today),
        "recovery": lambda: _body_recovery(db, user=user, today=today),
        "cycle": lambda: _cycle_context(db, user=user, today=today),
        "issues": lambda: _body_issues(db, user=user, today=today),
        "activities": lambda: _activities_and_gear(
            db,
            user=user,
            today=today,
            focus_activity_ids=body.context_ids,
        ),
        "plan_outcomes": lambda: _plan_outcomes(db, user=user, today=today),
        "strength": lambda: _strength_context(db, user=user, today=today),
        "analysis": lambda: _controlled_analysis(db, user=user, body=body, today=today),
        "prior": lambda: _prior_recommendations(db, user=user),
    }
    order = (
        "family_calendar",
        "weights_room",
        "household_meals",
        "weather",
        "goals",
        "schedule",
        "nutrition",
        "recovery",
        "cycle",
        "issues",
        "activities",
        "plan_outcomes",
        "strength",
        "analysis",
        "prior",
    )
    context_options = await _read_context_preferences(db, user=user)
    if context_options.family_calendar:
        domains.add("family_calendar")
    if context_options.household_meals:
        domains.add("household_meals")
    if context_options.weather:
        domains.add("weather")
    candidates = [await builders[key]() for key in order if key in domains]
    if body.context_ids:
        candidates.insert(
            0,
            await _selected_context(db, user=user, identifiers=body.context_ids),
        )
    return [item for item in candidates if item is not None][:MAX_EVIDENCE_ITEMS]


def bridge_context(evidence: list[dict], *, preferences: dict | None = None) -> dict:
    tone_preferences = None
    if preferences is not None:
        tone_preferences = {
            key: preferences.get(key)
            for key in (
                "personality_preset",
                "directness",
                "challenge_bias",
                "detail_level",
                "custom_instruction",
            )
        }
    return {
        "evidence": [
            {**item["public"], "facts": item["facts"]} for item in evidence[:MAX_EVIDENCE_ITEMS]
        ],
        "preferences": tone_preferences,
    }


def public_evidence(evidence: list[dict], cited_ids: list[str] | None = None) -> list[dict]:
    cited = set(cited_ids or [])
    selected = [item for item in evidence if not cited or item["public"]["id"] in cited]
    return [item["public"] for item in selected[:MAX_EVIDENCE_ITEMS]]


async def memory_setting(db, *, user: dict) -> CoachMemorySettingResponse:
    owner_settings = await planning.ensure_settings(db, user=user)
    return CoachMemorySettingResponse(
        enabled=bool(owner_settings["coach_memory_enabled"]),
        enabled_at=owner_settings["coach_memory_enabled_at"],
    )


async def set_memory_enabled(db, *, user: dict, enabled: bool) -> CoachMemorySettingResponse:
    owner_settings = await planning.ensure_settings(db, user=user)
    current = bool(owner_settings["coach_memory_enabled"])
    if current != enabled:
        await update_owned(
            db,
            table="health_user_settings",
            record_id=owner_settings["id"],
            values={
                "coach_memory_enabled": enabled,
                "coach_memory_enabled_at": now_iso() if enabled else None,
            },
            user=user,
        )
    return await memory_setting(db, user=user)


async def _require_memory_enabled(db, *, user: dict) -> None:
    if not (await memory_setting(db, user=user)).enabled:
        raise FitnessConflictError("Coach memory is not enabled")


def _conversation_response(row) -> CoachConversationResponse:
    return CoachConversationResponse(
        id=row["id"],
        title=row["title"],
        last_message_at=row["last_message_at"],
        revision=int(row["revision"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


async def list_conversations(db, *, user: dict) -> list[CoachConversationResponse]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_coach_conversations WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL "
            "ORDER BY COALESCE(last_message_at, created_at) DESC LIMIT 200",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    return [_conversation_response(row) for row in rows]


async def create_conversation(
    db, *, user: dict, body: CoachConversationCreate
) -> CoachConversationResponse:
    await _require_memory_enabled(db, user=user)
    identifier = new_id(body.id)
    reused = await (
        await db.execute("SELECT * FROM health_coach_conversations WHERE id = ?", (identifier,))
    ).fetchone()
    title = body.title or "New conversation"
    if reused is not None:
        if (
            reused["family_id"] != user["family_id"]
            or reused["owner_user_id"] != user["id"]
            or reused["deleted_at"] is not None
        ):
            raise FitnessNotFoundError("Coach conversation not found")
        if reused["title"] != title:
            raise FitnessConflictError(
                "Coach conversation ID was already used for a different title"
            )
        return _conversation_response(reused)
    await insert_owned(
        db,
        table="health_coach_conversations",
        record_id=identifier,
        values={"title": title, "last_message_at": None, "revision": 1},
        user=user,
        record_sync_change=False,
    )
    return _conversation_response(
        await owned_row(
            db,
            table="health_coach_conversations",
            record_id=identifier,
            user=user,
        )
    )


async def owned_conversation(db, *, user: dict, conversation_id: str):
    try:
        return await owned_row(
            db,
            table="health_coach_conversations",
            record_id=conversation_id,
            user=user,
        )
    except FitnessNotFoundError as exc:
        raise FitnessNotFoundError("Coach conversation not found") from exc


async def conversation_history(db, *, user: dict, conversation_id: str) -> list[dict[str, str]]:
    await owned_conversation(db, user=user, conversation_id=conversation_id)
    rows = await (
        await db.execute(
            "SELECT role, content FROM (SELECT role, content, sequence FROM "
            "health_coach_messages WHERE family_id = ? AND owner_user_id = ? "
            "AND conversation_id = ? AND deleted_at IS NULL "
            "ORDER BY sequence DESC LIMIT 8) ORDER BY sequence",
            (user["family_id"], user["id"], conversation_id),
        )
    ).fetchall()
    return [{"role": row["role"], "content": row["content"]} for row in rows]


async def conversation_detail(db, *, user: dict, conversation_id: str) -> CoachConversationDetail:
    row = await owned_conversation(db, user=user, conversation_id=conversation_id)
    messages = await (
        await db.execute(
            "SELECT * FROM (SELECT * FROM health_coach_messages WHERE family_id = ? "
            "AND owner_user_id = ? AND conversation_id = ? AND deleted_at IS NULL "
            "ORDER BY sequence DESC LIMIT 200) ORDER BY sequence",
            (user["family_id"], user["id"], conversation_id),
        )
    ).fetchall()
    summary = _conversation_response(row)
    return CoachConversationDetail(
        **summary.model_dump(),
        messages=[
            {
                "id": item["id"],
                "conversation_id": item["conversation_id"],
                "sequence": int(item["sequence"]),
                "role": item["role"],
                "content": item["content"],
                "intent": item["intent"],
                "created_at": item["created_at"],
            }
            for item in messages
        ],
    )


async def store_successful_exchange(
    db,
    *,
    user: dict,
    conversation_id: str,
    create_if_missing: bool,
    user_message: str,
    assistant_message: str,
    intent: str,
    provider: str,
    model: str,
) -> str | None:
    """Atomically store only a completed exchange after the bridge succeeds."""
    if not db.in_transaction:
        await db.execute("BEGIN IMMEDIATE")
    # Respect a memory toggle that may have changed while Hermes was running.
    if not (await memory_setting(db, user=user)).enabled:
        return None
    if create_if_missing:
        existing = await (
            await db.execute(
                "SELECT id FROM health_coach_conversations WHERE id = ?",
                (conversation_id,),
            )
        ).fetchone()
        if existing is not None:
            raise FitnessConflictError("Coach conversation ID is already in use")
        title = user_message.strip().splitlines()[0][:160] or "New conversation"
        await insert_owned(
            db,
            table="health_coach_conversations",
            record_id=conversation_id,
            values={"title": title, "last_message_at": None, "revision": 1},
            user=user,
            record_sync_change=False,
        )
    else:
        await owned_conversation(db, user=user, conversation_id=conversation_id)
    sequence_row = await (
        await db.execute(
            "SELECT COALESCE(MAX(sequence), 0) AS sequence FROM health_coach_messages "
            "WHERE family_id = ? AND owner_user_id = ? AND conversation_id = ?",
            (user["family_id"], user["id"], conversation_id),
        )
    ).fetchone()
    first_sequence = int(sequence_row["sequence"] or 0) + 1
    timestamp = now_iso()
    await insert_owned(
        db,
        table="health_coach_messages",
        record_id=new_id(),
        values={
            "conversation_id": conversation_id,
            "sequence": first_sequence,
            "role": "user",
            "content": user_message,
            "intent": intent,
            "model_provider": None,
            "model_id": None,
            "revision": 1,
        },
        user=user,
        now=timestamp,
        record_sync_change=False,
    )
    await insert_owned(
        db,
        table="health_coach_messages",
        record_id=new_id(),
        values={
            "conversation_id": conversation_id,
            "sequence": first_sequence + 1,
            "role": "assistant",
            "content": assistant_message,
            "intent": None,
            "model_provider": provider,
            "model_id": model,
            "revision": 1,
        },
        user=user,
        now=timestamp,
        record_sync_change=False,
    )
    await update_owned(
        db,
        table="health_coach_conversations",
        record_id=conversation_id,
        values={"last_message_at": timestamp},
        user=user,
        now=timestamp,
        record_sync_change=False,
    )
    return conversation_id


async def delete_conversation(db, *, user: dict, conversation_id: str) -> None:
    await owned_conversation(db, user=user, conversation_id=conversation_id)
    messages = await (
        await db.execute(
            "SELECT id FROM health_coach_messages WHERE family_id = ? "
            "AND owner_user_id = ? AND conversation_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], conversation_id),
        )
    ).fetchall()
    for message in messages:
        await soft_delete_owned(
            db,
            table="health_coach_messages",
            record_id=message["id"],
            user=user,
            record_sync_change=False,
        )
    await soft_delete_owned(
        db,
        table="health_coach_conversations",
        record_id=conversation_id,
        user=user,
        record_sync_change=False,
    )


def _memory_response(row) -> CoachMemoryResponse:
    return CoachMemoryResponse(
        id=row["id"],
        content=row["content"],
        category=row["category"],
        confirmed_at=row["confirmed_at"],
        revision=int(row["revision"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


async def list_memories(db, *, user: dict) -> list[CoachMemoryResponse]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_coach_memories WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL "
            "ORDER BY updated_at DESC LIMIT 200",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    return [_memory_response(row) for row in rows]


async def create_memory(db, *, user: dict, body: CoachMemoryCreate) -> CoachMemoryResponse:
    await _require_memory_enabled(db, user=user)
    identifier = new_id(body.id)
    reused = await (
        await db.execute("SELECT * FROM health_coach_memories WHERE id = ?", (identifier,))
    ).fetchone()
    if reused is not None:
        if (
            reused["family_id"] != user["family_id"]
            or reused["owner_user_id"] != user["id"]
            or reused["deleted_at"] is not None
        ):
            raise FitnessNotFoundError("Coach memory not found")
        if reused["content"] != body.content or reused["category"] != body.category:
            raise FitnessConflictError("Coach memory ID was already used for a different note")
        return _memory_response(reused)
    timestamp = now_iso()
    await insert_owned(
        db,
        table="health_coach_memories",
        record_id=identifier,
        values={
            "content": body.content,
            "category": body.category,
            "confirmed_at": timestamp,
            "revision": 1,
        },
        user=user,
        now=timestamp,
        record_sync_change=False,
    )
    return _memory_response(
        await owned_row(
            db,
            table="health_coach_memories",
            record_id=identifier,
            user=user,
        )
    )


async def patch_memory(
    db, *, user: dict, memory_id: str, body: CoachMemoryPatch
) -> CoachMemoryResponse:
    try:
        await owned_row(db, table="health_coach_memories", record_id=memory_id, user=user)
    except FitnessNotFoundError as exc:
        raise FitnessNotFoundError("Coach memory not found") from exc
    await update_owned(
        db,
        table="health_coach_memories",
        record_id=memory_id,
        values=body.model_dump(exclude_unset=True),
        user=user,
        record_sync_change=False,
    )
    return _memory_response(
        await owned_row(db, table="health_coach_memories", record_id=memory_id, user=user)
    )


async def delete_memory(db, *, user: dict, memory_id: str) -> None:
    try:
        await soft_delete_owned(
            db,
            table="health_coach_memories",
            record_id=memory_id,
            user=user,
            record_sync_change=False,
        )
    except FitnessNotFoundError as exc:
        raise FitnessNotFoundError("Coach memory not found") from exc


async def relevant_memories(
    db, *, user: dict, message: str, limit: int = 5
) -> list[dict[str, str | None]]:
    """Return a small deterministic relevance-ranked set of confirmed notes."""
    rows = await (
        await db.execute(
            "SELECT content, category, updated_at FROM health_coach_memories "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
            "ORDER BY updated_at DESC LIMIT 100",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    query_tokens = set(re.findall(r"[a-z0-9]+", message.lower()))
    ranked = []
    for recency, row in enumerate(rows):
        searchable = f"{row['category'] or ''} {row['content']}".lower()
        tokens = set(re.findall(r"[a-z0-9]+", searchable))
        overlap = len(query_tokens & tokens)
        ranked.append((overlap, -recency, row))
    ranked.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return [
        {"content": row["content"], "category": row["category"]}
        for _, _, row in ranked[: max(0, min(limit, 5))]
    ]


async def clear_memory(db, *, user: dict) -> CoachMemoryClearResponse:
    contracts = (
        ("messages", "health_coach_messages"),
        ("conversations", "health_coach_conversations"),
        ("memories", "health_coach_memories"),
    )
    counts = {"conversations": 0, "messages": 0, "memories": 0}
    for label, table in contracts:
        rows = await (
            await db.execute(
                f"SELECT id FROM {table} WHERE family_id = ? AND owner_user_id = ? "
                "AND deleted_at IS NULL",
                (user["family_id"], user["id"]),
            )
        ).fetchall()
        for row in rows:
            await soft_delete_owned(
                db,
                table=table,
                record_id=row["id"],
                user=user,
                record_sync_change=False,
            )
        counts[label] = len(rows)
    return CoachMemoryClearResponse(**counts)


def _validation_issues(exc: ValidationError) -> list[dict]:
    return [
        {
            "code": str(item.get("type") or "invalid"),
            "path": ".".join(str(part) for part in item.get("loc", ())) or None,
            "message": str(item.get("msg") or "Invalid proposal field")[:500],
        }
        for item in exc.errors()[:50]
    ]


def _same_instant(left: str | datetime | None, right: datetime | None) -> bool:
    if left is None or right is None:
        return left is None and right is None
    parsed = (
        left
        if isinstance(left, datetime)
        else datetime.fromisoformat(str(left).replace("Z", "+00:00"))
    )
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    expected = right
    if expected.tzinfo is None:
        expected = expected.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc) == expected.astimezone(timezone.utc)


def proposal_confirmability(kind: str, payload: dict) -> tuple[bool, str | None]:
    """Return whether the exact typed draft maps to an allowlisted write."""
    if kind == "nutrition_change":
        action = payload.get("action_type", "review_only")
        if action == "review_only":
            return False, "This is coaching guidance for review, not a stored nutrition action."
    if kind == "goal_adjustment":
        action = payload.get("action_type", "review_only")
        if action == "review_only":
            return False, "This goal suggestion is prose for review and has no typed target change."
    return kind in PROPOSAL_KINDS, None


def _training_week_workout(payload: CoachTrainingWeekPayload, item):
    common = {
        "title": item.title,
        "purpose": item.purpose or payload.purpose,
        "scheduled_date": item.scheduled_date,
        "local_timezone": payload.local_timezone,
        "estimated_duration_s": item.expected_duration_s,
        "goal_reason": item.goal_reason or item.purpose or payload.purpose,
        "goal_ids": item.goal_ids,
    }
    if item.sport_key == "running":
        return "run_workout", CoachRunWorkoutPayload(
            **common,
            estimated_distance_m=item.expected_distance_m,
            expected_difficulty=item.expected_difficulty,
            route_assumption=item.route_assumption,
            terrain_assumption=item.terrain_assumption,
            intended_gear_ids=item.intended_gear_ids,
            steps=item.steps,
            cues=item.cues,
            garmin_limitations=item.garmin_limitations,
        )
    return "strength_workout", CoachStrengthWorkoutPayload(
        **common,
        location=item.location,
        exercises=item.exercises,
    )


async def validate_proposal(
    db, *, user: dict, kind: str, payload: dict
) -> tuple[dict, dict, list[dict]]:
    model_type = PROPOSAL_PAYLOAD_MODELS.get(kind)
    if model_type is None:
        return (
            {},
            {
                "valid": False,
                "issues": [
                    {
                        "code": "unregistered_kind",
                        "path": "kind",
                        "message": "Proposal kind is not registered",
                    }
                ],
            },
            [],
        )
    allowed = set(model_type.model_fields)
    bounded = {key: value for key, value in payload.items() if key in allowed}
    extra = sorted(set(payload) - allowed)
    if extra:
        return (
            bounded,
            {
                "valid": False,
                "issues": [
                    {
                        "code": "extra_forbidden",
                        "path": key,
                        "message": "Unregistered proposal field",
                    }
                    for key in extra[:20]
                ],
            },
            [],
        )
    try:
        parsed = model_type.model_validate(bounded)
    except ValidationError as exc:
        return bounded, {"valid": False, "issues": _validation_issues(exc)}, []
    normalized = parsed.model_dump(mode="json")
    warnings: list[dict] = []
    try:
        if kind == "run_workout":
            assert isinstance(parsed, CoachRunWorkoutPayload)
            for goal_id in parsed.goal_ids:
                await validate_owned_reference(
                    db, table="health_goals", record_id=str(goal_id), user=user
                )
            for gear_id in parsed.intended_gear_ids:
                await validate_owned_reference(
                    db, table="health_gear_items", record_id=str(gear_id), user=user
                )
            run_result = run_plans.validate_run_steps(
                parsed.steps,
                parsed.cues,
                expected_distance_m=parsed.estimated_distance_m,
                expected_duration_s=parsed.estimated_duration_s,
            )
            warnings.extend(
                {"code": "garmin_mapping", "message": message} for message in run_result["warnings"]
            )
            warnings.extend(
                {"code": "planning_context", "message": message}
                for message in await run_plans.planning_context_warnings(
                    db, user=user, planned_distance_m=parsed.estimated_distance_m
                )
            )
        elif kind == "strength_workout":
            assert isinstance(parsed, CoachStrengthWorkoutPayload)
            for goal_id in parsed.goal_ids:
                await validate_owned_reference(
                    db, table="health_goals", record_id=str(goal_id), user=user
                )
            for index, item in enumerate(parsed.exercises):
                exercise_id, _ = await resolve_exercise_id(
                    db, user=user, exercise_id=str(item.exercise_id)
                )
                setup_id, _ = await resolve_setup_id(
                    db, user=user, setup_id=str(item.exercise_setup_id)
                )
                if exercise_id != str(item.exercise_id) or setup_id != str(item.exercise_setup_id):
                    raise FitnessConflictError(
                        f"exercises.{index} must use final canonical identities"
                    )
                exercise = await owned_row(
                    db, table="health_exercises", record_id=exercise_id, user=user
                )
                setup = await owned_row(
                    db, table="health_exercise_setups", record_id=setup_id, user=user
                )
                setup_exercise, _ = await resolve_exercise_id(
                    db, user=user, exercise_id=setup["exercise_id"]
                )
                if setup_exercise != exercise_id:
                    raise FitnessConflictError(
                        f"exercises.{index} setup does not belong to its exercise"
                    )
                normalized["exercises"][index]["exercise_name"] = exercise["name"]
                normalized["exercises"][index]["setup_name"] = setup["name"]
                for substitute in item.substitution_exercise_ids:
                    await validate_owned_reference(
                        db, table="health_exercises", record_id=str(substitute), user=user
                    )
        elif kind == "chart":
            chart = CoachChartPayload.model_validate(normalized)
            analysis.validate_saved_chart(SavedAnalysisChartPayload(**chart.model_dump()))
        elif kind == "training_week":
            assert isinstance(parsed, CoachTrainingWeekPayload)
            for index, item in enumerate(parsed.sessions):
                child_kind, child = _training_week_workout(parsed, item)
                child_normalized, child_validation, child_warnings = await validate_proposal(
                    db,
                    user=user,
                    kind=child_kind,
                    payload=child.model_dump(mode="json"),
                )
                if not child_validation["valid"]:
                    issue = child_validation["issues"][0]
                    path = issue.get("path")
                    prefix = f"sessions.{index}"
                    raise FitnessConflictError(
                        f"{prefix}{'.' + path if path else ''}: {issue['message']}"
                    )
                warnings.extend(
                    {
                        **warning,
                        "message": f"Session {index + 1}: {warning['message']}",
                    }
                    for warning in child_warnings
                )
                if child_kind == "strength_workout":
                    normalized["sessions"][index]["exercises"] = child_normalized["exercises"]
        elif kind == "nutrition_change":
            assert isinstance(parsed, CoachNutritionChangePayload)
            if parsed.action_type == "nutrition_target":
                target = parsed.nutrition_target
                assert target is not None
                await validate_owned_reference(
                    db,
                    table="health_training_phases",
                    record_id=str(target.phase_id) if target.phase_id else None,
                    user=user,
                )
            elif parsed.action_type == "meal_template":
                template = parsed.meal_template
                assert template is not None
                for index, item in enumerate(template.items):
                    try:
                        if item.food_version_id:
                            await nutrition.readable_food_version(
                                db, user=user, version_id=str(item.food_version_id)
                            )
                        else:
                            await nutrition.readable_recipe_version(
                                db, user=user, version_id=str(item.recipe_version_id)
                            )
                    except (FitnessConflictError, LookupError) as exc:
                        raise FitnessConflictError(
                            f"meal_template.items.{index} does not reference a readable version"
                        ) from exc
        elif kind == "goal_adjustment":
            assert isinstance(parsed, CoachGoalAdjustmentPayload)
            goal = await owned_row(
                db,
                table="health_goals",
                record_id=str(parsed.goal_id),
                user=user,
            )
            if parsed.goal_name != goal["name"]:
                raise FitnessConflictError("The goal name no longer matches this draft")
            if parsed.action_type == "adjust_target":
                if goal["target_value"] != parsed.current_target_value:
                    raise FitnessConflictError(
                        "The accepted goal target value changed after this draft"
                    )
                current_date = (
                    date.fromisoformat(goal["target_date"]) if goal["target_date"] else None
                )
                if current_date != parsed.current_target_date:
                    raise FitnessConflictError(
                        "The accepted goal target date changed after this draft"
                    )
                if parsed.unit_key is not None and parsed.unit_key != goal["unit_key"]:
                    raise FitnessConflictError("The goal unit no longer matches this draft")
        elif kind == "calendar_change":
            assert isinstance(parsed, CoachCalendarChangePayload)
            session = await owned_row(
                db,
                table="health_planned_sessions",
                record_id=str(parsed.planned_session_id),
                user=user,
            )
            if session["title"] != parsed.title:
                raise FitnessConflictError("The planned-session title no longer matches this draft")
            if not _same_instant(session["scheduled_start_utc"], parsed.current_start_utc):
                raise FitnessConflictError("The planned-session time changed after this draft")
            if session["scheduled_date"] != (
                parsed.current_scheduled_date.isoformat() if parsed.current_scheduled_date else None
            ):
                raise FitnessConflictError("The planned-session date changed after this draft")
            if not _same_instant(
                session["time_window_start_utc"], parsed.current_window_start_utc
            ) or not _same_instant(session["time_window_end_utc"], parsed.current_window_end_utc):
                raise FitnessConflictError("The planned-session window changed after this draft")
        elif kind == "family_calendar_event":
            assert isinstance(parsed, CoachFamilyCalendarEventPayload)
            normalized["title"] = "Training"
            if parsed.planned_session_id is not None:
                session = await owned_row(
                    db,
                    table="health_planned_sessions",
                    record_id=str(parsed.planned_session_id),
                    user=user,
                )
                if session["status"] not in {"accepted", "scheduled", "in_progress"}:
                    raise FitnessConflictError(
                        "Only an accepted session can be shared with the family"
                    )
                if not _same_instant(session["scheduled_start_utc"], parsed.start_time):
                    raise FitnessConflictError("The private session no longer starts at this time")
                normalized["all_day"] = False
                if session["expected_duration_s"] is not None:
                    expected_end = parsed.start_time + timedelta(
                        seconds=float(session["expected_duration_s"])
                    )
                    if parsed.end_time is None:
                        normalized["end_time"] = expected_end.isoformat()
                    elif not _same_instant(parsed.end_time, expected_end):
                        raise FitnessConflictError(
                            "The private session duration no longer matches this draft"
                        )
        elif kind == "planned_meal_log":
            assert isinstance(parsed, CoachPlannedMealLogPayload)
            meal = await household_meals._planned_meal_row(
                db, user=user, meal_plan_id=str(parsed.meal_plan_id)
            )
            if (
                meal["meal_name"] != parsed.meal_name
                or meal["link_id"] != str(parsed.link_id)
                or meal["recipe_version_id"] != str(parsed.recipe_version_id)
            ):
                raise FitnessConflictError("The linked household meal changed after this draft")
            if parsed.meal_date is None:
                normalized["meal_date"] = meal["date"]
            elif meal["date"] != parsed.meal_date.isoformat():
                raise FitnessConflictError("The household meal date changed after this draft")
            if parsed.meal_type is None:
                normalized["meal_type"] = meal["meal_type"]
            elif meal["meal_type"] != parsed.meal_type:
                raise FitnessConflictError("The household meal time changed after this draft")
            if parsed.unit == "serving" and (
                meal["servings"] is None or float(meal["servings"]) <= 0
            ):
                raise FitnessConflictError("This meal is no longer available by serving")
            if parsed.unit == "g" and (
                meal["finished_weight_g"] is None or float(meal["finished_weight_g"]) <= 0
            ):
                raise FitnessConflictError("This meal is no longer available by grams")
            existing_log = await (
                await db.execute(
                    "SELECT 1 FROM health_food_log_entries WHERE family_id = ? "
                    "AND owner_user_id = ? AND source_meal_plan_id = ? "
                    "AND deleted_at IS NULL",
                    (user["family_id"], user["id"], str(parsed.meal_plan_id)),
                )
            ).fetchone()
            if existing_log is not None:
                raise FitnessConflictError("This planned meal is already in your diary")
            try:
                ZoneInfo(parsed.local_timezone)
            except ZoneInfoNotFoundError as exc:
                raise FitnessConflictError("The diary timezone is no longer available") from exc
        elif kind == "shopping_list":
            assert isinstance(parsed, CoachShoppingListPayload)
            for item in parsed.items:
                if item.meal_plan_id is None:
                    continue
                exists = await (
                    await db.execute(
                        "SELECT 1 FROM meal_plans WHERE id = ? AND family_id = ? "
                        "AND deleted_at IS NULL",
                        (str(item.meal_plan_id), user["family_id"]),
                    )
                ).fetchone()
                if exists is None:
                    raise FitnessConflictError(
                        "A linked household meal plan is no longer available"
                    )
        elif kind == "family_task":
            assert isinstance(parsed, CoachFamilyTaskPayload)
            if parsed.assigned_to is not None:
                if await family_person_type(db, user["family_id"], parsed.assigned_to) is None:
                    raise FitnessConflictError("The task assignee is not in this family")
        elif kind == "fitness_reminder":
            assert isinstance(parsed, CoachFitnessReminderPayload)
            if parsed.remind_at_utc <= datetime.now(timezone.utc):
                raise FitnessConflictError("The reminder time has already passed")
            if parsed.planned_session_id is not None:
                session = await owned_row(
                    db,
                    table="health_planned_sessions",
                    record_id=str(parsed.planned_session_id),
                    user=user,
                )
                if session["status"] not in {"accepted", "scheduled", "in_progress"}:
                    raise FitnessConflictError(
                        "Only a current planned session can be linked to a reminder"
                    )
    except (FitnessConflictError, LookupError, ValueError) as exc:
        return (
            normalized,
            {
                "valid": False,
                "issues": [{"code": "domain_validation", "path": None, "message": str(exc)[:500]}],
            },
            warnings,
        )
    return normalized, {"valid": True, "issues": []}, warnings[:20]


_PREVIEW_WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_PREVIEW_MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)


def _preview_date(value: date) -> str:
    return (
        f"{_PREVIEW_WEEKDAYS[value.weekday()]} {value.day} "
        f"{_PREVIEW_MONTHS[value.month - 1]} {value.year}"
    )


def _preview_datetime(value: datetime, *, timezone_name: str | None = None) -> str:
    displayed = value.astimezone(ZoneInfo(timezone_name)) if timezone_name else value
    zone = displayed.tzname() or "UTC"
    return f"{_preview_date(displayed.date())}, {displayed:%H:%M} {zone}"


async def _proposal_preview(db, *, user: dict, kind: str, payload: dict) -> dict | None:
    """Project a typed action into review copy without internal identifiers."""
    if kind == "family_calendar_event":
        parsed = CoachFamilyCalendarEventPayload.model_validate(payload)
        change = [
            f"Add “{parsed.title}” to Calendar",
            f"Starts {_preview_datetime(parsed.start_time)}",
        ]
        if parsed.end_time is not None:
            change.append(f"Ends {_preview_datetime(parsed.end_time)}")
        if parsed.location:
            change.append(f"Location: {parsed.location}")
        change.append("Description: Training logistics")
        return {"change": change, "visibility": "Visible to your family"}
    if kind == "planned_meal_log":
        parsed = CoachPlannedMealLogPayload.model_validate(payload)
        change = [
            f"Add {parsed.portion:g} {parsed.unit} of {parsed.meal_name} to your diary",
        ]
        if parsed.meal_type is not None and parsed.meal_date is not None:
            change.append(
                f"{parsed.meal_type.title()} planned for {_preview_date(parsed.meal_date)}"
            )
        change.append(
            "Logged " + _preview_datetime(parsed.logged_at_utc, timezone_name=parsed.local_timezone)
        )
        if parsed.notes:
            change.append(f"Notes: {parsed.notes}")
        return {"change": change, "visibility": "Private to you"}
    if kind == "shopping_list":
        parsed = CoachShoppingListPayload.model_validate(payload)
        change = []
        for item in parsed.items:
            details = [value for value in (item.quantity, item.category) if value]
            suffix = f" — {' · '.join(details)}" if details else ""
            change.append(f"Add {item.name} to Shopping{suffix}")
        return {"change": change, "visibility": "Visible to your family"}
    if kind == "family_task":
        parsed = CoachFamilyTaskPayload.model_validate(payload)
        change = [f"Add task “{parsed.title}”"]
        if parsed.description:
            change.append(f"Details: {parsed.description}")
        if parsed.assigned_to:
            person = await (
                await db.execute(
                    "SELECT name FROM users WHERE id = ? AND family_id = ? "
                    "AND deleted_at IS NULL UNION ALL SELECT name FROM children "
                    "WHERE id = ? AND family_id = ? AND deleted_at IS NULL LIMIT 1",
                    (
                        parsed.assigned_to,
                        user["family_id"],
                        parsed.assigned_to,
                        user["family_id"],
                    ),
                )
            ).fetchone()
            if person is not None:
                change.append(f"Assigned to {person['name']}")
        if parsed.actionable_from:
            change.append(f"Available {_preview_datetime(parsed.actionable_from)}")
        if parsed.due_date:
            change.append(f"Due {_preview_datetime(parsed.due_date)}")
        priority = {1: "Low", 2: "Normal", 3: "High"}[parsed.priority]
        change.append(f"Priority {priority}")
        return {"change": change, "visibility": "Visible to your family"}
    if kind == "fitness_reminder":
        parsed = CoachFitnessReminderPayload.model_validate(payload)
        change = [
            f"Add reminder “{parsed.title}”",
            f"Remind {_preview_datetime(parsed.remind_at_utc)}",
        ]
        if parsed.notes:
            change.append(f"Notes: {parsed.notes}")
        if parsed.planned_session_id:
            change.append("Linked to your planned session")
        return {"change": change, "visibility": "Private to you"}
    return None


def _proposal_response(row, *, preview: dict | None = None) -> dict:
    data = decoded_row(
        row,
        json_fields={"payload_json", "validation_json", "warnings_json"},
    )
    confirmable, review_only_reason = proposal_confirmability(
        data["proposal_kind"], data["payload"]
    )
    confirmable = confirmable and bool(data["validation"].get("valid"))
    return {
        "id": data["id"],
        "kind": data["proposal_kind"],
        "payload": data["payload"],
        "preview": preview,
        "validation": data["validation"],
        "warnings": data["warnings"],
        "confirmable": confirmable,
        "review_only_reason": review_only_reason,
        "expires_at": data["expires_at"],
    }


async def store_proposal(
    db,
    *,
    user: dict,
    kind: str,
    payload: dict,
    evidence: list[dict],
    provider: str,
    model: str,
) -> dict:
    if kind not in PROPOSAL_KINDS:
        raise FitnessConflictError("Coach proposal kind is not registered")
    normalized, validation, warnings = await validate_proposal(
        db, user=user, kind=kind, payload=payload
    )
    identifier = new_id()
    expires_at = datetime.now(timezone.utc) + timedelta(
        minutes=settings.fitness_coach_proposal_ttl_minutes
    )
    await insert_owned(
        db,
        table="health_coach_proposals",
        record_id=identifier,
        values={
            "proposal_kind": kind,
            "payload_json": normalized,
            "validation_json": validation,
            "warnings_json": warnings,
            "evidence_json": [item["public"] for item in evidence],
            "model_provider": provider,
            "model_id": model,
            "status": "pending" if validation["valid"] else "invalid",
            "expires_at": expires_at.isoformat(),
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    row = await owned_row(db, table="health_coach_proposals", record_id=identifier, user=user)
    preview = (
        await _proposal_preview(db, user=user, kind=kind, payload=normalized)
        if validation["valid"]
        else None
    )
    result = _proposal_response(row, preview=preview)
    return result


def _recommendation_response(row) -> dict:
    data = decoded_row(
        row,
        json_fields={
            "goal_ids_json",
            "finding_references_json",
            "evidence_json",
            "expected_effect_json",
        },
    )
    return {
        "id": data["id"],
        "revision": data["revision"],
        "created_at": data["created_at"],
        "updated_at": data["updated_at"],
        "recommendation_type": data["recommendation_type"],
        "recommendation_text": data["recommendation_text"],
        "evidence": data["evidence"],
        "finding_references": data["finding_references"],
        "expected_effect": data.get("expected_effect"),
        "status": data["status"],
        "user_feedback": data["user_feedback"],
        "followed_state": data["followed_state"],
        "outcome_review": data["outcome_review"],
        "model_provider": data["model_provider"],
        "model_id": data["model_id"],
    }


async def store_recommendation(
    db,
    *,
    user: dict,
    recommendation_type: str,
    text: str,
    expected_effect: str | dict | None,
    evidence: list[dict],
    provider: str,
    model: str,
    proposal_id: str | None,
) -> dict:
    identifier = new_id()
    await insert_owned(
        db,
        table="health_coach_recommendations",
        record_id=identifier,
        values={
            "recommendation_type": recommendation_type[:80],
            "goal_ids_json": [],
            "finding_references_json": [item["public"]["id"] for item in evidence],
            "evidence_json": [item["public"] for item in evidence],
            "recommendation_text": text[:2_000],
            "proposal_id": proposal_id,
            "expected_effect_json": json_text(expected_effect)
            if expected_effect is not None
            else None,
            "model_provider": provider,
            "model_id": model,
            "status": "active",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    return _recommendation_response(
        await owned_row(db, table="health_coach_recommendations", record_id=identifier, user=user)
    )


async def ensure_weekly_review_markers(db, *, reference: datetime | None = None) -> int:
    """Create one inert weekly-review draft marker per active Fitness owner.

    This never calls Hermes. It merely makes the optional weekly review visible;
    evidence is assembled and sent only after the owner explicitly messages Coach.
    """
    instant = (reference or datetime.now(timezone.utc)).astimezone(timezone.utc)
    week_start = (instant.date() - timedelta(days=instant.weekday())).isoformat()
    marker = json_text({"week_start": week_start})
    users = await _rows(
        db,
        "SELECT DISTINCT u.* FROM users u JOIN health_user_settings s "
        "ON s.owner_user_id = u.id AND s.family_id = u.family_id "
        "AND s.deleted_at IS NULL WHERE u.family_id IS NOT NULL "
        "AND u.deleted_at IS NULL ORDER BY u.id",
    )
    created = 0
    for user in users:
        existing = await (
            await db.execute(
                "SELECT 1 FROM health_coach_recommendations WHERE family_id = ? "
                "AND owner_user_id = ? AND recommendation_type = 'weekly_review_draft' "
                "AND expected_effect_json = ? AND deleted_at IS NULL LIMIT 1",
                (user["family_id"], user["id"], marker),
            )
        ).fetchone()
        if existing is not None:
            continue
        await store_recommendation(
            db,
            user=user,
            recommendation_type="weekly_review_draft",
            text=(
                "Your weekly Fitness review is ready. Open Coach when you want to "
                "review what worked, the main constraint, and one or two changes."
            ),
            expected_effect={"week_start": week_start},
            evidence=[],
            provider="deterministic",
            model="hausklar-scheduler",
            proposal_id=None,
        )
        created += 1
    return created


async def list_recommendations(db, *, user: dict) -> list[dict]:
    rows = await _rows(
        db,
        "SELECT * FROM health_coach_recommendations WHERE family_id = ? "
        "AND owner_user_id = ? AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 50",
        (user["family_id"], user["id"]),
    )
    return [_recommendation_response(row) for row in rows]


async def record_feedback(
    db,
    *,
    user: dict,
    recommendation_id: str,
    body: CoachRecommendationFeedback,
) -> dict:
    await owned_row(
        db, table="health_coach_recommendations", record_id=recommendation_id, user=user
    )
    if body.feedback in {"rejected", "disliked", "analysis_inaccurate"}:
        status = "rejected"
    elif body.feedback.startswith("tried_"):
        status = "followed"
    elif body.feedback == "accepted":
        status = "accepted"
    else:
        status = "active"
    await update_owned(
        db,
        table="health_coach_recommendations",
        record_id=recommendation_id,
        values={
            "user_feedback": body.feedback,
            "followed_state": body.followed_state,
            "outcome_review": body.outcome_review,
            "status": status,
        },
        user=user,
        record_sync_change=False,
    )
    return _recommendation_response(
        await owned_row(
            db, table="health_coach_recommendations", record_id=recommendation_id, user=user
        )
    )


def _goal_links(goal_ids: list[UUID]) -> list[PlannedSessionGoalLinkPayload]:
    return [
        PlannedSessionGoalLinkPayload(
            goal_id=identifier,
            role="primary" if index == 0 else "secondary",
        )
        for index, identifier in enumerate(goal_ids)
    ]


async def _confirm_run(db, *, user: dict, payload: CoachRunWorkoutPayload) -> list[str]:
    definition_id, version_id, session_id = new_id(), new_id(), new_id()
    accepted_at = datetime.now(timezone.utc)
    version = WorkoutVersionPayload(
        id=UUID(version_id),
        title=payload.title,
        purpose=payload.purpose,
        estimated_duration_s=payload.estimated_duration_s,
        estimated_distance_m=payload.estimated_distance_m,
        structured_summary={
            "expected_difficulty": payload.expected_difficulty,
            "route_assumption": payload.route_assumption,
            "terrain_assumption": payload.terrain_assumption,
            "goal_reason": payload.goal_reason,
            "garmin_limitations": payload.garmin_limitations,
        },
        version_source="coach",
        accepted_at=accepted_at,
        run_steps=payload.steps,
        run_cues=payload.cues,
    )
    await templates.upsert_workout_definition(
        db,
        user=user,
        body=WorkoutDefinitionPayload(
            id=UUID(definition_id),
            sport_key="running",
            name=payload.title,
            description=payload.purpose,
            version=version,
        ),
    )
    await planning.upsert_planned_session(
        db,
        user=user,
        body=PlannedSessionPayload(
            id=UUID(session_id),
            sport_key="running",
            title=payload.title,
            local_timezone=payload.local_timezone,
            workout_version_id=UUID(version_id),
            status="scheduled",
            session_source="coach",
            scheduled_start_utc=payload.scheduled_start_utc,
            scheduled_date=payload.scheduled_date,
            expected_duration_s=payload.estimated_duration_s,
            expected_distance_m=payload.estimated_distance_m,
            reason_for_placement=payload.goal_reason,
            goal_links=_goal_links(payload.goal_ids),
            intended_gear_ids=payload.intended_gear_ids,
        ),
    )
    return [definition_id, version_id, session_id]


async def _confirm_strength(db, *, user: dict, payload: CoachStrengthWorkoutPayload) -> list[str]:
    definition_id, version_id, session_id = new_id(), new_id(), new_id()
    exercises = [
        PlannedExercisePayload(
            exercise_id=item.exercise_id,
            exercise_setup_id=item.exercise_setup_id,
            sequence=item.sequence,
            superset_group_key=item.superset_group_key,
            substitution_exercise_ids=item.substitution_exercise_ids,
            notes=item.notes,
            planned_sets=item.sets,
        )
        for item in payload.exercises
    ]
    await templates.upsert_workout_definition(
        db,
        user=user,
        body=WorkoutDefinitionPayload(
            id=UUID(definition_id),
            sport_key="strength",
            name=payload.title,
            description=payload.purpose,
            version=WorkoutVersionPayload(
                id=UUID(version_id),
                title=payload.title,
                purpose=payload.purpose,
                estimated_duration_s=payload.estimated_duration_s,
                structured_summary={
                    "location": payload.location,
                    "goal_reason": payload.goal_reason,
                },
                version_source="coach",
                accepted_at=datetime.now(timezone.utc),
                exercise_items=exercises,
            ),
        ),
    )
    await planning.upsert_planned_session(
        db,
        user=user,
        body=PlannedSessionPayload(
            id=UUID(session_id),
            sport_key="strength",
            title=payload.title,
            local_timezone=payload.local_timezone,
            workout_version_id=UUID(version_id),
            status="scheduled",
            session_source="coach",
            scheduled_start_utc=payload.scheduled_start_utc,
            scheduled_date=payload.scheduled_date,
            expected_duration_s=payload.estimated_duration_s,
            reason_for_placement=payload.goal_reason,
            goal_links=_goal_links(payload.goal_ids),
        ),
    )
    return [definition_id, version_id, session_id]


async def _confirm_training_week(db, *, user: dict, payload: CoachTrainingWeekPayload) -> list[str]:
    result_ids: list[str] = []
    for item in payload.sessions:
        kind, workout = _training_week_workout(payload, item)
        if kind == "run_workout":
            result_ids.extend(await _confirm_run(db, user=user, payload=workout))
        else:
            result_ids.extend(await _confirm_strength(db, user=user, payload=workout))
    return result_ids


async def _confirm_nutrition_change(
    db, *, user: dict, payload: CoachNutritionChangePayload
) -> tuple[list[str], str]:
    if payload.action_type == "nutrition_target":
        target = payload.nutrition_target
        assert target is not None
        identifier = new_id()
        body = target.model_copy(update={"id": None, "client_id": None, "client_timestamp": None})
        await nutrition.upsert_nutrition_target(db, user=user, body=body, record_id=identifier)
        return [identifier], "Nutrition target saved."
    if payload.action_type == "meal_template":
        template = payload.meal_template
        assert template is not None
        identifier = new_id()
        body = template.model_copy(update={"id": None, "client_id": None, "client_timestamp": None})
        await nutrition.create_meal_template(db, user=user, body=body, record_id=identifier)
        return [identifier], "Meal template saved."
    raise FitnessConflictError("Review-only nutrition guidance has no stored action")


async def _confirm_goal_adjustment(
    db, *, user: dict, payload: CoachGoalAdjustmentPayload
) -> list[str]:
    if payload.action_type != "adjust_target":
        raise FitnessConflictError("Review-only goal guidance has no stored action")
    values: dict[str, Any] = {}
    if payload.proposed_target_value is not None:
        values["target_value"] = payload.proposed_target_value
    if payload.proposed_target_date is not None:
        values["target_date"] = payload.proposed_target_date
    await planning.patch_goal(
        db,
        user=user,
        goal_id=str(payload.goal_id),
        body=GoalPatch(**values),
    )
    return [str(payload.goal_id)]


async def _confirm_calendar_change(
    db, *, user: dict, payload: CoachCalendarChangePayload
) -> list[str]:
    # Only the deterministically validated scheduling fields change. All workout,
    # goal, exercise and gear links remain untouched.
    await update_owned(
        db,
        table="health_planned_sessions",
        record_id=str(payload.planned_session_id),
        values={
            "scheduled_start_utc": payload.proposed_start_utc,
            "scheduled_date": None,
            "time_window_start_utc": None,
            "time_window_end_utc": None,
        },
        user=user,
    )
    return [str(payload.planned_session_id)]


async def _confirm_family_calendar_event(
    db, *, user: dict, payload: CoachFamilyCalendarEventPayload
) -> list[str]:
    identifier = new_id()
    await create_or_replay_calendar_event(
        db,
        CalendarEventCreate(
            id=UUID(identifier),
            title=payload.title,
            description="Training logistics",
            start_time=payload.start_time.isoformat(),
            end_time=payload.end_time.isoformat() if payload.end_time else None,
            all_day=payload.all_day,
            location=payload.location,
            family_member_ids=None,
            affected_member_ids=None,
            event_type="other",
            exertion=0,
        ),
        record_id=identifier,
        user=user,
        client_id=None,
        client_timestamp=None,
    )
    return [identifier]


async def _confirm_planned_meal_log(
    db, *, user: dict, payload: CoachPlannedMealLogPayload
) -> list[str]:
    identifier = new_id()
    await household_meals.log_planned_household_meal(
        db,
        user=user,
        meal_plan_id=str(payload.meal_plan_id),
        body=PlannedMealLogRequest(
            id=UUID(identifier),
            portion=payload.portion,
            unit=payload.unit,
            logged_at_utc=payload.logged_at_utc,
            local_timezone=payload.local_timezone,
            notes=payload.notes,
        ),
    )
    return [identifier]


async def _confirm_shopping_list(db, *, user: dict, payload: CoachShoppingListPayload) -> list[str]:
    identifiers: list[str] = []
    for item in payload.items:
        identifier = new_id()
        await create_or_replay_shopping_item(
            db,
            ShoppingItemCreate(
                id=UUID(identifier),
                name=item.name,
                quantity=item.quantity,
                category=item.category,
                meal_plan_id=str(item.meal_plan_id) if item.meal_plan_id else None,
            ),
            record_id=identifier,
            user=user,
        )
        identifiers.append(identifier)
    return identifiers


async def _confirm_family_task(db, *, user: dict, payload: CoachFamilyTaskPayload) -> list[str]:
    identifier = new_id()
    await create_or_replay_task(
        db,
        TaskCreate(
            id=UUID(identifier),
            title=payload.title,
            description=payload.description,
            assigned_to=payload.assigned_to,
            due_date=payload.due_date.isoformat() if payload.due_date else None,
            category="household",
            priority=payload.priority,
            actionable_from=(
                payload.actionable_from.isoformat() if payload.actionable_from else None
            ),
        ),
        record_id=identifier,
        user=user,
        client_id=None,
        client_timestamp=None,
    )
    return [identifier]


async def _confirm_fitness_reminder(
    db, *, user: dict, payload: CoachFitnessReminderPayload
) -> list[str]:
    identifier = new_id()
    await insert_owned(
        db,
        table="health_fitness_reminders",
        record_id=identifier,
        values={
            "title": payload.title,
            "remind_at_utc": payload.remind_at_utc,
            "notes": payload.notes,
            "planned_session_id": payload.planned_session_id,
            "status": "active",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    return [identifier]


def _proposal_destinations(
    kind: str, payload: dict, result_ids: list[str]
) -> list[CoachProposalDestination]:
    if kind in {"run_workout", "strength_workout"} and len(result_ids) >= 3:
        return [
            CoachProposalDestination(
                kind="planned_session",
                target=result_ids[2],
                label=f"Open {payload.get('title', 'planned session')}",
            )
        ]
    if kind == "training_week":
        sessions = payload.get("sessions") or []
        return [
            CoachProposalDestination(
                kind="planned_session",
                target=result_ids[index * 3 + 2],
                label=f"Open {item.get('title', 'planned session')}",
            )
            for index, item in enumerate(sessions)
            if index * 3 + 2 < len(result_ids)
        ]
    if kind == "nutrition_change" and result_ids:
        destination_kind = (
            "meal_template" if payload.get("action_type") == "meal_template" else "nutrition_target"
        )
        return [
            CoachProposalDestination(
                kind=destination_kind,
                target=result_ids[0],
                label=(
                    "Open meal template"
                    if destination_kind == "meal_template"
                    else "Open nutrition target"
                ),
            )
        ]
    if kind == "goal_adjustment" and result_ids:
        return [CoachProposalDestination(kind="goal", target=result_ids[0], label="Open goal")]
    if kind == "calendar_change" and result_ids:
        return [
            CoachProposalDestination(
                kind="planned_session",
                target=result_ids[0],
                label="Open moved session",
            )
        ]
    if kind == "family_calendar_event" and result_ids:
        return [
            CoachProposalDestination(
                kind="calendar_event",
                target=result_ids[0],
                label="Open family calendar event",
            )
        ]
    if kind == "planned_meal_log" and result_ids:
        return [
            CoachProposalDestination(
                kind="food_log",
                target=result_ids[0],
                label="Open diary entry",
            )
        ]
    if kind == "shopping_list" and result_ids:
        return [
            CoachProposalDestination(
                kind="shopping",
                target=result_ids[0],
                label="Open Shopping",
            )
        ]
    if kind == "family_task" and result_ids:
        return [
            CoachProposalDestination(kind="task", target=result_ids[0], label="Open family task")
        ]
    if kind == "fitness_reminder" and result_ids:
        return [
            CoachProposalDestination(
                kind="fitness_reminder",
                target=result_ids[0],
                label="Open private reminder",
            )
        ]
    if kind == "chart" and result_ids:
        return [
            CoachProposalDestination(
                kind="analysis_chart",
                target=result_ids[0],
                label="Open analysis chart",
            )
        ]
    return []


async def confirm_proposal(db, *, user: dict, proposal_id: str) -> CoachProposalDecision:
    await db.execute("BEGIN IMMEDIATE")
    row = await owned_row(db, table="health_coach_proposals", record_id=proposal_id, user=user)
    if row["status"] == "confirmed":
        try:
            result_ids = json.loads(row["result_ids_json"] or "[]")
        except json.JSONDecodeError:
            result_ids = []
        payload = json.loads(row["payload_json"])
        return CoachProposalDecision(
            status="confirmed",
            message="This proposal was already confirmed.",
            result_ids=result_ids,
            next_destinations=_proposal_destinations(row["proposal_kind"], payload, result_ids),
        )
    expires = datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
    if expires <= datetime.now(timezone.utc):
        if row["status"] not in {"expired", "declined"}:
            await update_owned(
                db,
                table="health_coach_proposals",
                record_id=proposal_id,
                values={"status": "expired"},
                user=user,
                record_sync_change=False,
            )
        return CoachProposalDecision(
            status="expired", message="This draft expired. Ask the coach for a fresh proposal."
        )
    if row["status"] != "pending":
        return CoachProposalDecision(
            status="invalid", message="This proposal is not pending and cannot be confirmed."
        )
    kind = row["proposal_kind"]
    payload = json.loads(row["payload_json"])
    confirmable, review_only_reason = proposal_confirmability(kind, payload)
    if not confirmable:
        return CoachProposalDecision(
            status="invalid",
            message=review_only_reason
            or "This draft is review-only and has no allowlisted stored action.",
        )
    normalized, validation, _ = await validate_proposal(db, user=user, kind=kind, payload=payload)
    if not validation["valid"]:
        await update_owned(
            db,
            table="health_coach_proposals",
            record_id=proposal_id,
            values={"status": "invalid", "validation_json": validation},
            user=user,
            record_sync_change=False,
        )
        return CoachProposalDecision(
            status="invalid",
            message="The linked source changed. Review a fresh proposal before saving.",
        )
    if kind == "run_workout":
        result_ids = await _confirm_run(
            db, user=user, payload=CoachRunWorkoutPayload.model_validate(normalized)
        )
        message = "Run workout version and planned session saved."
    elif kind == "strength_workout":
        result_ids = await _confirm_strength(
            db, user=user, payload=CoachStrengthWorkoutPayload.model_validate(normalized)
        )
        message = "Strength workout version and planned session saved."
    elif kind == "training_week":
        result_ids = await _confirm_training_week(
            db,
            user=user,
            payload=CoachTrainingWeekPayload.model_validate(normalized),
        )
        message = "Training-week workout definitions and planned sessions saved."
    elif kind == "nutrition_change":
        result_ids, message = await _confirm_nutrition_change(
            db,
            user=user,
            payload=CoachNutritionChangePayload.model_validate(normalized),
        )
    elif kind == "goal_adjustment":
        result_ids = await _confirm_goal_adjustment(
            db,
            user=user,
            payload=CoachGoalAdjustmentPayload.model_validate(normalized),
        )
        message = "Goal target updated."
    elif kind == "calendar_change":
        result_ids = await _confirm_calendar_change(
            db,
            user=user,
            payload=CoachCalendarChangePayload.model_validate(normalized),
        )
        message = "Planned session moved."
    elif kind == "family_calendar_event":
        result_ids = await _confirm_family_calendar_event(
            db,
            user=user,
            payload=CoachFamilyCalendarEventPayload.model_validate(normalized),
        )
        message = "Training logistics added to the family Calendar."
    elif kind == "planned_meal_log":
        result_ids = await _confirm_planned_meal_log(
            db,
            user=user,
            payload=CoachPlannedMealLogPayload.model_validate(normalized),
        )
        message = "Planned meal added to your private diary."
    elif kind == "shopping_list":
        result_ids = await _confirm_shopping_list(
            db,
            user=user,
            payload=CoachShoppingListPayload.model_validate(normalized),
        )
        message = "Reviewed items added to Shopping."
    elif kind == "family_task":
        result_ids = await _confirm_family_task(
            db,
            user=user,
            payload=CoachFamilyTaskPayload.model_validate(normalized),
        )
        message = "Task added for the family."
    elif kind == "fitness_reminder":
        result_ids = await _confirm_fitness_reminder(
            db,
            user=user,
            payload=CoachFitnessReminderPayload.model_validate(normalized),
        )
        message = "Private Fitness reminder saved."
    else:
        chart = CoachChartPayload.model_validate(normalized)
        saved = await analysis.save_chart(
            db,
            user=user,
            body=SavedAnalysisChartPayload(**chart.model_dump()),
            commit=False,
        )
        result_ids = [saved["id"]]
        message = "Analysis chart saved."
    timestamp = now_iso()
    await update_owned(
        db,
        table="health_coach_proposals",
        record_id=proposal_id,
        values={
            "status": "confirmed",
            "confirmed_at": timestamp,
            "result_ids_json": result_ids,
        },
        user=user,
        now=timestamp,
        record_sync_change=False,
    )
    return CoachProposalDecision(
        status="confirmed",
        message=message,
        result_ids=result_ids,
        next_destinations=_proposal_destinations(kind, normalized, result_ids),
    )


def _after(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return False
    left_value = datetime.fromisoformat(left.replace("Z", "+00:00"))
    right_value = datetime.fromisoformat(right.replace("Z", "+00:00"))
    if left_value.tzinfo is None:
        left_value = left_value.replace(tzinfo=timezone.utc)
    if right_value.tzinfo is None:
        right_value = right_value.replace(tzinfo=timezone.utc)
    return left_value.astimezone(timezone.utc) > right_value.astimezone(timezone.utc)


async def _soft_delete_children(
    db,
    *,
    user: dict,
    table: str,
    where: str,
    params: tuple,
    timestamp: str,
) -> list[str]:
    identifiers = await save_owned_rows_history(
        db, table=table, user=user, where=f"{where} AND deleted_at IS NULL", params=params
    )
    for identifier in identifiers:
        await soft_delete_owned(
            db,
            table=table,
            record_id=identifier,
            user=user,
            now=timestamp,
            record_sync_change=False,
            record_history=False,
        )
    return identifiers


async def _descendant_rows(db, *, user: dict, session_id: str, version_id: str) -> list[dict]:
    rows: list[dict] = []

    async def collect(table: str, where: str, params: tuple) -> list[dict]:
        found = await _rows(
            db,
            f"SELECT * FROM {table} WHERE family_id = ? AND owner_user_id = ? AND {where}",
            (user["family_id"], user["id"], *params),
        )
        rows.extend(found)
        return found

    planned_exercises = await collect(
        "health_planned_session_exercises",
        "planned_session_id = ?",
        (session_id,),
    )
    for exercise in planned_exercises:
        for table in (
            "health_planned_session_exercise_substitutions",
            "health_planned_session_sets",
        ):
            await collect(
                table,
                "planned_session_exercise_id = ?",
                (exercise["id"],),
            )
    for table in (
        "health_planned_session_goal_links",
        "health_planned_session_gear_links",
    ):
        await collect(table, "planned_session_id = ?", (session_id,))
    strength_exercises = await collect(
        "health_strength_workout_exercises",
        "workout_version_id = ?",
        (version_id,),
    )
    for exercise in strength_exercises:
        for table in (
            "health_strength_workout_exercise_substitutions",
            "health_strength_planned_sets",
        ):
            await collect(table, "workout_exercise_id = ?", (exercise["id"],))
    for table in ("health_run_workout_cues", "health_run_workout_steps"):
        await collect(table, "workout_version_id = ?", (version_id,))
    return rows


async def _soft_delete_parent_if_active(
    db, *, user: dict, table: str, record_id: str, timestamp: str
) -> None:
    row = await owned_row(
        db,
        table=table,
        record_id=record_id,
        user=user,
        include_deleted=True,
    )
    if row["deleted_at"] is None:
        await soft_delete_owned(
            db,
            table=table,
            record_id=record_id,
            user=user,
            now=timestamp,
            record_sync_change=table != "health_workout_versions",
        )


async def _undo_planned_session(db, *, user: dict, session_id: str, timestamp: str) -> None:
    exercise_ids = await _soft_delete_children(
        db,
        user=user,
        table="health_planned_session_exercises",
        where="planned_session_id = ?",
        params=(session_id,),
        timestamp=timestamp,
    )
    for exercise_id in exercise_ids:
        for table in (
            "health_planned_session_exercise_substitutions",
            "health_planned_session_sets",
        ):
            await _soft_delete_children(
                db,
                user=user,
                table=table,
                where="planned_session_exercise_id = ?",
                params=(exercise_id,),
                timestamp=timestamp,
            )
    for table in (
        "health_planned_session_goal_links",
        "health_planned_session_gear_links",
    ):
        await _soft_delete_children(
            db,
            user=user,
            table=table,
            where="planned_session_id = ?",
            params=(session_id,),
            timestamp=timestamp,
        )
    await _soft_delete_parent_if_active(
        db,
        user=user,
        table="health_planned_sessions",
        record_id=session_id,
        timestamp=timestamp,
    )


async def _undo_workout_version(db, *, user: dict, version_id: str, timestamp: str) -> None:
    exercise_ids = await _soft_delete_children(
        db,
        user=user,
        table="health_strength_workout_exercises",
        where="workout_version_id = ?",
        params=(version_id,),
        timestamp=timestamp,
    )
    for exercise_id in exercise_ids:
        for table in (
            "health_strength_workout_exercise_substitutions",
            "health_strength_planned_sets",
        ):
            await _soft_delete_children(
                db,
                user=user,
                table=table,
                where="workout_exercise_id = ?",
                params=(exercise_id,),
                timestamp=timestamp,
            )
    for table in ("health_run_workout_cues", "health_run_workout_steps"):
        await _soft_delete_children(
            db,
            user=user,
            table=table,
            where="workout_version_id = ?",
            params=(version_id,),
            timestamp=timestamp,
        )
    await _soft_delete_parent_if_active(
        db,
        user=user,
        table="health_workout_versions",
        record_id=version_id,
        timestamp=timestamp,
    )


async def _undo_created_records(
    db,
    *,
    user: dict,
    kind: str,
    payload: dict,
    result_ids: list[str],
    confirmed_at: str,
) -> CoachProposalUndoDecision:
    if kind in {"run_workout", "strength_workout", "training_week"}:
        if not result_ids or len(result_ids) % 3:
            return CoachProposalUndoDecision(
                status="invalid",
                message="The confirmed workout result audit is incomplete.",
            )
        parents = [
            (table, result_ids[index])
            for offset in range(0, len(result_ids), 3)
            for index, table in (
                (offset, "health_workout_definitions"),
                (offset + 1, "health_workout_versions"),
                (offset + 2, "health_planned_sessions"),
            )
            if index < len(result_ids)
        ]
    elif kind == "nutrition_change" and result_ids:
        parents = [
            (
                "health_meal_templates"
                if payload.get("action_type") == "meal_template"
                else "health_nutrition_targets",
                result_ids[0],
            )
        ]
    elif kind == "chart" and result_ids:
        parents = [("health_saved_analysis_charts", result_ids[0])]
    elif kind == "planned_meal_log" and result_ids:
        parents = [("health_food_log_entries", result_ids[0])]
    elif kind == "fitness_reminder" and result_ids:
        parents = [("health_fitness_reminders", result_ids[0])]
    else:
        return CoachProposalUndoDecision(
            status="invalid", message="This proposal did not create reversible records."
        )
    rows = [
        await owned_row(db, table=table, record_id=identifier, user=user, include_deleted=True)
        for table, identifier in parents
    ]
    descendants: list[dict] = []
    if kind in {"run_workout", "strength_workout", "training_week"}:
        for offset in range(0, len(result_ids), 3):
            descendants.extend(
                await _descendant_rows(
                    db,
                    user=user,
                    session_id=result_ids[offset + 2],
                    version_id=result_ids[offset + 1],
                )
            )
    elif parents and parents[0][0] == "health_meal_templates":
        descendants = await _rows(
            db,
            "SELECT * FROM health_meal_template_items WHERE family_id = ? "
            "AND owner_user_id = ? AND meal_template_id = ?",
            (user["family_id"], user["id"], parents[0][1]),
        )
    active = [row for row in rows + descendants if row["deleted_at"] is None]
    if not active:
        return CoachProposalUndoDecision(
            status="already_undone",
            message="This proposal was already undone.",
            affected_ids=result_ids,
        )
    if any(_after(row["updated_at"], confirmed_at) for row in active):
        return CoachProposalUndoDecision(
            status="conflict",
            message="A created record changed after confirmation, so it was not removed.",
        )
    timestamp = now_iso()
    if kind in {"run_workout", "strength_workout", "training_week"}:
        for offset in range(0, len(result_ids), 3):
            definition_id, version_id, session_id = result_ids[offset : offset + 3]
            await _undo_planned_session(db, user=user, session_id=session_id, timestamp=timestamp)
            await _undo_workout_version(db, user=user, version_id=version_id, timestamp=timestamp)
            await _soft_delete_parent_if_active(
                db,
                user=user,
                table="health_workout_definitions",
                record_id=definition_id,
                timestamp=timestamp,
            )
    else:
        table, identifier = parents[0]
        if table == "health_meal_templates":
            await _soft_delete_children(
                db,
                user=user,
                table="health_meal_template_items",
                where="meal_template_id = ?",
                params=(identifier,),
                timestamp=timestamp,
            )
        await soft_delete_owned(db, table=table, record_id=identifier, user=user, now=timestamp)
    return CoachProposalUndoDecision(
        status="undone",
        message="The records created by this proposal were removed.",
        affected_ids=result_ids,
    )


async def _undo_family_created_records(
    db,
    *,
    user: dict,
    kind: str,
    result_ids: list[str],
    confirmed_at: str,
) -> CoachProposalUndoDecision:
    table = {
        "family_calendar_event": "calendar_events",
        "shopping_list": "shopping_items",
        "family_task": "tasks",
    }[kind]
    rows = await _rows(
        db,
        f"SELECT * FROM {table} WHERE family_id = ? AND created_by = ? "
        f"AND id IN ({','.join('?' for _ in result_ids)})",
        (user["family_id"], user["id"], *result_ids),
    )
    if len(rows) != len(result_ids):
        return CoachProposalUndoDecision(
            status="invalid",
            message="The confirmed family action audit is incomplete.",
        )
    related: list[dict] = []
    if kind == "family_task":
        related = await _rows(
            db,
            f"SELECT * FROM task_assignments WHERE family_id = ? "
            f"AND task_id IN ({','.join('?' for _ in result_ids)})",
            (user["family_id"], *result_ids),
        )
    active = [row for row in rows + related if row["deleted_at"] is None]
    if not active:
        return CoachProposalUndoDecision(
            status="already_undone",
            message="This family action was already undone.",
            affected_ids=result_ids,
        )
    if any(_after(row["updated_at"], confirmed_at) for row in active):
        return CoachProposalUndoDecision(
            status="conflict",
            message="A family record changed after confirmation, so it was not removed.",
        )
    timestamp = now_iso()
    for row in related:
        if row["deleted_at"] is not None:
            continue
        await save_history(
            db,
            "task_assignments",
            row["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE task_assignments SET deleted_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (timestamp, timestamp, row["id"], user["family_id"]),
        )
    for row in rows:
        if row["deleted_at"] is not None:
            continue
        await save_history(
            db,
            table,
            row["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            f"UPDATE {table} SET deleted_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ? AND created_by = ? "
            "AND deleted_at IS NULL",
            (
                timestamp,
                timestamp,
                row["id"],
                user["family_id"],
                user["id"],
            ),
        )
    return CoachProposalUndoDecision(
        status="undone",
        message="The confirmed family action was removed.",
        affected_ids=result_ids,
    )


async def undo_proposal(db, *, user: dict, proposal_id: str) -> CoachProposalUndoDecision:
    await db.execute("BEGIN IMMEDIATE")
    row = await owned_row(db, table="health_coach_proposals", record_id=proposal_id, user=user)
    if row["status"] != "confirmed" or not row["confirmed_at"]:
        return CoachProposalUndoDecision(
            status="invalid", message="Only a confirmed proposal can be undone."
        )
    try:
        payload = json.loads(row["payload_json"])
        result_ids = json.loads(row["result_ids_json"] or "[]")
    except json.JSONDecodeError:
        return CoachProposalUndoDecision(
            status="invalid", message="The confirmed proposal audit is unreadable."
        )
    kind = row["proposal_kind"]
    if kind in {"family_calendar_event", "shopping_list", "family_task"}:
        if not result_ids:
            return CoachProposalUndoDecision(
                status="invalid",
                message="The confirmed family action audit is incomplete.",
            )
        return await _undo_family_created_records(
            db,
            user=user,
            kind=kind,
            result_ids=result_ids,
            confirmed_at=row["confirmed_at"],
        )
    if kind not in {"goal_adjustment", "calendar_change"}:
        return await _undo_created_records(
            db,
            user=user,
            kind=kind,
            payload=payload,
            result_ids=result_ids,
            confirmed_at=row["confirmed_at"],
        )
    if kind == "goal_adjustment":
        parsed = CoachGoalAdjustmentPayload.model_validate(payload)
        goal = await owned_row(db, table="health_goals", record_id=str(parsed.goal_id), user=user)
        original = (parsed.current_target_value, parsed.current_target_date)
        current = (
            goal["target_value"],
            date.fromisoformat(goal["target_date"]) if goal["target_date"] else None,
        )
        proposed = (
            parsed.proposed_target_value
            if parsed.proposed_target_value is not None
            else parsed.current_target_value,
            parsed.proposed_target_date
            if parsed.proposed_target_date is not None
            else parsed.current_target_date,
        )
        if current == original:
            return CoachProposalUndoDecision(
                status="already_undone",
                message="The goal already has its original target.",
                affected_ids=[str(parsed.goal_id)],
            )
        if current != proposed:
            return CoachProposalUndoDecision(
                status="conflict",
                message="The goal changed again after confirmation, so it was not reverted.",
            )
        values: dict[str, Any] = {}
        if parsed.proposed_target_value is not None:
            values["target_value"] = parsed.current_target_value
        if parsed.proposed_target_date is not None:
            values["target_date"] = parsed.current_target_date
        await planning.patch_goal(
            db,
            user=user,
            goal_id=str(parsed.goal_id),
            body=GoalPatch(**values),
        )
        return CoachProposalUndoDecision(
            status="undone",
            message="The goal target was restored.",
            affected_ids=[str(parsed.goal_id)],
        )
    parsed = CoachCalendarChangePayload.model_validate(payload)
    session = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=str(parsed.planned_session_id),
        user=user,
    )
    original = (
        parsed.current_start_utc,
        parsed.current_scheduled_date.isoformat() if parsed.current_scheduled_date else None,
        parsed.current_window_start_utc,
        parsed.current_window_end_utc,
    )
    current_matches_original = (
        _same_instant(session["scheduled_start_utc"], original[0])
        and session["scheduled_date"] == original[1]
        and _same_instant(session["time_window_start_utc"], original[2])
        and _same_instant(session["time_window_end_utc"], original[3])
    )
    if current_matches_original:
        return CoachProposalUndoDecision(
            status="already_undone",
            message="The planned session already has its original schedule.",
            affected_ids=[str(parsed.planned_session_id)],
        )
    proposed_matches = (
        _same_instant(session["scheduled_start_utc"], parsed.proposed_start_utc)
        and session["scheduled_date"] is None
        and session["time_window_start_utc"] is None
        and session["time_window_end_utc"] is None
    )
    if not proposed_matches:
        return CoachProposalUndoDecision(
            status="conflict",
            message="The planned session moved again after confirmation, so it was not reverted.",
        )
    await update_owned(
        db,
        table="health_planned_sessions",
        record_id=str(parsed.planned_session_id),
        values={
            "scheduled_start_utc": parsed.current_start_utc,
            "scheduled_date": parsed.current_scheduled_date,
            "time_window_start_utc": parsed.current_window_start_utc,
            "time_window_end_utc": parsed.current_window_end_utc,
        },
        user=user,
    )
    return CoachProposalUndoDecision(
        status="undone",
        message="The planned session schedule was restored.",
        affected_ids=[str(parsed.planned_session_id)],
    )


async def decline_proposal(db, *, user: dict, proposal_id: str) -> CoachProposalDecision:
    await db.execute("BEGIN IMMEDIATE")
    row = await owned_row(db, table="health_coach_proposals", record_id=proposal_id, user=user)
    expires = datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
    if expires <= datetime.now(timezone.utc):
        if row["status"] != "confirmed":
            await update_owned(
                db,
                table="health_coach_proposals",
                record_id=proposal_id,
                values={"status": "expired"},
                user=user,
                record_sync_change=False,
            )
        return CoachProposalDecision(status="expired", message="This draft has expired.")
    if row["status"] == "confirmed":
        return CoachProposalDecision(
            status="invalid", message="A confirmed proposal cannot be declined."
        )
    if row["status"] != "declined":
        await update_owned(
            db,
            table="health_coach_proposals",
            record_id=proposal_id,
            values={"status": "declined", "declined_at": now_iso()},
            user=user,
            record_sync_change=False,
        )
    return CoachProposalDecision(status="declined", message="Draft declined. No plan was created.")
