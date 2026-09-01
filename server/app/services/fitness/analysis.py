"""Bounded, registered-key unified Fitness analysis."""

from __future__ import annotations

import json
import math
import statistics
from collections import defaultdict
from datetime import date, timedelta
from typing import Any

from app.fitness_registry import SPORTS
from app.models.fitness_analysis import AnalysisFilter, AnalysisQueryPayload, SavedAnalysisChartPayload
from app.services.fitness.common import (
    FitnessConflictError,
    decoded_row,
    insert_owned,
    new_id,
    now_iso,
    owned_row,
    soft_delete_owned,
)

MAX_WINDOW_DAYS = 366
MAX_OUTPUT_POINTS = 200
MAX_FILTERS = 4
HEAVY_POLL_INTERVAL_MS = 1_000

CHART_TYPES = [
    {"key": "line", "label": "Line"},
    {"key": "rolling_average", "label": "Rolling average"},
    {"key": "bar", "label": "Bar"},
    {"key": "stacked_bar", "label": "Stacked bar"},
    {"key": "scatter", "label": "Scatter"},
    {"key": "histogram", "label": "Histogram"},
    {"key": "calendar_heatmap", "label": "Calendar heatmap"},
    {"key": "range_band", "label": "Range band"},
    {"key": "table", "label": "Table"},
]

DIMENSIONS = [
    {"key": "date", "label": "Date", "value_type": "date"},
    {"key": "week", "label": "Week", "value_type": "date"},
    {"key": "month", "label": "Month", "value_type": "date"},
    {"key": "weekday", "label": "Weekday", "value_type": "category"},
    {"key": "phase", "label": "Training phase", "value_type": "category"},
    {"key": "sport", "label": "Sport", "value_type": "category"},
    {"key": "workout_classification", "label": "Workout type", "value_type": "category"},
    {"key": "meal", "label": "Meal", "value_type": "category"},
    {"key": "food", "label": "Food", "value_type": "category"},
    {"key": "exercise", "label": "Canonical exercise", "value_type": "category"},
    {"key": "exercise_setup", "label": "Canonical setup", "value_type": "category"},
    {"key": "muscle_group", "label": "Muscle group", "value_type": "category"},
    {
        "key": "readiness",
        "label": "Contemporaneous readiness",
        "value_type": "category",
        "description": "Only state captured before the session outcome.",
    },
    {"key": "body_location", "label": "Body location", "value_type": "category"},
    {"key": "side", "label": "Side", "value_type": "category"},
    {"key": "session_effect", "label": "Session effect", "value_type": "category"},
    {"key": "gear", "label": "Gear", "value_type": "category"},
    {"key": "measurement_quality", "label": "Measurement quality", "value_type": "category"},
    {"key": "source_quality", "label": "Source quality", "value_type": "category"},
    {"key": "pace_bucket", "label": "Pace bucket", "value_type": "number"},
]

FILTERS = [
    {
        "key": "sport_key",
        "label": "Sport",
        "value_type": "registered_key",
        "operators": ["eq", "not_eq", "in"],
        "values": [
            {"key": sport["key"], "label": sport["display_name"]}
            for sport in SPORTS
        ],
        "max_values": len(SPORTS),
    },
    {
        "key": "workout_classification",
        "label": "Workout type",
        "value_type": "registered_key",
        "operators": ["eq", "not_eq", "in"],
        "values": [
            {"key": key, "label": key.replace("_", " ").title()}
            for key in (
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
            )
        ],
        "max_values": 13,
    },
    {"key": "phase_id", "label": "Training phase", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "max_values": 10},
    {"key": "gear_id", "label": "Gear", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "max_values": 10},
    {"key": "exercise_id", "label": "Exercise", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "max_values": 10},
    {"key": "exercise_setup_id", "label": "Exercise setup", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "max_values": 10},
    {"key": "meal_key", "label": "Meal", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "values": [{"key": key, "label": key.replace("_", " ").title()} for key in ("breakfast", "lunch", "dinner", "snack", "drink", "pre_workout", "during_workout", "post_workout", "other")], "max_values": 9},
    {"key": "weekday", "label": "Weekday", "value_type": "number", "operators": ["eq", "in", "gte", "lte", "between"], "max_values": 7},
    {"key": "readiness", "label": "Readiness", "value_type": "number", "operators": ["eq", "in", "gte", "lte", "between"], "max_values": 5},
    {"key": "body_location", "label": "Body location", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "max_values": 10},
    {"key": "side", "label": "Side", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "values": [{"key": key, "label": key.replace("_", " ").title()} for key in ("left", "right", "bilateral", "midline", "not_applicable", "unknown")], "max_values": 6},
    {"key": "measurement_quality", "label": "Measurement quality", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "max_values": 10},
    {"key": "source_quality", "label": "Source quality", "value_type": "registered_key", "operators": ["eq", "not_eq", "in"], "max_values": 10},
]


def _measure(
    key: str,
    label: str,
    unit: str | None,
    dimensions: list[str],
    *,
    charts: list[str] | None = None,
    filters: list[str] | None = None,
    classification: str = "descriptive",
    minimum: int = 1,
    aggregation: str = "mean",
    heavy: bool = False,
    description: str | None = None,
) -> dict:
    return {
        "key": key,
        "label": label,
        "description": description,
        "unit_key": unit,
        "supported_dimensions": dimensions,
        "chart_types": charts or ["line", "rolling_average", "bar", "calendar_heatmap", "range_band", "table"],
        "allowed_filter_keys": filters or [],
        "comparison_forms": ["previous_period"],
        "default_chart_type": (charts or ["line"])[0],
        "classification": classification,
        "minimum_sample_size": minimum,
        "_aggregation": aggregation,
        "_heavy": heavy,
    }


TIME = ["date", "week", "month"]
ACTIVITY_FILTERS = ["sport_key", "workout_classification", "phase_id", "gear_id", "readiness", "measurement_quality", "source_quality"]
STRENGTH_FILTERS = ["phase_id", "exercise_id", "exercise_setup_id", "readiness", "measurement_quality"]
NUTRITION_FILTERS = ["meal_key", "weekday", "measurement_quality", "phase_id"]
NUTRITION_CHARTS = [
    "line",
    "rolling_average",
    "bar",
    "stacked_bar",
    "calendar_heatmap",
    "range_band",
    "table",
]

