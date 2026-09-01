"""Tests for the illness tracking router (/api/illness)."""

import asyncio

from datetime import datetime, timedelta, timezone


# ===========================================================================
# Illness CRUD (7 tests)
# ===========================================================================


async def test_create_illness(client, adult_a_headers, child1):
    """POST /api/illness/ starts an illness for a child."""
    now = datetime.now(timezone.utc).isoformat()
    resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now, "notes": "Fever and cough"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["child_id"] == child1["id"]
    assert data["ended_at"] is None
    assert data["notes"] == "Fever and cough"


async def test_duplicate_active_illness_409(client, adult_a_headers, child1):
    """POST /api/illness/ returns 409 if child already has an active illness."""
    now = datetime.now(timezone.utc).isoformat()
    await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    assert resp.status_code == 409


async def test_concurrent_active_illness_creates_leave_one_active(
    client, adult_a_headers, child1
):
    now = datetime.now(timezone.utc).isoformat()

    responses = await asyncio.gather(
        *[
            client.post(
                "/api/illness/",
                json={"child_id": child1["id"], "started_at": now},
                headers=adult_a_headers,
            )
            for _ in range(2)
        ]
    )

    assert sorted(response.status_code for response in responses) == [201, 409]


async def test_record_completed_sick_days_while_an_active_illness_exists(
    client, adult_a_headers, child1
):
    """Historical sick-day ranges do not collide with the current illness."""
    now = datetime.now(timezone.utc)
    active = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now.isoformat()},
        headers=adult_a_headers,
    )
    assert active.status_code == 201

    start = (now - timedelta(days=14)).replace(hour=0, minute=0).isoformat()
    end = (now - timedelta(days=12)).replace(hour=23, minute=59).isoformat()
    historical = await client.post(
        "/api/illness/",
        json={
            "child_id": child1["id"],
            "started_at": start,
            "ended_at": end,
            "notes": "Stomach bug",
        },
        headers=adult_a_headers,
    )
    assert historical.status_code == 201
    assert historical.json()["ended_at"] == end

    listed = await client.get(
        f"/api/illness/?child_id={child1['id']}", headers=adult_a_headers
    )
    assert len(listed.json()) == 2


async def test_completed_sick_days_reject_end_before_start(client, adult_a_headers, child1):
    resp = await client.post(
        "/api/illness/",
        json={
            "child_id": child1["id"],
            "started_at": "2026-07-16T12:00:00+00:00",
            "ended_at": "2026-07-15T12:00:00+00:00",
        },
        headers=adult_a_headers,
    )
    assert resp.status_code == 422


async def test_active_illness_rejects_invalid_start_date(client, adult_a_headers, child1):
    resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": "not-a-date"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 422


async def test_illness_rejects_future_dates(client, adult_a_headers, child1):
    resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": "2999-01-01"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 422


