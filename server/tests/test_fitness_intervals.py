"""Focused Intervals.icu connection, mapping, and convergence contracts."""

from __future__ import annotations

import asyncio
import gzip
import io
import json
import uuid
import zipfile
from urllib.parse import parse_qs, urlparse

import aiosqlite
import pytest
from cryptography.fernet import Fernet

from app.services.fitness import intervals_icu
from app.utils.encryption import decrypt_value


pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _intervals_configuration(monkeypatch):
    monkeypatch.setattr(
        intervals_icu.settings, "intervals_icu_integration_enabled", True
    )
    monkeypatch.setattr(intervals_icu.settings, "intervals_icu_client_id", "client-id")
    monkeypatch.setattr(
        intervals_icu.settings, "intervals_icu_client_secret", "client-secret"
    )
    monkeypatch.setattr(
        intervals_icu.settings,
        "intervals_icu_redirect_uri",
        "https://test/api/fitness/integrations/intervals/oauth/callback",
    )
    monkeypatch.setattr(intervals_icu.settings, "web_app_url", "https://web.test")
    monkeypatch.setattr(
        intervals_icu.settings,
        "ha_token_encryption_key",
        Fernet.generate_key().decode(),
    )


def _provider(calls: list[dict], *, garmin_ready: bool = True):
    async def request(method: str, path: str, *, credential: dict, json_body=None):
        calls.append({"method": method, "path": path, "json": json_body})
        assert credential["secret"] == "personal-key-123"
        if path == "/athlete/0":
            return {
                "id": "athlete-123",
                "name": "Runner",
                "icu_garmin_upload_workouts": garmin_ready,
            }
        if path == "/athlete/0/connections":
            return {"garmin_training_connected": True}
        if path == "/athlete/0/events/bulk?upsert=true":
            return [{"id": "event-123", "push_errors": ["Garmin queue delayed"]}]
        if path == "/athlete/0/events/event-123":
            return {"id": "event-123", "push_errors": ["Garmin rejected target"]}
        if path == "/athlete/0/events/bulk-delete":
            return 1
        raise AssertionError(path)

    return request


async def _connect(client, headers, monkeypatch, calls, *, garmin_ready=True):
    monkeypatch.setattr(
        intervals_icu,
        "_intervals_request",
        _provider(calls, garmin_ready=garmin_ready),
    )
    response = await client.post(
        "/api/fitness/integrations/intervals/connect",
        headers=headers,
        json={"api_key": "personal-key-123"},
    )
    assert response.status_code == 200, response.text
    return response.json()


def _plan_body(version_id: str, *, title="Tuesday intervals", status="scheduled"):
    return {
        "sport_key": "running",
        "title": title,
        "local_timezone": "Europe/Berlin",
        "workout_version_id": version_id,
        "status": status,
        "time_window_start_utc": "2026-08-11T06:00:00Z",
        "time_window_end_utc": "2026-08-11T07:00:00Z",
        "expected_duration_s": 1800,
    }


async def _create_planned_run(client, headers):
    definition_id = str(uuid.uuid4())
    version_id = str(uuid.uuid4())
    planned_session_id = str(uuid.uuid4())
    definition = await client.post(
        "/api/fitness/workout-definitions",
        headers=headers,
        json={
            "id": definition_id,
            "sport_key": "running",
            "name": "Tuesday intervals",
            "version": {
                "id": version_id,
                "title": "Tuesday intervals",
                "estimated_duration_s": 1800,
                "run_steps": [
                    {
                        "sequence": 0,
                        "duration_type": "distance_m",
                        "duration_value": 500,
                        "target_type": "pace_s_per_km",
                        "target_low": 270,
                        "target_high": 300,
                        "target_unit": "s/km",
                        "display_name": "Controlled rep",
                    }
                ],
            },
        },
    )
    assert definition.status_code == 201, definition.text
    accepted = await client.post(
        f"/api/fitness/workout-definitions/{definition_id}/versions/{version_id}/accept",
        headers=headers,
    )
    assert accepted.status_code == 200, accepted.text
    plan = await client.post(
        "/api/fitness/planned-sessions",
        headers=headers,
        json={"id": planned_session_id, **_plan_body(version_id)},
    )
    assert plan.status_code == 201, plan.text
    return definition_id, version_id, planned_session_id, plan.json()