MEASURES = [
    _measure("nutrition.calories_kcal", "Calories", "kcal", TIME + ["weekday", "meal", "food", "measurement_quality", "phase"], charts=NUTRITION_CHARTS, filters=NUTRITION_FILTERS, aggregation="sum"),
    _measure("nutrition.protein_g", "Protein", "g", TIME + ["weekday", "meal", "food", "measurement_quality", "phase"], charts=NUTRITION_CHARTS, filters=NUTRITION_FILTERS, aggregation="sum"),
    _measure("nutrition.carbohydrate_g", "Carbohydrate", "g", TIME + ["weekday", "meal", "food", "measurement_quality", "phase"], charts=NUTRITION_CHARTS, filters=NUTRITION_FILTERS, aggregation="sum"),
    _measure("nutrition.fat_g", "Fat", "g", TIME + ["weekday", "meal", "food", "measurement_quality", "phase"], charts=NUTRITION_CHARTS, filters=NUTRITION_FILTERS, aggregation="sum"),
    _measure("nutrition.saturated_fat_g", "Saturated fat", "g", TIME + ["weekday", "meal", "food", "measurement_quality", "phase"], charts=NUTRITION_CHARTS, filters=NUTRITION_FILTERS, aggregation="sum"),
    _measure("nutrition.sugars_g", "Sugar", "g", TIME + ["weekday", "meal", "food", "measurement_quality", "phase"], charts=NUTRITION_CHARTS, filters=NUTRITION_FILTERS, aggregation="sum"),
    _measure("nutrition.fibre_g", "Fibre", "g", TIME + ["weekday", "meal", "food", "measurement_quality", "phase"], charts=NUTRITION_CHARTS, filters=NUTRITION_FILTERS, aggregation="sum"),
    _measure("nutrition.salt_g", "Salt", "g", TIME + ["weekday", "meal", "food", "measurement_quality", "phase"], charts=NUTRITION_CHARTS, filters=NUTRITION_FILTERS, aggregation="sum"),
    _measure("nutrition.adherence_pct", "Calorie target adherence", "%", TIME + ["weekday", "phase"], filters=["weekday", "phase_id"], minimum=3),
    _measure("body.weight_trend_kg", "Body-weight trend", "kg", TIME + ["phase", "source_quality", "measurement_quality"], filters=["phase_id", "measurement_quality", "source_quality"], minimum=2, description="Canonical body-weight readings with a seven-reading trend."),
    _measure("sleep.duration_s", "Sleep duration", "s", TIME + ["source_quality", "phase"], filters=["source_quality", "phase_id"], minimum=2),
    _measure("sleep.regularity_minutes", "Sleep timing regularity", "min", ["week", "month", "phase", "source_quality"], filters=["source_quality", "phase_id"], minimum=3),
    _measure("recovery.resting_heart_rate_bpm", "Resting heart rate", "bpm", TIME + ["source_quality"], filters=["source_quality"], minimum=3),
    _measure("recovery.hrv_sdnn_ms", "HRV (SDNN)", "ms", TIME + ["source_quality"], filters=["source_quality"], minimum=3),
    _measure("recovery.hrv_rmssd_ms", "HRV (RMSSD)", "ms", TIME + ["source_quality"], filters=["source_quality"], minimum=3),
    _measure("running.distance_m", "Running distance", "m", TIME + ["phase", "workout_classification", "gear", "readiness"], filters=ACTIVITY_FILTERS, aggregation="sum"),
    _measure("running.duration_s", "Running duration", "s", TIME + ["phase", "workout_classification", "gear", "readiness"], filters=ACTIVITY_FILTERS, aggregation="sum"),
    _measure("running.comparable_pace", "Comparable running pace", "s_per_km", TIME + ["phase", "workout_classification", "gear", "readiness"], filters=ACTIVITY_FILTERS, minimum=3, classification="correlational", description="Observed pace; filter to genuinely comparable run types, phases or gear."),
    _measure("training.session_rpe", "Session RPE", "rpe", TIME + ["sport", "phase", "workout_classification", "gear", "readiness"], filters=ACTIVITY_FILTERS, minimum=2),
    _measure("plan.adherence_pct", "Plan adherence", "%", TIME + ["sport", "phase", "workout_classification"], filters=["sport_key", "workout_classification", "phase_id"], classification="plan_arithmetic"),
    _measure("strength.observed_load_kg", "Observed strength load", "kg", TIME + ["phase", "exercise", "exercise_setup", "muscle_group", "readiness"], filters=STRENGTH_FILTERS, minimum=2, description="Heaviest performed component in each eligible logical set group."),
    _measure("strength.working_sets", "Logical working sets", "sets", TIME + ["phase", "exercise", "exercise_setup", "muscle_group"], filters=STRENGTH_FILTERS, aggregation="sum"),
    _measure("strength.hard_sets", "Logical hard sets", "sets", TIME + ["phase", "exercise", "exercise_setup", "muscle_group"], filters=STRENGTH_FILTERS, aggregation="sum"),
    _measure("strength.volume_kg", "Observed external-load volume", "kg_reps", TIME + ["phase", "exercise", "exercise_setup", "muscle_group"], filters=STRENGTH_FILTERS, aggregation="sum"),
    _measure("body_issue.severity", "Body-issue severity", "/10", TIME + ["body_location", "side", "session_effect", "exercise", "gear"], filters=["body_location", "side", "exercise_id", "gear_id"], minimum=2),
    _measure("body_issue.changed_sessions", "Issues that changed sessions", "count", TIME + ["body_location", "side", "session_effect", "exercise", "gear"], filters=["body_location", "side", "exercise_id", "gear_id"], aggregation="sum"),
    _measure("gear.distance_m", "Gear distance", "m", TIME + ["gear", "sport", "workout_classification"], filters=["gear_id", "sport_key", "workout_classification"], aggregation="sum"),
    _measure("gear.issue_rate", "Recorded issue rate by gear", "%", ["gear", "sport", "workout_classification"], filters=["gear_id", "sport_key", "workout_classification"], minimum=3, classification="correlational"),
    _measure("relationship.calories_weight", "Calories versus weight trend", "kg", TIME, charts=["scatter", "table"], filters=["measurement_quality"], minimum=4, classification="correlational"),
    _measure("relationship.body_weight_running", "Body weight versus running pace", "s_per_km", TIME + ["phase", "workout_classification", "gear"], charts=["scatter", "table"], filters=ACTIVITY_FILTERS, minimum=4, classification="correlational"),
    _measure("relationship.protein_strength", "Protein versus observed strength", "kg", TIME + ["exercise", "exercise_setup"], charts=["scatter", "table"], filters=STRENGTH_FILTERS, minimum=4, classification="correlational"),
    _measure("relationship.running_load_strength", "Running load versus strength performance", "kg", TIME + ["exercise", "exercise_setup"], charts=["scatter", "table"], filters=STRENGTH_FILTERS, minimum=4, classification="correlational"),
    _measure("relationship.leg_exposure_easy_run", "Leg exposure versus easy-run pace", "s_per_km", TIME + ["gear", "phase"], charts=["scatter", "table"], filters=ACTIVITY_FILTERS, minimum=4, classification="correlational"),
    _measure("relationship.readiness_outcome", "Readiness versus session outcome", "/5", ["readiness", "sport", "workout_classification", "phase"], charts=["scatter", "bar", "table"], filters=ACTIVITY_FILTERS, minimum=3, classification="correlational"),
    _measure("running.stream_pace_distribution", "Recorded pace distribution", "s_per_km", ["pace_bucket"], charts=["histogram", "table"], filters=["workout_classification", "phase_id", "gear_id"], minimum=10, heavy=True, description="Bounded distribution from normalized activity streams; processed by the single worker."),
]

MEASURE_BY_KEY = {item["key"]: item for item in MEASURES}
DIMENSION_KEYS = {item["key"] for item in DIMENSIONS}
FILTER_BY_KEY = {item["key"]: item for item in FILTERS}
COMPARISONS = [{"key": "previous_period", "label": "Previous period", "description": "Compare with the immediately preceding equal-length window."}]

DEFAULT_QUERIES = [
    {"key": "weight-progress", "label": "Weight trend", "description": "Canonical seven-reading body-weight trend.", "dimension_key": "date", "measure_key": "body.weight_trend_kg", "chart_type_key": "rolling_average", "date_window_days": 90, "surface": "both", "category": "body"},
    {"key": "running-progress", "label": "Running progress", "description": "Observed pace grouped by week; narrow filters improve comparability.", "dimension_key": "week", "measure_key": "running.comparable_pace", "chart_type_key": "line", "date_window_days": 84, "filters": [{"key": "sport_key", "operator": "eq", "value": "running"}], "surface": "both", "category": "running"},
    {"key": "weekly-running", "label": "Synthetic public demo record 2", "dimension_key": "week", "measure_key": "running.distance_m", "chart_type_key": "bar", "date_window_days": 84, "surface": "explore", "category": "running"},
    {"key": "strength-progress", "label": "Observed strength", "dimension_key": "week", "measure_key": "strength.observed_load_kg", "chart_type_key": "line", "date_window_days": 84, "surface": "both", "category": "strength"},
    {"key": "nutrition-pattern", "label": "Calories by weekday", "dimension_key": "weekday", "measure_key": "nutrition.calories_kcal", "chart_type_key": "bar", "date_window_days": 28, "surface": "explore", "category": "nutrition"},
    {"key": "sleep-progress", "label": "Sleep duration", "dimension_key": "week", "measure_key": "sleep.duration_s", "chart_type_key": "range_band", "date_window_days": 56, "surface": "progress", "category": "recovery"},
    {"key": "body-issues", "label": "Issues by location", "dimension_key": "body_location", "measure_key": "body_issue.severity", "chart_type_key": "bar", "date_window_days": 90, "surface": "explore", "category": "issues"},
    {"key": "gear-distance", "label": "Gear distance", "dimension_key": "gear", "measure_key": "gear.distance_m", "chart_type_key": "bar", "date_window_days": 180, "surface": "explore", "category": "gear"},
]


def registry() -> dict:
    public_measures = [
        {key: value for key, value in measure.items() if not key.startswith("_")}
        for measure in MEASURES
    ]
    return {
        "dimensions": DIMENSIONS,
        "measures": public_measures,
        "chart_types": CHART_TYPES,
        "filters": FILTERS,
        "comparisons": COMPARISONS,
        "limits": {
            "max_window_days": MAX_WINDOW_DAYS,
            "max_output_points": MAX_OUTPUT_POINTS,
            "max_filters": MAX_FILTERS,
            "heavy_poll_interval_ms": HEAVY_POLL_INTERVAL_MS,
        },
        "default_queries": DEFAULT_QUERIES,
    }


