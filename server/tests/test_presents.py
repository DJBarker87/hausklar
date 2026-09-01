"""Tests for the recipient-first gift planner."""
from datetime import date, datetime, timedelta, timezone

import aiosqlite


async def test_list_child_presents_has_default_occasions(client, adult_a_headers, child1):
    """GET returns christmas/birthday/easter even when no ideas exist."""
    resp = await client.get(f"/api/children/presents/{child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    occasions = [bucket["occasion"] for bucket in data["occasions"]]
    assert occasions == ["christmas", "birthday", "easter"]
    assert all(bucket["ideas"] == [] for bucket in data["occasions"])


async def test_create_present_idea_and_assignment(client, adult_a_headers, child1):
    """POST idea creates a present and stores assignment text."""
    resp = await client.post(
        "/api/children/presents/ideas",
        json={
            "child_id": child1["id"],
            "title": "Lego set",
            "occasion": "christmas",
            "assigned_to": "Morgan's parents",
            "notes": "Space theme",
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["title"] == "Lego set"
    assert data["occasion"] == "christmas"
    assert data["event_year"] == datetime.now(timezone.utc).year
    assert data["assigned_to"] == "Morgan's parents"
    assert data["scores"] == []

    list_resp = await client.get(f"/api/children/presents/{child1['id']}", headers=adult_a_headers)
    ideas = list_resp.json()["occasions"][0]["ideas"]
    assert len(ideas) == 1
    assert ideas[0]["title"] == "Lego set"


async def test_create_present_supports_a_custom_occasion(client, adult_a_headers, child1):
    """Real family occasions are not constrained to three hard-coded boards."""
    resp = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Scooter", "occasion": "summer"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    assert resp.json()["occasion"] == "summer"

    listed = await client.get(
        "/api/children/presents/ideas",
        params={"child_id": child1["id"], "occasion": "summer"},
        headers=adult_a_headers,
    )
    assert [idea["title"] for idea in listed.json()] == ["Scooter"]


async def test_dom_and_kat_can_score_idea(client, adult_a_headers, adult_b_headers, child1):
    """Each user can score 1-5 and both scores are returned."""
    create_resp = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Board game", "occasion": "birthday"},
        headers=adult_a_headers,
    )
    idea_id = create_resp.json()["id"]

    adult_a_score = await client.put(
        f"/api/children/presents/ideas/{idea_id}/score",
        json={"score": 4},
        headers=adult_a_headers,
    )
    assert adult_a_score.status_code == 200

    adult_b_score = await client.put(
        f"/api/children/presents/ideas/{idea_id}/score",
        json={"score": 5},
        headers=adult_b_headers,
    )
    assert adult_b_score.status_code == 200
    data = adult_b_score.json()
    assert round(data["average_score"], 2) == 4.5

    names_to_scores = {s["user_name"]: s["score"] for s in data["scores"]}
    assert names_to_scores["Alex"] == 4
    assert names_to_scores["Morgan"] == 5


async def test_score_out_of_range_400(client, adult_a_headers, child1):
    """Score must be between 1 and 5 inclusive."""
    create_resp = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Train set"},
        headers=adult_a_headers,
    )
    idea_id = create_resp.json()["id"]

    resp = await client.put(
        f"/api/children/presents/ideas/{idea_id}/score",
        json={"score": 6},
        headers=adult_a_headers,
    )
    assert resp.status_code == 400


async def test_delete_present_idea_soft_delete(client, adult_a_headers, child1):
    """DELETE idea removes it from listing."""
    create_resp = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Art supplies", "occasion": "easter"},
        headers=adult_a_headers,
    )
    idea_id = create_resp.json()["id"]

    del_resp = await client.delete(f"/api/children/presents/ideas/{idea_id}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    list_resp = await client.get(f"/api/children/presents/{child1['id']}", headers=adult_a_headers)
    easter_bucket = next(bucket for bucket in list_resp.json()["occasions"] if bucket["occasion"] == "easter")
    assert easter_bucket["ideas"] == []


async def test_presents_family_isolation(client, adult_a_headers, other_family_headers, child1):
    """Another family cannot access or score this family's present ideas."""
    create_resp = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Bike"},
        headers=adult_a_headers,
    )
    idea_id = create_resp.json()["id"]

    list_resp = await client.get(f"/api/children/presents/{child1['id']}", headers=other_family_headers)
    assert list_resp.status_code == 404

    score_resp = await client.put(
        f"/api/children/presents/ideas/{idea_id}/score",
        json={"score": 5},
        headers=other_family_headers,
    )
    assert score_resp.status_code == 404


