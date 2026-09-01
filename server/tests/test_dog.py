"""Tests for the dog tracking router (/api/dog)."""

from datetime import datetime, timezone

import aiosqlite


def _today_iso() -> str:
    """Return today's date-time in ISO 8601 format (UTC)."""
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


async def test_create_walk_activity(client, adult_a_headers):
    """POST /api/dog/activities with activity_type=walk returns 201."""
    resp = await client.post(
        "/api/dog/activities",
        json={
            "activity_type": "walk",
            "started_at": _today_iso(),
            "notes": "Morning walk around the park",
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["activity_type"] == "walk"
    assert data["notes"] == "Morning walk around the park"
    assert data["id"] is not None
    assert data["done_by"] is not None
    assert data["created_at"] is not None


async def test_create_feed_breakfast_activity(client, adult_a_headers):
    """POST /api/dog/activities with activity_type=feed_breakfast returns 201."""
    resp = await client.post(
        "/api/dog/activities",
        json={
            "activity_type": "feed_breakfast",
            "started_at": _today_iso(),
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["activity_type"] == "feed_breakfast"
    assert data["done_by"] is not None


async def test_create_feed_dinner_activity(client, adult_a_headers):
    """POST /api/dog/activities with activity_type=feed_dinner returns 201."""
    resp = await client.post(
        "/api/dog/activities",
        json={
            "activity_type": "feed_dinner",
            "started_at": _today_iso(),
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["activity_type"] == "feed_dinner"
    assert data["done_by"] is not None


# ---------------------------------------------------------------------------
# Vaccination records
# ---------------------------------------------------------------------------


async def test_create_list_and_soft_delete_dog_vaccination(client, adult_a_headers):
    created = await client.post(
        "/api/dog/vaccinations",
        json={
            "vaccine_name": "Leptospirosis",
            "given_on": "2026-07-16",
            "next_due_on": "2027-07-16",
            "notes": "Annual booster",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    vaccination = created.json()
    assert vaccination["vaccine_name"] == "Leptospirosis"
    assert vaccination["next_due_on"] == "2027-07-16"

    listed = await client.get("/api/dog/vaccinations", headers=adult_a_headers)
    assert listed.status_code == 200
    assert [item["id"] for item in listed.json()] == [vaccination["id"]]

    removed = await client.delete(
        f"/api/dog/vaccinations/{vaccination['id']}", headers=adult_a_headers
    )
    assert removed.status_code == 204
    after = await client.get("/api/dog/vaccinations", headers=adult_a_headers)
    assert after.json() == []


async def test_dog_vaccinations_are_family_scoped(
    client, adult_a_headers, other_family_headers
):
    created = await client.post(
        "/api/dog/vaccinations",
        json={"vaccine_name": "Rabies", "given_on": "2026-06-01"},
        headers=adult_a_headers,
    )
    vaccination_id = created.json()["id"]
    other_list = await client.get("/api/dog/vaccinations", headers=other_family_headers)
    assert all(item["id"] != vaccination_id for item in other_list.json())
    other_delete = await client.delete(
        f"/api/dog/vaccinations/{vaccination_id}", headers=other_family_headers
    )
    assert other_delete.status_code == 404


async def test_dog_vaccination_next_due_cannot_precede_given_date(client, adult_a_headers):
    resp = await client.post(
        "/api/dog/vaccinations",
        json={
            "vaccine_name": "Kennel cough",
            "given_on": "2026-07-16",
            "next_due_on": "2026-07-15",
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 422


async def test_dog_vaccination_dates_reject_trailing_content(client, adult_a_headers):
    resp = await client.post(
        "/api/dog/vaccinations",
        json={
            "vaccine_name": "Leptospirosis",
            "given_on": "2026-07-16T09:00:00Z",
            "next_due_on": "2027-07-16-not-a-date",
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 422


async def test_dog_vaccination_rejects_future_given_date(client, adult_a_headers):
    resp = await client.post(
        "/api/dog/vaccinations",
        json={"vaccine_name": "Rabies", "given_on": "2999-01-01"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------


async def test_list_activities(client, adult_a_headers):
    """GET /api/dog/activities returns all non-deleted activities."""
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "walk", "started_at": _today_iso()},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "feed_breakfast", "started_at": _today_iso()},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/dog/activities", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 2
    types = [a["activity_type"] for a in data]
    assert "walk" in types
    assert "feed_breakfast" in types


# ---------------------------------------------------------------------------
# Filter by type
# ---------------------------------------------------------------------------


async def test_filter_by_type(client, adult_a_headers):
    """GET /api/dog/activities?type=walk only returns walk activities."""
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "walk", "started_at": _today_iso()},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "feed_dinner", "started_at": _today_iso()},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/dog/activities?type=walk", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert all(a["activity_type"] == "walk" for a in data)
    assert len(data) >= 1


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------


async def test_update_activity(client, adult_a_headers):
    """PUT /api/dog/activities/{id} updates fields and returns the updated activity."""
    create_resp = await client.post(
        "/api/dog/activities",
        json={"activity_type": "walk", "started_at": _today_iso()},
        headers=adult_a_headers,
    )
    activity_id = create_resp.json()["id"]

    resp = await client.put(
        f"/api/dog/activities/{activity_id}",
        json={"notes": "Updated — longer walk than usual"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["notes"] == "Updated — longer walk than usual"


async def test_activity_times_are_normalised_and_end_cannot_precede_start(
    client,
    adult_a_headers,
):
    created = await client.post(
        "/api/dog/activities",
        json={
            "activity_type": "walk",
            "started_at": "2026-08-08T10:00:00+01:00",
            "ended_at": "2026-08-08T10:30:00+01:00",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    assert created.json()["started_at"] == "2026-08-08T09:00:00+00:00"

    invalid = await client.put(
        f"/api/dog/activities/{created.json()['id']}",
        json={"started_at": "2026-08-08T11:00:00Z"},
        headers=adult_a_headers,
    )
    assert invalid.status_code == 422


# ---------------------------------------------------------------------------
# Delete (soft)
# ---------------------------------------------------------------------------


async def test_delete_activity(client, adult_a_headers):
    """DELETE /api/dog/activities/{id} soft-deletes and returns 204."""
    create_resp = await client.post(
        "/api/dog/activities",
        json={"activity_type": "walk", "started_at": _today_iso()},
        headers=adult_a_headers,
    )
    activity_id = create_resp.json()["id"]

    resp = await client.delete(f"/api/dog/activities/{activity_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    # Activity should no longer appear in the list
    list_resp = await client.get("/api/dog/activities", headers=adult_a_headers)
    ids = [a["id"] for a in list_resp.json()]
    assert activity_id not in ids

    restored = await client.post(
        f"/api/dog/activities/{activity_id}/restore",
        headers=adult_a_headers,
    )
    assert restored.status_code == 200
    assert restored.json()["id"] == activity_id


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------


async def test_status_not_walked(client, adult_a_headers):
    """GET /api/dog/status with no activities shows walked_today=false."""
    resp = await client.get("/api/dog/status", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["walked_today"] is False
    assert data["fed_breakfast_today"] is False
    assert data["fed_dinner_today"] is False
    assert data["last_walk"] is None
    assert data["last_feed_breakfast"] is None
    assert data["last_feed_dinner"] is None


async def test_status_walked(client, adult_a_headers):
    """GET /api/dog/status after creating a walk today shows walked_today=true."""
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "walk", "started_at": _today_iso()},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/dog/status", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["walked_today"] is True
    assert data["last_walk"] is not None
    assert data["last_walk"]["activity_type"] == "walk"


async def test_status_fed_breakfast(client, adult_a_headers):
    """GET /api/dog/status after creating a feed_breakfast today shows fed_breakfast_today=true."""
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "feed_breakfast", "started_at": _today_iso()},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/dog/status", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["fed_breakfast_today"] is True
    assert data["last_feed_breakfast"] is not None
    assert data["last_feed_breakfast"]["activity_type"] == "feed_breakfast"


async def test_status_fed_dinner(client, adult_a_headers):
    """GET /api/dog/status after creating a feed_dinner today shows fed_dinner_today=true."""
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "feed_dinner", "started_at": _today_iso()},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/dog/status", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["fed_dinner_today"] is True
    assert data["last_feed_dinner"] is not None
    assert data["last_feed_dinner"]["activity_type"] == "feed_dinner"


# ---------------------------------------------------------------------------
# Feed breakfast / dinner independence
# ---------------------------------------------------------------------------


async def test_feed_breakfast_does_not_set_dinner(client, adult_a_headers):
    """Logging feed_breakfast sets fed_breakfast_today but NOT fed_dinner_today."""
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "feed_breakfast", "started_at": _today_iso()},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/dog/status", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["fed_breakfast_today"] is True
    assert data["fed_dinner_today"] is False
    assert data["last_feed_breakfast"] is not None
    assert data["last_feed_dinner"] is None


async def test_feed_dinner_does_not_set_breakfast(client, adult_a_headers):
    """Logging feed_dinner sets fed_dinner_today but NOT fed_breakfast_today."""
    await client.post(
        "/api/dog/activities",
        json={"activity_type": "feed_dinner", "started_at": _today_iso()},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/dog/status", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["fed_dinner_today"] is True
    assert data["fed_breakfast_today"] is False
    assert data["last_feed_dinner"] is not None
    assert data["last_feed_breakfast"] is None


async def test_status_uses_family_day_at_utc_midnight_boundary(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
    monkeypatch,
):
    """An activity at 00:15 BST is today even though its UTC date is yesterday."""
    reference = datetime(2026, 7, 11, 23, 30, tzinfo=timezone.utc)
    monkeypatch.setattr("app.routers.dog._utc_now", lambda: reference)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO dog_activities
                (id, activity_type, started_at, family_id, created_at, updated_at)
            VALUES ('bst-breakfast', 'feed_breakfast',
                    '2026-07-11T23:15:00+00:00',
                    ?, '2026-07-11T23:15:00+00:00',
                    '2026-07-11T23:15:00+00:00')
            """,
            (adult_a_user["family_id"],),
        )
        await db.commit()

    response = await client.get(
        "/api/dog/status",
        params={"timezone": "Europe/London"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json()["fed_breakfast_today"] is True


async def test_activity_date_filter_uses_family_timezone(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO dog_activities
                (id, activity_type, started_at, family_id, created_at, updated_at)
            VALUES ('bst-walk', 'walk', '2026-07-11T23:30:00Z',
                    ?, '2026-07-11T23:30:00Z', '2026-07-11T23:30:00Z')
            """,
            (adult_a_user["family_id"],),
        )
        await db.commit()

    response = await client.get(
        "/api/dog/activities",
        params={"date": "2026-07-12", "timezone": "Europe/London"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert "bst-walk" in {activity["id"] for activity in response.json()}


async def test_profile_care_windows_drive_plain_daily_states(
    client,
    adult_a_headers,
    monkeypatch,
):
    empty = await client.get("/api/dog/profile", headers=adult_a_headers)
    assert empty.status_code == 200
    assert empty.json()["name"] == "Dog"
    assert empty.json()["id"] is None

    saved = await client.put(
        "/api/dog/profile",
        json={
            "name": "Mabel",
            "breed": "Labrador",
            "breakfast_window_start": "07:30",
            "breakfast_window_end": "08:30",
            "walk_window_start": "10:00",
            "walk_window_end": "12:00",
            "dinner_window_start": "17:30",
            "dinner_window_end": "19:00",
        },
        headers=adult_a_headers,
    )
    assert saved.status_code == 200
    assert saved.json()["name"] == "Mabel"

    monkeypatch.setattr(
        "app.routers.dog._utc_now",
        lambda: datetime(2026, 8, 9, 7, 0, tzinfo=timezone.utc),
    )
    status_response = await client.get(
        "/api/dog/status",
        params={"timezone": "Europe/London"},
        headers=adult_a_headers,
    )
    status_data = status_response.json()
    assert status_data["dog_name"] == "Mabel"
    assert status_data["breakfast_state"] == "due"
    assert status_data["walk_state"] == "upcoming"
    assert status_data["dinner_state"] == "upcoming"


async def test_timed_walk_is_shared_and_becomes_completed_only_when_ended(
    client,
    adult_a_headers,
    monkeypatch,
):
    reference = datetime(2026, 8, 9, 10, 30, tzinfo=timezone.utc)
    monkeypatch.setattr("app.routers.dog._utc_now", lambda: reference)
    started = await client.post(
        "/api/dog/activities",
        json={
            "activity_type": "walk",
            "started_at": "2026-08-09T10:00:00Z",
            "is_active": True,
        },
        headers=adult_a_headers,
    )
    assert started.status_code == 201
    assert started.json()["is_active"] is True

    while_active = await client.get(
        "/api/dog/status",
        params={"timezone": "UTC"},
        headers=adult_a_headers,
    )
    assert while_active.json()["active_walk"]["id"] == started.json()["id"]
    assert while_active.json()["walked_today"] is False

    duplicate = await client.post(
        "/api/dog/activities",
        json={
            "activity_type": "walk",
            "started_at": "2026-08-09T10:15:00Z",
            "is_active": True,
        },
        headers=adult_a_headers,
    )
    assert duplicate.status_code == 409

    ended = await client.put(
        f"/api/dog/activities/{started.json()['id']}",
        json={"ended_at": "2026-08-09T10:30:00Z", "is_active": False},
        headers=adult_a_headers,
    )
    assert ended.status_code == 200
    assert ended.json()["is_active"] is False

    after = await client.get(
        "/api/dog/status",
        params={"timezone": "UTC"},
        headers=adult_a_headers,
    )
    assert after.json()["active_walk"] is None
    assert after.json()["walked_today"] is True


async def test_weight_correction_remove_and_restore(client, adult_a_headers):
    created = await client.post(
        "/api/dog/weights",
        json={"measured_on": "2026-08-01", "weight_kg": 22.4},
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    weight_id = created.json()["id"]

    corrected = await client.patch(
        f"/api/dog/weights/{weight_id}",
        json={"weight_kg": 22.1, "notes": "Vet scales"},
        headers=adult_a_headers,
    )
    assert corrected.status_code == 200
    assert corrected.json()["weight_kg"] == 22.1

    removed = await client.delete(f"/api/dog/weights/{weight_id}", headers=adult_a_headers)
    assert removed.status_code == 204
    assert (await client.get("/api/dog/weights", headers=adult_a_headers)).json() == []

    restored = await client.post(
        f"/api/dog/weights/{weight_id}/restore",
        headers=adult_a_headers,
    )
    assert restored.status_code == 200
    assert restored.json()["id"] == weight_id


async def test_pet_record_can_link_a_family_document(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO documents (
                id, title, original_filename, media_type, storage_key, file_size,
                sha256, source, category, status, family_id, created_by
            ) VALUES ('dog-insurance', 'Pet insurance', 'policy.pdf',
                      'application/pdf', 'dog/policy.pdf', 123, 'abc', 'file',
                      'household', 'filed', ?, ?)
            """,
            (adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    linked = await client.post(
        "/api/dog/documents",
        json={"document_id": "dog-insurance", "role": "insurance"},
        headers=adult_a_headers,
    )
    assert linked.status_code == 201
    assert linked.json()["title"] == "Pet insurance"
    assert linked.json()["download_url"] == "/api/documents/dog-insurance/content"

    listed = await client.get("/api/dog/documents", headers=adult_a_headers)
    assert [item["document_id"] for item in listed.json()] == ["dog-insurance"]

    removed = await client.delete(
        f"/api/dog/documents/{linked.json()['id']}",
        headers=adult_a_headers,
    )
    assert removed.status_code == 204
    assert (await client.get("/api/dog/documents", headers=adult_a_headers)).json() == []
