"""Focused completion contracts for Nutrition, Strength, Coach and export."""

import io
import json
import uuid
import zipfile
from datetime import date, datetime, timedelta, timezone

import aiosqlite
import pytest
from PIL import Image

from app.config import settings
from app.services.fitness.common import insert_owned, soft_delete_owned, update_owned
from app.services.fitness.strength import estimated_one_rep_max


pytestmark = pytest.mark.asyncio


def _mutation(entity_type: str, entity_id: str, payload: dict, operation="upsert"):
    return {
        "mutation_id": str(uuid.uuid4()),
        "entity_type": entity_type,
        "entity_id": entity_id,
        "operation": operation,
        "payload_schema_version": 1,
        "base_revision": None,
        "payload": payload,
        "created_at_client": "2026-08-02T10:00:00Z",
    }


def _sync(mutations: list[dict]):
    return {
        "sync_protocol_version": 1,
        "client_schema_version": 1,
        "client_app_version": "1",
        "client_build": "1",
        "platform": "web",
        "device_id": str(uuid.uuid4()),
        "cursor": 0,
        "mutations": mutations,
    }


def _png(colour="navy") -> bytes:
    output = io.BytesIO()
    Image.new("RGB", (32, 48), colour).save(output, format="PNG")
    return output.getvalue()


async def test_meal_completion_is_explicit_idempotent_and_owner_private(
    client, adult_a_headers, adult_b_headers
):
    payload = {
        "id": str(uuid.uuid4()),
        "nutrition_date": "2026-08-12",
        "meal_key": "breakfast",
        "client_id": "ios-test-device",
        "client_timestamp": "2026-08-12T08:30:00Z",
    }
    completed = await client.post(
        "/api/fitness/nutrition/meal-completions",
        headers=adult_a_headers,
        json=payload,
    )
    assert completed.status_code == 201, completed.text
    assert completed.json()["client_id"] == "ios-test-device"
    assert completed.json()["client_timestamp"] == "2026-08-12T08:30:00Z"
    replay = await client.post(
        "/api/fitness/nutrition/meal-completions",
        headers=adult_a_headers,
        json={**payload, "id": str(uuid.uuid4())},
    )
    assert replay.status_code == 201, replay.text
    assert replay.json()["id"] == completed.json()["id"]

    dom = await client.get(
        "/api/fitness/nutrition/meal-completions",
        headers=adult_a_headers,
        params={"date": "2026-08-12"},
    )
    kat = await client.get(
        "/api/fitness/nutrition/meal-completions",
        headers=adult_b_headers,
        params={"date": "2026-08-12"},
    )
    assert [item["meal_key"] for item in dom.json()] == ["breakfast"]
    assert kat.json() == []


