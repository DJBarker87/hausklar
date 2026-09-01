"""Focused integration coverage for the private adult Fitness module."""

import uuid
from datetime import date, datetime, time, timezone
from zoneinfo import ZoneInfo

import aiosqlite
import pytest

from app.models.fitness import FoodVersionPayload
from app.services.account_deletion import HEALTH_OWNER_PRIVATE_TABLES
from app.services.fitness.nutrition import authoritative_calories, nutrition_date_for
from app.services.fitness.planning import _plan_occurs_on_local_day
from app.services.fitness.sync import cleanup_sync_state
from app.services.fitness.strength import estimated_one_rep_max, summarize_group


pytestmark = pytest.mark.asyncio


def _mutation(
    entity_type: str,
    entity_id: str,
    payload: dict,
    *,
    payload_version: int = 1,
    operation: str = "upsert",
) -> dict:
    return {
        "mutation_id": str(uuid.uuid4()),
        "entity_type": entity_type,
        "entity_id": entity_id,
        "operation": operation,
        "payload_schema_version": payload_version,
        "base_revision": None,
        "payload": payload,
        "created_at_client": "2026-08-02T10:00:00+00:00",
    }


def _sync_body(mutations: list[dict], *, cursor: int = 0) -> dict:
    return {
        "sync_protocol_version": 1,
        "client_schema_version": 1,
        "client_app_version": "1.0",
        "client_build": "1",
        "platform": "ios",
        "device_id": str(uuid.uuid4()),
        "cursor": cursor,
        "mutations": mutations,
    }


def _exercise_payload(name: str) -> dict:
    return {
        "name": name,
        "aliases": [],
        "movement_pattern_key": "squat",
        "measurement_mode": "reps_load",
        "rep_count_mode": "total",
        "load_entry_mode": "total_external",
        "default_unit": "kg",
        "unilateral_mode": "bilateral",
        "bodyweight_involved": False,
        "progression_direction": "higher",
        "favourite": False,
        "active": True,
        "muscle_roles": [
            {
                "muscle_group_key": "quadriceps",
                "role": "primary",
                "contribution_weight": 1.0,
            }
        ],
    }


def _assert_no_scope_fields(value) -> None:
    if isinstance(value, list):
        for item in value:
            _assert_no_scope_fields(item)
        return
    if not isinstance(value, dict):
        return
    assert not {
        "owner_user_id",
        "family_id",
        "created_by",
        "client_id",
        "client_timestamp",
    }.intersection(value)
    for item in value.values():
        _assert_no_scope_fields(item)


async def test_sync_payload_preflight_is_atomic(client, adult_a_headers, initialized_db):
    goal_id = str(uuid.uuid4())
    response = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body(
            [
                _mutation(
                    "goal",
                    goal_id,
                    {
                        "goal_type": "body",
                        "metric_key": "body.weight_kg",
                        "name": "Unsupported payload",
                        "starts_on": "2026-08-01",
                    },
                    payload_version=0,
                )
            ]
        ),
    )
    assert response.status_code == 426
    assert response.json()["status"] == "payload_upgrade_required"
    async with aiosqlite.connect(initialized_db) as db:
        for table in (
            "health_goals",
            "health_sync_mutation_receipts",
            "health_change_log",
        ):
            assert (await (await db.execute(f"SELECT COUNT(*) FROM {table}")).fetchone())[0] == 0


