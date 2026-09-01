"""Tests for the medicine tracking feature (SAFETY-CRITICAL).

Minimum 17 tests covering medicine types CRUD, dose logging,
safety warnings (too_soon, max_reached), backdated dose validation,
and the safety-check endpoint.
"""

import asyncio
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite


# ---------------------------------------------------------------------------
# Helper: create a medicine type via API
# ---------------------------------------------------------------------------


async def _create_type(client, headers, child_id, **overrides):
    """Convenience wrapper to POST a medicine type."""
    payload = {
        "name": "Calpol",
        "min_hours_between_doses": 4.0,
        "max_doses_24h": 4,
        "child_id": child_id,
    }
    payload.update(overrides)
    resp = await client.post("/api/medicine/types", json=payload, headers=headers)
    assert resp.status_code == 201
    return resp.json()


async def _log_dose(client, headers, medicine_type_id, child_id, given_at, **overrides):
    """Convenience wrapper to POST a dose."""
    payload = {
        "medicine_type_id": medicine_type_id,
        "child_id": child_id,
        "given_at": given_at,
    }
    payload.update(overrides)
    resp = await client.post("/api/medicine/doses", json=payload, headers=headers)
    assert resp.status_code == 201
    return resp.json()


# ---------------------------------------------------------------------------
# Medicine Types — CRUD
# ---------------------------------------------------------------------------


async def test_create_medicine_type(client, adult_a_user, adult_a_headers, child1):
    """POST /api/medicine/types creates a medicine type and returns it."""
    data = await _create_type(client, adult_a_headers, child1["id"])

    assert data["name"] == "Calpol"
    assert data["min_hours_between_doses"] == 4.0
    assert data["max_doses_24h"] == 4
    assert data["child_id"] == child1["id"]
    assert data["created_by"] == adult_a_user["id"]
    assert "id" in data
    assert "created_at" in data
    assert "updated_at" in data