async def test_presents_default_to_current_year_and_archive_previous(client, adult_a_headers, child1):
    """Default list is current year only; previous years are archived by default view."""
    current_year = datetime.now(timezone.utc).year
    previous_year = current_year - 1

    now_resp = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Current", "occasion": "christmas", "event_year": current_year},
        headers=adult_a_headers,
    )
    assert now_resp.status_code == 201

    old_resp = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Old", "occasion": "christmas", "event_year": previous_year},
        headers=adult_a_headers,
    )
    assert old_resp.status_code == 201

    default_list = await client.get(f"/api/children/presents/{child1['id']}", headers=adult_a_headers)
    default_christmas = next(b for b in default_list.json()["occasions"] if b["occasion"] == "christmas")
    assert [i["title"] for i in default_christmas["ideas"]] == ["Current"]

    old_list = await client.get(
        f"/api/children/presents/{child1['id']}",
        params={"year": previous_year},
        headers=adult_a_headers,
    )
    old_christmas = next(b for b in old_list.json()["occasions"] if b["occasion"] == "christmas")
    assert [i["title"] for i in old_christmas["ideas"]] == ["Old"]


async def test_occasion_board_groups_by_child(client, adult_a_headers, child1, child2, child3):
    """GET /occasion/{occasion} returns child columns with ideas for the selected year."""
    current_year = datetime.now(timezone.utc).year

    await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Lego", "occasion": "birthday", "event_year": current_year},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child2["id"], "title": "Book", "occasion": "birthday", "event_year": current_year},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/children/presents/occasion/birthday", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["occasion"] == "birthday"
    assert data["year"] == current_year
    assert len(data["children"]) == 3

    ideas_by_child = {c["child_id"]: [i["title"] for i in c["ideas"]] for c in data["children"]}
    assert ideas_by_child[child1["id"]] == ["Lego"]
    assert ideas_by_child[child2["id"]] == ["Book"]
    assert ideas_by_child[child3["id"]] == []


async def test_rich_gift_details_owner_birthday_and_filters(
    client, adult_a_headers, child1, adult_b_user
):
    birthday = await client.post(
        "/api/birthdays/",
        json={"person_name": "Child 1", "date_of_birth": "1989-01-05"},
        headers=adult_a_headers,
    )
    assert birthday.status_code == 201, birthday.text
    birthday_id = birthday.json()["id"]
    deadline = (date.today() + timedelta(days=10)).isoformat()

    created = await client.post(
        "/api/children/presents/ideas",
        json={
            "child_id": child1["id"],
            "title": "Blue bicycle",
            "occasion": "birthday",
            "birthday_id": birthday_id,
            "owner_id": adult_b_user["id"],
            "url": "https://example.com/bike",
            "retailer": "Bike shop",
            "budget_minor": 25000,
            "price_minor": 21999,
            "currency": "gbp",
            "deadline": deadline,
            "hiding_location": "Garage loft",
            "recipient_can_see": False,
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    idea = created.json()
    assert idea["recipient_name"] == "Child 1"
    assert idea["birthday_id"] == birthday_id
    assert idea["owner_id"] == adult_b_user["id"]
    assert idea["owner_name"] == "Morgan"
    assert idea["price_minor"] == 21999
    assert idea["currency"] == "GBP"
    assert idea["deadline"] == deadline
    assert idea["hiding_location"] == "Garage loft"
    assert idea["recipient_can_see"] is False

    filtered = await client.get(
        "/api/children/presents/ideas",
        params={"birthday_id": birthday_id},
        headers=adult_a_headers,
    )
    assert [item["id"] for item in filtered.json()] == [idea["id"]]


async def test_duplicate_warning_requires_explicit_override(client, adult_a_headers, child1):
    first = await client.post(
        "/api/children/presents/ideas",
        json={
            "child_id": child1["id"],
            "title": "Marble run",
            "url": "https://example.com/marble-run",
        },
        headers=adult_a_headers,
    )
    assert first.status_code == 201

    check = await client.post(
        "/api/children/presents/ideas/check-duplicate",
        json={"child_id": child1["id"], "title": "  MARBLE RUN  "},
        headers=adult_a_headers,
    )
    assert check.status_code == 200
    assert check.json()["matches"][0]["id"] == first.json()["id"]

    blocked = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Marble run"},
        headers=adult_a_headers,
    )
    assert blocked.status_code == 409

    allowed = await client.post(
        "/api/children/presents/ideas",
        json={
            "child_id": child1["id"],
            "title": "Marble run",
            "allow_duplicate": True,
        },
        headers=adult_a_headers,
    )
    assert allowed.status_code == 201


async def test_lifecycle_history_supports_advancing_and_correction(
    client, adult_a_headers, child1
):
    created = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Telescope"},
        headers=adult_a_headers,
    )
    idea_id = created.json()["id"]
    assert [item["to_status"] for item in created.json()["status_history"]] == [
        "idea"
    ]

    for lifecycle_status in ("bought", "arrived", "wrapped"):
        response = await client.patch(
            f"/api/children/presents/ideas/{idea_id}/status",
            json={"status": lifecycle_status},
            headers=adult_a_headers,
        )
        assert response.status_code == 200, response.text
    corrected = await client.put(
        f"/api/children/presents/ideas/{idea_id}",
        json={"status": "arrived", "price_minor": 4599},
        headers=adult_a_headers,
    )
    assert corrected.status_code == 200
    data = corrected.json()
    assert data["status"] == "arrived"
    assert data["price_minor"] == 4599
    assert [item["to_status"] for item in data["status_history"]] == [
        "idea",
        "bought",
        "arrived",
        "wrapped",
        "arrived",
    ]
    assert data["status_history"][-1]["from_status"] == "wrapped"


