"""Tests for meal ratings and meal recommendations."""

import aiosqlite


async def _create_meal(client, adult_a_headers, name: str, tags: list[str], prep_minutes: int = 20):
    resp = await client.post(
        "/api/meals/",
        json={"name": name, "tags": tags, "prep_minutes": prep_minutes},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    return resp.json()["id"]


async def _create_plan(client, adult_a_headers, meal_id: str, date: str, meal_type: str = "dinner"):
    resp = await client.post(
        "/api/meals/plan",
        json={"meal_id": meal_id, "date": date, "meal_type": meal_type},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    return resp.json()["id"]


async def test_submit_and_get_meal_ratings(client, adult_a_headers, child1, child2):
    meal_id = await _create_meal(client, adult_a_headers, "Chicken Pasta", ["chicken", "pasta", "fast"], 15)
    plan_id = await _create_plan(client, adult_a_headers, meal_id, "2026-02-12")

    rate_resp = await client.post(
        f"/api/meals/plan/{plan_id}/ratings",
        json={
            "ratings": [
                {"child_id": child1["id"], "rating": 3},
                {"child_id": child2["id"], "rating": 2},
            ],
            "tired_household": True,
        },
        headers=adult_a_headers,
    )
    assert rate_resp.status_code == 200
    payload = rate_resp.json()
    assert payload["id"] == plan_id
    assert payload["tired_household"] is True
    assert len(payload["ratings"]) == 2

    # Re-rate child2 to validate upsert semantics.
    rerate_resp = await client.post(
        f"/api/meals/plan/{plan_id}/ratings",
        json={"ratings": [{"child_id": child2["id"], "rating": 1}]},
        headers=adult_a_headers,
    )
    assert rerate_resp.status_code == 200

    get_resp = await client.get(f"/api/meals/plan/{plan_id}/ratings", headers=adult_a_headers)
    assert get_resp.status_code == 200
    ratings = get_resp.json()["ratings"]
    assert len(ratings) == 2
    child2_rating = next(r for r in ratings if r["child_id"] == child2["id"])
    assert child2_rating["rating"] == 1


async def test_meal_ratings_reject_other_family_child(
    client,
    adult_a_headers,
    initialized_db,
    second_family,
):
    other_child_id = "00000000-0000-0000-0000-000000000777"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, family_id) VALUES (?, ?, ?, ?)",
            (other_child_id, "Private Child", "2020-01-01", second_family["id"]),
        )
        await db.commit()

    meal_id = await _create_meal(client, adult_a_headers, "Family pasta", ["pasta"])
    plan_id = await _create_plan(client, adult_a_headers, meal_id, "2026-02-12")
    response = await client.post(
        f"/api/meals/plan/{plan_id}/ratings",
        json={"ratings": [{"child_id": other_child_id, "rating": 3}]},
        headers=adult_a_headers,
    )

    assert response.status_code == 422
    assert "not in this family" in response.json()["detail"]


async def test_meal_ratings_reject_duplicate_child(client, adult_a_headers, child1):
    meal_id = await _create_meal(client, adult_a_headers, "Family curry", ["curry"])
    plan_id = await _create_plan(client, adult_a_headers, meal_id, "2026-02-12")
    response = await client.post(
        f"/api/meals/plan/{plan_id}/ratings",
        json={
            "ratings": [
                {"child_id": child1["id"], "rating": 2},
                {"child_id": child1["id"], "rating": 3},
            ]
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 422


async def test_submit_breakfast_ratings(client, adult_a_headers, child1):
    meal_id = await _create_meal(client, adult_a_headers, "Porridge", ["mild", "fast"], 10)
    plan_id = await _create_plan(client, adult_a_headers, meal_id, "2026-02-13", meal_type="breakfast")

    rate_resp = await client.post(
        f"/api/meals/plan/{plan_id}/ratings",
        json={"ratings": [{"child_id": child1["id"], "rating": 3}]},
        headers=adult_a_headers,
    )
    assert rate_resp.status_code == 200
    payload = rate_resp.json()
    assert payload["meal_type"] == "breakfast"
    assert len(payload["ratings"]) == 1
    assert payload["ratings"][0]["rating"] == 3


async def test_rating_history_filters(client, adult_a_headers, child1):
    meal_a = await _create_meal(client, adult_a_headers, "Wraps", ["wrap", "fast"], 15)
    meal_b = await _create_meal(client, adult_a_headers, "Roast Beef", ["roast", "slow"], 70)
    plan_a = await _create_plan(client, adult_a_headers, meal_a, "2026-02-10")
    plan_b = await _create_plan(client, adult_a_headers, meal_b, "2026-02-11")

    await client.post(
        f"/api/meals/plan/{plan_a}/ratings",
        json={"ratings": [{"child_id": child1["id"], "rating": 3}]},
        headers=adult_a_headers,
    )
    await client.post(
        f"/api/meals/plan/{plan_b}/ratings",
        json={"ratings": [{"child_id": child1["id"], "rating": 1}]},
        headers=adult_a_headers,
    )

    hist = await client.get(
        f"/api/meals/ratings/history?child_id={child1['id']}&meal_id={meal_a}&start=2026-02-01&end=2026-02-10",
        headers=adult_a_headers,
    )
    assert hist.status_code == 200
    data = hist.json()
    assert len(data) == 1
    assert data[0]["rating"] == 3


async def test_recommendations_use_context(client, adult_a_headers, child1):
    fast_meal = await _create_meal(client, adult_a_headers, "Quick Pasta", ["pasta", "fast", "chicken"], 15)
    slow_meal = await _create_meal(client, adult_a_headers, "Sunday Roast", ["roast", "slow"], 80)

    # Historical ratings favour quick pasta.
    plan_hist = await _create_plan(client, adult_a_headers, fast_meal, "2026-02-10")
    await client.post(
        f"/api/meals/plan/{plan_hist}/ratings",
        json={"ratings": [{"child_id": child1["id"], "rating": 3}]},
        headers=adult_a_headers,
    )

    # Add a club/sport late event to drive context.
    event_resp = await client.post(
        "/api/calendar/",
        json={
            "title": "Football club",
            "start_time": "2026-02-12T16:30:00Z",
            "end_time": "2026-02-12T18:15:00Z",
            "event_type": "sport",
            "exertion": 3,
        },
        headers=adult_a_headers,
    )
    assert event_resp.status_code == 201

    ctx_resp = await client.get("/api/meals/recommendations/context?date=2026-02-12", headers=adult_a_headers)
    assert ctx_resp.status_code == 200
    context = ctx_resp.json()["context"]
    assert context["club_day"] is True
    assert context["high_exertion"] is True
    assert context["late_home"] is True
    assert context["dinner_time_bucket"] == "late"

    rec_resp = await client.get("/api/meals/recommendations?date=2026-02-12", headers=adult_a_headers)
    assert rec_resp.status_code == 200
    recs = rec_resp.json()["recommendations"]
    assert len(recs) >= 2

    # Fast meal should generally outrank slow roast for this context.
    by_id = {r["meal_id"]: r for r in recs}
    assert by_id[fast_meal]["score"] >= by_id[slow_meal]["score"]