async def test_sync_bootstrap_and_food_batch_materialise_on_empty_client(client, adult_a_headers):
    bootstrap = await client.post("/api/fitness/sync", headers=adult_a_headers, json=_sync_body([]))
    assert bootstrap.status_code == 200, bootstrap.text
    payload = bootstrap.json()
    exercise_changes = [
        change
        for change in payload["changes"]
        if change["entity_type"] == "exercise" and change["operation"] == "upsert"
    ]
    assert exercise_changes
    assert exercise_changes[0]["data"]["setups"]
    assert exercise_changes[0]["data"]["muscle_roles"]
    _assert_no_scope_fields(payload["changes"])

    food_id = str(uuid.uuid4())
    version_id = str(uuid.uuid4())
    entry_id = str(uuid.uuid4())
    response = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body(
            [
                _mutation(
                    "food",
                    food_id,
                    {
                        "name": "Test oats",
                        "version": {
                            "id": version_id,
                            "reference_amount": 100,
                            "reference_unit": "g",
                            "calories_kcal": 400,
                            "protein_g": 12,
                        },
                    },
                ),
                _mutation(
                    "food_log_entry",
                    entry_id,
                    {
                        "food_version_id": version_id,
                        "logged_at_utc": "2026-08-02T08:00:00+00:00",
                        "local_timezone": "Europe/Berlin",
                        "meal_key": "breakfast",
                        "entered_amount": 50,
                        "entered_unit": "g",
                        "canonical_amount": 50,
                        "canonical_unit": "g",
                        "measurement_quality": "weighed",
                    },
                ),
            ],
            cursor=payload["next_cursor"],
        ),
    )
    assert response.status_code == 200, response.text
    changes = response.json()["changes"]
    food_change = next(
        change
        for change in reversed(changes)
        if change["entity_type"] == "food" and change["entity_id"] == food_id
    )
    assert food_change["data"]["current_version"]["id"] == version_id
    assert {item["id"] for item in food_change["data"]["versions"]} == {version_id}
    log_change = next(
        change
        for change in changes
        if change["entity_type"] == "food_log_entry" and change["entity_id"] == entry_id
    )
    assert log_change["data"]["calories_kcal"] == pytest.approx(200)
    _assert_no_scope_fields(changes)


async def test_owner_rows_and_client_uuid_collisions_are_private(client, adult_a_headers, adult_b_headers):
    exercise_id = str(uuid.uuid4())
    created = await client.post(
        "/api/fitness/exercises",
        headers=adult_a_headers,
        json={"id": exercise_id, **_exercise_payload("Alex-only squat")},
    )
    assert created.status_code == 201, created.text
    hidden = await client.get(f"/api/fitness/exercises/{exercise_id}", headers=adult_b_headers)
    assert hidden.status_code == 404
    collision = await client.post(
        "/api/fitness/exercises",
        headers=adult_b_headers,
        json={"id": exercise_id, **_exercise_payload("Guessed row")},
    )
    assert collision.status_code == 409


async def test_saved_food_quick_use_remembers_the_last_portion_not_an_average(
    client,
    adult_a_headers,
):
    food = await client.post(
        "/api/fitness/foods",
        headers=adult_a_headers,
        json={
            "name": "Adjustable yoghurt",
            "version": {
                "reference_amount": 100,
                "reference_unit": "g",
                "calories_kcal": 80,
                "protein_g": 9,
            },
        },
    )
    assert food.status_code == 201, food.text
    version_id = food.json()["versions"][0]["id"]
    for logged_at, amount in (
        ("2026-08-11T07:30:00Z", 50),
        ("2026-08-12T07:30:00Z", 80),
    ):
        response = await client.post(
            "/api/fitness/food-log",
            headers=adult_a_headers,
            json={
                "food_version_id": version_id,
                "logged_at_utc": logged_at,
                "local_timezone": "Europe/London",
                "meal_key": "breakfast",
                "entered_amount": amount,
                "entered_unit": "g",
                "canonical_amount": amount,
                "canonical_unit": "g",
                "measurement_quality": "weighed",
            },
        )
        assert response.status_code == 201, response.text

    listed = await client.get("/api/fitness/foods", headers=adult_a_headers)
    assert listed.status_code == 200, listed.text
    saved = next(item for item in listed.json() if item["id"] == food.json()["id"])
    assert saved["quick_use"]["last_logged_at_utc"].startswith("2026-08-12T07:30:00")
    assert saved["quick_use"]["frequency_count"] == 2
    assert saved["quick_use"]["last_amount"] == 80
    assert saved["quick_use"]["last_unit"] == "g"
    assert saved["quick_use"]["usual_amount"] == 80
    assert saved["quick_use"]["usual_unit"] == "g"


