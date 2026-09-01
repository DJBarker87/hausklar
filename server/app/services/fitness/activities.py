"""Private activity history, streams, gear, matching and deterministic analysis APIs."""

from __future__ import annotations

import asyncio
import json
import math
import statistics
from datetime import date, datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import pyarrow.parquet as pq

from app.fitness_registry import SPORTS
from app.models.fitness_activity import (
    ActivityContextPatch,
    ActivityGoalLinksReplacePayload,
    GearPatch,
    GearPayload,
    ManualActivityPayload,
)
from app.services.fitness.activity_import import asset_path
from app.services.fitness.common import (
    FitnessConflictError,
    append_change,
    decoded_row,
    insert_owned,
    new_id,
    now_iso,
    owned_row,
    save_owned_rows_history,
    soft_delete_owned,
    update_owned,
    validate_owned_reference,
)


RUN_CLASSIFICATIONS = {
    "recovery",
    "easy",
    "steady",
    "long",
    "tempo",
    "threshold",
    "interval",
    "hill",
    "race",
    "time_trial",
    "progression",
    "mixed",
    "unclassified",
}

RUN_SPORT_KEYS = {"running", "trail_running", "treadmill_running"}

MANUAL_ACTIVITY_PARSER_VERSION = "manual-activity-v1"
MANUAL_ENERGY_METHOD = "adult_compendium_2024_met"
SPORTS_BY_KEY = {sport["key"]: sport for sport in SPORTS}

STREAM_UNITS = {
    "distance_m": "m",
    "speed_mps": "m/s",
    "pace_s_per_km": "s/km",
    "heart_rate_bpm": "bpm",
    "altitude_m": "m",
    "latitude_deg": "deg",
    "longitude_deg": "deg",
    "cadence_spm": "spm",
    "power_w": "W",
    "temperature_c": "degC",
}

# Parquet decoding and the associated Python scans are CPU/filesystem work. Keep
# them away from the single Uvicorn event loop and bound concurrency so a burst
# of route-detail requests cannot swamp the NUC's disk or worker threads.
_PARQUET_READ_LIMIT = asyncio.Semaphore(2)


def _json(raw: Any, default: Any) -> Any:
    if isinstance(raw, (dict, list)):
        return raw
    if not isinstance(raw, str):
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return default


async def _summary_metrics(db, *, user: dict, activity_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT metric_key, value_number, value_text, value_bool, unit_key, origin, "
            "quality, calculation_version FROM health_activity_summary_metrics "
            "WHERE family_id = ? AND owner_user_id = ? AND activity_id = ? "
            "AND deleted_at IS NULL ORDER BY metric_key",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    return [dict(row) for row in rows]


async def _summary_metrics_for_activities(
    db, *, user: dict, activity_ids: list[str]
) -> dict[str, list[dict]]:
    """Load summary metrics for a page of activities in one query."""
    result = {activity_id: [] for activity_id in activity_ids}
    if not activity_ids:
        return result
    placeholders = ",".join("?" for _ in activity_ids)
    rows = await (
        await db.execute(
            "SELECT activity_id, metric_key, value_number, value_text, value_bool, "
            "unit_key, origin, quality, calculation_version "
            "FROM health_activity_summary_metrics WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id IN ("
            f"{placeholders}) AND deleted_at IS NULL "
            "ORDER BY activity_id, metric_key",
            (user["family_id"], user["id"], *activity_ids),
        )
    ).fetchall()
    for row in rows:
        item = dict(row)
        activity_id = str(item.pop("activity_id"))
        result.setdefault(activity_id, []).append(item)
    return result


async def _activity_gear(db, *, user: dict, activity_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT g.*, l.role, l.start_offset_ms, l.end_offset_ms "
            "FROM health_activity_gear_links l JOIN health_gear_items g ON g.id = l.gear_id "
            "WHERE l.family_id = ? AND l.owner_user_id = ? AND l.activity_id = ? "
            "AND l.deleted_at IS NULL AND g.family_id = ? AND g.owner_user_id = ? "
            "AND g.deleted_at IS NULL ORDER BY CASE l.role WHEN 'primary' THEN 0 "
            "WHEN 'sensor' THEN 1 ELSE 2 END, g.name",
            (user["family_id"], user["id"], activity_id, user["family_id"], user["id"]),
        )
    ).fetchall()
    return [decoded_row(row) for row in rows]


async def _gear_for_activities(
    db, *, user: dict, activity_ids: list[str]
) -> dict[str, list[dict]]:
    """Load linked gear for a page of activities in one query."""
    result = {activity_id: [] for activity_id in activity_ids}
    if not activity_ids:
        return result
    placeholders = ",".join("?" for _ in activity_ids)
    rows = await (
        await db.execute(
            "SELECT l.activity_id AS linked_activity_id, g.*, l.role, "
            "l.start_offset_ms, l.end_offset_ms FROM health_activity_gear_links l "
            "JOIN health_gear_items g ON g.id = l.gear_id "
            "WHERE l.family_id = ? AND l.owner_user_id = ? "
            f"AND l.activity_id IN ({placeholders}) "
            "AND l.deleted_at IS NULL AND g.family_id = ? "
            "AND g.owner_user_id = ? AND g.deleted_at IS NULL "
            "ORDER BY l.activity_id, CASE l.role WHEN 'primary' THEN 0 "
            "WHEN 'sensor' THEN 1 ELSE 2 END, g.name",
            (
                user["family_id"],
                user["id"],
                *activity_ids,
                user["family_id"],
                user["id"],
            ),
        )
    ).fetchall()
    for row in rows:
        item = decoded_row(row)
        activity_id = str(item.pop("linked_activity_id"))
        result.setdefault(activity_id, []).append(item)
    return result


async def _strength_summaries_for_activities(
    db, *, user: dict, activity_ids: list[str]
) -> dict[str, dict]:
    """Return compact strength totals for mixed activity-history pages."""
    if not activity_ids:
        return {}
    placeholders = ",".join("?" for _ in activity_ids)
    rows = await (
        await db.execute(
            "SELECT a.id AS activity_id, "
            "COUNT(DISTINCT se.id) AS exercise_count, "
            "COUNT(DISTINCT CASE WHEN g.status IN ('completed','partial') THEN g.id END) AS set_count, "
            "COUNT(DISTINCT CASE WHEN g.status IN ('completed','partial') "
            "AND g.training_role IN ('working','backoff','test') THEN g.id END) AS working_set_count, "
            "COUNT(DISTINCT CASE WHEN g.failure_state NOT IN ('none','stopped_for_body_issue') "
            "THEN g.id END) AS failure_set_count, "
            "COALESCE(SUM(CASE WHEN g.status IN ('completed','partial') "
            "AND g.training_role IN ('working','backoff','test') "
            "AND c.component_status IN ('completed','partial') "
            "THEN COALESCE(c.normalized_external_load_kg, 0) * "
            "COALESCE(c.reps, COALESCE(c.reps_left, 0) + COALESCE(c.reps_right, 0), 0) "
            "ELSE 0 END), 0) AS volume_kg "
            "FROM health_activities a "
            "LEFT JOIN health_strength_session_exercises se ON se.activity_id = a.id "
            "AND se.family_id = a.family_id AND se.owner_user_id = a.owner_user_id "
            "AND se.deleted_at IS NULL "
            "LEFT JOIN health_strength_set_groups g ON g.session_exercise_id = se.id "
            "AND g.family_id = a.family_id AND g.owner_user_id = a.owner_user_id "
            "AND g.deleted_at IS NULL "
            "LEFT JOIN health_strength_sets c ON c.set_group_id = g.id "
            "AND c.family_id = a.family_id AND c.owner_user_id = a.owner_user_id "
            "AND c.deleted_at IS NULL "
            "WHERE a.family_id = ? AND a.owner_user_id = ? AND a.sport_key = 'strength' "
            f"AND a.id IN ({placeholders}) GROUP BY a.id",
            (user["family_id"], user["id"], *activity_ids),
        )
    ).fetchall()
    return {
        str(row["activity_id"]): {
            "exercise_count": int(row["exercise_count"] or 0),
            "set_count": int(row["set_count"] or 0),
            "working_set_count": int(row["working_set_count"] or 0),
            "failure_set_count": int(row["failure_set_count"] or 0),
            "volume_kg": round(float(row["volume_kg"] or 0), 2),
        }
        for row in rows
    }