async def test_list_medicine_types(client, adult_a_user, adult_a_headers, child1):
    """GET /api/medicine/types lists all active medicine types."""
    await _create_type(client, adult_a_headers, child1["id"], name="Calpol")
    await _create_type(client, adult_a_headers, child1["id"], name="Ibuprofen")

    resp = await client.get("/api/medicine/types", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 2
    names = {t["name"] for t in data}
    assert names == {"Calpol", "Ibuprofen"}


async def test_list_types_filter_by_child(client, adult_a_user, adult_a_headers, child1, child3):
    """GET /api/medicine/types?child_id= filters by child."""
    await _create_type(client, adult_a_headers, child1["id"], name="Calpol")
    await _create_type(client, adult_a_headers, child3["id"], name="Nurofen")

    resp = await client.get(
        "/api/medicine/types",
        params={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 1
    assert data[0]["name"] == "Calpol"
    assert data[0]["child_id"] == child1["id"]


async def test_update_medicine_type(client, adult_a_user, adult_a_headers, child1):
    """PUT /api/medicine/types/{id} updates the type and saves history."""
    created = await _create_type(client, adult_a_headers, child1["id"])
    type_id = created["id"]

    resp = await client.put(
        f"/api/medicine/types/{type_id}",
        json={"name": "Calpol Six Plus", "min_hours_between_doses": 6.0},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["name"] == "Calpol Six Plus"
    assert data["min_hours_between_doses"] == 6.0
    # Unchanged fields remain
    assert data["max_doses_24h"] == 4


async def test_delete_medicine_type(client, adult_a_user, adult_a_headers, child1):
    """Archiving hides the medicine but keeps its name on past doses."""
    created = await _create_type(client, adult_a_headers, child1["id"])
    type_id = created["id"]
    await _log_dose(
        client,
        adult_a_headers,
        type_id,
        child1["id"],
        datetime(2026, 8, 8, 10, 0, tzinfo=timezone.utc).isoformat(),
    )

    resp = await client.delete(f"/api/medicine/types/{type_id}", headers=adult_a_headers)
    assert resp.status_code == 204

    # Should no longer appear in the list
    list_resp = await client.get("/api/medicine/types", headers=adult_a_headers)
    assert list_resp.status_code == 200
    assert len(list_resp.json()) == 0

    doses = await client.get("/api/medicine/doses", headers=adult_a_headers)
    assert doses.status_code == 200
    assert doses.json()[0]["medicine_name"] == "Calpol"


# ---------------------------------------------------------------------------
# Dose Logging
# ---------------------------------------------------------------------------


async def test_log_dose(client, adult_a_user, adult_a_headers, child1):
    """POST /api/medicine/doses creates a dose and returns it with warnings."""
    med_type = await _create_type(client, adult_a_headers, child1["id"])
    given_at = datetime.now(timezone.utc).isoformat()

    result = await _log_dose(
        client, adult_a_headers, med_type["id"], child1["id"], given_at,
        dose_amount="5ml", notes="With food",
    )

    assert "dose" in result
    assert "warnings" in result
    dose = result["dose"]
    assert dose["medicine_type_id"] == med_type["id"]
    assert dose["child_id"] == child1["id"]
    assert dose["given_by"] == adult_a_user["name"]
    assert dose["dose_amount"] == "5ml"
    assert dose["notes"] == "With food"


async def test_log_dose_no_warnings(client, adult_a_user, adult_a_headers, child1):
    """First dose for a medicine/child should produce zero warnings."""
    med_type = await _create_type(client, adult_a_headers, child1["id"])
    given_at = datetime.now(timezone.utc).isoformat()

    result = await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], given_at)

    assert result["warnings"] == []


async def test_correct_dose_recalculates_and_keeps_warnings_with_the_record(
    client,
    adult_a_headers,
    child1,
):
    """A correction uses the corrected real time for medicine safety."""
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=4.0,
    )
    first_at = datetime(2026, 8, 8, 10, 0, tzinfo=timezone.utc)
    await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        first_at.isoformat(),
    )
    second = await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        (first_at + timedelta(hours=1)).isoformat(),
        dose_amount="5 ml",
        notes="Before correction",
    )
    assert [warning["type"] for warning in second["warnings"]] == ["too_soon"]

    corrected_at = first_at + timedelta(hours=5)
    response = await client.patch(
        f"/api/medicine/doses/{second['dose']['id']}",
        json={
            "given_at": corrected_at.isoformat(),
            "dose_amount": "7.5 ml",
            "notes": "Corrected after checking the bottle",
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    corrected = response.json()
    assert corrected["warnings"] == []
    assert corrected["dose"]["warnings"] == []
    assert corrected["dose"]["given_at"] == corrected_at.isoformat()
    assert corrected["dose"]["dose_amount"] == "7.5 ml"
    assert corrected["dose"]["notes"] == "Corrected after checking the bottle"

    listed = await client.get(
        "/api/medicine/doses",
        params={"medicine_type_id": med_type["id"]},
        headers=adult_a_headers,
    )
    by_id = {dose["id"]: dose for dose in listed.json()}
    assert by_id[second["dose"]["id"]]["warnings"] == []


async def test_correct_dose_to_unsafe_time_returns_and_remembers_warning(
    client,
    adult_a_headers,
    child1,
):
    """Warnings remain visible when a saved correction creates a close interval."""
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=4.0,
    )
    first_at = datetime(2026, 8, 8, 10, 0, tzinfo=timezone.utc)
    await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        first_at.isoformat(),
    )
    second = await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        (first_at + timedelta(hours=6)).isoformat(),
    )

    response = await client.patch(
        f"/api/medicine/doses/{second['dose']['id']}",
        json={"given_at": (first_at + timedelta(hours=2)).isoformat()},
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    assert [warning["type"] for warning in response.json()["warnings"]] == ["too_soon"]

    listed = await client.get(
        "/api/medicine/doses",
        params={"medicine_type_id": med_type["id"]},
        headers=adult_a_headers,
    )
    corrected = next(dose for dose in listed.json() if dose["id"] == second["dose"]["id"])
    assert [warning["type"] for warning in corrected["warnings"]] == ["too_soon"]


async def test_remove_and_restore_dose_recalculates_warning(
    client,
    adult_a_headers,
    child1,
):
    """A mistaken record can be removed and immediately restored without losing safety context."""
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=4.0,
    )
    first_at = datetime(2026, 8, 8, 10, 0, tzinfo=timezone.utc)
    first = await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        first_at.isoformat(),
    )
    second = await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        (first_at + timedelta(hours=1)).isoformat(),
    )
    dose_id = second["dose"]["id"]

    removed = await client.delete(f"/api/medicine/doses/{dose_id}", headers=adult_a_headers)
    assert removed.status_code == 204
    listed = await client.get(
        "/api/medicine/doses",
        params={"medicine_type_id": med_type["id"]},
        headers=adult_a_headers,
    )
    assert {dose["id"] for dose in listed.json()} == {first["dose"]["id"]}

    restored = await client.post(
        f"/api/medicine/doses/{dose_id}/restore",
        headers=adult_a_headers,
    )
    assert restored.status_code == 200
    assert [warning["type"] for warning in restored.json()["warnings"]] == ["too_soon"]

    relisted = await client.get(
        "/api/medicine/doses",
        params={"medicine_type_id": med_type["id"]},
        headers=adult_a_headers,
    )
    restored_row = next(dose for dose in relisted.json() if dose["id"] == dose_id)
    assert [warning["type"] for warning in restored_row["warnings"]] == ["too_soon"]


