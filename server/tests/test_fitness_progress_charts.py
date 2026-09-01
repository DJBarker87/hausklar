"""Compact Fitness charts use owner-scoped, semantically comparable evidence."""

import json
import uuid

import aiosqlite
import pytest

from app.services.fitness.common import insert_owned


pytestmark = pytest.mark.asyncio


async def _measurement(db, *, user: dict, value: float, measured_at: str) -> None:
    await insert_owned(
        db,
        table="health_body_measurements",
        record_id=str(uuid.uuid4()),
        values={
            "metric_key": "body.weight_kg",
            "measured_at_utc": measured_at,
            "local_timezone": "Europe/London",
            "value": value,
            "unit_key": "kg",
            "measurement_quality": "measured",
            "canonical_state": "canonical",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )


async def _run(
    db,
    *,
    user: dict,
    started_at: str,
    distance_m: float,
    duration_s: float,
    best_5k_s: float | None = None,
) -> str:
    activity_id = str(uuid.uuid4())
    await insert_owned(
        db,
        table="health_activities",
        record_id=activity_id,
        values={
            "sport_key": "running",
            "title": "Run",
            "status": "completed",
            "started_at_utc": started_at,
            "local_timezone": "Europe/London",
            "moving_duration_s": duration_s,
            "distance_m": distance_m,
            "measurement_quality": "measured",
            "import_state": "complete",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    if best_5k_s is not None:
        await insert_owned(
            db,
            table="health_activity_features",
            record_id=str(uuid.uuid4()),
            values={
                "activity_id": activity_id,
                "feature_key": "running.records",
                "feature_version": "running-v1",
                "value_json": json.dumps(
                    [
                        {
                            "record_key": "best_5k",
                            "label": "Best 5 km",
                            "value_s": best_5k_s,
                        }
                    ]
                ),
                "quality": "derived",
                "revision": 1,
            },
            user=user,
            record_sync_change=False,
        )
    return activity_id


async def _exercise(db, *, user: dict, seed_key: str, name: str, movement: str) -> tuple[str, str]:
    exercise_id = str(uuid.uuid4())
    setup_id = str(uuid.uuid4())
    await insert_owned(
        db,
        table="health_exercises",
        record_id=exercise_id,
        values={
            "seed_key": seed_key,
            "name": name,
            "movement_pattern_key": movement,
            "measurement_mode": "reps_load",
            "rep_count_mode": "total",
            "load_entry_mode": "total_external",
            "default_unit": "kg",
            "unilateral_mode": "bilateral",
            "progression_direction": "higher",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    await insert_owned(
        db,
        table="health_exercise_setups",
        record_id=setup_id,
        values={
            "exercise_id": exercise_id,
            "name": "Gym setup",
            "load_entry_mode": "total_external",
            "rep_count_mode": "total",
            "unilateral_mode": "bilateral",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    return exercise_id, setup_id


async def _strength_activity(
    db,
    *,
    user: dict,
    started_at: str,
    exercise_id: str,
    setup_id: str,
    working_sets: list[tuple[float, int]],
    warmup_load: float | None = None,
) -> str:
    activity_id = str(uuid.uuid4())
    session_exercise_id = str(uuid.uuid4())
    await insert_owned(
        db,
        table="health_activities",
        record_id=activity_id,
        values={
            "sport_key": "strength",
            "title": "Strength",
            "status": "completed",
            "started_at_utc": started_at,
            "local_timezone": "Europe/London",
            "measurement_quality": "measured",
            "import_state": "not_imported",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    await insert_owned(
        db,
        table="health_strength_session_exercises",
        record_id=session_exercise_id,
        values={
            "activity_id": activity_id,
            "exercise_id": exercise_id,
            "exercise_setup_id": setup_id,
            "exercise_setup_name_snapshot": "Gym setup",
            "load_entry_mode_snapshot": "total_external",
            "rep_count_mode_snapshot": "total",
            "unilateral_mode_snapshot": "bilateral",
            "sequence": 0,
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    values = [("working", load, reps) for load, reps in working_sets]
    if warmup_load is not None:
        values.append(("warmup", warmup_load, 1))
    for sequence, (role, load, reps) in enumerate(values):
        group_id = str(uuid.uuid4())
        await insert_owned(
            db,
            table="health_strength_set_groups",
            record_id=group_id,
            values={
                "activity_id": activity_id,
                "session_exercise_id": session_exercise_id,
                "sequence": sequence,
                "training_role": role,
                "structure_type": "straight",
                "status": "completed",
                "revision": 1,
            },
            user=user,
            record_sync_change=False,
        )
        await insert_owned(
            db,
            table="health_strength_sets",
            record_id=str(uuid.uuid4()),
            values={
                "set_group_id": group_id,
                "component_index": 0,
                "component_status": "completed",
                "reps": reps,
                "load_value": load,
                "load_unit": "kg",
                "load_entry_mode_snapshot": "total_external",
                "normalized_external_load_kg": load,
                "revision": 1,
            },
            user=user,
            record_sync_change=False,
        )
    return activity_id


async def test_progress_charts_cover_weight_run_estimates_and_named_working_sets(
    client,
    adult_a_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await _measurement(db, user=adult_a_user, value=81.2, measured_at="2026-07-01T07:00:00Z")
        await _measurement(db, user=adult_a_user, value=80.4, measured_at="2026-08-01T07:00:00Z")
        await _measurement(db, user=adult_b_user, value=60.0, measured_at="2026-08-02T07:00:00Z")

        exact_run = await _run(
            db,
            user=adult_a_user,
            started_at="2026-07-05T08:00:00Z",
            distance_m=5_100,
            duration_s=1_600,
            best_5k_s=1_450,
        )
        estimated_run = await _run(
            db,
            user=adult_a_user,
            started_at="2026-08-05T08:00:00Z",
            distance_m=10_000,
            duration_s=3_200,
        )
        await _run(
            db,
            user=adult_b_user,
            started_at="2026-08-06T08:00:00Z",
            distance_m=10_000,
            duration_s=2_500,
            best_5k_s=1_200,
        )

        squat_id, squat_setup = await _exercise(
            db,
            user=adult_a_user,
            seed_key="barbell_back_squat",
            name="Barbell Back Squat",
            movement="squat",
        )
        chest_id, chest_setup = await _exercise(
            db,
            user=adult_a_user,
            seed_key="barbell_bench_press",
            name="Barbell Bench Press",
            movement="horizontal_push",
        )
        overhead_id, overhead_setup = await _exercise(
            db,
            user=adult_a_user,
            seed_key="overhead_press",
            name="Overhead Press",
            movement="vertical_push",
        )
        await _strength_activity(
            db,
            user=adult_a_user,
            started_at="2026-07-10T18:00:00Z",
            exercise_id=squat_id,
            setup_id=squat_setup,
            working_sets=[(80, 6)],
        )
        latest_squat = await _strength_activity(
            db,
            user=adult_a_user,
            started_at="2026-08-07T18:00:00Z",
            exercise_id=squat_id,
            setup_id=squat_setup,
            working_sets=[(85, 8), (90, 5)],
            warmup_load=200,
        )
        await _strength_activity(
            db,
            user=adult_a_user,
            started_at="2026-08-08T18:00:00Z",
            exercise_id=chest_id,
            setup_id=chest_setup,
            working_sets=[(70, 8)],
        )
        await _strength_activity(
            db,
            user=adult_a_user,
            started_at="2026-08-09T18:00:00Z",
            exercise_id=overhead_id,
            setup_id=overhead_setup,
            working_sets=[(45, 6)],
        )
        await db.commit()

    response = await client.get("/api/fitness/progress/charts", headers=adult_a_headers)
    assert response.status_code == 200, response.text
    payload = response.json()

    assert [point["weight_kg"] for point in payload["weight"]] == [81.2, 80.4]
    five_k, ten_k = payload["running"]
    assert five_k["key"] == "5k"
    assert [(point["activity_id"], point["duration_s"], point["source"]) for point in five_k["points"]] == [
        (exact_run, 1_450.0, "best_effort"),
        (estimated_run, 1_600.0, "average_pace_estimate"),
    ]
    assert ten_k["key"] == "10k"
    assert [(point["activity_id"], point["duration_s"]) for point in ten_k["points"]] == [
        (estimated_run, 3_200.0)
    ]

    squat, chest, overhead = payload["strength"]
    assert (squat["key"], squat["exercise_name"], squat["setup_name"]) == (
        "squat",
        "Barbell Back Squat",
        "Gym setup",
    )
    assert [(point["load_kg"], point["repetitions"]) for point in squat["points"]] == [
        (80.0, 6),
        (90.0, 5),
    ]
    assert squat["points"][-1] == {
        "activity_id": latest_squat,
        "performed_at_utc": "2026-08-07T18:00:00Z",
        "load_kg": 90.0,
        "repetitions": 5,
        "working_set_count": 2,
    }
    assert (chest["key"], chest["points"][-1]["load_kg"]) == ("chest_press", 70.0)
    assert (overhead["key"], overhead["points"][-1]["load_kg"]) == (
        "overhead_press",
        45.0,
    )