def validate_query(body: AnalysisQueryPayload) -> dict:
    measure = MEASURE_BY_KEY.get(body.measure_key)
    if measure is None:
        raise FitnessConflictError("Analysis measure is not registered")
    if body.dimension_key not in DIMENSION_KEYS or body.dimension_key not in measure["supported_dimensions"]:
        raise FitnessConflictError("Analysis dimension is not registered for this measure")
    if body.chart_type_key not in measure["chart_types"]:
        raise FitnessConflictError("Chart type is not registered for this measure")
    window_days = (body.date_range.end - body.date_range.start).days + 1
    if window_days > MAX_WINDOW_DAYS:
        raise FitnessConflictError("Analysis window exceeds the registered limit")
    if body.max_points > MAX_OUTPUT_POINTS or len(body.filters) > MAX_FILTERS:
        raise FitnessConflictError("Analysis request exceeds a registered limit")
    if body.comparison_key and body.comparison_key not in measure["comparison_forms"]:
        raise FitnessConflictError("Analysis comparison is not registered for this measure")
    for item in body.filters:
        definition = FILTER_BY_KEY.get(item.key)
        if definition is None or item.key not in measure["allowed_filter_keys"]:
            raise FitnessConflictError("Analysis filter is not registered for this measure")
        if item.operator not in definition["operators"]:
            raise FitnessConflictError("Analysis filter operator is not registered")
        values = item.value if isinstance(item.value, list) else [item.value]
        if item.operator in {"in", "between"} and not isinstance(item.value, list):
            raise FitnessConflictError("Analysis filter operator requires a value list")
        if item.operator not in {"in", "between"} and isinstance(item.value, list):
            raise FitnessConflictError("Analysis filter operator requires one value")
        if item.operator == "between" and len(values) != 2:
            raise FitnessConflictError("Analysis between filter requires two values")
        if len(values) > int(definition.get("max_values", 20)):
            raise FitnessConflictError("Analysis filter has too many values")
        allowed = {value["key"] for value in definition.get("values", [])}
        if allowed and any(str(value) not in allowed for value in values):
            raise FitnessConflictError("Analysis filter value is not registered")
        if any(isinstance(value, str) and len(value) > 160 for value in values):
            raise FitnessConflictError("Analysis filter value is too long")
    return measure


def _day(value: str) -> date:
    return date.fromisoformat(value[:10])


def _phase_dimension(phases: list, day: date, explicit_id: str | None = None) -> tuple[str, str]:
    if explicit_id:
        row = next((phase for phase in phases if phase["id"] == explicit_id), None)
        return explicit_id, row["name"] if row else explicit_id
    for phase in phases:
        if phase["starts_on"] <= day.isoformat() and (
            phase["ends_on"] is None or phase["ends_on"] >= day.isoformat()
        ):
            return phase["id"], phase["name"]
    return "unassigned", "Unassigned"


async def _phases(db, *, user: dict) -> list:
    return await (
        await db.execute(
            "SELECT id, name, starts_on, ends_on FROM health_training_phases "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
            "ORDER BY starts_on DESC",
            (user["family_id"], user["id"]),
        )
    ).fetchall()


def _sample(
    *,
    identifier: str,
    day: date,
    value: float | None,
    dimensions: dict[str, tuple[Any, str]],
    filters: dict[str, Any],
    measurement_quality: str | None,
    source_quality: str | None,
    x_value: float | None = None,
) -> dict:
    return {
        "id": identifier,
        "date": day,
        "value": value,
        "x_value": x_value,
        "dimensions": dimensions,
        "filters": filters,
        "measurement_quality": measurement_quality or "not_recorded",
        "source_quality": source_quality or "not_recorded",
    }


async def _nutrition_samples(db, *, user: dict, body: AnalysisQueryPayload, measure: dict) -> list[dict]:
    field = {
        "nutrition.calories_kcal": "calories_kcal",
        "nutrition.protein_g": "protein_g",
        "nutrition.carbohydrate_g": "carbohydrate_g",
        "nutrition.fat_g": "fat_g",
        "nutrition.saturated_fat_g": "saturated_fat_g",
        "nutrition.sugars_g": "sugars_g",
        "nutrition.fibre_g": "fibre_g",
        "nutrition.salt_g": "salt_g",
    }.get(body.measure_key)
    rows = await (
        await db.execute(
            "SELECT l.*, f.id AS food_id, f.name AS food_name, r.id AS recipe_id, "
            "r.name AS recipe_name FROM health_food_log_entries l "
            "LEFT JOIN health_food_versions fv ON fv.id = l.food_version_id "
            "AND fv.family_id = l.family_id AND fv.owner_user_id = l.owner_user_id "
            "LEFT JOIN health_foods f ON f.id = fv.food_id AND f.family_id = l.family_id "
            "AND f.owner_user_id = l.owner_user_id AND f.deleted_at IS NULL "
            "LEFT JOIN health_recipe_versions rv ON rv.id = l.recipe_version_id "
            "AND rv.family_id = l.family_id AND rv.owner_user_id = l.owner_user_id "
            "LEFT JOIN health_recipes r ON r.id = rv.recipe_id AND r.family_id = l.family_id "
            "AND r.owner_user_id = l.owner_user_id AND r.deleted_at IS NULL "
            "WHERE l.family_id = ? AND l.owner_user_id = ? AND l.deleted_at IS NULL "
            "AND l.nutrition_date BETWEEN ? AND ? ORDER BY l.nutrition_date, l.logged_at_utc",
            (user["family_id"], user["id"], body.date_range.start.isoformat(), body.date_range.end.isoformat()),
        )
    ).fetchall()
    phases = await _phases(db, user=user)
    if body.measure_key == "nutrition.adherence_pct":
        daily: dict[str, dict[str, float | bool]] = {}
        for row in rows:
            totals = daily.setdefault(
                row["nutrition_date"], {"calories": 0.0, "missing": False}
            )
            if row["calories_kcal"] is None:
                totals["missing"] = True
            else:
                totals["calories"] = float(totals["calories"]) + float(
                    row["calories_kcal"]
                )
        samples = []
        for day_text, totals in sorted(daily.items()):
            target = await (
                await db.execute(
                    "SELECT * FROM health_nutrition_targets WHERE family_id = ? "
                    "AND owner_user_id = ? AND metric_key = 'nutrition.calories_kcal' "
                    "AND active = 1 AND effective_from <= ? "
                    "AND (effective_until IS NULL OR effective_until >= ?) "
                    "AND deleted_at IS NULL ORDER BY effective_from DESC LIMIT 1",
                    (user["family_id"], user["id"], day_text, day_text),
                )
            ).fetchone()
            target_value = None
            if target:
                target_value = next(
                    (
                        target[key]
                        for key in ("target_value", "target_max", "target_min")
                        if target[key] is not None
                    ),
                    None,
                )
            day_value = date.fromisoformat(day_text)
            phase = _phase_dimension(phases, day_value)
            calories = float(totals["calories"])
            value = None
            if not totals["missing"] and target_value is not None and float(target_value) > 0:
                value = calories / float(target_value) * 100
            samples.append(_sample(identifier=day_text, day=day_value, value=value, dimensions={"phase": phase}, filters={"weekday": day_value.weekday(), "phase_id": phase[0]}, measurement_quality="mixed", source_quality="manual_or_imported"))
        return samples
    samples = []
    for row in rows:
        day_value = date.fromisoformat(row["nutrition_date"])
        food_key = row["food_id"] or row["recipe_id"] or "unknown"
        food_label = row["food_name"] or row["recipe_name"] or "Unknown item"
        phase = _phase_dimension(phases, day_value)
        raw = row[field] if field else None
        samples.append(_sample(identifier=row["id"], day=day_value, value=float(raw) if raw is not None else None, dimensions={"weekday": (day_value.weekday(), day_value.strftime("%A")), "meal": (row["meal_key"], row["meal_key"].replace("_", " ").title()), "food": (food_key, food_label), "measurement_quality": (row["measurement_quality"], row["measurement_quality"].replace("_", " ").title()), "phase": phase}, filters={"meal_key": row["meal_key"], "weekday": day_value.weekday(), "measurement_quality": row["measurement_quality"], "phase_id": phase[0]}, measurement_quality=row["measurement_quality"], source_quality="manual_or_imported"))
    return samples


async def _body_samples(db, *, user: dict, body: AnalysisQueryPayload) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT m.*, s.transport_key, s.origin_provider_key FROM health_body_measurements m "
            "LEFT JOIN health_source_records s ON s.id = m.source_record_id "
            "AND s.family_id = m.family_id AND s.owner_user_id = m.owner_user_id "
            "WHERE m.family_id = ? AND m.owner_user_id = ? AND m.metric_key = 'body.weight_kg' "
            "AND m.canonical_state = 'canonical' AND m.deleted_at IS NULL "
            "AND substr(m.measured_at_utc,1,10) BETWEEN ? AND ? ORDER BY m.measured_at_utc",
            (user["family_id"], user["id"], body.date_range.start.isoformat(), body.date_range.end.isoformat()),
        )
    ).fetchall()
    phases = await _phases(db, user=user)
    samples = []
    trend_values: list[float] = []
    for row in rows:
        day_value = _day(row["measured_at_utc"])
        trend_values.append(float(row["value"]))
        trend = statistics.fmean(trend_values[-7:])
        source_quality = row["transport_key"] or "manual"
        phase = _phase_dimension(phases, day_value)
        samples.append(_sample(identifier=row["id"], day=day_value, value=trend, dimensions={"phase": phase, "source_quality": (source_quality, source_quality.replace("_", " ").title()), "measurement_quality": (row["measurement_quality"], row["measurement_quality"].replace("_", " ").title())}, filters={"phase_id": phase[0], "measurement_quality": row["measurement_quality"], "source_quality": source_quality}, measurement_quality=row["measurement_quality"], source_quality=source_quality))
    return samples