async def test_api_key_is_encrypted_owner_private_and_garmin_readiness_is_effective(
    client, adult_a_user, adult_a_headers, adult_b_headers, initialized_db, monkeypatch
):
    calls: list[dict] = []
    status = await _connect(
        client, adult_a_headers, monkeypatch, calls, garmin_ready=False
    )
    assert status["connected"] is True
    assert status["auth_method"] == "personal_api_key"
    assert status["oauth_scopes"] == [
        "CALENDAR:WRITE",
        "SETTINGS:READ",
        "ACTIVITY:READ",
    ]
    assert status["activity_read_authorized"] is True
    assert status["activity_import_enabled"] is False
    assert status["garmin_training_connected"] is False
    assert (
        await client.get(
            "/api/fitness/integrations/intervals/status", headers=adult_b_headers
        )
    ).json()["status"] == "not_connected"

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        row = await (
            await db.execute("SELECT * FROM health_intervals_connections")
        ).fetchone()
    assert row["owner_user_id"] == adult_a_user["id"]
    assert "personal-key-123" not in row["encrypted_token_json"]
    credential = json.loads(decrypt_value(row["encrypted_token_json"]))
    assert credential["api_key"] == "personal-key-123"
    assert json.loads(row["scopes_json"]) == ["PERSONAL_API_KEY_BROAD"]


async def test_oauth_scope_and_failed_app_callback_preserve_return_surface(
    client, adult_a_headers, monkeypatch
):
    started = await client.post(
        "/api/fitness/integrations/intervals/oauth/start",
        headers=adult_a_headers,
        json={"return_surface": "app"},
    )
    assert started.status_code == 200, started.text
    query = parse_qs(urlparse(started.json()["authorization_url"]).query)
    assert query["scope"] == ["CALENDAR:WRITE,SETTINGS:READ,ACTIVITY:READ"]
    state = query["state"][0]

    async def failed_exchange(_code: str) -> str:
        raise intervals_icu.IntervalsProviderError("provider response is private")

    monkeypatch.setattr(intervals_icu, "_exchange_oauth_code", failed_exchange)
    callback = await client.get(
        "/api/fitness/integrations/intervals/oauth/callback",
        params={"state": state, "code": "short-lived"},
    )
    assert callback.status_code == 303
    assert callback.headers["location"] == "hausklar://fitness/intervals?status=failed"


