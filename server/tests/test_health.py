"""Tests for the health tracking module (/api/health)."""

import pytest

from app.services import strava, withings


@pytest.fixture(autouse=True)
def _clear_oauth_settings(monkeypatch):
    """Keep tests deterministic regardless of local .env OAuth credentials."""
    monkeypatch.setattr(strava.settings, "strava_client_id", "")
    monkeypatch.setattr(strava.settings, "strava_client_secret", "")
    monkeypatch.setattr(strava.settings, "strava_redirect_uri", "")
    monkeypatch.setattr(withings.settings, "withings_client_id", "")
    monkeypatch.setattr(withings.settings, "withings_client_secret", "")
    monkeypatch.setattr(withings.settings, "withings_redirect_uri", "")
    monkeypatch.setattr(strava.settings, "strava_webhook_verify_token", "test-strava-verify-token")
    monkeypatch.setattr(strava.settings, "health_webhook_secret", "test-health-webhook-secret")
    monkeypatch.setattr(strava.settings, "legacy_health_integrations_enabled", True)


# ---------------------------------------------------------------------------
# Create health data (direct POST)
# ---------------------------------------------------------------------------


async def test_create_health_data(client, adult_a_user, adult_a_headers):
    """POST /api/health/data creates a new health data record."""
    payload = {
        "source": "apple_health",
        "data_type": "steps",
        "value": 8500.0,
        "unit": "count",
        "recorded_at": "2026-01-15T10:00:00Z",
        "metadata": {"device": "iPhone"},
    }
    resp = await client.post("/api/health/data", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["source"] == "apple_health"
    assert data["data_type"] == "steps"
    assert data["value"] == 8500.0
    assert data["unit"] == "count"
    assert data["recorded_at"] == "2026-01-15T10:00:00Z"
    assert data["metadata"] == {"device": "iPhone"}
    assert data["created_by"] == adult_a_user["id"]
    assert "id" in data
    assert "created_at" in data
    assert "updated_at" in data


# ---------------------------------------------------------------------------
# List health data
# ---------------------------------------------------------------------------


async def test_list_health_data(client, adult_a_user, adult_a_headers):
    """GET /api/health/data returns health data records."""
    # Create a record first
    payload = {
        "source": "strava",
        "data_type": "run",
        "value": 5000.0,
        "unit": "meters",
        "recorded_at": "2026-01-20T08:00:00Z",
    }
    create_resp = await client.post("/api/health/data", json=payload, headers=adult_a_headers)
    assert create_resp.status_code == 201

    resp = await client.get("/api/health/data", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 1
    sources = [r["source"] for r in data]
    assert "strava" in sources


# ---------------------------------------------------------------------------
# Filter by source
# ---------------------------------------------------------------------------


async def test_filter_by_source(client, adult_a_user, adult_a_headers):
    """GET /api/health/data?source=... filters records by source."""
    # Create records from different sources
    await client.post(
        "/api/health/data",
        json={
            "source": "strava",
            "data_type": "run",
            "value": 10000.0,
            "unit": "meters",
            "recorded_at": "2026-02-01T09:00:00Z",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/health/data",
        json={
            "source": "apple_health",
            "data_type": "heart_rate",
            "value": 72.0,
            "unit": "bpm",
            "recorded_at": "2026-02-01T10:00:00Z",
        },
        headers=adult_a_headers,
    )

    # Filter to strava only
    resp = await client.get(
        "/api/health/data",
        params={"source": "strava"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) >= 1
    sources = {r["source"] for r in data}
    assert sources == {"strava"}


# ---------------------------------------------------------------------------
# Filter by date range
# ---------------------------------------------------------------------------


async def test_filter_by_date_range(client, adult_a_user, adult_a_headers):
    """GET /api/health/data?start=...&end=... filters by date range."""
    # Create records at different times
    await client.post(
        "/api/health/data",
        json={
            "source": "apple_health",
            "data_type": "steps",
            "value": 6000.0,
            "unit": "count",
            "recorded_at": "2026-01-10T12:00:00Z",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/health/data",
        json={
            "source": "apple_health",
            "data_type": "steps",
            "value": 9000.0,
            "unit": "count",
            "recorded_at": "2026-01-20T12:00:00Z",
        },
        headers=adult_a_headers,
    )
    await client.post(
        "/api/health/data",
        json={
            "source": "apple_health",
            "data_type": "steps",
            "value": 12000.0,
            "unit": "count",
            "recorded_at": "2026-01-30T12:00:00Z",
        },
        headers=adult_a_headers,
    )

    # Filter to Jan 15 - Jan 25
    resp = await client.get(
        "/api/health/data",
        params={"start": "2026-01-15T00:00:00Z", "end": "2026-01-25T23:59:59Z"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    # Should include the Jan 20 record but not Jan 10 or Jan 30
    dates = [r["recorded_at"] for r in data]
    assert any("2026-01-20" in d for d in dates)
    assert not any("2026-01-10" in d for d in dates)
    assert not any("2026-01-30" in d for d in dates)


# ---------------------------------------------------------------------------
# Apple Health webhook processing
# ---------------------------------------------------------------------------


async def test_apple_health_webhook(client, adult_a_user, adult_a_headers, initialized_db):
    """POST /api/health/apple processes Apple Health data from webhook."""
    payload = {
        "data": {
            "metrics": [
                {
                    "name": "heart_rate",
                    "units": "bpm",
                    "data": [
                        {"date": "2026-02-05T08:00:00Z", "qty": 68.0},
                        {"date": "2026-02-05T09:00:00Z", "qty": 72.0},
                    ],
                },
                {
                    "name": "steps",
                    "units": "count",
                    "data": [
                        {"date": "2026-02-05T23:59:00Z", "qty": 11234.0},
                    ],
                },
            ]
        }
    }

    resp = await client.post(
        "/api/health/apple",
        json=payload,
        headers={"X-Webhook-Secret": "test-health-webhook-secret"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "saved"
    assert data["count"] == 3

    # Verify the records are in the database
    list_resp = await client.get(
        "/api/health/data",
        params={"source": "apple_health"},
        headers=adult_a_headers,
    )
    assert list_resp.status_code == 200
    records = list_resp.json()
    types = {r["data_type"] for r in records}
    assert "heart_rate" in types
    assert "steps" in types


# ---------------------------------------------------------------------------
# Strava authorize URL
# ---------------------------------------------------------------------------


async def test_strava_authorize_url_empty_keys(client, adult_a_headers):
    """GET /api/health/strava/authorize returns empty url when keys not configured."""
    resp = await client.get("/api/health/strava/authorize", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    # With empty client_id, should return empty url or error message
    assert "url" in data
    assert data["url"] == ""


# ---------------------------------------------------------------------------
# Withings authorize URL
# ---------------------------------------------------------------------------


async def test_withings_authorize_url_empty_keys(client, adult_a_headers):
    """GET /api/health/withings/authorize returns empty url when keys not configured."""
    resp = await client.get("/api/health/withings/authorize", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    # With empty client_id, should return empty url or error message
    assert "url" in data
    assert data["url"] == ""


# ---------------------------------------------------------------------------
# Strava webhook verification
# ---------------------------------------------------------------------------


async def test_strava_webhook_verify(client):
    """GET /api/health/strava/webhook returns the hub.challenge value."""
    resp = await client.get(
        "/api/health/strava/webhook",
        params={
            "hub.mode": "subscribe",
            "hub.challenge": "test_challenge_123",
            "hub.verify_token": "test-strava-verify-token",
        },
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["hub.challenge"] == "test_challenge_123"


# ---------------------------------------------------------------------------
# Auth required for data endpoint
# ---------------------------------------------------------------------------


async def test_data_requires_auth(client, initialized_db):
    """GET /api/health/data requires authentication."""
    resp = await client.get("/api/health/data")
    assert resp.status_code in (401, 403)


async def test_legacy_health_integrations_fail_closed(
    client,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(strava.settings, "legacy_health_integrations_enabled", False)

    authorize = await client.get(
        "/api/health/strava/authorize",
        headers=adult_a_headers,
    )
    webhook = await client.post(
        "/api/health/apple",
        json={"data": {"metrics": []}},
        headers={"X-Webhook-Secret": "test-health-webhook-secret"},
    )

    assert authorize.status_code == 503
    assert webhook.status_code == 503


# ---------------------------------------------------------------------------
# Apple Health webhook with empty payload
# ---------------------------------------------------------------------------


async def test_apple_health_webhook_empty(client, initialized_db):
    """POST /api/health/apple handles empty metrics gracefully."""
    resp = await client.post(
        "/api/health/apple",
        json={"data": {"metrics": []}},
        headers={"X-Webhook-Secret": "test-health-webhook-secret"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ignored"