async def test_nutrition_sync_graph_shared_reads_and_atomic_failure(
    client, adult_a_headers, adult_b_headers, initialized_db
):
    capabilities = (await client.get("/api/fitness/sync/capabilities", headers=adult_a_headers)).json()[
        "supported_payload_schema_versions_by_entity"
    ]
    assert {
        "food_version",
        "food_serving",
        "recipe",
        "recipe_version",
        "meal_template",
        "nutrition_target",
    } <= set(capabilities)

    food_id, version_id, serving_id = (str(uuid.uuid4()) for _ in range(3))
    recipe_id, recipe_version_id = (str(uuid.uuid4()) for _ in range(2))
    template_id, target_id = (str(uuid.uuid4()) for _ in range(2))
    mutations = [
        _mutation(
            "meal_template",
            template_id,
            {
                "name": "Breakfast",
                "meal_key": "breakfast",
                "items": [
                    {
                        "food_version_id": version_id,
                        "label": "Oats",
                        "amount": 50,
                        "unit": "g",
                        "canonical_amount": 50,
                        "canonical_unit": "g",
                        "measurement_quality": "weighed",
                    }
                ],
            },
        ),
        _mutation(
            "nutrition_target",
            target_id,
            {
                "metric_key": "nutrition.protein_g",
                "target_type": "range",
                "target_min": 100,
                "target_max": 140,
                "effective_from": "2026-08-01",
            },
        ),
        _mutation(
            "recipe_version",
            recipe_version_id,
            {
                "recipe_id": recipe_id,
                "finished_weight_g": 200,
                "components": [
                    {
                        "food_version_id": version_id,
                        "amount": 100,
                        "unit": "g",
                        "canonical_amount": 100,
                        "canonical_unit": "g",
                    }
                ],
            },
        ),
        _mutation(
            "recipe",
            recipe_id,
            {"name": "Porridge", "household_shared": True},
        ),
        _mutation(
            "food_serving",
            serving_id,
            {
                "food_id": food_id,
                "name": "Bowl",
                "amount": 50,
                "unit": "g",
                "canonical_amount": 50,
                "canonical_unit": "g",
                "measurement_quality": "weighed",
                "is_default": True,
            },
        ),
        _mutation(
            "food_version",
            version_id,
            {
                "food_id": food_id,
                "reference_amount": 100,
                "reference_unit": "g",
                "calories_kcal": 400,
                "protein_g": None,
            },
        ),
        _mutation(
            "food",
            food_id,
            {"name": "Shared oats", "household_shared": True},
        ),
    ]
    response = await client.post("/api/fitness/sync", headers=adult_a_headers, json=_sync(mutations))
    assert response.status_code == 200, response.text
    assert len(response.json()["accepted"]) == len(mutations)
    recipe = await client.get(f"/api/fitness/recipes/{recipe_id}", headers=adult_a_headers)
    assert recipe.status_code == 200
    calculated = recipe.json()["versions"][0]
    assert calculated["calories_kcal"] == pytest.approx(400)
    assert calculated["protein_g"] is None
    assert calculated["components"][0]["food_name"] == "Shared oats"
    targets = await client.get(
        "/api/fitness/nutrition/targets",
        params={"date": "2026-08-02"},
        headers=adult_a_headers,
    )
    assert targets.json()[0]["target_min"] == 100
    calorie_target = await client.post(
        "/api/fitness/nutrition/targets",
        headers=adult_a_headers,
        json={
            "metric_key": "nutrition.calories_kcal",
            "target_type": "fixed",
            "target_value": 500,
            "effective_from": "2026-08-01",
        },
    )
    assert calorie_target.status_code == 201, calorie_target.text
    diary_entry = await client.post(
        "/api/fitness/food-log",
        headers=adult_a_headers,
        json={
            "food_version_id": version_id,
            "logged_at_utc": "2026-08-02T07:30:00Z",
            "local_timezone": "Europe/Berlin",
            "meal_key": "breakfast",
            "entered_amount": 50,
            "entered_unit": "g",
            "canonical_amount": 50,
            "canonical_unit": "g",
            "measurement_quality": "weighed",
        },
    )
    assert diary_entry.status_code == 201, diary_entry.text
    diary = (
        await client.get(
            "/api/fitness/food-log",
            params={"date": "2026-08-02"},
            headers=adult_a_headers,
        )
    ).json()
    assert diary["totals"]["calories_kcal"] == pytest.approx(200)
    assert diary["targets"]["calories_kcal"] == pytest.approx(500)
    assert diary["remaining"]["calories_kcal"] == pytest.approx(300)
    assert diary["meal_totals"]["breakfast"]["calories_kcal"] == pytest.approx(200)
    assert diary["measured_share"] == pytest.approx(1)
    assert diary["estimated_share"] == pytest.approx(0)
    calorie_contributor = next(
        item for item in diary["contributors"] if item["nutrient_key"] == "calories_kcal"
    )
    assert calorie_contributor["label"] == "Shared oats"
    assert calorie_contributor["value"] == pytest.approx(200)
    shared = (await client.get("/api/fitness/foods", headers=adult_b_headers)).json()
    shared_food = next(item for item in shared if item["id"] == food_id)
    assert shared_food["versions"][0]["id"] == version_id
    assert shared_food["servings"][0]["id"] == serving_id

    private_id = str(uuid.uuid4())
    invalid_parent = str(uuid.uuid4())
    failed = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync(
            [
                _mutation("food", private_id, {"name": "Must roll back"}),
                _mutation(
                    "recipe_version",
                    str(uuid.uuid4()),
                    {
                        "recipe_id": invalid_parent,
                        "finished_weight_g": 100,
                        "components": [],
                    },
                ),
            ]
        ),
    )
    assert failed.status_code in {404, 409}
    nonfinite = await client.post(
        "/api/fitness/foods",
        headers={**adult_a_headers, "Content-Type": "application/json"},
        content=(
            '{"name":"Infinite food","version":{"reference_amount":100,'
            '"reference_unit":"g","calories_kcal":1e999}}'
        ),
    )
    assert nonfinite.status_code == 422
    async with aiosqlite.connect(initialized_db) as db:
        assert (
            await (
                await db.execute("SELECT 1 FROM health_foods WHERE id = ?", (private_id,))
            ).fetchone()
        ) is None


