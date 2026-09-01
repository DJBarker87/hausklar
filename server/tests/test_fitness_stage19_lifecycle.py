"""Stage 19 owner-private and household-shared lifecycle contracts."""

import io
import json
import uuid
import zipfile

import aiosqlite
import pytest

from app.services.fitness.common import insert_owned


pytestmark = pytest.mark.asyncio


def _export_tables(response) -> dict[str, list[dict]]:
    assert response.status_code == 200, response.text
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        return json.loads(archive.read("fitness-data.json"))["tables"]


async def _linked_recipe(client, headers, *, prefix: str) -> dict[str, str]:
    food = await client.post(
        "/api/fitness/foods",
        headers=headers,
        json={
            "name": f"{prefix} ingredient",
            "household_shared": False,
            "version": {
                "reference_amount": 100,
                "reference_unit": "g",
                "calories_kcal": 360,
                "protein_g": 12,
            },
        },
    )
    assert food.status_code == 201, food.text
    food_id = food.json()["id"]
    food_version_id = food.json()["versions"][0]["id"]
    serving = await client.post(
        f"/api/fitness/foods/{food_id}/servings",
        headers=headers,
        json={
            "name": "Cup",
            "amount": 80,
            "unit": "g",
            "canonical_amount": 80,
            "canonical_unit": "g",
            "measurement_quality": "measured",
        },
    )
    assert serving.status_code == 201, serving.text

    recipe = await client.post(
        "/api/fitness/recipes",
        headers=headers,
        json={
            "name": f"{prefix} shared recipe",
            "household_shared": True,
            "version": {
                "servings": 4,
                "finished_weight_g": 400,
                "components": [
                    {
                        "food_version_id": food_version_id,
                        "amount": 100,
                        "unit": "g",
                        "canonical_amount": 100,
                        "canonical_unit": "g",
                    }
                ],
            },
        },
    )
    assert recipe.status_code == 201, recipe.text
    recipe_id = recipe.json()["id"]
    recipe_version_id = recipe.json()["versions"][0]["id"]
    component_id = recipe.json()["versions"][0]["components"][0]["id"]

    meal = await client.post(
        "/api/meals/",
        headers=headers,
        json={"name": f"{prefix} family dinner"},
    )
    assert meal.status_code == 201, meal.text
    meal_id = meal.json()["id"]
    link_id = str(uuid.uuid4())
    linked = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=headers,
        json={
            "id": link_id,
            "recipe_version_id": recipe_version_id,
            "client_id": f"{prefix}-phone",
        },
    )
    assert linked.status_code == 200, linked.text
    return {
        "food_id": food_id,
        "food_version_id": food_version_id,
        "serving_id": serving.json()["id"],
        "recipe_id": recipe_id,
        "recipe_version_id": recipe_version_id,
        "component_id": component_id,
        "meal_id": meal_id,
        "link_id": link_id,
    }


