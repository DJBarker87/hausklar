"""Household meal links are shared; each adult's diary remains private."""

import json
import uuid

import aiosqlite
import pytest

from app.database import init_db


pytestmark = pytest.mark.asyncio


async def test_legacy_food_diary_gains_planned_meal_provenance(db_path):
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "CREATE TABLE health_food_log_entries ("
            "id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, "
            "nutrition_date TEXT NOT NULL, logged_at_utc TEXT NOT NULL, "
            "deleted_at TEXT)"
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        columns = {
            row[1]
            for row in await (
                await db.execute("PRAGMA table_info(health_food_log_entries)")
            ).fetchall()
        }
        indexes = {
            row[1]
            for row in await (
                await db.execute("PRAGMA index_list(health_food_log_entries)")
            ).fetchall()
        }
        tables = {
            row[0]
            for row in await (
                await db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
            ).fetchall()
        }
    assert {"source_meal_plan_id", "household_meal_link_id"} <= columns
    assert "idx_health_food_log_owner_meal_plan" in indexes
    assert {
        "health_onboarding_profiles",
        "health_household_meal_recipe_links",
    } <= tables


async def _create_household_plan(client, headers):
    meal = await client.post(
        "/api/meals/",
        headers=headers,
        json={"name": "Monday pasta"},
    )
    assert meal.status_code == 201, meal.text
    meal_id = meal.json()["id"]
    plan = await client.post(
        "/api/meals/plan",
        headers=headers,
        json={
            "meal_id": meal_id,
            "date": "2026-08-03",
            "meal_type": "dinner",
        },
    )
    assert plan.status_code == 201, plan.text
    recipe = await client.post(
        "/api/fitness/recipes",
        headers=headers,
        json={
            "name": "Family pasta recipe",
            "household_shared": True,
            "version": {
                "servings": 4,
                "finished_weight_g": 800,
                "calories_kcal": 800,
                "protein_g": 80,
            },
        },
    )
    assert recipe.status_code == 201, recipe.text
    return meal_id, plan.json()["id"], recipe.json()["versions"][0]["id"]