async def test_nutrition_analysis_returns_exact_contributors_and_practical_change(
    client, adult_a_headers, initialized_db
):
    food = await client.post(
        "/api/fitness/foods",
        headers=adult_a_headers,
        json={
            "name": "Measured oats",
            "version": {
                "reference_amount": 100,
                "reference_unit": "g",
                "calories_kcal": 400,
                "protein_g": 16,
                "fibre_g": 10,
                "sugars_g": 1,
                "saturated_fat_g": 2,
                "salt_g": 0.2,
            },
        },
    )
    assert food.status_code == 201, food.text
    food_version_id = food.json()["versions"][0]["id"]
    recipe = await client.post(
        "/api/fitness/recipes",
        headers=adult_a_headers,
        json={
            "name": "Repeatable pasta",
            "version": {
                "servings": 1,
                "calories_kcal": 600,
                "protein_g": 40,
                "fibre_g": 8,
                "sugars_g": 6,
                "saturated_fat_g": 5,
                "salt_g": 1.2,
                "confidence": "calculated",
            },
        },
    )
    assert recipe.status_code == 201, recipe.text
    recipe_version_id = recipe.json()["versions"][0]["id"]
    target = await client.post(
        "/api/fitness/nutrition/targets",
        headers=adult_a_headers,
        json={
            "metric_key": "nutrition.calories_kcal",
            "target_type": "fixed",
            "target_value": 760,
            "effective_from": "2026-08-01",
        },
    )
    assert target.status_code == 201, target.text

    for day in range(1, 8):
        logged = await client.post(
            "/api/fitness/food-log",
            headers=adult_a_headers,
            json={
                "food_version_id": food_version_id,
                "logged_at_utc": f"2026-08-0{day}T07:30:00Z",
                "local_timezone": "Europe/London",
                "meal_key": "breakfast",
                "entered_amount": 50,
                "entered_unit": "g",
                "canonical_amount": 50,
                "canonical_unit": "g",
                "measurement_quality": "estimated" if day == 1 else "weighed",
            },
        )
        assert logged.status_code == 201, logged.text
    for day in range(1, 8):
        logged = await client.post(
            "/api/fitness/food-log",
            headers=adult_a_headers,
            json={
                "recipe_version_id": recipe_version_id,
                "logged_at_utc": f"2026-08-0{day}T18:30:00Z",
                "local_timezone": "Europe/London",
                "meal_key": "dinner",
                "entered_amount": 1,
                "entered_unit": "serving",
                "canonical_amount": 1,
                "canonical_unit": "serving",
                "measurement_quality": "standard_serving",
            },
        )
        assert logged.status_code == 201, logged.text

    response = await client.get(
        "/api/fitness/nutrition/analysis",
        params={"start": "2026-08-01", "end": "2026-08-07"},
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    result = response.json()
    calories = [item for item in result["contributors"] if item["nutrient_key"] == "calories_kcal"]
    assert [(item["label"], item["item_kind"]) for item in calories] == [
        ("Repeatable pasta", "recipe"),
        ("Measured oats", "food"),
    ]
    assert calories[0]["meal_key"] == "dinner"
    assert calories[0]["total"] == pytest.approx(4_200)
    assert calories[0]["entry_count"] == calories[0]["sample_days"] == 7
    assert calories[0]["typical_amount"] == pytest.approx(1)
    assert calories[0]["typical_unit"] == "serving"
    assert {item["nutrient_key"] for item in result["contributors"]} == {
        "calories_kcal",
        "protein_g",
        "fibre_g",
        "sugars_g",
        "saturated_fat_g",
        "salt_g",
    }

    recommendation = result["recommendation"]
    assert recommendation["food_or_meal"] == "Measured oats"
    assert recommendation["observation_period"] == {
        "start": "2026-08-01",
        "end": "2026-08-07",
        "calendar_days": 7,
        "logged_days": 7,
    }
    assert recommendation["calculation"]["observed_average_calories_kcal"] == pytest.approx(800)
    assert recommendation["calculation"]["target_average_calories_kcal"] == pytest.approx(760)
    assert recommendation["calculation"]["average_gap_calories_kcal"] == pytest.approx(40)
    assert recommendation["frequency"]["entries"] == 7
    assert recommendation["frequency"]["days"] == 7
    assert recommendation["typical_amount"] == {"value": 50.0, "unit": "g"}
    assert recommendation["proposed_change"]["fraction"] == pytest.approx(0.2)
    assert recommendation["proposed_change"]["amount"] == pytest.approx(10)
    assert recommendation["proposed_change"]["resulting_amount"] == pytest.approx(40)
    assert recommendation["expected_effect"]["per_occurrence_calories_kcal"] == pytest.approx(40)
    assert recommendation["expected_effect"]["period_calories_kcal"] == pytest.approx(280)
    assert recommendation["expected_effect"]["weekly_calories_kcal"] == pytest.approx(280)
    assert recommendation["uncertainty"]["nutrient_completeness"] == pytest.approx(1)
    assert recommendation["uncertainty"]["diary_day_completeness"] == pytest.approx(1)
    assert recommendation["uncertainty"]["target_day_coverage"] == pytest.approx(1)
    assert recommendation["uncertainty"]["estimated_entry_share"] == pytest.approx(1 / 14)
    assert "highest-impact recurring Calories contributor" in recommendation["why_practical"]

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_food_log_entries SET entered_amount = 1, "
            "entered_unit = 'serving' WHERE food_version_id = ?",
            (food_version_id,),
        )
        await db.commit()
    serving_only = await client.get(
        "/api/fitness/nutrition/analysis",
        params={"start": "2026-08-01", "end": "2026-08-07"},
        headers=adult_a_headers,
    )
    assert serving_only.json()["recommendation"] is None

    raised_target = await client.put(
        f"/api/fitness/nutrition/targets/{target.json()['id']}",
        headers=adult_a_headers,
        json={
            "metric_key": "nutrition.calories_kcal",
            "target_type": "fixed",
            "target_value": 900,
            "effective_from": "2026-08-01",
        },
    )
    assert raised_target.status_code == 200, raised_target.text
    under_target = await client.get(
        "/api/fitness/nutrition/analysis",
        params={"start": "2026-08-01", "end": "2026-08-07"},
        headers=adult_a_headers,
    )
    assert under_target.status_code == 200, under_target.text
    assert under_target.json()["recommendation"] is None
    assert under_target.json()["contributors"]


