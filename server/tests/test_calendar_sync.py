"""External ICS synchronization and private outbound feed tests."""

from datetime import datetime, timezone

import aiosqlite
import pytest
from cryptography.fernet import Fernet

from app.config import settings
from app.services.calendar_sync import (
    CalendarSyncError,
    FetchedCalendar,
    parse_calendar,
    sync_calendar_source,
    validate_public_https_url,
)
from app.utils.encryption import encrypt_value


ICS = b"""BEGIN:VCALENDAR\r
VERSION:2.0\r
PRODID:-//Test//EN\r
BEGIN:VEVENT\r
UID:school-term@test\r
DTSTART:20260714T080000Z\r
DTEND:20260714T090000Z\r
RRULE:FREQ=DAILY;COUNT=3\r
EXDATE:20260715T080000Z\r
SUMMARY:School run\r
LOCATION:School\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:school-term@test\r
RECURRENCE-ID:20260716T080000Z\r
DTSTART:20260716T100000Z\r
DTEND:20260716T110000Z\r
SUMMARY:Late school run\r
END:VEVENT\r
END:VCALENDAR\r
"""


def fixed_calendar_now() -> datetime:
    """Keep bounded-import tests independent of the wall clock."""
    return datetime(2026, 7, 12, 12, 0, tzinfo=timezone.utc)


def test_parse_calendar_expands_recurrence_exclusions_and_overrides():
    events = parse_calendar(
        ICS,
        source_id="source-1",
        assigned_to="person-1",
        now=datetime(2026, 7, 12, tzinfo=timezone.utc),
    )
    assert [(event["title"], event["start_time"]) for event in events] == [
        ("School run", "2026-07-14T08:00:00Z"),
        ("Late school run", "2026-07-16T10:00:00Z"),
    ]
    assert all(event["assigned_to"] == "person-1" for event in events)
    assert len({event["external_instance_key"] for event in events}) == 2


@pytest.mark.parametrize(
    "url",
    [
        "http://calendar.example/feed.ics",
        "https://localhost/feed.ics",
        "https://user:pass@example.invalid/feed.ics",
        "https://example.com:8443/feed.ics",
        "https://example.com/feed.ics#fragment",
    ],
)
async def test_calendar_url_rejects_unsafe_addresses(url):
    with pytest.raises(CalendarSyncError):
        await validate_public_https_url(url)


async def test_source_admin_management_hides_url_and_imports_read_only(
    client, adult_a_headers, adult_b_headers, adult_a_user, initialized_db, monkeypatch
):
    monkeypatch.setattr("app.services.calendar_sync._utc_now", fixed_calendar_now)
    settings.ha_token_encryption_key = Fernet.generate_key().decode()

    async def safe_url(value):
        return value, "calendar.example"

    async def fetched(*args, **kwargs):
        return FetchedCalendar(ICS, '"v1"', "Thu, 16 Jul 2026 11:00:00 GMT")

    monkeypatch.setattr("app.routers.calendar_sync.validate_public_https_url", safe_url)
    monkeypatch.setattr("app.services.calendar_sync.validate_public_https_url", safe_url)
    monkeypatch.setattr("app.services.calendar_sync.fetch_calendar", fetched)

    denied = await client.post(
        "/api/calendar/sources",
        json={"name": "School", "url": "https://calendar.example/private.ics"},
        headers=adult_b_headers,
    )
    assert denied.status_code == 403

    created = await client.post(
        "/api/calendar/sources",
        json={"name": "School", "url": "https://calendar.example/private.ics"},
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    source = created.json()
    assert source["hostname"] == "calendar.example"
    assert "url" not in source and "encrypted_url" not in source
    assert source["last_error"] is None

    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-07-12", "end": "2026-07-20"},
        headers=adult_a_headers,
    )
    assert listed.status_code == 200, listed.text
    imported = next(event for event in listed.json() if event["title"] == "School run")
    assert imported["read_only"] is True
    assert imported["source_name"] == "School"
    assert imported["source_color"] == "#2563EB"
    updated = await client.put(
        f"/api/calendar/{imported['id']}", json={"title": "Changed"}, headers=adult_a_headers
    )
    assert updated.status_code == 200
    override = updated.json()
    assert override["id"] != imported["id"]
    assert override["read_only"] is False
    assert override["overridden_event_id"] == imported["id"]

    relisted = await client.get(
        "/api/calendar/",
        params={"start": "2026-07-12", "end": "2026-07-20"},
        headers=adult_a_headers,
    )
    assert imported["id"] not in {event["id"] for event in relisted.json()}
    assert override["id"] in {event["id"] for event in relisted.json()}
    deleted = await client.delete(f"/api/calendar/{imported['id']}", headers=adult_a_headers)
    assert deleted.status_code == 409

    removed = await client.delete(
        f"/api/calendar/sources/{source['id']}", headers=adult_a_headers
    )
    assert removed.status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        override_deleted_at = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM calendar_events WHERE id = ?",
                    (override["id"],),
                )
            ).fetchone()
        )[0]
    assert override_deleted_at is not None


