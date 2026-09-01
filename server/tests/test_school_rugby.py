"""Managed Example School rugby fixture discovery, syncing, and venue overrides."""

import aiosqlite
from cryptography.fernet import Fernet

from app.config import settings
from app.services.calendar_sync import FetchedCalendar, sync_calendar_source
from app.services.school_rugby import parse_rugby_teams, rugby_source_config
from app.utils.encryption import encrypt_value


RUGBY_ICS = b"""BEGIN:VCALENDAR\r
VERSION:2.0\r
PRODID:-//SOCS//EN\r
BEGIN:VEVENT\r
UID:colts-c-dulwich@socs\r
DTSTART:20260919T133000Z\r
DTEND:20260919T153000Z\r
SUMMARY:Example School College Rugby Union Colts C vs Dulwich College\r
LOCATION:Home\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:colts-c-marlborough@socs\r
DTSTART:20261017T133000Z\r
DTEND:20261017T153000Z\r
SUMMARY:Example School College Rugby Union Colts C vs Marlborough College\r
LOCATION:Away\r
END:VEVENT\r
END:VCALENDAR\r
"""


def test_team_parser_extracts_rugby_dropdown_options_once():
    page = """
    <a href="Fixtures_List.asp?Id=65&amp;TID=2064255&amp;SID=24"
       title="Colts C Fixtures &amp; Results">Colts C</a>
    <a href="Fixtures_List.asp?Id=65&amp;TID=2064255&amp;SID=24">Colts C</a>
    <a href="Fixtures_List.asp?Id=65&amp;TID=999&amp;SID=10">Wrong sport</a>
    """
    assert parse_rugby_teams(page) == [{"id": "2064255", "name": "Colts C"}]


async def test_managed_rugby_calendar_and_manual_venue_override(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
    monkeypatch,
):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()

    async def teams():
        return {
            "season": "2026/27",
            "teams": [
                {"id": "2064254", "name": "Colts B"},
                {"id": "2064255", "name": "Colts C"},
            ],
        }

    async def fetched(*_args, **_kwargs):
        return FetchedCalendar(RUGBY_ICS, '"rugby-v1"', None)

    monkeypatch.setattr("app.routers.calendar_sync.discover_rugby_teams", teams)
    monkeypatch.setattr("app.routers.calendar_sync.fetch_calendar", fetched)
    monkeypatch.setattr("app.services.calendar_sync.fetch_calendar", fetched)

    denied = await client.put(
        "/api/calendar/rugby",
        json={"team_id": "2064255"},
        headers=adult_b_headers,
    )
    assert denied.status_code == 403

    available = await client.get("/api/calendar/rugby/teams", headers=adult_a_headers)
    assert available.status_code == 200
    assert available.json()["teams"][1] == {"id": "2064255", "name": "Colts C"}

    configured = await client.put(
        "/api/calendar/rugby",
        json={"team_id": "2064255"},
        headers=adult_a_headers,
    )
    assert configured.status_code == 200, configured.text
    setting = configured.json()
    assert setting["configured"] is True
    assert setting["team_name"] == "Colts C"
    assert setting["season"] == "2026/27"
    assert setting["owner_user_id"] == adult_a_user["id"]
    assert setting["affected_user_ids"] == [adult_b_user["id"]]
    assert setting["fixture_count"] == 2

    generic_sources = await client.get("/api/calendar/sources", headers=adult_a_headers)
    assert generic_sources.status_code == 200
    assert generic_sources.json() == []

    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-09-01", "end": "2026-10-31"},
        headers=adult_a_headers,
    )
    assert listed.status_code == 200, listed.text
    fixtures = {event["rugby_venue"]: event for event in listed.json()}
    home = fixtures["home"]
    away = fixtures["away"]
    assert home["title"] == "HOME — Colts C rugby v Dulwich College"
    assert home["start_time"] == "2026-09-19T12:00:00Z"
    assert home["end_time"] == "2026-09-19T18:00:00Z"
    assert home["location"] == "HOME"
    assert home["family_member_ids"] == [adult_a_user["id"]]
    assert home["affected_member_ids"] == [adult_b_user["id"]]
    assert home["event_type"] == "rugby_fixture"
    assert home["exertion"] == 3
    assert home["source_color"] == "#2563EB"
    assert "pressure" not in (home["description"] or "").lower()
    assert away["title"] == "AWAY — Colts C rugby v Marlborough College"
    assert away["source_color"] == "#DC2626"

    changed = await client.put(
        f"/api/calendar/rugby/fixtures/{home['id']}/venue",
        json={"venue": "away", "client_id": "kat-phone"},
        headers=adult_b_headers,
    )
    assert changed.status_code == 200, changed.text
    assert changed.json()["rugby_venue"] == "away"
    assert changed.json()["rugby_venue_overridden"] is True
    assert changed.json()["title"].startswith("AWAY —")
    assert changed.json()["source_color"] == "#DC2626"

    refreshed = await client.post("/api/calendar/rugby/sync", headers=adult_a_headers)
    assert refreshed.status_code == 200, refreshed.text
    after_sync = await client.get(
        "/api/calendar/",
        params={"start": "2026-09-19", "end": "2026-09-20"},
        headers=adult_a_headers,
    )
    persisted = after_sync.json()[0]
    assert persisted["rugby_venue"] == "away"
    assert persisted["rugby_venue_overridden"] is True
    assert persisted["source_color"] == "#DC2626"

    restored = await client.put(
        f"/api/calendar/rugby/fixtures/{home['id']}/venue",
        json={"venue": "home"},
        headers=adult_a_headers,
    )
    assert restored.status_code == 200
    assert restored.json()["rugby_venue"] == "home"
    assert restored.json()["rugby_venue_overridden"] is False
    assert restored.json()["source_color"] == "#2563EB"

    async with aiosqlite.connect(initialized_db) as db:
        source_kind, override = await (
            await db.execute(
                """SELECT cs.source_kind,ce.rugby_venue_override
                   FROM calendar_events ce JOIN calendar_sources cs
                     ON cs.id=ce.calendar_source_id WHERE ce.id=?""",
                (home["id"],),
            )
        ).fetchone()
    assert source_kind == "school_rugby"
    assert override is None