async def test_list_illnesses_by_child(client, adult_a_headers, child1, child2):
    """GET /api/illness/?child_id= filters by child."""
    now = datetime.now(timezone.utc).isoformat()
    await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/illness/",
        json={"child_id": child2["id"], "started_at": now},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/illness/?child_id={child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 1
    assert data[0]["child_id"] == child1["id"]


async def test_list_active_illnesses(client, adult_a_headers, child1, child2):
    """GET /api/illness/?active=true returns only active illnesses."""
    now = datetime.now(timezone.utc).isoformat()
    # Active illness
    await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    # Ended illness
    resp = await client.post(
        "/api/illness/",
        json={"child_id": child2["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = resp.json()["id"]
    await client.put(
        f"/api/illness/{illness_id}",
        json={"ended_at": now},
        headers=adult_a_headers,
    )

    resp = await client.get("/api/illness/?active=true", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 1
    assert data[0]["child_id"] == child1["id"]


async def test_end_illness(client, adult_a_headers, child1):
    """PUT /api/illness/{id} sets ended_at to end an illness."""
    now = datetime.now(timezone.utc).isoformat()
    create_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = create_resp.json()["id"]

    end_time = datetime.now(timezone.utc).isoformat()
    resp = await client.put(
        f"/api/illness/{illness_id}",
        json={"ended_at": end_time},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["ended_at"] == end_time


async def test_end_illness_rejects_date_before_start(client, adult_a_headers, child1):
    create_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": "2026-07-17"},
        headers=adult_a_headers,
    )

    resp = await client.put(
        f"/api/illness/{create_resp.json()['id']}",
        json={"ended_at": "2026-07-16"},
        headers=adult_a_headers,
    )

    assert resp.status_code == 400
    assert resp.json()["detail"] == "End date cannot be before start date"


async def test_completed_illness_cannot_reopen_beside_active_one(
    client, adult_a_headers, child1
):
    historical = await client.post(
        "/api/illness/",
        json={
            "child_id": child1["id"],
            "started_at": "2026-07-01",
            "ended_at": "2026-07-02",
        },
        headers=adult_a_headers,
    )
    active = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": "2026-07-17"},
        headers=adult_a_headers,
    )
    assert active.status_code == 201

    resp = await client.put(
        f"/api/illness/{historical.json()['id']}",
        json={"ended_at": None},
        headers=adult_a_headers,
    )

    assert resp.status_code == 409
    assert resp.json()["detail"] == "Child already has an active illness"


async def test_completed_illness_can_be_reopened(client, adult_a_headers, child1):
    historical = await client.post(
        "/api/illness/",
        json={
            "child_id": child1["id"],
            "started_at": "2026-07-01T09:00:00+00:00",
            "ended_at": "2026-07-02T09:00:00+00:00",
        },
        headers=adult_a_headers,
    )

    resp = await client.put(
        f"/api/illness/{historical.json()['id']}",
        json={"ended_at": None},
        headers=adult_a_headers,
    )

    assert resp.status_code == 200
    assert resp.json()["ended_at"] is None


async def test_correct_illness_start_and_notes(client, adult_a_headers, child1):
    historical = await client.post(
        "/api/illness/",
        json={
            "child_id": child1["id"],
            "started_at": "2026-07-10T09:00:00+00:00",
            "ended_at": "2026-07-12T09:00:00+00:00",
            "notes": "Fever",
        },
        headers=adult_a_headers,
    )

    resp = await client.put(
        f"/api/illness/{historical.json()['id']}",
        json={
            "started_at": "2026-07-09T18:30:00+00:00",
            "notes": "Fever and cough",
        },
        headers=adult_a_headers,
    )

    assert resp.status_code == 200
    assert resp.json()["started_at"] == "2026-07-09T18:30:00+00:00"
    assert resp.json()["notes"] == "Fever and cough"


async def test_correct_illness_start_rejects_after_existing_end(
    client, adult_a_headers, child1
):
    historical = await client.post(
        "/api/illness/",
        json={
            "child_id": child1["id"],
            "started_at": "2026-07-10T09:00:00+00:00",
            "ended_at": "2026-07-12T09:00:00+00:00",
        },
        headers=adult_a_headers,
    )

    resp = await client.put(
        f"/api/illness/{historical.json()['id']}",
        json={"started_at": "2026-07-13T09:00:00+00:00"},
        headers=adult_a_headers,
    )

    assert resp.status_code == 400
    assert resp.json()["detail"] == "End date cannot be before start date"


async def test_get_active_illness(client, adult_a_headers, child1):
    """GET /api/illness/active/{child_id} returns the active illness."""
    now = datetime.now(timezone.utc).isoformat()
    await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/illness/active/{child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    assert resp.json()["child_id"] == child1["id"]


async def test_get_active_illness_404(client, adult_a_headers, child1):
    """GET /api/illness/active/{child_id} returns 404 if no active illness."""
    resp = await client.get(f"/api/illness/active/{child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 404


# ===========================================================================
# Temperature readings (6 tests)
# ===========================================================================


async def test_log_temperature(client, adult_a_headers, child1):
    """POST /api/illness/temperature logs a reading."""
    now = datetime.now(timezone.utc).isoformat()
    resp = await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "value_celsius": 38.5, "recorded_at": now},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["value_celsius"] == 38.5
    assert data["child_id"] == child1["id"]


async def test_temperature_auto_associate_illness(client, adult_a_headers, child1):
    """Temperature reading auto-associates with active illness."""
    now = datetime.now(timezone.utc).isoformat()
    illness_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = illness_resp.json()["id"]

    resp = await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "value_celsius": 39.0, "recorded_at": now},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201
    assert resp.json()["illness_id"] == illness_id


async def test_list_temperature_by_illness(client, adult_a_headers, child1):
    """GET /api/illness/temperature?illness_id= filters by illness."""
    now = datetime.now(timezone.utc).isoformat()
    illness_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = illness_resp.json()["id"]

    await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "illness_id": illness_id, "value_celsius": 38.0, "recorded_at": now},
        headers=adult_a_headers,
    )
    # Unassociated reading
    await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "value_celsius": 37.0, "recorded_at": now},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/illness/temperature?illness_id={illness_id}", headers=adult_a_headers)
    assert resp.status_code == 200
    # Both should be associated since auto-associate is active
    data = resp.json()
    assert all(r["illness_id"] == illness_id for r in data)


async def test_list_temperature_by_child(client, adult_a_headers, child1, child2):
    """GET /api/illness/temperature?child_id= filters by child."""
    now = datetime.now(timezone.utc).isoformat()
    await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "value_celsius": 38.0, "recorded_at": now},
        headers=adult_a_headers,
    )
    await client.post(
        "/api/illness/temperature",
        json={"child_id": child2["id"], "value_celsius": 37.5, "recorded_at": now},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/illness/temperature?child_id={child1['id']}", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert all(r["child_id"] == child1["id"] for r in data)


async def test_delete_temperature_reading(client, adult_a_headers, child1):
    """DELETE /api/illness/temperature/{id} soft-deletes a reading."""
    now = datetime.now(timezone.utc).isoformat()
    create_resp = await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "value_celsius": 38.0, "recorded_at": now},
        headers=adult_a_headers,
    )
    reading_id = create_resp.json()["id"]

    resp = await client.delete(f"/api/illness/temperature/{reading_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    # Should no longer appear in list
    list_resp = await client.get(f"/api/illness/temperature?child_id={child1['id']}", headers=adult_a_headers)
    ids = [r["id"] for r in list_resp.json()]
    assert reading_id not in ids


async def test_correct_temperature_reading(client, adult_a_headers, child1):
    now = datetime.now(timezone.utc).isoformat()
    create_resp = await client.post(
        "/api/illness/temperature",
        json={
            "child_id": child1["id"],
            "value_celsius": 38.0,
            "recorded_at": now,
            "notes": "Before medicine",
        },
        headers=adult_a_headers,
    )
    reading_id = create_resp.json()["id"]
    corrected_at = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()

    resp = await client.put(
        f"/api/illness/temperature/{reading_id}",
        json={
            "value_celsius": 38.4,
            "recorded_at": corrected_at,
            "notes": "Retaken",
        },
        headers=adult_a_headers,
    )

    assert resp.status_code == 200
    assert resp.json()["value_celsius"] == 38.4
    assert resp.json()["recorded_at"] == corrected_at
    assert resp.json()["notes"] == "Retaken"


async def test_temperature_correction_is_family_scoped(
    client, adult_a_headers, other_family_headers, child1
):
    now = datetime.now(timezone.utc).isoformat()
    created = await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "value_celsius": 38.0, "recorded_at": now},
        headers=adult_a_headers,
    )

    resp = await client.put(
        f"/api/illness/temperature/{created.json()['id']}",
        json={"value_celsius": 37.9},
        headers=other_family_headers,
    )

    assert resp.status_code == 404