async def test_strength_nested_history_validation_merge_and_suggestions(
    client, adult_a_headers, initialized_db
):
    exercises = (await client.get("/api/fitness/exercises", headers=adult_a_headers)).json()
    exercise = exercises[0]
    source_setup = exercise["setups"][0]
    proposed_plan_id = str(uuid.uuid4())
    proposed_plan = await client.post(
        "/api/fitness/planned-sessions",
        headers=adult_a_headers,
        json={
            "id": proposed_plan_id,
            "sport_key": "strength",
            "title": "Review-only draft",
            "local_timezone": "Europe/Berlin",
            "status": "proposed",
            "scheduled_date": "2026-08-02",
        },
    )
    assert proposed_plan.status_code == 201, proposed_plan.text
    proposed_start = await client.post(
        "/api/fitness/strength/sessions",
        headers=adult_a_headers,
        json={
            "id": str(uuid.uuid4()),
            "title": "Must not start",
            "started_at_utc": "2026-08-02T09:00:00Z",
            "local_timezone": "Europe/Berlin",
            "status": "in_progress",
            "planned_session_id": proposed_plan_id,
        },
    )
    assert proposed_start.status_code == 409
    session_id, session_exercise_id, group_id = (str(uuid.uuid4()) for _ in range(3))
    session_started_at = datetime.now(timezone.utc).replace(microsecond=0)
    session_body = {
        "id": session_id,
        "title": "Snapshot session",
        "started_at_utc": session_started_at.isoformat(),
        "local_timezone": "Europe/Berlin",
        "status": "in_progress",
    }
    created = await client.post(
        "/api/fitness/strength/sessions", headers=adult_a_headers, json=session_body
    )
    assert created.status_code == 201, created.text
    other = await client.post(
        "/api/fitness/strength/sessions",
        headers=adult_a_headers,
        json={**session_body, "id": str(uuid.uuid4()), "title": "Second"},
    )
    assert other.status_code == 409
    added = await client.post(
        f"/api/fitness/strength/sessions/{session_id}/exercises",
        headers=adult_a_headers,
        json={
            "id": session_exercise_id,
            "activity_id": session_id,
            "exercise_id": exercise["id"],
            "exercise_setup_id": source_setup["id"],
            "sequence": 0,
        },
    )
    assert added.status_code == 201, added.text
    group = await client.post(
        f"/api/fitness/strength/session-exercises/{session_exercise_id}/set-groups",
        headers=adult_a_headers,
        json={
            "id": group_id,
            "activity_id": session_id,
            "session_exercise_id": session_exercise_id,
            "sequence": 0,
            "training_role": "working",
            "structure_type": "straight",
            "status": "completed",
            "failure_state": "stopped_for_body_issue",
        },
    )
    assert group.status_code == 201, group.text
    bad = await client.post(
        f"/api/fitness/strength/set-groups/{group_id}/components",
        headers=adult_a_headers,
        json={
            "set_group_id": group_id,
            "component_index": 0,
            "component_status": "completed",
            "reps": 8,
            "load_value": 50,
            "load_unit": "lb",
        },
    )
    assert bad.status_code == 409
    nonfinite = await client.post(
        f"/api/fitness/strength/set-groups/{group_id}/components",
        headers={**adult_a_headers, "Content-Type": "application/json"},
        content=(
            '{"set_group_id":"' + group_id + '","component_index":0,"component_status":"completed",'
            '"reps":8,"load_value":1e999,"load_unit":"kg"}'
        ),
    )
    assert nonfinite.status_code == 422
    component = await client.post(
        f"/api/fitness/strength/set-groups/{group_id}/components",
        headers=adult_a_headers,
        json={
            "set_group_id": group_id,
            "component_index": 0,
            "component_status": "completed",
            "reps": 8,
            "load_value": 50,
            "load_unit": "kg",
            "normalized_external_load_kg": 999,
            "rpe": 8,
        },
    )
    assert component.status_code == 201, component.text
    assert component.json()["normalized_external_load_kg"] != 999
    await client.post(
        f"/api/fitness/strength/sessions/{session_id}/finish",
        headers=adult_a_headers,
        json={
            "status": "completed",
            "ended_at_utc": (session_started_at + timedelta(hours=1)).isoformat(),
        },
    )
    activity_history = await client.get("/api/fitness/activities", headers=adult_a_headers)
    assert activity_history.status_code == 200, activity_history.text
    activity_summary = next(item for item in activity_history.json() if item["id"] == session_id)
    assert activity_summary["sport_key"] == "strength"
    assert activity_summary["duration_s"] == 3600
    assert activity_summary["strength_summary"] == {
        "exercise_count": 1,
        "set_count": 1,
        "working_set_count": 1,
        "failure_set_count": 0,
        "volume_kg": 400.0,
    }
    target_setup_id = str(uuid.uuid4())
    target = await client.post(
        "/api/fitness/exercise-setups",
        headers=adult_a_headers,
        json={
            "id": target_setup_id,
            "exercise_id": exercise["id"],
            "name": "Renamed future setup",
            "load_entry_mode": source_setup.get("load_entry_mode"),
            "rep_count_mode": source_setup.get("rep_count_mode"),
            "unilateral_mode": source_setup.get("unilateral_mode"),
            "active": True,
        },
    )
    assert target.status_code == 201, target.text
    merged = await client.post(
        "/api/fitness/exercise-setups/merge",
        headers=adult_a_headers,
        json={"source_id": source_setup["id"], "target_id": target_setup_id},
    )
    assert merged.status_code == 200, merged.text
    async with aiosqlite.connect(initialized_db) as db:
        history = await (
            await db.execute(
                "SELECT COUNT(*) FROM record_history WHERE table_name = ? AND record_id = ?",
                ("health_exercise_setups", source_setup["id"]),
            )
        ).fetchone()
        assert history[0] >= 1
    listing = (await client.get("/api/fitness/strength/sessions", headers=adult_a_headers)).json()
    hydrated = next(item for item in listing if item["id"] == session_id)
    recorded = hydrated["exercises"][0]
    assert recorded["set_groups"][0]["components"]
    assert recorded["exercise_setup_id"] == source_setup["id"]
    assert recorded["source_setup_label"] == source_setup["name"]
    progress = await client.get(
        f"/api/fitness/strength/exercises/{exercise['id']}/progress",
        headers=adult_a_headers,
    )
    assert progress.status_code == 200, progress.text
    assert progress.json()["observed_sets"][0]["source_setup_label"] == source_setup["name"]

    # A second setup in the same activity must retain its own records and e1RM.
    # Machine/rack variants are not silently comparable just because they belong
    # to the same exercise and happened in the same session.
    separate_setup_id = str(uuid.uuid4())
    separate = await client.post(
        "/api/fitness/exercise-setups",
        headers=adult_a_headers,
        json={
            "id": separate_setup_id,
            "exercise_id": exercise["id"],
            "name": "Separate rack",
            "load_entry_mode": source_setup.get("load_entry_mode"),
            "rep_count_mode": source_setup.get("rep_count_mode"),
            "unilateral_mode": source_setup.get("unilateral_mode"),
            "active": True,
        },
    )
    assert separate.status_code == 201, separate.text
    second_session_exercise_id, second_group_id = str(uuid.uuid4()), str(uuid.uuid4())
    second_exercise = await client.post(
        f"/api/fitness/strength/sessions/{session_id}/exercises",
        headers=adult_a_headers,
        json={
            "id": second_session_exercise_id,
            "activity_id": session_id,
            "exercise_id": exercise["id"],
            "exercise_setup_id": separate_setup_id,
            "sequence": 1,
        },
    )
    assert second_exercise.status_code == 201, second_exercise.text
    second_group = await client.post(
        f"/api/fitness/strength/session-exercises/{second_session_exercise_id}/set-groups",
        headers=adult_a_headers,
        json={
            "id": second_group_id,
            "activity_id": session_id,
            "session_exercise_id": second_session_exercise_id,
            "sequence": 0,
            "training_role": "working",
            "structure_type": "straight",
            "status": "completed",
            "failure_state": "muscular",
        },
    )
    assert second_group.status_code == 201, second_group.text
    second_component = await client.post(
        f"/api/fitness/strength/set-groups/{second_group_id}/components",
        headers=adult_a_headers,
        json={
            "set_group_id": second_group_id,
            "component_index": 0,
            "component_status": "completed",
            "reps": 5,
            "load_value": 80,
            "load_unit": "kg",
            "rpe": 9,
        },
    )
    assert second_component.status_code == 201, second_component.text

    unilateral_setup_id = str(uuid.uuid4())
    unilateral_setup = await client.post(
        "/api/fitness/exercise-setups",
        headers=adult_a_headers,
        json={
            "id": unilateral_setup_id,
            "exercise_id": exercise["id"],
            "name": "Separate left/right setup",
            "load_entry_mode": "total_external",
            "rep_count_mode": "left_right_separate",
            "unilateral_mode": "unilateral_same_set",
            "active": True,
        },
    )
    assert unilateral_setup.status_code == 201, unilateral_setup.text
    unilateral_exercise_id, unilateral_group_id = str(uuid.uuid4()), str(uuid.uuid4())
    unilateral_exercise = await client.post(
        f"/api/fitness/strength/sessions/{session_id}/exercises",
        headers=adult_a_headers,
        json={
            "id": unilateral_exercise_id,
            "activity_id": session_id,
            "exercise_id": exercise["id"],
            "exercise_setup_id": unilateral_setup_id,
            "sequence": 2,
        },
    )
    assert unilateral_exercise.status_code == 201, unilateral_exercise.text
    unilateral_group = await client.post(
        f"/api/fitness/strength/session-exercises/{unilateral_exercise_id}/set-groups",
        headers=adult_a_headers,
        json={
            "id": unilateral_group_id,
            "activity_id": session_id,
            "session_exercise_id": unilateral_exercise_id,
            "sequence": 0,
            "training_role": "working",
            "structure_type": "straight",
            "status": "completed",
        },
    )
    assert unilateral_group.status_code == 201, unilateral_group.text
    unilateral_component = await client.post(
        f"/api/fitness/strength/set-groups/{unilateral_group_id}/components",
        headers=adult_a_headers,
        json={
            "set_group_id": unilateral_group_id,
            "component_index": 0,
            "component_status": "completed",
            "reps_left": 8,
            "reps_right": 8,
            "load_value": 70,
            "load_unit": "kg",
            "rpe": 8,
        },
    )
    assert unilateral_component.status_code == 201, unilateral_component.text
    separated_progress = (
        await client.get(
            f"/api/fitness/strength/exercises/{exercise['id']}/progress",
            headers=adult_a_headers,
        )
    ).json()
    assert len(separated_progress["records_by_comparison"]) == 3
    assert separated_progress["records"]["heaviest"] is None
    assert len(separated_progress["estimated_1rm"]) == 2
    assert {item["comparison_key"]["setup_id"] for item in separated_progress["estimated_1rm"]} == {
        target_setup_id,
        separate_setup_id,
    }
    merged_history = next(
        item
        for item in separated_progress["observed_sets"]
        if item["source_setup_id"] == source_setup["id"]
    )
    assert merged_history["comparison_key"]["setup_id"] == target_setup_id
    assert merged_history["source_setup_label"] == source_setup["name"]
    unilateral_record = next(
        item
        for item in separated_progress["records_by_comparison"]
        if item["comparison_key"]["setup_id"] == unilateral_setup_id
    )
    assert unilateral_record["best_by_rep_band"]["7-10"]["reps_left"] == 8
    assert unilateral_record["best_by_rep_band"]["7-10"]["reps_right"] == 8
    assert unilateral_record["best_by_rep_band"]["11-15"] is None
    suggestions = await client.get(
        "/api/fitness/strength/suggestions",
        headers=adult_a_headers,
        params={
            "available_minutes": 45,
            "equipment": exercise.get("equipment_type") or "bodyweight",
        },
    )
    assert suggestions.status_code == 200, suggestions.text
    assert suggestions.json()["recent_running_load"]["window_days"] == 7
    suggestion = next(
        item
        for item in suggestions.json()["exercise_candidates"]
        if item["exercise_id"] == exercise["id"]
    )
    assert suggestion["exercise_setup_id"] == target_setup_id
    assert group_id in {item["group_id"] for item in suggestion["recent_evidence"]}
    assert second_group_id not in {item["group_id"] for item in suggestion["recent_evidence"]}

    assert (
        estimated_one_rep_max(
            {
                "structure_type": "straight",
                "training_role": "working",
                "failure_state": "muscular",
            },
            {
                "component_status": "completed",
                "reps": None,
                "reps_left": 8,
                "reps_right": 8,
                "normalized_external_load_kg": 50,
                "load_entry_mode_snapshot": "total_external",
            },
        )
        is None
    )


