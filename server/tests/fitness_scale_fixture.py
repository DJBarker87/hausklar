"""Deterministic Stage 17 Fitness scale fixture for production read-path audits."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from uuid import NAMESPACE_URL, uuid5


FIT_ACTIVITY_COUNT = 140
LONG_STREAM_COUNT = 14
STRENGTH_SESSION_COUNT = 120
FOOD_COUNT = 30
FOOD_LOG_COUNT = 600
HISTORY_DAY_COUNT = 1_096
HISTORICAL_PLAN_COUNT = FIT_ACTIVITY_COUNT + STRENGTH_SESSION_COUNT
FUTURE_PLAN_COUNT = 20
PLANNED_SESSION_COUNT = HISTORICAL_PLAN_COUNT + FUTURE_PLAN_COUNT + 1
EXERCISE_COUNT = 6
STRENGTH_EXERCISES_PER_SESSION = 2
STRENGTH_SETS_PER_EXERCISE = 3


@dataclass(frozen=True)
class FitnessScaleFixture:
    reference_day: date
    current_plan_id: str
    latest_fit_activity_id: str
    running_goal_id: str
    fit_activity_ids: tuple[str, ...]
    strength_activity_ids: tuple[str, ...]


def _id(kind: str, index: int = 0) -> str:
    return str(uuid5(NAMESPACE_URL, f"hausklar-fitness-scale:{kind}:{index}"))


def _at(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=timezone.utc)


def _iso(value: datetime) -> str:
    return value.isoformat()


def _route_preview(index: int) -> str:
    latitude = 51.492 + (index % 7) * 0.0001
    longitude = -0.609 + (index % 5) * 0.0001
    return json.dumps(
        [
            {"lat": latitude, "lon": longitude},
            {"lat": latitude + 0.004, "lon": longitude + 0.006},
            {"lat": latitude + 0.008, "lon": longitude + 0.002},
        ],
        separators=(",", ":"),
    )


async def seed_representative_fitness_scale(
    db,
    *,
    user: dict,
    reference_day: date,
) -> FitnessScaleFixture:
    """Insert a realistic, owner-scoped history without service-side model calls."""
    owner_id = user["id"]
    family_id = user["family_id"]
    fixture_now = _iso(_at(reference_day, 12))
    oldest_day = reference_day - timedelta(days=HISTORY_DAY_COUNT - 1)

    await db.execute(
        "INSERT INTO health_user_settings "
        "(id, owner_user_id, timezone, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, 'Europe/London', ?, ?, ?, ?)",
        (_id("settings"), owner_id, family_id, fixture_now, fixture_now, owner_id),
    )

    goals = (
        (
            _id("goal", 0),
            "performance",
            "running.distance_m",
            "Run 20 km each week",
            0.0,
            20_000.0,
            "m",
            10,
            "active",
        ),
        (
            _id("goal", 1),
            "performance",
            "strength.sessions_per_week",
            "Strength twice each week",
            0.0,
            2.0,
            "sessions",
            8,
            "active",
        ),
        (
            _id("goal", 2),
            "body_composition",
            "body.weight_kg",
            "Reach a comfortable weight",
            82.0,
            76.0,
            "kg",
            5,
            "active",
        ),
        (
            _id("goal", 3),
            "habit",
            "activity.active_days_per_week",
            "Build a regular habit",
            0.0,
            4.0,
            "days",
            1,
            "completed",
        ),
    )
    await db.executemany(
        "INSERT INTO health_goals "
        "(id, owner_user_id, goal_type, metric_key, name, baseline_value, target_value, "
        "unit_key, starts_on, target_date, priority, status, completed_at, family_id, "
        "created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
            (
                identifier,
                owner_id,
                goal_type,
                metric_key,
                name,
                baseline,
                target,
                unit,
                oldest_day.isoformat(),
                (reference_day + timedelta(days=180)).isoformat(),
                priority,
                status,
                fixture_now if status == "completed" else None,
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            )
            for (
                identifier,
                goal_type,
                metric_key,
                name,
                baseline,
                target,
                unit,
                priority,
                status,
            ) in goals
        ],
    )

    phase_rows = []
    for index in range(6):
        starts_on = oldest_day + timedelta(days=index * 183)
        ends_on = None if index == 5 else starts_on + timedelta(days=182)
        phase_rows.append(
            (
                _id("phase", index),
                owner_id,
                "base" if index % 2 == 0 else "build",
                f"Scale training phase {index + 1}",
                starts_on.isoformat(),
                ends_on.isoformat() if ends_on else None,
                json.dumps(["consistent running", "recover well"]),
                json.dumps(["full body", "gradual progression"]),
                json.dumps(["family time stays protected"]),
                1 if index == 5 else 0,
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            )
        )
    await db.executemany(
        "INSERT INTO health_training_phases "
        "(id, owner_user_id, phase_type, name, starts_on, ends_on, "
        "running_priorities_json, strength_priorities_json, accepted_tradeoffs_json, "
        "active, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        phase_rows,
    )

    food_rows = []
    food_version_rows = []
    for index in range(FOOD_COUNT):
        food_rows.append(
            (
                _id("food", index),
                owner_id,
                f"Scale food {index + 1:02d}",
                "Fixture kitchen",
                "staple",
                1 if index < 8 else 0,
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            )
        )
        food_version_rows.append(
            (
                _id("food-version", index),
                owner_id,
                _id("food", index),
                oldest_day.isoformat(),
                100.0,
                90.0 + index * 7,
                3.0 + index % 9,
                10.0 + index % 15,
                2.0 + index % 6,
                1.5 + index % 5,
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            )
        )
    await db.executemany(
        "INSERT INTO health_foods "
        "(id, owner_user_id, name, brand, category_key, favourite, family_id, "
        "created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        food_rows,
    )
    await db.executemany(
        "INSERT INTO health_food_versions "
        "(id, owner_user_id, food_id, version_number, effective_from, reference_amount, "
        "reference_unit, calories_kcal, protein_g, carbohydrate_g, fat_g, fibre_g, "
        "family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, 1, ?, ?, 'g', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        food_version_rows,
    )

    food_log_rows = []
    meal_keys = ("breakfast", "lunch", "dinner")
    meal_hours = (7, 12, 18)
    for index in range(FOOD_LOG_COUNT):
        food_index = index % FOOD_COUNT
        diary_day = reference_day - timedelta(days=index // 3)
        logged_at = _at(diary_day, meal_hours[index % 3], (index * 7) % 60)
        calories = 90.0 + food_index * 7
        protein = 3.0 + food_index % 9
        carbohydrate = 10.0 + food_index % 15
        fat = 2.0 + food_index % 6
        fibre = 1.5 + food_index % 5
        food_log_rows.append(
            (
                _id("food-log", index),
                owner_id,
                _id("food-version", food_index),
                _iso(logged_at),
                diary_day.isoformat(),
                meal_keys[index % 3],
                100.0,
                100.0,
                calories,
                protein,
                carbohydrate,
                fat,
                fibre,
                family_id,
                _iso(logged_at),
                _iso(logged_at),
                owner_id,
            )
        )
    await db.executemany(
        "INSERT INTO health_food_log_entries "
        "(id, owner_user_id, food_version_id, logged_at_utc, local_timezone, "
        "nutrition_date, meal_key, entered_amount, entered_unit, canonical_amount, "
        "canonical_unit, measurement_quality, calories_kcal, protein_g, carbohydrate_g, "
        "fat_g, fibre_g, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, 'Europe/London', ?, ?, ?, 'g', ?, 'g', 'measured', "
        "?, ?, ?, ?, ?, ?, ?, ?, ?)",
        food_log_rows,
    )
    await db.executemany(
        "INSERT INTO health_nutrition_targets "
        "(id, owner_user_id, metric_key, target_type, target_value, target_min, "
        "effective_from, active, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)",
        [
            (
                _id("nutrition-target", 0),
                owner_id,
                "nutrition.calories_kcal",
                "fixed",
                2_300.0,
                None,
                oldest_day.isoformat(),
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            ),
            (
                _id("nutrition-target", 1),
                owner_id,
                "nutrition.protein_g",
                "range",
                None,
                130.0,
                oldest_day.isoformat(),
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            ),
        ],
    )

    measurement_rows = []
    sleep_rows = []
    recovery_rows = []
    for index in range(HISTORY_DAY_COUNT):
        observed_day = oldest_day + timedelta(days=index)
        weight = 82.0 - index * 0.004 + (index % 14) * 0.015
        wake = _at(observed_day, 6, 30 + index % 10)
        duration_minutes = 460 + (index % 9) * 5
        sleep_start = wake - timedelta(minutes=duration_minutes)
        measurement_rows.append(
            (
                _id("weight", index),
                owner_id,
                _iso(_at(observed_day, 7)),
                round(weight, 3),
                family_id,
                _iso(_at(observed_day, 7)),
                _iso(_at(observed_day, 7)),
                owner_id,
            )
        )
        sleep_rows.append(
            (
                _id("sleep", index),
                owner_id,
                _iso(sleep_start),
                _iso(wake),
                float(duration_minutes * 60),
                "measured",
                family_id,
                _iso(wake),
                _iso(wake),
                owner_id,
            )
        )
        recovery_rows.append(
            (
                _id("recovery", index),
                owner_id,
                _iso(_at(observed_day, 6, 45)),
                float(52 + index % 8),
                family_id,
                _iso(_at(observed_day, 6, 45)),
                _iso(_at(observed_day, 6, 45)),
                owner_id,
            )
        )
    await db.executemany(
        "INSERT INTO health_body_measurements "
        "(id, owner_user_id, metric_key, measured_at_utc, local_timezone, value, "
        "unit_key, measurement_quality, canonical_state, family_id, created_at, "
        "updated_at, created_by) VALUES (?, ?, 'body.weight_kg', ?, 'Europe/London', "
        "?, 'kg', 'measured', 'canonical', ?, ?, ?, ?)",
        measurement_rows,
    )
    await db.executemany(
        "INSERT INTO health_sleep_sessions "
        "(id, owner_user_id, sleep_start_utc, sleep_end_utc, duration_s, source_quality, "
        "family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        sleep_rows,
    )
    await db.executemany(
        "INSERT INTO health_recovery_observations "
        "(id, owner_user_id, metric_key, observed_at_utc, value_number, unit_key, "
        "source_quality, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, 'recovery.resting_heart_rate_bpm', ?, ?, 'bpm', 'measured', "
        "?, ?, ?, ?)",
        recovery_rows,
    )

    exercise_specs = (
        ("Back Squat", "squat", "quadriceps", "primary"),
        ("Deadlift", "hinge", "hamstrings", "primary"),
        ("Bench Press", "horizontal_push", "chest", "primary"),
        ("Barbell Row", "horizontal_pull", "upper_back", "primary"),
        ("Overhead Press", "vertical_push", "front_delts", "primary"),
        ("Pull-up", "vertical_pull", "lats", "primary"),
    )
    await db.executemany(
        "INSERT INTO health_exercises "
        "(id, owner_user_id, seed_key, name, movement_pattern_key, equipment_type, "
        "favourite, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, 'barbell', ?, ?, ?, ?, ?)",
        [
            (
                _id("exercise", index),
                owner_id,
                f"scale_{index}",
                name,
                movement,
                1 if index < 3 else 0,
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            )
            for index, (name, movement, _muscle, _role) in enumerate(exercise_specs)
        ],
    )
    await db.executemany(
        "INSERT INTO health_exercise_setups "
        "(id, owner_user_id, exercise_id, name, location, equipment_identifier, "
        "load_entry_mode, rep_count_mode, unilateral_mode, is_default, family_id, "
        "created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, 'Home setup', 'Home gym', 'scale-rack', 'total_external', "
        "'total', 'bilateral', 1, ?, ?, ?, ?)",
        [
            (
                _id("setup", index),
                owner_id,
                _id("exercise", index),
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            )
            for index in range(EXERCISE_COUNT)
        ],
    )
    await db.executemany(
        "INSERT INTO health_exercise_muscle_roles "
        "(id, owner_user_id, exercise_id, muscle_group_key, role, contribution_weight, "
        "family_id, created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, 1.0, ?, ?, ?, ?)",
        [
            (
                _id("muscle-role", index),
                owner_id,
                _id("exercise", index),
                muscle,
                role,
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            )
            for index, (_name, _movement, muscle, role) in enumerate(exercise_specs)
        ],
    )

    gear_rows = [
        (
            _id("gear", 0),
            owner_id,
            "shoes",
            "Scale daily trainers",
            "running",
            family_id,
            fixture_now,
            fixture_now,
            owner_id,
        ),
        (
            _id("gear", 1),
            owner_id,
            "bike",
            "Scale road bike",
            "cycling",
            family_id,
            fixture_now,
            fixture_now,
            owner_id,
        ),
    ]
    await db.executemany(
        "INSERT INTO health_gear_items "
        "(id, owner_user_id, gear_type_key, name, default_for_sport_key, family_id, "
        "created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        gear_rows,
    )

    fit_activity_ids = tuple(_id("fit-activity", index) for index in range(FIT_ACTIVITY_COUNT))
    strength_activity_ids = tuple(
        _id("strength-activity", index) for index in range(STRENGTH_SESSION_COUNT)
    )
    plan_rows = []
    activity_rows = []
    checkin_rows = []
    goal_link_rows = []
    plan_activity_rows = []

    for index, activity_id in enumerate(fit_activity_ids):
        activity_day = reference_day - timedelta(days=index * 2)
        started_at = _at(activity_day, 6, index % 45)
        duration_s = 2_400 + (index % 12) * 120
        ended_at = started_at + timedelta(seconds=duration_s)
        distance_m = 5_000.0 + (index % 20) * 350.0
        plan_id = _id("historical-plan", index)
        plan_rows.append(
            (
                plan_id,
                owner_id,
                "cycling" if index % 5 == 4 else "running",
                f"Imported endurance session {index + 1:03d}",
                "completed",
                "imported",
                _iso(started_at),
                activity_day.isoformat(),
                duration_s,
                distance_m,
                activity_id,
                "completed",
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        source_id = _id("fit-source", index)
        stream_id = _id("fit-stream", index)
        activity_rows.append(
            (
                activity_id,
                owner_id,
                "cycling" if index % 5 == 4 else "running",
                f"Morning {'ride' if index % 5 == 4 else 'run'} {index + 1:03d}",
                "completed",
                plan_id,
                source_id,
                stream_id,
                _iso(started_at),
                _iso(ended_at),
                activity_day.isoformat(),
                duration_s,
                distance_m,
                300.0 + index % 200,
                "complete",
                "fitparse-scale-v1",
                "easy" if index % 4 else "tempo",
                _route_preview(index),
                float(4 + index % 6),
                3 + index % 3,
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        checkin_at = started_at - timedelta(minutes=20)
        checkin_rows.append(
            (
                _id("checkin-fit", index),
                owner_id,
                plan_id,
                activity_id,
                _iso(checkin_at),
                1 + index % 5,
                2 + index % 4,
                1 + index % 4,
                2 + index % 4,
                family_id,
                _iso(checkin_at),
                _iso(checkin_at),
                owner_id,
            )
        )
        goal_link_rows.append(
            (
                _id("activity-goal-fit", index),
                owner_id,
                activity_id,
                _id("goal", 0),
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        plan_activity_rows.append(
            (
                _id("plan-activity-fit", index),
                owner_id,
                plan_id,
                activity_id,
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )

    strength_exercise_rows = []
    strength_group_rows = []
    strength_set_rows = []
    for index, activity_id in enumerate(strength_activity_ids):
        activity_day = reference_day - timedelta(days=index * 3)
        started_at = _at(activity_day, 17, index % 30)
        duration_s = 3_300 + (index % 8) * 120
        ended_at = started_at + timedelta(seconds=duration_s)
        plan_index = FIT_ACTIVITY_COUNT + index
        plan_id = _id("historical-plan", plan_index)
        plan_rows.append(
            (
                plan_id,
                owner_id,
                "strength",
                f"Strength session {index + 1:03d}",
                "completed",
                "user",
                _iso(started_at),
                activity_day.isoformat(),
                duration_s,
                None,
                activity_id,
                "completed",
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        activity_rows.append(
            (
                activity_id,
                owner_id,
                "strength",
                f"Full body strength {index + 1:03d}",
                "completed",
                plan_id,
                None,
                None,
                _iso(started_at),
                _iso(ended_at),
                activity_day.isoformat(),
                duration_s,
                None,
                240.0 + index % 80,
                "not_imported",
                None,
                None,
                "[]",
                float(5 + index % 5),
                3 + index % 3,
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        checkin_at = started_at - timedelta(minutes=15)
        checkin_rows.append(
            (
                _id("checkin-strength", index),
                owner_id,
                plan_id,
                activity_id,
                _iso(checkin_at),
                1 + index % 5,
                2 + index % 4,
                1 + index % 4,
                2 + index % 4,
                family_id,
                _iso(checkin_at),
                _iso(checkin_at),
                owner_id,
            )
        )
        goal_link_rows.append(
            (
                _id("activity-goal-strength", index),
                owner_id,
                activity_id,
                _id("goal", 1),
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        plan_activity_rows.append(
            (
                _id("plan-activity-strength", index),
                owner_id,
                plan_id,
                activity_id,
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        for exercise_sequence in range(STRENGTH_EXERCISES_PER_SESSION):
            exercise_index = (index + exercise_sequence) % EXERCISE_COUNT
            session_exercise_id = _id(
                "session-exercise",
                index * STRENGTH_EXERCISES_PER_SESSION + exercise_sequence,
            )
            strength_exercise_rows.append(
                (
                    session_exercise_id,
                    owner_id,
                    activity_id,
                    _id("exercise", exercise_index),
                    _id("setup", exercise_index),
                    f"{exercise_specs[exercise_index][0]} — Home setup",
                    exercise_sequence,
                    family_id,
                    _iso(started_at),
                    _iso(ended_at),
                    owner_id,
                )
            )
            for set_sequence in range(STRENGTH_SETS_PER_EXERCISE):
                flattened = (
                    index
                    * STRENGTH_EXERCISES_PER_SESSION
                    * STRENGTH_SETS_PER_EXERCISE
                    + exercise_sequence * STRENGTH_SETS_PER_EXERCISE
                    + set_sequence
                )
                group_id = _id("strength-group", flattened)
                completed_at = ended_at - timedelta(minutes=20 - set_sequence * 5)
                strength_group_rows.append(
                    (
                        group_id,
                        owner_id,
                        activity_id,
                        session_exercise_id,
                        set_sequence,
                        _iso(completed_at - timedelta(minutes=2)),
                        _iso(completed_at),
                        family_id,
                        _iso(started_at),
                        _iso(ended_at),
                        owner_id,
                    )
                )
                load = 40.0 + exercise_index * 10 + (index % 12) * 1.25
                strength_set_rows.append(
                    (
                        _id("strength-set", flattened),
                        owner_id,
                        group_id,
                        8 + (set_sequence % 3),
                        load,
                        load,
                        7.0 + set_sequence * 0.5,
                        3.0 - set_sequence * 0.5,
                        _iso(completed_at),
                        family_id,
                        _iso(started_at),
                        _iso(ended_at),
                        owner_id,
                    )
                )

    current_plan_id = _id("current-plan")
    plan_rows.append(
        (
            current_plan_id,
            owner_id,
            "running",
            "Today's easy run",
            "accepted",
            "user",
            _iso(_at(reference_day, 18)),
            reference_day.isoformat(),
            2_700,
            5_000.0,
            None,
            None,
            family_id,
            fixture_now,
            fixture_now,
            owner_id,
        )
    )
    for index in range(FUTURE_PLAN_COUNT):
        planned_day = reference_day + timedelta(days=index + 1)
        plan_rows.append(
            (
                _id("future-plan", index),
                owner_id,
                "strength" if index % 3 == 0 else "running",
                f"Future session {index + 1:02d}",
                "scheduled",
                "user",
                _iso(_at(planned_day, 7 + index % 4)),
                planned_day.isoformat(),
                2_700 + (index % 3) * 600,
                None if index % 3 == 0 else 5_000.0 + index * 100,
                None,
                None,
                family_id,
                fixture_now,
                fixture_now,
                owner_id,
            )
        )

    await db.executemany(
        "INSERT INTO health_planned_sessions "
        "(id, owner_user_id, sport_key, title, status, session_source, "
        "scheduled_start_utc, scheduled_date, local_timezone, expected_duration_s, "
        "expected_distance_m, completion_activity_id, completion_state, visibility, "
        "family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'Europe/London', ?, ?, ?, ?, 'private', ?, ?, ?, ?)",
        plan_rows,
    )
    await db.executemany(
        "INSERT INTO health_activities "
        "(id, owner_user_id, sport_key, title, status, planned_session_id, "
        "primary_source_record_id, primary_stream_asset_id, started_at_utc, ended_at_utc, "
        "local_timezone, local_calendar_date, elapsed_duration_s, timer_duration_s, "
        "moving_duration_s, distance_m, energy_kcal, measurement_quality, import_state, "
        "parser_version, workout_classification, classification_source, route_preview_json, "
        "session_rpe, perceived_performance, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'Europe/London', ?, ?, ?, ?, ?, ?, "
        "'measured', ?, ?, ?, 'fixture', ?, ?, ?, ?, ?, ?, ?)",
        [
            (
                identifier,
                row_owner,
                sport,
                title,
                status,
                plan_id,
                source_id,
                stream_id,
                started_at,
                ended_at,
                local_day,
                duration,
                duration,
                duration,
                distance,
                energy,
                import_state,
                parser_version,
                classification,
                route,
                session_rpe,
                performance,
                row_family,
                created_at,
                updated_at,
                created_by,
            )
            for (
                identifier,
                row_owner,
                sport,
                title,
                status,
                plan_id,
                source_id,
                stream_id,
                started_at,
                ended_at,
                local_day,
                duration,
                distance,
                energy,
                import_state,
                parser_version,
                classification,
                route,
                session_rpe,
                performance,
                row_family,
                created_at,
                updated_at,
                created_by,
            ) in activity_rows
        ],
    )
    await db.executemany(
        "INSERT INTO health_session_checkins "
        "(id, owner_user_id, planned_session_id, activity_id, timing, captured_at_utc, "
        "capture_quality, captured_before_activity_start, readiness_1_5, energy_1_5, "
        "soreness_1_5, motivation_1_5, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, 'pre', ?, 'contemporaneous', 1, ?, ?, ?, ?, ?, ?, ?, ?)",
        checkin_rows,
    )
    await db.executemany(
        "INSERT INTO health_activity_goal_links "
        "(id, owner_user_id, activity_id, goal_id, role, family_id, created_at, updated_at, "
        "created_by) VALUES (?, ?, ?, ?, 'planned', ?, ?, ?, ?)",
        goal_link_rows,
    )
    await db.executemany(
        "INSERT INTO health_plan_activity_links "
        "(id, owner_user_id, planned_session_id, activity_id, match_method, confidence, "
        "active, user_confirmed, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, 'fixture_exact', 1.0, 1, 1, ?, ?, ?, ?)",
        plan_activity_rows,
    )

    await db.executemany(
        "INSERT INTO health_strength_session_exercises "
        "(id, owner_user_id, activity_id, exercise_id, exercise_setup_id, "
        "exercise_setup_name_snapshot, load_entry_mode_snapshot, rep_count_mode_snapshot, "
        "unilateral_mode_snapshot, sequence, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, 'total_external', 'total', 'bilateral', ?, ?, ?, ?, ?)",
        strength_exercise_rows,
    )
    await db.executemany(
        "INSERT INTO health_strength_set_groups "
        "(id, owner_user_id, activity_id, session_exercise_id, sequence, training_role, "
        "structure_type, status, is_amrap, failure_state, started_at_utc, completed_at_utc, "
        "family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, 'working', 'straight', 'completed', 0, 'none', ?, ?, ?, ?, ?, ?)",
        strength_group_rows,
    )
    await db.executemany(
        "INSERT INTO health_strength_sets "
        "(id, owner_user_id, set_group_id, component_index, component_status, reps, "
        "load_value, load_unit, load_entry_mode_snapshot, normalized_external_load_kg, "
        "rpe, rir, completed_at_utc, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, 0, 'completed', ?, ?, 'kg', 'total_external', ?, ?, ?, ?, ?, ?, ?, ?)",
        strength_set_rows,
    )

    file_asset_rows = []
    source_rows = []
    import_rows = []
    source_link_rows = []
    stream_rows = []
    metric_rows = []
    summary_rows = []
    gear_link_rows = []
    interval_rows = []
    metric_specs = (
        ("distance_m", "m", 0.0, 12_000.0, 5_000.0),
        ("pace_s_per_km", "s/km", 250.0, 420.0, 330.0),
        ("heart_rate_bpm", "bpm", 85.0, 190.0, 145.0),
        ("altitude_m", "m", 15.0, 120.0, 55.0),
        ("cadence_spm", "spm", 140.0, 205.0, 174.0),
    )
    for index, activity_id in enumerate(fit_activity_ids):
        activity_day = reference_day - timedelta(days=index * 2)
        started_at = _at(activity_day, 6, index % 45)
        ended_at = started_at + timedelta(seconds=2_400 + (index % 12) * 120)
        source_asset_id = _id("fit-source-file", index)
        stream_file_id = _id("fit-stream-file", index)
        source_id = _id("fit-source", index)
        stream_id = _id("fit-stream", index)
        row_count = 36_000 if index % 10 == 0 else 3_600 + (index % 8) * 300
        file_asset_rows.extend(
            [
                (
                    source_asset_id,
                    owner_id,
                    "fit_source",
                    "source_required",
                    f"health/scale/source/{index:03d}.fit",
                    f"scale-{index:03d}.fit",
                    "application/vnd.ant.fit",
                    80_000 + index * 101,
                    f"scale-fit-{index:03d}",
                    family_id,
                    _iso(started_at),
                    _iso(ended_at),
                    owner_id,
                ),
                (
                    stream_file_id,
                    owner_id,
                    "activity_stream",
                    "regenerable",
                    f"health/scale/streams/{index:03d}.parquet",
                    f"scale-{index:03d}.parquet",
                    "application/vnd.apache.parquet",
                    row_count * 24,
                    f"scale-stream-{index:03d}",
                    family_id,
                    _iso(started_at),
                    _iso(ended_at),
                    owner_id,
                ),
            ]
        )
        source_rows.append(
            (
                source_id,
                owner_id,
                f"fit-file-{index:03d}",
                activity_id,
                activity_id,
                _iso(started_at),
                source_asset_id,
                f"scale-fit-{index:03d}",
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        import_rows.append(
            (
                _id("fit-import", index),
                owner_id,
                f"scale-import-{index:03d}",
                source_asset_id,
                source_id,
                activity_id,
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        source_link_rows.append(
            (
                _id("fit-source-link", index),
                owner_id,
                activity_id,
                source_id,
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        stream_rows.append(
            (
                stream_id,
                owner_id,
                activity_id,
                stream_file_id,
                row_count,
                (row_count - 1) * 1_000,
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        for metric_index, (metric, unit, minimum, maximum, average) in enumerate(
            metric_specs
        ):
            metric_rows.append(
                (
                    _id("metric-index", index * len(metric_specs) + metric_index),
                    owner_id,
                    activity_id,
                    stream_id,
                    metric,
                    row_count,
                    row_count,
                    minimum,
                    maximum,
                    average,
                    unit,
                    family_id,
                    _iso(started_at),
                    _iso(ended_at),
                    owner_id,
                )
            )
        summary_values = (
            ("running.average_heart_rate_bpm", 145.0 + index % 10, "bpm"),
            ("running.average_pace_s_per_km", 330.0 + index % 20, "s/km"),
            ("running.elevation_gain_m", 35.0 + index % 80, "m"),
        )
        for summary_index, (metric, value, unit) in enumerate(summary_values):
            summary_rows.append(
                (
                    _id("summary-metric", index * len(summary_values) + summary_index),
                    owner_id,
                    activity_id,
                    metric,
                    value,
                    unit,
                    family_id,
                    _iso(started_at),
                    _iso(ended_at),
                    owner_id,
                )
            )
        gear_link_rows.append(
            (
                _id("gear-link", index),
                owner_id,
                activity_id,
                _id("gear", 1 if index % 5 == 4 else 0),
                family_id,
                _iso(started_at),
                _iso(ended_at),
                owner_id,
            )
        )
        for interval_index in range(4):
            start_offset = interval_index * 600_000
            end_offset = min((interval_index + 1) * 600_000, int((ended_at - started_at).total_seconds() * 1_000))
            interval_rows.append(
                (
                    _id("interval", index * 4 + interval_index),
                    owner_id,
                    activity_id,
                    interval_index,
                    start_offset,
                    end_offset,
                    f"Segment {interval_index + 1}",
                    json.dumps({"average_heart_rate_bpm": 140 + interval_index * 5}),
                    family_id,
                    _iso(started_at),
                    _iso(ended_at),
                    owner_id,
                )
            )

    await db.executemany(
        "INSERT INTO health_file_assets "
        "(id, owner_user_id, asset_kind, storage_class, storage_key, original_filename, "
        "media_type, byte_size, file_fingerprint, state, family_id, created_at, updated_at, "
        "created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'ready', ?, ?, ?, ?)",
        file_asset_rows,
    )
    await db.executemany(
        "INSERT INTO health_source_records "
        "(id, owner_user_id, record_kind, transport_key, origin_provider_key, "
        "source_namespace, source_object_id, external_object_id, source_device_identifier, "
        "source_name, domain_entity_type, domain_entity_id, source_created_at_utc, raw_asset_id, "
        "file_fingerprint, state, parser_name, parser_version, family_id, created_at, updated_at, "
        "created_by) VALUES (?, ?, 'activity', 'file', 'fit', 'scale-fit', ?, ?, "
        "'forerunner-970', 'Scale Forerunner', 'activity', ?, ?, ?, ?, 'active', "
        "'fitparse', 'scale-v1', ?, ?, ?, ?)",
        source_rows,
    )
    await db.executemany(
        "INSERT INTO health_imports "
        "(id, owner_user_id, client_import_id, file_asset_id, source_record_id, activity_id, "
        "status, attempt_count, retryable, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, 'complete', 1, 1, ?, ?, ?, ?)",
        import_rows,
    )
    await db.executemany(
        "INSERT INTO health_activity_source_records "
        "(id, owner_user_id, activity_id, source_record_id, role, family_id, created_at, "
        "updated_at, created_by) VALUES (?, ?, ?, ?, 'primary', ?, ?, ?, ?)",
        source_link_rows,
    )
    await db.executemany(
        "INSERT INTO health_activity_stream_assets "
        "(id, owner_user_id, activity_id, file_asset_id, stream_kind, format, schema_version, "
        "parser_version, row_count, start_offset_ms, end_offset_ms, family_id, created_at, "
        "updated_at, created_by) VALUES (?, ?, ?, ?, 'primary', 'parquet', 1, 'scale-v1', "
        "?, 0, ?, ?, ?, ?, ?)",
        stream_rows,
    )
    await db.executemany(
        "INSERT INTO health_activity_metric_index "
        "(id, owner_user_id, activity_id, stream_asset_id, metric_key, sample_count, "
        "non_null_count, minimum, maximum, average, unit_key, quality, source_field, family_id, "
        "created_at, updated_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, "
        "'measured', 'fixture', ?, ?, ?, ?)",
        metric_rows,
    )
    await db.executemany(
        "INSERT INTO health_activity_summary_metrics "
        "(id, owner_user_id, activity_id, metric_key, value_number, unit_key, origin, quality, "
        "calculation_version, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, 'derived', 'measured', 'scale-v1', ?, ?, ?, ?)",
        summary_rows,
    )
    await db.executemany(
        "INSERT INTO health_activity_gear_links "
        "(id, owner_user_id, activity_id, gear_id, role, family_id, created_at, updated_at, "
        "created_by) VALUES (?, ?, ?, ?, 'primary', ?, ?, ?, ?)",
        gear_link_rows,
    )
    await db.executemany(
        "INSERT INTO health_activity_intervals "
        "(id, owner_user_id, activity_id, sequence, interval_kind, origin, start_offset_ms, "
        "end_offset_ms, label, metrics_json, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, 'lap', 'source', ?, ?, ?, ?, ?, ?, ?, ?)",
        interval_rows,
    )

    await db.execute(
        "INSERT INTO health_activity_quality_findings "
        "(id, owner_user_id, activity_id, finding_key, severity, message, "
        "limits_analysis_keys_json, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, 'scale-completeness', 'info', 'Representative fixture stream', "
        "'[]', ?, ?, ?, ?)",
        (
            _id("quality-finding"),
            owner_id,
            fit_activity_ids[0],
            family_id,
            fixture_now,
            fixture_now,
            owner_id,
        ),
    )
    await db.commit()
    return FitnessScaleFixture(
        reference_day=reference_day,
        current_plan_id=current_plan_id,
        latest_fit_activity_id=fit_activity_ids[0],
        running_goal_id=_id("goal", 0),
        fit_activity_ids=fit_activity_ids,
        strength_activity_ids=strength_activity_ids,
    )


async def seed_private_today_plan(
    db,
    *,
    user: dict,
    reference_day: date,
    title: str,
) -> str:
    """Add one other-owner sentinel used to prove compact-read isolation."""
    identifier = str(uuid5(NAMESPACE_URL, f"hausklar-fitness-scale:sentinel:{user['id']}"))
    timestamp = _iso(_at(reference_day, 9))
    await db.execute(
        "INSERT INTO health_user_settings "
        "(id, owner_user_id, timezone, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, 'Europe/London', ?, ?, ?, ?)",
        (
            str(uuid5(NAMESPACE_URL, f"hausklar-fitness-scale:settings:{user['id']}")),
            user["id"],
            user["family_id"],
            timestamp,
            timestamp,
            user["id"],
        ),
    )
    await db.execute(
        "INSERT INTO health_planned_sessions "
        "(id, owner_user_id, sport_key, title, status, session_source, "
        "scheduled_start_utc, scheduled_date, local_timezone, expected_duration_s, "
        "visibility, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, 'strength', ?, 'accepted', 'user', ?, ?, 'Europe/London', 2700, "
        "'private', ?, ?, ?, ?)",
        (
            identifier,
            user["id"],
            title,
            timestamp,
            reference_day.isoformat(),
            user["family_id"],
            timestamp,
            timestamp,
            user["id"],
        ),
    )
    await db.commit()
    return identifier