async def test_completed_garmin_fit_import_is_opt_in_and_idempotent(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
    tmp_path,
):
    calls: list[dict] = []
    await _connect(client, adult_a_headers, monkeypatch, calls)
    monkeypatch.setattr(
        intervals_icu.settings,
        "fitness_storage_path",
        str(tmp_path / "health"),
    )
    monkeypatch.setattr(
        intervals_icu.settings,
        "fitness_cache_path",
        str(tmp_path / "cache"),
    )
    base_provider = _provider(calls)

    async def provider(method: str, path: str, *, credential: dict, json_body=None):
        if path.startswith("/athlete/0/activities?"):
            calls.append({"method": method, "path": path, "json": json_body})
            return [
                {
                    "id": "i-garmin-1",
                    "source": "GARMIN_CONNECT",
                    "file_type": "fit",
                    "device_name": "Garmin Forerunner 970",
                    "start_date": "2026-08-02T08:00:00Z",
                },
                {"id": "i-strava-1", "source": "STRAVA", "file_type": "fit"},
                {
                    "id": "i-garmin-tcx",
                    "source": "GARMIN_CONNECT",
                    "file_type": "tcx",
                },
            ]
        return await base_provider(
            method,
            path,
            credential=credential,
            json_body=json_body,
        )

    downloads: list[str] = []

    async def download(path: str, *, credential: dict) -> bytes:
        assert credential["secret"] == "personal-key-123"
        downloads.append(path)
        return gzip.compress(b"retained-garmin-fit")

    monkeypatch.setattr(intervals_icu, "_intervals_request", provider)
    monkeypatch.setattr(intervals_icu, "_intervals_binary_request", download)

    enabled = await client.put(
        "/api/fitness/integrations/intervals/activity-import",
        headers=adult_a_headers,
        json={"enabled": True, "lookback_days": 30},
    )
    assert enabled.status_code == 200, enabled.text
    assert enabled.json()["activity_import_enabled"] is True

    synced = await client.post(
        "/api/fitness/integrations/intervals/activity-import/sync",
        headers=adult_a_headers,
    )
    assert synced.status_code == 200, synced.text
    assert synced.json()["discovered_count"] == 3
    assert synced.json()["queued_count"] == 1
    assert synced.json()["skipped_count"] == 2
    assert synced.json()["status"]["activity_import_pending_count"] == 1
    assert downloads == ["/activity/i-garmin-1/file"]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        source = await (
            await db.execute(
                "SELECT * FROM health_source_records WHERE transport_key = 'intervals_icu'"
            )
        ).fetchone()
        imported = await (
            await db.execute(
                "SELECT i.*, f.storage_key FROM health_imports i "
                "JOIN health_file_assets f ON f.id = i.file_asset_id "
                "WHERE i.source_record_id = ?",
                (source["id"],),
            )
        ).fetchone()
    assert source["owner_user_id"] == adult_a_user["id"]
    assert source["origin_provider_key"] == "garmin"
    assert source["source_namespace"] == "intervals_icu:athlete-123"
    assert source["source_object_id"] == "i-garmin-1"
    assert source["source_device_identifier"] == "Garmin Forerunner 970"
    assert imported["status"] == "processing"
    assert (tmp_path / "health" / imported["storage_key"]).read_bytes() == b"retained-garmin-fit"

    replay = await client.post(
        "/api/fitness/integrations/intervals/activity-import/sync",
        headers=adult_a_headers,
    )
    assert replay.status_code == 200, replay.text
    assert replay.json()["queued_count"] == 0
    assert replay.json()["existing_count"] == 1
    assert downloads == ["/activity/i-garmin-1/file"]

    assert await intervals_icu.process_enabled_activity_imports() == 1
    assert downloads == ["/activity/i-garmin-1/file"]

    disabled = await client.put(
        "/api/fitness/integrations/intervals/activity-import",
        headers=adult_a_headers,
        json={"enabled": False, "lookback_days": 30},
    )
    assert disabled.json()["activity_import_enabled"] is False
    rejected = await client.post(
        "/api/fitness/integrations/intervals/activity-import/sync",
        headers=adult_a_headers,
    )
    assert rejected.status_code == 422


async def test_existing_oauth_connection_needs_activity_read_scope(
    client, adult_a_headers, initialized_db, monkeypatch
):
    calls: list[dict] = []
    await _connect(client, adult_a_headers, monkeypatch, calls)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_intervals_connections SET auth_method = 'oauth', "
            "scopes_json = '[\"CALENDAR:WRITE\",\"SETTINGS:READ\"]'"
        )
        await db.commit()
    status = await client.get(
        "/api/fitness/integrations/intervals/status", headers=adult_a_headers
    )
    assert status.json()["activity_read_authorized"] is False
    enabled = await client.put(
        "/api/fitness/integrations/intervals/activity-import",
        headers=adult_a_headers,
        json={"enabled": True, "lookback_days": 30},
    )
    assert enabled.status_code == 422
    assert "Reconnect Intervals.icu" in enabled.json()["detail"]


async def test_gzip_activity_file_expansion_is_bounded(monkeypatch):
    monkeypatch.setattr(intervals_icu.settings, "fitness_fit_max_upload_bytes", 5)
    with pytest.raises(intervals_icu.IntervalsActivityFileError) as raised:
        intervals_icu._decode_original_fit(gzip.compress(b"123456"))
    assert raised.value.code == "activity_file_too_large"


