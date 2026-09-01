"""Tests for the growth tracking router (/api/growth)."""


# ---------------------------------------------------------------------------
# Create growth record
# ---------------------------------------------------------------------------


async def test_create_growth_record(client, adult_a_user, adult_a_headers, child1):
    """POST /api/growth creates a new growth record."""
    payload = {
        "child_id": child1["id"],
        "date": "2026-01-15",
        "height_cm": 95.5,
        "weight_kg": 14.2,
        "head_circumference_cm": 48.0,
        "notes": "Regular checkup",
    }
    resp = await client.post("/api/growth/", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["child_id"] == child1["id"]
    assert data["date"] == "2026-01-15"
    assert data["height_cm"] == 95.5
    assert data["weight_kg"] == 14.2
    assert data["head_circumference_cm"] == 48.0
    assert data["notes"] == "Regular checkup"
    assert data["created_by"] == adult_a_user["id"]
    assert "id" in data
    assert "created_at" in data
    assert "updated_at" in data


# ---------------------------------------------------------------------------
# List growth records
# ---------------------------------------------------------------------------


async def test_list_growth_records(client, adult_a_user, adult_a_headers, child1):
    """GET /api/growth returns growth records that have been created."""
    payload = {
        "child_id": child1["id"],
        "date": "2026-01-20",
        "height_cm": 96.0,
        "weight_kg": 14.5,
    }
    create_resp = await client.post("/api/growth/", json=payload, headers=adult_a_headers)
    assert create_resp.status_code == 201

    resp = await client.get("/api/growth/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 1
    dates = [r["date"] for r in data]
    assert "2026-01-20" in dates


# ---------------------------------------------------------------------------
# Filter by child
# ---------------------------------------------------------------------------


async def test_filter_by_child(client, adult_a_user, adult_a_headers, child1, child2):
    """GET /api/growth?child_id=... filters records by child."""
    await client.post(
        "/api/growth/",
        json={"child_id": child1["id"], "date": "2026-02-01", "height_cm": 96.5},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/growth/",
        json={"child_id": child2["id"], "date": "2026-02-01", "height_cm": 85.0},
        headers=adult_a_headers,
    )

    # Filter to child1 only
    resp = await client.get(
        "/api/growth/",
        params={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 1
    child_ids = {r["child_id"] for r in data}
    assert child_ids == {child1["id"]}


# ---------------------------------------------------------------------------
# Update growth record
# ---------------------------------------------------------------------------


async def test_update_growth_record(client, adult_a_user, adult_a_headers, child1):
    """PUT /api/growth/{id} updates an existing growth record."""
    payload = {
        "child_id": child1["id"],
        "date": "2026-01-25",
        "height_cm": 97.0,
        "weight_kg": 14.8,
    }
    create_resp = await client.post("/api/growth/", json=payload, headers=adult_a_headers)
    record_id = create_resp.json()["id"]

    update_resp = await client.put(
        f"/api/growth/{record_id}",
        json={"height_cm": 97.5, "notes": "Corrected measurement"},
        headers=adult_a_headers,
    )
    assert update_resp.status_code == 200
    data = update_resp.json()
    assert data["height_cm"] == 97.5
    assert data["notes"] == "Corrected measurement"
    # Unchanged fields should remain
    assert data["weight_kg"] == 14.8
    assert data["date"] == "2026-01-25"


# ---------------------------------------------------------------------------
# Delete growth record
# ---------------------------------------------------------------------------


async def test_delete_growth_record(client, adult_a_user, adult_a_headers, child1):
    """DELETE /api/growth/{id} soft-deletes the growth record (204)."""
    payload = {
        "child_id": child1["id"],
        "date": "2026-01-30",
        "height_cm": 97.0,
    }
    create_resp = await client.post("/api/growth/", json=payload, headers=adult_a_headers)
    record_id = create_resp.json()["id"]

    del_resp = await client.delete(f"/api/growth/{record_id}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    # Verify it no longer appears in GET
    list_resp = await client.get("/api/growth/", headers=adult_a_headers)
    ids = [r["id"] for r in list_resp.json()]
    assert record_id not in ids


# ---------------------------------------------------------------------------
# Growth chart
# ---------------------------------------------------------------------------


async def test_growth_chart(client, adult_a_user, adult_a_headers, child1):
    """GET /api/growth/chart/{child_id} returns records and child info."""
    # Create a couple of records for child1
    await client.post(
        "/api/growth/",
        json={"child_id": child1["id"], "date": "2025-06-01", "height_cm": 90.0, "weight_kg": 13.0},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/growth/",
        json={"child_id": child1["id"], "date": "2025-12-01", "height_cm": 94.0, "weight_kg": 14.0},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/growth/chart/{child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()

    assert data["child_name"] == child1["name"]
    assert data["child_dob"] == child1["date_of_birth"]
    assert isinstance(data["records"], list)
    assert len(data["records"]) >= 2

    # Records should be ordered by date ASC
    dates = [r["date"] for r in data["records"]]
    assert dates == sorted(dates)