async def test_managed_team_rolls_forward_to_the_new_school_season(
    initialized_db,
    adult_a_user,
    adult_b_user,
    monkeypatch,
):
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    source_id = "00000000-0000-4000-8000-000000000777"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO calendar_sources
               (id,family_id,name,encrypted_url,hostname,assigned_to,source_kind,
                config_json,color,created_by)
               VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (
                source_id,
                adult_a_user["family_id"],
                "Example School Colts C rugby",
                encrypt_value("https://ical.schoolssports.com/?TID=111"),
                "ical.schoolssports.com",
                adult_a_user["id"],
                "school_rugby",
                rugby_source_config(
                    team_id="111",
                    team_name="Colts C",
                    season="2025/26",
                ),
                "#2563EB",
                adult_a_user["id"],
            ),
        )
        await db.commit()

    async def teams():
        return {"season": "2026/27", "teams": [{"id": "2064255", "name": "Colts C"}]}

    async def fetched(*_args, **_kwargs):
        return FetchedCalendar(RUGBY_ICS, '"new-season"', None)

    monkeypatch.setattr(
        "app.services.calendar_sync.current_school_season",
        lambda: ("20262027", "2026/27"),
    )
    monkeypatch.setattr("app.services.calendar_sync.discover_rugby_teams", teams)
    monkeypatch.setattr("app.services.calendar_sync.fetch_calendar", fetched)

    result = await sync_calendar_source(source_id, family_id=adult_a_user["family_id"])
    assert result["events"] == 2
    async with aiosqlite.connect(initialized_db) as db:
        source = await (
            await db.execute(
                "SELECT config_json,last_success_at FROM calendar_sources WHERE id=?",
                (source_id,),
            )
        ).fetchone()
        affected = await (
            await db.execute(
                "SELECT affected_member_ids FROM calendar_events WHERE calendar_source_id=? LIMIT 1",
                (source_id,),
            )
        ).fetchone()
    assert '"team_id":"2064255"' in source[0]
    assert source[1] is not None
    assert adult_b_user["id"] in affected[0]
