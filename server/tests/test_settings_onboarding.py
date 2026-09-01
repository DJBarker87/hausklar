"""Focused contracts for progressive Settings and household onboarding."""

from unittest.mock import AsyncMock, patch

import aiosqlite

from app.services.calendar_sync import FetchedCalendar


ICS = b"""BEGIN:VCALENDAR\r
VERSION:2.0\r
PRODID:-//HausKlar test//EN\r
BEGIN:VEVENT\r
UID:first-commitment@test\r
DTSTART:20260810T080000Z\r
DTEND:20260810T090000Z\r
SUMMARY:First family commitment\r
END:VEVENT\r
END:VCALENDAR\r
"""


async def test_profile_name_is_editable_without_changing_auth_identity(
    client, adult_a_headers, adult_a_user
):
    updated = await client.patch(
        "/api/auth/me",
        headers=adult_a_headers,
        json={"name": "  Dominic   Example "},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["name"] == "Dominic Example"
    assert updated.json()["email"] == adult_a_user["email"]
    assert updated.json()["role"] == "admin"

    profile = await client.get("/api/auth/me", headers=adult_a_headers)
    assert profile.json()["name"] == "Dominic Example"


async def test_onboarding_is_derived_and_skippable(client, adult_a_headers):
    initial = await client.get("/api/auth/onboarding", headers=adult_a_headers)
    assert initial.status_code == 200, initial.text
    assert initial.json() == {
        "family_name": "Test Family",
        "people_count": 1,
        "adult_count": 1,
        "child_count": 0,
        "calendar_commitment_count": 0,
        "reminders_configured": False,
        "selected_modules": [],
        "dismissed": False,
        "completed": False,
        "should_show": True,
        "first_success": False,
    }

    saved = await client.patch(
        "/api/auth/onboarding",
        headers=adult_a_headers,
        json={"selected_modules": ["children", "medicine_sleep"], "dismissed": True},
    )
    assert saved.status_code == 200, saved.text
    assert saved.json()["selected_modules"] == ["children", "medicine_sleep"]
    assert saved.json()["dismissed"] is True
    assert saved.json()["should_show"] is False


async def test_family_invite_has_single_shareable_fragment_link(client, adult_a_headers):
    response = await client.post("/api/auth/invite", headers=adult_a_headers)
    assert response.status_code == 200, response.text
    invitation = response.json()
    assert invitation["join_url"] == f"https://test/#join={invitation['invite_code']}"
    assert invitation["expires_at"]


async def test_web_join_uses_http_only_session_cookies(client, adult_a_headers):
    invitation = (await client.post("/api/auth/invite", headers=adult_a_headers)).json()
    joined = await client.post(
        "/api/auth/web/join-family",
        json={
            "invite_code": invitation["invite_code"],
            "user_name": "Other adult",
            "email": "other-adult@example.invalid",
            "password": "a-secure-new-password",
        },
    )
    assert joined.status_code == 200, joined.text
    assert joined.json()["role"] == "user"
    assert "access_token" not in joined.json()
    cookies = joined.headers.get_list("set-cookie")
    assert any("hausklar_access=" in item and "HttpOnly" in item for item in cookies)
    assert any("hausklar_refresh=" in item and "HttpOnly" in item for item in cookies)


async def test_child_can_be_established_during_onboarding(client, adult_a_headers):
    created = await client.post(
        "/api/children/",
        headers=adult_a_headers,
        json={
            "id": "c74f63ce-dba2-4f82-b21e-151bbb5d5570",
            "name": "  Alice ",
            "date_of_birth": "2022-04-12",
        },
    )
    assert created.status_code == 201, created.text
    assert created.json()["name"] == "Alice"

    status = await client.get("/api/auth/onboarding", headers=adult_a_headers)
    assert status.json()["child_count"] == 1
    assert status.json()["people_count"] == 2


async def test_calendar_connection_validates_before_any_secret_is_saved(
    client, adult_a_headers, initialized_db, monkeypatch
):
    async def safe_url(value):
        return value, "calendar.example"

    async def fetched(*_args, **_kwargs):
        return FetchedCalendar(ICS, None, None)

    monkeypatch.setattr("app.routers.calendar_sync.validate_public_https_url", safe_url)
    monkeypatch.setattr("app.routers.calendar_sync.fetch_calendar", fetched)

    response = await client.post(
        "/api/calendar/sources/validate",
        headers=adult_a_headers,
        json={"name": "School", "url": "https://calendar.example/private.ics"},
    )
    assert response.status_code == 200, response.text
    assert response.json() == {
        "valid": True,
        "hostname": "calendar.example",
        "event_count": 1,
    }
    async with aiosqlite.connect(initialized_db) as db:
        count = await (await db.execute("SELECT COUNT(*) FROM calendar_sources")).fetchone()
    assert count[0] == 0


async def test_home_connection_candidate_is_tested_without_being_saved(
    client, adult_a_headers
):
    mock_response = AsyncMock()
    mock_response.raise_for_status = lambda: None
    with patch("app.routers.family.httpx.AsyncClient") as client_type:
        instance = AsyncMock()
        instance.get.return_value = mock_response
        instance.__aenter__.return_value = instance
        instance.__aexit__.return_value = False
        client_type.return_value = instance
        response = await client.post(
            "/api/family/settings/ha/test",
            headers=adult_a_headers,
            json={
                "ha_url": "http://ha.local:8123",
                "ha_token": "candidate-long-lived-access-token",
            },
        )

    assert response.status_code == 200, response.text
    assert response.json()["success"] is True
    saved = await client.get("/api/family/settings/ha", headers=adult_a_headers)
    assert saved.json()["configured"] is False