async def test_basic_foods_are_ready_to_log_and_shared_without_duplicates(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    initialized_db,
):
    first = await client.get("/api/fitness/foods", params={"q": "potato"}, headers=adult_a_headers)
    assert first.status_code == 200, first.text
    potatoes = next(item for item in first.json() if item["name"] == "Potatoes, boiled")
    assert potatoes["household_shared"] is True
    assert potatoes["editable"] is True
    expected_version = {
        "reference_amount": 100,
        "reference_unit": "g",
        "calories_kcal": 87,
        "protein_g": 1.9,
        "source_type": "reference",
        "confidence": "estimated",
    }
    assert {key: potatoes["current_version"][key] for key in expected_version} == expected_version
    assert potatoes["servings"][0]["name"] == "1 medium potato"
    assert potatoes["servings"][0]["canonical_amount"] == 170

    second = await client.get("/api/fitness/foods", params={"q": "potato"}, headers=adult_a_headers)
    assert second.status_code == 200, second.text
    assert [item["id"] for item in second.json()] == [item["id"] for item in first.json()]

    shared = await client.get("/api/fitness/foods", params={"q": "potato"}, headers=adult_b_headers)
    assert shared.status_code == 200, shared.text
    adult_b_potatoes = next(item for item in shared.json() if item["name"] == "Potatoes, boiled")
    assert adult_b_potatoes["id"] == potatoes["id"]
    assert adult_b_potatoes["editable"] is False

    async with aiosqlite.connect(initialized_db) as db:
        count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_foods WHERE family_id = ? "
                "AND LOWER(name) = 'potatoes, boiled' AND deleted_at IS NULL",
                (adult_a_user["family_id"],),
            )
        ).fetchone()
        owner = await (
            await db.execute(
                "SELECT owner_user_id FROM health_foods WHERE id = ?",
                (potatoes["id"],),
            )
        ).fetchone()
    assert count[0] == 1
    assert owner[0] == adult_a_user["id"]


async def test_sync_requires_explicit_setup_for_new_exercise(client, adult_a_headers, initialized_db):
    exercise_id = str(uuid.uuid4())
    response = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body([_mutation("exercise", exercise_id, _exercise_payload("No setup"))]),
    )
    assert response.status_code == 409
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute("SELECT 1 FROM health_exercises WHERE id = ?", (exercise_id,))
        ).fetchone()
        assert row is None


async def test_sync_sorts_exercise_before_its_single_explicit_setup(
    client, adult_a_headers, initialized_db
):
    exercise_id = str(uuid.uuid4())
    setup_id = str(uuid.uuid4())
    response = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body(
            [
                _mutation(
                    "exercise_setup",
                    setup_id,
                    {
                        "exercise_id": exercise_id,
                        "name": "Home rack",
                        "load_entry_mode": "total_external",
                        "is_default": True,
                        "active": True,
                    },
                ),
                _mutation("exercise", exercise_id, _exercise_payload("Home rack squat")),
            ]
        ),
    )
    assert response.status_code == 200, response.text
    async with aiosqlite.connect(initialized_db) as db:
        count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_exercise_setups WHERE exercise_id = ? "
                "AND active = 1 AND deleted_at IS NULL",
                (exercise_id,),
            )
        ).fetchone()
        assert count[0] == 1