async def test_documented_workout_syntax_and_honest_mapping_warnings():
    description, warnings = intervals_icu._workout_description(
        [
            {
                "sequence": 0,
                "step_kind": "step",
                "duration_type": "distance_m",
                "duration_value": 500,
                "target_type": "pace_s_per_km",
                "target_low": 270,
                "target_high": 300,
                "display_name": "Pace",
            },
            {
                "sequence": 1,
                "step_kind": "step",
                "duration_type": "distance_m",
                "duration_value": 1500,
                "target_type": "heart_rate_zone",
                "target_low": 2,
                "target_high": 3,
                "display_name": "Aerobic",
            },
            {
                "sequence": 2,
                "step_kind": "step",
                "duration_type": "time_s",
                "duration_value": 60,
                "target_type": "power_zone",
                "target_low": 2,
                "target_high": 3,
                "display_name": "Power",
            },
            {
                "sequence": 3,
                "step_kind": "step",
                "duration_type": "time_s",
                "duration_value": 30,
                "target_type": "power_w",
                "target_low": 200,
                "target_high": 250,
                "display_name": "Watts",
            },
            {
                "sequence": 4,
                "step_kind": "repeat_block",
                "repeat_count": 3,
                "children": [
                    {
                        "sequence": 0,
                        "step_kind": "step",
                        "duration_type": "distance_m",
                        "duration_value": 400,
                        "target_type": "none",
                        "display_name": "Rep",
                    },
                    {
                        "sequence": 1,
                        "step_kind": "repeat_block",
                        "repeat_count": 2,
                        "children": [
                            {
                                "sequence": 0,
                                "step_kind": "step",
                                "duration_type": "time_s",
                                "duration_value": 60,
                                "target_type": "heart_rate_bpm",
                                "target_low": 140,
                                "target_high": 150,
                                "display_name": "Absolute HR",
                                "instruction_text": "Relax",
                            }
                        ],
                    },
                    {
                        "sequence": 2,
                        "step_kind": "step",
                        "duration_type": "calories",
                        "duration_value": 20,
                        "target_type": "rpe",
                        "target_low": 7,
                        "target_high": 8,
                        "display_name": "Unsupported finish",
                    },
                ],
            },
            {
                "sequence": 5,
                "step_kind": "repeat_block",
                "repeat_count": 2,
                "children": [
                    {
                        "sequence": 0,
                        "step_kind": "step",
                        "duration_type": "open",
                        "target_type": "none",
                        "display_name": "Manual only",
                    }
                ],
            },
        ],
        cues=[{"short_text": "Do not promise speech"}],
    )
    assert description.splitlines() == [
        "- Pace 500mtr 4:30-5:00/km Pace",
        "- Aerobic 1.5km Z2-Z3 HR",
        "- Power 1m Z2-Z3",
        "- Watts 30s 200-250w",
        "",
        "3x",
        "- Rep 400mtr",
        "- Absolute HR — Relax 1m",
        "- Absolute HR — Relax 1m",
    ]
    joined = " ".join(warnings)
    assert "Nested repeats were flattened" in joined
    assert "absolute heart-rate" in joined
    assert "calories duration remains" in joined
    assert "no safely deliverable child steps" in joined
    assert "speech are not guaranteed" in joined