async def test_household_link_visibility_and_private_idempotent_logging(
    client,
    adult_a_headers,
    adult_b_headers,
    other_family_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    meal_id, plan_id, recipe_version_id = await _create_household_plan(client, adult_a_headers)
    link_id = str(uuid.uuid4())
    linked = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=adult_a_headers,
        json={"id": link_id, "recipe_version_id": recipe_version_id},
    )
    assert linked.status_code == 200, linked.text
    link = linked.json()
    assert set(link) == {
        "id",
        "meal_id",
        "meal_name",
        "recipe_id",
        "recipe_version_id",
        "recipe_name",
        "linked_at",
    }
    assert link["id"] == link_id
    assert link["meal_id"] == meal_id
    assert link["recipe_version_id"] == recipe_version_id

    replayed_link = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=adult_b_headers,
        json={"recipe_version_id": recipe_version_id},
    )
    assert replayed_link.status_code == 200
    assert replayed_link.json() == link
    assert (await client.get("/api/fitness/household-meals", headers=adult_a_headers)).json() == [link]
    assert (await client.get("/api/fitness/household-meals", headers=adult_b_headers)).json() == [link]
    assert (
        await client.get("/api/fitness/household-meals", headers=other_family_headers)
    ).json() == []

    planned_dom = await client.get(
        "/api/fitness/planned-meals",
        params={"date": "2026-08-03"},
        headers=adult_a_headers,
    )
    planned_kat = await client.get(
        "/api/fitness/planned-meals",
        params={"date": "2026-08-03"},
        headers=adult_b_headers,
    )
    assert planned_dom.status_code == planned_kat.status_code == 200
    assert planned_dom.json() == planned_kat.json()
    assert len(planned_dom.json()) == 1
    planned = planned_dom.json()[0]
    assert set(planned) == {
        "meal_plan_id",
        "date",
        "meal_type",
        "meal_id",
        "meal_name",
        "link_id",
        "recipe_id",
        "recipe_version_id",
        "recipe_name",
        "suggested_portion",
        "suggested_unit",
    }
    assert planned["meal_plan_id"] == plan_id
    assert planned["suggested_portion"] == 1
    assert planned["suggested_unit"] == "serving"
    assert (
        await client.get(
            "/api/fitness/planned-meals",
            params={"date": "2026-08-04"},
            headers=adult_a_headers,
        )
    ).json() == []

    adult_a_entry_id = str(uuid.uuid4())
    adult_a_body = {
        "id": adult_a_entry_id,
        "portion": 1,
        "unit": "serving",
        "logged_at_utc": "2026-08-03T18:00:00Z",
        "local_timezone": "Europe/London",
        "notes": "Ate together",
        "client_id": "dom-phone",
        "client_timestamp": "2026-08-03T19:00:00+01:00",
    }
    adult_a_logged = await client.post(
        f"/api/fitness/planned-meals/{plan_id}/log",
        headers=adult_a_headers,
        json=adult_a_body,
    )
    assert adult_a_logged.status_code == 201, adult_a_logged.text
    assert adult_a_logged.json() == {
        "id": adult_a_entry_id,
        "source_meal_plan_id": plan_id,
        "household_meal_link_id": link_id,
        "recipe_version_id": recipe_version_id,
        "nutrition_date": "2026-08-03",
        "meal_type": "dinner",
        "logged_at_utc": "2026-08-03T18:00:00Z",
        "portion": 1.0,
        "unit": "serving",
        "calories_kcal": 200.0,
        "protein_g": 20.0,
    }
    adult_a_replay = await client.post(
        f"/api/fitness/planned-meals/{plan_id}/log",
        headers=adult_a_headers,
        json=adult_a_body,
    )
    assert adult_a_replay.status_code == 201, adult_a_replay.text
    assert adult_a_replay.json() == adult_a_logged.json()
    conflict = await client.post(
        f"/api/fitness/planned-meals/{plan_id}/log",
        headers=adult_a_headers,
        json={**adult_a_body, "id": str(uuid.uuid4())},
    )
    assert conflict.status_code == 409

    adult_b_entry_id = str(uuid.uuid4())
    adult_b_logged = await client.post(
        f"/api/fitness/planned-meals/{plan_id}/log",
        headers=adult_b_headers,
        json={
            "id": adult_b_entry_id,
            "portion": 100,
            "unit": "g",
            "logged_at_utc": "2026-08-03T18:30:00Z",
            "local_timezone": "Europe/London",
        },
    )
    assert adult_b_logged.status_code == 201, adult_b_logged.text
    assert adult_b_logged.json()["calories_kcal"] == 100
    assert adult_b_logged.json()["protein_g"] == 10

    adult_a_diary = await client.get(
        "/api/fitness/food-log",
        params={"date": "2026-08-03"},
        headers=adult_a_headers,
    )
    adult_b_diary = await client.get(
        "/api/fitness/food-log",
        params={"date": "2026-08-03"},
        headers=adult_b_headers,
    )
    assert [entry["id"] for entry in adult_a_diary.json()["entries"]] == [adult_a_entry_id]
    assert [entry["id"] for entry in adult_b_diary.json()["entries"]] == [adult_b_entry_id]
    assert adult_a_diary.json()["entries"][0]["source_meal_plan_id"] == plan_id
    assert adult_b_diary.json()["entries"][0]["source_meal_plan_id"] == plan_id

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT * FROM health_food_log_entries WHERE source_meal_plan_id = ? "
                "AND deleted_at IS NULL ORDER BY owner_user_id",
                (plan_id,),
            )
        ).fetchall()
        stored_link = await (
            await db.execute(
                "SELECT * FROM health_household_meal_recipe_links WHERE id = ?",
                (link_id,),
            )
        ).fetchone()
    assert {row["owner_user_id"] for row in rows} == {
        adult_a_user["id"],
        adult_b_user["id"],
    }
    assert all(row["household_meal_link_id"] == link_id for row in rows)
    assert [row["revision"] for row in rows] == [1, 1]
    assert stored_link["revision"] == 1

    removed = await client.delete(f"/api/fitness/food-log/{adult_a_entry_id}", headers=adult_a_headers)
    assert removed.status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        tombstone = await (
            await db.execute(
                "SELECT * FROM health_food_log_entries WHERE id = ?",
                (adult_a_entry_id,),
            )
        ).fetchone()
        history = await (
            await db.execute(
                "SELECT previous_values FROM record_history "
                "WHERE table_name = 'health_food_log_entries' AND record_id = ? "
                "ORDER BY changed_at DESC LIMIT 1",
                (adult_a_entry_id,),
            )
        ).fetchone()
    assert tombstone["deleted_at"] is not None
    assert tombstone["source_meal_plan_id"] == plan_id
    assert tombstone["household_meal_link_id"] == link_id
    snapshot = json.loads(history["previous_values"])
    assert snapshot["source_meal_plan_id"] == plan_id
    assert snapshot["household_meal_link_id"] == link_id

    unlinked = await client.delete(f"/api/fitness/household-meals/{meal_id}", headers=adult_a_headers)
    assert unlinked.status_code == 204
    assert (await client.get("/api/fitness/household-meals", headers=adult_b_headers)).json() == []
    assert (
        await client.get(
            "/api/fitness/planned-meals",
            params={"date": "2026-08-03"},
            headers=adult_b_headers,
        )
    ).json() == []
    adult_b_diary_after_unlink = await client.get(
        "/api/fitness/food-log",
        params={"date": "2026-08-03"},
        headers=adult_b_headers,
    )
    assert [entry["id"] for entry in adult_b_diary_after_unlink.json()["entries"]] == [adult_b_entry_id]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        link_tombstone = await (
            await db.execute(
                "SELECT * FROM health_household_meal_recipe_links WHERE id = ?",
                (link_id,),
            )
        ).fetchone()
    assert link_tombstone["deleted_at"] is not None
    assert link_tombstone["revision"] == 2