async def test_sync_covers_goal_relationships_gear_activity_context_and_snapshot(
    client, adult_a_headers, adult_b_headers, initialized_db, adult_a_user
):
    goal_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    for index, goal_id in enumerate(goal_ids):
        created = await client.post(
            "/api/fitness/goals",
            headers=adult_a_headers,
            json={
                "id": goal_id,
                "goal_type": "running",
                "metric_key": f"running.goal_{index}",
                "name": f"Goal {index + 1}",
                "starts_on": "2026-08-01",
            },
        )
        assert created.status_code == 201, created.text

    activity_id = str(uuid.uuid4())
    activity = await client.post(
        "/api/fitness/strength/sessions",
        headers=adult_a_headers,
        json={
            "id": activity_id,
            "title": "Recorded strength",
            "started_at_utc": "2026-08-02T09:00:00+00:00",
            "ended_at_utc": "2026-08-02T10:00:00+00:00",
            "local_timezone": "Europe/London",
            "status": "completed",
        },
    )
    assert activity.status_code == 201, activity.text

    planned_goal_link_id = str(uuid.uuid4())
    async with aiosqlite.connect(initialized_db) as db:
        timestamp = "2026-08-02T10:30:00+00:00"
        await db.execute(
            "INSERT INTO health_activity_goal_links "
            "(id, owner_user_id, activity_id, goal_id, role, revision, family_id, "
            "created_at, updated_at, created_by) VALUES (?, ?, ?, ?, 'planned', 1, ?, ?, ?, ?)",
            (
                planned_goal_link_id,
                adult_a_user["id"],
                activity_id,
                goal_ids[0],
                adult_a_user["family_id"],
                timestamp,
                timestamp,
                adult_a_user["id"],
            ),
        )
        await db.commit()

    relationship_id = str(uuid.uuid4())
    gear_id = str(uuid.uuid4())
    link_id = str(uuid.uuid4())
    user_goal_link_id = str(uuid.uuid4())
    synced = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body(
            [
                _mutation(
                    "goal_relationship",
                    relationship_id,
                    {
                        "id": relationship_id,
                        "source_goal_id": goal_ids[0],
                        "target_goal_id": goal_ids[1],
                        "relationship": "supports",
                        "notes": "Aerobic consistency supports the race goal.",
                    },
                ),
                _mutation(
                    "gear",
                    gear_id,
                    {
                        "id": gear_id,
                        "gear_type_key": "lifting_shoes",
                        "name": "Lifters",
                        "active": True,
                    },
                ),
                _mutation(
                    "activity_context",
                    activity_id,
                    {
                        "id": activity_id,
                        "title": "Lower-body strength",
                        "notes": "Felt controlled.",
                        "session_rpe": 7,
                        "workout_classification": "steady",
                    },
                ),
                _mutation(
                    "activity_gear_link",
                    link_id,
                    {
                        "id": link_id,
                        "activity_id": activity_id,
                        "gear_id": gear_id,
                        "role": "primary",
                    },
                ),
                _mutation(
                    "activity_goal_link",
                    user_goal_link_id,
                    {
                        "id": user_goal_link_id,
                        "activity_id": activity_id,
                        "goal_id": goal_ids[1],
                        "role": "user_assigned",
                    },
                ),
            ]
        ),
    )
    assert synced.status_code == 200, synced.text
    payload = synced.json()
    assert {item["entity_id"] for item in payload["accepted"]} >= {
        relationship_id,
        gear_id,
        activity_id,
        link_id,
        user_goal_link_id,
    }
    assert {
        "goal_relationship",
        "gear",
        "activity_context",
        "activity_gear_link",
        "activity_goal_link",
    } <= {item["entity_type"] for item in payload["changes"]}
    cursor = payload["next_cursor"]

    relationships = await client.get("/api/fitness/goal-relationships", headers=adult_a_headers)
    assert relationships.status_code == 200
    assert relationships.json()[0]["id"] == relationship_id
    assert (await client.get("/api/fitness/goal-relationships", headers=adult_b_headers)).json() == []
    goal_links = await client.get(
        f"/api/fitness/activities/{activity_id}/goal-links", headers=adult_a_headers
    )
    assert goal_links.status_code == 200
    assert {(item["goal_id"], item["role"]) for item in goal_links.json()} == {
        (goal_ids[0], "planned"),
        (goal_ids[1], "user_assigned"),
    }
    kept = await client.put(
        f"/api/fitness/activities/{activity_id}/goal-links",
        headers=adult_a_headers,
        json={
            "links": [
                {"goal_id": goal_ids[1], "role": "user_assigned"},
            ]
        },
    )
    assert kept.status_code == 200, kept.text
    assert {(item["goal_id"], item["role"]) for item in kept.json()} == {
        (goal_ids[0], "planned"),
        (goal_ids[1], "user_assigned"),
    }

    patched = await client.patch(
        f"/api/fitness/activities/{activity_id}/context",
        headers=adult_a_headers,
        json={"notes": "Updated after review.", "session_rpe": 6.5},
    )
    assert patched.status_code == 200, patched.text
    pulled = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body([], cursor=cursor),
    )
    assert pulled.status_code == 200, pulled.text
    context_change = next(
        item
        for item in pulled.json()["changes"]
        if item["entity_type"] == "activity_context" and item["entity_id"] == activity_id
    )
    assert context_change["data"]["notes"] == "Updated after review."
    assert context_change["data"]["gear_ids"] == [gear_id]

    snapshot = await client.get("/api/fitness/sync/snapshot", headers=adult_a_headers)
    assert snapshot.status_code == 200, snapshot.text
    snapshot_entities = {
        (item["entity_type"], item["entity_id"]) for item in snapshot.json()["entities"]
    }
    assert {
        ("goal_relationship", relationship_id),
        ("gear", gear_id),
        ("activity_context", activity_id),
        ("activity_gear_link", link_id),
        ("activity_goal_link", planned_goal_link_id),
        ("activity_goal_link", user_goal_link_id),
    } <= snapshot_entities
    adult_b_snapshot = await client.get("/api/fitness/sync/snapshot", headers=adult_b_headers)
    assert adult_b_snapshot.status_code == 200
    assert not {
        relationship_id,
        gear_id,
        activity_id,
        link_id,
        planned_goal_link_id,
        user_goal_link_id,
    }.intersection({item["entity_id"] for item in adult_b_snapshot.json()["entities"]})
    cleared = await client.put(
        f"/api/fitness/activities/{activity_id}/goal-links",
        headers=adult_a_headers,
        json={"links": []},
    )
    assert cleared.status_code == 200, cleared.text
    assert [(item["goal_id"], item["role"]) for item in cleared.json()] == [
        (goal_ids[0], "planned")
    ]


