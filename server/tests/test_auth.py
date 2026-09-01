"""Tests for the auth router (/api/auth)."""

import asyncio
import aiosqlite
import json
import threading
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from urllib.parse import unquote, urlsplit
from unittest.mock import AsyncMock
import jwt
from pwdlib.hashers.bcrypt import BcryptHasher

from app.auth import create_password_reset_token, hash_password, hash_refresh_token
from app.config import settings
from app.routers import auth as auth_router
from app.services.account_deletion import FAMILY_PURGE_EXEMPT_TABLES, FAMILY_PURGE_TABLES
from app.services.ai_consent import AI_CONSENT_VERSION
from app.services.email import password_reset_link


# ---------------------------------------------------------------------------
# Login tests
# ---------------------------------------------------------------------------


async def test_login_success(client, adult_a_user):
    """POST /api/auth/login with valid credentials returns tokens."""
    resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "access_token" in data
    assert "refresh_token" in data
    assert data["token_type"] == "bearer"


async def test_login_upgrades_legacy_bcrypt_hash_to_argon2(
    client,
    adult_a_user,
    initialized_db,
):
    legacy_hash = BcryptHasher().hash("password123")
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE users SET password_hash = ? WHERE id = ?",
            (legacy_hash, adult_a_user["id"]),
        )
        await db.commit()

    response = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert response.status_code == 200

    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT password_hash FROM users WHERE id = ?",
                (adult_a_user["id"],),
            )
        ).fetchone()
    assert row[0].startswith("$argon2id$")


async def test_login_wrong_password(client, adult_a_user):
    """POST /api/auth/login with wrong password returns 401."""
    resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "wrongpassword"},
    )
    assert resp.status_code == 401


async def test_login_wrong_email(client, adult_a_user):
    """POST /api/auth/login with unknown email returns 401."""
    resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-43@example.invalid", "password": "password123"},
    )
    assert resp.status_code == 401


async def test_login_deleted_user(client, initialized_db):
    """POST /api/auth/login for a soft-deleted user returns 401."""
    password_hash = hash_password("password123")
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO users (id, name, email, password_hash, role, priority, deleted_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "00000000-0000-0000-0000-000000000099",
                "Deleted User",
                "demo-person-38@example.invalid",
                password_hash,
                "user",
                1,
                datetime.now(timezone.utc).isoformat(),
            ),
        )
        await db.commit()

    resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-38@example.invalid", "password": "password123"},
    )
    assert resp.status_code == 401


async def test_web_session_uses_secure_httponly_rotating_cookies(client, adult_a_user, monkeypatch):
    monkeypatch.setattr(settings, "app_env", "production")
    login_resp = await client.post(
        "/api/auth/web/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert login_resp.status_code == 200
    assert login_resp.json()["id"] == adult_a_user["id"]
    assert "access_token" not in login_resp.json()
    set_cookie = login_resp.headers.get_list("set-cookie")
    assert all("HttpOnly" in value for value in set_cookie)
    assert all("SameSite=strict" in value for value in set_cookie)
    assert all("Secure" in value for value in set_cookie)

    access = login_resp.cookies.get("hausklar_access")
    refresh_token = login_resp.cookies.get("hausklar_refresh")
    session_resp = await client.get(
        "/api/auth/web/session",
        headers={"Cookie": f"hausklar_access={access}"},
    )
    assert session_resp.status_code == 200
    assert session_resp.json()["email"] == "demo-person-51@example.invalid"

    refresh_resp = await client.post(
        "/api/auth/web/refresh",
        headers={
            "Cookie": f"hausklar_refresh={refresh_token}",
            "Origin": "https://test",
        },
    )
    assert refresh_resp.status_code == 204
    rotated_access = refresh_resp.cookies.get("hausklar_access")
    rotated_refresh = refresh_resp.cookies.get("hausklar_refresh")
    assert rotated_access
    assert rotated_refresh != refresh_token

    logout_resp = await client.post(
        "/api/auth/web/logout",
        headers={
            "Cookie": (f"hausklar_access={rotated_access}; hausklar_refresh={rotated_refresh}"),
            "Origin": "https://test",
        },
    )
    assert logout_resp.status_code == 204
    assert any(
        'hausklar_access=""' in value for value in logout_resp.headers.get_list("set-cookie")
    )


async def test_web_logout_revokes_refresh_when_access_cookie_is_expired(
    client,
    adult_a_user,
):
    login = await client.post(
        "/api/auth/web/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    refresh_token = login.cookies.get("hausklar_refresh")
    expired_access = jwt.encode(
        {
            "sub": adult_a_user["id"],
            "fam": adult_a_user["family_id"],
            "type": "access",
            "exp": datetime.now(timezone.utc) - timedelta(minutes=1),
        },
        settings.jwt_secret_key,
        algorithm=settings.jwt_algorithm,
    )

    logout = await client.post(
        "/api/auth/web/logout",
        headers={
            "Cookie": (f"hausklar_access={expired_access}; hausklar_refresh={refresh_token}"),
            "Origin": "https://test",
        },
    )
    replay = await client.post(
        "/api/auth/web/refresh",
        headers={
            "Cookie": f"hausklar_refresh={refresh_token}",
            "Origin": "https://test",
        },
    )

    assert logout.status_code == 204
    assert any('hausklar_refresh=""' in value for value in logout.headers.get_list("set-cookie"))
    assert replay.status_code == 401


# ---------------------------------------------------------------------------
# Token refresh tests
# ---------------------------------------------------------------------------


async def test_refresh_token(client, adult_a_user):
    """POST /api/auth/refresh with a valid refresh token returns new tokens."""
    # Login to obtain initial tokens
    login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    tokens = login_resp.json()

    # Refresh
    resp = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": tokens["refresh_token"]},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "access_token" in data
    assert "refresh_token" in data
    # New tokens should differ from the originals (rotation)
    assert data["refresh_token"] != tokens["refresh_token"]
    next_rotation = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": data["refresh_token"]},
    )
    assert next_rotation.status_code == 200


async def test_refresh_revoked_token(client, adult_a_user):
    """After rotation the old refresh token must be rejected (401)."""
    login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    old_refresh = login_resp.json()["refresh_token"]

    # First refresh succeeds and revokes the old token
    rotated = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": old_refresh},
    )
    descendant = rotated.json()["refresh_token"]

    # Attempting to reuse the old token should fail
    resp = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": old_refresh},
    )
    assert resp.status_code == 401
    descendant_response = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": descendant},
    )
    assert descendant_response.status_code == 401