async def test_concurrent_replay_creates_one_dose_and_repeats_original_warnings(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    """Two simultaneous deliveries of one operation are one safety write."""
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=4.0,
    )
    base = datetime(2026, 2, 8, 10, 0, tzinfo=timezone.utc)
    await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        base.isoformat(),
    )

    operation_id = str(uuid.uuid4())
    payload = {
        "id": operation_id,
        "medicine_type_id": med_type["id"],
        "child_id": child1["id"],
        "given_at": (base + timedelta(hours=1)).isoformat(),
        "dose_amount": "5 ml",
        "notes": "After breakfast",
    }
    start = asyncio.Event()

    async def deliver():
        await start.wait()
        return await client.post(
            "/api/medicine/doses",
            json=payload,
            headers=adult_a_headers,
        )

    requests = [asyncio.create_task(deliver()) for _ in range(2)]
    start.set()
    responses = await asyncio.gather(*requests)

    assert [response.status_code for response in responses] == [201, 201]
    results = [response.json() for response in responses]
    assert {result["dose"]["id"] for result in results} == {operation_id}
    assert [warning["type"] for warning in results[0]["warnings"]] == ["too_soon"]
    assert results[1]["warnings"] == results[0]["warnings"]

    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM medicine_doses WHERE id = ?",
                    (operation_id,),
                )
            ).fetchone()
        )[0]
    assert count == 1


async def test_direct_and_sync_replay_share_one_serialized_dose_write(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    """A lost online response replayed through offline sync cannot double-log."""
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=4.0,
    )
    base = datetime(2026, 2, 9, 10, 0, tzinfo=timezone.utc)
    await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        base.isoformat(),
    )
    operation_id = str(uuid.uuid4())
    proposed_at = (base + timedelta(hours=1)).isoformat()
    dose_payload = {
        "medicine_type_id": med_type["id"],
        "child_id": child1["id"],
        "given_at": proposed_at,
        "dose_amount": "5 ml",
        "medicine_name": None,
        "notes": None,
    }
    direct_payload = {"id": operation_id, **dose_payload}
    sync_payload = {
        "items": [
            {
                "operation": "create",
                "table_name": "medicine_doses",
                "record_id": operation_id,
                "payload": dose_payload,
                "client_id": str(uuid.uuid4()),
                "client_timestamp": datetime.now(timezone.utc).isoformat(),
            }
        ]
    }
    start = asyncio.Event()

    async def deliver(path: str, payload: dict):
        await start.wait()
        return await client.post(path, json=payload, headers=adult_a_headers)

    direct = asyncio.create_task(
        deliver("/api/medicine/doses", direct_payload)
    )
    synced = asyncio.create_task(deliver("/api/sync/push", sync_payload))
    start.set()
    direct_response, sync_response = await asyncio.gather(direct, synced)

    assert direct_response.status_code == 201
    assert sync_response.status_code == 200
    direct_result = direct_response.json()
    sync_result = sync_response.json()["results"][0]
    assert direct_result["dose"]["id"] == operation_id
    assert sync_result["status"] == "accepted"
    assert [warning["type"] for warning in direct_result["warnings"]] == [
        "too_soon"
    ]
    assert sync_result["warnings"] == direct_result["warnings"]

    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM medicine_doses WHERE id = ?",
                    (operation_id,),
                )
            ).fetchone()
        )[0]
    assert count == 1