async def test_temperature_value_range(client, adult_a_headers, child1):
    """Temperature outside 30-45°C is rejected."""
    now = datetime.now(timezone.utc).isoformat()
    resp = await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "value_celsius": 29.0, "recorded_at": now},
        headers=adult_a_headers,
    )
    assert resp.status_code == 400

    resp = await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "value_celsius": 46.0, "recorded_at": now},
        headers=adult_a_headers,
    )
    assert resp.status_code == 400


# ===========================================================================
# Illness detail (4 tests)
# ===========================================================================


async def test_illness_detail_includes_readings(client, adult_a_headers, child1):
    """GET /api/illness/{id}/detail includes temperature readings."""
    now = datetime.now(timezone.utc).isoformat()
    illness_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = illness_resp.json()["id"]

    await client.post(
        "/api/illness/temperature",
        json={"child_id": child1["id"], "illness_id": illness_id, "value_celsius": 38.5, "recorded_at": now},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/illness/{illness_id}/detail", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["temperature_readings"]) == 1
    assert data["temperature_readings"][0]["value_celsius"] == 38.5


async def test_illness_detail_includes_doses(client, adult_a_headers, child1):
    """GET /api/illness/{id}/detail includes medicine doses during illness."""
    now_dt = datetime.now(timezone.utc)
    now = now_dt.isoformat()
    illness_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = illness_resp.json()["id"]

    # Create a medicine type
    type_resp = await client.post(
        "/api/medicine/types",
        json={"name": "Calpol", "child_id": child1["id"]},
        headers=adult_a_headers,
    )
    med_type_id = type_resp.json()["id"]

    # Give a dose during illness
    dose_time = (now_dt + timedelta(minutes=5)).isoformat()
    await client.post(
        "/api/medicine/doses",
        json={"medicine_type_id": med_type_id, "child_id": child1["id"], "given_at": dose_time},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/illness/{illness_id}/detail", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["medicine_doses"]) >= 1


async def test_illness_detail_next_dose_times(client, adult_a_headers, child1):
    """GET /api/illness/{id}/detail includes next_dose_times."""
    now = datetime.now(timezone.utc).isoformat()
    illness_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = illness_resp.json()["id"]

    # Create a medicine type
    await client.post(
        "/api/medicine/types",
        json={"name": "Ibuprofen", "child_id": child1["id"]},
        headers=adult_a_headers,
    )

    resp = await client.get(f"/api/illness/{illness_id}/detail", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["next_dose_times"]) == 1
    assert data["next_dose_times"][0]["medicine_name"] == "Ibuprofen"
    assert data["next_dose_times"][0]["is_safe_now"] is True


async def test_illness_detail_excludes_doses_outside_period(client, adult_a_headers, child1):
    """Doses given before illness start are excluded from detail."""
    now_dt = datetime.now(timezone.utc)
    before_illness = (now_dt - timedelta(hours=2)).isoformat()
    illness_start = now_dt.isoformat()

    # Create medicine type and give dose BEFORE illness
    type_resp = await client.post(
        "/api/medicine/types",
        json={"name": "Calpol", "child_id": child1["id"]},
        headers=adult_a_headers,
    )
    med_type_id = type_resp.json()["id"]

    await client.post(
        "/api/medicine/doses",
        json={"medicine_type_id": med_type_id, "child_id": child1["id"], "given_at": before_illness},
        headers=adult_a_headers,
    )

    # Start illness AFTER the dose
    illness_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": illness_start},
        headers=adult_a_headers,
    )
    illness_id = illness_resp.json()["id"]

    resp = await client.get(f"/api/illness/{illness_id}/detail", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["medicine_doses"]) == 0


# ===========================================================================
# Edge cases (3 tests)
# ===========================================================================


async def test_soft_delete_illness(client, adult_a_headers, child1):
    """DELETE /api/illness/{id} soft-deletes the illness."""
    now = datetime.now(timezone.utc).isoformat()
    create_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = create_resp.json()["id"]

    resp = await client.delete(f"/api/illness/{illness_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    # Should not appear in list
    list_resp = await client.get(f"/api/illness/?child_id={child1['id']}", headers=adult_a_headers)
    assert len(list_resp.json()) == 0


async def test_start_new_after_ending(client, adult_a_headers, child1):
    """Can start a new illness after ending the previous one."""
    now = datetime.now(timezone.utc).isoformat()
    create_resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    illness_id = create_resp.json()["id"]

    # End it
    await client.put(
        f"/api/illness/{illness_id}",
        json={"ended_at": now},
        headers=adult_a_headers,
    )

    # Start a new one
    resp = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    assert resp.status_code == 201


async def test_children_independent(client, adult_a_headers, child1, child2):
    """Each child's illness tracking is independent."""
    now = datetime.now(timezone.utc).isoformat()
    resp1 = await client.post(
        "/api/illness/",
        json={"child_id": child1["id"], "started_at": now},
        headers=adult_a_headers,
    )
    assert resp1.status_code == 201

    resp2 = await client.post(
        "/api/illness/",
        json={"child_id": child2["id"], "started_at": now},
        headers=adult_a_headers,
    )
    assert resp2.status_code == 201

    # Both children have active illnesses
    active1 = await client.get(f"/api/illness/active/{child1['id']}", headers=adult_a_headers)
    active2 = await client.get(f"/api/illness/active/{child2['id']}", headers=adult_a_headers)
    assert active1.status_code == 200
    assert active2.status_code == 200