async def test_onboarding_and_household_meals_export_and_delete_with_correct_scope(
    client,
    adult_a_headers,
    adult_b_headers,
    other_family_headers,
    adult_a_user,
    adult_b_user,
    other_family_user,
    initialized_db,
):
    adult_a_profile = (await client.get("/api/fitness/onboarding", headers=adult_a_headers)).json()
    adult_b_profile = (await client.get("/api/fitness/onboarding", headers=adult_b_headers)).json()
    family_graph = await _linked_recipe(client, adult_a_headers, prefix="default")
    other_graph = await _linked_recipe(client, other_family_headers, prefix="other")

    adult_a_reminder_id, adult_b_reminder_id = str(uuid.uuid4()), str(uuid.uuid4())
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        for user, identifier, title in (
            (adult_a_user, adult_a_reminder_id, "Alex private reminder"),
            (adult_b_user, adult_b_reminder_id, "Morgan private reminder"),
        ):
            await insert_owned(
                db,
                table="health_fitness_reminders",
                record_id=identifier,
                values={
                    "title": title,
                    "remind_at_utc": "2026-08-05T17:00:00Z",
                    "status": "active",
                    "revision": 1,
                },
                user=user,
                record_sync_change=False,
            )
        await db.commit()

    private_food = await client.post(
        "/api/fitness/foods",
        headers=adult_a_headers,
        json={
            "name": "Alex only snack",
            "version": {
                "reference_amount": 1,
                "reference_unit": "item",
                "calories_kcal": 100,
            },
        },
    )
    assert private_food.status_code == 201, private_food.text
    private_food_id = private_food.json()["id"]

    adult_a_export = _export_tables(await client.get("/api/fitness/export", headers=adult_a_headers))
    adult_b_export = _export_tables(await client.get("/api/fitness/export", headers=adult_b_headers))
    for tables, own_profile_id, own_reminder_id in (
        (adult_a_export, adult_a_profile["id"], adult_a_reminder_id),
        (adult_b_export, adult_b_profile["id"], adult_b_reminder_id),
    ):
        assert [row["id"] for row in tables["health_onboarding_profiles"]] == [own_profile_id]
        assert [row["id"] for row in tables["health_household_meal_recipe_links"]] == [
            family_graph["link_id"]
        ]
        assert [row["id"] for row in tables["health_fitness_reminders"]] == [own_reminder_id]
        assert family_graph["recipe_id"] in {row["id"] for row in tables["health_recipes"]}
        assert family_graph["recipe_version_id"] in {
            row["id"] for row in tables["health_recipe_versions"]
        }
        assert other_graph["link_id"] not in {
            row["id"] for row in tables["health_household_meal_recipe_links"]
        }

    deleted_dom = await client.delete("/api/auth/me", headers=adult_a_headers)
    assert deleted_dom.status_code == 204, deleted_dom.text

    retained = await client.get("/api/fitness/household-meals", headers=adult_b_headers)
    assert retained.status_code == 200, retained.text
    assert [row["id"] for row in retained.json()] == [family_graph["link_id"]]
    transferred_recipe = await client.get(
        f"/api/fitness/recipes/{family_graph['recipe_id']}", headers=adult_b_headers
    )
    assert transferred_recipe.status_code == 200, transferred_recipe.text
    assert transferred_recipe.json()["versions"][0]["components"][0]["food_name"] == (
        "default ingredient"
    )

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        onboarding = await (
            await db.execute(
                "SELECT id, owner_user_id FROM health_onboarding_profiles WHERE family_id = ?",
                (adult_b_user["family_id"],),
            )
        ).fetchall()
        link = await (
            await db.execute(
                "SELECT * FROM health_household_meal_recipe_links WHERE id = ?",
                (family_graph["link_id"],),
            )
        ).fetchone()
        transferred_owners = {}
        for table, identifier in (
            ("health_recipes", family_graph["recipe_id"]),
            ("health_recipe_versions", family_graph["recipe_version_id"]),
            ("health_recipe_components", family_graph["component_id"]),
            ("health_foods", family_graph["food_id"]),
            ("health_food_versions", family_graph["food_version_id"]),
            ("health_food_servings", family_graph["serving_id"]),
        ):
            row = await (
                await db.execute(f"SELECT owner_user_id FROM {table} WHERE id = ?", (identifier,))
            ).fetchone()
            transferred_owners[table] = None if row is None else row[0]
        private_count = await (
            await db.execute("SELECT COUNT(*) FROM health_foods WHERE id = ?", (private_food_id,))
        ).fetchone()
        reminders = await (
            await db.execute(
                "SELECT id, owner_user_id FROM health_fitness_reminders WHERE family_id = ?",
                (adult_b_user["family_id"],),
            )
        ).fetchall()
    assert [(row["id"], row["owner_user_id"]) for row in onboarding] == [
        (adult_b_profile["id"], adult_b_user["id"])
    ]
    assert link is not None
    assert link["deleted_at"] is None
    assert link["created_by"] is None
    assert link["client_id"] is None
    assert set(transferred_owners.values()) == {adult_b_user["id"]}
    assert private_count[0] == 0
    assert [(row["id"], row["owner_user_id"]) for row in reminders] == [
        (adult_b_reminder_id, adult_b_user["id"])
    ]

    post_transfer_export = _export_tables(
        await client.get("/api/fitness/export", headers=adult_b_headers)
    )
    assert family_graph["link_id"] in {
        row["id"] for row in post_transfer_export["health_household_meal_recipe_links"]
    }
    assert family_graph["recipe_version_id"] in {
        row["id"] for row in post_transfer_export["health_recipe_versions"]
    }

    deleted_kat = await client.delete("/api/auth/me", headers=adult_b_headers)
    assert deleted_kat.status_code == 204, deleted_kat.text
    async with aiosqlite.connect(initialized_db) as db:
        default_link_count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_household_meal_recipe_links WHERE family_id = ?",
                (adult_b_user["family_id"],),
            )
        ).fetchone()
        default_profile_count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_onboarding_profiles WHERE family_id = ?",
                (adult_b_user["family_id"],),
            )
        ).fetchone()
        default_reminder_count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_fitness_reminders WHERE family_id = ?",
                (adult_b_user["family_id"],),
            )
        ).fetchone()
        other_link_count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_household_meal_recipe_links "
                "WHERE family_id = ? AND id = ?",
                (other_family_user["family_id"], other_graph["link_id"]),
            )
        ).fetchone()
    assert default_link_count[0] == 0
    assert default_profile_count[0] == 0
    assert default_reminder_count[0] == 0
    assert other_link_count[0] == 1