async def test_distinct_concurrent_direct_and_sync_writes_see_each_other(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    """One of two racing writes must warn based on the other committed dose."""
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=4.0,
    )
    first_id = str(uuid.uuid4())
    second_id = str(uuid.uuid4())
    first_at = datetime(2026, 2, 10, 10, 0, tzinfo=timezone.utc).isoformat()
    second_at = datetime(2026, 2, 10, 11, 0, tzinfo=timezone.utc).isoformat()
    direct_payload = {
        "id": first_id,
        "medicine_type_id": med_type["id"],
        "child_id": child1["id"],
        "given_at": first_at,
    }
    sync_payload = {
        "items": [
            {
                "operation": "create",
                "table_name": "medicine_doses",
                "record_id": second_id,
                "payload": {
                    "medicine_type_id": med_type["id"],
                    "child_id": child1["id"],
                    "given_at": second_at,
                    "medicine_name": None,
                },
                "client_id": str(uuid.uuid4()),
                "client_timestamp": datetime.now(timezone.utc).isoformat(),
            }
        ]
    }
    start = asyncio.Event()

    async def deliver(path: str, payload: dict):
        await start.wait()
        return await client.post(path, json=payload, headers=adult_a_headers)

    direct = asyncio.create_task(
        deliver("/api/medicine/doses", direct_payload)
    )
    synced = asyncio.create_task(deliver("/api/sync/push", sync_payload))
    start.set()
    direct_response, sync_response = await asyncio.gather(direct, synced)

    assert direct_response.status_code == 201
    assert sync_response.status_code == 200
    direct_warnings = direct_response.json()["warnings"]
    sync_result = sync_response.json()["results"][0]
    assert sync_result["status"] == "accepted"
    warning_sets = [direct_warnings, sync_result["warnings"]]
    assert sorted(len(warnings) for warnings in warning_sets) == [0, 1]
    assert any(
        [warning["type"] for warning in warnings] == ["too_soon"]
        for warnings in warning_sets
    )

    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM medicine_doses WHERE id IN (?, ?)",
                    (first_id, second_id),
                )
            ).fetchone()
        )[0]
    assert count == 2


async def test_reused_dose_operation_id_with_different_payload_is_rejected(
    client,
    adult_a_headers,
    child1,
    initialized_db,
):
    med_type = await _create_type(client, adult_a_headers, child1["id"])
    operation_id = str(uuid.uuid4())
    payload = {
        "id": operation_id,
        "medicine_type_id": med_type["id"],
        "child_id": child1["id"],
        "given_at": datetime.now(timezone.utc).isoformat(),
        "notes": "Original",
    }
    first = await client.post(
        "/api/medicine/doses",
        json=payload,
        headers=adult_a_headers,
    )
    changed = await client.post(
        "/api/medicine/doses",
        json={**payload, "notes": "Changed"},
        headers=adult_a_headers,
    )

    assert first.status_code == 201
    assert changed.status_code == 409
    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM medicine_doses WHERE id = ?",
                    (operation_id,),
                )
            ).fetchone()
        )[0]
    assert count == 1


# ---------------------------------------------------------------------------
# Safety: "Too soon" warnings
# ---------------------------------------------------------------------------


async def test_dose_too_soon_warning(client, adult_a_user, adult_a_headers, child1):
    """Logging a dose only 1h after the previous one (min_hours=4) triggers too_soon."""
    med_type = await _create_type(
        client, adult_a_headers, child1["id"], min_hours_between_doses=4.0,
    )
    base = datetime(2026, 2, 8, 10, 0, 0, tzinfo=timezone.utc)

    # First dose at 10:00
    await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], base.isoformat())

    # Second dose at 11:00 — only 1 hour later
    too_soon = (base + timedelta(hours=1)).isoformat()
    result = await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], too_soon)

    assert len(result["warnings"]) >= 1
    types = [w["type"] for w in result["warnings"]]
    assert "too_soon" in types


async def test_dose_safe_after_interval(client, adult_a_user, adult_a_headers, child1):
    """Logging a dose 5h after the previous (min_hours=4) should be warning-free."""
    med_type = await _create_type(
        client, adult_a_headers, child1["id"], min_hours_between_doses=4.0,
    )
    base = datetime(2026, 2, 8, 10, 0, 0, tzinfo=timezone.utc)

    await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], base.isoformat())

    safe_time = (base + timedelta(hours=5)).isoformat()
    result = await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], safe_time)

    assert result["warnings"] == []


# ---------------------------------------------------------------------------
# Safety: "Child One reached" warnings
# ---------------------------------------------------------------------------