async def test_sync_upserts_then_removes_missing_occurrences(
    initialized_db, adult_a_user, monkeypatch
):
    monkeypatch.setattr("app.services.calendar_sync._utc_now", fixed_calendar_now)
    settings.ha_token_encryption_key = Fernet.generate_key().decode()
    source_id = "00000000-0000-4000-8000-000000000099"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO calendar_sources
               (id,family_id,name,encrypted_url,hostname,color,created_by)
               VALUES (?,?,?,?,?,?,?)""",
            (
                source_id,
                adult_a_user["family_id"],
                "School",
                encrypt_value("https://calendar.example/private.ics"),
                "calendar.example",
                "#123456",
                adult_a_user["id"],
            ),
        )
        await db.commit()

    responses = [
        FetchedCalendar(ICS, '"v1"', None),
        FetchedCalendar(
            ICS.replace(b"BEGIN:VEVENT\r\nUID:school-term@test", b"BEGIN:VEVENT\r\nSTATUS:CANCELLED\r\nUID:school-term@test", 1),
            '"v2"',
            None,
        ),
    ]

    async def fetched(*args, **kwargs):
        return responses.pop(0)

    monkeypatch.setattr("app.services.calendar_sync.fetch_calendar", fetched)
    first = await sync_calendar_source(source_id, family_id=adult_a_user["family_id"])
    assert first["events"] == 2
    assert first["changed"] == 2
    override_id = "00000000-0000-4000-8000-000000000098"
    now_text = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        source_event = await (
            await db.execute(
                "SELECT * FROM calendar_events WHERE calendar_source_id = ? AND title = 'School run'",
                (source_id,),
            )
        ).fetchone()
        assert source_event is not None
        await db.execute(
            """
            INSERT INTO calendar_events
                (id, title, start_time, all_day, read_only, overridden_event_id,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, 'Corrected school run', '2026-07-14T08:00:00Z', 0, 0,
                    ?, ?, ?, ?, ?)
            """,
            (
                override_id,
                source_event[0],
                adult_a_user["family_id"],
                now_text,
                now_text,
                adult_a_user["id"],
            ),
        )
        await db.commit()
    second = await sync_calendar_source(source_id, family_id=adult_a_user["family_id"])
    assert second["removed"] >= 1
    async with aiosqlite.connect(initialized_db) as db:
        source_deleted, override_deleted = await (
            await db.execute(
                """
                SELECT
                    (SELECT deleted_at FROM calendar_events WHERE id = ?),
                    (SELECT deleted_at FROM calendar_events WHERE id = ?)
                """,
                (source_event[0], override_id),
            )
        ).fetchone()
    assert source_deleted is not None
    assert override_deleted is not None


async def test_outbound_feed_rotation_revokes_old_url_and_excludes_imports(
    client, adult_a_headers, adult_a_user, initialized_db
):
    native = await client.post(
        "/api/calendar/",
        json={"title": "Family supper", "start_time": "2026-07-20T18:00:00Z"},
        headers=adult_a_headers,
    )
    assert native.status_code == 201
    recurring = await client.post(
        "/api/calendar/",
        json={
            "title": "Recurring school run",
            "start_time": "2026-07-22T09:00:00Z",
            "recurrence_rule": "FREQ=DAILY;COUNT=3",
        },
        headers=adult_a_headers,
    )
    assert recurring.status_code == 201
    cancelled = await client.post(
        f"/api/calendar/{recurring.json()['id']}/occurrences/delete",
        json={
            "scope": "only_this",
            "occurrence_start": "2026-07-23T09:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 204
    generated_id = "00000000-0000-0000-0000-00000000feed"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO calendar_events
                (id, title, start_time, all_day, read_only, source_term_date_id,
                 term_boundary, family_id, created_at, updated_at, created_by)
            VALUES (?, 'Wrong generated date', '2026-09-01', 1, 1, 'feed-term',
                    'first', ?, '2026-07-17T08:00:00Z',
                    '2026-07-17T08:00:00Z', 'term-calendar')
            """,
            (generated_id, adult_a_user["family_id"]),
        )
        await db.commit()
    corrected = await client.put(
        f"/api/calendar/{generated_id}",
        json={"title": "Correct generated date", "start_time": "2026-09-02"},
        headers=adult_a_headers,
    )
    assert corrected.status_code == 200

    first = await client.post("/api/calendar/feed/rotate", headers=adult_a_headers)
    assert first.status_code == 200
    first_url = first.json()["feed_url"].replace("https://test", "")
    download = await client.get(first_url)
    assert download.status_code == 200
    assert "text/calendar" in download.headers["content-type"]
    assert b"Family supper" in download.content
    assert b"Recurring school run" in download.content
    assert b"EXDATE:20260723T090000Z" in download.content
    assert b"Correct generated date" in download.content
    assert b"Wrong generated date" not in download.content

    second = await client.post("/api/calendar/feed/rotate", headers=adult_a_headers)
    assert second.status_code == 200
    assert (await client.get(first_url)).status_code == 404
    second_url = second.json()["feed_url"].replace("https://test", "")
    assert (await client.get(second_url)).status_code == 200

    revoked = await client.delete("/api/calendar/feed", headers=adult_a_headers)
    assert revoked.status_code == 204
    assert (await client.get(second_url)).status_code == 404
