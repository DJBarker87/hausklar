"""Tests for the meals router (/api/meals)."""

import json
from uuid import uuid4


# ---------------------------------------------------------------------------
# Meals — Create
# ---------------------------------------------------------------------------


async def test_create_meal(client, adult_a_headers):
    """POST /api/meals/ with valid data returns 201 and the new meal."""
    resp = await client.post(
        "/api/meals/",
        json={
            "name": "Spaghetti Bolognese",
            "description": "Classic Italian pasta",
            "recipe_url": "https://example.com/spag-bol",
            "tags": ["pasta", "italian"],
            "ingredients": [
                {"name": "spaghetti", "quantity": "500g", "category": "pasta"},
                {"name": "minced beef", "quantity": "400g", "category": "meat"},
            ],
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["name"] == "Spaghetti Bolognese"
    assert data["description"] == "Classic Italian pasta"
    assert data["recipe_url"] == "https://example.com/spag-bol"
    assert data["id"] is not None
    assert data["created_at"] is not None
    # tags and ingredients stored as JSON strings
    assert json.loads(data["tags"]) == ["pasta", "italian"]
    ingredients = json.loads(data["ingredients"])
    assert len(ingredients) == 2
    assert ingredients[0]["name"] == "spaghetti"


# ---------------------------------------------------------------------------
# Meals — List
# ---------------------------------------------------------------------------


async def test_list_meals(client, adult_a_headers):
    """GET /api/meals/ returns all non-deleted meals ordered by name."""
    await client.post(
        "/api/meals/",
        json={"name": "Banana Pancakes"},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/meals/",
        json={"name": "Avocado Toast"},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/meals/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 2
    names = [m["name"] for m in data]
    assert "Avocado Toast" in names
    assert "Banana Pancakes" in names
    # Verify alphabetical ordering
    assert names.index("Avocado Toast") < names.index("Banana Pancakes")


# ---------------------------------------------------------------------------
# Meals — Update
# ---------------------------------------------------------------------------


async def test_update_meal(client, adult_a_headers):
    """PUT /api/meals/{id} updates fields and returns the updated meal."""
    create_resp = await client.post(
        "/api/meals/",
        json={"name": "Original Meal", "description": "Old description"},
        headers=adult_a_headers,
    )
    meal_id = create_resp.json()["id"]

    resp = await client.put(
        f"/api/meals/{meal_id}",
        json={"name": "Updated Meal", "description": "New description"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["name"] == "Updated Meal"
    assert data["description"] == "New description"


# ---------------------------------------------------------------------------
# Meals — Delete
# ---------------------------------------------------------------------------


async def test_delete_meal(client, adult_a_headers):
    """DELETE /api/meals/{id} soft-deletes and returns 204."""
    create_resp = await client.post(
        "/api/meals/",
        json={"name": "Temporary Meal"},
        headers=adult_a_headers,
    )
    meal_id = create_resp.json()["id"]

    resp = await client.delete(f"/api/meals/{meal_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    # Meal should no longer appear in the list
    list_resp = await client.get("/api/meals/", headers=adult_a_headers)
    ids = [m["id"] for m in list_resp.json()]
    assert meal_id not in ids


# ---------------------------------------------------------------------------
# Meal Plans — Create
# ---------------------------------------------------------------------------


async def test_create_meal_plan(client, adult_a_headers):
    """POST /api/meals/plan creates a meal plan entry with joined meal_name."""
    # First create a meal
    meal_resp = await client.post(
        "/api/meals/",
        json={"name": "Fish Fingers"},
        headers=adult_a_headers,
    )
    meal_id = meal_resp.json()["id"]

    resp = await client.post(
        "/api/meals/plan",
        json={"meal_id": meal_id, "date": "2026-02-10", "meal_type": "dinner"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["meal_id"] == meal_id
    assert data["date"] == "2026-02-10"
    assert data["meal_type"] == "dinner"
    assert data["meal_name"] == "Fish Fingers"
    assert data["id"] is not None


async def test_create_meal_plan_rejects_other_family_meal(
    client,
    adult_a_headers,
    other_family_headers,
):
    other_meal = await client.post(
        "/api/meals/",
        json={"name": "Private other-family meal"},
        headers=other_family_headers,
    )

    response = await client.post(
        "/api/meals/plan",
        json={
            "meal_id": other_meal.json()["id"],
            "date": "2026-02-10",
            "meal_type": "dinner",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 422
    assert "not available" in response.json()["detail"]


# ---------------------------------------------------------------------------
# Meal Plans — List
# ---------------------------------------------------------------------------


async def test_list_meal_plans(client, adult_a_headers):
    """GET /api/meals/plan returns plans with optional date filtering."""
    # Create a meal
    meal_resp = await client.post(
        "/api/meals/",
        json={"name": "Porridge"},
        headers=adult_a_headers,
    )
    meal_id = meal_resp.json()["id"]

    # Create plans for different dates
    await client.post(
        "/api/meals/plan",
        json={"meal_id": meal_id, "date": "2026-02-09", "meal_type": "breakfast"},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/meals/plan",
        json={"meal_id": meal_id, "date": "2026-02-11", "meal_type": "lunch"},
        headers=adult_a_headers,
    )

    # List all
    resp = await client.get("/api/meals/plan", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 2

    # Filter by date range
    resp = await client.get(
        "/api/meals/plan?start=2026-02-09&end=2026-02-09",
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 1
    assert all(d["date"] == "2026-02-09" for d in data)


# ---------------------------------------------------------------------------
# Shopping Items — Create
# ---------------------------------------------------------------------------


async def test_create_shopping_item(client, adult_a_headers):
    """POST /api/meals/shopping creates a shopping item."""
    resp = await client.post(
        "/api/meals/shopping",
        json={"name": "Whole milk", "quantity": "2 pints", "category": "dairy"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["name"] == "Whole milk"
    assert data["quantity"] == "2 pints"
    assert data["category"] == "dairy"
    assert data["checked"] is False
    assert data["id"] is not None


async def test_shopping_item_create_is_idempotent_for_offline_replay(client, adult_a_headers):
    item_id = str(uuid4())
    payload = {
        "id": item_id,
        "name": "Whole milk",
        "quantity": "2 pints",
        "category": "dairy",
        "client_id": "pwa-offline",
        "client_timestamp": "2026-07-13T08:30:00Z",
    }

    first = await client.post("/api/meals/shopping", json=payload, headers=adult_a_headers)
    replay = await client.post("/api/meals/shopping", json=payload, headers=adult_a_headers)
    mismatch = await client.post(
        "/api/meals/shopping",
        json={**payload, "name": "Semi-skimmed milk"},
        headers=adult_a_headers,
    )

    assert first.status_code == 201
    assert replay.status_code == 201
    assert first.json() == replay.json()
    assert first.json()["id"] == item_id
    assert mismatch.status_code == 409

    items = await client.get("/api/meals/shopping", headers=adult_a_headers)
    assert [item["id"] for item in items.json()].count(item_id) == 1


# ---------------------------------------------------------------------------
# Shopping Items — Check (toggle)
# ---------------------------------------------------------------------------


async def test_check_shopping_item(client, adult_a_headers):
    """PATCH /api/meals/shopping/{id}/check toggles checked status."""
    # Create an item
    create_resp = await client.post(
        "/api/meals/shopping",
        json={"name": "Eggs"},
        headers=adult_a_headers,
    )
    item_id = create_resp.json()["id"]
    assert create_resp.json()["checked"] is False

    # Toggle to checked
    resp = await client.patch(
        f"/api/meals/shopping/{item_id}/check",
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["checked"] is True

    # Toggle back to unchecked
    resp = await client.patch(
        f"/api/meals/shopping/{item_id}/check",
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["checked"] is False


# ---------------------------------------------------------------------------
# Shopping Items — Generate from Meal Plans
# ---------------------------------------------------------------------------


async def test_generate_shopping_list(client, adult_a_headers):
    """POST /api/meals/shopping/generate creates items from meal plan ingredients."""
    # Create a meal with ingredients
    meal_resp = await client.post(
        "/api/meals/",
        json={
            "name": "Chicken Curry",
            "ingredients": [
                {"name": "chicken breast", "quantity": "500g", "category": "meat"},
                {"name": "curry paste", "quantity": "2 tbsp", "category": "spices"},
                {"name": "coconut milk", "quantity": "1 tin", "category": "tinned"},
            ],
        },
        headers=adult_a_headers,
    )
    meal_id = meal_resp.json()["id"]

    # Create a meal plan for that meal
    plan_resp = await client.post(
        "/api/meals/plan",
        json={"meal_id": meal_id, "date": "2026-02-12", "meal_type": "dinner"},
        headers=adult_a_headers,
    )
    plan_id = plan_resp.json()["id"]

    # Generate shopping list
    resp = await client.post(
        "/api/meals/shopping/generate?start=2026-02-12&end=2026-02-12",
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    items = resp.json()
    assert len(items) == 3

    item_names = [i["name"] for i in items]
    assert "chicken breast" in item_names
    assert "curry paste" in item_names
    assert "coconut milk" in item_names

    # Verify all items are linked to the meal plan
    assert all(i["meal_plan_id"] == plan_id for i in items)

    # Verify quantities and categories carried over
    chicken = next(i for i in items if i["name"] == "chicken breast")
    assert chicken["quantity"] == "500g"
    assert chicken["category"] == "meat"
    assert chicken["checked"] is False


async def test_delete_and_clear_shopping_items(client, adult_a_headers):
    first = await client.post(
        "/api/meals/shopping",
        json={"name": "Eggs"},
        headers=adult_a_headers,
    )
    second = await client.post(
        "/api/meals/shopping",
        json={"name": "Milk"},
        headers=adult_a_headers,
    )
    assert first.status_code == 201
    assert second.status_code == 201

    del_resp = await client.delete(
        f"/api/meals/shopping/{first.json()['id']}",
        headers=adult_a_headers,
    )
    assert del_resp.status_code == 204

    list_resp = await client.get("/api/meals/shopping", headers=adult_a_headers)
    assert list_resp.status_code == 200
    names = [item["name"] for item in list_resp.json()]
    assert "Eggs" not in names
    assert "Milk" in names

    clear_resp = await client.post("/api/meals/shopping/done-all", headers=adult_a_headers)
    assert clear_resp.status_code == 200
    assert clear_resp.json()["cleared"] >= 1

    list_after = await client.get("/api/meals/shopping", headers=adult_a_headers)
    assert list_after.status_code == 200
    assert list_after.json() == []


async def test_plan_shopping_preview_deduplicates_and_only_adds_reviewed_items(
    client,
    adult_a_headers,
):
    curry = await client.post(
        "/api/meals/",
        json={
            "name": "Curry",
            "ingredients": [
                {"name": "Coconut milk", "quantity": "1 tin", "category": "Tins"},
                {"name": "Spinach", "quantity": "200g", "category": "Rileys"},
            ],
        },
        headers=adult_a_headers,
    )
    soup = await client.post(
        "/api/meals/",
        json={
            "name": "Soup",
            "ingredients": [
                {"name": "Spinach", "quantity": "1 bag", "category": "Rileys"},
            ],
        },
        headers=adult_a_headers,
    )
    for meal in (curry.json(), soup.json()):
        await client.post(
            "/api/meals/plan",
            json={"meal_id": meal["id"], "date": "2026-08-10", "meal_type": "dinner"},
            headers=adult_a_headers,
        )
    await client.post(
        "/api/meals/shopping",
        json={"name": "Coconut milk"},
        headers=adult_a_headers,
    )

    preview = await client.get(
        "/api/meals/shopping/plan-diff?start=2026-08-10&end=2026-08-16",
        headers=adult_a_headers,
    )
    assert preview.status_code == 200
    items = {item["name"]: item for item in preview.json()["items"]}
    assert items["Coconut milk"]["already_on_list"] is True
    assert items["Spinach"]["quantity"] == "200g + 1 bag"
    assert len(items["Spinach"]["meal_plan_ids"]) == 2

    applied = await client.post(
        "/api/meals/shopping/plan-diff/apply",
        json={
            "start": "2026-08-10",
            "end": "2026-08-16",
            "keys": [items["Coconut milk"]["key"], items["Spinach"]["key"]],
        },
        headers=adult_a_headers,
    )
    assert applied.status_code == 200
    assert [item["name"] for item in applied.json()["created"]] == ["Spinach"]
    assert applied.json()["skipped"] == 1


async def test_recommendation_can_become_tonights_dinner_or_be_skipped(
    client,
    adult_a_headers,
):
    first = await client.post("/api/meals/", json={"name": "Tacos"}, headers=adult_a_headers)
    second = await client.post("/api/meals/", json={"name": "Risotto"}, headers=adult_a_headers)

    chosen = await client.post(
        f"/api/meals/recommendations/{first.json()['id']}/decision",
        json={"action": "plan_another_day", "date": "2026-08-15"},
        headers=adult_a_headers,
    )
    assert chosen.status_code == 200
    assert chosen.json()["plan"]["meal_name"] == "Tacos"
    assert chosen.json()["plan"]["date"] == "2026-08-15"

    skipped = await client.post(
        f"/api/meals/recommendations/{second.json()['id']}/decision",
        json={"action": "not_for_us"},
        headers=adult_a_headers,
    )
    assert skipped.status_code == 200
    assert skipped.json()["meal"]["not_for_us"] is True
    recommendations = await client.get(
        "/api/meals/recommendations?date=2026-08-15",
        headers=adult_a_headers,
    )
    assert second.json()["id"] not in {
        item["meal_id"] for item in recommendations.json()["recommendations"]
    }


async def test_recipe_preview_extracts_editable_fields(client, adult_a_headers):
    response = await client.post(
        "/api/meals/recipe-preview",
        json={
            "recipe_url": "https://example.com/chicken-noodle-soup",
            "text": "Chicken noodle soup\nServes 5\nPrep time: 25 minutes\n\nIngredients\n- 500g chicken\n- 2 cloves garlic\n- noodles\n\nMethod\nCook everything.",
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    assert response.json()["name"] == "Chicken noodle soup"
    assert response.json()["servings"] == 5
    assert response.json()["prep_minutes"] == 25
    assert response.json()["ingredients"][0] == {
        "name": "chicken",
        "quantity": "500g",
        "category": None,
    }