async def _sleep_samples(db, *, user: dict, body: AnalysisQueryPayload) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT s.*, r.transport_key FROM health_sleep_sessions s "
            "LEFT JOIN health_source_records r ON r.id = s.source_record_id "
            "AND r.family_id = s.family_id AND r.owner_user_id = s.owner_user_id "
            "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.deleted_at IS NULL "
            "AND substr(s.sleep_end_utc,1,10) BETWEEN ? AND ? ORDER BY s.sleep_end_utc",
            (user["family_id"], user["id"], body.date_range.start.isoformat(), body.date_range.end.isoformat()),
        )
    ).fetchall()
    phases = await _phases(db, user=user)
    samples = []
    bedtimes: list[float] = []
    for row in rows:
        day_value = _day(row["sleep_end_utc"])
        source_quality = row["source_quality"] or row["transport_key"] or "manual"
        phase = _phase_dimension(phases, day_value)
        if body.measure_key == "sleep.regularity_minutes":
            start = row["sleep_start_utc"][11:16].split(":")
            bedtime = int(start[0]) * 60 + int(start[1])
            bedtime += 1440 if bedtime < 720 else 0
            bedtimes.append(float(bedtime))
            value = statistics.pstdev(bedtimes[-7:]) if len(bedtimes[-7:]) >= 2 else None
        else:
            value = float(row["duration_s"])
        samples.append(_sample(identifier=row["id"], day=day_value, value=value, dimensions={"phase": phase, "source_quality": (source_quality, source_quality.replace("_", " ").title())}, filters={"phase_id": phase[0], "source_quality": source_quality}, measurement_quality="normalized", source_quality=source_quality))
    return samples


async def _recovery_samples(db, *, user: dict, body: AnalysisQueryPayload) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT o.*, s.transport_key FROM health_recovery_observations o "
            "LEFT JOIN health_source_records s ON s.id = o.source_record_id "
            "AND s.family_id = o.family_id AND s.owner_user_id = o.owner_user_id "
            "WHERE o.family_id = ? AND o.owner_user_id = ? AND o.metric_key = ? "
            "AND o.deleted_at IS NULL AND substr(o.observed_at_utc,1,10) BETWEEN ? AND ? "
            "ORDER BY o.observed_at_utc",
            (user["family_id"], user["id"], body.measure_key, body.date_range.start.isoformat(), body.date_range.end.isoformat()),
        )
    ).fetchall()
    samples = []
    for row in rows:
        source_quality = row["source_quality"] or row["transport_key"] or "manual"
        samples.append(_sample(identifier=row["id"], day=_day(row["observed_at_utc"]), value=float(row["value_number"]) if row["value_number"] is not None else None, dimensions={"source_quality": (source_quality, source_quality.replace("_", " ").title())}, filters={"source_quality": source_quality}, measurement_quality=row["source_quality"] or "recorded", source_quality=source_quality))
    return samples


async def _activity_context(db, *, user: dict, start: date, end: date) -> tuple[list, dict, dict]:
    rows = await (
        await db.execute(
            "SELECT a.*, p.name AS phase_name, s.transport_key FROM health_activities a "
            "LEFT JOIN health_training_phases p ON p.id = a.phase_id AND p.family_id = a.family_id "
            "AND p.owner_user_id = a.owner_user_id AND p.deleted_at IS NULL "
            "LEFT JOIN health_source_records s ON s.id = a.primary_source_record_id "
            "AND s.family_id = a.family_id AND s.owner_user_id = a.owner_user_id "
            "WHERE a.family_id = ? AND a.owner_user_id = ? AND a.status = 'completed' "
            "AND a.deleted_at IS NULL AND COALESCE(a.local_calendar_date, substr(a.started_at_utc,1,10)) "
            "BETWEEN ? AND ? ORDER BY a.started_at_utc",
            (user["family_id"], user["id"], start.isoformat(), end.isoformat()),
        )
    ).fetchall()
    gear_rows = await (
        await db.execute(
            "SELECT l.activity_id, g.id, g.name, l.role FROM health_activity_gear_links l "
            "JOIN health_gear_items g ON g.id = l.gear_id AND g.family_id = l.family_id "
            "AND g.owner_user_id = l.owner_user_id AND g.deleted_at IS NULL "
            "WHERE l.family_id = ? AND l.owner_user_id = ? AND l.deleted_at IS NULL "
            "ORDER BY CASE l.role WHEN 'primary' THEN 0 ELSE 1 END, l.created_at",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    gear: dict[str, tuple[str, str]] = {}
    for row in gear_rows:
        gear.setdefault(row["activity_id"], (row["id"], row["name"]))
    checkins = await (
        await db.execute(
            "SELECT activity_id, readiness_1_5 FROM health_session_checkins "
            "WHERE family_id = ? AND owner_user_id = ? AND timing = 'pre' "
            "AND capture_quality = 'contemporaneous' AND captured_before_activity_start = 1 "
            "AND activity_id IS NOT NULL AND deleted_at IS NULL ORDER BY captured_at_utc",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    readiness = {row["activity_id"]: row["readiness_1_5"] for row in checkins}
    return rows, gear, readiness


async def _activity_samples(db, *, user: dict, body: AnalysisQueryPayload) -> list[dict]:
    rows, gear, readiness = await _activity_context(db, user=user, start=body.date_range.start, end=body.date_range.end)
    samples = []
    for row in rows:
        if body.measure_key.startswith("running.") and row["sport_key"] != "running":
            continue
        day_value = date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10])
        selected_gear = gear.get(row["id"], ("unassigned", "Unassigned"))
        readiness_value = readiness.get(row["id"])
        phase = (row["phase_id"] or "unassigned", row["phase_name"] or "Unassigned")
        classification = row["workout_classification"] or "unclassified"
        if body.measure_key == "running.distance_m":
            value = float(row["distance_m"]) if row["distance_m"] is not None else None
        elif body.measure_key == "running.duration_s":
            value = float(row["timer_duration_s"]) if row["timer_duration_s"] is not None else None
        elif body.measure_key == "running.comparable_pace":
            value = (float(row["timer_duration_s"]) * 1000 / float(row["distance_m"]) if row["timer_duration_s"] and row["distance_m"] else None)
        elif body.measure_key == "training.session_rpe":
            value = float(row["session_rpe"]) if row["session_rpe"] is not None else None
        else:
            plan = None
            if row["planned_session_id"]:
                plan = await (
                    await db.execute(
                        "SELECT expected_distance_m, expected_duration_s FROM health_planned_sessions "
                        "WHERE id = ? AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
                        (row["planned_session_id"], user["family_id"], user["id"]),
                    )
                ).fetchone()
            ratios = []
            if plan and plan["expected_distance_m"] and row["distance_m"]:
                ratios.append(float(row["distance_m"]) / float(plan["expected_distance_m"]))
            if plan and plan["expected_duration_s"] and row["timer_duration_s"]:
                ratios.append(float(row["timer_duration_s"]) / float(plan["expected_duration_s"]))
            value = statistics.fmean(ratios) * 100 if ratios else None
        source_quality = row["transport_key"] or "manual"
        samples.append(_sample(identifier=row["id"], day=day_value, value=value, dimensions={"sport": (row["sport_key"], row["sport_key"].replace("_", " ").title()), "phase": phase, "workout_classification": (classification, classification.replace("_", " ").title()), "gear": selected_gear, "readiness": (readiness_value if readiness_value is not None else "missing", f"Readiness {readiness_value}/5" if readiness_value is not None else "Missing readiness")}, filters={"sport_key": row["sport_key"], "workout_classification": classification, "phase_id": phase[0], "gear_id": selected_gear[0], "readiness": readiness_value, "measurement_quality": row["measurement_quality"], "source_quality": source_quality}, measurement_quality=row["measurement_quality"], source_quality=source_quality))
    return samples


async def _strength_samples(db, *, user: dict, body: AnalysisQueryPayload) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT g.id, a.id AS activity_id, g.training_role, g.status, g.failure_state, a.started_at_utc, "
            "a.local_calendar_date, a.phase_id, a.measurement_quality, p.name AS phase_name, "
            "COALESCE(canonical_e.id, e.id) AS exercise_id, "
            "COALESCE(canonical_e.name, e.name) AS exercise_name, "
            "COALESCE(canonical_setup.id, setup.id) AS setup_id, "
            "COALESCE(canonical_setup.name, setup.name) AS setup_name, "
            "MAX(CASE WHEN c.component_status IN ('completed','partial') THEN c.normalized_external_load_kg END) AS max_load, "
            "SUM(CASE WHEN c.component_status IN ('completed','partial') THEN "
            "COALESCE(c.normalized_external_load_kg,0) * COALESCE(c.reps,c.reps_left + c.reps_right,0) ELSE 0 END) AS volume, "
            "MIN(CASE WHEN c.component_status IN ('completed','partial') THEN c.rir END) AS min_rir, "
            "MAX(CASE WHEN c.component_status IN ('completed','partial') THEN c.rpe END) AS max_rpe, "
            "SUM(CASE WHEN c.component_status IN ('completed','partial') AND "
            "(COALESCE(c.reps,c.reps_left + c.reps_right,0) > 0 OR c.duration_s > 0 OR c.distance_m > 0) THEN 1 ELSE 0 END) AS performed_components "
            "FROM health_strength_set_groups g "
            "JOIN health_activities a ON a.id = g.activity_id AND a.family_id = g.family_id "
            "AND a.owner_user_id = g.owner_user_id AND a.deleted_at IS NULL "
            "JOIN health_strength_session_exercises se ON se.id = g.session_exercise_id "
            "AND se.family_id = g.family_id AND se.owner_user_id = g.owner_user_id AND se.deleted_at IS NULL "
            "JOIN health_exercises e ON e.id = se.exercise_id AND e.family_id = g.family_id "
            "AND e.owner_user_id = g.owner_user_id AND e.deleted_at IS NULL "
            "LEFT JOIN health_exercises canonical_e ON canonical_e.id = e.merged_into_exercise_id "
            "AND canonical_e.family_id = g.family_id AND canonical_e.owner_user_id = g.owner_user_id "
            "AND canonical_e.deleted_at IS NULL "
            "JOIN health_exercise_setups setup ON setup.id = se.exercise_setup_id "
            "AND setup.family_id = g.family_id AND setup.owner_user_id = g.owner_user_id "
            "AND setup.deleted_at IS NULL "
            "LEFT JOIN health_exercise_setups canonical_setup "
            "ON canonical_setup.id = setup.merged_into_setup_id "
            "AND canonical_setup.family_id = g.family_id "
            "AND canonical_setup.owner_user_id = g.owner_user_id "
            "AND canonical_setup.deleted_at IS NULL "
            "LEFT JOIN health_strength_sets c ON c.set_group_id = g.id "
            "AND c.family_id = g.family_id AND c.owner_user_id = g.owner_user_id AND c.deleted_at IS NULL "
            "LEFT JOIN health_training_phases p ON p.id = a.phase_id "
            "AND p.family_id = a.family_id AND p.owner_user_id = a.owner_user_id "
            "AND p.deleted_at IS NULL "
            "WHERE g.family_id = ? AND g.owner_user_id = ? AND g.deleted_at IS NULL "
            "AND g.status IN ('completed','partial') AND substr(a.started_at_utc,1,10) BETWEEN ? AND ? "
            "GROUP BY g.id ORDER BY a.started_at_utc, g.sequence",
            (user["family_id"], user["id"], body.date_range.start.isoformat(), body.date_range.end.isoformat()),
        )
    ).fetchall()
    muscle_rows = await (
        await db.execute(
            "SELECT exercise_id, muscle_group_key, role FROM health_exercise_muscle_roles "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
            "ORDER BY CASE role WHEN 'primary' THEN 0 ELSE 1 END, created_at",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    muscles: dict[str, str] = {}
    for muscle in muscle_rows:
        muscles.setdefault(muscle["exercise_id"], muscle["muscle_group_key"])
    _, _, readiness = await _activity_context(db, user=user, start=body.date_range.start, end=body.date_range.end)
    samples = []
    eligible_roles = {"working", "backoff", "test"}
    for row in rows:
        performed = int(row["performed_components"] or 0) > 0
        eligible = performed and row["training_role"] in eligible_roles
        hard = eligible and (row["failure_state"] in {"technical", "muscular"} or (row["min_rir"] is not None and row["min_rir"] <= 3) or (row["max_rpe"] is not None and row["max_rpe"] >= 7))
        if body.measure_key == "strength.observed_load_kg":
            value = float(row["max_load"]) if eligible and row["max_load"] is not None else None
        elif body.measure_key == "strength.working_sets":
            value = 1.0 if eligible else 0.0
        elif body.measure_key == "strength.hard_sets":
            value = 1.0 if hard else 0.0
        else:
            value = float(row["volume"] or 0) if eligible else 0.0
        day_value = date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10])
        phase = (row["phase_id"] or "unassigned", row["phase_name"] or "Unassigned")
        muscle = muscles.get(row["exercise_id"], "unassigned")
        readiness_value = readiness.get(row["activity_id"])
        samples.append(_sample(identifier=row["id"], day=day_value, value=value, dimensions={"phase": phase, "exercise": (row["exercise_id"], row["exercise_name"]), "exercise_setup": (row["setup_id"], row["setup_name"]), "muscle_group": (muscle, muscle.replace("_", " ").title()), "readiness": (readiness_value if readiness_value is not None else "missing", f"Readiness {readiness_value}/5" if readiness_value is not None else "Missing readiness")}, filters={"phase_id": phase[0], "exercise_id": row["exercise_id"], "exercise_setup_id": row["setup_id"], "readiness": readiness_value, "measurement_quality": row["measurement_quality"]}, measurement_quality=row["measurement_quality"], source_quality="recorded_strength"))
    return samples