async def test_refresh_invalid_token(client, adult_a_user):
    """POST /api/auth/refresh with garbage token returns 401."""
    resp = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": "not-a-real-token"},
    )
    assert resp.status_code == 401


async def test_refresh_token_rotation_can_only_be_claimed_once(client, adult_a_user):
    login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    old_refresh = login_resp.json()["refresh_token"]

    first, second = await asyncio.gather(
        client.post("/api/auth/refresh", json={"refresh_token": old_refresh}),
        client.post("/api/auth/refresh", json={"refresh_token": old_refresh}),
    )

    assert sorted([first.status_code, second.status_code]) == [200, 401]
    successful = first if first.status_code == 200 else second
    revoked_descendant = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": successful.json()["refresh_token"]},
    )
    assert revoked_descendant.status_code == 401


async def test_refresh_reuse_revokes_only_that_device_family(client, adult_a_user):
    first_login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    second_login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    first_initial = first_login.json()["refresh_token"]
    second_initial = second_login.json()["refresh_token"]

    first_rotation = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": first_initial},
    )
    replay = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": first_initial},
    )
    compromised_descendant = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": first_rotation.json()["refresh_token"]},
    )
    other_device = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": second_initial},
    )

    assert first_rotation.status_code == 200
    assert replay.status_code == 401
    assert compromised_descendant.status_code == 401
    assert other_device.status_code == 200


async def test_refresh_rotation_persists_hashed_lineage(
    client,
    adult_a_user,
    initialized_db,
):
    login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    initial_token = login.json()["refresh_token"]
    rotation = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": initial_token},
    )
    replacement_token = rotation.json()["refresh_token"]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT id, token, revoked_at, rotation_family_id, "
                "parent_token_id, replaced_by_id FROM refresh_tokens "
                "WHERE user_id = ? ORDER BY created_at",
                (adult_a_user["id"],),
            )
        ).fetchall()

    assert rotation.status_code == 200
    assert len(rows) == 2
    parent, child = rows
    assert parent["token"] == hash_refresh_token(initial_token)
    assert child["token"] == hash_refresh_token(replacement_token)
    assert initial_token not in {row["token"] for row in rows}
    assert replacement_token not in {row["token"] for row in rows}
    assert parent["rotation_family_id"] == child["rotation_family_id"]
    assert parent["replaced_by_id"] == child["id"]
    assert child["parent_token_id"] == parent["id"]
    assert parent["revoked_at"] is not None
    assert child["revoked_at"] is None


# ---------------------------------------------------------------------------
# Logout test
# ---------------------------------------------------------------------------


async def test_logout(client, adult_a_user):
    """POST /api/auth/logout revokes the refresh token (204)."""
    # Login to get tokens
    login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    tokens = login_resp.json()
    auth_headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    # Logout
    resp = await client.post(
        "/api/auth/logout",
        json={"refresh_token": tokens["refresh_token"]},
        headers=auth_headers,
    )
    assert resp.status_code == 204

    # Attempting to refresh with the now-revoked token should fail
    refresh_resp = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": tokens["refresh_token"]},
    )
    assert refresh_resp.status_code == 401


async def test_logout_revokes_only_presented_device_session(client, adult_a_user):
    first_login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    second_login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    first = first_login.json()
    second = second_login.json()

    logout_response = await client.post(
        "/api/auth/logout",
        headers={"Authorization": f"Bearer {first['access_token']}"},
        json={"refresh_token": first["refresh_token"]},
    )
    first_refresh = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": first["refresh_token"]},
    )
    second_refresh = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": second["refresh_token"]},
    )

    assert logout_response.status_code == 204
    assert first_refresh.status_code == 401
    assert second_refresh.status_code == 200


# ---------------------------------------------------------------------------
# Me endpoint
# ---------------------------------------------------------------------------