async def test_send_update_scheduler_cancel_disconnect_and_owner_isolation(
    client, adult_a_headers, adult_b_headers, initialized_db, monkeypatch
):
    calls: list[dict] = []
    await _connect(client, adult_a_headers, monkeypatch, calls)
    _, version_id, plan_id, _ = await _create_planned_run(client, adult_a_headers)
    sent = await client.post(
        f"/api/fitness/integrations/intervals/workouts/{plan_id}",
        headers=adult_a_headers,
    )
    assert sent.status_code == 200, sent.text
    assert sent.json()["state"] == "sent"
    assert sent.json()["operation"] == "created"
    assert "Garmin queue delayed" in sent.json()["push_errors"]
    assert not any("Short step text" in item for item in sent.json()["push_errors"])
    publish_calls = [call for call in calls if "bulk?upsert" in call["path"]]
    outbound = publish_calls[0]["json"][0]
    assert outbound["start_date_local"] == "2026-08-11T08:00:00"
    assert outbound["description"] == "- Controlled rep 500mtr 4:30-5:00/km Pace"
    external_id = outbound["external_id"]

    replay = await client.post(
        f"/api/fitness/integrations/intervals/workouts/{plan_id}",
        headers=adult_a_headers,
    )
    assert replay.json()["operation"] == "unchanged"
    assert len([call for call in calls if "bulk?upsert" in call["path"]]) == 1
    cached = await client.get(
        f"/api/fitness/integrations/intervals/workouts/{plan_id}",
        headers=adult_a_headers,
    )
    assert cached.status_code == 200
    assert not any(call["path"] == "/athlete/0/events/event-123" for call in calls)
    refreshed = await client.get(
        f"/api/fitness/integrations/intervals/workouts/{plan_id}",
        headers=adult_a_headers,
        params={"refresh": "true"},
    )
    assert "Garmin rejected target" in refreshed.json()["push_errors"]
    assert (
        await client.get(
            f"/api/fitness/integrations/intervals/workouts/{plan_id}",
            headers=adult_b_headers,
        )
    ).status_code == 404

    changed = await client.patch(
        f"/api/fitness/planned-sessions/{plan_id}",
        headers=adult_a_headers,
        json=_plan_body(version_id, title="Moved intervals"),
    )
    assert changed.status_code == 200, changed.text
    pending = await client.get(
        f"/api/fitness/integrations/intervals/workouts/{plan_id}",
        headers=adult_a_headers,
    )
    assert pending.json()["state"] == "pending"
    updated = await client.post(
        f"/api/fitness/integrations/intervals/workouts/{plan_id}",
        headers=adult_a_headers,
    )
    assert updated.json()["operation"] == "updated"
    publish_calls = [call for call in calls if "bulk?upsert" in call["path"]]
    assert len(publish_calls) == 2
    assert publish_calls[1]["json"][0]["external_id"] == external_id
    assert publish_calls[1]["json"][0]["name"] == "Moved intervals"

    exported_response = await client.get("/api/fitness/export", headers=adult_a_headers)
    assert exported_response.status_code == 200
    with zipfile.ZipFile(io.BytesIO(exported_response.content)) as archive:
        exported = json.loads(archive.read("fitness-data.json"))
    assert "health_intervals_connections" not in exported["tables"]
    exported_publication = exported["tables"]["health_intervals_publications"][0]
    assert "payload" not in exported_publication
    assert "payload_json" not in exported_publication
    assert "personal-key-123" not in exported_response.content.decode(
        "latin-1", errors="ignore"
    )

    cancelled_plan = await client.patch(
        f"/api/fitness/planned-sessions/{plan_id}",
        headers=adult_a_headers,
        json=_plan_body(version_id, title="Moved intervals", status="cancelled"),
    )
    assert cancelled_plan.status_code == 200, cancelled_plan.text
    assert await intervals_icu.process_pending_deliveries() == 1
    delete_call = next(call for call in calls if call["path"].endswith("bulk-delete"))
    assert delete_call["method"] == "PUT"
    assert delete_call["json"] == [{"external_id": external_id}]

    disconnected = await client.delete(
        "/api/fitness/integrations/intervals", headers=adult_a_headers
    )
    assert disconnected.status_code == 200, disconnected.text
    assert disconnected.json()["retained_publication_count"] == 1
    async with aiosqlite.connect(initialized_db) as db:
        connection = await (
            await db.execute(
                "SELECT encrypted_token_json, provider_user_id "
                "FROM health_intervals_connections"
            )
        ).fetchone()
        publication = await (
            await db.execute(
                "SELECT payload_json FROM health_intervals_publications"
            )
        ).fetchone()
    assert connection == (None, None)
    assert publication == (None,)


def _sync_request(mutation: dict) -> dict:
    return {
        "sync_protocol_version": 1,
        "client_schema_version": 1,
        "client_app_version": "1",
        "client_build": "1",
        "platform": "ios",
        "device_id": str(uuid.uuid4()),
        "cursor": 0,
        "mutations": [mutation],
    }


async def test_offline_sync_edit_and_delete_queue_existing_publication(
    client, adult_a_headers, initialized_db, monkeypatch
):
    calls: list[dict] = []
    await _connect(client, adult_a_headers, monkeypatch, calls)
    _, version_id, plan_id, plan = await _create_planned_run(client, adult_a_headers)
    sent = await client.post(
        f"/api/fitness/integrations/intervals/workouts/{plan_id}", headers=adult_a_headers
    )
    assert sent.status_code == 200, sent.text

    mutation_id = str(uuid.uuid4())
    edited = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_request(
            {
                "mutation_id": mutation_id,
                "entity_type": "planned_session",
                "entity_id": plan_id,
                "operation": "upsert",
                "payload_schema_version": 1,
                "base_revision": plan["revision"],
                "payload": _plan_body(version_id, title="Offline move"),
                "created_at_client": "2026-08-11T05:00:00Z",
            }
        ),
    )
    assert edited.status_code == 200, edited.text
    revision = edited.json()["accepted"][0]["revision"]
    async with aiosqlite.connect(initialized_db) as db:
        queued = await (
            await db.execute(
                "SELECT state, desired_action FROM health_intervals_publications"
            )
        ).fetchone()
    assert queued == ("pending", "publish")

    deleted = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync_request(
            {
                "mutation_id": str(uuid.uuid4()),
                "entity_type": "planned_session",
                "entity_id": plan_id,
                "operation": "delete",
                "payload_schema_version": 1,
                "base_revision": revision,
                "payload": {},
                "created_at_client": "2026-08-11T05:01:00Z",
            }
        ),
    )
    assert deleted.status_code == 200, deleted.text
    async with aiosqlite.connect(initialized_db) as db:
        queued = await (
            await db.execute(
                "SELECT state, desired_action FROM health_intervals_publications"
            )
        ).fetchone()
    assert queued == ("pending", "cancel")