async def test_central_history_and_idempotent_soft_delete(adult_a_user, initialized_db):
    record_id = str(uuid.uuid4())
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await insert_owned(
            db,
            table="health_goals",
            record_id=record_id,
            values={
                "goal_type": "body",
                "metric_key": "body.weight_kg",
                "name": "History",
                "starts_on": "2026-08-01",
                "priority": 0,
                "status": "active",
                "revision": 1,
            },
            user=adult_a_user,
            record_sync_change=False,
        )
        await update_owned(
            db,
            table="health_goals",
            record_id=record_id,
            values={"name": "Updated"},
            user=adult_a_user,
            record_sync_change=False,
        )
        await soft_delete_owned(
            db,
            table="health_goals",
            record_id=record_id,
            user=adult_a_user,
            record_sync_change=False,
        )
        await soft_delete_owned(
            db,
            table="health_goals",
            record_id=record_id,
            user=adult_a_user,
            record_sync_change=False,
        )
        count = await (
            await db.execute(
                "SELECT COUNT(*) FROM record_history WHERE table_name = ? AND record_id = ?",
                ("health_goals", record_id),
            )
        ).fetchone()
        assert count[0] == 2


async def test_strength_parent_integrity_and_body_location_registry(client, adult_a_headers):
    locations = await client.get("/api/fitness/body-locations", headers=adult_a_headers)
    assert locations.status_code == 200, locations.text
    assert {item["location_key"] for item in locations.json()} == {
        "shoulder",
        "elbow",
        "wrist_hand",
        "upper_back",
        "lower_back",
        "hip_groin",
        "thigh",
        "knee",
        "calf_shin",
        "ankle",
        "foot",
        "other",
    }

    issue_body = {
        "observed_at_utc": "2026-08-02T12:00:00Z",
        "timing": "standalone",
        "issue_type_key": "pain",
        "body_location_key": "not-a-location",
        "side": "unknown",
        "severity_0_10": 2,
        "changed_session": False,
        "session_change_key": "none",
    }
    unknown = await client.post("/api/fitness/body-issues", headers=adult_a_headers, json=issue_body)
    assert unknown.status_code == 409

    exercise = (await client.get("/api/fitness/exercises", headers=adult_a_headers)).json()[0]
    setup = exercise["setups"][0]
    invalid_mode = await client.post(
        "/api/fitness/exercise-setups",
        headers=adult_a_headers,
        json={
            "exercise_id": exercise["id"],
            "name": "Invalid mode",
            "load_entry_mode": "whatever-the-client-says",
        },
    )
    assert invalid_mode.status_code == 422

    plan_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    planned_exercise_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    planned_set_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    for index in range(2):
        planned = await client.post(
            "/api/fitness/planned-sessions",
            headers=adult_a_headers,
            json={
                "id": plan_ids[index],
                "sport_key": "strength",
                "title": f"Plan {index + 1}",
                "local_timezone": "Europe/Berlin",
                "status": "accepted",
                "scheduled_date": date.today().isoformat(),
                "exercise_items": [
                    {
                        "id": planned_exercise_ids[index],
                        "exercise_id": exercise["id"],
                        "exercise_setup_id": setup["id"],
                        "sequence": 0,
                        "planned_sets": [
                            {
                                "id": planned_set_ids[index],
                                "sequence": 0,
                                "training_role": "working",
                                "reps_min": 5,
                                "reps_max": 8,
                            }
                        ],
                    }
                ],
            },
        )
        assert planned.status_code == 201, planned.text

    activity_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    session_exercise_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    active_started_at = datetime.now(timezone.utc).isoformat()
    for index in range(2):
        activity = await client.post(
            "/api/fitness/strength/sessions",
            headers=adult_a_headers,
            json={
                "id": activity_ids[index],
                "title": f"Session {index + 1}",
                "started_at_utc": active_started_at if index == 0 else "2026-08-02T10:00:00Z",
                "local_timezone": "Europe/Berlin",
                "planned_session_id": plan_ids[index],
                "status": "in_progress" if index == 0 else "completed",
            },
        )
        assert activity.status_code == 201, activity.text

    crossed_plan = await client.post(
        f"/api/fitness/strength/sessions/{activity_ids[0]}/exercises",
        headers=adult_a_headers,
        json={
            "activity_id": activity_ids[0],
            "exercise_id": exercise["id"],
            "exercise_setup_id": setup["id"],
            "planned_exercise_id": planned_exercise_ids[1],
            "sequence": 0,
        },
    )
    assert crossed_plan.status_code == 409

    for index in range(2):
        recorded = await client.post(
            f"/api/fitness/strength/sessions/{activity_ids[index]}/exercises",
            headers=adult_a_headers,
            json={
                "id": session_exercise_ids[index],
                "activity_id": activity_ids[index],
                "exercise_id": exercise["id"],
                "exercise_setup_id": setup["id"],
                "planned_exercise_id": planned_exercise_ids[index],
                "sequence": 0,
            },
        )
        assert recorded.status_code == 201, recorded.text

    wrong_planned_set = await client.post(
        f"/api/fitness/strength/session-exercises/{session_exercise_ids[0]}/set-groups",
        headers=adult_a_headers,
        json={
            "activity_id": activity_ids[0],
            "session_exercise_id": session_exercise_ids[0],
            "planned_set_id": planned_set_ids[1],
            "sequence": 0,
            "training_role": "working",
            "structure_type": "straight",
            "status": "completed",
        },
    )
    assert wrong_planned_set.status_code == 409

    group_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    for index in range(2):
        group = await client.post(
            f"/api/fitness/strength/session-exercises/{session_exercise_ids[index]}/set-groups",
            headers=adult_a_headers,
            json={
                "id": group_ids[index],
                "activity_id": activity_ids[index],
                "session_exercise_id": session_exercise_ids[index],
                "planned_set_id": planned_set_ids[index],
                "sequence": 0,
                "training_role": "working",
                "structure_type": "straight",
                "status": "completed",
            },
        )
        assert group.status_code == 201, group.text

    moved_group = await client.patch(
        f"/api/fitness/strength/set-groups/{group_ids[0]}",
        headers=adult_a_headers,
        json={
            "activity_id": activity_ids[1],
            "session_exercise_id": session_exercise_ids[1],
            "planned_set_id": planned_set_ids[1],
            "sequence": 0,
            "training_role": "working",
            "structure_type": "straight",
            "status": "completed",
        },
    )
    assert moved_group.status_code == 409

    component_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    for index in range(2):
        component = await client.post(
            f"/api/fitness/strength/set-groups/{group_ids[index]}/components",
            headers=adult_a_headers,
            json={
                "id": component_ids[index],
                "set_group_id": group_ids[index],
                "component_index": 0,
                "component_status": "completed",
                "reps": 6,
                "load_value": 50,
                "load_unit": "kg",
            },
        )
        assert component.status_code == 201, component.text
    moved_component = await client.patch(
        f"/api/fitness/strength/set-components/{component_ids[0]}",
        headers=adult_a_headers,
        json={
            "set_group_id": group_ids[1],
            "component_index": 0,
            "component_status": "completed",
            "reps": 6,
            "load_value": 50,
            "load_unit": "kg",
        },
    )
    assert moved_component.status_code == 409

    crossed_issue = await client.post(
        "/api/fitness/body-issues",
        headers=adult_a_headers,
        json={
            **issue_body,
            "body_location_key": "knee",
            "activity_id": activity_ids[0],
            "session_exercise_id": session_exercise_ids[1],
        },
    )
    assert crossed_issue.status_code == 409

    today = await client.get("/api/fitness/today", headers=adult_a_headers)
    assert today.status_code == 200, today.text
    assert today.json()["planned_session"]["id"] == plan_ids[0]
    assert today.json()["active_strength_session"]["exercises"][0]["set_groups"]
    assert {"nutrition", "weight_trend", "recovery", "recommendation"} <= set(today.json())
    progress = await client.get("/api/fitness/progress", headers=adult_a_headers)
    assert progress.status_code == 200, progress.text
    assert progress.json()["recent_activities"]
    assert progress.json()["exercise_progress"]
    assert progress.json()["overall_fitness_score"] is None
    assert progress.json()["estimated_1rm_headline"] is None