async def test_me(client, adult_a_user, adult_a_headers):
    """GET /api/auth/me with valid auth returns the user profile."""
    resp = await client.get("/api/auth/me", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["id"] == adult_a_user["id"]
    assert data["name"] == "Alex"
    assert data["email"] == "demo-person-51@example.invalid"
    assert data["role"] == "admin"
    assert data["priority"] == 5


async def test_me_no_auth(client):
    """GET /api/auth/me without an auth header returns 401 or 403."""
    resp = await client.get("/api/auth/me")
    assert resp.status_code in (401, 403)


async def test_pre_version_access_token_remains_valid_until_security_event(
    client,
    adult_a_user,
):
    legacy_access = jwt.encode(
        {
            "sub": adult_a_user["id"],
            "fam": adult_a_user["family_id"],
            "type": "access",
            "exp": datetime.now(timezone.utc) + timedelta(minutes=5),
        },
        settings.jwt_secret_key,
        algorithm=settings.jwt_algorithm,
    )

    response = await client.get(
        "/api/auth/me",
        headers={"Authorization": f"Bearer {legacy_access}"},
    )

    assert response.status_code == 200


async def test_auth_capabilities_report_registration_setting(client, monkeypatch):
    monkeypatch.setattr(settings, "allow_public_registration", False)
    disabled = await client.get("/api/auth/capabilities")
    assert disabled.status_code == 200
    assert disabled.json() == {"public_registration": False}

    monkeypatch.setattr(settings, "allow_public_registration", True)
    enabled = await client.get("/api/auth/capabilities")
    assert enabled.status_code == 200
    assert enabled.json() == {"public_registration": True}


async def test_ai_consent_is_explicit_versioned_and_revocable(
    client,
    adult_a_headers,
    monkeypatch,
):
    status_response = await client.get("/api/auth/ai-consent", headers=adult_a_headers)
    assert status_response.status_code == 200
    assert status_response.json()["consented"] is True
    assert status_response.json()["version"] == AI_CONSENT_VERSION
    assert status_response.json()["provider"] == "OpenAI"
    assert status_response.json()["background_processing"] is False
    assert "children's" in status_response.json()["disclosure"]
    assert "cycle" in status_response.json()["disclosure"]
    assert "wallet addresses" in status_response.json()["disclosure"]

    revoked = await client.delete("/api/auth/ai-consent", headers=adult_a_headers)
    assert revoked.status_code == 200
    assert revoked.json()["consented"] is False

    assistant = AsyncMock()
    monkeypatch.setattr("app.routers.assistant.ask_family_assistant", assistant)
    blocked = await client.post(
        "/api/assistant/message",
        headers=adult_a_headers,
        json={"message": "What is happening today?"},
    )
    assert blocked.status_code == 428
    assistant.assert_not_awaited()

    rejected_false = await client.put(
        "/api/auth/ai-consent",
        headers=adult_a_headers,
        json={"accepted": False, "version": AI_CONSENT_VERSION},
    )
    assert rejected_false.status_code == 422
    stale = await client.put(
        "/api/auth/ai-consent",
        headers=adult_a_headers,
        json={"accepted": True, "version": "2026-07-13"},
    )
    assert stale.status_code == 409

    granted = await client.put(
        "/api/auth/ai-consent",
        headers=adult_a_headers,
        json={"accepted": True, "version": AI_CONSENT_VERSION},
    )
    assert granted.status_code == 200
    assert granted.json()["consented"] is True
    assert granted.json()["consented_at"]


async def test_final_family_purge_allowlist_covers_every_family_scoped_table(initialized_db):
    async with aiosqlite.connect(initialized_db) as db:
        table_rows = await (
            await db.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
        ).fetchall()
        family_tables: set[str] = set()
        for (table_name,) in table_rows:
            columns = await (await db.execute(f"PRAGMA table_info({table_name})")).fetchall()
            if "family_id" in {column[1] for column in columns}:
                family_tables.add(table_name)

    assert family_tables - {
        "users",
        "record_history",
        *FAMILY_PURGE_EXEMPT_TABLES,
    } == set(FAMILY_PURGE_TABLES)


async def test_delete_me_deletes_user_and_revokes_tokens(client, adult_a_user, initialized_db):
    """DELETE /api/auth/me physically removes the account and active refresh tokens."""
    login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert login_resp.status_code == 200
    tokens = login_resp.json()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    delete_resp = await client.delete("/api/auth/me", headers=headers)
    assert delete_resp.status_code == 204

    me_resp = await client.get("/api/auth/me", headers=headers)
    assert me_resp.status_code in (401, 403)

    refresh_resp = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": tokens["refresh_token"]},
    )
    assert refresh_resp.status_code == 401
    async with aiosqlite.connect(initialized_db) as db:
        user_count = (
            await (
                await db.execute("SELECT COUNT(*) FROM users WHERE id = ?", (adult_a_user["id"],))
            ).fetchone()
        )[0]
        token_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM refresh_tokens WHERE user_id = ?", (adult_a_user["id"],)
                )
            ).fetchone()
        )[0]
    assert user_count == 0
    assert token_count == 0


async def test_browser_account_delete_clears_cookies_and_invalidates_session(
    client,
    adult_a_user,
):
    login = await client.post(
        "/api/auth/web/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    old_access = login.cookies.get("hausklar_access")
    old_refresh = login.cookies.get("hausklar_refresh")

    deleted = await client.delete(
        "/api/auth/me",
        headers={
            "Cookie": (f"hausklar_access={old_access}; hausklar_refresh={old_refresh}"),
            "Origin": "https://test",
        },
    )
    old_session = await client.get(
        "/api/auth/web/session",
        headers={"Cookie": f"hausklar_access={old_access}"},
    )
    old_refresh_response = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": old_refresh},
    )

    assert deleted.status_code == 204
    cleared = deleted.headers.get_list("set-cookie")
    assert any('hausklar_access=""' in value for value in cleared)
    assert any('hausklar_refresh=""' in value for value in cleared)
    assert old_session.status_code == 401
    assert old_refresh_response.status_code == 401


async def test_delete_me_last_member_physically_deletes_family_data(
    client, adult_a_user, initialized_db, child1, monkeypatch, tmp_path
):
    """Deleting the last active account physically removes family-scoped live data."""
    cache_root = tmp_path / "media-cache"
    family_cache = cache_root / adult_a_user["family_id"] / "child-photos"
    family_cache.mkdir(parents=True)
    (family_cache / "cached-thumb.jpg").write_bytes(b"cached family image")
    monkeypatch.setattr(settings, "media_cache_path", str(cache_root))

    login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert login_resp.status_code == 200
    tokens = login_resp.json()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    delete_resp = await client.delete("/api/auth/me", headers=headers)
    assert delete_resp.status_code == 204
    assert not (cache_root / adult_a_user["family_id"]).exists()

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row

        user_row = await (
            await db.execute(
                "SELECT id FROM users WHERE id = ?",
                (adult_a_user["id"],),
            )
        ).fetchone()
        assert user_row is None

        family_row = await (
            await db.execute(
                "SELECT id FROM families WHERE id = ?",
                (adult_a_user["family_id"],),
            )
        ).fetchone()
        assert family_row is None

        child_row = await (
            await db.execute(
                "SELECT id FROM children WHERE id = ?",
                (child1["id"],),
            )
        ).fetchone()
        assert child_row is None