async def test_max_doses_warning(client, adult_a_user, adult_a_headers, child1):
    """Exceeding max_doses_24h in a 24-hour window triggers max_reached warning."""
    med_type = await _create_type(
        client, adult_a_headers, child1["id"],
        min_hours_between_doses=4.0,
        max_doses_24h=3,
    )
    base = datetime(2026, 2, 8, 6, 0, 0, tzinfo=timezone.utc)

    # Log 3 doses (the max) spaced 5 hours apart to avoid too_soon
    for i in range(3):
        t = (base + timedelta(hours=i * 5)).isoformat()
        await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], t)

    # 4th dose should trigger max_reached
    fourth = (base + timedelta(hours=15)).isoformat()
    result = await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], fourth)

    types = [w["type"] for w in result["warnings"]]
    assert "max_reached" in types


# ---------------------------------------------------------------------------
# Backdated dose safety
# ---------------------------------------------------------------------------


async def test_backdated_dose_too_soon(client, adult_a_user, adult_a_headers, child1):
    """Backdating a dose to 1pm when a dose exists at 2pm (min_hours=4) warns too_soon."""
    med_type = await _create_type(
        client, adult_a_headers, child1["id"], min_hours_between_doses=4.0,
    )
    # Existing dose at 2pm
    two_pm = datetime(2026, 2, 8, 14, 0, 0, tzinfo=timezone.utc).isoformat()
    await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], two_pm)

    # Backdate a dose to 1pm — only 1 hour before the existing dose
    one_pm = datetime(2026, 2, 8, 13, 0, 0, tzinfo=timezone.utc).isoformat()
    result = await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], one_pm)

    types = [w["type"] for w in result["warnings"]]
    assert "too_soon" in types


async def test_backdated_dose_safe(client, adult_a_user, adult_a_headers, child1):
    """Backdating a dose to 9am when a dose exists at 2pm (5h gap, min_hours=4) is safe."""
    med_type = await _create_type(
        client, adult_a_headers, child1["id"], min_hours_between_doses=4.0,
    )
    # Existing dose at 2pm
    two_pm = datetime(2026, 2, 8, 14, 0, 0, tzinfo=timezone.utc).isoformat()
    await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], two_pm)

    # Backdate a dose to 9am — 5 hours before, which is safe
    nine_am = datetime(2026, 2, 8, 9, 0, 0, tzinfo=timezone.utc).isoformat()
    result = await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], nine_am)

    assert result["warnings"] == []


async def test_backdated_dose_checks_future_rolling_24_hour_windows(
    client,
    adult_a_headers,
    child1,
):
    """A backdated dose can join earlier and later doses into one over-limit window."""
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=1.0,
        max_doses_24h=2,
    )
    proposed = datetime(2026, 2, 11, 12, 0, tzinfo=timezone.utc)
    await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        (proposed - timedelta(hours=20)).isoformat(),
    )
    await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        (proposed + timedelta(hours=3)).isoformat(),
    )

    result = await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        proposed.isoformat(),
    )

    assert [warning["type"] for warning in result["warnings"]] == ["max_reached"]


# ---------------------------------------------------------------------------
# Safety check endpoint
# ---------------------------------------------------------------------------


