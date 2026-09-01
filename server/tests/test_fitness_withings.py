"""Owner-bound Withings OAuth, import, webhook, and chart contracts."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse

import aiosqlite
import pytest
from cryptography.fernet import Fernet

from app.services.fitness import withings
from app.utils.encryption import decrypt_value


pytestmark = pytest.mark.asyncio


async def test_withings_notification_source_uses_published_dns_allowlist(monkeypatch):
    class FakeResponse:
        content = b"{}"

        def raise_for_status(self):
            return None

        def json(self):
            return {
                "Answer": [
                    {
                        "type": 16,
                        "data": '"89.30.121.171 89.30.121.172"',
                    }
                ]
            }

    class FakeClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def get(self, *_args, **_kwargs):
            return FakeResponse()

    monkeypatch.setattr(withings, "_notification_networks", ())
    monkeypatch.setattr(withings, "_notification_networks_updated_at", None)
    monkeypatch.setattr(withings.httpx, "AsyncClient", lambda **_kwargs: FakeClient())
    assert await withings.notification_source_allowed("89.30.121.171") is True
    assert await withings.notification_source_allowed("203.0.113.9") is False


@pytest.fixture(autouse=True)
def _withings_configuration(monkeypatch):
    monkeypatch.setattr(withings.settings, "withings_integration_enabled", True)
    monkeypatch.setattr(withings.settings, "withings_client_id", "client-id")
    monkeypatch.setattr(withings.settings, "withings_client_secret", "client-secret")
    monkeypatch.setattr(
        withings.settings,
        "withings_redirect_uri",
        "https://test/api/fitness/integrations/withings/callback",
    )
    monkeypatch.setattr(
        withings.settings,
        "withings_webhook_secret",
        "test-withings-webhook-secret-0123456789",
    )
    monkeypatch.setattr(withings.settings, "app_base_url", "https://test")
    monkeypatch.setattr(withings.settings, "web_app_url", "https://web.test")
    monkeypatch.setattr(
        withings.settings, "ha_token_encryption_key", Fernet.generate_key().decode()
    )


async def _connect(client, adult_a_headers, monkeypatch) -> str:
    async def provider(url: str, *, data: dict, access_token: str | None = None):
        assert url == withings.WITHINGS_TOKEN_URL
        assert data["grant_type"] == "authorization_code"
        return {
            "userid": "123456",
            "access_token": "access-first",
            "refresh_token": "refresh-first",
            "scope": "user.metrics",
            "expires_in": 10_800,
        }

    async def no_background(_connection_id: str) -> None:
        return None

    monkeypatch.setattr(withings, "_withings_post", provider)
    monkeypatch.setattr(withings, "finish_connection_setup", no_background)
    started = await client.post(
        "/api/fitness/integrations/withings/start",
        headers=adult_a_headers,
        json={"return_surface": "app"},
    )
    assert started.status_code == 200, started.text
    authorization_url = started.json()["authorization_url"]
    state = parse_qs(urlparse(authorization_url).query)["state"][0]
    callback = await client.get(
        "/api/fitness/integrations/withings/callback",
        params={"state": state, "code": "short-lived-code"},
    )
    assert callback.status_code == 303, callback.text
    assert callback.headers["location"] == "hausklar://fitness/withings?status=connected"
    status = await client.get(
        "/api/fitness/integrations/withings/status", headers=adult_a_headers
    )
    assert status.status_code == 200
    assert status.json()["connected"] is True
    return state


async def test_oauth_callback_accepts_withings_reachability_probe(client):
    response = await client.get("/api/fitness/integrations/withings/callback")
    head_response = await client.head("/api/fitness/integrations/withings/callback")

    assert response.status_code == 200
    assert response.text == "HausKlar Withings OAuth callback is ready"
    assert head_response.status_code == 200
    assert head_response.content == b""


async def test_oauth_state_is_hashed_and_tokens_are_encrypted(
    client, adult_a_user, adult_a_headers, initialized_db, monkeypatch
):
    state = await _connect(client, adult_a_headers, monkeypatch)
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        oauth = await (
            await db.execute("SELECT * FROM health_provider_oauth_states")
        ).fetchone()
        connection = await (
            await db.execute("SELECT * FROM health_provider_connections")
        ).fetchone()
    assert oauth["state_digest"] != state
    assert len(oauth["state_digest"]) == 64
    assert oauth["consumed_at"] is not None
    assert connection["owner_user_id"] == adult_a_user["id"]
    assert "access-first" not in connection["encrypted_token_json"]
    assert "refresh-first" not in connection["encrypted_token_json"]
    tokens = json.loads(decrypt_value(connection["encrypted_token_json"]))
    assert tokens == {
        "access_token": "access-first",
        "refresh_token": "refresh-first",
    }


async def test_oauth_state_is_one_time(client, adult_a_headers, monkeypatch):
    state = await _connect(client, adult_a_headers, monkeypatch)
    replay = await client.get(
        "/api/fitness/integrations/withings/callback",
        params={"state": state, "code": "replayed"},
    )
    assert replay.status_code == 303
    assert replay.headers["location"].endswith("withings=failed")


def _measure_body() -> dict:
    dates = [
        int(datetime(2026, 7, day, 7, tzinfo=timezone.utc).timestamp())
        for day in (1, 2, 10)
    ]
    weights = (80.0, 81.0, 78.0)
    groups = []
    for index, (timestamp, weight) in enumerate(zip(dates, weights, strict=True)):
        groups.append(
            {
                "grpid": 7000 + index,
                "date": timestamp,
                "created": timestamp,
                "modified": timestamp,
                "category": 1,
                "deviceid": "scale-1",
                "measures": [
                    {"type": 1, "value": int(weight * 100), "unit": -2},
                    {"type": 6, "value": 210 + index, "unit": -1},
                    *([{"type": 4, "value": 180, "unit": -2}] if index == 0 else []),
                ],
            }
        )
    bp_timestamp = int(datetime(2026, 7, 10, 8, tzinfo=timezone.utc).timestamp())
    groups.append(
        {
            "grpid": 8000,
            "date": bp_timestamp,
            "category": 1,
            "deviceid": "bpm-1",
            "measures": [
                {"type": 10, "value": 122, "unit": 0},
                {"type": 9, "value": 78, "unit": 0},
                {"type": 11, "value": 61, "unit": 0},
            ],
        }
    )
    # Category 2 is a target, not a real scale observation.
    groups.append(
        {
            "grpid": 9000,
            "date": bp_timestamp,
            "category": 2,
            "measures": [{"type": 1, "value": 6500, "unit": -2}],
        }
    )
    return {
        "updatetime": int(datetime(2026, 7, 10, 9, tzinfo=timezone.utc).timestamp()),
        "timezone": "Europe/Berlin",
        "measuregrps": groups,
        "more": 0,
    }


async def test_sync_normalises_scale_and_blood_pressure_idempotently(
    client, adult_a_headers, initialized_db, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch)
    measure_body = _measure_body()

    async def provider(url: str, *, data: dict, access_token: str | None = None):
        assert url == withings.WITHINGS_MEASURE_URL
        assert access_token == "access-first"
        assert data["meastypes"] == "1,4,5,6,8,9,10,11,76,77,88"
        return measure_body

    monkeypatch.setattr(withings, "_withings_post", provider)
    first = await client.post(
        "/api/fitness/integrations/withings/sync", headers=adult_a_headers
    )
    assert first.status_code == 200, first.text
    assert first.json()["imported"] == 10
    assert first.json()["ignored"] == 1

    second = await client.post(
        "/api/fitness/integrations/withings/sync", headers=adult_a_headers
    )
    assert second.status_code == 200, second.text
    assert second.json()["unchanged"] == 10
    assert second.json()["imported"] == 0

    weights = await client.get(
        "/api/fitness/body/measurements",
        params={"metric_key": "body.weight_kg"},
        headers=adult_a_headers,
    )
    assert [item["value"] for item in reversed(weights.json())] == [80.0, 81.0, 78.0]
    assert all(item["source"]["transport_key"] == "withings_api" for item in weights.json())

    heights = await client.get(
        "/api/fitness/body/measurements",
        params={"metric_key": "body.height_m"},
        headers=adult_a_headers,
    )
    assert [(item["value"], item["unit_key"]) for item in heights.json()] == [(1.8, "m")]

    observations = await client.get(
        "/api/fitness/recovery/observations",
        headers=adult_a_headers,
        params={"from_date": "2026-07-01", "to_date": "2026-07-31", "limit": 200},
    )
    metrics = {item["metric_key"]: item["value_number"] for item in observations.json()}
    assert metrics["vitals.blood_pressure_systolic_mmhg"] == 122
    assert metrics["vitals.blood_pressure_diastolic_mmhg"] == 78
    assert metrics["vitals.heart_rate_bpm"] == 61

    async with aiosqlite.connect(initialized_db) as db:
        source_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM health_source_records WHERE transport_key='withings_api'"
                )
            ).fetchone()
        )[0]
    assert source_count == 10


async def test_sync_backfills_height_for_an_existing_connection(
    client, adult_a_headers, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch)
    normal_body = _measure_body()
    for group in normal_body["measuregrps"]:
        group["measures"] = [item for item in group["measures"] if item["type"] != 4]
    height_timestamp = int(datetime(2024, 1, 1, 7, tzinfo=timezone.utc).timestamp())
    requested_types = []

    async def provider(url: str, *, data: dict, access_token: str | None = None):
        requested_types.append(data["meastypes"])
        if data["meastypes"] == "4":
            return {
                "updatetime": height_timestamp,
                "timezone": "Europe/London",
                "measuregrps": [{
                    "grpid": 4000,
                    "date": height_timestamp,
                    "category": 1,
                    "measures": [{"type": 4, "value": 180, "unit": -2}],
                }],
                "more": 0,
            }
        return normal_body

    monkeypatch.setattr(withings, "_withings_post", provider)
    response = await client.post(
        "/api/fitness/integrations/withings/sync", headers=adult_a_headers
    )
    assert response.status_code == 200, response.text
    assert requested_types == ["1,4,5,6,8,9,10,11,76,77,88", "4"]
    heights = await client.get(
        "/api/fitness/body/measurements",
        params={"metric_key": "body.height_m"},
        headers=adult_a_headers,
    )
    assert [(item["value"], item["unit_key"]) for item in heights.json()] == [(1.8, "m")]


async def test_history_returns_raw_and_time_aware_trend(
    client, adult_a_headers, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch)

    async def provider(url: str, *, data: dict, access_token: str | None = None):
        return _measure_body()

    monkeypatch.setattr(withings, "_withings_post", provider)
    await client.post("/api/fitness/integrations/withings/sync", headers=adult_a_headers)

    weight = await client.get(
        "/api/fitness/measurements/history",
        headers=adult_a_headers,
        params={"metric": "weight", "start_on": "2026-07-02"},
    )
    assert weight.status_code == 200, weight.text
    payload = weight.json()
    assert payload["smoothing_method"] == "time_weighted_exponential"
    assert payload["smoothing_half_life_days"] == 7.0
    assert [point["raw_value"] for point in payload["series"][0]["points"]] == [81.0, 78.0]
    # The hidden 1 July point still seeds a stable trend for a panned subrange.
    assert payload["series"][0]["points"][0]["trend_value"] > 80.0
    assert payload["series"][0]["points"][-1]["trend_value"] > 78.0

    pressure = await client.get(
        "/api/fitness/measurements/history",
        headers=adult_a_headers,
        params={"metric": "blood_pressure"},
    )
    assert pressure.status_code == 200
    assert [(series["key"], series["points"][0]["raw_value"]) for series in pressure.json()["series"]] == [
        ("systolic", 122.0),
        ("diastolic", 78.0),
    ]


async def test_refresh_token_rotation_is_stored_atomically(
    client, adult_a_headers, initialized_db, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch)
    expired = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_provider_connections SET access_token_expires_at=?", (expired,)
        )
        await db.commit()

    calls: list[str] = []

    async def provider(url: str, *, data: dict, access_token: str | None = None):
        calls.append(url)
        if url == withings.WITHINGS_TOKEN_URL:
            assert data["refresh_token"] == "refresh-first"
            return {
                "userid": "123456",
                "access_token": "access-rotated",
                "refresh_token": "refresh-rotated",
                "scope": "user.metrics",
                "expires_in": 10_800,
            }
        assert access_token == "access-rotated"
        return {"updatetime": int(datetime.now(timezone.utc).timestamp()), "measuregrps": []}

    monkeypatch.setattr(withings, "_withings_post", provider)
    synced = await client.post(
        "/api/fitness/integrations/withings/sync", headers=adult_a_headers
    )
    assert synced.status_code == 200, synced.text
    assert calls == [
        withings.WITHINGS_TOKEN_URL,
        withings.WITHINGS_MEASURE_URL,
        withings.WITHINGS_MEASURE_URL,
    ]
    async with aiosqlite.connect(initialized_db) as db:
        encrypted = (
            await (
                await db.execute(
                    "SELECT encrypted_token_json FROM health_provider_connections"
                )
            ).fetchone()
        )[0]
    assert "refresh-rotated" not in encrypted
    assert json.loads(decrypt_value(encrypted))["refresh_token"] == "refresh-rotated"


async def test_webhook_requires_secret_form_encoding_and_deduplicates(
    client, adult_a_headers, initialized_db, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch)

    async def allowed_source(_source_ip: str) -> bool:
        return True

    monkeypatch.setattr(withings, "notification_source_allowed", allowed_source)
    payload = {
        "userid": "123456",
        "appli": "4",
        "startdate": "1785600000",
        "enddate": "1785600060",
    }
    rejected = await client.post(
        "/api/fitness/integrations/withings/webhook",
        params={"token": "wrong"},
        headers={"CF-Connecting-IP": "89.30.121.171"},
        data=payload,
    )
    assert rejected.status_code == 401
    for index in range(2):
        payload["enddate"] = str(1785600060 + index * 60)
        accepted = await client.post(
            "/api/fitness/integrations/withings/webhook",
            params={"token": "test-withings-webhook-secret-0123456789"},
            headers={"CF-Connecting-IP": "89.30.121.171"},
            data=payload,
        )
        assert accepted.status_code == 202, accepted.text
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT COUNT(*) AS count, MIN(start_at_unix) AS start_at, "
                "MAX(end_at_unix) AS end_at FROM health_provider_notifications"
            )
        ).fetchone()
    assert row[0] == 1
    assert row[1:] == (1785600000, 1785600120)


async def test_webhook_wakeup_during_processing_coalesces_one_followup(
    client, adult_a_headers, initialized_db, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch)
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        notification_id = await withings.enqueue_notification(
            db,
            provider_user_id="123456",
            category=4,
            start_at=1785600000,
            end_at=1785600060,
        )
    assert notification_id
    sync_calls = 0

    async def sync_and_redirty(_db, **kwargs):
        nonlocal sync_calls
        sync_calls += 1
        assert "start_at" not in kwargs and "end_at" not in kwargs
        if sync_calls == 1:
            async with aiosqlite.connect(initialized_db) as other:
                other.row_factory = aiosqlite.Row
                await withings.enqueue_notification(
                    other,
                    provider_user_id="123456",
                    category=4,
                    start_at=1785600060,
                    end_at=1785600120,
                )
        return {"inserted": 0, "updated": 0, "unchanged": 0}

    monkeypatch.setattr(withings, "sync_connection", sync_and_redirty)
    await withings.process_notification(notification_id)
    async with aiosqlite.connect(initialized_db) as db:
        first = await (
            await db.execute(
                "SELECT status, attempt_count FROM health_provider_notifications WHERE id = ?",
                (notification_id,),
            )
        ).fetchone()
    assert first == ("pending", 0)
    await withings.process_notification(notification_id)
    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT status FROM health_provider_notifications WHERE connection_id = "
                "(SELECT id FROM health_provider_connections LIMIT 1)"
            )
        ).fetchall()
    assert rows == [("complete",)]
    assert sync_calls == 2


async def test_connection_is_owner_private_and_disconnect_retains_history(
    client, adult_a_headers, adult_b_headers, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch)
    adult_b_status = await client.get(
        "/api/fitness/integrations/withings/status", headers=adult_b_headers
    )
    assert adult_b_status.json()["status"] == "not_connected"

    async def provider(url: str, *, data: dict, access_token: str | None = None):
        if url == withings.WITHINGS_MEASURE_URL:
            return _measure_body()
        return {}

    monkeypatch.setattr(withings, "_withings_post", provider)
    await client.post("/api/fitness/integrations/withings/sync", headers=adult_a_headers)
    disconnected = await client.delete(
        "/api/fitness/integrations/withings", headers=adult_a_headers
    )
    assert disconnected.status_code == 200, disconnected.text
    assert disconnected.json()["retained_measurement_count"] == 10
    history = await client.get(
        "/api/fitness/measurements/history",
        params={"metric": "weight"},
        headers=adult_a_headers,
    )
    assert history.json()["sample_count"] == 3
    status_payload = (
        await client.get(
            "/api/fitness/integrations/withings/status", headers=adult_a_headers
        )
    ).json()
    assert status_payload["status"] == "disconnected"
    assert status_payload["connected"] is False