async def test_coach_preferences_are_private_bounded_and_need_no_extra_consent(
    client, adult_a_headers, adult_b_headers
):
    assert (await client.get("/api/fitness/coach/preferences", headers=adult_a_headers)).json()[
        "personality_preset"
    ] == "balanced_supportive"
    changed = await client.patch(
        "/api/fitness/coach/preferences",
        headers=adult_a_headers,
        json={
            "personality_preset": "scientific_hard_driving",
            "directness": 5,
            "challenge_bias": "ambitious",
            "detail_level": "detailed",
            "custom_instruction": "Lead with the evidence.",
        },
    )
    assert changed.status_code == 200, changed.text
    assert changed.json()["directness"] == 5
    kat = await client.get("/api/fitness/coach/preferences", headers=adult_b_headers)
    assert kat.json()["personality_preset"] == "balanced_supportive"
    invalid = await client.patch(
        "/api/fitness/coach/preferences",
        headers=adult_a_headers,
        json={
            "personality_preset": "custom",
            "directness": 6,
            "challenge_bias": "balanced",
            "detail_level": "standard",
        },
    )
    assert invalid.status_code == 422


async def test_export_is_owner_scoped_and_contains_only_durable_originals(
    client, adult_a_headers, adult_b_headers, monkeypatch, tmp_path
):
    storage = tmp_path / "health"
    cache = tmp_path / "cache"
    monkeypatch.setattr(settings, "fitness_storage_path", str(storage))
    monkeypatch.setattr(settings, "fitness_cache_path", str(cache))
    adult_a_asset, adult_b_asset = str(uuid.uuid4()), str(uuid.uuid4())
    for headers, asset_id, colour in (
        (adult_a_headers, adult_a_asset, "navy"),
        (adult_b_headers, adult_b_asset, "red"),
    ):
        uploaded = await client.post(
            "/api/fitness/files/private",
            headers=headers,
            data={"asset_id": asset_id, "asset_kind": "nutrition_label"},
            files={"file": ("../label.png", _png(colour), "image/png")},
        )
        assert uploaded.status_code == 201, uploaded.text
        food_id, version_id = str(uuid.uuid4()), str(uuid.uuid4())
        saved = await client.post(
            "/api/fitness/foods",
            headers=headers,
            json={
                "id": food_id,
                "name": f"{colour} food",
                "version": {
                    "id": version_id,
                    "reference_amount": 100,
                    "reference_unit": "g",
                    "calories_kcal": 100,
                    "label_asset_id": asset_id,
                },
            },
        )
        assert saved.status_code == 201, saved.text
    label = await client.get(f"/api/fitness/files/private/{adult_a_asset}", headers=adult_a_headers)
    assert label.status_code == 200
    assert "inline" in label.headers["content-disposition"]
    assert (
        await client.get(f"/api/fitness/files/private/{adult_a_asset}", headers=adult_b_headers)
    ).status_code == 404

    saved_chart_id = str(uuid.uuid4())
    saved_chart = await client.post(
        "/api/fitness/analysis/charts",
        headers=adult_a_headers,
        json={
            "id": saved_chart_id,
            "name": "My weight trend",
            "measure_key": "body.weight_trend_kg",
            "dimension_key": "date",
            "chart_type_key": "line",
            "filter_keys": [],
            "date_window_days": 90,
        },
    )
    assert saved_chart.status_code == 201, saved_chart.text

    response = await client.get("/api/fitness/export", headers=adult_a_headers)
    assert response.status_code == 200, response.text
    assert response.headers["content-disposition"] == (
        f'attachment; filename="hausklar-fitness-export-{date.today().isoformat()}.zip"'
    )
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        names = archive.namelist()
        assert any(adult_a_asset in name for name in names)
        assert not any(adult_b_asset in name for name in names)
        assert not any(".." in name for name in names)
        exported = json.loads(archive.read("fitness-data.json"))
        owners = {
            row["owner_user_id"]
            for rows in exported["tables"].values()
            for row in rows
            if "owner_user_id" in row
        }
        assert owners == {"00000000-0000-0000-0000-000000000001"}
        assert [row["id"] for row in exported["tables"]["health_saved_analysis_charts"]] == [
            saved_chart_id
        ]
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["normalized_streams_are_full_resolution"] is True
        assert manifest["included_normalized_stream_asset_ids"] == []
        assert manifest["excluded_regenerable_asset_kinds"] == [
            "garmin_workout",
            "photo_thumbnail",
        ]


async def test_private_image_limits_are_per_kind(client, adult_a_headers, monkeypatch, tmp_path):
    monkeypatch.setattr(settings, "fitness_storage_path", str(tmp_path / "health"))
    image = _png()
    monkeypatch.setattr(settings, "fitness_label_max_upload_bytes", len(image) - 1)
    monkeypatch.setattr(settings, "fitness_photo_max_upload_bytes", len(image) + 1)
    label = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": str(uuid.uuid4()), "asset_kind": "nutrition_label"},
        files={"file": ("label.png", image, "image/png")},
    )
    assert label.status_code == 413
    photo = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": str(uuid.uuid4()), "asset_kind": "progress_photo"},
        files={"file": ("photo.png", image, "image/png")},
    )
    assert photo.status_code == 201, photo.text