async def test_household_links_reject_foreign_unshared_and_unknown_ids(
    client,
    adult_a_headers,
    other_family_headers,
):
    meal_id, _plan_id, shared_version_id = await _create_household_plan(client, adult_a_headers)
    unshared = await client.post(
        "/api/fitness/recipes",
        headers=adult_a_headers,
        json={
            "name": "Alex's private recipe",
            "household_shared": False,
            "version": {"servings": 2, "calories_kcal": 500},
        },
    )
    assert unshared.status_code == 201
    unshared_version_id = unshared.json()["versions"][0]["id"]

    hidden_recipe = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=adult_a_headers,
        json={"recipe_version_id": unshared_version_id},
    )
    assert hidden_recipe.status_code == 404
    unknown_recipe = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=adult_a_headers,
        json={"recipe_version_id": str(uuid.uuid4())},
    )
    assert unknown_recipe.status_code == 404
    foreign_meal = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=other_family_headers,
        json={"recipe_version_id": shared_version_id},
    )
    assert foreign_meal.status_code == 404
    unknown_plan_log = await client.post(
        f"/api/fitness/planned-meals/{uuid.uuid4()}/log",
        headers=adult_a_headers,
        json={
            "id": str(uuid.uuid4()),
            "portion": 1,
            "unit": "serving",
            "logged_at_utc": "2026-08-03T18:00:00Z",
            "local_timezone": "Europe/London",
        },
    )
    assert unknown_plan_log.status_code == 404


async def test_relink_soft_deletes_old_immutable_link_and_keeps_diary_provenance(
    client,
    adult_a_headers,
    initialized_db,
):
    meal_id, plan_id, first_version_id = await _create_household_plan(client, adult_a_headers)
    first_link_id = str(uuid.uuid4())
    first_link = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=adult_a_headers,
        json={"id": first_link_id, "recipe_version_id": first_version_id},
    )
    assert first_link.status_code == 200
    entry_id = str(uuid.uuid4())
    logged = await client.post(
        f"/api/fitness/planned-meals/{plan_id}/log",
        headers=adult_a_headers,
        json={
            "id": entry_id,
            "portion": 1,
            "unit": "serving",
            "logged_at_utc": "2026-08-03T18:00:00Z",
            "local_timezone": "Europe/London",
        },
    )
    assert logged.status_code == 201, logged.text

    replacement_recipe = await client.post(
        "/api/fitness/recipes",
        headers=adult_a_headers,
        json={
            "name": "Updated family pasta recipe",
            "household_shared": True,
            "version": {"servings": 4, "calories_kcal": 1_000},
        },
    )
    assert replacement_recipe.status_code == 201
    replacement_version_id = replacement_recipe.json()["versions"][0]["id"]
    replacement_link_id = str(uuid.uuid4())
    replaced = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=adult_a_headers,
        json={
            "id": replacement_link_id,
            "recipe_version_id": replacement_version_id,
        },
    )
    assert replaced.status_code == 200, replaced.text
    assert replaced.json()["id"] == replacement_link_id
    assert replaced.json()["recipe_version_id"] == replacement_version_id
    planned = await client.get(
        "/api/fitness/planned-meals",
        params={"date": "2026-08-03"},
        headers=adult_a_headers,
    )
    assert planned.json()[0]["link_id"] == replacement_link_id

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        old_link = await (
            await db.execute(
                "SELECT * FROM health_household_meal_recipe_links WHERE id = ?",
                (first_link_id,),
            )
        ).fetchone()
        new_link = await (
            await db.execute(
                "SELECT * FROM health_household_meal_recipe_links WHERE id = ?",
                (replacement_link_id,),
            )
        ).fetchone()
        diary = await (
            await db.execute(
                "SELECT * FROM health_food_log_entries WHERE id = ?",
                (entry_id,),
            )
        ).fetchone()
    assert old_link["deleted_at"] is not None
    assert old_link["recipe_version_id"] == first_version_id
    assert new_link["deleted_at"] is None
    assert diary["household_meal_link_id"] == first_link_id
    assert diary["recipe_version_id"] == first_version_id

    changed_source = await client.put(
        f"/api/fitness/food-log/{entry_id}",
        headers=adult_a_headers,
        json={
            "recipe_version_id": replacement_version_id,
            "logged_at_utc": "2026-08-03T18:00:00Z",
            "local_timezone": "Europe/London",
            "meal_key": "dinner",
            "entered_amount": 1,
            "entered_unit": "serving",
            "canonical_amount": 1,
            "canonical_unit": "serving",
            "measurement_quality": "standard_serving",
        },
    )
    assert changed_source.status_code == 409