def _recorded_duration_seconds(raw: dict) -> float | None:
    stored = raw.get("timer_duration_s")
    if stored is not None:
        return float(stored)
    if raw.get("sport_key") != "strength" or not raw.get("ended_at_utc"):
        return None
    try:
        started = datetime.fromisoformat(str(raw["started_at_utc"]).replace("Z", "+00:00"))
        ended = datetime.fromisoformat(str(raw["ended_at_utc"]).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return max(0.0, (ended - started).total_seconds())


async def list_activity_goal_links(
    db, *, user: dict, activity_id: str
) -> list[dict]:
    await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    rows = await (
        await db.execute(
            "SELECT * FROM health_activity_goal_links WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL "
            "ORDER BY CASE role WHEN 'planned' THEN 0 WHEN 'user_assigned' THEN 1 ELSE 2 END, "
            "created_at, id",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    return [decoded_row(row) for row in rows]


async def replace_activity_goal_links(
    db,
    *,
    user: dict,
    activity_id: str,
    body: ActivityGoalLinksReplacePayload,
) -> list[dict]:
    await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    requested = {(str(item.goal_id), item.role) for item in body.links}
    for goal_id, _ in requested:
        await validate_owned_reference(
            db, table="health_goals", record_id=goal_id, user=user
        )
    existing = await (
        await db.execute(
            "SELECT * FROM health_activity_goal_links WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    editable = {
        (row["goal_id"], row["role"]): row
        for row in existing
        if row["role"] in {"user_assigned", "inferred_reviewed"}
    }
    for key, row in editable.items():
        if key not in requested:
            await soft_delete_owned(
                db,
                table="health_activity_goal_links",
                record_id=row["id"],
                user=user,
            )
    for goal_id, role in requested - set(editable):
        await insert_owned(
            db,
            table="health_activity_goal_links",
            record_id=new_id(),
            values={
                "activity_id": activity_id,
                "goal_id": goal_id,
                "role": role,
                "revision": 1,
            },
            user=user,
        )
    return await list_activity_goal_links(db, user=user, activity_id=activity_id)


async def activity_summary(
    db,
    *,
    user: dict,
    row: Any,
    primary_metrics: list[dict] | None = None,
    gear: list[dict] | None = None,
    strength_summary: dict | None = None,
) -> dict:
    raw = dict(row)
    if primary_metrics is None:
        primary_metrics = await _summary_metrics(
            db, user=user, activity_id=raw["id"]
        )
    if gear is None:
        gear = await _activity_gear(db, user=user, activity_id=raw["id"])
    if strength_summary is None and raw.get("sport_key") == "strength":
        strength_summary = (
            await _strength_summaries_for_activities(
                db, user=user, activity_ids=[str(raw["id"])]
            )
        ).get(str(raw["id"]))
    recorded_duration = _recorded_duration_seconds(raw)
    return {
        "id": raw["id"],
        "revision": raw["revision"],
        "created_at": raw["created_at"],
        "updated_at": raw["updated_at"],
        "deleted_at": raw["deleted_at"],
        "title": raw["title"],
        "sport_key": raw["sport_key"],
        "sub_sport_key": raw.get("sub_sport_key"),
        "started_at_utc": raw["started_at_utc"],
        "ended_at_utc": raw.get("ended_at_utc"),
        "local_timezone": raw.get("local_timezone"),
        "local_calendar_date": raw.get("local_calendar_date"),
        "status": raw["status"],
        "planned_session_id": raw.get("planned_session_id"),
        "planned_session_title": raw.get("planned_session_title"),
        "workout_classification": raw.get("workout_classification"),
        "phase_id": raw.get("phase_id"),
        "distance_m": raw.get("distance_m"),
        "duration_s": recorded_duration,
        "elapsed_duration_s": raw.get("elapsed_duration_s") or recorded_duration,
        "timer_duration_s": recorded_duration,
        "moving_duration_s": raw.get("moving_duration_s"),
        "energy_kcal": raw.get("energy_kcal"),
        "energy_estimation_method": raw.get("energy_estimation_method"),
        "energy_estimation_weight_kg": raw.get("energy_estimation_weight_kg"),
        "energy_estimation_weight_measured_at_utc": raw.get(
            "energy_estimation_weight_measured_at_utc"
        ),
        "energy_estimation_met": raw.get("energy_estimation_met"),
        "notes": raw.get("notes"),
        "route_preview": _json(raw.get("route_preview_json"), []),
        "primary_metrics": primary_metrics,
        "gear": gear,
        "strength_summary": strength_summary,
        "import_error": None if raw.get("import_state") != "failed" else "Import failed",
    }


async def manual_activity_defaults(db, *, user: dict) -> dict:
    """Return the canonical weight that a new manual estimate would use."""
    row = await (
        await db.execute(
            "SELECT value, unit_key, measured_at_utc FROM health_body_measurements "
            "WHERE family_id = ? AND owner_user_id = ? "
            "AND metric_key = 'body.weight_kg' AND canonical_state = 'canonical' "
            "AND deleted_at IS NULL ORDER BY measured_at_utc DESC, created_at DESC LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    weight_kg = None
    if row is not None:
        value = float(row["value"])
        unit = str(row["unit_key"] or "kg").lower()
        if unit == "kg":
            weight_kg = value
        elif unit in {"lb", "lbs"}:
            weight_kg = value * 0.45359237
    return {
        "latest_weight_kg": round(weight_kg, 2) if weight_kg and weight_kg > 0 else None,
        "latest_weight_measured_at_utc": row["measured_at_utc"] if row else None,
        "energy_estimation_method": MANUAL_ENERGY_METHOD,
    }


def _manual_activity_met(
    *, sport_key: str, duration_s: float, distance_m: float | None
) -> float:
    """Choose a transparent, speed-aware MET value for a rough energy estimate."""
    hours = duration_s / 3_600
    speed_kmh = distance_m / 1_000 / hours if distance_m and hours > 0 else None
    if sport_key == "running":
        if speed_kmh is None:
            return 8.0
        for ceiling, met in (
            (6.4, 6.0),
            (8.0, 8.0),
            (9.7, 9.8),
            (11.3, 11.0),
            (12.9, 11.8),
            (14.5, 12.8),
        ):
            if speed_kmh < ceiling:
                return met
        return 14.5
    if sport_key == "walking":
        if speed_kmh is None:
            return 3.5
        for ceiling, met in ((3.2, 2.8), (4.8, 3.5), (5.6, 4.0), (6.4, 4.8)):
            if speed_kmh < ceiling:
                return met
        return 6.0
    if sport_key == "cycling":
        if speed_kmh is None:
            return 6.8
        for ceiling, met in ((16.0, 4.0), (19.0, 6.8), (22.0, 8.0), (26.0, 10.0)):
            if speed_kmh < ceiling:
                return met
        return 12.0
    return {
        "hiking": 6.0,
        "rowing_indoor": 7.0,
        "rowing_water": 7.0,
        "swimming_pool": 6.0,
        "swimming_open_water": 6.0,
        "other": 5.0,
    }.get(sport_key, 5.0)


async def upsert_manual_activity(
    db,
    *,
    user: dict,
    body: ManualActivityPayload,
    record_id: str | None = None,
) -> dict:
    activity_id = record_id or new_id(body.id)
    sport = SPORTS_BY_KEY.get(body.sport_key)
    if sport is None:
        raise FitnessConflictError("Choose a supported activity type")
    if body.sport_key == "strength":
        raise FitnessConflictError("Use the strength workout logger for strength sessions")
    try:
        zone = ZoneInfo(body.local_timezone)
    except ZoneInfoNotFoundError as exc:
        raise FitnessConflictError("Choose a valid activity timezone") from exc

    started = body.started_at_utc.astimezone(timezone.utc)
    ended = started + timedelta(seconds=body.duration_s)
    defaults = await manual_activity_defaults(db, user=user)
    weight_kg = defaults["latest_weight_kg"] if body.estimate_energy else None
    met = (
        _manual_activity_met(
            sport_key=body.sport_key,
            duration_s=body.duration_s,
            distance_m=body.distance_m,
        )
        if weight_kg is not None
        else None
    )
    energy_kcal = (
        round(float(met) * float(weight_kg) * body.duration_s / 3_600, 1)
        if met is not None and weight_kg is not None
        else None
    )
    values = {
        "sport_key": body.sport_key,
        "title": body.title or sport["display_name"],
        "status": "completed",
        "planned_session_id": None,
        "started_at_utc": started,
        "ended_at_utc": ended,
        "local_timezone": body.local_timezone,
        "local_calendar_date": started.astimezone(zone).date(),
        "elapsed_duration_s": body.duration_s,
        "timer_duration_s": body.duration_s,
        "moving_duration_s": body.duration_s,
        "distance_m": body.distance_m,
        "energy_kcal": energy_kcal,
        "energy_estimation_method": MANUAL_ENERGY_METHOD if energy_kcal is not None else None,
        "energy_estimation_weight_kg": weight_kg,
        "energy_estimation_weight_measured_at_utc": (
            defaults["latest_weight_measured_at_utc"] if energy_kcal is not None else None
        ),
        "energy_estimation_met": met,
        "measurement_quality": "user_entered",
        "import_state": "not_imported",
        "parser_version": MANUAL_ACTIVITY_PARSER_VERSION,
        "workout_classification": body.workout_classification,
        "classification_source": "user" if body.workout_classification else None,
        "session_rpe": body.session_rpe,
        "notes": body.notes,
    }
    existing = await (
        await db.execute(
            "SELECT * FROM health_activities WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (activity_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None and existing["parser_version"] != MANUAL_ACTIVITY_PARSER_VERSION:
        raise FitnessConflictError("This activity was created by another data source")
    if existing is None:
        await insert_owned(
            db,
            table="health_activities",
            record_id=activity_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            record_sync_change=False,
        )
    else:
        await update_owned(
            db,
            table="health_activities",
            record_id=activity_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
            record_sync_change=False,
        )
    row = await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    await append_change(
        db,
        entity_type="manual_activity",
        entity_id=activity_id,
        revision=int(row["revision"]),
        operation="upsert",
        user=user,
    )
    return await activity_summary(db, user=user, row=row)


async def delete_manual_activity(db, *, user: dict, activity_id: str) -> int:
    row = await owned_row(
        db,
        table="health_activities",
        record_id=activity_id,
        user=user,
        include_deleted=True,
    )
    if row["parser_version"] != MANUAL_ACTIVITY_PARSER_VERSION:
        raise FitnessConflictError("Only manually logged activities can be deleted here")
    revision = await soft_delete_owned(
        db,
        table="health_activities",
        record_id=activity_id,
        user=user,
        record_sync_change=False,
    )
    await append_change(
        db,
        entity_type="manual_activity",
        entity_id=activity_id,
        revision=revision,
        operation="delete",
        user=user,
    )
    return revision


async def list_activities(
    db,
    *,
    user: dict,
    sport_key: str | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    phase_id: str | None = None,
    workout_classification: str | None = None,
    gear_id: str | None = None,
    status: str | None = None,
    offset: int = 0,
    limit: int = 50,
) -> list[dict]:
    clauses = ["a.family_id = ?", "a.owner_user_id = ?", "a.deleted_at IS NULL"]
    params: list[Any] = [user["family_id"], user["id"]]
    if sport_key:
        clauses.append("a.sport_key = ?")
        params.append(sport_key)
    if date_from:
        clauses.append("COALESCE(a.local_calendar_date, substr(a.started_at_utc, 1, 10)) >= ?")
        params.append(date_from.isoformat())
    if date_to:
        clauses.append("COALESCE(a.local_calendar_date, substr(a.started_at_utc, 1, 10)) <= ?")
        params.append(date_to.isoformat())
    if phase_id:
        clauses.append("a.phase_id = ?")
        params.append(phase_id)
    if workout_classification:
        clauses.append("a.workout_classification = ?")
        params.append(workout_classification)
    if status:
        clauses.append("a.status = ?")
        params.append(status)
    if gear_id:
        clauses.append(
            "EXISTS (SELECT 1 FROM health_activity_gear_links gl WHERE gl.activity_id = a.id "
            "AND gl.family_id = a.family_id AND gl.owner_user_id = a.owner_user_id "
            "AND gl.gear_id = ? AND gl.deleted_at IS NULL)"
        )
        params.append(gear_id)
    rows = await (
        await db.execute(
            f"WITH activity_page AS ("
            "SELECT a.*, p.title AS planned_session_title FROM health_activities a "
            "LEFT JOIN health_planned_sessions p ON p.id = a.planned_session_id "
            "AND p.family_id = a.family_id AND p.owner_user_id = a.owner_user_id "
            "AND p.deleted_at IS NULL "
            f"WHERE {' AND '.join(clauses)} "
            "ORDER BY a.started_at_utc DESC, a.id LIMIT ? OFFSET ?"
            "), strength_totals AS ("
            "SELECT se.activity_id, COUNT(DISTINCT se.id) AS exercise_count, "
            "COUNT(DISTINCT CASE WHEN g.status IN ('completed','partial') THEN g.id END) AS set_count, "
            "COUNT(DISTINCT CASE WHEN g.status IN ('completed','partial') "
            "AND g.training_role IN ('working','backoff','test') THEN g.id END) AS working_set_count, "
            "COUNT(DISTINCT CASE WHEN g.failure_state NOT IN ('none','stopped_for_body_issue') "
            "THEN g.id END) AS failure_set_count, "
            "COALESCE(SUM(CASE WHEN g.status IN ('completed','partial') "
            "AND g.training_role IN ('working','backoff','test') "
            "AND c.component_status IN ('completed','partial') "
            "THEN COALESCE(c.normalized_external_load_kg, 0) * "
            "COALESCE(c.reps, COALESCE(c.reps_left, 0) + COALESCE(c.reps_right, 0), 0) "
            "ELSE 0 END), 0) AS volume_kg "
            "FROM health_strength_session_exercises se "
            "JOIN activity_page page ON page.id = se.activity_id "
            "AND page.sport_key = 'strength' "
            "LEFT JOIN health_strength_set_groups g ON g.session_exercise_id = se.id "
            "AND g.family_id = se.family_id AND g.owner_user_id = se.owner_user_id "
            "AND g.deleted_at IS NULL "
            "LEFT JOIN health_strength_sets c ON c.set_group_id = g.id "
            "AND c.family_id = se.family_id AND c.owner_user_id = se.owner_user_id "
            "AND c.deleted_at IS NULL "
            "WHERE se.family_id = ? AND se.owner_user_id = ? AND se.deleted_at IS NULL "
            "GROUP BY se.activity_id"
            ") SELECT page.*, totals.exercise_count AS strength_exercise_count, "
            "totals.set_count AS strength_set_count, "
            "totals.working_set_count AS strength_working_set_count, "
            "totals.failure_set_count AS strength_failure_set_count, "
            "totals.volume_kg AS strength_volume_kg FROM activity_page page "
            "LEFT JOIN strength_totals totals ON totals.activity_id = page.id "
            "ORDER BY page.started_at_utc DESC, page.id",
            (*params, limit, offset, user["family_id"], user["id"]),
        )
    ).fetchall()
    activity_ids = [str(row["id"]) for row in rows]
    metrics_by_activity, gear_by_activity = await asyncio.gather(
        _summary_metrics_for_activities(
            db, user=user, activity_ids=activity_ids
        ),
        _gear_for_activities(db, user=user, activity_ids=activity_ids),
    )
    strength_by_activity = {
        str(row["id"]): {
            "exercise_count": int(row["strength_exercise_count"] or 0),
            "set_count": int(row["strength_set_count"] or 0),
            "working_set_count": int(row["strength_working_set_count"] or 0),
            "failure_set_count": int(row["strength_failure_set_count"] or 0),
            "volume_kg": round(float(row["strength_volume_kg"] or 0), 2),
        }
        for row in rows
        if row["sport_key"] == "strength"
    }
    return [
        await activity_summary(
            db,
            user=user,
            row=row,
            primary_metrics=metrics_by_activity.get(str(row["id"]), []),
            gear=gear_by_activity.get(str(row["id"]), []),
            strength_summary=strength_by_activity.get(str(row["id"])),
        )
        for row in rows
    ]


async def _quality_findings(db, *, user: dict, activity_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT id, finding_key AS key, severity, message, start_offset_ms, end_offset_ms, "
            "limits_analysis_keys_json FROM health_activity_quality_findings "
            "WHERE family_id = ? AND owner_user_id = ? AND activity_id = ? "
            "AND deleted_at IS NULL ORDER BY CASE severity WHEN 'error' THEN 0 "
            "WHEN 'warning' THEN 1 ELSE 2 END, created_at",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    findings = []
    for row in rows:
        data = dict(row)
        data["limits_analysis_keys"] = _json(data.pop("limits_analysis_keys_json"), [])
        findings.append(data)
    return findings


async def activity_analysis(db, *, user: dict, activity_id: str) -> dict:
    activity = await owned_row(db, table="health_activities", record_id=activity_id, user=user)
    rows = await (
        await db.execute(
            "SELECT result_json FROM health_activity_analysis_results "
            "WHERE family_id = ? AND owner_user_id = ? AND activity_id = ? "
            "AND deleted_at IS NULL ORDER BY analysis_key",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    findings = [_json(row["result_json"], {}) for row in rows]
    records = await _records(db, user=user, activity_id=activity_id)
    return {
        "findings": findings,
        "records": records,
        "achievements": [record for record in records if record.get("is_personal_best")],
        "data_quality": await _quality_findings(
            db, user=user, activity_id=activity_id
        ),
        "training_load": (
            await running_training_load(
                db,
                user=user,
                as_of=date.fromisoformat(
                    activity["local_calendar_date"] or activity["started_at_utc"][:10]
                ),
            )
            if activity["sport_key"] == "running"
            else None
        ),
    }


async def running_training_load(
    db,
    *,
    user: dict,
    as_of: date | None = None,
) -> dict:
    """Return transparent running volume/load components, never a single score."""
    end = as_of or datetime.now(timezone.utc).date()
    start = end - timedelta(days=41)
    rows = await (
        await db.execute(
            "SELECT id, started_at_utc, local_calendar_date, distance_m, "
            "timer_duration_s, session_rpe, workout_classification "
            "FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
            "AND sport_key = 'running' AND status = 'completed' "
            "AND COALESCE(local_calendar_date, substr(started_at_utc,1,10)) BETWEEN ? AND ? "
            "AND deleted_at IS NULL ORDER BY started_at_utc",
            (user["family_id"], user["id"], start.isoformat(), end.isoformat()),
        )
    ).fetchall()
    hard_classes = {"tempo", "threshold", "interval", "hill", "race", "time_trial"}
    daily: dict[date, dict[str, float | int]] = {}
    sessions = []
    for row in rows:
        day = date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10])
        duration_s = float(row["timer_duration_s"] or 0)
        distance_m = float(row["distance_m"] or 0)
        rpe = float(row["session_rpe"]) if row["session_rpe"] is not None else None
        rpe_load = duration_s / 60 * rpe if rpe is not None else None
        hard = row["workout_classification"] in hard_classes
        bucket = daily.setdefault(
            day,
            {"distance_m": 0.0, "duration_s": 0.0, "rpe_load": 0.0, "hard_sessions": 0},
        )
        bucket["distance_m"] = float(bucket["distance_m"]) + distance_m
        bucket["duration_s"] = float(bucket["duration_s"]) + duration_s
        if rpe_load is not None:
            bucket["rpe_load"] = float(bucket["rpe_load"]) + rpe_load
        if hard:
            bucket["hard_sessions"] = int(bucket["hard_sessions"]) + 1
        sessions.append(
            {
                "id": row["id"],
                "day": day,
                "distance_m": distance_m,
                "duration_s": duration_s,
                "rpe_load": rpe_load,
                "classification": row["workout_classification"] or "unclassified",
                "hard": hard,
            }
        )

    def window(days: int, *, end_day: date = end) -> dict[str, float | int | None]:
        first = end_day - timedelta(days=days - 1)
        selected = [item for item in sessions if first <= item["day"] <= end_day]
        distances = [float(item["distance_m"]) for item in selected]
        loads = [float(item["rpe_load"]) for item in selected if item["rpe_load"] is not None]
        return {
            "days": days,
            "distance_m": round(sum(distances), 1),
            "duration_s": round(sum(float(item["duration_s"]) for item in selected), 1),
            "session_count": len(selected),
            "hard_session_count": sum(bool(item["hard"]) for item in selected),
            "session_rpe_load": round(sum(loads), 1) if loads else None,
            "long_run_share": (
                round(max(distances) / sum(distances), 4) if distances and sum(distances) else None
            ),
        }

    current_week = window(7)
    previous_week = window(7, end_day=end - timedelta(days=7))
    previous_distance = float(previous_week["distance_m"] or 0)
    volume_change_pct = (
        (float(current_week["distance_m"] or 0) - previous_distance)
        / previous_distance
        * 100
        if previous_distance > 0
        else None
    )
    hard_days = sorted({item["day"] for item in sessions if item["hard"]})
    consecutive_hard_days = [
        (left.isoformat(), right.isoformat())
        for left, right in zip(hard_days, hard_days[1:])
        if right - left == timedelta(days=1)
    ]
    seven_daily_loads = [
        float(daily.get(end - timedelta(days=offset), {}).get("rpe_load", 0))
        for offset in range(7)
    ]
    mean_load = statistics.fmean(seven_daily_loads) if seven_daily_loads else 0
    deviation = statistics.pstdev(seven_daily_loads) if len(seven_daily_loads) > 1 else 0
    distribution: dict[str, int] = {}
    for item in sessions:
        if item["day"] >= end - timedelta(days=6):
            key = str(item["classification"])
            distribution[key] = distribution.get(key, 0) + 1
    return {
        "as_of": end.isoformat(),
        "algorithm_version": "running-load-v1",
        "windows": {"7d": current_week, "28d": window(28), "42d": window(42)},
        "previous_7d": previous_week,
        "volume_change_pct": round(volume_change_pct, 1) if volume_change_pct is not None else None,
        "sudden_volume_change": volume_change_pct is not None and abs(volume_change_pct) >= 25,
        "consecutive_hard_days": consecutive_hard_days,
        "intensity_distribution_7d": distribution,
        "training_monotony_7d": round(mean_load / deviation, 2) if deviation > 0 else None,
        "missing_rpe_sessions": sum(item["rpe_load"] is None for item in sessions if item["day"] >= end - timedelta(days=41)),
        "sample_size": len(sessions),
        "explanation": "Distance, duration, hard days and session-RPE load are kept separate; missing RPE is not inferred.",
    }


async def _activity_intervals(db, *, user: dict, activity_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_activity_intervals WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL "
            "ORDER BY sequence, start_offset_ms",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    result = []
    for row in rows:
        data = decoded_row(row, json_fields={"metrics_json"})
        data["metrics_json"] = data["metrics"]
        result.append(data)
    return result


async def _records(db, *, user: dict, activity_id: str) -> list[dict]:
    row = await (
        await db.execute(
            "SELECT value_json FROM health_activity_features WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND feature_key = 'running.records' "
            "AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchone()
    records = _json(row["value_json"], []) if row else []
    if not records:
        return []
    previous_rows = await (
        await db.execute(
            "SELECT value_json FROM health_activity_features WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id <> ? "
            "AND feature_key = 'running.records' AND deleted_at IS NULL",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    previous_best: dict[str, float] = {}
    for previous_row in previous_rows:
        for previous in _json(previous_row["value_json"], []):
            key = previous.get("record_key")
            value = previous.get("value_s")
            if key and value is not None:
                previous_best[key] = min(previous_best.get(key, math.inf), float(value))
    for record in records:
        key = record.get("record_key")
        value = record.get("value_s")
        record["id"] = record.get("id") or f"{activity_id}:{key}"
        record["is_personal_best"] = bool(
            key
            and value is not None
            and float(value) <= previous_best.get(key, math.inf)
        )
    return records


async def _checkins(db, *, user: dict, activity_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_session_checkins WHERE family_id = ? AND owner_user_id = ? "
            "AND activity_id = ? AND deleted_at IS NULL ORDER BY captured_at_utc",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    return [decoded_row(row) for row in rows]


async def _body_issues(db, *, user: dict, activity_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_body_issue_observations WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL "
            "ORDER BY observed_at_utc",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    return [decoded_row(row) for row in rows]


async def activity_detail(db, *, user: dict, activity_id: str) -> dict:
    row = await owned_row(db, table="health_activities", record_id=activity_id, user=user)
    source_rows = await (
        await db.execute(
            "SELECT s.id, s.transport_key AS source_type, s.origin_provider_key AS provider, "
            "s.source_device_identifier AS device_name, s.state AS status, l.created_at AS attached_at, "
            "CASE WHEN l.role = 'primary' THEN 1 ELSE 0 END AS is_primary, "
            "json_extract(s.raw_metadata_json, '$.data_quality') AS data_quality "
            "FROM health_activity_source_records l JOIN health_source_records s "
            "ON s.id = l.source_record_id WHERE l.family_id = ? AND l.owner_user_id = ? "
            "AND l.activity_id = ? AND l.deleted_at IS NULL AND s.deleted_at IS NULL "
            "ORDER BY is_primary DESC, attached_at",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    metrics = await _summary_metrics(db, user=user, activity_id=activity_id)
    gear = await _activity_gear(db, user=user, activity_id=activity_id)
    metric_rows = await (
        await db.execute(
            "SELECT metric_key FROM health_activity_metric_index WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL ORDER BY metric_key",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchall()
    available = [metric["metric_key"] for metric in metric_rows]
    panels = []
    for panel, keys in (
        ("route", {"latitude_deg", "longitude_deg"}),
        ("pace", {"pace_s_per_km", "speed_mps"}),
        ("heart_rate", {"heart_rate_bpm"}),
        ("elevation", {"altitude_m"}),
        ("cadence", {"cadence_spm"}),
        ("power", {"power_w"}),
    ):
        if keys.intersection(available):
            panels.append(panel)
    planned = None
    if row["planned_session_id"]:
        from app.services.fitness.planning import _planned_session_response

        plan_row = await owned_row(
            db,
            table="health_planned_sessions",
            record_id=row["planned_session_id"],
            user=user,
        )
        planned = await _planned_session_response(db, user=user, row=plan_row)
    records = await _records(db, user=user, activity_id=activity_id)
    return {
        "activity": await activity_summary(
            db, user=user, row=row, primary_metrics=metrics, gear=gear
        ),
        "sources": [decoded_row(source) for source in source_rows],
        "summary_metrics": metrics,
        "available_stream_metrics": available,
        "recommended_panels": panels,
        "intervals": await _activity_intervals(db, user=user, activity_id=activity_id),
        "records": records,
        "achievements": [record for record in records if record.get("is_personal_best")],
        "notes": row["notes"],
        "session_rpe": row["session_rpe"],
        "planned_session": planned,
        "checkins": await _checkins(db, user=user, activity_id=activity_id),
        "body_issues": await _body_issues(db, user=user, activity_id=activity_id),
        "gear": gear,
        "goal_links": await list_activity_goal_links(
            db, user=user, activity_id=activity_id
        ),
        "data_quality": await _quality_findings(db, user=user, activity_id=activity_id),
        "adherence": await activity_adherence(db, user=user, activity_id=activity_id),
    }


def _downsample_indices(offsets: list[int], series: dict[str, list], maximum: int) -> list[int]:
    count = len(offsets)
    if count <= maximum:
        return list(range(count))
    mandatory = {0, count - 1}
    for values in series.values():
        present = [(index, value) for index, value in enumerate(values) if value is not None]
        if present:
            mandatory.add(min(present, key=lambda pair: pair[1])[0])
            mandatory.add(max(present, key=lambda pair: pair[1])[0])
    latitudes = series.get("latitude_deg")
    longitudes = series.get("longitude_deg")
    if latitudes is not None and longitudes is not None and maximum > 4:
        # Retain the strongest bends as well as temporal/extrema samples. This
        # keeps a bounded route recognisable without a separate geometry store.
        turns: list[tuple[float, int]] = []
        for index in range(1, count - 1):
            if any(
                value is None
                for value in (
                    latitudes[index - 1],
                    longitudes[index - 1],
                    latitudes[index],
                    longitudes[index],
                    latitudes[index + 1],
                    longitudes[index + 1],
                )
            ):
                continue
            latitude = float(latitudes[index])
            scale = max(0.01, math.cos(math.radians(latitude)))
            first = (
                (float(longitudes[index]) - float(longitudes[index - 1])) * scale,
                float(latitudes[index]) - float(latitudes[index - 1]),
            )
            second = (
                (float(longitudes[index + 1]) - float(longitudes[index])) * scale,
                float(latitudes[index + 1]) - float(latitudes[index]),
            )
            first_length = math.hypot(*first)
            second_length = math.hypot(*second)
            if first_length and second_length:
                cosine = max(
                    -1.0,
                    min(
                        1.0,
                        (first[0] * second[0] + first[1] * second[1])
                        / (first_length * second_length),
                    ),
                )
                turns.append((math.acos(cosine), index))
        route_budget = min(
            max(1, maximum // 3),
            max(0, maximum - len(mandatory)),
        )
        for _, index in sorted(turns, reverse=True)[:route_budget]:
            mandatory.add(index)
    buckets = max(1, (maximum - len(mandatory)) // 2)
    width = max(1, math.ceil((count - 2) / buckets))
    primary = next(iter(series.values()), offsets)
    candidates: list[int] = []
    for start in range(1, count - 1, width):
        end = min(count - 1, start + width)
        available = [index for index in range(start, end) if primary[index] is not None]
        if available:
            candidates.extend(
                [min(available, key=lambda index: primary[index]), max(available, key=lambda index: primary[index])]
            )
    selected = set(mandatory)
    for index in candidates:
        if len(selected) >= maximum:
            break
        selected.add(index)
    if len(selected) < maximum:
        step = (count - 1) / max(1, maximum - 1)
        for position in range(maximum):
            selected.add(round(position * step))
            if len(selected) >= maximum:
                break
    ordered = sorted(selected)
    if len(ordered) <= maximum:
        return ordered
    if maximum <= 2:
        return [0, count - 1][:maximum]
    interior = ordered[1:-1]
    keep = maximum - 2
    if len(interior) > keep:
        positions = {
            round(index * (len(interior) - 1) / max(1, keep - 1))
            for index in range(keep)
        }
        interior = [interior[index] for index in sorted(positions)]
    return [0, *interior[:keep], count - 1]


async def _bounded_parquet_call(function, /, *args, **kwargs):
    async with _PARQUET_READ_LIMIT:
        return await asyncio.to_thread(function, *args, **kwargs)


def _stream_payload_from_parquet(
    path,
    *,
    columns: list[str],
    clock_column: str,
    requested: list[str],
    from_offset_ms: int | None,
    to_offset_ms: int | None,
    max_points: int,
) -> dict:
    data = pq.read_table(path, columns=columns).to_pydict()
    offsets = [int(value) for value in data[clock_column]]
    indices = [
        index
        for index, value in enumerate(offsets)
        if (from_offset_ms is None or value >= from_offset_ms)
        and (to_offset_ms is None or value <= to_offset_ms)
    ]
    range_offsets = [offsets[index] for index in indices]
    range_series = {
        metric: [data[metric][index] for index in indices] for metric in requested
    }
    distance_values = [data["distance_m"][index] for index in indices]
    selected = _downsample_indices(range_offsets, range_series, max_points)
    return {
        "offset_ms": [range_offsets[index] for index in selected],
        "distance_m": [distance_values[index] for index in selected],
        "series": {
            metric: [values[index] for index in selected]
            for metric, values in range_series.items()
        },
        "downsampled": len(range_offsets) > len(selected),
        "source_point_count": len(range_offsets),
        "range_first": range_offsets[0] if range_offsets else 0,
        "range_last": range_offsets[-1] if range_offsets else 0,
    }


def _distance_overlay_source_from_parquet(
    path, *, usable_metrics: list[str]
) -> tuple[list[float], dict[str, list]] | None:
    data = pq.read_table(
        path, columns=["distance_m", *usable_metrics]
    ).to_pydict()
    keep = [
        index
        for index, distance in enumerate(data["distance_m"])
        if distance is not None
    ]
    if len(keep) < 2:
        return None
    return (
        [float(data["distance_m"][index]) for index in keep],
        {
            metric: [data[metric][index] for index in keep]
            for metric in usable_metrics
        },
    )


def _parquet_rows(path, *, columns: list[str]) -> list[dict]:
    return pq.read_table(path, columns=columns).to_pylist()


async def activity_stream(
    db,
    *,
    user: dict,
    activity_id: str,
    metrics: list[str],
    clock: str,
    from_offset_ms: int | None,
    to_offset_ms: int | None,
    max_points: int,
) -> dict:
    activity = await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    stream = await (
        await db.execute(
            "SELECT s.*, f.storage_key, f.storage_class, f.state FROM "
            "health_activity_stream_assets s JOIN health_file_assets f ON f.id = s.file_asset_id "
            "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.activity_id = ? "
            "AND s.id = ? AND s.deleted_at IS NULL AND f.deleted_at IS NULL",
            (
                user["family_id"],
                user["id"],
                activity_id,
                activity["primary_stream_asset_id"],
            ),
        )
    ).fetchone()
    if stream is None or stream["state"] != "ready":
        raise FitnessConflictError("Activity stream is unavailable and must be regenerated")
    available_rows = await (
        await db.execute(
            "SELECT metric_key, unit_key FROM health_activity_metric_index WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND stream_asset_id = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"], activity_id, stream["id"]),
        )
    ).fetchall()
    units = {row["metric_key"]: row["unit_key"] for row in available_rows}
    requested = list(dict.fromkeys(metrics))
    unknown = [metric for metric in requested if metric not in units]
    if unknown:
        raise FitnessConflictError(f"Unavailable stream metric: {unknown[0]}")
    clock_column = "elapsed_ms" if clock == "elapsed" else "timer_ms"
    columns = list(dict.fromkeys([clock_column, "distance_m", *requested]))
    path = asset_path(stream)
    if not path.is_file():
        raise FitnessConflictError("Activity stream file is missing and regeneration was queued")
    payload = await _bounded_parquet_call(
        _stream_payload_from_parquet,
        path,
        columns=columns,
        clock_column=clock_column,
        requested=requested,
        from_offset_ms=from_offset_ms,
        to_offset_ms=to_offset_ms,
        max_points=max_points,
    )
    return {
        "activity_id": activity_id,
        "clock": clock,
        "offset_ms": payload["offset_ms"],
        "distance_m": payload["distance_m"],
        "series": payload["series"],
        "units": {metric: units[metric] for metric in requested},
        "downsampled": payload["downsampled"],
        "source_point_count": payload["source_point_count"],
        "requested_range": (
            {
                "from_offset_ms": from_offset_ms if from_offset_ms is not None else payload["range_first"],
                "to_offset_ms": to_offset_ms if to_offset_ms is not None else payload["range_last"],
            }
            if from_offset_ms is not None or to_offset_ms is not None
            else None
        ),
    }


def _interpolate_distance_series(
    distances: list[float],
    values: list[float | None],
    targets: list[float],
) -> list[float | None]:
    result: list[float | None] = []
    cursor = 0
    for target in targets:
        while cursor + 1 < len(distances) and distances[cursor + 1] < target:
            cursor += 1
        if cursor + 1 >= len(distances):
            result.append(values[cursor] if distances[cursor] == target else None)
            continue
        left_distance, right_distance = distances[cursor], distances[cursor + 1]
        left_value, right_value = values[cursor], values[cursor + 1]
        if left_value is None or right_value is None or right_distance <= left_distance:
            result.append(left_value if target == left_distance else None)
            continue
        fraction = (target - left_distance) / (right_distance - left_distance)
        result.append(float(left_value) + fraction * (float(right_value) - float(left_value)))
    return result


async def distance_aligned_comparison_overlay(
    db,
    *,
    user: dict,
    activity_id: str,
    comparison_ids: list[str],
    metrics: list[str],
    points: int,
) -> dict:
    identifiers = list(dict.fromkeys([activity_id, *comparison_ids]))
    if len(identifiers) > 6:
        raise FitnessConflictError("At most five comparison activities may be overlaid")
    allowed_metrics = {"pace_s_per_km", "heart_rate_bpm", "altitude_m", "cadence_spm", "power_w"}
    requested = list(dict.fromkeys(metrics))
    if not requested or any(metric not in allowed_metrics for metric in requested):
        raise FitnessConflictError("Comparison overlay metric is not registered")
    sources: list[dict[str, Any]] = []
    for identifier in identifiers:
        activity = await owned_row(
            db, table="health_activities", record_id=identifier, user=user
        )
        if activity["sport_key"] != "running":
            raise FitnessConflictError("Distance overlays require running activities")
        stream = await (
            await db.execute(
                "SELECT s.id, f.storage_key, f.storage_class, f.state FROM "
                "health_activity_stream_assets s JOIN health_file_assets f ON f.id = s.file_asset_id "
                "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.activity_id = ? "
                "AND s.id = ? AND s.deleted_at IS NULL AND f.deleted_at IS NULL",
                (
                    user["family_id"], user["id"], identifier, activity["primary_stream_asset_id"]
                ),
            )
        ).fetchone()
        if stream is None or stream["state"] != "ready" or not asset_path(stream).is_file():
            continue
        available = {
            row["metric_key"]
            for row in await (
                await db.execute(
                    "SELECT metric_key FROM health_activity_metric_index WHERE family_id = ? "
                    "AND owner_user_id = ? AND activity_id = ? AND stream_asset_id = ? "
                    "AND deleted_at IS NULL",
                    (user["family_id"], user["id"], identifier, stream["id"]),
                )
            ).fetchall()
        }
        usable_metrics = [metric for metric in requested if metric in available]
        loaded = await _bounded_parquet_call(
            _distance_overlay_source_from_parquet,
            asset_path(stream),
            usable_metrics=usable_metrics,
        )
        if loaded is None:
            continue
        distances, metric_series = loaded
        sources.append(
            {
                "activity_id": identifier,
                "title": activity["title"],
                "distance_m": distances,
                "metrics": metric_series,
            }
        )
    if not sources:
        return {"distance_m": [], "activities": [], "metrics": requested}
    common_distance = min(source["distance_m"][-1] for source in sources)
    targets = [common_distance * index / (points - 1) for index in range(points)]
    return {
        "distance_m": [round(value, 2) for value in targets],
        "metrics": requested,
        "alignment": "absolute_distance_to_shortest_selected_activity",
        "activities": [
            {
                "activity_id": source["activity_id"],
                "title": source["title"],
                "series": {
                    metric: _interpolate_distance_series(
                        source["distance_m"], values, targets
                    )
                    for metric, values in source["metrics"].items()
                },
            }
            for source in sources
        ],
    }


async def list_gear(db, *, user: dict, include_inactive: bool = False) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT g.*, COUNT(DISTINCT l.activity_id) AS activity_count, "
            "COALESCE(SUM(a.distance_m), 0) AS usage_distance_m, "
            "COALESCE(SUM(a.timer_duration_s), 0) AS usage_duration_s "
            "FROM health_gear_items g LEFT JOIN health_activity_gear_links l "
            "ON l.gear_id = g.id AND l.family_id = g.family_id "
            "AND l.owner_user_id = g.owner_user_id AND l.deleted_at IS NULL "
            "LEFT JOIN health_activities a ON a.id = l.activity_id "
            "AND a.family_id = g.family_id AND a.owner_user_id = g.owner_user_id "
            "AND a.deleted_at IS NULL "
            "WHERE g.family_id = ? AND g.owner_user_id = ? AND g.deleted_at IS NULL "
            + ("" if include_inactive else "AND g.active = 1 ")
            + "GROUP BY g.id ORDER BY g.active DESC, g.name",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    return [decoded_row(row) for row in rows]


async def _clear_default(db, *, user: dict, sport_key: str, except_id: str | None = None) -> None:
    params: list[Any] = [now_iso(), user["family_id"], user["id"], sport_key]
    query = (
        "UPDATE health_gear_items SET default_for_sport_key = NULL, revision = revision + 1, "
        "updated_at = ? WHERE family_id = ? AND owner_user_id = ? "
        "AND default_for_sport_key = ? AND deleted_at IS NULL"
    )
    if except_id:
        query += " AND id <> ?"
        params.append(except_id)
    history_where = "default_for_sport_key = ? AND deleted_at IS NULL"
    history_params: list[Any] = [sport_key]
    if except_id:
        history_where += " AND id <> ?"
        history_params.append(except_id)
    await save_owned_rows_history(
        db,
        table="health_gear_items",
        user=user,
        where=history_where,
        params=history_params,
    )
    await db.execute(query, params)


async def create_gear(db, *, user: dict, body: GearPayload) -> dict:
    identifier = new_id(body.id)
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    if body.default_for_sport_key:
        await _clear_default(db, user=user, sport_key=body.default_for_sport_key)
    await insert_owned(
        db,
        table="health_gear_items",
        record_id=identifier,
        values=values,
        user=user,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    return decoded_row(
        await owned_row(db, table="health_gear_items", record_id=identifier, user=user)
    )


async def patch_gear(db, *, user: dict, gear_id: str, body: GearPatch) -> dict:
    row = await owned_row(db, table="health_gear_items", record_id=gear_id, user=user)
    values = body.model_dump(exclude_unset=True)
    resulting_start = values.get("started_at", row["started_at"])
    resulting_retired = values.get("retired_at", row["retired_at"])
    if resulting_start and resulting_retired:
        start_date = (
            resulting_start
            if isinstance(resulting_start, date)
            else date.fromisoformat(str(resulting_start)[:10])
        )
        retired_date = (
            resulting_retired
            if isinstance(resulting_retired, date)
            else date.fromisoformat(str(resulting_retired)[:10])
        )
        if retired_date < start_date:
            raise FitnessConflictError("retired_at cannot be before started_at")
    if values.get("default_for_sport_key"):
        await _clear_default(
            db, user=user, sport_key=values["default_for_sport_key"], except_id=gear_id
        )
    if values:
        await update_owned(
            db, table="health_gear_items", record_id=gear_id, values=values, user=user
        )
    return decoded_row(
        await owned_row(db, table="health_gear_items", record_id=row["id"], user=user)
    )


async def set_gear_default(db, *, user: dict, gear_id: str, sport_key: str) -> dict:
    await owned_row(db, table="health_gear_items", record_id=gear_id, user=user)
    await _clear_default(db, user=user, sport_key=sport_key, except_id=gear_id)
    await update_owned(
        db,
        table="health_gear_items",
        record_id=gear_id,
        values={"default_for_sport_key": sport_key, "active": True},
        user=user,
    )
    return decoded_row(
        await owned_row(db, table="health_gear_items", record_id=gear_id, user=user)
    )


async def delete_gear(db, *, user: dict, gear_id: str) -> None:
    await soft_delete_owned(db, table="health_gear_items", record_id=gear_id, user=user)


async def retire_gear(db, *, user: dict, gear_id: str) -> dict:
    await owned_row(db, table="health_gear_items", record_id=gear_id, user=user)
    await update_owned(
        db,
        table="health_gear_items",
        record_id=gear_id,
        values={
            "active": False,
            "retired_at": date.today().isoformat(),
            "default_for_sport_key": None,
        },
        user=user,
    )
    return decoded_row(
        await owned_row(db, table="health_gear_items", record_id=gear_id, user=user)
    )


async def _replace_activity_gear(
    db, *, user: dict, activity_id: str, gear_ids: list[str]
) -> None:
    timestamp = now_iso()
    await save_owned_rows_history(
        db,
        table="health_activity_gear_links",
        user=user,
        where="activity_id = ? AND deleted_at IS NULL",
        params=(activity_id,),
    )
    await db.execute(
        "UPDATE health_activity_gear_links SET deleted_at = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND activity_id = ? "
        "AND deleted_at IS NULL",
        (timestamp, timestamp, user["family_id"], user["id"], activity_id),
    )
    for index, gear_id in enumerate(dict.fromkeys(gear_ids)):
        await validate_owned_reference(
            db, table="health_gear_items", record_id=gear_id, user=user
        )
        await insert_owned(
            db,
            table="health_activity_gear_links",
            record_id=new_id(),
            values={
                "activity_id": activity_id,
                "gear_id": gear_id,
                "role": "primary" if index == 0 else "secondary",
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )


async def link_activity_to_plan(
    db,
    *,
    user: dict,
    activity_id: str,
    planned_session_id: str,
    match_method: str,
    user_confirmed: bool,
    explanation: str | None = None,
    record_activity_sync_change: bool | None = None,
) -> None:
    activity = await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    plan = await owned_row(
        db, table="health_planned_sessions", record_id=planned_session_id, user=user
    )
    if activity["sport_key"] != plan["sport_key"]:
        raise FitnessConflictError("Activity and planned session sports do not match")
    timestamp = now_iso()
    old_links = await (
        await db.execute(
            "SELECT * FROM health_plan_activity_links WHERE family_id = ? "
            "AND owner_user_id = ? AND active = 1 AND (activity_id = ? OR planned_session_id = ?) "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"], activity_id, planned_session_id),
        )
    ).fetchall()
    for old in old_links:
        await save_owned_rows_history(
            db,
            table="health_plan_activity_links",
            user=user,
            where="id = ?",
            params=(old["id"],),
        )
        await db.execute(
            "UPDATE health_plan_activity_links SET active = 0, unlinked_at = ?, updated_at = ?, "
            "revision = revision + 1 WHERE id = ?",
            (timestamp, timestamp, old["id"]),
        )
        if old["planned_session_id"] != planned_session_id:
            await save_owned_rows_history(
                db,
                table="health_planned_sessions",
                user=user,
                where="id = ?",
                params=(old["planned_session_id"],),
            )
            await db.execute(
                "UPDATE health_planned_sessions SET completion_activity_id = NULL, "
                "completion_state = NULL, updated_at = ?, revision = revision + 1 "
                "WHERE id = ? AND family_id = ? AND owner_user_id = ?",
                (timestamp, old["planned_session_id"], user["family_id"], user["id"]),
            )
    await insert_owned(
        db,
        table="health_plan_activity_links",
        record_id=new_id(),
        values={
            "planned_session_id": planned_session_id,
            "activity_id": activity_id,
            "match_method": match_method,
            "confidence": 1.0 if user_confirmed else 0.75,
            "active": True,
            "user_confirmed": user_confirmed,
            "explanation": explanation,
            "revision": 1,
        },
        user=user,
        now=timestamp,
    )
    await update_owned(
        db,
        table="health_activities",
        record_id=activity_id,
        values={
            "planned_session_id": planned_session_id,
            "workout_version_id": plan["workout_version_id"],
            "matched_plan_key": match_method,
        },
        user=user,
        now=timestamp,
        record_sync_change=(
            activity["sport_key"] == "strength"
            if record_activity_sync_change is None
            else record_activity_sync_change
        ),
    )
    await update_owned(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        values={
            "completion_activity_id": activity_id,
            "completion_state": "matched",
            "status": "completed",
        },
        user=user,
        now=timestamp,
    )
    removed_planned_goal_links = await save_owned_rows_history(
        db,
        table="health_activity_goal_links",
        user=user,
        where="activity_id = ? AND role = 'planned' AND deleted_at IS NULL",
        params=(activity_id,),
    )
    await db.execute(
        "UPDATE health_activity_goal_links SET deleted_at = ?, updated_at = ?, "
        "revision = revision + 1 "
        "WHERE family_id = ? AND owner_user_id = ? AND activity_id = ? "
        "AND role = 'planned' AND deleted_at IS NULL",
        (timestamp, timestamp, user["family_id"], user["id"], activity_id),
    )
    for link_id in removed_planned_goal_links:
        deleted_link = await (
            await db.execute(
                "SELECT revision FROM health_activity_goal_links WHERE id = ? "
                "AND family_id = ? AND owner_user_id = ?",
                (link_id, user["family_id"], user["id"]),
            )
        ).fetchone()
        await append_change(
            db,
            entity_type="activity_goal_link",
            entity_id=link_id,
            revision=int(deleted_link["revision"]),
            operation="delete",
            user=user,
            changed_at=timestamp,
        )
    goal_links = await (
        await db.execute(
            "SELECT goal_id FROM health_planned_session_goal_links WHERE family_id = ? "
            "AND owner_user_id = ? AND planned_session_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], planned_session_id),
        )
    ).fetchall()
    for goal in goal_links:
        await insert_owned(
            db,
            table="health_activity_goal_links",
            record_id=new_id(),
            values={
                "activity_id": activity_id,
                "goal_id": goal["goal_id"],
                "role": "planned",
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )
    await save_owned_rows_history(
        db,
        table="health_session_checkins",
        user=user,
        where="planned_session_id = ? AND timing = 'pre' "
        "AND activity_id IS NULL AND deleted_at IS NULL",
        params=(planned_session_id,),
    )
    await db.execute(
        "UPDATE health_session_checkins SET activity_id = ?, updated_at = ?, revision = revision + 1 "
        "WHERE family_id = ? AND owner_user_id = ? AND planned_session_id = ? "
        "AND timing = 'pre' AND activity_id IS NULL AND deleted_at IS NULL",
        (activity_id, timestamp, user["family_id"], user["id"], planned_session_id),
    )
    actual_gear = await (
        await db.execute(
            "SELECT 1 FROM health_activity_gear_links WHERE family_id = ? AND owner_user_id = ? "
            "AND activity_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchone()
    if actual_gear is None:
        intended = await (
            await db.execute(
                "SELECT gear_id, role FROM health_planned_session_gear_links WHERE family_id = ? "
                "AND owner_user_id = ? AND planned_session_id = ? AND deleted_at IS NULL",
                (user["family_id"], user["id"], planned_session_id),
            )
        ).fetchall()
        for gear in intended:
            await insert_owned(
                db,
                table="health_activity_gear_links",
                record_id=new_id(),
                values={
                    "activity_id": activity_id,
                    "gear_id": gear["gear_id"],
                    "role": gear["role"],
                    "revision": 1,
                },
                user=user,
                now=timestamp,
            )


async def unlink_activity_from_plan(db, *, user: dict, activity_id: str) -> None:
    activity = await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    timestamp = now_iso()
    if activity["planned_session_id"]:
        await save_owned_rows_history(
            db,
            table="health_planned_sessions",
            user=user,
            where="id = ?",
            params=(activity["planned_session_id"],),
        )
        await db.execute(
            "UPDATE health_planned_sessions SET completion_activity_id = NULL, "
            "completion_state = NULL, updated_at = ?, revision = revision + 1 WHERE id = ? "
            "AND family_id = ? AND owner_user_id = ?",
            (
                timestamp,
                activity["planned_session_id"],
                user["family_id"],
                user["id"],
            ),
        )
    await save_owned_rows_history(
        db,
        table="health_plan_activity_links",
        user=user,
        where="activity_id = ? AND active = 1 AND deleted_at IS NULL",
        params=(activity_id,),
    )
    await db.execute(
        "UPDATE health_plan_activity_links SET active = 0, unlinked_at = ?, updated_at = ?, "
        "revision = revision + 1 WHERE family_id = ? AND owner_user_id = ? "
        "AND activity_id = ? AND active = 1 AND deleted_at IS NULL",
        (timestamp, timestamp, user["family_id"], user["id"], activity_id),
    )
    await update_owned(
        db,
        table="health_activities",
        record_id=activity_id,
        values={"planned_session_id": None, "workout_version_id": None, "matched_plan_key": None},
        user=user,
        record_sync_change=activity["sport_key"] == "strength",
    )


async def auto_match_activity(
    db,
    *,
    user: dict,
    activity_id: str,
    record_activity_sync_change: bool | None = None,
) -> str | None:
    activity = await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    if activity["planned_session_id"]:
        return activity["planned_session_id"]
    started = datetime.fromisoformat(activity["started_at_utc"].replace("Z", "+00:00"))
    lower = (started - timedelta(hours=2)).isoformat()
    upper = (started + timedelta(hours=2)).isoformat()
    timed_candidates = await (
        await db.execute(
            "SELECT * FROM health_planned_sessions WHERE family_id = ? AND owner_user_id = ? "
            "AND sport_key = ? AND status IN ('accepted','scheduled','in_progress') "
            "AND scheduled_start_utc BETWEEN ? AND ? AND completion_activity_id IS NULL "
            "AND deleted_at IS NULL ORDER BY ABS(julianday(scheduled_start_utc) - "
            "julianday(?)) LIMIT 3",
            (
                user["family_id"],
                user["id"],
                activity["sport_key"],
                lower,
                upper,
                activity["started_at_utc"],
            ),
        )
    ).fetchall()
    plausible = [
        plan for plan in timed_candidates if _duration_is_plausible(plan, activity)
    ]
    if len(plausible) == 1:
        await link_activity_to_plan(
            db,
            user=user,
            activity_id=activity_id,
            planned_session_id=plausible[0]["id"],
            match_method="conservative_time_sport_duration",
            user_confirmed=False,
            record_activity_sync_change=record_activity_sync_change,
        )
        return plausible[0]["id"]
    if plausible:
        return None

    local_day = activity["local_calendar_date"] or activity["started_at_utc"][:10]
    local_date = date.fromisoformat(local_day)
    day_candidates = await (
        await db.execute(
            "SELECT * FROM health_planned_sessions WHERE family_id = ? AND owner_user_id = ? "
            "AND sport_key = ? AND status IN ('accepted','scheduled','in_progress') "
            "AND (scheduled_date = ? OR substr(scheduled_start_utc,1,10) BETWEEN ? AND ?) "
            "AND completion_activity_id IS NULL AND deleted_at IS NULL "
            "ORDER BY created_at LIMIT 10",
            (
                user["family_id"], user["id"], activity["sport_key"], local_day,
                (local_date - timedelta(days=1)).isoformat(),
                (local_date + timedelta(days=1)).isoformat(),
            ),
        )
    ).fetchall()
    plausible = [
        plan
        for plan in day_candidates
        if _plan_local_day(plan) == local_day
        and _duration_is_plausible(plan, activity)
    ]
    if len(plausible) == 1:
        await link_activity_to_plan(
            db,
            user=user,
            activity_id=activity_id,
            planned_session_id=plausible[0]["id"],
            match_method="conservative_same_day_sport_duration",
            user_confirmed=False,
            explanation="Only plausible completed activity for this dated session.",
            record_activity_sync_change=record_activity_sync_change,
        )
        return plausible[0]["id"]
    return None


def _duration_is_plausible(plan, activity) -> bool:
    expected = float(plan["expected_duration_s"] or 0)
    actual = float(
        activity["timer_duration_s"]
        or activity["moving_duration_s"]
        or activity["elapsed_duration_s"]
        or 0
    )
    return not expected or not actual or 0.5 <= actual / expected <= 1.5


def _plan_local_day(plan) -> str | None:
    if plan["scheduled_date"]:
        return str(plan["scheduled_date"])
    if not plan["scheduled_start_utc"]:
        return None
    scheduled = datetime.fromisoformat(
        str(plan["scheduled_start_utc"]).replace("Z", "+00:00")
    )
    if scheduled.tzinfo is None:
        scheduled = scheduled.replace(tzinfo=timezone.utc)
    try:
        zone = ZoneInfo(plan["local_timezone"] or "UTC")
    except (ZoneInfoNotFoundError, ValueError):
        zone = ZoneInfo("UTC")
    return scheduled.astimezone(zone).date().isoformat()


async def auto_match_plan(
    db,
    *,
    user: dict,
    planned_session_id: str,
) -> str | None:
    """Match a newly saved plan to one unambiguous activity already imported."""
    plan = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
    )
    if (
        plan["status"] not in {"accepted", "scheduled", "in_progress"}
        or plan["completion_activity_id"]
    ):
        return None

    candidates = []
    match_method = "conservative_time_sport_duration"
    explanation = "Only plausible completed activity near the planned start."
    if plan["scheduled_start_utc"]:
        scheduled = datetime.fromisoformat(
            plan["scheduled_start_utc"].replace("Z", "+00:00")
        )
        lower = (scheduled - timedelta(hours=2)).isoformat()
        upper = (scheduled + timedelta(hours=2)).isoformat()
        candidates = await (
            await db.execute(
                "SELECT * FROM health_activities WHERE family_id = ? "
                "AND owner_user_id = ? AND sport_key = ? AND status = 'completed' "
                "AND planned_session_id IS NULL AND started_at_utc BETWEEN ? AND ? "
                "AND deleted_at IS NULL ORDER BY ABS(julianday(started_at_utc) - "
                "julianday(?)) LIMIT 3",
                (
                    user["family_id"], user["id"], plan["sport_key"], lower, upper,
                    plan["scheduled_start_utc"],
                ),
            )
        ).fetchall()

    plausible = [
        activity for activity in candidates if _duration_is_plausible(plan, activity)
    ]
    planned_day = _plan_local_day(plan)
    if not plausible and planned_day:
        match_method = "conservative_same_day_sport_duration"
        explanation = "Only plausible completed activity for this dated session."
        candidates = await (
            await db.execute(
                "SELECT * FROM health_activities WHERE family_id = ? "
                "AND owner_user_id = ? AND sport_key = ? AND status = 'completed' "
                "AND planned_session_id IS NULL AND COALESCE(local_calendar_date, "
                "substr(started_at_utc,1,10)) = ? AND deleted_at IS NULL "
                "ORDER BY started_at_utc LIMIT 3",
                (
                    user["family_id"], user["id"], plan["sport_key"],
                    planned_day,
                ),
            )
        ).fetchall()
        plausible = [
            activity
            for activity in candidates
            if _duration_is_plausible(plan, activity)
        ]
    if len(plausible) != 1:
        return None
    activity_id = plausible[0]["id"]
    await link_activity_to_plan(
        db,
        user=user,
        activity_id=activity_id,
        planned_session_id=planned_session_id,
        match_method=match_method,
        user_confirmed=False,
        explanation=explanation,
        record_activity_sync_change=False,
    )
    return activity_id


async def patch_activity_context(
    db, *, user: dict, activity_id: str, body: ActivityContextPatch
) -> dict:
    row = await owned_row(db, table="health_activities", record_id=activity_id, user=user)
    values = body.model_dump(
        exclude_unset=True,
        exclude={"id", "gear_ids", "planned_session_id"},
    )
    if "workout_classification" in values:
        values["classification_source"] = "user"
    if values:
        await update_owned(
            db,
            table="health_activities",
            record_id=activity_id,
            values=values,
            user=user,
            record_sync_change=row["sport_key"] == "strength",
        )
    fields_set = body.model_fields_set
    if "planned_session_id" in fields_set:
        if body.planned_session_id is None:
            await unlink_activity_from_plan(db, user=user, activity_id=activity_id)
        else:
            await link_activity_to_plan(
                db,
                user=user,
                activity_id=activity_id,
                planned_session_id=str(body.planned_session_id),
                match_method="user",
                user_confirmed=True,
            )
    if body.gear_ids is not None:
        await _replace_activity_gear(
            db,
            user=user,
            activity_id=activity_id,
            gear_ids=[str(identifier) for identifier in body.gear_ids],
        )
    return await activity_detail(db, user=user, activity_id=activity_id)


def _route_overlap_score(
    left_raw: Any,
    right_raw: Any,
    *,
    tolerance_m: float = 75,
) -> float | None:
    left = _json(left_raw, [])
    right = _json(right_raw, [])
    if len(left) < 2 or len(right) < 2:
        return None

    def near_share(source: list, target: list) -> float:
        matched = 0
        for latitude, longitude in source:
            lat_scale = 111_320.0
            lon_scale = max(1.0, 111_320.0 * math.cos(math.radians(float(latitude))))
            if any(
                math.hypot(
                    (float(latitude) - float(other_latitude)) * lat_scale,
                    (float(longitude) - float(other_longitude)) * lon_scale,
                )
                <= tolerance_m
                for other_latitude, other_longitude in target
            ):
                matched += 1
        return matched / len(source)

    return (near_share(left, right) + near_share(right, left)) / 2


async def _source_signature(db, *, user: dict, activity_id: str) -> str | None:
    row = await (
        await db.execute(
            "SELECT COALESCE(s.source_device_identifier, s.origin_provider_key) AS source_key "
            "FROM health_activity_source_records l JOIN health_source_records s "
            "ON s.id = l.source_record_id WHERE l.family_id = ? AND l.owner_user_id = ? "
            "AND l.activity_id = ? AND l.deleted_at IS NULL AND s.deleted_at IS NULL "
            "ORDER BY CASE l.role WHEN 'primary' THEN 0 ELSE 1 END LIMIT 1",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchone()
    return row["source_key"] if row else None


async def _contemporaneous_readiness(
    db, *, user: dict, activity_id: str
) -> float | None:
    row = await (
        await db.execute(
            "SELECT readiness_1_5 FROM health_session_checkins WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND timing = 'pre' "
            "AND capture_quality = 'contemporaneous' AND captured_before_activity_start = 1 "
            "AND deleted_at IS NULL ORDER BY captured_at_utc DESC LIMIT 1",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchone()
    return float(row["readiness_1_5"]) if row and row["readiness_1_5"] is not None else None


def _run_duration_seconds(activity: Any) -> float | None:
    for key in ("moving_duration_s", "timer_duration_s", "elapsed_duration_s"):
        value = activity[key]
        if value is not None and float(value) > 0:
            return float(value)
    return None


def _run_distance_label(distance_m: float) -> str:
    standards = (
        (1_609.344, "1 mile"),
        (5_000.0, "5K"),
        (10_000.0, "10K"),
        (21_097.5, "Half marathon"),
        (42_195.0, "Marathon"),
    )
    nearest_distance, nearest_label = min(
        standards, key=lambda item: abs(item[0] - distance_m)
    )
    if abs(nearest_distance - distance_m) / nearest_distance <= 0.05:
        return nearest_label
    return f"{distance_m / 1_000:.1f} km"


def _automatic_run_comparison(target: Any, previous: Any) -> dict | None:
    target_distance = float(target["distance_m"] or 0)
    previous_distance = float(previous["distance_m"] or 0)
    target_duration = _run_duration_seconds(target)
    previous_duration = _run_duration_seconds(previous)
    if (
        target_distance <= 0
        or previous_distance <= 0
        or target_duration is None
        or previous_duration is None
    ):
        return None
    target_pace = target_duration * 1_000 / target_distance
    previous_pace = previous_duration * 1_000 / previous_distance
    return {
        "algorithm_version": "previous-similar-distance-v1",
        "distance_label": _run_distance_label(target_distance),
        "current_distance_m": target_distance,
        "previous_distance_m": previous_distance,
        "distance_delta_m": target_distance - previous_distance,
        "current_duration_s": target_duration,
        "previous_duration_s": previous_duration,
        "duration_delta_s": target_duration - previous_duration,
        "duration_improvement_s": previous_duration - target_duration,
        "current_pace_s_per_km": target_pace,
        "previous_pace_s_per_km": previous_pace,
        "pace_delta_s_per_km": target_pace - previous_pace,
        "pace_improvement_s_per_km": previous_pace - target_pace,
    }


async def previous_similar_run(
    db,
    *,
    user: dict,
    activity_id: str,
) -> dict | None:
    """Return the immediately previous owner-private run within 5% distance."""
    target = await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    target_distance = float(target["distance_m"] or 0)
    if target["sport_key"] not in RUN_SPORT_KEYS or target_distance <= 0:
        return None
    previous = await (
        await db.execute(
            "SELECT * FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
            "AND sport_key = ? AND id <> ? AND status = 'completed' "
            "AND julianday(started_at_utc) < julianday(?) "
            "AND distance_m BETWEEN ? AND ? "
            "AND COALESCE(moving_duration_s, timer_duration_s, elapsed_duration_s) > 0 "
            "AND deleted_at IS NULL ORDER BY julianday(started_at_utc) DESC LIMIT 1",
            (
                user["family_id"],
                user["id"],
                target["sport_key"],
                activity_id,
                target["started_at_utc"],
                target_distance * 0.95,
                target_distance * 1.05,
            ),
        )
    ).fetchone()
    if previous is None:
        return None
    comparison = _automatic_run_comparison(target, previous)
    if comparison is None:
        return None
    return {
        "activity": await activity_summary(db, user=user, row=previous),
        "comparison": comparison,
    }


async def comparable_runs(
    db,
    *,
    user: dict,
    activity_id: str,
    gear_id: str | None = None,
    phase_id: str | None = None,
    sensor_key: str | None = None,
    readiness_min: float | None = None,
    readiness_max: float | None = None,
) -> list[dict]:
    target = await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    if target["sport_key"] not in RUN_SPORT_KEYS:
        return []
    rows = await (
        await db.execute(
            "SELECT * FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
            "AND sport_key = ? AND id <> ? AND status = 'completed' "
            "AND deleted_at IS NULL ORDER BY started_at_utc DESC LIMIT 100",
            (user["family_id"], user["id"], target["sport_key"], activity_id),
        )
    ).fetchall()
    target_gear = {item["id"] for item in await _activity_gear(db, user=user, activity_id=activity_id)}
    target_source = await _source_signature(db, user=user, activity_id=activity_id)
    target_readiness = await _contemporaneous_readiness(
        db, user=user, activity_id=activity_id
    )
    target_metrics = {
        item["metric_key"]: item["value_number"]
        for item in await _summary_metrics(db, user=user, activity_id=activity_id)
    }
    target_started = datetime.fromisoformat(target["started_at_utc"].replace("Z", "+00:00"))
    automatic = await previous_similar_run(
        db, user=user, activity_id=activity_id
    )
    results = []
    for row in rows:
        if phase_id and row["phase_id"] != phase_id:
            continue
        components: dict[str, float | None] = {}
        reasons: list[str] = []
        similar_distance = False
        if target["distance_m"] and row["distance_m"]:
            ratio = abs(float(row["distance_m"]) - float(target["distance_m"])) / float(
                target["distance_m"]
            )
            components["distance"] = max(0.0, 1 - ratio)
            if ratio <= 0.1:
                similar_distance = True
                reasons.append("similar distance")
        if target["timer_duration_s"] and row["timer_duration_s"]:
            ratio = abs(float(row["timer_duration_s"]) - float(target["timer_duration_s"])) / float(
                target["timer_duration_s"]
            )
            components["duration"] = max(0.0, 1 - ratio)
            if ratio <= 0.1:
                reasons.append("similar duration")
        if target["workout_classification"] and row["workout_classification"]:
            components["classification"] = float(
                target["workout_classification"] == row["workout_classification"]
            )
            if components["classification"]:
                reasons.append("same workout classification")
        if target["phase_id"] and row["phase_id"]:
            components["phase"] = float(target["phase_id"] == row["phase_id"])
            if components["phase"]:
                reasons.append("same training phase")
        candidate_gear = {
            item["id"] for item in await _activity_gear(db, user=user, activity_id=row["id"])
        }
        if gear_id and gear_id not in candidate_gear:
            continue
        if target_gear and candidate_gear:
            components["gear"] = float(bool(target_gear.intersection(candidate_gear)))
            if components["gear"]:
                reasons.append("same recorded gear")
        route_overlap = _route_overlap_score(
            target["route_preview_json"], row["route_preview_json"]
        )
        if route_overlap is not None:
            components["route_overlap"] = route_overlap
            if route_overlap >= 0.7:
                reasons.append("substantially the same route")
        candidate_metrics = {
            item["metric_key"]: item["value_number"]
            for item in await _summary_metrics(db, user=user, activity_id=row["id"])
        }
        target_gain = target_metrics.get("elevation.gain_m")
        candidate_gain = candidate_metrics.get("elevation.gain_m")
        if target_gain is not None and candidate_gain is not None:
            denominator = max(50.0, abs(float(target_gain)))
            components["elevation"] = max(
                0.0, 1 - abs(float(candidate_gain) - float(target_gain)) / denominator
            )
            if components["elevation"] >= 0.8:
                reasons.append("similar elevation gain")
        candidate_source = await _source_signature(
            db, user=user, activity_id=row["id"]
        )
        if sensor_key and candidate_source != sensor_key:
            continue
        if target_source and candidate_source:
            components["sensor_source"] = float(target_source == candidate_source)
            if components["sensor_source"]:
                reasons.append("same recorded sensor source")
        candidate_readiness = await _contemporaneous_readiness(
            db, user=user, activity_id=row["id"]
        )
        if readiness_min is not None and (
            candidate_readiness is None or candidate_readiness < readiness_min
        ):
            continue
        if readiness_max is not None and (
            candidate_readiness is None or candidate_readiness > readiness_max
        ):
            continue
        if target_readiness is not None and candidate_readiness is not None:
            components["readiness"] = max(
                0.0, 1 - abs(candidate_readiness - target_readiness) / 4
            )
            if abs(candidate_readiness - target_readiness) <= 0.5:
                reasons.append("similar contemporaneous readiness")
        candidate_started = datetime.fromisoformat(row["started_at_utc"].replace("Z", "+00:00"))
        age_days = abs((target_started - candidate_started).days)
        components["recency"] = max(0.0, 1 - age_days / 365)
        available = [value for value in components.values() if value is not None]
        score = sum(available) / len(available) if available else 0
        # Distance is the primary comparison for a distance event. Do not throw
        # away a genuine 5K/10K peer merely because optional route, gear or
        # readiness context is absent or different.
        if score < 0.35 and not similar_distance:
            continue
        results.append(
            {
                "activity": await activity_summary(db, user=user, row=row),
                "score": round(score, 4),
                "reasons": reasons or ["recent running activity"],
                "component_scores": components,
                "algorithm_version": "comparable-runs-v3",
                "available_component_count": len(available),
                "selected": False,
            }
        )
    ranked = sorted(results, key=lambda result: result["score"], reverse=True)
    automatic_id = automatic["activity"]["id"] if automatic else None
    automatic_result = next(
        (
            result
            for result in ranked
            if result["activity"]["id"] == automatic_id
        ),
        None,
    )
    if (
        automatic is not None
        and automatic_result is None
        and automatic_id not in {row["id"] for row in rows}
    ):
        distance_score = max(
            0.0,
            1
            - abs(automatic["comparison"]["distance_delta_m"])
            / float(target["distance_m"]),
        )
        automatic_result = {
            "activity": automatic["activity"],
            "score": round(distance_score, 4),
            "reasons": ["previous similar-distance run"],
            "component_scores": {"distance": distance_score},
            "algorithm_version": "comparable-runs-v3",
            "available_component_count": 1,
            "selected": False,
        }
        ranked.append(automatic_result)
        ranked.sort(key=lambda result: result["score"], reverse=True)
    if automatic_result is not None:
        automatic_result["is_previous_similar_distance"] = True
        automatic_result["automatic_comparison"] = automatic["comparison"]
    ordered = ranked[:12]
    if automatic_result is not None and automatic_result not in ordered:
        ordered = sorted(
            [*ordered[:11], automatic_result],
            key=lambda result: result["score"],
            reverse=True,
        )
    for result in ordered[:5]:
        result["selected"] = True
    return ordered


def _flatten_steps(steps: list[dict], multiplier: int = 1) -> list[dict]:
    leaves: list[dict] = []
    for step in steps:
        if step["step_kind"] == "repeat_block":
            for _ in range(int(step.get("repeat_count") or 0) * multiplier):
                leaves.extend(_flatten_steps(step.get("children", [])))
        else:
            leaves.extend([step] * multiplier)
    return leaves


async def _run_target_adherence(
    db,
    *,
    user: dict,
    activity: Any,
    steps: list[dict],
) -> dict:
    if not steps or not activity["primary_stream_asset_id"]:
        return {"time_in_target_s": None, "target_time_s": None, "steps": {}}
    metric_for_target = {
        "pace_s_per_km": "pace_s_per_km",
        "heart_rate_bpm": "heart_rate_bpm",
        "power_w": "power_w",
        "cadence_spm": "cadence_spm",
    }
    requested = sorted(
        {
            metric_for_target[step["target_type"]]
            for step in steps
            if step.get("target_type") in metric_for_target
        }
    )
    if not requested:
        return {"time_in_target_s": None, "target_time_s": None, "steps": {}}
    stream = await (
        await db.execute(
            "SELECT s.id, f.storage_key, f.storage_class, f.state FROM "
            "health_activity_stream_assets s JOIN health_file_assets f ON f.id = s.file_asset_id "
            "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.activity_id = ? "
            "AND s.id = ? AND s.deleted_at IS NULL AND f.deleted_at IS NULL",
            (
                user["family_id"],
                user["id"],
                activity["id"],
                activity["primary_stream_asset_id"],
            ),
        )
    ).fetchone()
    if stream is None or stream["state"] != "ready":
        return {"time_in_target_s": None, "target_time_s": None, "steps": {}}
    available = {
        row["metric_key"]
        for row in await (
            await db.execute(
                "SELECT metric_key FROM health_activity_metric_index WHERE family_id = ? "
                "AND owner_user_id = ? AND activity_id = ? AND stream_asset_id = ? "
                "AND deleted_at IS NULL",
                (user["family_id"], user["id"], activity["id"], stream["id"]),
            )
        ).fetchall()
    }
    columns = ["timer_ms", "distance_m", *[item for item in requested if item in available]]
    path = asset_path(stream)
    if not path.is_file():
        return {"time_in_target_s": None, "target_time_s": None, "steps": {}}
    data = await _bounded_parquet_call(_parquet_rows, path, columns=columns)
    if len(data) < 2:
        return {"time_in_target_s": None, "target_time_s": None, "steps": {}}

    per_step = {
        str(step["id"]): {"target_time_s": 0.0, "time_in_target_s": 0.0}
        for step in steps
    }
    step_index = 0
    step_start_timer = int(data[0]["timer_ms"] or 0)
    step_start_distance = float(data[0]["distance_m"] or 0)
    for current, following in zip(data, data[1:]):
        while step_index < len(steps) - 1:
            step = steps[step_index]
            duration_value = float(step.get("duration_value") or 0)
            complete = False
            if step.get("duration_type") == "time_s":
                complete = (int(current["timer_ms"] or 0) - step_start_timer) / 1_000 >= duration_value
            elif step.get("duration_type") == "distance_m" and current.get("distance_m") is not None:
                complete = float(current["distance_m"]) - step_start_distance >= duration_value
            if not complete:
                break
            step_index += 1
            step_start_timer = int(current["timer_ms"] or 0)
            step_start_distance = float(current.get("distance_m") or step_start_distance)
        step = steps[step_index]
        target_type = step.get("target_type")
        metric_key = metric_for_target.get(str(target_type))
        if metric_key is None or metric_key not in available:
            continue
        value = current.get(metric_key)
        if value is None:
            continue
        duration_s = (int(following["timer_ms"] or 0) - int(current["timer_ms"] or 0)) / 1_000
        if duration_s <= 0 or duration_s > 60:
            continue
        low = step.get("target_low")
        high = step.get("target_high")
        if low is None or high is None:
            continue
        lower, upper = sorted((float(low), float(high)))
        bucket = per_step[str(step["id"])]
        bucket["target_time_s"] += duration_s
        if lower <= float(value) <= upper:
            bucket["time_in_target_s"] += duration_s
    total_target = sum(item["target_time_s"] for item in per_step.values())
    total_inside = sum(item["time_in_target_s"] for item in per_step.values())
    for item in per_step.values():
        item["target_adherence_pct"] = (
            round(item["time_in_target_s"] / item["target_time_s"] * 100, 1)
            if item["target_time_s"]
            else None
        )
        item["target_time_s"] = round(item["target_time_s"], 1)
        item["time_in_target_s"] = round(item["time_in_target_s"], 1)
    return {
        "time_in_target_s": round(total_inside, 1) if total_target else None,
        "target_time_s": round(total_target, 1) if total_target else None,
        "steps": per_step,
    }


async def activity_adherence(db, *, user: dict, activity_id: str) -> dict:
    activity = await owned_row(
        db, table="health_activities", record_id=activity_id, user=user
    )
    if not activity["planned_session_id"]:
        return {"status": "unavailable", "explanation": "No planned session is linked."}
    plan = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=activity["planned_session_id"],
        user=user,
    )
    steps = []
    if plan["workout_version_id"]:
        from app.services.fitness.run_plans import run_steps_for_version

        steps = _flatten_steps(
            await run_steps_for_version(
                db, user=user, version_id=plan["workout_version_id"]
            )
        )
    target_adherence = await _run_target_adherence(
        db,
        user=user,
        activity=activity,
        steps=steps,
    )
    planned_distance = sum(
        float(step["duration_value"] or 0)
        for step in steps
        if step["duration_type"] == "distance_m"
    ) or plan["expected_distance_m"]
    planned_duration = sum(
        float(step["duration_value"] or 0)
        for step in steps
        if step["duration_type"] == "time_s"
    ) or plan["expected_duration_s"]
    actual_distance = activity["distance_m"]
    actual_duration = activity["timer_duration_s"]
    step_results = []
    for step in steps:
        if step["duration_type"] == "distance_m" and planned_distance and actual_distance:
            ratio = float(actual_distance) / float(planned_distance)
            actual = float(step["duration_value"] or 0) * min(ratio, 1.25)
            planned_text = f"{float(step['duration_value']):.0f} m"
            actual_text = f"{actual:.0f} m"
        elif step["duration_type"] == "time_s" and planned_duration and actual_duration:
            ratio = float(actual_duration) / float(planned_duration)
            actual = float(step["duration_value"] or 0) * min(ratio, 1.25)
            planned_text = f"{float(step['duration_value']):.0f} s"
            actual_text = f"{actual:.0f} s"
        else:
            ratio = 1.0
            planned_text = step["duration_type"].replace("_", " ")
            actual_text = "Not measurable"
        state = "completed" if 0.9 <= ratio <= 1.1 else ("extended" if ratio > 1.1 else "partial")
        step_results.append(
            {
                "id": step["id"],
                "label": step["display_name"],
                "state": state,
                "actual": actual_text,
                "planned": planned_text,
                "target_adherence_pct": target_adherence["steps"]
                .get(str(step["id"]), {})
                .get("target_adherence_pct"),
                "time_in_target_s": target_adherence["steps"]
                .get(str(step["id"]), {})
                .get("time_in_target_s"),
                "target_time_s": target_adherence["steps"]
                .get(str(step["id"]), {})
                .get("target_time_s"),
            }
        )
    ratios = []
    if planned_distance and actual_distance:
        ratios.append(float(actual_distance) / float(planned_distance))
    if planned_duration and actual_duration:
        ratios.append(float(actual_duration) / float(planned_duration))
    overall = sum(ratios) / len(ratios) if ratios else None
    return {
        "status": "complete" if overall is not None and 0.9 <= overall <= 1.1 else "partial",
        "algorithm_version": "plan-adherence-v2",
        "completed_distance_m": actual_distance,
        "planned_distance_m": planned_distance,
        "completed_duration_s": actual_duration,
        "planned_duration_s": planned_duration,
        "time_in_target_s": target_adherence["time_in_target_s"],
        "target_time_s": target_adherence["target_time_s"],
        "explanation": plan["completion_state"],
        "steps": step_results,
    }


async def planned_session_adherence(db, *, user: dict, planned_session_id: str) -> dict:
    plan = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
    )
    if not plan["completion_activity_id"]:
        return {"status": "unavailable", "explanation": "No completed activity is linked."}
    return await activity_adherence(
        db, user=user, activity_id=plan["completion_activity_id"]
    )


async def calendar_layer(
    db,
    *,
    user: dict,
    start: date,
    end: date,
    include_completed: bool,
) -> list[dict]:
    plan_rows = await (
        await db.execute(
            "SELECT id, title, sport_key, status, scheduled_start_utc, scheduled_date, "
            "time_window_start_utc, time_window_end_utc, expected_duration_s "
            "FROM health_planned_sessions WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL AND ("
            "scheduled_date BETWEEN ? AND ? OR substr(scheduled_start_utc,1,10) BETWEEN ? AND ? "
            "OR substr(time_window_start_utc,1,10) BETWEEN ? AND ?) "
            "ORDER BY COALESCE(scheduled_start_utc, time_window_start_utc, scheduled_date)",
            (
                user["family_id"], user["id"], start.isoformat(), end.isoformat(),
                start.isoformat(), end.isoformat(), start.isoformat(), end.isoformat(),
            ),
        )
    ).fetchall()
    items = [
        {
            "id": row["id"],
            "owner_user_id": user["id"],
            "layer_kind": "planned",
            "display_title": row["title"],
            "sport_key": row["sport_key"],
            "status": row["status"],
            "scheduled_start_utc": row["scheduled_start_utc"],
            "scheduled_date": row["scheduled_date"],
            "time_window_start_utc": row["time_window_start_utc"],
            "time_window_end_utc": row["time_window_end_utc"],
            "duration_s": row["expected_duration_s"],
            "detail_id": row["id"],
        }
        for row in plan_rows
    ]
    if include_completed:
        activity_rows = await (
            await db.execute(
                "SELECT id, title, sport_key, status, started_at_utc, timer_duration_s "
                "FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
                "AND deleted_at IS NULL AND status = 'completed' "
                "AND COALESCE(local_calendar_date, substr(started_at_utc,1,10)) BETWEEN ? AND ? "
                "ORDER BY started_at_utc",
                (user["family_id"], user["id"], start.isoformat(), end.isoformat()),
            )
        ).fetchall()
        items.extend(
            {
                "id": row["id"],
                "owner_user_id": user["id"],
                "layer_kind": "completed",
                "display_title": row["title"],
                "sport_key": row["sport_key"],
                "status": row["status"],
                "scheduled_start_utc": row["started_at_utc"],
                "scheduled_date": None,
                "time_window_start_utc": None,
                "time_window_end_utc": None,
                "duration_s": row["timer_duration_s"],
                "detail_id": row["id"],
            }
            for row in activity_rows
        )
    return items


async def household_logistics_calendar_projections(
    db,
    *,
    user: dict,
    range_start: datetime,
    range_end: datetime,
):
    """Return only another adult's explicitly shared title/time logistics."""
    from app.models.calendar import CalendarEventResponse

    rows = await (
        await db.execute(
            "SELECT id, owner_user_id, shared_title, scheduled_start_utc, scheduled_date, "
            "time_window_start_utc, time_window_end_utc, expected_duration_s, created_at, "
            "updated_at FROM health_planned_sessions WHERE family_id = ? "
            "AND owner_user_id <> ? AND visibility = 'logistics_shared' "
            "AND status NOT IN ('skipped','cancelled') AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    events = []
    for row in rows:
        all_day = bool(row["scheduled_date"] and not row["scheduled_start_utc"] and not row["time_window_start_utc"])
        start_text = row["scheduled_start_utc"] or row["time_window_start_utc"] or row["scheduled_date"]
        if not start_text:
            continue
        if all_day:
            point = datetime.combine(
                date.fromisoformat(start_text), datetime.min.time(), tzinfo=range_start.tzinfo
            )
            end_text = None
        else:
            point = datetime.fromisoformat(str(start_text).replace("Z", "+00:00"))
            if point.tzinfo is None:
                point = point.replace(tzinfo=timezone.utc)
            point = point.astimezone(range_start.tzinfo or timezone.utc)
            if row["time_window_end_utc"]:
                end_text = row["time_window_end_utc"]
            elif row["expected_duration_s"] and row["scheduled_start_utc"]:
                end_text = (
                    datetime.fromisoformat(row["scheduled_start_utc"].replace("Z", "+00:00"))
                    + timedelta(seconds=int(row["expected_duration_s"]))
                ).isoformat()
            else:
                end_text = None
        if not (range_start <= point < range_end):
            continue
        events.append(
            CalendarEventResponse(
                id=f"fitness-logistics:{row['id']}",
                title=row["shared_title"] or "Training",
                description="Shared training logistics.",
                start_time=start_text,
                end_time=end_text,
                all_day=all_day,
                family_member_ids=[row["owner_user_id"]],
                assigned_to=row["owner_user_id"],
                event_type="fitness_logistics",
                exertion=0,
                source_name="Fitness logistics",
                source_color="#16A34A",
                read_only=True,
                created_at=row["created_at"],
                updated_at=row["updated_at"],
                created_by=row["owner_user_id"],
            )
        )
    return events