async def test_delete_me_last_member_erases_owned_history_without_cross_family(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    other_family_user,
    initialized_db,
):
    sensitive_marker = "private-growth-history-for-deletion"
    create_response = await client.post(
        "/api/growth/",
        headers=adult_a_headers,
        json={
            "child_id": child1["id"],
            "date": "2026-07-10",
            "weight_kg": 21.5,
            "notes": sensitive_marker,
        },
    )
    assert create_response.status_code == 201
    record_id = create_response.json()["id"]
    update_response = await client.put(
        f"/api/growth/{record_id}",
        headers=adult_a_headers,
        json={"notes": "updated"},
    )
    assert update_response.status_code == 200

    other_family_id = other_family_user["family_id"]
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        tagged = await (
            await db.execute(
                "SELECT family_id FROM record_history WHERE record_id = ?",
                (record_id,),
            )
        ).fetchone()
        assert tagged is not None
        assert tagged[0] == adult_a_user["family_id"]

        await db.executemany(
            """
            INSERT INTO record_history (
                id, table_name, record_id, previous_values, changed_by,
                changed_at, family_id
            ) VALUES (?, 'growth_records', ?, ?, ?, ?, NULL)
            """,
            [
                (
                    "legacy-owned-snapshot",
                    "legacy-owned-snapshot",
                    json.dumps(
                        {
                            "family_id": adult_a_user["family_id"],
                            "notes": "owned-legacy-private-data",
                        }
                    ),
                    adult_a_user["id"],
                    now,
                ),
                (
                    "legacy-owned-author",
                    "legacy-owned-author",
                    json.dumps({"notes": "owned-pre-tenancy-private-data"}),
                    adult_a_user["id"],
                    now,
                ),
                (
                    "legacy-other-family",
                    "legacy-other-family",
                    json.dumps(
                        {
                            "family_id": other_family_id,
                            "notes": "other-family-private-data",
                        }
                    ),
                    other_family_user["id"],
                    now,
                ),
                (
                    "legacy-conflicting-attribution",
                    "legacy-conflicting-attribution",
                    json.dumps(
                        {
                            "family_id": other_family_id,
                            "notes": "other-family-snapshot",
                        }
                    ),
                    adult_a_user["id"],
                    now,
                ),
            ],
        )
        await db.commit()

    delete_response = await client.delete("/api/auth/me", headers=adult_a_headers)
    assert delete_response.status_code == 204

    async with aiosqlite.connect(initialized_db) as db:
        remaining = await (
            await db.execute(
                "SELECT id, record_id, previous_values FROM record_history ORDER BY id"
            )
        ).fetchall()

    remaining_by_id = {row[0]: row[2] for row in remaining}
    assert "legacy-owned-snapshot" not in remaining_by_id
    assert "legacy-owned-author" not in remaining_by_id
    assert record_id not in {row[1] for row in remaining}
    assert sensitive_marker not in "\n".join(remaining_by_id.values())
    assert "legacy-other-family" in remaining_by_id
    assert "legacy-conflicting-attribution" in remaining_by_id
    assert "other-family-private-data" in remaining_by_id["legacy-other-family"]


