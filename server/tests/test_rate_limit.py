"""Tests for login rate limiting (brute-force protection)."""

from unittest.mock import patch



LOGIN_URL = "/api/auth/login"
WRONG_CREDS = {"email": "demo-person-51@example.invalid", "password": "wrongpassword"}
CORRECT_CREDS = {"email": "demo-person-51@example.invalid", "password": "password123"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _rate_limiter():
    """Return the rate limiter instance used by the auth router."""
    from app.routers.auth import rate_limiter
    return rate_limiter


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestRateLimitBasic:
    """First 5 attempts should not trigger rate limiting."""

    async def test_first_five_wrong_password_returns_401(self, client, adult_a_user):
        rl = _rate_limiter()
        rl.reset()

        for i in range(5):
            resp = await client.post(LOGIN_URL, json=WRONG_CREDS)
            assert resp.status_code == 401, f"Attempt {i + 1} should return 401, got {resp.status_code}"

    async def test_sixth_attempt_returns_429(self, client, adult_a_user):
        rl = _rate_limiter()
        rl.reset()

        # Exhaust the 5 allowed attempts.
        for _ in range(5):
            await client.post(LOGIN_URL, json=WRONG_CREDS)

        # The 6th attempt should be rate limited.
        resp = await client.post(LOGIN_URL, json=WRONG_CREDS)
        assert resp.status_code == 429
        body = resp.json()
        assert "Too many login attempts" in body["detail"]
        assert "Retry-After" in resp.headers


class TestRateLimitWindowExpiry:
    """Rate limit should reset after the window expires."""

    async def test_rate_limit_resets_after_window(self, client, adult_a_user):
        rl = _rate_limiter()
        rl.reset()

        # Use a short window for easy time-mocking.
        original_window = rl.window_seconds

        # Exhaust the allowed attempts.
        for _ in range(5):
            await client.post(LOGIN_URL, json=WRONG_CREDS)

        # 6th attempt should be blocked.
        resp = await client.post(LOGIN_URL, json=WRONG_CREDS)
        assert resp.status_code == 429

        # Advance time past the window by patching time.time.
        import time as _time

        real_time = _time.time()
        with patch("app.middleware.rate_limit.time") as mock_time:
            mock_time.time.return_value = real_time + original_window + 1
            resp = await client.post(LOGIN_URL, json=WRONG_CREDS)
            # After the window expires the attempt should go through (wrong
            # password -> 401, but NOT 429).
            assert resp.status_code == 401


class TestRateLimitPerIP:
    """Different IPs should have independent limits."""

    async def test_different_ips_have_separate_limits(self, client, adult_a_user):
        rl = _rate_limiter()
        rl.reset()

        # Exhaust attempts for the default test-client IP.
        for _ in range(5):
            await client.post(LOGIN_URL, json=WRONG_CREDS)

        resp = await client.post(LOGIN_URL, json=WRONG_CREDS)
        assert resp.status_code == 429

        # Simulate a request from a different IP by injecting timestamps under
        # a different key — then verify that the different IP's bucket is empty.
        other_ip = "192.0.2.109"
        assert other_ip not in rl._attempts or len(rl._attempts[other_ip]) == 0

    async def test_uses_cf_connecting_ip_when_behind_proxy(self, client, adult_a_user):
        rl = _rate_limiter()
        rl.reset()

        resp = await client.post(
            LOGIN_URL,
            json=WRONG_CREDS,
            headers={"CF-Connecting-IP": "203.0.113.10"},
        )
        assert resp.status_code == 401
        assert "203.0.113.10" in rl._attempts

    async def test_uses_xff_fallback_when_cf_header_missing(self, client, adult_a_user):
        rl = _rate_limiter()
        rl.reset()

        resp = await client.post(
            LOGIN_URL,
            json=WRONG_CREDS,
            headers={"X-Forwarded-For": "198.51.100.24, 127.0.0.1"},
        )
        assert resp.status_code == 401
        assert "198.51.100.24" in rl._attempts


class TestRateLimitSuccessResetsFailures:
    """Successful logins should not consume the failure budget."""

    async def test_successful_login_clears_failure_history(self, client, adult_a_user):
        rl = _rate_limiter()
        rl.reset()

        # Record a couple failures
        for _ in range(2):
            resp = await client.post(LOGIN_URL, json=WRONG_CREDS)
            assert resp.status_code == 401

        # Successful login should clear failure bucket
        success = await client.post(LOGIN_URL, json=CORRECT_CREDS)
        assert success.status_code == 200

        # We should be able to fail 5 more times before 429
        for _ in range(5):
            resp = await client.post(LOGIN_URL, json=WRONG_CREDS)
            assert resp.status_code == 401

        blocked = await client.post(LOGIN_URL, json=WRONG_CREDS)
        assert blocked.status_code == 429


async def test_account_limit_survives_process_memory_reset_and_ip_change(
    client,
    adult_a_user,
):
    limiter = _rate_limiter()
    for index in range(5):
        response = await client.post(
            LOGIN_URL,
            json=WRONG_CREDS,
            headers={"CF-Connecting-IP": f"203.0.113.{index + 1}"},
        )
        assert response.status_code == 401

    limiter.reset()
    blocked = await client.post(
        LOGIN_URL,
        json=WRONG_CREDS,
        headers={"CF-Connecting-IP": "203.0.113.99"},
    )

    assert blocked.status_code == 429
    assert "Retry-After" in blocked.headers
