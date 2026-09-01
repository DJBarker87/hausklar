"""Deterministic weekly Fitness reviews expose useful actions, not internals."""

import uuid

import aiosqlite
import pytest

from app.services.fitness.common import insert_owned


pytestmark = pytest.mark.asyncio


def _forbidden_detail(payload: object) -> set[str]:
    forbidden = {
        "metric_key",
        "model",
        "provider",
        "confidence",
        "completeness",
        "evidence",
        "source",
        "raw_metric",
    }
    found: set[str] = set()
    if isinstance(payload, dict):
        for key, value in payload.items():
            if key.lower() in forbidden:
                found.add(key.lower())
            found.update(_forbidden_detail(value))
    elif isinstance(payload, list):
        for value in payload:
            found.update(_forbidden_detail(value))
    return found


async def _activity(
    db,
    *,
    user: dict,
    title: str,
    sport: str,
    started: str,
    local_date: str,
    duration_s: float | None = None,
    distance_m: float | None = None,
    parent_activity_id: str | None = None,
    imported: bool = False,
) -> str:
    identifier = str(uuid.uuid4())
    await insert_owned(
        db,
        table="health_activities",
        record_id=identifier,
        values={
            "sport_key": sport,
            "parent_activity_id": parent_activity_id,
            "title": title,
            "status": "completed",
            "started_at_utc": started,
            "local_timezone": "Europe/London",
            "local_calendar_date": local_date,
            "timer_duration_s": duration_s,
            "distance_m": distance_m,
            "measurement_quality": "measured",
            "import_state": "complete" if imported else "not_imported",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    return identifier


async def _strength_sets(db, *, user: dict, activity_id: str) -> None:
    exercise_id, setup_id, session_exercise_id, group_id = (str(uuid.uuid4()) for _ in range(4))
    await insert_owned(
        db,
        table="health_exercises",
        record_id=exercise_id,
        values={
            "name": "Back squat",
            "movement_pattern_key": "squat",
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
        values={"exercise_id": exercise_id, "name": "Barbell", "revision": 1},
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
            "sequence": 0,
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    await insert_owned(
        db,
        table="health_strength_set_groups",
        record_id=group_id,
        values={
            "activity_id": activity_id,
            "session_exercise_id": session_exercise_id,
            "sequence": 0,
            "training_role": "working",
            "structure_type": "straight",
            "status": "completed",
            "revision": 1,
        },
        user=user,
        record_sync_change=False,
    )
    for index, load, reps in ((0, 50, 10), (1, 60, 5)):
        await insert_owned(
            db,
            table="health_strength_sets",
            record_id=str(uuid.uuid4()),
            values={
                "set_group_id": group_id,
                "component_index": index,
                "component_status": "completed",
                "reps": reps,
                "normalized_external_load_kg": load,
                "revision": 1,
            },
            user=user,
            record_sync_change=False,
        )


async def test_weekly_review_combines_imported_and_native_work_without_double_counting(
    client,
    adult_a_headers,
    adult_a_user,
    adult_b_user,
    other_family_user,
    initialized_db,
):
    goal = await client.post(
        "/api/fitness/goals/from-template",
        headers=adult_a_headers,
        json={
            "id": str(uuid.uuid4()),
            "template_id": "move-consistently",
            "target_value": 3,
            "starts_on": "2026-08-03",
            "priority": 10,
        },
    )
    assert goal.status_code == 201, goal.text
    run_goal = await client.post(
        "/api/fitness/goals/from-template",
        headers=adult_a_headers,
        json={
            "id": str(uuid.uuid4()),
            "template_id": "run-weekly-distance",
            "target_value": 10,
            "starts_on": "2026-08-03",
            "priority": 80,
        },
    )
    assert run_goal.status_code == 201, run_goal.text

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        run_id = await _activity(
            db,
            user=adult_a_user,
            title="Morning run",
            sport="running",
            started="2026-08-03T06:00:00Z",
            local_date="2026-08-03",
            duration_s=1_800,
            distance_m=5_000,
            imported=True,
        )
        strength_id = await _activity(
            db,
            user=adult_a_user,
            title="Garage strength",
            sport="strength",
            started="2026-08-05T17:00:00Z",
            local_date="2026-08-05",
            duration_s=3_600,
        )
        await _strength_sets(db, user=adult_a_user, activity_id=strength_id)
        await _activity(
            db,
            user=adult_a_user,
            title="Run leg duplicate",
            sport="running",
            started="2026-08-03T06:00:00Z",
            local_date="2026-08-03",
            duration_s=1_800,
            distance_m=5_000,
            parent_activity_id=run_id,
            imported=True,
        )
        await _activity(
            db,
            user=adult_a_user,
            title="Previous Sunday",
            sport="running",
            started="2026-08-02T08:00:00Z",
            local_date="2026-08-02",
            duration_s=600,
            distance_m=1_000,
        )
        await _activity(
            db,
            user=adult_a_user,
            title="Next Monday",
            sport="running",
            started="2026-08-10T08:00:00Z",
            local_date="2026-08-10",
            duration_s=600,
            distance_m=1_000,
        )
        await _activity(
            db,
            user=adult_b_user,
            title="Morgan private run",
            sport="running",
            started="2026-08-04T08:00:00Z",
            local_date="2026-08-04",
            duration_s=7_200,
            distance_m=20_000,
        )
        await _activity(
            db,
            user=other_family_user,
            title="Other family run",
            sport="running",
            started="2026-08-04T08:00:00Z",
            local_date="2026-08-04",
            duration_s=7_200,
            distance_m=20_000,
        )
        await db.commit()

    first = await client.get(
        "/api/fitness/weekly-review",
        params={"week_start": "2026-08-03"},
        headers=adult_a_headers,
    )
    repeated = await client.get(
        "/api/fitness/weekly-review",
        params={"week_start": "2026-08-03"},
        headers=adult_a_headers,
    )
    assert first.status_code == 200, first.text
    assert repeated.json() == first.json()
    review = first.json()
    assert review["week_start"] == "2026-08-03"
    assert review["week_end"] == "2026-08-09"
    assert review["totals"] == {
        "completed_sessions": 2,
        "active_days": 2,
        "duration_minutes": 90,
        "distance_km": 5.0,
        "strength_volume_kg": 800.0,
    }
    assert review["goal"] == {
        "goal_id": run_goal.json()["goal_id"],
        "goal_name": "Run further",
        "progress_text": "5.0 of 10 km completed this week.",
        "progress_percent": 50,
    }
    assert review["highlight"] == {
        "title": "Longest session",
        "detail": "Garage strength was 60 minutes.",
    }
    assert review["opportunity"] == {
        "title": "Put the next step in the week",
        "detail": "Planning it now makes the goal easier to act on.",
        "destination": "plan",
        "action": "plan_session",
        "action_label": "Add a run",
    }
    assert _forbidden_detail(review) == set()


async def test_weekly_review_empty_and_partial_weeks_still_have_a_useful_action(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    empty = await client.get(
        "/api/fitness/weekly-review",
        params={"week_start": "2026-08-03"},
        headers=adult_a_headers,
    )
    assert empty.status_code == 200, empty.text
    assert empty.json()["totals"] == {
        "completed_sessions": 0,
        "active_days": 0,
        "duration_minutes": None,
        "distance_km": None,
        "strength_volume_kg": None,
    }
    assert empty.json()["goal"] is None
    assert empty.json()["highlight"]["title"] == "A fresh week"
    assert empty.json()["opportunity"]["action"] == "plan_session"

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await _activity(
            db,
            user=adult_a_user,
            title="Untracked walk",
            sport="walking",
            started="2026-08-09T23:30:00Z",
            local_date="2026-08-09",
        )
        await db.commit()
    partial = await client.get(
        "/api/fitness/weekly-review",
        params={"week_start": "2026-08-03"},
        headers=adult_a_headers,
    )
    assert partial.status_code == 200, partial.text
    assert partial.json()["totals"] == {
        "completed_sessions": 1,
        "active_days": 1,
        "duration_minutes": None,
        "distance_km": None,
        "strength_volume_kg": None,
    }
    assert partial.json()["highlight"] == {
        "title": "You showed up",
        "detail": "You completed 1 session.",
    }
    assert partial.json()["opportunity"]["action"] == "choose_goal"
    assert _forbidden_detail(partial.json()) == set()


async def test_weekly_review_makes_a_faster_5k_goal_actionable(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    created = await client.post(
        "/api/fitness/goals/from-template",
        headers=adult_a_headers,
        json={
            "id": str(uuid.uuid4()),
            "template_id": "run-faster-5k",
            "target_value": 22 * 60 + 30,
            "starts_on": "2026-08-03",
            "priority": 90,
        },
    )
    assert created.status_code == 201, created.text
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await _activity(
            db,
            user=adult_a_user,
            title="Saturday 10K",
            sport="running",
            started="2026-08-08T07:00:00Z",
            local_date="2026-08-08",
            duration_s=44 * 60,
            distance_m=10_000,
        )
        await _activity(
            db,
            user=adult_a_user,
            title="Fast kilometre reps",
            sport="running",
            started="2026-08-06T07:00:00Z",
            local_date="2026-08-06",
            duration_s=3 * 60 + 30,
            distance_m=1_000,
        )
        await db.commit()

    response = await client.get(
        "/api/fitness/weekly-review",
        params={"week_start": "2026-08-03"},
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    review = response.json()
    assert review["goal"] == {
        "goal_id": created.json()["goal_id"],
        "goal_name": "Run 5K in 22:30",
        "progress_text": "Best 5K-equivalent this week: 22:00; target 22:30.",
        "progress_percent": 100,
    }
    assert review["opportunity"]["action_label"] == "Plan the next session"
    assert _forbidden_detail(review) == set()