async def _issue_samples(db, *, user: dict, body: AnalysisQueryPayload) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT i.*, COALESCE(canonical_e.id,e.id) AS exercise_id, "
            "COALESCE(canonical_e.name,e.name) AS exercise_name, "
            "g.id AS gear_id, g.name AS gear_name "
            "FROM health_body_issue_observations i "
            "LEFT JOIN health_strength_session_exercises se ON se.id = i.session_exercise_id "
            "AND se.family_id = i.family_id AND se.owner_user_id = i.owner_user_id "
            "LEFT JOIN health_exercises e ON e.id = se.exercise_id "
            "AND e.family_id = i.family_id AND e.owner_user_id = i.owner_user_id "
            "AND e.deleted_at IS NULL "
            "LEFT JOIN health_exercises canonical_e ON canonical_e.id = e.merged_into_exercise_id "
            "AND canonical_e.family_id = i.family_id "
            "AND canonical_e.owner_user_id = i.owner_user_id "
            "AND canonical_e.deleted_at IS NULL "
            "LEFT JOIN health_activity_gear_links gl ON gl.activity_id = i.activity_id "
            "AND gl.family_id = i.family_id AND gl.owner_user_id = i.owner_user_id "
            "AND gl.role = 'primary' AND gl.deleted_at IS NULL "
            "LEFT JOIN health_gear_items g ON g.id = gl.gear_id "
            "AND g.family_id = i.family_id AND g.owner_user_id = i.owner_user_id "
            "AND g.deleted_at IS NULL "
            "WHERE i.family_id = ? AND i.owner_user_id = ? AND i.deleted_at IS NULL "
            "AND substr(i.observed_at_utc,1,10) BETWEEN ? AND ? ORDER BY i.observed_at_utc",
            (user["family_id"], user["id"], body.date_range.start.isoformat(), body.date_range.end.isoformat()),
        )
    ).fetchall()
    samples = []
    for row in rows:
        effect = row["session_change_key"] if row["changed_session"] else "none"
        value = float(row["severity_0_10"]) if body.measure_key == "body_issue.severity" else float(bool(row["changed_session"]))
        samples.append(_sample(identifier=row["id"], day=_day(row["observed_at_utc"]), value=value, dimensions={"body_location": (row["body_location_key"], row["body_location_key"].replace("_", " ").title()), "side": (row["side"], row["side"].replace("_", " ").title()), "session_effect": (effect, effect.replace("_", " ").title()), "exercise": (row["exercise_id"] or "unassigned", row["exercise_name"] or "Unassigned"), "gear": (row["gear_id"] or "unassigned", row["gear_name"] or "Unassigned")}, filters={"body_location": row["body_location_key"], "side": row["side"], "exercise_id": row["exercise_id"], "gear_id": row["gear_id"]}, measurement_quality="recorded_observation", source_quality="manual"))
    return samples