async def test_first_send_edit_race_keeps_newer_plan_pending(
    client, adult_a_headers, monkeypatch
):
    calls: list[dict] = []
    started = asyncio.Event()
    release = asyncio.Event()
    base_provider = _provider(calls)

    async def provider(method: str, path: str, *, credential: dict, json_body=None):
        if path == "/athlete/0/events/bulk?upsert=true":
            calls.append({"method": method, "path": path, "json": json_body})
            started.set()
            await release.wait()
            return [{"id": "event-123"}]
        return await base_provider(
            method, path, credential=credential, json_body=json_body
        )

    monkeypatch.setattr(intervals_icu, "_intervals_request", provider)
    connected = await client.post(
        "/api/fitness/integrations/intervals/connect",
        headers=adult_a_headers,
        json={"api_key": "personal-key-123"},
    )
    assert connected.status_code == 200, connected.text
    _, version_id, plan_id, _ = await _create_planned_run(client, adult_a_headers)

    sending = asyncio.create_task(
        client.post(
            f"/api/fitness/integrations/intervals/workouts/{plan_id}",
            headers=adult_a_headers,
        )
    )
    await started.wait()
    edited = await client.patch(
        f"/api/fitness/planned-sessions/{plan_id}",
        headers=adult_a_headers,
        json=_plan_body(version_id, title="Race winner"),
    )
    assert edited.status_code == 200, edited.text
    release.set()
    result = await sending
    assert result.status_code == 200, result.text
    assert result.json()["state"] == "pending"
    assert result.json()["operation"] == "created"


async def test_cancel_race_keeps_concurrent_reactivation_pending(
    client, adult_a_headers, initialized_db, monkeypatch
):
    calls: list[dict] = []
    cancel_started = asyncio.Event()
    release_cancel = asyncio.Event()
    should_block_cancel = False
    base_provider = _provider(calls)

    async def provider(method: str, path: str, *, credential: dict, json_body=None):
        if path == "/athlete/0/events/bulk-delete" and should_block_cancel:
            calls.append({"method": method, "path": path, "json": json_body})
            cancel_started.set()
            await release_cancel.wait()
            return 1
        return await base_provider(
            method, path, credential=credential, json_body=json_body
        )

    monkeypatch.setattr(intervals_icu, "_intervals_request", provider)
    connected = await client.post(
        "/api/fitness/integrations/intervals/connect",
        headers=adult_a_headers,
        json={"api_key": "personal-key-123"},
    )
    assert connected.status_code == 200, connected.text
    _, version_id, plan_id, _ = await _create_planned_run(client, adult_a_headers)
    sent = await client.post(
        f"/api/fitness/integrations/intervals/workouts/{plan_id}", headers=adult_a_headers
    )
    assert sent.status_code == 200, sent.text

    should_block_cancel = True
    cancelling = asyncio.create_task(
        client.delete(
            f"/api/fitness/integrations/intervals/workouts/{plan_id}",
            headers=adult_a_headers,
        )
    )
    await cancel_started.wait()
    reactivated = await client.patch(
        f"/api/fitness/planned-sessions/{plan_id}",
        headers=adult_a_headers,
        json=_plan_body(version_id, title="Keep this newer edit"),
    )
    assert reactivated.status_code == 200, reactivated.text
    release_cancel.set()
    result = await cancelling
    assert result.status_code == 200, result.text
    assert result.json()["state"] == "pending"
    async with aiosqlite.connect(initialized_db) as db:
        queued = await (
            await db.execute(
                "SELECT state, desired_action FROM health_intervals_publications"
            )
        ).fetchone()
    assert queued == ("pending", "publish")


