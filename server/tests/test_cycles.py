import io
import json
import uuid
import zipfile
from datetime import date, datetime, timezone

import aiosqlite
import pytest

from app.database import init_db
from app.services.cycles import calculate_cycle_dates
from app.services.fitness import coach


pytestmark = pytest.mark.asyncio


async def test_cycle_calculation_uses_configured_length_and_fourteen_day_estimate():
    next_period, ovulation = calculate_cycle_dates(date(2026, 7, 1), 30)

    assert next_period == date(2026, 7, 31)
    assert ovulation == date(2026, 7, 17)


async def test_cycle_calculation_without_period_start_has_no_predictions():
    assert calculate_cycle_dates(None, 28) == (None, None)


async def _configure(client, headers, **overrides):
    body = {
        "cycle_length_days": 30,
        "share_with_adults": False,
        "show_period_starts": True,
        "show_predicted_period": True,
        "show_estimated_ovulation": True,
        **overrides,
    }
    response = await client.put("/api/cycles/settings", json=body, headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


async def test_owner_can_configure_log_and_receive_calculations(
    client,
    adult_b_headers,
):
    profile = await _configure(client, adult_b_headers)
    assert profile["is_owner"] is True
    assert profile["cycle_length_days"] == 30
    assert profile["predicted_next_period"] is None

    created = await client.post(
        "/api/cycles/periods",
        json={"started_on": "2026-07-01"},
        headers=adult_b_headers,
    )
    assert created.status_code == 201

    response = await client.get("/api/cycles/", headers=adult_b_headers)
    assert response.status_code == 200
    profile = response.json()[0]
    assert profile["latest_period_start"] == "2026-07-01"
    assert profile["predicted_next_period"] == "2026-07-31"
    assert profile["estimated_ovulation"] == "2026-07-17"


async def test_cycle_profile_is_private_until_owner_consents(
    client,
    adult_a_headers,
    adult_b_headers,
):
    await _configure(client, adult_b_headers, share_with_adults=False)
    await client.post(
        "/api/cycles/periods",
        json={"started_on": "2026-07-01"},
        headers=adult_b_headers,
    )

    hidden = await client.get("/api/cycles/", headers=adult_a_headers)
    assert hidden.status_code == 200
    assert hidden.json() == []

    await _configure(client, adult_b_headers, share_with_adults=True)
    visible = await client.get("/api/cycles/", headers=adult_a_headers)
    assert visible.status_code == 200
    assert visible.json()[0]["owner_name"] == "Morgan"
    assert visible.json()[0]["is_owner"] is False


async def test_shared_profile_exposes_only_selected_calendar_date_types(
    client,
    adult_a_headers,
    adult_b_headers,
):
    await _configure(
        client,
        adult_b_headers,
        share_with_adults=True,
        show_period_starts=False,
        show_predicted_period=True,
        show_estimated_ovulation=False,
    )
    await client.post(
        "/api/cycles/periods",
        json={"started_on": "2026-07-01"},
        headers=adult_b_headers,
    )

    shared = (await client.get("/api/cycles/", headers=adult_a_headers)).json()[0]
    assert shared["period_starts"] == []
    assert shared["latest_period_start"] is None
    assert shared["predicted_next_period"] == "2026-07-31"
    assert shared["estimated_ovulation"] is None


async def test_admin_cannot_change_or_delete_another_adults_cycle_data(
    client,
    adult_a_headers,
    adult_b_headers,
):
    await _configure(client, adult_b_headers, share_with_adults=True)
    created = await client.post(
        "/api/cycles/periods",
        json={"started_on": "2026-07-01"},
        headers=adult_b_headers,
    )
    period_id = created.json()["id"]

    deletion = await client.delete(f"/api/cycles/periods/{period_id}", headers=adult_a_headers)
    assert deletion.status_code == 404

    still_visible = await client.get("/api/cycles/", headers=adult_b_headers)
    assert still_visible.json()[0]["period_starts"][0]["id"] == period_id


async def test_duplicate_period_start_is_rejected(
    client,
    adult_b_headers,
):
    await _configure(client, adult_b_headers)
    first = await client.post(
        "/api/cycles/periods",
        json={"started_on": "2026-07-01"},
        headers=adult_b_headers,
    )
    second = await client.post(
        "/api/cycles/periods",
        json={"started_on": "2026-07-01"},
        headers=adult_b_headers,
    )
    assert first.status_code == 201
    assert second.status_code == 409


async def test_direct_cycle_writes_safely_replay_client_generated_ids(
    client,
    adult_b_headers,
):
    settings_id = str(uuid.uuid4())
    settings_body = {
        "id": settings_id,
        "cycle_length_days": 31,
        "share_with_adults": False,
        "show_period_starts": True,
        "show_predicted_period": True,
        "show_estimated_ovulation": True,
    }
    first_settings = await client.put(
        "/api/cycles/settings",
        json=settings_body,
        headers=adult_b_headers,
    )
    replayed_settings = await client.put(
        "/api/cycles/settings",
        json=settings_body,
        headers=adult_b_headers,
    )
    assert first_settings.status_code == 200
    assert replayed_settings.status_code == 200
    assert first_settings.json()["id"] == settings_id
    assert replayed_settings.json()["id"] == settings_id

    period_id = str(uuid.uuid4())
    period_body = {"id": period_id, "started_on": "2026-07-01"}
    first_period = await client.post(
        "/api/cycles/periods",
        json=period_body,
        headers=adult_b_headers,
    )
    replayed_period = await client.post(
        "/api/cycles/periods",
        json=period_body,
        headers=adult_b_headers,
    )
    assert first_period.status_code == 201
    assert replayed_period.status_code == 201
    assert first_period.json()["id"] == period_id
    assert replayed_period.json()["id"] == period_id

    first_delete = await client.delete(
        f"/api/cycles/periods/{period_id}",
        headers=adult_b_headers,
    )
    replayed_delete = await client.delete(
        f"/api/cycles/periods/{period_id}",
        headers=adult_b_headers,
    )
    assert first_delete.status_code == 204
    assert replayed_delete.status_code == 204


async def test_period_operation_id_cannot_be_reused_for_a_different_date(
    client,
    adult_b_headers,
):
    await _configure(client, adult_b_headers)
    period_id = str(uuid.uuid4())
    first = await client.post(
        "/api/cycles/periods",
        json={"id": period_id, "started_on": "2026-07-01"},
        headers=adult_b_headers,
    )
    mismatch = await client.post(
        "/api/cycles/periods",
        json={"id": period_id, "started_on": "2026-07-02"},
        headers=adult_b_headers,
    )
    assert first.status_code == 201
    assert mismatch.status_code == 409


async def test_cycle_settings_and_period_starts_replay_through_offline_sync(
    client,
    adult_b_headers,
):
    now = datetime.now(timezone.utc).isoformat()
    settings_id = str(uuid.uuid4())
    period_id = str(uuid.uuid4())
    response = await client.post(
        "/api/sync/push",
        json={
            "items": [
                {
                    "operation": "create",
                    "table_name": "cycle_settings",
                    "record_id": settings_id,
                    "payload": {
                        "cycle_length_days": 32,
                        "share_with_adults": True,
                        "show_period_starts": True,
                        "show_predicted_period": True,
                        "show_estimated_ovulation": True,
                    },
                    "client_id": "ios-cycle-test",
                    "client_timestamp": now,
                },
                {
                    "operation": "create",
                    "table_name": "cycle_period_starts",
                    "record_id": period_id,
                    "payload": {"started_on": "2026-07-01"},
                    "client_id": "ios-cycle-test",
                    "client_timestamp": now,
                },
            ]
        },
        headers=adult_b_headers,
    )
    assert response.status_code == 200, response.text
    assert [result["status"] for result in response.json()["results"]] == [
        "accepted",
        "accepted",
    ]

    profile = (await client.get("/api/cycles/", headers=adult_b_headers)).json()[0]
    assert profile["id"] == settings_id
    assert profile["cycle_length_days"] == 32
    assert profile["period_starts"][0]["id"] == period_id
    assert profile["predicted_next_period"] == "2026-08-02"

    delete_item = {
        "operation": "delete",
        "table_name": "cycle_period_starts",
        "record_id": period_id,
        "payload": None,
        "client_id": "ios-cycle-test",
        "client_timestamp": datetime.now(timezone.utc).isoformat(),
    }
    deleted = await client.post(
        "/api/sync/push",
        json={"items": [delete_item]},
        headers=adult_b_headers,
    )
    replayed = await client.post(
        "/api/sync/push",
        json={"items": [delete_item]},
        headers=adult_b_headers,
    )
    assert deleted.json()["results"][0]["status"] == "accepted"
    assert replayed.json()["results"][0]["status"] == "accepted"


async def test_offline_sync_cannot_mutate_another_adults_cycle(
    client,
    adult_a_headers,
    adult_b_headers,
):
    profile = await _configure(client, adult_b_headers, share_with_adults=True)
    response = await client.post(
        "/api/sync/push",
        json={
            "items": [
                {
                    "operation": "update",
                    "table_name": "cycle_settings",
                    "record_id": profile["id"],
                    "payload": {
                        "cycle_length_days": 20,
                        "share_with_adults": False,
                        "show_period_starts": False,
                        "show_predicted_period": False,
                        "show_estimated_ovulation": False,
                    },
                    "client_id": "malicious-family-client",
                    "client_timestamp": datetime.now(timezone.utc).isoformat(),
                }
            ]
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    assert response.json()["results"][0]["status"] == "error"

    unchanged = (await client.get("/api/cycles/", headers=adult_b_headers)).json()[0]
    assert unchanged["cycle_length_days"] == 30
    assert unchanged["share_with_adults"] is True


async def test_calendar_projects_only_visible_enabled_cycle_entries(
    client,
    adult_a_headers,
    adult_b_headers,
):
    await _configure(
        client,
        adult_b_headers,
        share_with_adults=True,
        show_period_starts=True,
        show_predicted_period=True,
        show_estimated_ovulation=False,
    )
    await client.post(
        "/api/cycles/periods",
        json={"started_on": "2026-07-01"},
        headers=adult_b_headers,
    )

    response = await client.get(
        "/api/calendar/?start=2026-07-01&end=2026-08-02&limit=200",
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    cycle_events = [
        event for event in response.json() if event["event_type"].startswith("cycle_")
    ]
    assert [(event["title"], event["start_time"]) for event in cycle_events] == [
        ("Period started", "2026-07-01"),
        ("Predicted period", "2026-07-31"),
    ]
    assert all(event["read_only"] for event in cycle_events)
    assert all(event["assigned_to"].endswith("0002") for event in cycle_events)


async def test_revoking_consent_removes_cycle_events_from_other_adult_calendar(
    client,
    adult_a_headers,
    adult_b_headers,
):
    await _configure(client, adult_b_headers, share_with_adults=True)
    await client.post(
        "/api/cycles/periods",
        json={"started_on": "2026-07-01"},
        headers=adult_b_headers,
    )
    await _configure(client, adult_b_headers, share_with_adults=False)

    response = await client.get(
        "/api/calendar/?start=2026-07-01&end=2026-08-02&limit=200",
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    assert not any(
        event["event_type"].startswith("cycle_") for event in response.json()
    )


async def test_fitness_cycle_api_splits_personal_display_from_category_sharing(
    client,
    adult_a_headers,
    adult_b_headers,
):
    settings_id = str(uuid.uuid4())
    configured = await client.put(
        "/api/fitness/cycles/settings",
        headers=adult_b_headers,
        json={
            "id": settings_id,
            "cycle_length_days": 29,
            "show_period_starts": True,
            "show_predicted_period": True,
            "show_estimated_ovulation": True,
            "share_period_starts_with_adults": False,
            "share_predicted_period_with_adults": True,
            "share_estimated_ovulation_with_adults": False,
        },
    )
    assert configured.status_code == 200, configured.text
    assert configured.json()["id"] == settings_id
    assert configured.json()["share_predicted_period_with_adults"] is True
    created = await client.post(
        "/api/fitness/cycles/periods",
        headers=adult_b_headers,
        json={"id": str(uuid.uuid4()), "started_on": "2026-07-01"},
    )
    assert created.status_code == 201, created.text

    shared = (await client.get("/api/fitness/cycles", headers=adult_a_headers)).json()[0]
    assert shared["show_period_starts"] is False
    assert shared["show_predicted_period"] is True
    assert shared["show_estimated_ovulation"] is False
    assert shared["period_starts"] == []
    assert shared["latest_period_start"] is None
    assert shared["predicted_next_period"] == "2026-07-30"

    legacy = (await client.get("/api/cycles/", headers=adult_a_headers)).json()[0]
    assert legacy["share_with_adults"] is True
    assert legacy["show_period_starts"] is False
    assert legacy["show_predicted_period"] is True

    exported = await client.get("/api/fitness/export", headers=adult_b_headers)
    assert exported.status_code == 200
    with zipfile.ZipFile(io.BytesIO(exported.content)) as archive:
        data = json.loads(archive.read("fitness-data.json"))
    assert [
        item["id"] for item in data["tables"]["health_cycle_settings"]
    ] == [settings_id]
    assert len(data["tables"]["health_cycle_period_starts"]) == 1


async def test_assistant_cycle_context_is_owner_private(
    client,
    adult_a_user,
    adult_b_user,
    adult_b_headers,
    initialized_db,
):
    configured = await client.put(
        "/api/fitness/cycles/settings",
        headers=adult_b_headers,
        json={
            "cycle_length_days": 29,
            "show_period_starts": True,
            "show_predicted_period": True,
            "show_estimated_ovulation": True,
            "share_period_starts_with_adults": True,
            "share_predicted_period_with_adults": True,
            "share_estimated_ovulation_with_adults": True,
        },
    )
    assert configured.status_code == 200, configured.text
    recorded = await client.post(
        "/api/fitness/cycles/periods",
        headers=adult_b_headers,
        json={"started_on": "2026-07-15"},
    )
    assert recorded.status_code == 201, recorded.text

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        adult_b_snapshot = await coach.build_owner_read_snapshot(
            db,
            user=adult_b_user,
            today=date(2026, 8, 12),
        )
        adult_a_snapshot = await coach.build_owner_read_snapshot(
            db,
            user=adult_a_user,
            today=date(2026, 8, 12),
        )

    cycle = next(item for item in adult_b_snapshot if item["id"] == "owner-cycle-history")
    assert cycle["facts"]["period_starts"] == [
        {"id": recorded.json()["id"], "started_on": "2026-07-15"}
    ]
    assert not any(item["id"] == "owner-cycle-history" for item in adult_a_snapshot)


def _fitness_sync_body(mutations, cursor=0):
    return {
        "sync_protocol_version": 1,
        "client_schema_version": 1,
        "client_app_version": "cycle-tests",
        "client_build": "1",
        "platform": "ios",
        "device_id": "cycle-test-device",
        "cursor": cursor,
        "mutations": mutations,
    }


def _fitness_cycle_mutation(entity_type, entity_id, operation, payload, base_revision=None):
    return {
        "mutation_id": str(uuid.uuid4()),
        "entity_type": entity_type,
        "entity_id": entity_id,
        "operation": operation,
        "payload_schema_version": 1,
        "base_revision": base_revision,
        "payload": payload,
        "created_at_client": datetime.now(timezone.utc).isoformat(),
    }


async def test_fitness_sync_cycle_delete_restore_and_snapshot(client, adult_b_headers):
    settings_id = str(uuid.uuid4())
    period_id = str(uuid.uuid4())
    created = await client.post(
        "/api/fitness/sync",
        headers=adult_b_headers,
        json=_fitness_sync_body(
            [
                _fitness_cycle_mutation(
                    "cycle_settings",
                    settings_id,
                    "upsert",
                    {
                        "id": settings_id,
                        "cycle_length_days": 30,
                        "show_period_starts": True,
                        "show_predicted_period": True,
                        "show_estimated_ovulation": True,
                        "share_period_starts_with_adults": False,
                        "share_predicted_period_with_adults": False,
                        "share_estimated_ovulation_with_adults": False,
                    },
                ),
                _fitness_cycle_mutation(
                    "cycle_period_start",
                    period_id,
                    "upsert",
                    {"id": period_id, "started_on": "2026-07-01"},
                ),
            ]
        ),
    )
    assert created.status_code == 200, created.text
    assert {item["entity_id"] for item in created.json()["accepted"]} == {
        settings_id,
        period_id,
    }
    cursor = created.json()["next_cursor"]

    deleted = await client.post(
        "/api/fitness/sync",
        headers=adult_b_headers,
        json=_fitness_sync_body(
            [
                _fitness_cycle_mutation(
                    "cycle_period_start",
                    period_id,
                    "delete",
                    {},
                    base_revision=1,
                )
            ],
            cursor=cursor,
        ),
    )
    assert deleted.status_code == 200, deleted.text
    assert deleted.json()["accepted"][0]["revision"] == 2
    assert any(
        change["entity_type"] == "cycle_period_start"
        and change["entity_id"] == period_id
        and change["operation"] == "delete"
        for change in deleted.json()["changes"]
    )

    restored = await client.post(
        "/api/fitness/sync",
        headers=adult_b_headers,
        json=_fitness_sync_body(
            [
                _fitness_cycle_mutation(
                    "cycle_period_start",
                    period_id,
                    "upsert",
                    {"id": period_id, "started_on": "2026-07-01"},
                    base_revision=2,
                )
            ],
            cursor=deleted.json()["next_cursor"],
        ),
    )
    assert restored.status_code == 200, restored.text
    assert restored.json()["accepted"][0]["revision"] == 3
    restored_change = next(
        change
        for change in restored.json()["changes"]
        if change["entity_type"] == "cycle_period_start"
        and change["entity_id"] == period_id
    )
    assert restored_change["operation"] == "upsert"
    assert restored_change["data"]["started_on"] == "2026-07-01"

    snapshot = await client.get("/api/fitness/sync/snapshot", headers=adult_b_headers)
    assert snapshot.status_code == 200, snapshot.text
    assert {
        (item["entity_type"], item["entity_id"])
        for item in snapshot.json()["entities"]
    } >= {
        ("cycle_settings", settings_id),
        ("cycle_period_start", period_id),
    }


async def test_cycle_migration_preserves_metadata_soft_deletes_and_is_idempotent(
    tmp_path,
):
    path = tmp_path / "cycle-migration.db"
    await init_db(str(path))
    settings_id, period_id = str(uuid.uuid4()), str(uuid.uuid4())
    family_id, owner_id = str(uuid.uuid4()), str(uuid.uuid4())
    created_at = "2025-01-02T03:04:05+00:00"
    updated_at = "2026-02-03T04:05:06+00:00"
    deleted_at = "2026-03-04T05:06:07+00:00"
    async with aiosqlite.connect(path) as db:
        await db.execute(
            "INSERT INTO cycle_settings (id, owner_user_id, cycle_length_days, "
            "share_with_adults, show_period_starts, show_predicted_period, "
            "show_estimated_ovulation, family_id, created_at, updated_at, created_by, "
            "client_id, client_timestamp) VALUES (?, ?, 31, 1, 0, 1, 1, ?, ?, ?, ?, ?, ?)",
            (
                settings_id,
                owner_id,
                family_id,
                created_at,
                updated_at,
                owner_id,
                "legacy-ios",
                created_at,
            ),
        )
        await db.execute(
            "INSERT INTO cycle_period_starts (id, owner_user_id, started_on, family_id, "
            "created_at, updated_at, created_by, client_id, client_timestamp, deleted_at) "
            "VALUES (?, ?, '2026-01-01', ?, ?, ?, ?, ?, ?, ?)",
            (
                period_id,
                owner_id,
                family_id,
                created_at,
                updated_at,
                owner_id,
                "legacy-ios",
                created_at,
                deleted_at,
            ),
        )
        await db.commit()

    await init_db(str(path))
    await init_db(str(path))
    async with aiosqlite.connect(path) as db:
        db.row_factory = aiosqlite.Row
        settings = await (
            await db.execute(
                "SELECT * FROM health_cycle_settings WHERE id = ?", (settings_id,)
            )
        ).fetchone()
        period = await (
            await db.execute(
                "SELECT * FROM health_cycle_period_starts WHERE id = ?", (period_id,)
            )
        ).fetchone()
        change_count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_change_log WHERE entity_id IN (?, ?)",
                (settings_id, period_id),
            )
        ).fetchone()
    assert settings["created_at"] == created_at
    assert settings["updated_at"] == updated_at
    assert settings["client_id"] == "legacy-ios"
    assert settings["client_timestamp"] == created_at
    assert settings["share_period_starts_with_adults"] == 0
    assert settings["share_predicted_period_with_adults"] == 1
    assert settings["share_estimated_ovulation_with_adults"] == 1
    assert period["deleted_at"] == deleted_at
    assert change_count[0] == 2