async def test_expired_sync_cursor_requires_owner_snapshot(client, adult_a_headers, initialized_db):
    goal_id = str(uuid.uuid4())
    created = await client.post(
        "/api/fitness/goals",
        headers=adult_a_headers,
        json={
            "id": goal_id,
            "goal_type": "body",
            "metric_key": "body.weight_kg",
            "name": "Retained snapshot goal",
            "starts_on": "2026-08-01",
        },
    )
    assert created.status_code == 201, created.text
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_change_log SET changed_at = '2020-01-01T00:00:00+00:00' "
            "WHERE entity_type = 'goal' AND entity_id = ?",
            (goal_id,),
        )
        cleaned = await cleanup_sync_state(db, reference=datetime(2026, 8, 2, tzinfo=timezone.utc))
        await db.commit()
    assert cleaned["change_upserts"] == 1

    stale = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body([], cursor=0),
    )
    assert stale.status_code == 200, stale.text
    assert stale.json()["status"] == "full_snapshot_required"
    assert stale.json()["changes"] == []
    assert stale.json()["snapshot_url"] == "/api/fitness/sync/snapshot"

    snapshot = await client.get("/api/fitness/sync/snapshot", headers=adult_a_headers)
    assert snapshot.status_code == 200, snapshot.text
    assert ("goal", goal_id) in {
        (item["entity_type"], item["entity_id"]) for item in snapshot.json()["entities"]
    }
    resumed = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body([], cursor=snapshot.json()["next_cursor"]),
    )
    assert resumed.status_code == 200
    assert resumed.json()["status"] == "ok"


async def test_canonical_redirects_include_target_and_reviewable_attempt(client, adult_a_headers):
    source_id, target_id = str(uuid.uuid4()), str(uuid.uuid4())
    for identifier, name in ((source_id, "Rolled oats"), (target_id, "Porridge oats")):
        created = await client.post(
            "/api/fitness/foods",
            headers=adult_a_headers,
            json={"id": identifier, "name": name},
        )
        assert created.status_code == 201, created.text
    merged = await client.post(
        "/api/fitness/foods/merge",
        headers=adult_a_headers,
        json={"source_id": source_id, "target_id": target_id},
    )
    assert merged.status_code == 200, merged.text

    direct = await client.patch(
        f"/api/fitness/foods/{source_id}",
        headers=adult_a_headers,
        json={"name": "Attempted alias edit"},
    )
    assert direct.status_code == 409, direct.text
    detail = direct.json()["detail"]
    assert detail["code"] == "canonical_identity_changed"
    assert detail["target_id"] == target_id
    assert detail["target_summary"]["name"] == "Porridge oats"

    attempted = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_body(
            [
                _mutation(
                    "food",
                    source_id,
                    {"id": source_id, "name": "Offline alias edit"},
                )
            ]
        ),
    )
    assert attempted.status_code == 200, attempted.text
    rejected = attempted.json()["rejected_mutations"][0]
    assert rejected["code"] == "canonical_identity_changed"
    assert rejected["target_id"] == target_id
    assert rejected["target_summary"]["name"] == "Porridge oats"
    redirect = next(
        item for item in attempted.json()["redirects"] if item["source_id"] == source_id
    )
    assert redirect["target_summary"]["id"] == target_id
    notice = next(
        item for item in attempted.json()["notices"] if item["id"] == rejected["notice_id"]
    )
    assert notice["previous_values"]["attempted_fields"] == ["id", "name"]
    assert notice["previous_values"]["attempted_values"]["name"] == "Offline alias edit"


