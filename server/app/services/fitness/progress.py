"""Small deterministic progress series shared by the Fitness clients."""

from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping
from typing import Any

from app.models.fitness_progress import (
    FitnessProgressChartsResponse,
    FitnessRunningProgressPoint,
    FitnessRunningProgressSeries,
    FitnessStrengthProgressPoint,
    FitnessStrengthProgressSeries,
    FitnessWeightProgressPoint,
)


RUNNING_TARGETS = (("5k", "5K", 5_000), ("10k", "10K", 10_000))
STRENGTH_TARGETS = (
    ("squat", "Squat"),
    ("chest_press", "Chest press"),
    ("overhead_press", "Overhead press"),
)


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _json_list(value: Any) -> list[dict[str, Any]]:
    try:
        parsed = json.loads(value) if isinstance(value, str) else value
    except (TypeError, ValueError, json.JSONDecodeError):
        return []
    if not isinstance(parsed, list):
        return []
    return [item for item in parsed if isinstance(item, dict)]


async def _weight_points(db, *, user: dict) -> list[FitnessWeightProgressPoint]:
    rows = await (
        await db.execute(
            "SELECT id, measured_at_utc, value FROM health_body_measurements "
            "WHERE family_id = ? AND owner_user_id = ? "
            "AND metric_key = 'body.weight_kg' AND canonical_state = 'canonical' "
            "AND deleted_at IS NULL ORDER BY measured_at_utc DESC LIMIT 24",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    points = []
    for row in reversed(rows):
        value = _number(row["value"])
        if value is None or value <= 0:
            continue
        points.append(
            FitnessWeightProgressPoint(
                measurement_id=row["id"],
                measured_at_utc=row["measured_at_utc"],
                weight_kg=value,
            )
        )
    return points


def _best_effort(records: list[dict[str, Any]], *, key: str) -> float | None:
    candidates = []
    expected = f"best_{key}"
    for record in records:
        if str(record.get("record_key") or "").casefold() != expected:
            continue
        value = _number(record.get("value_s"))
        if value is not None and value > 0:
            candidates.append(value)
    return min(candidates, default=None)


async def _running_series(db, *, user: dict) -> list[FitnessRunningProgressSeries]:
    rows = await (
        await db.execute(
            "SELECT a.id, a.started_at_utc, a.distance_m, a.moving_duration_s, "
            "a.timer_duration_s, a.elapsed_duration_s, f.value_json, f.created_at AS feature_created_at "
            "FROM health_activities a LEFT JOIN health_activity_features f "
            "ON f.activity_id = a.id AND f.family_id = a.family_id "
            "AND f.owner_user_id = a.owner_user_id AND f.feature_key = 'running.records' "
            "AND f.deleted_at IS NULL WHERE a.family_id = ? AND a.owner_user_id = ? "
            "AND a.sport_key = 'running' AND a.status IN ('complete','completed','partial') "
            "AND a.deleted_at IS NULL ORDER BY a.started_at_utc DESC, f.created_at DESC LIMIT 400",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    points: dict[str, list[FitnessRunningProgressPoint]] = {"5k": [], "10k": []}
    seen_activities: set[str] = set()
    for row in rows:
        activity_id = str(row["id"])
        if activity_id in seen_activities:
            continue
        seen_activities.add(activity_id)
        records = _json_list(row["value_json"])
        distance = _number(row["distance_m"])
        duration = next(
            (
                value
                for value in (
                    _number(row["moving_duration_s"]),
                    _number(row["timer_duration_s"]),
                    _number(row["elapsed_duration_s"]),
                )
                if value is not None and value > 0
            ),
            None,
        )
        for key, _label, target_distance in RUNNING_TARGETS:
            exact = _best_effort(records, key=key)
            source = "best_effort"
            value = exact
            if value is None and distance is not None and duration is not None and distance >= target_distance:
                value = duration * target_distance / distance
                source = "average_pace_estimate"
            if value is None or value <= 0:
                continue
            points[key].append(
                FitnessRunningProgressPoint(
                    activity_id=activity_id,
                    started_at_utc=row["started_at_utc"],
                    duration_s=value,
                    source=source,
                )
            )

    return [
        FitnessRunningProgressSeries(
            key=key,
            label=label,
            distance_m=distance,
            points=list(reversed(points[key][:12])),
        )
        for key, label, distance in RUNNING_TARGETS
    ]


def _normalised_name(value: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9]+", " ", value.casefold()).split())


def _strength_category(row: Mapping[str, Any]) -> str | None:
    seed = str(row["seed_key"] or "").casefold()
    name = _normalised_name(str(row["exercise_name"] or ""))
    movement = str(row["movement_pattern_key"] or "").casefold()
    if seed == "overhead_press" or "overhead press" in name or "shoulder press" in name:
        return "overhead_press"
    if movement == "vertical_push" and "press" in name:
        return "overhead_press"
    if seed in {"barbell_bench_press", "dumbbell_bench_press"}:
        return "chest_press"
    if "chest press" in name or "bench press" in name:
        return "chest_press"
    if movement == "horizontal_push" and "press" in name:
        return "chest_press"
    if seed == "barbell_back_squat" or "squat" in name or movement == "squat":
        return "squat"
    return None


def _repetitions(row: Mapping[str, Any]) -> int | None:
    direct = row["reps"]
    if direct is not None and int(direct) > 0:
        return int(direct)
    sides = [int(value) for value in (row["reps_left"], row["reps_right"]) if value is not None and int(value) > 0]
    return min(sides, default=None)


def _component_load(row: Mapping[str, Any]) -> float | None:
    normalised = _number(row["normalized_external_load_kg"])
    if normalised is not None and normalised >= 0:
        return normalised
    if str(row["load_unit"] or "").casefold() == "kg":
        entered = _number(row["load_value"])
        if entered is not None and entered >= 0:
            return entered
    return None


async def _strength_series(db, *, user: dict) -> list[FitnessStrengthProgressSeries]:
    rows = await (
        await db.execute(
            "SELECT a.id AS activity_id, a.started_at_utc, e.id AS exercise_id, "
            "e.seed_key, e.name AS exercise_name, e.movement_pattern_key, "
            "se.exercise_setup_id AS setup_id, se.exercise_setup_name_snapshot AS setup_name, "
            "se.load_entry_mode_snapshot, se.rep_count_mode_snapshot, se.unilateral_mode_snapshot, "
            "g.id AS group_id, s.reps, s.reps_left, s.reps_right, s.load_value, s.load_unit, "
            "s.normalized_external_load_kg FROM health_strength_session_exercises se "
            "JOIN health_activities a ON a.id = se.activity_id AND a.family_id = se.family_id "
            "AND a.owner_user_id = se.owner_user_id "
            "JOIN health_exercises e ON e.id = se.exercise_id AND e.family_id = se.family_id "
            "AND e.owner_user_id = se.owner_user_id "
            "JOIN health_strength_set_groups g ON g.session_exercise_id = se.id "
            "AND g.family_id = se.family_id AND g.owner_user_id = se.owner_user_id "
            "JOIN health_strength_sets s ON s.set_group_id = g.id AND s.family_id = g.family_id "
            "AND s.owner_user_id = g.owner_user_id "
            "WHERE se.family_id = ? AND se.owner_user_id = ? AND se.deleted_at IS NULL "
            "AND a.deleted_at IS NULL AND e.deleted_at IS NULL AND g.deleted_at IS NULL "
            "AND s.deleted_at IS NULL AND a.status IN ('complete','completed','partial') "
            "AND g.training_role = 'working' AND g.status IN ('completed','partial') "
            "AND s.component_status IN ('completed','partial') "
            "ORDER BY a.started_at_utc DESC, g.sequence, s.component_index LIMIT 4000",
            (user["family_id"], user["id"]),
        )
    ).fetchall()

    comparisons: dict[tuple[str, str, str, str, str, str], dict[str, Any]] = {}
    for row in rows:
        category = _strength_category(row)
        load = _component_load(row)
        if category is None or load is None:
            continue
        identity = (
            category,
            str(row["exercise_id"]),
            str(row["setup_id"]),
            str(row["load_entry_mode_snapshot"] or ""),
            str(row["rep_count_mode_snapshot"] or ""),
            str(row["unilateral_mode_snapshot"] or ""),
        )
        comparison = comparisons.setdefault(
            identity,
            {
                "category": category,
                "exercise_id": str(row["exercise_id"]),
                "exercise_name": str(row["exercise_name"]),
                "setup_id": str(row["setup_id"]),
                "setup_name": str(row["setup_name"]),
                "latest_at": str(row["started_at_utc"]),
                "activities": {},
            },
        )
        comparison["latest_at"] = max(comparison["latest_at"], str(row["started_at_utc"]))
        activity = comparison["activities"].setdefault(
            str(row["activity_id"]),
            {
                "performed_at_utc": str(row["started_at_utc"]),
                "groups": {},
            },
        )
        repetitions = _repetitions(row)
        group = activity["groups"].get(str(row["group_id"]))
        candidate = {"load_kg": load, "repetitions": repetitions}
        if group is None or (load, repetitions or 0) > (group["load_kg"], group["repetitions"] or 0):
            activity["groups"][str(row["group_id"])] = candidate

    selected: dict[str, dict[str, Any]] = {}
    for comparison in comparisons.values():
        category = comparison["category"]
        current = selected.get(category)
        if current is None or comparison["latest_at"] > current["latest_at"]:
            selected[category] = comparison

    result: list[FitnessStrengthProgressSeries] = []
    for key, label in STRENGTH_TARGETS:
        comparison = selected.get(key)
        if comparison is None:
            result.append(FitnessStrengthProgressSeries(key=key, label=label))
            continue
        activity_points = []
        for activity_id, activity in comparison["activities"].items():
            groups = list(activity["groups"].values())
            if not groups:
                continue
            top = max(groups, key=lambda item: (item["load_kg"], item["repetitions"] or 0))
            activity_points.append(
                FitnessStrengthProgressPoint(
                    activity_id=activity_id,
                    performed_at_utc=activity["performed_at_utc"],
                    load_kg=top["load_kg"],
                    repetitions=top["repetitions"],
                    working_set_count=len(groups),
                )
            )
        activity_points.sort(key=lambda point: point.performed_at_utc)
        result.append(
            FitnessStrengthProgressSeries(
                key=key,
                label=label,
                exercise_id=comparison["exercise_id"],
                exercise_name=comparison["exercise_name"],
                setup_id=comparison["setup_id"],
                setup_name=comparison["setup_name"],
                points=activity_points[-12:],
            )
        )
    return result


async def progress_charts(db, *, user: dict) -> FitnessProgressChartsResponse:
    return FitnessProgressChartsResponse(
        weight=await _weight_points(db, user=user),
        running=await _running_series(db, user=user),
        strength=await _strength_series(db, user=user),
    )
