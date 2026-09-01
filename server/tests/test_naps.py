"""Tests for the naps router (/api/naps)."""


# ---------------------------------------------------------------------------
# Start nap
# ---------------------------------------------------------------------------


async def test_start_nap(client, adult_a_user, adult_a_headers, child1):
    """POST /api/naps/start creates a new nap and returns it."""
    payload = {
        "child_id": child1["id"],
        "started_at": "2026-02-08T13:00:00Z",
        "location": "Bedroom",
        "notes": "Fell asleep quickly",
    }
    resp = await client.post("/api/naps/start", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["child_id"] == child1["id"]
    assert data["started_at"] == "2026-02-08T13:00:00Z"
    assert data["location"] == "Bedroom"
    assert data["notes"] == "Fell asleep quickly"
    assert data["ended_at"] is None
    assert data["duration_minutes"] is None
    assert data["created_by"] == adult_a_user["id"]
    assert "id" in data
    assert "created_at" in data
    assert "updated_at" in data


# ---------------------------------------------------------------------------
# Active naps
# ---------------------------------------------------------------------------


async def test_active_naps(client, adult_a_user, adult_a_headers, child1):
    """Starting a nap should make it appear in GET /api/naps/active."""
    payload = {
        "child_id": child1["id"],
        "started_at": "2026-02-08T14:00:00Z",
    }
    start_resp = await client.post("/api/naps/start", json=payload, headers=adult_a_headers)
    assert start_resp.status_code == 201
    nap_id = start_resp.json()["id"]

    resp = await client.get("/api/naps/active", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    ids = [n["id"] for n in data]
    assert nap_id in ids


# ---------------------------------------------------------------------------
# End nap
# ---------------------------------------------------------------------------


async def test_end_nap(client, adult_a_user, adult_a_headers, child1):
    """PATCH /api/naps/{id}/end sets ended_at and calculates duration_minutes."""
    # Start nap
    start_resp = await client.post(
        "/api/naps/start",
        json={
            "child_id": child1["id"],
            "started_at": "2026-02-08T13:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert start_resp.status_code == 201
    nap_id = start_resp.json()["id"]

    # End nap 90 minutes later
    end_resp = await client.patch(
        f"/api/naps/{nap_id}/end",
        json={"ended_at": "2026-02-08T14:30:00Z"},
        headers=adult_a_headers,
    )
    assert end_resp.status_code == 200
    data = end_resp.json()
    assert data["ended_at"] == "2026-02-08T14:30:00Z"
    assert data["duration_minutes"] == 90.0


# ---------------------------------------------------------------------------
# List naps
# ---------------------------------------------------------------------------


async def test_list_naps(client, adult_a_user, adult_a_headers, child1):
    """GET /api/naps returns created naps."""
    # Create two naps
    await client.post(
        "/api/naps/start",
        json={"child_id": child1["id"], "started_at": "2026-02-08T10:00:00Z"},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/naps/start",
        json={"child_id": child1["id"], "started_at": "2026-02-08T14:00:00Z"},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/naps/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 2


async def test_date_filter_includes_sleep_overlapping_local_day(
    client,
    adult_a_headers,
    child1,
):
    """A bedtime begun yesterday remains available as last night's sleep."""
    started = await client.post(
        "/api/naps/start",
        json={
            "child_id": child1["id"],
            "started_at": "2026-07-11T20:30:00Z",
            "sleep_type": "bedtime",
        },
        headers=adult_a_headers,
    )
    bedtime_id = started.json()["id"]
    await client.patch(
        f"/api/naps/{bedtime_id}/end",
        json={"ended_at": "2026-07-12T05:30:00Z"},
        headers=adult_a_headers,
    )

    response = await client.get(
        "/api/naps/",
        params={"date": "2026-07-12", "timezone": "Europe/London"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert bedtime_id in {entry["id"] for entry in response.json()}


async def test_date_filter_uses_family_timezone_boundaries(
    client,
    adult_a_headers,
    child1,
):
    """00:30 BST belongs to the new local day even though UTC is still yesterday."""
    started = await client.post(
        "/api/naps/start",
        json={
            "child_id": child1["id"],
            "started_at": "2026-07-11T23:30:00Z",
            "sleep_type": "nap",
        },
        headers=adult_a_headers,
    )
    nap_id = started.json()["id"]
    await client.patch(
        f"/api/naps/{nap_id}/end",
        json={"ended_at": "2026-07-12T00:00:00Z"},
        headers=adult_a_headers,
    )

    local_day = await client.get(
        "/api/naps/",
        params={"date": "2026-07-12", "timezone": "Europe/London"},
        headers=adult_a_headers,
    )
    previous_local_day = await client.get(
        "/api/naps/",
        params={"date": "2026-07-11", "timezone": "Europe/London"},
        headers=adult_a_headers,
    )

    assert nap_id in {entry["id"] for entry in local_day.json()}
    assert nap_id not in {entry["id"] for entry in previous_local_day.json()}


async def test_date_filter_rejects_unknown_timezone(client, adult_a_headers):
    response = await client.get(
        "/api/naps/",
        params={"date": "2026-07-12", "timezone": "Not/AZone"},
        headers=adult_a_headers,
    )

    assert response.status_code == 422


# ---------------------------------------------------------------------------
# List naps filtered by child
# ---------------------------------------------------------------------------


async def test_list_naps_by_child(client, adult_a_user, adult_a_headers, child1, child2):
    """GET /api/naps?child_id=... filters naps to the specified child."""
    # Create a nap for child1
    await client.post(
        "/api/naps/start",
        json={"child_id": child1["id"], "started_at": "2026-02-08T10:00:00Z"},
        headers=adult_a_headers,
    )
    # Create a nap for child2
    await client.post(
        "/api/naps/start",
        json={"child_id": child2["id"], "started_at": "2026-02-08T11:00:00Z"},
        headers=adult_a_headers,
    )

    # Filter by child1
    resp = await client.get(
        "/api/naps/", params={"child_id": child1["id"]}, headers=adult_a_headers
    )
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 1
    for nap in data:
        assert nap["child_id"] == child1["id"]


# ---------------------------------------------------------------------------
# Delete nap (soft delete)
# ---------------------------------------------------------------------------


async def test_delete_nap(client, adult_a_user, adult_a_headers, child1):
    """DELETE /api/naps/{id} soft-deletes a nap (204). It should not appear in GET."""
    # Create a nap
    start_resp = await client.post(
        "/api/naps/start",
        json={"child_id": child1["id"], "started_at": "2026-02-08T09:00:00Z"},
        headers=adult_a_headers,
    )
    nap_id = start_resp.json()["id"]

    # Delete it
    del_resp = await client.delete(f"/api/naps/{nap_id}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    # Verify it no longer appears in the list
    list_resp = await client.get("/api/naps/", headers=adult_a_headers)
    ids = [n["id"] for n in list_resp.json()]
    assert nap_id not in ids


async def test_full_correction_delete_and_undo(client, adult_a_headers, child1):
    started = await client.post(
        "/api/naps/start",
        json={
            "child_id": child1["id"],
            "started_at": "2026-02-08T13:00:00Z",
            "location": "buggy",
            "notes": "Original note",
        },
        headers=adult_a_headers,
    )
    nap_id = started.json()["id"]
    await client.patch(
        f"/api/naps/{nap_id}/end",
        json={"ended_at": "2026-02-08T14:00:00Z"},
        headers=adult_a_headers,
    )

    corrected = await client.patch(
        f"/api/naps/{nap_id}",
        json={
            "started_at": "2026-02-08T12:50:00Z",
            "ended_at": "2026-02-08T14:10:00Z",
            "location": "cot",
            "notes": "Corrected after checking",
        },
        headers=adult_a_headers,
    )
    assert corrected.status_code == 200
    assert corrected.json()["duration_minutes"] == 80
    assert corrected.json()["location"] == "cot"
    assert corrected.json()["notes"] == "Corrected after checking"

    deleted = await client.delete(f"/api/naps/{nap_id}", headers=adult_a_headers)
    restored = await client.post(f"/api/naps/{nap_id}/restore", headers=adult_a_headers)

    assert deleted.status_code == 204
    assert restored.status_code == 200
    assert restored.json()["id"] == nap_id
    assert restored.json()["location"] == "cot"


async def test_correction_can_reopen_and_clear_optional_details(client, adult_a_headers, child1):
    started = await client.post(
        "/api/naps/start",
        json={
            "child_id": child1["id"],
            "started_at": "2026-02-08T13:00:00Z",
            "location": "sofa",
            "notes": "Settled with a story",
        },
        headers=adult_a_headers,
    )
    nap_id = started.json()["id"]
    await client.patch(
        f"/api/naps/{nap_id}/end",
        json={"ended_at": "2026-02-08T13:30:00Z"},
        headers=adult_a_headers,
    )

    reopened = await client.patch(
        f"/api/naps/{nap_id}",
        json={"clear_ended_at": True, "clear_location": True, "clear_notes": True},
        headers=adult_a_headers,
    )

    assert reopened.status_code == 200
    assert reopened.json()["ended_at"] is None
    assert reopened.json()["location"] is None
    assert reopened.json()["notes"] is None


# ---------------------------------------------------------------------------
# No active nap after ending it
# ---------------------------------------------------------------------------


async def test_no_active_after_end(client, adult_a_user, adult_a_headers, child1):
    """After ending a nap, it should no longer appear in GET /api/naps/active."""
    # Start a nap
    start_resp = await client.post(
        "/api/naps/start",
        json={"child_id": child1["id"], "started_at": "2026-02-08T15:00:00Z"},
        headers=adult_a_headers,
    )
    nap_id = start_resp.json()["id"]

    # Verify it is active
    active_resp = await client.get("/api/naps/active", headers=adult_a_headers)
    active_ids = [n["id"] for n in active_resp.json()]
    assert nap_id in active_ids

    # End the nap
    await client.patch(
        f"/api/naps/{nap_id}/end",
        json={"ended_at": "2026-02-08T16:30:00Z"},
        headers=adult_a_headers,
    )

    # Verify it is no longer active
    active_resp2 = await client.get("/api/naps/active", headers=adult_a_headers)
    active_ids2 = [n["id"] for n in active_resp2.json()]
    assert nap_id not in active_ids2


# ---------------------------------------------------------------------------
# Bedtime (sleep_type) tests
# ---------------------------------------------------------------------------


async def test_start_bedtime(client, adult_a_user, adult_a_headers, child1):
    """POST /api/naps/start with sleep_type='bedtime' creates a bedtime entry."""
    payload = {
        "child_id": child1["id"],
        "started_at": "2026-02-08T21:00:00Z",
        "sleep_type": "bedtime",
        "notes": "Fell asleep after stories",
    }
    resp = await client.post("/api/naps/start", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["sleep_type"] == "bedtime"
    assert data["child_id"] == child1["id"]
    assert data["notes"] == "Fell asleep after stories"


async def test_default_sleep_type_is_nap(client, adult_a_user, adult_a_headers, child1):
    """POST without sleep_type should default to 'nap'."""
    payload = {
        "child_id": child1["id"],
        "started_at": "2026-02-08T13:00:00Z",
    }
    resp = await client.post("/api/naps/start", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    assert resp.json()["sleep_type"] == "nap"


async def test_filter_by_sleep_type(client, adult_a_user, adult_a_headers, child1):
    """GET /api/naps?sleep_type=nap returns only naps, not bedtimes."""
    # Create a nap
    await client.post(
        "/api/naps/start",
        json={"child_id": child1["id"], "started_at": "2026-02-08T13:00:00Z", "sleep_type": "nap"},
        headers=adult_a_headers,
    )
    # Create a bedtime
    await client.post(
        "/api/naps/start",
        json={"child_id": child1["id"], "started_at": "2026-02-08T21:00:00Z", "sleep_type": "bedtime"},
        headers=adult_a_headers,
    )

    # Filter by nap
    resp = await client.get("/api/naps/", params={"sleep_type": "nap"}, headers=adult_a_headers)
    assert resp.status_code == 200
    for entry in resp.json():
        assert entry["sleep_type"] == "nap"

    # Filter by bedtime
    resp2 = await client.get("/api/naps/", params={"sleep_type": "bedtime"}, headers=adult_a_headers)
    assert resp2.status_code == 200
    assert len(resp2.json()) >= 1
    for entry in resp2.json():
        assert entry["sleep_type"] == "bedtime"


async def test_active_filter_by_sleep_type(client, adult_a_user, adult_a_headers, child1, child2):
    """GET /api/naps/active?sleep_type=bedtime returns only active bedtimes."""
    # Start a nap for child1
    await client.post(
        "/api/naps/start",
        json={"child_id": child1["id"], "started_at": "2026-02-08T14:00:00Z", "sleep_type": "nap"},
        headers=adult_a_headers,
    )
    # Start a bedtime for child2
    bed_resp = await client.post(
        "/api/naps/start",
        json={"child_id": child2["id"], "started_at": "2026-02-08T21:00:00Z", "sleep_type": "bedtime"},
        headers=adult_a_headers,
    )
    bed_id = bed_resp.json()["id"]

    # Filter active by bedtime
    resp = await client.get("/api/naps/active", params={"sleep_type": "bedtime"}, headers=adult_a_headers)
    assert resp.status_code == 200
    ids = [n["id"] for n in resp.json()]
    assert bed_id in ids
    for entry in resp.json():
        assert entry["sleep_type"] == "bedtime"


async def test_end_bedtime_duration(client, adult_a_user, adult_a_headers, child1):
    """Start bedtime at 21:00, end at 06:30 — duration should be 570 minutes."""
    start_resp = await client.post(
        "/api/naps/start",
        json={
            "child_id": child1["id"],
            "started_at": "2026-02-08T21:00:00Z",
            "sleep_type": "bedtime",
        },
        headers=adult_a_headers,
    )
    assert start_resp.status_code == 201
    nap_id = start_resp.json()["id"]

    end_resp = await client.patch(
        f"/api/naps/{nap_id}/end",
        json={"ended_at": "2026-02-09T06:30:00Z"},
        headers=adult_a_headers,
    )
    assert end_resp.status_code == 200
    data = end_resp.json()
    assert data["duration_minutes"] == 570.0
    assert data["sleep_type"] == "bedtime"