async def test_nutrition_and_strength_calculations_keep_fixed_semantics():
    kj_only = FoodVersionPayload(
        reference_amount=100,
        reference_unit="g",
        source_energy_value=836.8,
        source_energy_unit="kj",
    )
    assert authoritative_calories(kj_only) == pytest.approx(200)
    printed = kj_only.model_copy(update={"calories_kcal": 210})
    assert authoritative_calories(printed) == 210
    assert nutrition_date_for(
        datetime(2026, 3, 29, 1, 30, tzinfo=timezone.utc),
        "Europe/Berlin",
        240,
    ) == date(2026, 3, 28)

    group = {
        "status": "completed",
        "training_role": "working",
        "structure_type": "drop",
        "failure_state": "none",
    }
    components = [
        {
            "component_status": "completed",
            "reps": 10,
            "normalized_external_load_kg": 50,
            "rir": None,
            "rpe": None,
        },
        {
            "component_status": "partial",
            "reps": 5,
            "normalized_external_load_kg": 40,
            "rir": None,
            "rpe": 7,
        },
        {
            "component_status": "skipped",
            "reps": 20,
            "normalized_external_load_kg": 100,
            "rir": 0,
            "rpe": 10,
        },
    ]
    summary = summarize_group(group, components)
    assert summary["working_sets"] == 1
    assert summary["hard_sets"] == 1
    assert summary["primary_volume_kg"] == pytest.approx(700)
    assert (
        summarize_group({**group, "training_role": "warmup"}, components)["primary_volume_kg"] == 0
    )
    unknown = summarize_group(group, [components[0]])
    assert unknown["hard_sets"] == 0
    assert unknown["unknown_hardness_sets"] == 1

    straight = {**group, "structure_type": "straight"}
    near_hard = {
        "component_status": "completed",
        "reps": 5,
        "normalized_external_load_kg": 100,
        "load_entry_mode_snapshot": "total_external",
        "rir": 2,
        "rpe": None,
    }
    assert estimated_one_rep_max(straight, near_hard) == pytest.approx(100 * (1 + 7 / 30))
    assert estimated_one_rep_max(straight, {**near_hard, "reps": 9}) is None
    assert estimated_one_rep_max({**straight, "is_amrap": True}, {**near_hard, "rir": None}) is None


async def test_today_match_uses_owner_local_dst_day():
    zone = ZoneInfo("Europe/Berlin")
    day = date(2026, 3, 29)
    local_start = datetime.combine(day, time.min, tzinfo=zone)
    local_end = datetime.combine(date(2026, 3, 30), time.min, tzinfo=zone)
    assert (
        local_end.astimezone(timezone.utc) - local_start.astimezone(timezone.utc)
    ).total_seconds() == 23 * 3600
    assert _plan_occurs_on_local_day(
        {"scheduled_start_utc": "2026-03-29T21:30:00+00:00"},
        day=day,
        zone=zone,
        day_start_utc=local_start.astimezone(timezone.utc),
        day_end_utc=local_end.astimezone(timezone.utc),
    )
    assert not _plan_occurs_on_local_day(
        {"scheduled_start_utc": "2026-03-29T22:30:00+00:00"},
        day=day,
        zone=zone,
        day_start_utc=local_start.astimezone(timezone.utc),
        day_end_utc=local_end.astimezone(timezone.utc),
    )