async def _gear_samples(db, *, user: dict, body: AnalysisQueryPayload) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT a.id, a.local_calendar_date, a.started_at_utc, a.sport_key, "
            "a.workout_classification, a.distance_m, a.measurement_quality, g.id AS gear_id, "
            "g.name AS gear_name, COUNT(DISTINCT i.id) AS issue_count "
            "FROM health_activities a JOIN health_activity_gear_links l ON l.activity_id = a.id "
            "AND l.family_id = a.family_id AND l.owner_user_id = a.owner_user_id "
            "AND l.deleted_at IS NULL JOIN health_gear_items g ON g.id = l.gear_id "
            "AND g.family_id = a.family_id AND g.owner_user_id = a.owner_user_id "
            "AND g.deleted_at IS NULL LEFT JOIN health_body_issue_observations i "
            "ON i.activity_id = a.id AND i.family_id = a.family_id "
            "AND i.owner_user_id = a.owner_user_id AND i.deleted_at IS NULL "
            "WHERE a.family_id = ? AND a.owner_user_id = ? AND a.deleted_at IS NULL "
            "AND COALESCE(a.local_calendar_date,substr(a.started_at_utc,1,10)) BETWEEN ? AND ? "
            "GROUP BY a.id, g.id ORDER BY a.started_at_utc",
            (user["family_id"], user["id"], body.date_range.start.isoformat(), body.date_range.end.isoformat()),
        )
    ).fetchall()
    samples = []
    for row in rows:
        classification = row["workout_classification"] or "unclassified"
        value = (float(row["issue_count"] > 0) * 100 if body.measure_key == "gear.issue_rate" else (float(row["distance_m"]) if row["distance_m"] is not None else None))
        samples.append(_sample(identifier=f"{row['id']}:{row['gear_id']}", day=date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10]), value=value, dimensions={"gear": (row["gear_id"], row["gear_name"]), "sport": (row["sport_key"], row["sport_key"].replace("_", " ").title()), "workout_classification": (classification, classification.replace("_", " ").title())}, filters={"gear_id": row["gear_id"], "sport_key": row["sport_key"], "workout_classification": classification}, measurement_quality=row["measurement_quality"], source_quality="recorded_activity"))
    return samples


async def _relationship_samples(db, *, user: dict, body: AnalysisQueryPayload) -> list[dict]:
    key = body.measure_key
    if key == "relationship.readiness_outcome":
        rows = await (
            await db.execute(
                "SELECT c.id, c.readiness_1_5, a.perceived_performance, a.sport_key, "
                "a.workout_classification, a.phase_id, a.local_calendar_date, a.started_at_utc "
                "FROM health_session_checkins c JOIN health_activities a ON a.id = c.activity_id "
                "AND a.family_id = c.family_id AND a.owner_user_id = c.owner_user_id "
                "WHERE c.family_id = ? AND c.owner_user_id = ? AND c.timing = 'pre' "
                "AND c.capture_quality = 'contemporaneous' AND c.captured_before_activity_start = 1 "
                "AND c.deleted_at IS NULL AND a.deleted_at IS NULL "
                "AND COALESCE(a.local_calendar_date,substr(a.started_at_utc,1,10)) BETWEEN ? AND ?",
                (user["family_id"], user["id"], body.date_range.start.isoformat(), body.date_range.end.isoformat()),
            )
        ).fetchall()
        phases = await _phases(db, user=user)
        return [_sample(identifier=row["id"], day=date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10]), value=float(row["perceived_performance"]) if row["perceived_performance"] is not None else None, x_value=float(row["readiness_1_5"]) if row["readiness_1_5"] is not None else None, dimensions={"readiness": (row["readiness_1_5"] if row["readiness_1_5"] is not None else "missing", f"Readiness {row['readiness_1_5']}/5" if row["readiness_1_5"] is not None else "Missing readiness"), "sport": (row["sport_key"], row["sport_key"].replace("_", " ").title()), "workout_classification": (row["workout_classification"] or "unclassified", (row["workout_classification"] or "unclassified").replace("_", " ").title()), "phase": _phase_dimension(phases, date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10]), row["phase_id"])}, filters={"sport_key": row["sport_key"], "workout_classification": row["workout_classification"] or "unclassified", "phase_id": row["phase_id"], "readiness": row["readiness_1_5"]}, measurement_quality="contemporaneous", source_quality="pre_session_checkin") for row in rows]

    nutrition_rows = await (
        await db.execute(
            "SELECT nutrition_date, SUM(calories_kcal) AS calories, SUM(protein_g) AS protein "
            "FROM health_food_log_entries WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL AND nutrition_date BETWEEN ? AND ? GROUP BY nutrition_date",
            (user["family_id"], user["id"], body.date_range.start.isoformat(), body.date_range.end.isoformat()),
        )
    ).fetchall()
    nutrition = {row["nutrition_date"]: row for row in nutrition_rows}
    if key == "relationship.calories_weight":
        weight_body = body.model_copy(update={"measure_key": "body.weight_trend_kg"})
        weights = await _body_samples(db, user=user, body=weight_body)
        return [_sample(identifier=sample["id"], day=sample["date"], value=sample["value"], x_value=float(nutrition[sample["date"].isoformat()]["calories"]) if sample["date"].isoformat() in nutrition and nutrition[sample["date"].isoformat()]["calories"] is not None else None, dimensions={}, filters={}, measurement_quality=sample["measurement_quality"], source_quality="nutrition_and_weight") for sample in weights]

    activities, gear, _readiness = await _activity_context(db, user=user, start=body.date_range.start, end=body.date_range.end)
    phases = await _phases(db, user=user)
    if key == "relationship.body_weight_running":
        weight_body = body.model_copy(update={"measure_key": "body.weight_trend_kg"})
        weights = await _body_samples(db, user=user, body=weight_body)
        samples = []
        for row in activities:
            if row["sport_key"] != "running":
                continue
            day_value = date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10])
            prior = [sample for sample in weights if sample["date"] <= day_value and (day_value - sample["date"]).days <= 7]
            weight = prior[-1]["value"] if prior else None
            pace = float(row["timer_duration_s"]) * 1000 / float(row["distance_m"]) if row["timer_duration_s"] and row["distance_m"] else None
            selected_gear = gear.get(row["id"], ("unassigned", "Unassigned"))
            samples.append(_sample(identifier=row["id"], day=day_value, value=pace, x_value=weight, dimensions={"phase": _phase_dimension(phases, day_value, row["phase_id"]), "workout_classification": (row["workout_classification"] or "unclassified", (row["workout_classification"] or "unclassified").replace("_", " ").title()), "gear": selected_gear}, filters={"sport_key": "running", "workout_classification": row["workout_classification"] or "unclassified", "phase_id": row["phase_id"], "gear_id": selected_gear[0], "measurement_quality": row["measurement_quality"], "source_quality": row["transport_key"] or "manual"}, measurement_quality=row["measurement_quality"], source_quality="weight_and_activity"))
        return samples

    strength_body = body.model_copy(update={"measure_key": "strength.observed_load_kg"})
    strength = await _strength_samples(db, user=user, body=strength_body)
    running_by_day: dict[date, float] = defaultdict(float)
    for row in activities:
        if row["sport_key"] == "running" and row["distance_m"]:
            running_by_day[date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10])] += float(row["distance_m"])
    if key == "relationship.protein_strength":
        for sample in strength:
            row = nutrition.get(sample["date"].isoformat())
            sample["x_value"] = float(row["protein"]) if row and row["protein"] is not None else None
            sample["source_quality"] = "nutrition_and_strength"
        return strength
    if key == "relationship.running_load_strength":
        for sample in strength:
            sample["x_value"] = sum(running_by_day.get(sample["date"] - timedelta(days=offset), 0) for offset in range(1, 8))
            sample["source_quality"] = "running_and_strength"
        return strength
    # Lower-body logical working-set exposure during the prior three days versus
    # subsequent easy-run pace. Missing exposure remains a measured zero.
    leg_dates: dict[date, float] = defaultdict(float)
    for sample in strength:
        muscle = sample["dimensions"].get("muscle_group", ("", ""))[0]
        if muscle in {"quadriceps", "hamstrings", "glutes", "calves", "adductors"}:
            leg_dates[sample["date"]] += 1
    samples = []
    for row in activities:
        if row["sport_key"] != "running" or (row["workout_classification"] or "") not in {"easy", "recovery"}:
            continue
        day_value = date.fromisoformat(row["local_calendar_date"] or row["started_at_utc"][:10])
        pace = float(row["timer_duration_s"]) * 1000 / float(row["distance_m"]) if row["timer_duration_s"] and row["distance_m"] else None
        selected_gear = gear.get(row["id"], ("unassigned", "Unassigned"))
        samples.append(_sample(identifier=row["id"], day=day_value, value=pace, x_value=sum(leg_dates.get(day_value - timedelta(days=offset), 0) for offset in range(1, 4)), dimensions={"gear": selected_gear, "phase": _phase_dimension(phases, day_value, row["phase_id"])}, filters={"sport_key": "running", "workout_classification": row["workout_classification"], "phase_id": row["phase_id"], "gear_id": selected_gear[0], "measurement_quality": row["measurement_quality"], "source_quality": row["transport_key"] or "manual"}, measurement_quality=row["measurement_quality"], source_quality="strength_and_activity"))
    return samples