async def test_deleted_gift_can_be_restored_for_undo(client, adult_a_headers, child1):
    created = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": child1["id"], "title": "Art easel"},
        headers=adult_a_headers,
    )
    idea_id = created.json()["id"]
    assert (
        await client.delete(
            f"/api/children/presents/ideas/{idea_id}", headers=adult_a_headers
        )
    ).status_code == 204
    assert (
        await client.get(
            f"/api/children/presents/ideas/{idea_id}", headers=adult_a_headers
        )
    ).status_code == 404

    restored = await client.post(
        f"/api/children/presents/ideas/{idea_id}/restore", headers=adult_a_headers
    )
    assert restored.status_code == 200
    assert restored.json()["title"] == "Art easel"


async def test_typed_owner_and_birthday_are_family_scoped(
    client,
    adult_a_headers,
    child1,
    other_family_user,
):
    owner = await client.post(
        "/api/children/presents/ideas",
        json={
            "child_id": child1["id"],
            "title": "Camera",
            "owner_id": other_family_user["id"],
        },
        headers=adult_a_headers,
    )
    assert owner.status_code == 404


async def test_recipient_privacy_hides_unrevealed_gifts_from_matching_account(
    client,
    initialized_db,
    adult_a_headers,
    adult_b_headers,
    adult_b_user,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO children (id, name, date_of_birth, family_id) VALUES (?, ?, ?, ?)",
            (adult_b_user["id"], "Morgan", "1990-01-01", adult_b_user["family_id"]),
        )
        await db.commit()

    hidden = await client.post(
        "/api/children/presents/ideas",
        json={"child_id": adult_b_user["id"], "title": "Secret book"},
        headers=adult_a_headers,
    )
    assert hidden.status_code == 201
    idea_id = hidden.json()["id"]
    adult_b_list = await client.get(
        "/api/children/presents/ideas",
        params={"child_id": adult_b_user["id"]},
        headers=adult_b_headers,
    )
    assert adult_b_list.status_code == 200
    assert adult_b_list.json() == []
    assert (
        await client.get(
            f"/api/children/presents/ideas/{idea_id}", headers=adult_b_headers
        )
    ).status_code == 404

    revealed = await client.put(
        f"/api/children/presents/ideas/{idea_id}",
        json={"recipient_can_see": True},
        headers=adult_a_headers,
    )
    assert revealed.status_code == 200
    visible = await client.get(
        "/api/children/presents/ideas",
        params={"child_id": adult_b_user["id"]},
        headers=adult_b_headers,
    )
    assert [item["id"] for item in visible.json()] == [idea_id]
