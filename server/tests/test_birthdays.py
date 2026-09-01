"""Tests for the birthdays router (/api/birthdays)."""

from datetime import date, timedelta

from app.services.birthdays import birthday_in_year, current_age, next_birthday, turning_age


# ---------------------------------------------------------------------------
# Create birthday
# ---------------------------------------------------------------------------


async def test_create_birthday(client, adult_a_user, adult_a_headers):
    """POST /api/birthdays creates a new birthday entry."""
    payload = {
        "person_name": "Grandma",
        "date_of_birth": "1955-06-15",
        "relationship": "family",
        "reminder_days_before": 14,
    }
    resp = await client.post("/api/birthdays/", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["person_name"] == "Grandma"
    assert data["date_of_birth"] == "1955-06-15"
    assert data["relationship"] == "family"
    assert data["reminder_days_before"] == 14
    assert data["created_by"] == adult_a_user["id"]
    assert "id" in data
    assert "created_at" in data
    assert "updated_at" in data
    assert "age" in data
    assert "turning_age" in data
    assert "next_birthday" in data
    assert "days_until" in data


# ---------------------------------------------------------------------------
# List birthdays
# ---------------------------------------------------------------------------


async def test_list_birthdays(client, adult_a_user, adult_a_headers):
    """GET /api/birthdays returns birthdays that have been created."""
    payload = {
        "person_name": "Uncle Bob",
        "date_of_birth": "1980-03-20",
        "relationship": "family",
    }
    create_resp = await client.post("/api/birthdays/", json=payload, headers=adult_a_headers)
    assert create_resp.status_code == 201

    resp = await client.get("/api/birthdays/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 1
    names = [b["person_name"] for b in data]
    assert "Uncle Bob" in names


# ---------------------------------------------------------------------------
# Age calculation
# ---------------------------------------------------------------------------


async def test_age_calculation(client, adult_a_user, adult_a_headers):
    """Create a birthday with a known DOB and verify the age is correct."""
    today = date.today()
    # Someone born exactly 30 years ago today
    dob = today.replace(year=today.year - 30)
    payload = {
        "person_name": "Age Test Person",
        "date_of_birth": dob.isoformat(),
        "relationship": "friend",
    }
    resp = await client.post("/api/birthdays/", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["age"] == 30
    assert data["turning_age"] == 30

    # Someone whose birthday is tomorrow — they haven't had their birthday yet this year
    dob_tomorrow = today + timedelta(days=1)
    dob_tomorrow_30 = dob_tomorrow.replace(year=dob_tomorrow.year - 30)
    payload2 = {
        "person_name": "Almost 30",
        "date_of_birth": dob_tomorrow_30.isoformat(),
        "relationship": "friend",
    }
    resp2 = await client.post("/api/birthdays/", json=payload2, headers=adult_a_headers)
    assert resp2.status_code == 201
    data2 = resp2.json()
    # Birthday hasn't happened yet this year, so still 29
    assert data2["age"] == 29
    assert data2["turning_age"] == 30


def test_leap_day_birthday_uses_consistent_observed_date_and_age():
    dob = date(2000, 2, 29)
    observed = date(2025, 2, 28)

    assert birthday_in_year(dob, 2025) == observed
    assert next_birthday(dob, observed) == observed
    assert current_age(dob, observed) == 25
    assert turning_age(dob, observed) == 25


async def test_leap_day_birthday_endpoint_does_not_fail(client, adult_a_headers):
    response = await client.post(
        "/api/birthdays/",
        json={"person_name": "Leapling", "date_of_birth": "2000-02-29"},
        headers=adult_a_headers,
    )

    assert response.status_code == 201
    data = response.json()
    assert data["next_birthday"][5:] in {"02-28", "02-29"}
    assert data["turning_age"] >= data["age"]


# ---------------------------------------------------------------------------
# Upcoming filter
# ---------------------------------------------------------------------------


async def test_upcoming_filter(client, adult_a_user, adult_a_headers):
    """Filter birthdays by upcoming_days returns only those within the window."""
    today = date.today()

    # Birthday in 3 days
    soon_dob_date = today + timedelta(days=3)
    soon_dob = soon_dob_date.replace(year=soon_dob_date.year - 25)

    # Birthday in 60 days
    far_dob_date = today + timedelta(days=60)
    far_dob = far_dob_date.replace(year=far_dob_date.year - 40)

    await client.post(
        "/api/birthdays/",
        json={"person_name": "Soon Birthday", "date_of_birth": soon_dob.isoformat()},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/birthdays/",
        json={"person_name": "Far Birthday", "date_of_birth": far_dob.isoformat()},
        headers=adult_a_headers,
    )

    # Filter to next 7 days
    resp = await client.get(
        "/api/birthdays/",
        params={"upcoming_days": 7},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    names = [b["person_name"] for b in data]
    assert "Soon Birthday" in names
    assert "Far Birthday" not in names


# ---------------------------------------------------------------------------
# Update birthday
# ---------------------------------------------------------------------------


async def test_update_birthday(client, adult_a_user, adult_a_headers):
    """PUT /api/birthdays/{id} updates an existing birthday."""
    payload = {
        "person_name": "Original Name",
        "date_of_birth": "1990-01-01",
        "relationship": "friend",
    }
    create_resp = await client.post("/api/birthdays/", json=payload, headers=adult_a_headers)
    birthday_id = create_resp.json()["id"]

    update_resp = await client.put(
        f"/api/birthdays/{birthday_id}",
        json={"person_name": "Updated Name", "relationship": "family"},
        headers=adult_a_headers,
    )
    assert update_resp.status_code == 200
    data = update_resp.json()
    assert data["person_name"] == "Updated Name"
    assert data["relationship"] == "family"
    # Unchanged fields should remain
    assert data["date_of_birth"] == "1990-01-01"


# ---------------------------------------------------------------------------
# Delete birthday
# ---------------------------------------------------------------------------


async def test_delete_birthday(client, adult_a_user, adult_a_headers):
    """DELETE /api/birthdays/{id} soft-deletes the birthday (204)."""
    payload = {
        "person_name": "To Be Deleted",
        "date_of_birth": "1985-12-25",
    }
    create_resp = await client.post("/api/birthdays/", json=payload, headers=adult_a_headers)
    birthday_id = create_resp.json()["id"]

    del_resp = await client.delete(f"/api/birthdays/{birthday_id}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    # Verify it no longer appears in GET
    list_resp = await client.get("/api/birthdays/", headers=adult_a_headers)
    ids = [b["id"] for b in list_resp.json()]
    assert birthday_id not in ids


async def test_unknown_birth_year_keeps_date_without_inventing_an_age(client, adult_a_headers):
    response = await client.post(
        "/api/birthdays/",
        json={"person_name": "Aunt Jo", "birth_month": 11, "birth_day": 4},
        headers=adult_a_headers,
    )

    assert response.status_code == 201
    birthday = response.json()
    assert birthday["date_of_birth"] is None
    assert birthday["birth_month"] == 11
    assert birthday["birth_day"] == 4
    assert birthday["year_known"] is False
    assert birthday["age"] is None
    assert birthday["turning_age"] is None


async def test_duplicate_can_be_reviewed_and_explicitly_kept(client, adult_a_headers):
    payload = {"person_name": "Grandad", "birth_month": 5, "birth_day": 12}
    first = await client.post("/api/birthdays/", json=payload, headers=adult_a_headers)
    duplicate = await client.post("/api/birthdays/", json=payload, headers=adult_a_headers)
    kept = await client.post(
        "/api/birthdays/",
        json={**payload, "allow_duplicate": True},
        headers=adult_a_headers,
    )

    assert first.status_code == 201
    assert duplicate.status_code == 409
    assert kept.status_code == 201


async def test_removed_birthday_can_be_restored(client, adult_a_headers):
    created = await client.post(
        "/api/birthdays/",
        json={"person_name": "Restore Me", "date_of_birth": "1988-08-09"},
        headers=adult_a_headers,
    )
    birthday_id = created.json()["id"]

    assert (
        await client.delete(f"/api/birthdays/{birthday_id}", headers=adult_a_headers)
    ).status_code == 204
    restored = await client.post(
        f"/api/birthdays/{birthday_id}/restore", headers=adult_a_headers
    )

    assert restored.status_code == 200
    assert restored.json()["person_name"] == "Restore Me"


async def test_paste_import_is_reviewed_and_marks_existing_people(client, adult_a_headers):
    await client.post(
        "/api/birthdays/",
        json={"person_name": "Grandma", "date_of_birth": "1955-06-15"},
        headers=adult_a_headers,
    )
    response = await client.post(
        "/api/birthdays/import-preview",
        json={"text": "Grandma, 15 June 1955\nCoach, 03/09\nnot enough detail"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    drafts = response.json()["drafts"]
    assert drafts[0]["duplicate_id"] is not None
    assert drafts[1]["date_of_birth"] is None
    assert (drafts[1]["birth_month"], drafts[1]["birth_day"]) == (9, 3)
    assert drafts[2]["issue"]


async def test_birthday_preparation_connects_card_task_and_planner(client, adult_a_headers):
    created = await client.post(
        "/api/birthdays/",
        json={"person_name": "Nana", "birth_month": 10, "birth_day": 20},
        headers=adult_a_headers,
    )
    birthday_id = created.json()["id"]

    saved = await client.put(
        f"/api/birthdays/{birthday_id}/preparation",
        json={
            "card_status": "written",
            "card_message": "With lots of love",
            "celebration_status": "planning",
        },
        headers=adult_a_headers,
    )
    task = await client.post(
        f"/api/birthdays/{birthday_id}/preparation/task",
        json={"title": "Post Nana's card", "due_days_before": 5},
        headers=adult_a_headers,
    )
    event = await client.post(
        f"/api/birthdays/{birthday_id}/preparation/event",
        json={},
        headers=adult_a_headers,
    )

    assert saved.status_code == 200
    assert saved.json()["card_status"] == "written"
    assert task.status_code == 200
    assert task.json()["tasks"][0]["title"] == "Post Nana's card"
    assert event.status_code == 200
    assert event.json()["calendar_event"]["title"] == "Nana's birthday"


# ---------------------------------------------------------------------------
# Days until calculation
# ---------------------------------------------------------------------------


async def test_days_until(client, adult_a_user, adult_a_headers):
    """Verify days_until is calculated correctly."""
    today = date.today()

    # Birthday exactly 10 days from now
    future_dob_date = today + timedelta(days=10)
    future_dob = future_dob_date.replace(year=future_dob_date.year - 20)

    resp = await client.post(
        "/api/birthdays/",
        json={"person_name": "Ten Days Away", "date_of_birth": future_dob.isoformat()},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["days_until"] == 10
    assert data["next_birthday"] == future_dob_date.isoformat()

    # Birthday today
    today_dob = today.replace(year=today.year - 15)
    resp2 = await client.post(
        "/api/birthdays/",
        json={"person_name": "Birthday Today", "date_of_birth": today_dob.isoformat()},
        headers=adult_a_headers,
    )
    assert resp2.status_code == 201
    data2 = resp2.json()
    assert data2["days_until"] == 0
    assert data2["next_birthday"] == today.isoformat()