async def _load_samples(db, *, user: dict, body: AnalysisQueryPayload, measure: dict) -> list[dict]:
    key = body.measure_key
    if key.startswith("nutrition."):
        samples = await _nutrition_samples(db, user=user, body=body, measure=measure)
    elif key == "body.weight_trend_kg":
        samples = await _body_samples(db, user=user, body=body)
    elif key.startswith("sleep."):
        samples = await _sleep_samples(db, user=user, body=body)
    elif key.startswith("recovery."):
        samples = await _recovery_samples(db, user=user, body=body)
    elif key.startswith("running.") or key in {"training.session_rpe", "plan.adherence_pct"}:
        samples = await _activity_samples(db, user=user, body=body)
    elif key.startswith("strength."):
        samples = await _strength_samples(db, user=user, body=body)
    elif key.startswith("body_issue."):
        samples = await _issue_samples(db, user=user, body=body)
    elif key.startswith("gear."):
        samples = await _gear_samples(db, user=user, body=body)
    else:
        samples = await _relationship_samples(db, user=user, body=body)
    return [sample for sample in samples if _matches_filters(sample, body.filters)]


def _matches_filters(sample: dict, filters: list[AnalysisFilter]) -> bool:
    for item in filters:
        actual = sample["filters"].get(item.key)
        expected = item.value
        values = expected if isinstance(expected, list) else [expected]
        if item.operator == "eq" and actual != expected:
            return False
        if item.operator == "not_eq" and actual == expected:
            return False
        if item.operator == "in" and actual not in values:
            return False
        if item.operator in {"gte", "lte", "between"}:
            if actual is None or isinstance(actual, bool):
                return False
            try:
                numeric = float(actual)
                bounds = [float(value) for value in values]
            except (TypeError, ValueError):
                return False
            if item.operator == "gte" and numeric < bounds[0]:
                return False
            if item.operator == "lte" and numeric > bounds[0]:
                return False
            if item.operator == "between" and not min(bounds) <= numeric <= max(bounds):
                return False
    return True


def _dimension(sample: dict, key: str) -> tuple[str, str, str | float | None]:
    day_value = sample["date"]
    if key == "date":
        return day_value.isoformat(), day_value.isoformat(), day_value.isoformat()
    if key == "week":
        year, week, _ = day_value.isocalendar()
        value = f"{year}-W{week:02d}"
        return value, value, (day_value - timedelta(days=day_value.weekday())).isoformat()
    if key == "month":
        value = day_value.strftime("%Y-%m")
        return value, value, f"{value}-01"
    if key == "weekday":
        return str(day_value.weekday()), day_value.strftime("%A"), float(day_value.weekday())
    value, label = sample["dimensions"].get(key, ("missing", "Missing"))
    return str(value), str(label), float(value) if isinstance(value, (int, float)) else None


def _downsample(points: list[dict], maximum: int) -> list[dict]:
    if len(points) <= maximum:
        return points
    if maximum == 1:
        return [points[-1]]
    indexes = {round(index * (len(points) - 1) / (maximum - 1)) for index in range(maximum)}
    return [point for index, point in enumerate(points) if index in indexes]


def _aggregate(samples: list[dict], body: AnalysisQueryPayload, measure: dict) -> list[dict]:
    if body.chart_type_key == "scatter":
        points = []
        for sample in samples:
            key, label, _ = _dimension(sample, body.dimension_key)
            points.append({"key": sample["id"], "label": label, "x": sample["date"].isoformat(), "x_value": sample["x_value"], "value": sample["value"], "sample_size": 1, "missing_rate": float(sample["x_value"] is None or sample["value"] is None), "quality": sample["measurement_quality"]})
        return _downsample(points, body.max_points)
    present = [float(sample["value"]) for sample in samples if sample["value"] is not None and math.isfinite(float(sample["value"]))]
    if body.chart_type_key == "histogram":
        if not present:
            return []
        low, high = min(present), max(present)
        width = (high - low) / min(10, max(1, int(math.sqrt(len(present))))) if high > low else 1
        buckets: dict[int, list[float]] = defaultdict(list)
        for value in present:
            index = min(int((value - low) / width), 9) if width else 0
            buckets[index].append(value)
        return [{"key": f"bucket-{index}", "label": f"{low + index * width:.1f}–{low + (index + 1) * width:.1f}", "x_value": low + (index + 0.5) * width, "value": float(len(values)), "low": min(values), "high": max(values), "sample_size": len(values), "missing_rate": 0.0, "quality": "recorded"} for index, values in sorted(buckets.items())]
    grouped: dict[str, list[dict]] = defaultdict(list)
    labels: dict[str, tuple[str, str | float | None]] = {}
    for sample in samples:
        key, label, x_value = _dimension(sample, body.dimension_key)
        grouped[key].append(sample)
        labels[key] = (label, x_value)
    points = []
    for key in sorted(grouped):
        rows = grouped[key]
        values = [float(row["value"]) for row in rows if row["value"] is not None]
        missing = len(rows) - len(values)
        if measure["_aggregation"] == "sum":
            value = sum(values) if values else None
        else:
            value = statistics.fmean(values) if values else None
        point = {"key": key, "label": labels[key][0], "x": labels[key][1] if isinstance(labels[key][1], str) else None, "x_value": labels[key][1] if isinstance(labels[key][1], (int, float)) else None, "value": value, "sample_size": len(values), "missing_rate": missing / len(rows) if rows else 0.0, "quality": ", ".join(sorted({row["measurement_quality"] for row in rows}))}
        if body.chart_type_key == "range_band" and values:
            point["low"], point["high"] = min(values), max(values)
        points.append(point)
    if body.chart_type_key == "rolling_average":
        values: list[float] = []
        for point in points:
            if point["value"] is not None:
                values.append(float(point["value"]))
                point["value"] = statistics.fmean(values[-7:])
    return _downsample(points, body.max_points)


def _series(
    samples: list[dict],
    body: AnalysisQueryPayload,
    measure: dict,
    *,
    key_prefix: str,
    label_prefix: str | None = None,
) -> list[dict]:
    if body.chart_type_key != "stacked_bar":
        return [
            {
                "key": key_prefix,
                "label": label_prefix or "Observed",
                "unit_key": measure.get("unit_key"),
                "points": _aggregate(samples, body, measure),
            }
        ]

    # Registered stacked nutrition charts use the finite meal-key vocabulary as
    # their stack. The requested dimension remains the x/category axis.
    grouped: dict[str, tuple[str, list[dict]]] = {}
    for sample in samples:
        stack_key, stack_label = sample["dimensions"].get("meal", ("other", "Other"))
        entry = grouped.setdefault(str(stack_key), (str(stack_label), []))
        entry[1].append(sample)
    bar_body = body.model_copy(update={"chart_type_key": "bar"})
    return [
        {
            "key": f"{key_prefix}:{stack_key}",
            "label": f"{label_prefix} · {label}" if label_prefix else label,
            "unit_key": measure.get("unit_key"),
            "points": _aggregate(rows, bar_body, measure),
        }
        for stack_key, (label, rows) in sorted(grouped.items())
    ]


def _aggregate_scalar(values: list[float], measure: dict) -> float:
    if measure["_aggregation"] == "sum":
        return sum(values)
    return statistics.fmean(values)


def _metadata(body: AnalysisQueryPayload, measure: dict, samples: list[dict]) -> dict:
    missing = sum(sample["value"] is None or (body.chart_type_key == "scatter" and sample["x_value"] is None) for sample in samples)
    return {
        "period": {"start": body.date_range.start.isoformat(), "end": body.date_range.end.isoformat()},
        "sample_size": len(samples) - missing,
        "missing_count": missing,
        "missing_rate": missing / len(samples) if samples else 0.0,
        "source_quality": sorted({sample["source_quality"] for sample in samples}),
        "measurement_quality": sorted({sample["measurement_quality"] for sample in samples}),
        "canonical_policy": "Canonical body readings and canonical exercise/setup identities are used.",
        "duplicate_policy": "Duplicate body readings are excluded; logical strength groups count once.",
        "classification": measure["classification"],
    }


def _empty_result(body: AnalysisQueryPayload, measure: dict, status: str, *, job_id: str | None = None, error: str | None = None) -> dict:
    limitations = []
    if measure["classification"] == "correlational":
        limitations.append("Association only; this result does not show that one factor caused another.")
    limitations.append(error or "No usable owner-scoped observations matched this registered query.")
    return {"status": status, "job_id": job_id, "poll_after_ms": HEAVY_POLL_INTERVAL_MS if status in {"queued", "processing"} else None, "title": measure["label"], "description": measure.get("description"), "dimension_key": body.dimension_key, "measure_key": body.measure_key, "chart_type_key": body.chart_type_key, "unit_key": measure.get("unit_key"), "series": [], "metadata": {"period": {"start": body.date_range.start.isoformat(), "end": body.date_range.end.isoformat()}, "sample_size": 0, "missing_count": 0, "missing_rate": 0.0, "source_quality": [], "measurement_quality": [], "canonical_policy": "Canonical body readings and canonical exercise/setup identities are used.", "duplicate_policy": "Duplicate body readings are excluded; logical strength groups count once.", "classification": measure["classification"]}, "summary": None, "difference": None, "limitations": limitations}