async def test_delete_me_with_remaining_family_member_keeps_family_data(
    client, adult_a_user, adult_b_user, initialized_db, child1
):
    """Shared family data survives without retaining the departing adult's identity."""
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE children SET created_by = ?, client_id = 'dom-device' WHERE id = ?",
            (adult_a_user["id"], child1["id"]),
        )
        await db.execute(
            """INSERT INTO calendar_events
               (id, title, start_time, assigned_to, family_member_ids, affected_member_ids, family_id,
                created_at, updated_at, created_by, client_id)
               VALUES ('departure-event', 'Family plan', ?, ?, ?, ?, ?, ?, ?, ?, 'dom-device')""",
            (
                now,
                adult_a_user["id"],
                json.dumps([adult_a_user["id"], child1["id"]]),
                json.dumps([adult_a_user["id"]]),
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO tasks
               (id, title, assigned_to, family_id, created_at, updated_at, created_by)
               VALUES ('departure-task', 'Shared task', ?, ?, ?, ?, ?)""",
            (adult_a_user["id"], adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO task_assignments
               (id, task_id, assignee_id, assignee_type, completed_by, family_id,
                created_at, updated_at, created_by)
               VALUES ('departure-assignment', 'departure-task', ?, 'user', ?, ?, ?, ?, ?)""",
            (adult_a_user["id"], adult_a_user["id"], adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO medicine_doses
               (id, child_id, given_at, given_by, medicine_name, family_id,
                created_at, updated_at, created_by)
               VALUES ('departure-dose', ?, ?, ?, 'Test medicine', ?, ?, ?, ?)""",
            (child1["id"], now, adult_a_user["id"], adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO routine_items
               (id, person_id, name, color, days_of_week, family_id,
                created_at, updated_at, created_by)
               VALUES ('departure-routine', ?, 'Personal routine', '#000000', '[]', ?, ?, ?, ?)""",
            (adult_a_user["id"], adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO inbound_email_messages
               (id, provider_message_id, from_address, to_address, subject, status,
                family_id, created_at, updated_at, created_by)
               VALUES ('departure-email', 'provider-departure', ?, 'inbox@test',
                       'Private sender', 'processed', ?, ?, ?, ?)""",
            (adult_a_user["email"], adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO documents
               (id, title, original_filename, media_type, storage_key, file_size, sha256,
                source, category, status, notes, family_id, created_at, updated_at, created_by)
               VALUES ('departure-document', 'Shared letter', 'letter.txt', 'text/plain',
                       'shared/letter.txt', 1, ?, 'file', 'other', 'filed', ?, ?, ?, ?, ?)""",
            (
                "a" * 64,
                f"Forwarded by {adult_a_user['email']}",
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO document_people
               (id, document_id, person_id, person_type, family_id,
                created_at, updated_at, created_by)
               VALUES ('departure-person', 'departure-document', ?, 'user', ?, ?, ?, ?)""",
            (adult_a_user["id"], adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO record_history
               (id, table_name, record_id, previous_values, changed_by, changed_at, family_id)
               VALUES ('departure-history', 'tasks', 'departure-task', ?, ?, ?, ?)""",
            (
                json.dumps({"assigned_to": adult_a_user["id"], "email": adult_a_user["email"]}),
                adult_a_user["id"],
                now,
                adult_a_user["family_id"],
            ),
        )
        await db.commit()

    login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert login_resp.status_code == 200
    tokens = login_resp.json()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    delete_resp = await client.delete("/api/auth/me", headers=headers)
    assert delete_resp.status_code == 204

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row

        family_row = await (
            await db.execute(
                "SELECT deleted_at FROM families WHERE id = ?",
                (adult_a_user["family_id"],),
            )
        ).fetchone()
        assert family_row is not None
        assert family_row["deleted_at"] is None

        child_row = await (
            await db.execute(
                "SELECT deleted_at FROM children WHERE id = ?",
                (child1["id"],),
            )
        ).fetchone()
        assert child_row is not None
        assert child_row["deleted_at"] is None

        adult_b_row = await (
            await db.execute(
                "SELECT deleted_at FROM users WHERE id = ?",
                (adult_b_user["id"],),
            )
        ).fetchone()
        assert adult_b_row is not None
        assert adult_b_row["deleted_at"] is None

        adult_a_row = await (
            await db.execute(
                "SELECT id FROM users WHERE id = ?",
                (adult_a_user["id"],),
            )
        ).fetchone()
        assert adult_a_row is None

        child_audit = await (
            await db.execute(
                "SELECT created_by, client_id FROM children WHERE id = ?", (child1["id"],)
            )
        ).fetchone()
        assert tuple(child_audit) == (None, None)

        event = await (
            await db.execute(
                "SELECT assigned_to, family_member_ids, affected_member_ids, created_by, client_id "
                "FROM calendar_events WHERE id = 'departure-event'"
            )
        ).fetchone()
        assert event["assigned_to"] is None
        assert json.loads(event["family_member_ids"]) == [child1["id"]]
        assert event["affected_member_ids"] is None
        assert event["created_by"] is None
        assert event["client_id"] is None

        task = await (
            await db.execute(
                "SELECT assigned_to, created_by FROM tasks WHERE id = 'departure-task'"
            )
        ).fetchone()
        assert tuple(task) == (None, None)
        assert (
            await (
                await db.execute(
                    "SELECT id FROM task_assignments WHERE id = 'departure-assignment'"
                )
            ).fetchone()
            is None
        )
        dose = await (
            await db.execute(
                "SELECT given_by, created_by FROM medicine_doses WHERE id = 'departure-dose'"
            )
        ).fetchone()
        assert tuple(dose) == ("Deleted family member", None)
        assert (
            await (
                await db.execute("SELECT id FROM routine_items WHERE id = 'departure-routine'")
            ).fetchone()
            is None
        )
        assert (
            await (
                await db.execute(
                    "SELECT id FROM inbound_email_messages WHERE id = 'departure-email'"
                )
            ).fetchone()
            is None
        )
        assert (
            await (
                await db.execute("SELECT id FROM document_people WHERE id = 'departure-person'")
            ).fetchone()
            is None
        )
        document = await (
            await db.execute(
                "SELECT notes, created_by, client_id FROM documents WHERE id = 'departure-document'"
            )
        ).fetchone()
        assert adult_a_user["email"] not in document["notes"]
        assert tuple(document)[1:] == (None, None)
        assert (
            await (
                await db.execute("SELECT id FROM record_history WHERE id = 'departure-history'")
            ).fetchone()
            is None
        )


async def test_delete_me_removes_private_finance_and_keeps_shared_finance(
    client,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
):
    spaces_response = await client.get("/api/finance/spaces", headers=adult_a_headers)
    assert spaces_response.status_code == 200
    spaces = {item["kind"]: item["id"] for item in spaces_response.json()}

    private_fact = await client.post(
        "/api/finance/facts",
        params={"space_id": spaces["personal"]},
        json={
            "fact_key": "private.deletion",
            "statement": "private-finance-marker",
        },
        headers=adult_a_headers,
    )
    shared_fact = await client.post(
        "/api/finance/facts",
        params={"space_id": spaces["household"]},
        json={
            "fact_key": "shared.deletion",
            "statement": "shared-finance-marker",
        },
        headers=adult_a_headers,
    )
    assert private_fact.status_code == 201
    assert shared_fact.status_code == 201

    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO finance_ai_consents
                (id, space_id, user_id, disclosure_version, consent_version,
                 provider, model, accepted_at, family_id, created_at, updated_at,
                 created_by)
            VALUES ('departure-finance-consent', ?, ?, 'v1', 'v1/openai/model',
                    'openai', 'model', ?, ?, ?, ?, ?)
            """,
            (
                spaces["household"],
                adult_a_user["id"],
                now,
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_connections
                (id, space_id, provider, status, granted_capabilities,
                 encrypted_provider_secret_ref, family_id, created_at, updated_at,
                 created_by)
            VALUES ('departure-finance-connection', ?, 'ENABLE_BANKING',
                    'CONNECTED', '["accounts"]', 'private-session-marker',
                    ?, ?, ?, ?)
            """,
            (
                spaces["personal"],
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_connections
                (id, space_id, provider, institution_id, status,
                 granted_capabilities, encrypted_provider_secret_ref,
                 callback_state_hash, sync_lease_token, sync_lease_expires_at,
                 operation_generation, family_id, created_at, updated_at, created_by)
            VALUES ('departure-household-connection', ?, 'TRUELAYER', 'GB:Revolut',
                    'CONNECTED', '["accounts","balances","cards","transactions"]',
                    'household-private-token', ?, 'active-sync-lease', ?, 7,
                    ?, ?, ?, ?)
            """,
            (
                spaces["household"],
                "a" * 64,
                now,
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_accounts
                (id, space_id, connection_id, provider_account_id, label,
                 institution, account_type, purpose, currency, family_id,
                 created_at, updated_at, created_by)
            VALUES ('departure-shared-account', ?, 'departure-household-connection',
                    'provider-shared-account', 'Family current account', 'Revolut',
                    'CURRENT', 'OPERATING_CURRENT', 'GBP', ?, ?, ?, ?)
            """,
            (
                spaces["household"],
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_transactions
                (id, space_id, account_id, canonical_date, amount_minor, currency,
                 state, source_kind, description, cleaned_description,
                 data_through_at, family_id, created_at, updated_at, created_by)
            VALUES ('departure-shared-transaction', ?, 'departure-shared-account',
                    '2026-08-01', -2450, 'GBP', 'POSTED', 'PROVIDER',
                    'Family groceries', 'family groceries', ?, ?, ?, ?, ?)
            """,
            (
                spaces["household"],
                now,
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO record_history
                (id, table_name, record_id, previous_values, changed_by,
                 changed_at, family_id)
            VALUES ('departure-finance-history', 'finance_connections',
                    'departure-finance-connection', ?, ?, ?, ?)
            """,
            (
                json.dumps(
                    {
                        "space_id": spaces["personal"],
                        "secret": "private-session-marker",
                    }
                ),
                adult_b_user["id"],
                now,
                adult_a_user["family_id"],
            ),
        )
        await db.commit()

    deleted = await client.delete("/api/auth/me", headers=adult_a_headers)
    assert deleted.status_code == 204

    async with aiosqlite.connect(initialized_db) as db:
        private_space = await (
            await db.execute(
                "SELECT id FROM finance_spaces WHERE id = ?",
                (spaces["personal"],),
            )
        ).fetchone()
        private_rows = await (
            await db.execute(
                "SELECT COUNT(*) FROM finance_facts WHERE space_id = ?",
                (spaces["personal"],),
            )
        ).fetchone()
        connection = await (
            await db.execute(
                "SELECT id FROM finance_connections WHERE id = 'departure-finance-connection'"
            )
        ).fetchone()
        household_connection = await (
            await db.execute(
                "SELECT status, encrypted_provider_secret_ref, callback_state_hash, "
                "sync_lease_token, sync_lease_expires_at, operation_generation, "
                "created_by FROM finance_connections "
                "WHERE id = 'departure-household-connection'"
            )
        ).fetchone()
        shared_transaction = await (
            await db.execute(
                "SELECT description, created_by FROM finance_transactions "
                "WHERE id = 'departure-shared-transaction'"
            )
        ).fetchone()
        consent = await (
            await db.execute(
                "SELECT id FROM finance_ai_consents WHERE user_id = ?",
                (adult_a_user["id"],),
            )
        ).fetchone()
        retained = await (
            await db.execute(
                "SELECT statement, created_by FROM finance_facts WHERE id = ?",
                (shared_fact.json()["id"],),
            )
        ).fetchone()
        history = await (
            await db.execute(
                "SELECT previous_values FROM record_history WHERE family_id = ?",
                (adult_a_user["family_id"],),
            )
        ).fetchall()

    assert private_space is None
    assert private_rows[0] == 0
    assert connection is None
    assert household_connection == ("DISCONNECTED", None, None, None, None, 8, None)
    assert shared_transaction == ("Family groceries", None)
    assert consent is None
    assert retained == ("shared-finance-marker", None)
    assert "private-finance-marker" not in "\n".join(row[0] for row in history)
    assert "private-session-marker" not in "\n".join(row[0] for row in history)

    remaining_adult_sync = await client.post(
        "/api/finance/connections/departure-household-connection/sync",
        headers=adult_b_headers,
    )
    assert remaining_adult_sync.status_code in {404, 409}


# ---------------------------------------------------------------------------
# Password reset
# ---------------------------------------------------------------------------


async def test_forgot_password(client, adult_a_user):
    """POST /api/auth/forgot-password with a known email returns a generic message."""
    resp = await client.post(
        "/api/auth/forgot-password",
        json={"email": "demo-person-51@example.invalid"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "message" in data
    assert "reset_token" not in data


async def test_forgot_password_unknown_email(client):
    """POST /api/auth/forgot-password with unknown email returns a generic message."""
    resp = await client.post(
        "/api/auth/forgot-password",
        json={"email": "demo-person-42@example.invalid"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "message" in data
    assert "reset_token" not in data


async def test_forgot_password_releases_database_before_sending_email(
    client,
    adult_a_user,
    monkeypatch,
):
    database_context_active = False
    send_observed_active: bool | None = None
    original_database_lease = auth_router.database_lease

    @asynccontextmanager
    async def tracked_database_lease():
        nonlocal database_context_active
        async with original_database_lease() as db:
            database_context_active = True
            try:
                yield db
            finally:
                database_context_active = False

    async def capture_send(to_email: str, reset_token: str) -> dict:
        nonlocal send_observed_active
        send_observed_active = database_context_active
        return {"success": True, "error": None}

    monkeypatch.setattr(auth_router, "database_lease", tracked_database_lease)
    monkeypatch.setattr(auth_router, "send_password_reset_email", capture_send)

    response = await client.post(
        "/api/auth/forgot-password",
        json={"email": adult_a_user["email"]},
    )

    assert response.status_code == 200
    assert send_observed_active is False


async def test_forgot_password_rate_limit_is_durable(
    client,
    monkeypatch,
):
    monkeypatch.setattr(auth_router.sensitive_action_limiter, "max_attempts", 1)
    first = await client.post(
        "/api/auth/forgot-password",
        json={"email": "demo-person-42@example.invalid"},
    )
    auth_router.sensitive_action_limiter.reset()
    second = await client.post(
        "/api/auth/forgot-password",
        json={"email": "demo-person-42@example.invalid"},
    )

    assert first.status_code == 200
    assert second.status_code == 429


async def test_reset_password(client, adult_a_user, initialized_db):
    """Full password-reset flow: reset, then login with new password."""
    # Create a valid reset token directly (simulates email link flow).
    async with aiosqlite.connect(initialized_db) as db:
        password_hash = (
            await (
                await db.execute(
                    "SELECT password_hash FROM users WHERE id = ?",
                    (adult_a_user["id"],),
                )
            ).fetchone()
        )[0]
    reset_token = create_password_reset_token(adult_a_user["id"], password_hash)

    login_before_reset = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    old_refresh = login_before_reset.json()["refresh_token"]
    old_access = login_before_reset.json()["access_token"]

    # Step 2: reset the password
    new_password = "brand-new-password-456"
    reset_resp = await client.post(
        "/api/auth/reset-password",
        json={"token": reset_token, "new_password": new_password},
    )
    assert reset_resp.status_code == 200

    reused = await client.post(
        "/api/auth/reset-password",
        json={"token": reset_token, "new_password": "another-new-password-789"},
    )
    assert reused.status_code == 400

    revoked_session = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": old_refresh},
    )
    assert revoked_session.status_code == 401
    revoked_access = await client.get(
        "/api/auth/me",
        headers={"Authorization": f"Bearer {old_access}"},
    )
    assert revoked_access.status_code == 401

    # Step 3: login with the new password succeeds
    login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": new_password},
    )
    assert login_resp.status_code == 200
    assert "access_token" in login_resp.json()

    # Step 4: login with the old password fails
    old_login_resp = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    assert old_login_resp.status_code == 401


async def test_password_reset_token_can_only_be_committed_once_concurrently(
    client,
    adult_a_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        password_hash = (
            await (
                await db.execute(
                    "SELECT password_hash FROM users WHERE id = ?",
                    (adult_a_user["id"],),
                )
            ).fetchone()
        )[0]
    reset_token = create_password_reset_token(adult_a_user["id"], password_hash)
    login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )

    first, second = await asyncio.gather(
        client.post(
            "/api/auth/reset-password",
            json={"token": reset_token, "new_password": "concurrent-password-one"},
        ),
        client.post(
            "/api/auth/reset-password",
            json={"token": reset_token, "new_password": "concurrent-password-two"},
        ),
    )

    old_access = await client.get(
        "/api/auth/me",
        headers={"Authorization": f"Bearer {login.json()['access_token']}"},
    )
    password_one = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "concurrent-password-one"},
    )
    password_two = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "concurrent-password-two"},
    )

    assert sorted([first.status_code, second.status_code]) == [200, 400]
    assert old_access.status_code == 401
    assert sorted([password_one.status_code, password_two.status_code]) == [200, 401]


async def test_login_verified_before_reset_cannot_create_session_after_reset(
    client,
    adult_a_user,
    initialized_db,
    monkeypatch,
):
    async with aiosqlite.connect(initialized_db) as db:
        password_hash = (
            await (
                await db.execute(
                    "SELECT password_hash FROM users WHERE id = ?",
                    (adult_a_user["id"],),
                )
            ).fetchone()
        )[0]
    reset_token = create_password_reset_token(adult_a_user["id"], password_hash)
    verification_finished = threading.Event()
    allow_login_to_continue = threading.Event()
    original_verify = auth_router.verify_and_upgrade_password

    def delayed_verify(plain_password: str, stored_hash: str):
        result = original_verify(plain_password, stored_hash)
        verification_finished.set()
        allow_login_to_continue.wait(timeout=5)
        return result

    monkeypatch.setattr(auth_router, "verify_and_upgrade_password", delayed_verify)
    login_task = asyncio.create_task(
        client.post(
            "/api/auth/login",
            json={"email": "demo-person-51@example.invalid", "password": "password123"},
        )
    )
    assert await asyncio.to_thread(verification_finished.wait, 2)
    try:
        reset = await client.post(
            "/api/auth/reset-password",
            json={"token": reset_token, "new_password": "race-proof-new-password"},
        )
    finally:
        allow_login_to_continue.set()
    login = await asyncio.wait_for(login_task, timeout=2)

    async with aiosqlite.connect(initialized_db) as db:
        active_refresh_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM refresh_tokens WHERE user_id = ? AND revoked_at IS NULL",
                    (adult_a_user["id"],),
                )
            ).fetchone()
        )[0]

    assert reset.status_code == 200
    assert login.status_code == 401
    assert active_refresh_count == 0