async def test_safety_check_endpoint(client, adult_a_user, adult_a_headers, child1):
    """GET /api/medicine/check/{type_id}/{child_id} returns safety status."""
    med_type = await _create_type(client, adult_a_headers, child1["id"])

    resp = await client.get(
        f"/api/medicine/check/{med_type['id']}/{child1['id']}",
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "safe" in data
    assert "warnings" in data
    assert isinstance(data["warnings"], list)
    # No doses yet, so it should be safe
    assert data["safe"] is True
    assert data["warnings"] == []


async def test_safety_check_uses_candidate_time_without_creating_a_dose(
    client,
    adult_a_headers,
    child1,
):
    """Preflight must evaluate the time selected in the form, not server now."""
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=4.0,
    )
    existing = datetime(2026, 2, 8, 14, 0, tzinfo=timezone.utc)
    await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        existing.isoformat(),
    )

    response = await client.get(
        f"/api/medicine/check/{med_type['id']}/{child1['id']}",
        params={"given_at": "2026-02-08T13:00:00+00:00"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    result = response.json()
    assert result["safe"] is False
    assert [warning["type"] for warning in result["warnings"]] == ["too_soon"]

    doses = await client.get(
        "/api/medicine/doses",
        params={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    assert len(doses.json()) == 1


async def test_safety_check_normalises_candidate_timezone_offset(
    client,
    adult_a_headers,
    child1,
):
    med_type = await _create_type(
        client,
        adult_a_headers,
        child1["id"],
        min_hours_between_doses=4.0,
    )
    await _log_dose(
        client,
        adult_a_headers,
        med_type["id"],
        child1["id"],
        "2026-06-08T12:00:00+00:00",
    )

    response = await client.get(
        f"/api/medicine/check/{med_type['id']}/{child1['id']}",
        params={"given_at": "2026-06-08T14:00:00+01:00"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert [warning["type"] for warning in response.json()["warnings"]] == ["too_soon"]


# ---------------------------------------------------------------------------
# Dose creation despite warnings
# ---------------------------------------------------------------------------


async def test_dose_creates_despite_warning(client, adult_a_user, adult_a_headers, child1):
    """Doses are ALWAYS created even when warnings are present — never silently blocked."""
    med_type = await _create_type(
        client, adult_a_headers, child1["id"], min_hours_between_doses=4.0,
    )
    base = datetime(2026, 2, 8, 10, 0, 0, tzinfo=timezone.utc)

    await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], base.isoformat())

    # Log again 1h later — will produce a warning
    too_soon = (base + timedelta(hours=1)).isoformat()
    result = await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], too_soon)

    # Warnings present
    assert len(result["warnings"]) >= 1

    # But the dose WAS created — verify it appears in the listing
    list_resp = await client.get(
        "/api/medicine/doses",
        params={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    assert list_resp.status_code == 200
    doses = list_resp.json()
    assert len(doses) == 2  # Both doses exist


# ---------------------------------------------------------------------------
# Dose listing / filtering
# ---------------------------------------------------------------------------


async def test_list_doses_by_child(client, adult_a_user, adult_a_headers, child1, child3):
    """GET /api/medicine/doses?child_id= filters doses by child."""
    type1 = await _create_type(client, adult_a_headers, child1["id"], name="Calpol")
    type3 = await _create_type(client, adult_a_headers, child3["id"], name="Nurofen")

    now = datetime.now(timezone.utc).isoformat()
    await _log_dose(client, adult_a_headers, type1["id"], child1["id"], now)
    later = (datetime.now(timezone.utc) + timedelta(hours=5)).isoformat()
    await _log_dose(client, adult_a_headers, type3["id"], child3["id"], later)

    resp = await client.get(
        "/api/medicine/doses",
        params={"child_id": child1["id"]},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    doses = resp.json()
    assert len(doses) == 1
    assert doses[0]["child_id"] == child1["id"]


async def test_list_doses_by_date(client, adult_a_user, adult_a_headers, child1):
    """GET /api/medicine/doses?date= filters by the date portion of given_at."""
    med_type = await _create_type(client, adult_a_headers, child1["id"])

    # Dose on Feb 8
    feb8 = datetime(2026, 2, 8, 10, 0, 0, tzinfo=timezone.utc).isoformat()
    await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], feb8)

    # Dose on Feb 9
    feb9 = datetime(2026, 2, 9, 10, 0, 0, tzinfo=timezone.utc).isoformat()
    await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], feb9)

    resp = await client.get(
        "/api/medicine/doses",
        params={"date": "2026-02-08"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    doses = resp.json()
    assert len(doses) == 1
    assert doses[0]["given_at"].startswith("2026-02-08")


# ---------------------------------------------------------------------------
# next_safe_at calculation
# ---------------------------------------------------------------------------


async def test_next_safe_at_calculation(client, adult_a_user, adult_a_headers, child1):
    """Verify next_safe_at is correctly calculated in a too_soon warning."""
    med_type = await _create_type(
        client, adult_a_headers, child1["id"], min_hours_between_doses=4.0,
    )
    base = datetime(2026, 2, 8, 10, 0, 0, tzinfo=timezone.utc)

    # First dose at 10:00
    await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], base.isoformat())

    # Second dose at 11:00 — too soon
    too_soon = (base + timedelta(hours=1)).isoformat()
    result = await _log_dose(client, adult_a_headers, med_type["id"], child1["id"], too_soon)

    too_soon_warnings = [w for w in result["warnings"] if w["type"] == "too_soon"]
    assert len(too_soon_warnings) == 1

    warning = too_soon_warnings[0]
    assert warning["next_safe_at"] is not None

    # next_safe_at should be base + 4 hours = 14:00
    expected = (base + timedelta(hours=4)).isoformat()
    assert warning["next_safe_at"] == expected
