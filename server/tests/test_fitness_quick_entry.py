"""Focused coverage for the calm Fitness actions surfaced on Today."""

import json
import uuid
from datetime import date, datetime, timedelta

import aiosqlite
import httpx
import pytest

from app.models.fitness_quick_entry import ViClassWindow
from app.services.fitness.quick_entry import (
    VI_CALENDAR_URL,
    _parse_vi_calendar,
    _vi_cache,
    _vi_windows,
    clear_vi_strength_cache,
    strength_availability,
    vi_schedule,
)
from app.services.facilities import FACILITY_ZONE


pytestmark = pytest.mark.asyncio


def _vi_response(*, day: date, status_code: int = 200) -> httpx.Response:
    provider_date = day.isoformat()
    payload = [
        {
            "object_id": 1,
            "object_type": "appointment",
            "text": "Small Group Personal Training",
            "start_time": f"{provider_date}T05:30:00.000Z",
            "end_time": f"{provider_date}T06:20:00.000Z",
            "data": {
                "service": "Small Group Personal Training",
                "service_description": "Vi = Strength.",
                "visits_remaining": 2,
                "waitlist": True,
            },
        },
        {
            "object_id": 2,
            "object_type": "appointment",
            "text": "Run community",
            "start_time": f"{provider_date}T07:30:00.000Z",
            "end_time": f"{provider_date}T08:20:00.000Z",
            "data": {"service": "Run community"},
        },
    ]
    request = httpx.Request("GET", VI_CALENDAR_URL)
    return httpx.Response(status_code, request=request, json=payload)


async def test_quick_entry_preferences_are_owner_scoped(
    client,
    adult_a_headers,
    adult_b_headers,
):
    default_response = await client.get(
        "/api/fitness/quick-entry-preferences",
        headers=adult_a_headers,
    )
    assert default_response.status_code == 200
    assert default_response.json() == {
        "meal_times": {
            "breakfast": "08:00",
            "lunch": "12:30",
            "dinner": "18:30",
        }
    }

    updated = await client.patch(
        "/api/fitness/quick-entry-preferences",
        headers=adult_a_headers,
        json={
            "meal_times": {
                "breakfast": "07:15",
                "lunch": "13:05",
                "dinner": "19:20",
            }
        },
    )
    assert updated.status_code == 200
    assert updated.json()["meal_times"]["dinner"] == "19:20"

    adult_b_response = await client.get(
        "/api/fitness/quick-entry-preferences",
        headers=adult_b_headers,
    )
    assert adult_b_response.status_code == 200
    assert adult_b_response.json()["meal_times"]["dinner"] == "18:30"


async def test_meal_times_must_be_chronological(client, adult_a_headers):
    response = await client.patch(
        "/api/fitness/quick-entry-preferences",
        headers=adult_a_headers,
        json={
            "meal_times": {
                "breakfast": "18:00",
                "lunch": "12:00",
                "dinner": "08:00",
            }
        },
    )
    assert response.status_code == 422


async def test_kat_uses_public_vi_strength_classes(adult_b_user, initialized_db):
    clear_vi_strength_cache()
    day = datetime.now(FACILITY_ZONE).date()

    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.host == "app.vitraininggym.co.uk"
        assert request.headers["referer"].startswith("https://app.vitraininggym.co.uk/a/booking/")
        return _vi_response(day=day)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as vi_client:
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            result = await strength_availability(
                db,
                user=adult_b_user,
                start=day,
                end=day,
                vi_client=vi_client,
            )

    assert result.provider == "vi_training"
    assert result.source_url == "https://www.vitraininggym.co.uk/class-schedule/"
    assert [(item.start, item.end) for item in result.days[0].windows] == [("06:30", "07:20")]
    assert result.days[0].windows[0].booking_url is not None