async def test_reset_password_rate_limit_is_durable(
    client,
    adult_a_user,
    initialized_db,
    monkeypatch,
):
    async with aiosqlite.connect(initialized_db) as db:
        password_hash = (
            await (
                await db.execute(
                    "SELECT password_hash FROM users WHERE id = ?",
                    (adult_a_user["id"],),
                )
            ).fetchone()
        )[0]
    reset_token = create_password_reset_token(adult_a_user["id"], password_hash)
    monkeypatch.setattr(auth_router.sensitive_action_limiter, "max_attempts", 1)

    first = await client.post(
        "/api/auth/reset-password",
        json={"token": reset_token, "new_password": "durable-reset-password"},
    )
    auth_router.sensitive_action_limiter.reset()
    second = await client.post(
        "/api/auth/reset-password",
        json={"token": reset_token, "new_password": "different-reset-password"},
    )

    assert first.status_code == 200
    assert second.status_code == 429


async def test_emailed_fragment_reset_link_works_end_to_end(
    client,
    adult_a_user,
    initialized_db,
    monkeypatch,
):
    """The emailed token stays in a URL fragment and can complete the browser flow."""
    captured: dict[str, str] = {}

    async def capture_email(to_email: str, reset_token: str) -> dict:
        captured.update(to_email=to_email, reset_token=reset_token)
        return {"success": True, "error": None}

    monkeypatch.setattr("app.routers.auth.send_password_reset_email", capture_email)
    monkeypatch.setattr(settings, "web_app_url", "https://hausklar.example")
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE users SET must_change_password = 1 WHERE id = ?",
            (adult_a_user["id"],),
        )
        await db.commit()

    browser_login = await client.post(
        "/api/auth/web/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    old_access = browser_login.cookies.get("hausklar_access")
    old_refresh = browser_login.cookies.get("hausklar_refresh")
    forgot = await client.post(
        "/api/auth/forgot-password",
        json={"email": "demo-person-51@example.invalid"},
    )

    assert forgot.status_code == 200
    assert captured["to_email"] == "demo-person-51@example.invalid"
    link = password_reset_link(captured["reset_token"])
    parsed = urlsplit(link)
    assert parsed.scheme == "https"
    assert parsed.netloc == "hausklar.example"
    assert parsed.path == "/"
    assert parsed.query == ""
    assert parsed.fragment.startswith("reset-password=")
    fragment_token = unquote(parsed.fragment.removeprefix("reset-password="))

    reset = await client.post(
        "/api/auth/reset-password",
        json={"token": fragment_token, "new_password": "reset-private-password"},
    )

    assert reset.status_code == 200
    assert any('hausklar_access=""' in value for value in reset.headers.get_list("set-cookie"))
    old_session = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": old_refresh},
    )
    assert old_session.status_code == 401
    old_access_session = await client.get(
        "/api/auth/web/session",
        headers={"Cookie": f"hausklar_access={old_access}"},
    )
    assert old_access_session.status_code == 401
    new_login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "reset-private-password"},
    )
    assert new_login.status_code == 200
    assert new_login.json()["user"]["must_change_password"] is False