async def test_workout_versions_are_immutable_and_copy_substitutions(client, adult_a_headers):
    exercises = (await client.get("/api/fitness/exercises", headers=adult_a_headers)).json()
    primary, substitute = exercises[:2]
    definition_id = str(uuid.uuid4())
    version_id = str(uuid.uuid4())
    workout_exercise_id = str(uuid.uuid4())
    planned_set_id = str(uuid.uuid4())
    created = await client.post(
        "/api/fitness/strength/templates",
        headers=adult_a_headers,
        json={
            "id": definition_id,
            "sport_key": "strength",
            "name": "Lower A",
            "version": {
                "id": version_id,
                "title": "Lower A v1",
                "exercise_items": [
                    {
                        "id": workout_exercise_id,
                        "exercise_id": primary["id"],
                        "exercise_setup_id": primary["setups"][0]["id"],
                        "sequence": 0,
                        "substitution_exercise_ids": [substitute["id"]],
                        "planned_sets": [
                            {
                                "id": planned_set_id,
                                "sequence": 0,
                                "training_role": "working",
                                "structure_type": "drop",
                                "component_count": 4,
                                "reps_min": 8,
                                "reps_max": 10,
                            }
                        ],
                    }
                ],
            },
        },
    )
    assert created.status_code == 201, created.text
    second_id = str(uuid.uuid4())
    second = await client.post(
        f"/api/fitness/strength/templates/{definition_id}/versions",
        headers=adult_a_headers,
        json={"id": second_id, "title": "Lower A v2", "exercise_items": []},
    )
    assert second.status_code == 201, second.text
    templates = (await client.get("/api/fitness/strength/templates", headers=adult_a_headers)).json()
    template = next(item for item in templates if item["id"] == definition_id)
    assert [version["title"] for version in template["versions"]] == [
        "Lower A v2",
        "Lower A v1",
    ]
    copied = await client.post(
        f"/api/fitness/strength/templates/{definition_id}/copy",
        params={"version_id": version_id},
        headers=adult_a_headers,
    )
    assert copied.status_code == 200, copied.text
    copied_item = copied.json()["exercise_items"][0]
    assert copied_item["id"] != workout_exercise_id
    assert copied_item["planned_sets"][0]["id"] != planned_set_id
    assert copied_item["planned_sets"][0]["component_count"] == 4
    assert copied_item["substitution_exercise_ids"] == [substitute["id"]]


async def test_account_deletion_purges_only_the_departing_adults_fitness(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    for headers, name in ((adult_a_headers, "Alex goal"), (adult_b_headers, "Morgan goal")):
        goal = await client.post(
            "/api/fitness/goals",
            headers=headers,
            json={
                "goal_type": "body",
                "metric_key": "body.weight_kg",
                "name": name,
                "starts_on": "2026-08-01",
            },
        )
        assert goal.status_code == 201, goal.text
        assert (await client.get("/api/fitness/exercises", headers=headers)).status_code == 200
        assert (
            await client.put(
                "/api/fitness/coach/memory/settings",
                headers=headers,
                json={"enabled": True},
            )
        ).status_code == 200
        assert (
            await client.post(
                "/api/fitness/coach/conversations",
                headers=headers,
                json={"title": f"{name} private Coach thread"},
            )
        ).status_code == 201
        assert (
            await client.post(
                "/api/fitness/coach/memories",
                headers=headers,
                json={"content": f"{name} private confirmed memory."},
            )
        ).status_code == 201

    assert (await client.delete("/api/auth/me", headers=adult_a_headers)).status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        for table in HEALTH_OWNER_PRIVATE_TABLES:
            count = await (
                await db.execute(
                    f"SELECT COUNT(*) FROM {table} WHERE owner_user_id = ?",
                    (adult_a_user["id"],),
                )
            ).fetchone()
            assert count[0] == 0, table
        adult_b_rows = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_exercises WHERE owner_user_id = ?",
                (adult_b_user["id"],),
            )
        ).fetchone()
        assert adult_b_rows[0] > 0
        adult_b_coach_rows = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_coach_memories WHERE owner_user_id = ?",
                (adult_b_user["id"],),
            )
        ).fetchone()
        assert adult_b_coach_rows[0] == 1

    assert (await client.delete("/api/auth/me", headers=adult_b_headers)).status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        for table in HEALTH_OWNER_PRIVATE_TABLES:
            count = await (
                await db.execute(
                    f"SELECT COUNT(*) FROM {table} WHERE family_id = ?",
                    (adult_b_user["family_id"],),
                )
            ).fetchone()
            assert count[0] == 0, table
