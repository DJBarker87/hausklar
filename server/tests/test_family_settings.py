"""Tests for the HA family settings endpoints (/api/family/settings/ha)."""

from unittest.mock import AsyncMock, patch

import aiosqlite
import pytest
from cryptography.fernet import Fernet

from app.utils.encryption import decrypt_value

# Fixed test key — must be set before any request touches encryption.
TEST_FERNET_KEY = Fernet.generate_key().decode()


@pytest.fixture(autouse=True)
def _set_encryption_key(monkeypatch):
    """Ensure the encryption module uses a test key for every test."""
    monkeypatch.setattr("app.config.settings.ha_token_encryption_key", TEST_FERNET_KEY)


# ── Helpers ──────────────────────────────────────────────────────────────

HA_URL = "/api/family/settings/ha"
HA_TEST_URL = "/api/family/settings/ha/test"

FULL_PAYLOAD = {
    "dashboard_url": "http://ha.local:8123/dashboard",
    "ha_url": "http://ha.local:8123",
    "ha_token": "my-long-lived-access-token",
    "config_api_url": "http://ha.local:8123/api",
}


# ── Tests ────────────────────────────────────────────────────────────────


async def test_get_ha_settings_empty(client, adult_a_headers):
    """GET should return all-null fields and configured=false when nothing is saved."""
    resp = await client.get(HA_URL, headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["configured"] is False
    assert data["dashboard_url"] is None
    assert data["ha_url"] is None
    assert data["token_configured"] is False
    assert data["config_api_url"] is None


async def test_get_ha_settings_after_save(client, adult_a_headers):
    """PUT then GET must report token presence without returning the secret."""
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    resp = await client.get(HA_URL, headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["configured"] is True
    assert data["dashboard_url"] == FULL_PAYLOAD["dashboard_url"]
    assert data["ha_url"] == FULL_PAYLOAD["ha_url"]
    assert "ha_token" not in data
    assert data["token_configured"] is True
    assert data["config_api_url"] == FULL_PAYLOAD["config_api_url"]


async def test_put_ha_settings_saves_all_fields(client, adult_a_headers):
    """PUT with all four fields should return 200."""
    resp = await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)
    assert resp.status_code == 200
    data = resp.json()
    assert data["ha_url"] == FULL_PAYLOAD["ha_url"]
    assert "ha_token" not in data
    assert data["token_configured"] is True


async def test_put_ha_settings_partial_update(client, adult_a_headers):
    """PUT with a non-secret field should leave the HA origin and token untouched."""
    # Save full settings first
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    resp = await client.put(
        HA_URL,
        headers=adult_a_headers,
        json={"dashboard_url": "http://dashboard.local:8080"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["dashboard_url"] == "http://dashboard.local:8080"
    assert data["ha_url"] == FULL_PAYLOAD["ha_url"]
    assert "ha_token" not in data
    assert data["token_configured"] is True


async def test_put_ha_settings_non_admin_403(client, adult_b_headers):
    """Non-admin users should receive 403 when trying to update HA settings."""
    resp = await client.put(HA_URL, headers=adult_b_headers, json=FULL_PAYLOAD)
    assert resp.status_code == 403


async def test_other_family_admin_can_manage_its_own_ha(client, other_family_headers):
    update = await client.put(HA_URL, headers=other_family_headers, json=FULL_PAYLOAD)
    test = await client.post(HA_TEST_URL, headers=other_family_headers)

    assert update.status_code == 200
    assert test.status_code == 200


async def test_put_ha_settings_encrypts_token(client, adult_a_headers, initialized_db):
    """The ha_token stored in the DB must differ from the plaintext."""
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    async with aiosqlite.connect(initialized_db) as db:
        cursor = await db.execute(
            "SELECT setting_value FROM family_settings WHERE setting_key = 'ha_token'",
        )
        row = await cursor.fetchone()

    stored_value = row[0]
    # The stored ciphertext must NOT equal the plaintext
    assert stored_value != FULL_PAYLOAD["ha_token"]
    # But decrypting it should give back the original
    assert decrypt_value(stored_value) == FULL_PAYLOAD["ha_token"]


async def test_ha_test_connection_success(client, adult_a_headers):
    """POST /test should return success=true when HA responds with 200."""
    # Save settings first so there is a URL + token to test
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    mock_response = AsyncMock()
    mock_response.raise_for_status = lambda: None

    with patch("app.routers.family.httpx.AsyncClient") as MockClient:
        instance = AsyncMock()
        instance.get.return_value = mock_response
        instance.__aenter__ = AsyncMock(return_value=instance)
        instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = instance

        resp = await client.post(HA_TEST_URL, headers=adult_a_headers)

    assert resp.status_code == 200
    assert resp.json()["success"] is True


async def test_ha_test_connection_failure(client, adult_a_headers):
    """POST /test should return success=false when HA is unreachable."""
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    with patch("app.routers.family.httpx.AsyncClient") as MockClient:
        instance = AsyncMock()
        instance.get.side_effect = ConnectionError("Connection refused")
        instance.__aenter__ = AsyncMock(return_value=instance)
        instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = instance

        resp = await client.post(HA_TEST_URL, headers=adult_a_headers)

    assert resp.status_code == 200
    assert resp.json()["success"] is False


async def test_ha_test_connection_non_admin_403(client, adult_b_headers):
    """Non-admin users should receive 403 when trying to test the HA connection."""
    resp = await client.post(HA_TEST_URL, headers=adult_b_headers)
    assert resp.status_code == 403


async def test_ha_settings_isolated_between_families(
    client, adult_a_headers, other_family_headers
):
    """Settings saved by one family must not be visible to another family."""
    # Alex saves HA settings for his family
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    # Other family should see empty / unconfigured settings
    resp = await client.get(HA_URL, headers=other_family_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["configured"] is False
    assert data["ha_url"] is None
    assert "ha_token" not in data
    assert data["token_configured"] is False


async def test_non_admin_cannot_read_internal_ha_urls(client, adult_a_headers, adult_b_headers):
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    response = await client.get(HA_URL, headers=adult_b_headers)

    assert response.status_code == 200
    assert response.json()["configured"] is True
    assert response.json()["token_configured"] is True
    assert response.json()["ha_url"] is None
    assert response.json()["config_api_url"] is None
    assert "ha_token" not in response.json()


async def test_ha_settings_rejects_embedded_url_credentials(client, adult_a_headers):
    response = await client.put(
        HA_URL,
        headers=adult_a_headers,
        json={"ha_url": "http://user:demo-person-35@example.invalid:8123"},
    )

    assert response.status_code == 422


async def test_ha_settings_rejects_public_and_local_metadata_origins(client, adult_a_headers):
    for url in (
        "https://attacker.example",
        "http://127.0.0.1:8123",
        "http://169.254.169.254",
    ):
        response = await client.put(
            HA_URL,
            headers=adult_a_headers,
            json={"ha_url": url, "ha_token": FULL_PAYLOAD["ha_token"]},
        )
        assert response.status_code == 422


async def test_ha_origin_change_requires_replacing_token(client, adult_a_headers):
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    response = await client.put(
        HA_URL,
        headers=adult_a_headers,
        json={"ha_url": "http://new-ha.local:8123"},
    )

    assert response.status_code == 422
    assert "requires a new access token" in response.json()["detail"]


async def test_ha_origin_and_token_can_be_replaced_atomically(client, adult_a_headers):
    await client.put(HA_URL, headers=adult_a_headers, json=FULL_PAYLOAD)

    response = await client.put(
        HA_URL,
        headers=adult_a_headers,
        json={
            "ha_url": "http://new-ha.local:8123",
            "ha_token": "replacement-long-lived-token",
        },
    )

    assert response.status_code == 200
    assert response.json()["ha_url"] == "http://new-ha.local:8123"
    assert response.json()["token_configured"] is True