async def test_required_password_change_blocks_features_but_allows_recovery(
    client,
    adult_a_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE users SET must_change_password = 1 WHERE id = ?",
            (adult_a_user["id"],),
        )
        await db.commit()

    first_login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    first_tokens = first_login.json()
    first_headers = {"Authorization": f"Bearer {first_tokens['access_token']}"}

    blocked = await client.get("/api/family/members", headers=first_headers)
    profile = await client.get("/api/auth/me", headers=first_headers)
    logout = await client.post(
        "/api/auth/logout",
        headers=first_headers,
        json={"refresh_token": first_tokens["refresh_token"]},
    )

    assert blocked.status_code == 403
    assert blocked.json()["detail"] == "Password change required"
    assert profile.status_code == 200
    assert profile.json()["must_change_password"] is True
    assert logout.status_code == 204

    second_login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    second_tokens = second_login.json()
    changed = await client.post(
        "/api/auth/change-password",
        headers={"Authorization": f"Bearer {second_tokens['access_token']}"},
        json={
            "current_password": "password123",
            "new_password": "required-private-password",
        },
    )
    assert changed.status_code == 200
    assert changed.json()["user"]["must_change_password"] is False
    allowed = await client.get(
        "/api/family/members",
        headers={"Authorization": f"Bearer {changed.json()['access_token']}"},
    )
    assert allowed.status_code == 200