async def execute_query(db, *, user: dict, body: AnalysisQueryPayload) -> dict:
    measure = validate_query(body)
    if measure["_heavy"]:
        raise FitnessConflictError("Heavy analysis must use the queued worker path")
    samples = await _load_samples(db, user=user, body=body, measure=measure)
    metadata = _metadata(body, measure, samples)
    present = metadata["sample_size"]
    if not samples:
        return _empty_result(body, measure, "empty")
    if present < measure["minimum_sample_size"]:
        result = _empty_result(body, measure, "insufficient_sample")
        result["metadata"] = metadata
        result["limitations"].append(f"At least {measure['minimum_sample_size']} usable observations are required.")
        return result
    series = _series(samples, body, measure, key_prefix="observed")
    difference = None
    if body.comparison_key == "previous_period":
        days = (body.date_range.end - body.date_range.start).days + 1
        previous_payload = body.model_dump(mode="json")
        previous_payload["date_range"] = {
            "start": (body.date_range.start - timedelta(days=days)).isoformat(),
            "end": (body.date_range.start - timedelta(days=1)).isoformat(),
        }
        previous_payload["comparison_key"] = None
        previous_body = AnalysisQueryPayload.model_validate(previous_payload)
        previous_samples = await _load_samples(db, user=user, body=previous_body, measure=measure)
        series.extend(
            _series(
                previous_samples,
                previous_body,
                measure,
                key_prefix="comparison",
                label_prefix="Previous period",
            )
        )
        current_values = [float(sample["value"]) for sample in samples if sample["value"] is not None]
        previous_values = [float(sample["value"]) for sample in previous_samples if sample["value"] is not None]
        if current_values and previous_values:
            difference = {"label": "Descriptive difference", "value": _aggregate_scalar(current_values, measure) - _aggregate_scalar(previous_values, measure), "unit_key": measure.get("unit_key")}
    limitations = []
    if measure["classification"] == "correlational":
        limitations.append("Association only; this result does not show that one factor caused another.")
    if metadata["missing_count"]:
        limitations.append("Missing observations are reported and were not imputed.")
    if present < 10:
        limitations.append("The owner-specific sample is small; treat the pattern as descriptive.")
    return {"status": "complete", "title": f"{measure['label']} by {body.dimension_key.replace('_', ' ')}", "description": measure.get("description"), "dimension_key": body.dimension_key, "measure_key": body.measure_key, "chart_type_key": body.chart_type_key, "unit_key": measure.get("unit_key"), "series": series, "metadata": metadata, "summary": f"{present} owner-scoped observations contributed to this {measure['classification']} view.", "difference": difference, "limitations": limitations}


async def submit_query(db, *, user: dict, body: AnalysisQueryPayload) -> dict:
    measure = validate_query(body)
    if not measure["_heavy"]:
        return await execute_query(db, user=user, body=body)
    job_id = new_id()
    await insert_owned(db, table="health_jobs", record_id=job_id, values={"job_type": "analysis_query", "status": "queued", "payload_json": {"query": body.model_dump(mode="json")}, "attempt_count": 0, "available_at": now_iso(), "revision": 1}, user=user, record_sync_change=False)
    await db.commit()
    return _empty_result(body, measure, "queued", job_id=job_id)


async def analysis_job(db, *, user: dict, job_id: str) -> dict:
    row = await owned_row(db, table="health_jobs", record_id=job_id, user=user)
    if row["job_type"] != "analysis_query":
        raise FitnessConflictError("This job is not an analysis query")
    payload = json.loads(row["payload_json"] or "{}")
    body = AnalysisQueryPayload.model_validate(payload["query"])
    measure = validate_query(body)
    if row["status"] == "complete" and row["result_json"]:
        return json.loads(row["result_json"])
    if row["status"] == "failed":
        return _empty_result(body, measure, "error", job_id=job_id, error=row["last_error"] or "The bounded analysis job failed.")
    return _empty_result(body, measure, "processing" if row["status"] == "running" else "queued", job_id=job_id)


def complete_heavy_query(
    body: AnalysisQueryPayload,
    *,
    points: list[dict],
    source_count: int,
    sample_count: int,
    missing_count: int,
) -> dict:
    """Build the canonical envelope from a validated worker histogram manifest."""
    measure = validate_query(body)
    if not measure["_heavy"]:
        raise FitnessConflictError("Analysis job result is not a heavy registered measure")
    metadata = {
        "period": {
            "start": body.date_range.start.isoformat(),
            "end": body.date_range.end.isoformat(),
        },
        "sample_size": sample_count,
        "missing_count": missing_count,
        "missing_rate": (
            missing_count / (sample_count + missing_count)
            if sample_count + missing_count
            else 0.0
        ),
        "source_quality": ["normalized activity streams"] if source_count else [],
        "measurement_quality": ["recorded stream samples"] if sample_count else [],
        "canonical_policy": "Canonical activities and their primary normalized streams are used.",
        "duplicate_policy": "Duplicate activities and superseded stream assets are excluded.",
        "classification": measure["classification"],
    }
    if sample_count == 0:
        result = _empty_result(body, measure, "empty")
        result["metadata"] = metadata
        return result
    if sample_count < measure["minimum_sample_size"]:
        result = _empty_result(body, measure, "insufficient_sample")
        result["metadata"] = metadata
        result["limitations"].append(
            f"At least {measure['minimum_sample_size']} stream samples are required."
        )
        return result
    return {
        "status": "complete",
        "title": measure["label"],
        "description": measure.get("description"),
        "dimension_key": body.dimension_key,
        "measure_key": body.measure_key,
        "chart_type_key": body.chart_type_key,
        "unit_key": measure.get("unit_key"),
        "series": [
            {
                "key": "observed",
                "label": "Observed stream samples",
                "unit_key": measure.get("unit_key"),
                "points": _downsample(points, body.max_points),
            }
        ],
        "metadata": metadata,
        "summary": (
            f"{sample_count} bounded stream samples from {source_count} activities "
            "contributed to this descriptive distribution."
        ),
        "difference": None,
        "limitations": [
            "This distribution is downsampled and does not replace the synchronized activity trace."
        ],
    }


def validate_saved_chart(body: SavedAnalysisChartPayload) -> dict:
    measure = MEASURE_BY_KEY.get(body.measure_key)
    if measure is None or body.dimension_key not in measure["supported_dimensions"] or body.chart_type_key not in measure["chart_types"]:
        raise FitnessConflictError("Saved chart uses an unregistered analysis key")
    if body.comparison_key and body.comparison_key not in measure["comparison_forms"]:
        raise FitnessConflictError("Saved chart comparison is not registered")
    if any(key not in measure["allowed_filter_keys"] or key not in FILTER_BY_KEY for key in body.filter_keys):
        raise FitnessConflictError("Saved chart filter is not registered")
    return measure


def _saved_response(row) -> dict:
    data = decoded_row(row, json_fields={"filter_keys_json"})
    return {
        key: data[key]
        for key in (
            "id",
            "name",
            "measure_key",
            "dimension_key",
            "chart_type_key",
            "filter_keys",
            "comparison_key",
            "date_window_days",
            "revision",
            "created_at",
            "updated_at",
        )
    }


async def list_saved_charts(db, *, user: dict) -> list[dict]:
    rows = await (await db.execute("SELECT * FROM health_saved_analysis_charts WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL ORDER BY updated_at DESC", (user["family_id"], user["id"]))).fetchall()
    return [_saved_response(row) for row in rows]


async def save_chart(
    db,
    *,
    user: dict,
    body: SavedAnalysisChartPayload,
    commit: bool = True,
) -> dict:
    validate_saved_chart(body)
    identifier = new_id(body.id)
    await insert_owned(db, table="health_saved_analysis_charts", record_id=identifier, values={"name": body.name, "measure_key": body.measure_key, "dimension_key": body.dimension_key, "chart_type_key": body.chart_type_key, "filter_keys_json": body.filter_keys, "comparison_key": body.comparison_key, "date_window_days": body.date_window_days, "revision": 1}, user=user, record_sync_change=False)
    if commit:
        await db.commit()
    return _saved_response(await owned_row(db, table="health_saved_analysis_charts", record_id=identifier, user=user))


async def delete_saved_chart(db, *, user: dict, chart_id: str) -> None:
    await soft_delete_owned(db, table="health_saved_analysis_charts", record_id=chart_id, user=user, record_sync_change=False)
    await db.commit()