async def test_vi_schedule_returns_all_safe_classes_for_kat_but_not_dom(
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    day = datetime.now(FACILITY_ZONE).date()

    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.host == "app.vitraininggym.co.uk"
        assert request.url.path == "/api/v4/calendar"
        assert request.url.params["user_id"] == "undefined"
        assert request.url.params["q[public]"] == "true"
        assert "attendee" not in request.url.params
        return _vi_response(day=day)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as vi_client:
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            adult_b_result = await vi_schedule(
                db,
                user=adult_b_user,
                start=day,
                end=day,
                vi_client=vi_client,
            )
            adult_a_result = await vi_schedule(
                db,
                user=adult_a_user,
                start=day,
                end=day,
                vi_client=vi_client,
            )

    assert adult_b_result.relevant is True
    assert [(item.label, item.classification) for item in adult_b_result.days[0].classes] == [
        ("Small Group Personal Training", "strength"),
        ("Run community", "run"),
    ]
    assert adult_a_result.relevant is False
    assert adult_a_result.days == []


async def test_strength_range_dates_are_bounded_before_provider_egress(
    client,
    adult_b_headers,
    monkeypatch,
):
    from app.services.fitness import quick_entry

    provider_called = False

    async def unexpected_download(**_kwargs):
        nonlocal provider_called
        provider_called = True
        return {}

    monkeypatch.setattr(quick_entry, "_download_vi_calendar", unexpected_download)
    today = datetime.now(FACILITY_ZONE).date()
    cases = [
        (today - timedelta(days=2), today),
        (today, today + timedelta(days=31)),
        (today + timedelta(days=367), today + timedelta(days=367)),
    ]
    for start, end in cases:
        response = await client.get(
            "/api/fitness/strength-availability",
            params={"start": start.isoformat(), "end": end.isoformat()},
            headers=adult_b_headers,
        )
        assert response.status_code == 422
    assert provider_called is False


async def test_vi_parser_returns_only_bounded_sanitised_public_class_fields():
    day = datetime.now(FACILITY_ZONE).date() + timedelta(days=1)
    payload = []
    for index in range(55):
        start = datetime.combine(day, datetime.min.time(), tzinfo=FACILITY_ZONE) + timedelta(
            minutes=index * 10
        )
        payload.append(
            {
                "text": "Strength with Attendee Jane Doe",
                "start_time": start.isoformat(),
                "end_time": (start + timedelta(minutes=5)).isoformat(),
                "data": {
                    "service": "Strength session for Jane Doe",
                    "service_description": "Vi = Strength. jane@example.invalid",
                    "attendees": [{"name": "Jane Doe", "email": "jane@example.invalid"}],
                    "customer_name": "Jane Doe",
                    "visits_remaining": 1,
                },
            }
        )

    parsed = _parse_vi_calendar(payload, start=day, end=day)
    assert len(parsed[day]) == 40
    encoded = json.dumps([item.model_dump() for item in parsed[day]])
    assert "Jane Doe" not in encoded
    assert "jane@example.invalid" not in encoded
    assert {item.label for item in parsed[day]} == {"Strength class"}


async def test_vi_cache_has_age_count_and_failure_backoff_bounds(monkeypatch):
    from app.services.fitness import quick_entry

    clear_vi_strength_cache()
    today = datetime.now(FACILITY_ZONE).date()
    now = quick_entry.monotonic()
    for offset in range(70):
        day = today + timedelta(days=offset)
        _vi_cache[(day, day)] = (now + offset, {day: []})
    quick_entry._prune_vi_cache(now + 70)
    assert len(_vi_cache) == quick_entry._VI_CACHE_MAX_ENTRIES

    provider_calls = 0

    async def failing_download(**_kwargs):
        nonlocal provider_calls
        provider_calls += 1
        raise httpx.ConnectError("unavailable")

    clear_vi_strength_cache()
    monkeypatch.setattr(quick_entry, "_download_vi_calendar", failing_download)
    first = await _vi_windows(start=today, end=today)
    second = await _vi_windows(start=today, end=today)
    assert first == second == (None, False)
    assert provider_calls == 1


async def test_vi_cache_keeps_bounded_stale_fallback_after_freshness_expires(monkeypatch):
    from app.services.fitness import quick_entry

    clear_vi_strength_cache()
    today = datetime.now(FACILITY_ZONE).date()
    clock = [10_000.0]
    provider_calls = 0

    async def download(**_kwargs):
        nonlocal provider_calls
        provider_calls += 1
        if provider_calls == 1:
            return {today: []}
        raise httpx.ConnectError("unavailable")

    monkeypatch.setattr(quick_entry, "monotonic", lambda: clock[0])
    monkeypatch.setattr(quick_entry, "_download_vi_calendar", download)
    fresh = await _vi_windows(start=today, end=today)
    clock[0] += quick_entry._VI_CACHE_TTL_SECONDS + 1
    stale = await _vi_windows(start=today, end=today)

    assert fresh == ({today: []}, False)
    assert stale == ({today: []}, True)
    assert provider_calls == 2
    assert (today, today) in _vi_cache

    clock[0] = 10_000.0 + quick_entry._VI_CACHE_MAX_STALE_SECONDS + 1
    expired = await _vi_windows(start=today, end=today)
    assert expired == (None, False)
    assert provider_calls == 3
    assert (today, today) not in _vi_cache


async def test_latest_example_school_owner_controls_provider_without_leaking_other_adult_schedule(
    adult_a_user,
    adult_b_user,
    initialized_db,
    monkeypatch,
):
    from app.services.fitness import quick_entry

    today = datetime.now(FACILITY_ZONE).date()
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(
            """INSERT INTO facility_schedule_versions
               (id, title, source_document_id, personal_owner_user_id, valid_from,
                valid_to, source_sha256, day_count, family_id, created_at, updated_at,
                created_by)
               VALUES (?, ?, NULL, ?, ?, ?, ?, 1, ?, ?, ?, ?)""",
            (
                str(uuid.uuid4()),
                "Old Morgan timetable",
                adult_b_user["id"],
                today.isoformat(),
                (today + timedelta(days=30)).isoformat(),
                "a" * 64,
                adult_a_user["family_id"],
                "2026-08-01T00:00:00+00:00",
                "2026-08-01T00:00:00+00:00",
                adult_b_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO facility_schedule_versions
               (id, title, source_document_id, personal_owner_user_id, valid_from,
                valid_to, source_sha256, day_count, family_id, created_at, updated_at,
                created_by)
               VALUES (?, ?, NULL, ?, ?, ?, ?, 1, ?, ?, ?, ?)""",
            (
                str(uuid.uuid4()),
                "Current Alex timetable",
                adult_a_user["id"],
                today.isoformat(),
                (today + timedelta(days=7)).isoformat(),
                "b" * 64,
                adult_a_user["family_id"],
                "2026-08-10T00:00:00+00:00",
                "2026-08-10T00:00:00+00:00",
                adult_a_user["id"],
            ),
        )
        await db.commit()

        async def fake_vi(**_kwargs):
            return quick_entry.StrengthAvailabilityResponse(
                provider="vi_training",
                source_title="Vi Training Example School class timetable",
                days=[{"date": today, "covered": True, "windows": []}],
            )

        monkeypatch.setattr(quick_entry, "_vi_strength_availability", fake_vi)
        adult_b_result = await strength_availability(db, user=adult_b_user, start=today, end=today)
        adult_a_result = await strength_availability(db, user=adult_a_user, start=today, end=today)

    assert adult_b_result.provider == "vi_training"
    assert "Alex" not in adult_b_result.source_title
    assert adult_a_result.provider == "school_weights_room"


async def test_vi_booking_confirmation_is_exactly_once(
    client,
    adult_b_headers,
    monkeypatch,
    initialized_db,
):
    from app.services.fitness import quick_entry
    from app.models.fitness_quick_entry import ViClassWindow

    booking_day = datetime.now(FACILITY_ZONE).date() + timedelta(days=1)
    provider_calls = 0

    async def fake_vi_windows(**_kwargs):
        nonlocal provider_calls
        provider_calls += 1
        if provider_calls > 1:
            return ({booking_day: []}, False)
        return (
            {
                booking_day: [
                    ViClassWindow(
                        start="06:30",
                        end="07:20",
                        label="Small Group Personal Training",
                        classification="strength",
                        booking_url=quick_entry.VI_BOOKING_URL,
                    )
                ]
            },
            False,
        )

    monkeypatch.setattr(quick_entry, "_vi_windows", fake_vi_windows)
    booking_id = str(uuid.uuid4())
    body = {
        "id": booking_id,
        "provider": "vi_training",
        "date": booking_day.isoformat(),
        "start": "06:30",
        "end": "07:20",
        "label": "Small Group Personal Training",
        "client_id": booking_id,
        "client_timestamp": "2026-08-12T12:00:00Z",
    }
    first = await client.post(
        "/api/fitness/strength-bookings",
        headers=adult_b_headers,
        json=body,
    )
    replay = await client.post(
        "/api/fitness/strength-bookings",
        headers=adult_b_headers,
        json=body,
    )
    assert first.status_code == 201
    assert replay.status_code == 201
    assert first.json() == replay.json()
    assert first.json()["location"] == "Vi Training, Example School"
    assert provider_calls == 1

    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT title, family_member_ids FROM calendar_events WHERE id = ?",
                (booking_id,),
            )
        ).fetchone()
    assert row[0] == "Small Group Personal Training"
    assert json.loads(row[1]) == ["00000000-0000-0000-0000-000000000002"]


async def test_generic_vi_run_booking_is_exactly_once_and_matches_public_class(
    client,
    adult_b_headers,
    monkeypatch,
    initialized_db,
):
    from app.services.fitness import quick_entry

    day = datetime.now(FACILITY_ZONE).date() + timedelta(days=1)
    provider_calls = 0

    async def fake_vi_windows(**_kwargs):
        nonlocal provider_calls
        provider_calls += 1
        return (
            {
                day: [
                    ViClassWindow(
                        start="08:30",
                        end="09:20",
                        label="Run community",
                        classification="run",
                        booking_url=quick_entry.VI_BOOKING_URL,
                    )
                ]
            },
            False,
        )

    monkeypatch.setattr(quick_entry, "_vi_windows", fake_vi_windows)
    booking_id = str(uuid.uuid4())
    body = {
        "id": booking_id,
        "provider": "vi_training",
        "date": day.isoformat(),
        "start": "08:30",
        "end": "09:20",
        "label": "Run community",
        "classification": "run",
    }
    first = await client.post("/api/fitness/vi-bookings", headers=adult_b_headers, json=body)
    replay = await client.post("/api/fitness/vi-bookings", headers=adult_b_headers, json=body)
    assert first.status_code == replay.status_code == 201
    assert first.json() == replay.json()
    assert first.json()["classification"] == "run"
    assert provider_calls == 1

    changed_classification = await client.post(
        "/api/fitness/vi-bookings",
        headers=adult_b_headers,
        json={**body, "classification": "mobility"},
    )
    assert changed_classification.status_code == 409

    wrong_class = await client.post(
        "/api/fitness/vi-bookings",
        headers=adult_b_headers,
        json={**body, "id": str(uuid.uuid4()), "classification": "strength"},
    )
    wrong_label = await client.post(
        "/api/fitness/vi-bookings",
        headers=adult_b_headers,
        json={**body, "id": str(uuid.uuid4()), "label": "Jane's private run"},
    )
    assert wrong_class.status_code == wrong_label.status_code == 422

    async with aiosqlite.connect(initialized_db) as db:
        event = await (
            await db.execute(
                "SELECT title, description, created_by, family_member_ids "
                "FROM calendar_events WHERE id = ?",
                (booking_id,),
            )
        ).fetchone()
    encoded = json.dumps(event)
    assert event[0] == "Run community"
    assert event[2] == "00000000-0000-0000-0000-000000000002"
    assert json.loads(event[3]) == [event[2]]
    assert "attendee" not in encoded.casefold()
    assert "customer" not in encoded.casefold()


async def test_vi_booking_logical_receipt_survives_new_uuid_and_calendar_tombstone(
    client,
    adult_b_headers,
    adult_b_user,
    monkeypatch,
    initialized_db,
):
    from app.services.fitness import quick_entry

    day = datetime.now(FACILITY_ZONE).date() + timedelta(days=1)
    provider_calls = 0

    async def fake_vi_windows(**_kwargs):
        nonlocal provider_calls
        provider_calls += 1
        return (
            {
                day: [
                    ViClassWindow(
                        start="08:30",
                        end="09:20",
                        label="Run community",
                        classification="run",
                    )
                ]
            },
            False,
        )

    monkeypatch.setattr(quick_entry, "_vi_windows", fake_vi_windows)
    first_id = str(uuid.uuid4())
    retry_id = str(uuid.uuid4())
    body = {
        "id": first_id,
        "provider": "vi_training",
        "date": day.isoformat(),
        "start": "08:30",
        "end": "09:20",
        "label": "Run community",
        "classification": "run",
    }
    first = await client.post("/api/fitness/vi-bookings", headers=adult_b_headers, json=body)
    restarted_retry = await client.post(
        "/api/fitness/vi-bookings",
        headers=adult_b_headers,
        json={**body, "id": retry_id},
    )
    assert first.status_code == restarted_retry.status_code == 201
    assert restarted_retry.json() == first.json()
    assert restarted_retry.json()["event_id"] == first_id
    assert provider_calls == 1

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE calendar_events SET deleted_at = updated_at WHERE id = ?",
            (first_id,),
        )
        await db.commit()

    after_tombstone = await client.post(
        "/api/fitness/vi-bookings",
        headers=adult_b_headers,
        json={**body, "id": str(uuid.uuid4())},
    )
    assert after_tombstone.status_code == 201
    assert after_tombstone.json() == first.json()
    assert provider_calls == 1

    reused_alias = await client.post(
        "/api/fitness/vi-bookings",
        headers=adult_b_headers,
        json={**body, "id": retry_id, "classification": "mobility"},
    )
    assert reused_alias.status_code == 409

    async with aiosqlite.connect(initialized_db) as db:
        receipts = await (
            await db.execute(
                "SELECT is_canonical, event_id FROM fitness_vi_booking_receipts "
                "WHERE owner_user_id = ? ORDER BY is_canonical DESC, id",
                (adult_b_user["id"],),
            )
        ).fetchall()
    assert sum(row[0] for row in receipts) == 1
    assert len(receipts) == 3
    assert {row[1] for row in receipts} == {first_id}

    deleted = await client.delete("/api/auth/me", headers=adult_b_headers)
    assert deleted.status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        remaining = await (
            await db.execute(
                "SELECT COUNT(*) FROM fitness_vi_booking_receipts WHERE owner_user_id = ?",
                (adult_b_user["id"],),
            )
        ).fetchone()
    assert remaining[0] == 0


async def test_vi_booking_receipt_is_owner_scoped_even_for_same_logical_class(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    monkeypatch,
):
    from app.services.fitness import quick_entry

    day = datetime.now(FACILITY_ZONE).date() + timedelta(days=1)
    monkeypatch.setattr(quick_entry, "_uses_example_school_timetable", lambda *_args, **_kwargs: False)

    async def fake_vi_windows(**_kwargs):
        return (
            {
                day: [
                    ViClassWindow(
                        start="08:30",
                        end="09:20",
                        label="Run community",
                        classification="run",
                    )
                ]
            },
            False,
        )

    monkeypatch.setattr(quick_entry, "_vi_windows", fake_vi_windows)
    booking_id = str(uuid.uuid4())
    body = {
        "id": booking_id,
        "provider": "vi_training",
        "date": day.isoformat(),
        "start": "08:30",
        "end": "09:20",
        "label": "Run community",
        "classification": "run",
    }
    kat = await client.post("/api/fitness/vi-bookings", headers=adult_b_headers, json=body)
    adult_a_reused_id = await client.post(
        "/api/fitness/vi-bookings", headers=adult_a_headers, json=body
    )
    adult_a_new_id = await client.post(
        "/api/fitness/vi-bookings",
        headers=adult_a_headers,
        json={**body, "id": str(uuid.uuid4())},
    )
    assert kat.status_code == 201
    assert adult_a_reused_id.status_code == 409
    assert adult_a_new_id.status_code == 201, adult_a_new_id.text
    assert adult_a_new_id.json()["event_id"] != kat.json()["event_id"]


async def test_strength_booking_replay_conflicts_and_user_isolation(
    client,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
    initialized_db,
):
    from app.services.fitness import quick_entry
    from app.models.fitness_quick_entry import ViClassWindow

    today = datetime.now(FACILITY_ZONE).date() + timedelta(days=1)

    async def fake_vi_windows(**_kwargs):
        return (
            {
                today: [
                    ViClassWindow(
                        start="06:30",
                        end="07:20",
                        label="Small Group Personal Training",
                        classification="strength",
                    )
                ]
            },
            False,
        )

    monkeypatch.setattr(quick_entry, "_vi_windows", fake_vi_windows)
    booking_id = str(uuid.uuid4())
    body = {
        "id": booking_id,
        "provider": "vi_training",
        "date": today.isoformat(),
        "start": "06:30",
        "end": "07:20",
        "label": "Small Group Personal Training",
    }
    created = await client.post("/api/fitness/strength-bookings", headers=adult_b_headers, json=body)
    assert created.status_code == 201, created.text

    changed = await client.post(
        "/api/fitness/strength-bookings",
        headers=adult_b_headers,
        json={**body, "start": "06:40", "end": "07:30"},
    )
    assert changed.status_code == 409
    other_user = await client.post("/api/fitness/strength-bookings", headers=adult_a_headers, json=body)
    assert other_user.status_code in {409, 422}

    async with aiosqlite.connect(initialized_db) as db:
        owner = await (
            await db.execute(
                "SELECT created_by, family_member_ids FROM calendar_events WHERE id = ?",
                (booking_id,),
            )
        ).fetchone()
    assert owner[0] == "00000000-0000-0000-0000-000000000002"
    assert json.loads(owner[1]) == [owner[0]]


async def test_strength_booking_rejects_abusive_dates_before_provider_call(
    client,
    adult_b_headers,
    monkeypatch,
):
    from app.services.fitness import quick_entry

    provider_called = False

    async def unexpected_vi(**_kwargs):
        nonlocal provider_called
        provider_called = True
        return quick_entry.StrengthAvailabilityResponse(
            provider="vi_training",
            source_title="Vi Training Example School class timetable",
            days=[],
        )

    monkeypatch.setattr(quick_entry, "_vi_strength_availability", unexpected_vi)
    today = datetime.now(FACILITY_ZONE).date()
    for booking_day in (today - timedelta(days=2), today + timedelta(days=367)):
        response = await client.post(
            "/api/fitness/strength-bookings",
            headers=adult_b_headers,
            json={
                "id": str(uuid.uuid4()),
                "provider": "vi_training",
                "date": booking_day.isoformat(),
                "start": "06:30",
                "end": "07:20",
                "label": "Small Group Personal Training",
            },
        )
        assert response.status_code == 422
    assert provider_called is False