async def test_public_family_registration_is_disabled_by_default(
    client,
    monkeypatch,
):
    monkeypatch.setattr(settings, "allow_public_registration", False)
    response = await client.post(
        "/api/auth/register-family",
        json={
            "family_name": "Uninvited Family",
            "user_name": "Unknown",
            "email": "unknown@example.invalid",
            "password": "secure-password-123",
        },
    )

    assert response.status_code == 403


async def test_change_password_updates_login_and_clears_required_flag(
    client,
    adult_a_user,
    adult_a_headers,
):
    prior_login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    response = await client.post(
        "/api/auth/change-password",
        headers=adult_a_headers,
        json={
            "current_password": "password123",
            "new_password": "a-new-secure-password",
        },
    )

    assert response.status_code == 200
    result = response.json()
    assert result["user"]["must_change_password"] is False
    assert result["access_token"]
    assert result["refresh_token"]
    old_access_rejected = await client.get("/api/auth/me", headers=adult_a_headers)
    assert old_access_rejected.status_code == 401
    replacement_access_accepted = await client.get(
        "/api/auth/me",
        headers={"Authorization": f"Bearer {result['access_token']}"},
    )
    assert replacement_access_accepted.status_code == 200
    rejected_old_refresh = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": prior_login.json()["refresh_token"]},
    )
    assert rejected_old_refresh.status_code == 401
    refreshed = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": result["refresh_token"]},
    )
    assert refreshed.status_code == 200
    login = await client.post(
        "/api/auth/login",
        json={"email": "demo-person-51@example.invalid", "password": "a-new-secure-password"},
    )
    assert login.status_code == 200


async def test_web_change_password_rotates_httponly_session(client, adult_a_user):
    login = await client.post(
        "/api/auth/web/login",
        json={"email": "demo-person-51@example.invalid", "password": "password123"},
    )
    old_access = login.cookies.get("hausklar_access")
    old_refresh = login.cookies.get("hausklar_refresh")

    changed = await client.post(
        "/api/auth/web/change-password",
        json={
            "current_password": "password123",
            "new_password": "browser-private-password",
        },
        headers={"Origin": "https://test"},
    )

    assert changed.status_code == 200
    assert changed.json()["must_change_password"] is False
    assert "access_token" not in changed.json()
    assert changed.cookies.get("hausklar_access")
    new_refresh = changed.cookies.get("hausklar_refresh")
    assert new_refresh and new_refresh != old_refresh
    old_refresh_result = await client.post(
        "/api/auth/refresh",
        json={"refresh_token": old_refresh},
    )
    assert old_refresh_result.status_code == 401
    old_access_result = await client.get(
        "/api/auth/web/session",
        headers={"Cookie": f"hausklar_access={old_access}"},
    )
    assert old_access_result.status_code == 401
    session = await client.get("/api/auth/web/session")
    assert session.status_code == 200


async def test_change_password_rejects_short_or_reused_password(
    client,
    adult_a_user,
    adult_a_headers,
):
    short = await client.post(
        "/api/auth/change-password",
        headers=adult_a_headers,
        json={"current_password": "password123", "new_password": "too-short"},
    )
    initial_change = await client.post(
        "/api/auth/change-password",
        headers=adult_a_headers,
        json={
            "current_password": "password123",
            "new_password": "initial-secure-password",
        },
    )
    reused = await client.post(
        "/api/auth/change-password",
        headers={"Authorization": f"Bearer {initial_change.json()['access_token']}"},
        json={
            "current_password": "initial-secure-password",
            "new_password": "initial-secure-password",
        },
    )

    assert short.status_code == 422
    assert initial_change.status_code == 200
    assert reused.status_code == 400


async def test_family_invite_is_expiring_single_use_and_atomically_consumed(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
):
    invite = await client.post("/api/auth/invite", headers=adult_a_headers)
    invite_data = invite.json()
    expires_at = datetime.fromisoformat(invite_data["expires_at"])
    remaining = expires_at - datetime.now(timezone.utc)
    assert invite.status_code == 200
    assert len(invite_data["invite_code"]) == 8
    assert timedelta(hours=23, minutes=59) < remaining <= timedelta(hours=24)

    def join_body(index: int) -> dict:
        return {
            "invite_code": invite_data["invite_code"],
            "user_name": f"Joining User {index}",
                "email": f"joining-{index}@example.invalid",
            "password": "join-family-password",
        }

    first, second = await asyncio.gather(
        client.post("/api/auth/join-family", json=join_body(1)),
        client.post("/api/auth/join-family", json=join_body(2)),
    )
    replay = await client.post("/api/auth/join-family", json=join_body(3))

    async with aiosqlite.connect(initialized_db) as db:
        family_invite = await (
            await db.execute(
                "SELECT invite_code, invite_expires_at FROM families WHERE id = ?",
                (adult_a_user["family_id"],),
            )
        ).fetchone()
        joined_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM users WHERE email LIKE 'joining-%@example.invalid'"
                )
            ).fetchone()
        )[0]

    assert sorted([first.status_code, second.status_code]) == [200, 404]
    assert replay.status_code == 404
    assert family_invite == (None, None)
    assert joined_count == 1


async def test_expired_family_invite_cannot_be_used(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
):
    invite = await client.post("/api/auth/invite", headers=adult_a_headers)
    invite_code = invite.json()["invite_code"]
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE families SET invite_expires_at = ? WHERE id = ?",
            (
                (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat(),
                adult_a_user["family_id"],
            ),
        )
        await db.commit()

    response = await client.post(
        "/api/auth/join-family",
        json={
            "invite_code": invite_code,
            "user_name": "Too Late",
            "email": "expired-invite@example.invalid",
            "password": "join-family-password",
        },
    )

    assert response.status_code == 404


async def test_join_family_rate_limit_is_durable(client, monkeypatch):
    monkeypatch.setattr(auth_router.sensitive_action_limiter, "max_attempts", 1)
    body = {
        "invite_code": "BOGUS123",
        "user_name": "Unknown",
        "email": "unknown-join@example.invalid",
        "password": "join-family-password",
    }

    first = await client.post("/api/auth/join-family", json=body)
    auth_router.sensitive_action_limiter.reset()
    second = await client.post("/api/auth/join-family", json=body)

    assert first.status_code == 404
    assert second.status_code == 429