async def test_failed_first_send_after_cancel_queues_safe_delete(
    client, adult_a_headers, initialized_db, monkeypatch
):
    calls: list[dict] = []
    publish_started = asyncio.Event()
    release_failure = asyncio.Event()
    should_fail = False
    base_provider = _provider(calls)

    async def provider(method: str, path: str, *, credential: dict, json_body=None):
        if path == "/athlete/0/events/bulk?upsert=true" and should_fail:
            calls.append({"method": method, "path": path, "json": json_body})
            publish_started.set()
            await release_failure.wait()
            raise intervals_icu.IntervalsProviderError("private provider detail")
        return await base_provider(
            method, path, credential=credential, json_body=json_body
        )

    monkeypatch.setattr(intervals_icu, "_intervals_request", provider)
    connected = await client.post(
        "/api/fitness/integrations/intervals/connect",
        headers=adult_a_headers,
        json={"api_key": "personal-key-123"},
    )
    assert connected.status_code == 200, connected.text
    _, version_id, plan_id, _ = await _create_planned_run(client, adult_a_headers)

    should_fail = True
    sending = asyncio.create_task(
        client.post(
            f"/api/fitness/integrations/intervals/workouts/{plan_id}",
            headers=adult_a_headers,
        )
    )
    await publish_started.wait()
    cancelled = await client.patch(
        f"/api/fitness/planned-sessions/{plan_id}",
        headers=adult_a_headers,
        json=_plan_body(version_id, status="cancelled"),
    )
    assert cancelled.status_code == 200, cancelled.text
    release_failure.set()
    failed = await sending
    assert failed.status_code == 502
    async with aiosqlite.connect(initialized_db) as db:
        queued = await (
            await db.execute(
                "SELECT state, desired_action, payload_json "
                "FROM health_intervals_publications"
            )
        ).fetchone()
    assert queued == ("error", "cancel", None)

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_intervals_publications SET next_retry_at = NULL"
        )
        await db.commit()
    should_fail = False
    assert await intervals_icu.process_pending_deliveries() == 1
    async with aiosqlite.connect(initialized_db) as db:
        final_state = await (
            await db.execute("SELECT state FROM health_intervals_publications")
        ).fetchone()
    assert final_state == ("cancelled",)


async def test_disconnect_wins_publish_in_flight_without_restoring_payload(
    client, adult_a_headers, initialized_db, monkeypatch
):
    calls: list[dict] = []
    publish_started = asyncio.Event()
    release_publish = asyncio.Event()
    should_block = False
    base_provider = _provider(calls)

    async def provider(method: str, path: str, *, credential: dict, json_body=None):
        if path == "/athlete/0/events/bulk?upsert=true" and should_block:
            calls.append({"method": method, "path": path, "json": json_body})
            publish_started.set()
            await release_publish.wait()
            return [{"id": "event-123"}]
        return await base_provider(
            method, path, credential=credential, json_body=json_body
        )

    monkeypatch.setattr(intervals_icu, "_intervals_request", provider)
    connected = await client.post(
        "/api/fitness/integrations/intervals/connect",
        headers=adult_a_headers,
        json={"api_key": "personal-key-123"},
    )
    assert connected.status_code == 200, connected.text
    _, _, plan_id, _ = await _create_planned_run(client, adult_a_headers)

    should_block = True
    sending = asyncio.create_task(
        client.post(
            f"/api/fitness/integrations/intervals/workouts/{plan_id}",
            headers=adult_a_headers,
        )
    )
    await publish_started.wait()
    disconnected = await client.delete(
        "/api/fitness/integrations/intervals", headers=adult_a_headers
    )
    assert disconnected.status_code == 200, disconnected.text
    release_publish.set()
    result = await sending
    assert result.status_code == 200, result.text
    assert result.json()["state"] == "error"
    assert result.json()["last_error_code"] == "disconnected"
    async with aiosqlite.connect(initialized_db) as db:
        connection = await (
            await db.execute(
                "SELECT encrypted_token_json, status FROM health_intervals_connections"
            )
        ).fetchone()
        publication = await (
            await db.execute(
                "SELECT payload_json, next_retry_at, attempt_count "
                "FROM health_intervals_publications"
            )
        ).fetchone()
    assert connection == (None, "disconnected")
    assert publication == (None, None, intervals_icu.MAX_SCHEDULED_RETRIES)
