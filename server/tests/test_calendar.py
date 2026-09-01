"""Tests for the calendar router (/api/calendar)."""

import aiosqlite


# ---------------------------------------------------------------------------
# Create event
# ---------------------------------------------------------------------------


async def test_create_event(client, adult_a_user, adult_a_headers):
    """POST /api/calendar creates a new calendar event."""
    payload = {
        "title": "School pickup",
        "description": "Collect kids from school",
        "start_time": "2026-02-10T15:00:00Z",
        "end_time": "2026-02-10T15:30:00Z",
        "all_day": False,
        "location": "Example School College",
    }
    resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["title"] == "School pickup"
    assert data["description"] == "Collect kids from school"
    assert data["start_time"] == "2026-02-10T15:00:00Z"
    assert data["end_time"] == "2026-02-10T15:30:00Z"
    assert data["all_day"] is False
    assert data["location"] == "Example School College"
    assert data["created_by"] == adult_a_user["id"]
    assert "id" in data
    assert "created_at" in data
    assert "updated_at" in data


async def test_event_supports_multiple_participants_and_an_affected_adult(
    client,
    adult_a_user,
    adult_b_user,
    child1,
    adult_a_headers,
):
    response = await client.post(
        "/api/calendar/",
        json={
            "title": "Doctor appointment",
            "start_time": "2026-07-15T10:00:00Z",
            "family_member_ids": [adult_b_user["id"], child1["id"]],
            "affected_member_ids": [adult_a_user["id"]],
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 201
    event = response.json()
    assert event["assigned_to"] is None
    assert event["family_member_ids"] == [adult_b_user["id"], child1["id"]]
    assert event["affected_member_ids"] == [adult_a_user["id"]]

    adult_a_events = await client.get(
        "/api/calendar/",
        params={"assigned_to": adult_a_user["id"]},
        headers=adult_a_headers,
    )
    assert event["id"] in {item["id"] for item in adult_a_events.json()}


async def test_affected_people_must_be_non_attending_adults_in_the_family(
    client,
    adult_a_user,
    adult_b_user,
    child1,
    adult_a_headers,
):
    base = {
        "title": "Appointment",
        "start_time": "2026-07-15T10:00:00Z",
        "family_member_ids": [adult_b_user["id"]],
    }
    child_response = await client.post(
        "/api/calendar/",
        json={**base, "affected_member_ids": [child1["id"]]},
        headers=adult_a_headers,
    )
    overlap_response = await client.post(
        "/api/calendar/",
        json={**base, "affected_member_ids": [adult_b_user["id"]]},
        headers=adult_a_headers,
    )
    whole_family_response = await client.post(
        "/api/calendar/",
        json={
            "title": "Family day",
            "start_time": "2026-07-15",
            "affected_member_ids": [adult_a_user["id"]],
        },
        headers=adult_a_headers,
    )

    assert child_response.status_code == 400
    assert child_response.json()["detail"] == "Affected person must be an adult in this family"
    assert overlap_response.status_code == 400
    assert (
        overlap_response.json()["detail"] == "An event participant cannot also be an affected adult"
    )
    assert whole_family_response.status_code == 400


# ---------------------------------------------------------------------------
# List events
# ---------------------------------------------------------------------------


async def test_list_events(client, adult_a_user, adult_a_headers):
    """GET /api/calendar returns events that have been created."""
    # Create an event first
    payload = {
        "title": "Dentist appointment",
        "start_time": "2026-02-11T09:00:00Z",
        "end_time": "2026-02-11T10:00:00Z",
    }
    create_resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    assert create_resp.status_code == 201

    # List events
    resp = await client.get("/api/calendar/", headers=adult_a_headers)
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 1
    titles = [e["title"] for e in data]
    assert "Dentist appointment" in titles


# ---------------------------------------------------------------------------
# List events with date range filter
# ---------------------------------------------------------------------------


async def test_list_events_date_range(client, adult_a_user, adult_a_headers):
    """GET /api/calendar?start=...&end=... filters by date range."""
    # Create events at different times
    event_feb = {
        "title": "February event",
        "start_time": "2026-02-15T10:00:00Z",
        "end_time": "2026-02-15T11:00:00Z",
    }
    event_mar = {
        "title": "March event",
        "start_time": "2026-03-15T10:00:00Z",
        "end_time": "2026-03-15T11:00:00Z",
    }
    await client.post("/api/calendar/", json=event_feb, headers=adult_a_headers)
    await client.post("/api/calendar/", json=event_mar, headers=adult_a_headers)

    # Filter to February only
    resp = await client.get(
        "/api/calendar/",
        params={"start": "2026-02-01T00:00:00Z", "end": "2026-02-28T23:59:59Z"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    titles = [e["title"] for e in data]
    assert "February event" in titles
    assert "March event" not in titles


async def test_multi_day_event_is_returned_for_every_overlapping_day(
    client,
    adult_a_headers,
):
    """A timed event spans each day before its exclusive midnight end."""
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Family trip",
            "start_time": "2026-07-10T18:00:00Z",
            "end_time": "2026-07-13T00:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    event_id = created.json()["id"]

    for day in ("2026-07-10", "2026-07-11", "2026-07-12"):
        response = await client.get(
            "/api/calendar/",
            params={"start": day, "end": day, "limit": 200},
            headers=adult_a_headers,
        )
        assert response.status_code == 200
        assert event_id in {event["id"] for event in response.json()}

    ended = await client.get(
        "/api/calendar/",
        params={"start": "2026-07-13", "end": "2026-07-13", "limit": 200},
        headers=adult_a_headers,
    )
    assert ended.status_code == 200
    assert event_id not in {event["id"] for event in ended.json()}


async def test_all_day_end_date_is_exclusive(client, adult_a_headers):
    """All-day end_time follows iCalendar DTEND (the first excluded date)."""
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Camping",
            "start_time": "2026-08-04",
            "end_time": "2026-08-07",
            "all_day": True,
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    event_id = created.json()["id"]

    visible = await client.get(
        "/api/calendar/",
        params={"start": "2026-08-04", "end": "2026-08-06", "limit": 200},
        headers=adult_a_headers,
    )
    assert visible.status_code == 200
    assert event_id in {event["id"] for event in visible.json()}

    ended = await client.get(
        "/api/calendar/",
        params={"start": "2026-08-07", "end": "2026-08-07", "limit": 200},
        headers=adult_a_headers,
    )
    assert ended.status_code == 200
    assert event_id not in {event["id"] for event in ended.json()}


async def test_zulu_ranges_include_no_end_all_day_event_across_western_boundary(
    client,
    adult_a_headers,
):
    """A west-of-UTC iOS boundary must not clip the first all-day event."""
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "School inset day",
            "start_time": "2026-09-07",
            "all_day": True,
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    event_id = created.json()["id"]

    ranges = (
        # Local midnight in a UTC-4 timezone, serialized by iOS as Zulu.
        ("2026-09-07T04:00:00Z", "2026-09-08T04:00:00Z"),
        ("2026-09-07T04:00:00Z", "2026-09-14T04:00:00Z"),
        # A partial-day consumer still sees an all-day event.
        ("2026-09-07T12:00:00Z", "2026-09-07T13:00:00Z"),
    )
    for start, end in ranges:
        response = await client.get(
            "/api/calendar/",
            params={"start": start, "end": end, "limit": 200},
            headers=adult_a_headers,
        )
        assert response.status_code == 200
        event = next(item for item in response.json() if item["id"] == event_id)
        assert event["end_time"] is None

    following_day = await client.get(
        "/api/calendar/",
        params={
            "start": "2026-09-08T04:00:00Z",
            "end": "2026-09-09T04:00:00Z",
            "limit": 200,
        },
        headers=adult_a_headers,
    )
    assert event_id not in {event["id"] for event in following_day.json()}


async def test_date_only_start_has_one_day_duration_without_all_day_flag(
    client,
    adult_a_headers,
):
    """Legacy date-only rows retain civil-day visibility even if all_day is false."""
    created = await client.post(
        "/api/calendar/",
        json={"title": "Legacy date event", "start_time": "2026-09-11"},
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    event_id = created.json()["id"]

    response = await client.get(
        "/api/calendar/",
        params={
            "start": "2026-09-11T15:00:00Z",
            "end": "2026-09-11T16:00:00Z",
            "limit": 200,
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    event = next(item for item in response.json() if item["id"] == event_id)
    assert event["all_day"] is False
    assert event["end_time"] is None


async def test_weekly_recurring_event_is_expanded_in_future_range(client, adult_a_headers):
    """A stored weekly RRULE produces a distinct occurrence in later planner weeks."""
    create_resp = await client.post(
        "/api/calendar/",
        json={
            "title": "Swimming lesson",
            "start_time": "2026-02-03T16:00:00Z",
            "end_time": "2026-02-03T17:00:00Z",
            "recurrence_rule": "FREQ=WEEKLY;BYDAY=TU",
        },
        headers=adult_a_headers,
    )
    assert create_resp.status_code == 201
    series_id = create_resp.json()["id"]

    response = await client.get(
        "/api/calendar/",
        params={
            "start": "2026-02-09T00:00:00Z",
            "end": "2026-02-15T23:59:59Z",
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    occurrences = [event for event in response.json() if event["title"] == "Swimming lesson"]
    assert len(occurrences) == 1
    assert occurrences[0]["start_time"] == "2026-02-10T16:00:00Z"
    assert occurrences[0]["end_time"] == "2026-02-10T17:00:00Z"
    assert occurrences[0]["series_id"] == series_id
    assert occurrences[0]["is_generated_occurrence"] is True
    assert occurrences[0]["id"] != series_id


async def test_recurring_multi_day_occurrence_overlaps_each_day(client, adult_a_headers):
    """A generated occurrence is returned after its start and before its end."""
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Two-night duty",
            "start_time": "2026-07-06T18:00:00Z",
            "end_time": "2026-07-08T00:00:00Z",
            "recurrence_rule": "FREQ=WEEKLY;BYDAY=MO",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    series_id = created.json()["id"]

    during = await client.get(
        "/api/calendar/",
        params={"start": "2026-07-14", "end": "2026-07-14", "limit": 200},
        headers=adult_a_headers,
    )
    occurrences = [event for event in during.json() if event.get("series_id") == series_id]
    assert len(occurrences) == 1
    assert occurrences[0]["start_time"] == "2026-07-13T18:00:00Z"
    assert occurrences[0]["end_time"] == "2026-07-15T00:00:00Z"

    ended = await client.get(
        "/api/calendar/",
        params={"start": "2026-07-15", "end": "2026-07-15", "limit": 200},
        headers=adult_a_headers,
    )
    assert series_id not in {event.get("series_id") for event in ended.json()}


async def test_daily_recurring_event_expansion_respects_limit(client, adult_a_headers):
    """Expanded series are paginated after occurrences are generated."""
    await client.post(
        "/api/calendar/",
        json={
            "title": "Daily reading",
            "start_time": "2026-04-01T18:00:00Z",
            "recurrence_rule": "FREQ=DAILY",
        },
        headers=adult_a_headers,
    )

    response = await client.get(
        "/api/calendar/",
        params={
            "start": "2026-04-01T00:00:00Z",
            "end": "2026-04-07T23:59:59Z",
            "limit": 3,
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    occurrences = [event for event in response.json() if event["title"] == "Daily reading"]
    assert len(occurrences) == 3
    assert len({event["id"] for event in occurrences}) == 3


async def test_all_day_recurrence_uses_civil_date_across_timezones(
    client,
    adult_a_headers,
):
    """All-day occurrence visibility and identity do not shift with UTC offset."""
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Daily holiday activity",
            "start_time": "2026-09-09",
            "all_day": True,
            "recurrence_rule": "FREQ=DAILY;COUNT=3",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    series_id = created.json()["id"]

    occurrence_ids = []
    ranges = (
        # Partial-day Zulu range requires the implicit all-day duration.
        ("2026-09-10T12:00:00Z", "2026-09-10T13:00:00Z"),
        ("2026-09-10T00:00:00+01:00", "2026-09-10T23:59:59+01:00"),
    )
    for start, end in ranges:
        response = await client.get(
            "/api/calendar/",
            params={
                "start": start,
                "end": end,
                "limit": 200,
            },
            headers=adult_a_headers,
        )
        assert response.status_code == 200
        occurrence = next(event for event in response.json() if event.get("series_id") == series_id)
        assert occurrence["start_time"] == "2026-09-10"
        assert occurrence["end_time"] is None
        occurrence_ids.append(occurrence["id"])

    assert occurrence_ids == [f"{series_id}::2026-09-10"] * 2


async def test_edit_only_this_recurring_occurrence_creates_one_isolated_event(
    client,
    initialized_db,
    adult_a_headers,
):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "School run",
            "start_time": "2026-10-01T09:00:00Z",
            "end_time": "2026-10-01T09:30:00Z",
            "recurrence_rule": "FREQ=DAILY;COUNT=4",
        },
        headers=adult_a_headers,
    )
    series_id = created.json()["id"]

    edited = await client.patch(
        f"/api/calendar/{series_id}/occurrences",
        json={
            "scope": "only_this",
            "occurrence_start": "2026-10-02T09:00:00Z",
            "updates": {
                "title": "Late school run",
                "start_time": "2026-10-02T10:00:00Z",
                "end_time": "2026-10-02T10:30:00Z",
                "all_day": False,
            },
        },
        headers=adult_a_headers,
    )

    assert edited.status_code == 200
    assert edited.json()["series_id"] is None
    assert edited.json()["recurrence_rule"] is None
    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-10-01", "end": "2026-10-05", "limit": 200},
        headers=adult_a_headers,
    )
    school_runs = [event for event in listed.json() if "school run" in event["title"].lower()]
    assert [(event["title"], event["start_time"]) for event in school_runs] == [
        ("School run", "2026-10-01T09:00:00Z"),
        ("Late school run", "2026-10-02T10:00:00Z"),
        ("School run", "2026-10-03T09:00:00Z"),
        ("School run", "2026-10-04T09:00:00Z"),
    ]

    async with aiosqlite.connect(initialized_db) as db:
        exception = await (
            await db.execute(
                "SELECT action, occurrence_start, replacement_event_id "
                "FROM calendar_event_exceptions WHERE series_id = ? AND deleted_at IS NULL",
                (series_id,),
            )
        ).fetchone()
    assert exception == (
        "replacement",
        "2026-10-02T09:00:00+00:00",
        edited.json()["id"],
    )


async def test_delete_only_this_recurring_occurrence_keeps_the_rest(client, adult_a_headers):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Library day",
            "start_time": "2026-10-01",
            "all_day": True,
            "recurrence_rule": "FREQ=WEEKLY;COUNT=3",
        },
        headers=adult_a_headers,
    )
    series_id = created.json()["id"]

    deleted = await client.post(
        f"/api/calendar/{series_id}/occurrences/delete",
        json={
            "scope": "only_this",
            "occurrence_start": "2026-10-08",
        },
        headers=adult_a_headers,
    )

    assert deleted.status_code == 204
    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-10-01", "end": "2026-10-20", "limit": 200},
        headers=adult_a_headers,
    )
    occurrences = [event for event in listed.json() if event.get("series_id") == series_id]
    assert [event["start_time"] for event in occurrences] == ["2026-10-01", "2026-10-15"]


async def test_edit_this_and_later_splits_series_and_preserves_total_count(
    client,
    initialized_db,
    adult_a_headers,
):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Piano practice",
            "start_time": "2026-10-01T09:00:00Z",
            "end_time": "2026-10-01T09:30:00Z",
            "recurrence_rule": "FREQ=DAILY;COUNT=5",
        },
        headers=adult_a_headers,
    )
    original_id = created.json()["id"]

    edited = await client.patch(
        f"/api/calendar/{original_id}/occurrences",
        json={
            "scope": "this_and_later",
            "occurrence_start": "2026-10-03T09:00:00Z",
            "updates": {
                "title": "Later piano practice",
                "start_time": "2026-10-03T10:00:00Z",
                "end_time": "2026-10-03T10:30:00Z",
                "all_day": False,
            },
        },
        headers=adult_a_headers,
    )

    assert edited.status_code == 200
    suffix_id = edited.json()["id"]
    assert suffix_id != original_id
    assert edited.json()["recurrence_rule"] == "FREQ=DAILY;COUNT=3"
    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-10-01", "end": "2026-10-07", "limit": 200},
        headers=adult_a_headers,
    )
    practices = [event for event in listed.json() if "piano practice" in event["title"].lower()]
    assert [(event["title"], event["start_time"]) for event in practices] == [
        ("Piano practice", "2026-10-01T09:00:00Z"),
        ("Piano practice", "2026-10-02T09:00:00Z"),
        ("Later piano practice", "2026-10-03T10:00:00Z"),
        ("Later piano practice", "2026-10-04T10:00:00Z"),
        ("Later piano practice", "2026-10-05T10:00:00Z"),
    ]

    async with aiosqlite.connect(initialized_db) as db:
        prefix_rule = (
            await (
                await db.execute(
                    "SELECT recurrence_rule FROM calendar_events WHERE id = ?",
                    (original_id,),
                )
            ).fetchone()
        )[0]
    assert "UNTIL=20261003T085959Z" in prefix_rule


async def test_delete_this_and_later_truncates_before_selected_occurrence(
    client,
    adult_a_headers,
):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Daily check-in",
            "start_time": "2026-10-01",
            "all_day": True,
            "recurrence_rule": "FREQ=DAILY;COUNT=5",
        },
        headers=adult_a_headers,
    )
    series_id = created.json()["id"]

    deleted = await client.post(
        f"/api/calendar/{series_id}/occurrences/delete",
        json={
            "scope": "this_and_later",
            "occurrence_start": "2026-10-03",
        },
        headers=adult_a_headers,
    )

    assert deleted.status_code == 204
    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-10-01", "end": "2026-10-07", "limit": 200},
        headers=adult_a_headers,
    )
    occurrences = [event for event in listed.json() if event.get("series_id") == series_id]
    assert [event["start_time"] for event in occurrences] == ["2026-10-01", "2026-10-02"]


async def test_edit_entire_series_translates_selected_time_back_to_series_anchor(
    client,
    adult_a_headers,
):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Morning walk",
            "start_time": "2026-10-01T09:00:00Z",
            "end_time": "2026-10-01T09:30:00Z",
            "recurrence_rule": "FREQ=DAILY;COUNT=3",
        },
        headers=adult_a_headers,
    )
    series_id = created.json()["id"]

    edited = await client.patch(
        f"/api/calendar/{series_id}/occurrences",
        json={
            "scope": "entire_series",
            "occurrence_start": "2026-10-02T09:00:00Z",
            "updates": {
                "title": "Long morning walk",
                "start_time": "2026-10-02T11:00:00Z",
                "end_time": "2026-10-02T12:00:00Z",
                "all_day": False,
            },
        },
        headers=adult_a_headers,
    )

    assert edited.status_code == 200
    assert edited.json()["id"] == series_id
    assert edited.json()["start_time"] == "2026-10-01T11:00:00Z"
    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-10-01", "end": "2026-10-04", "limit": 200},
        headers=adult_a_headers,
    )
    occurrences = [event for event in listed.json() if event.get("series_id") == series_id]
    assert [event["start_time"] for event in occurrences] == [
        "2026-10-01T11:00:00Z",
        "2026-10-02T11:00:00Z",
        "2026-10-03T11:00:00Z",
    ]
    assert {event["title"] for event in occurrences} == {"Long morning walk"}

    end_only = await client.patch(
        f"/api/calendar/{series_id}/occurrences",
        json={
            "scope": "entire_series",
            "occurrence_start": "2026-10-02T11:00:00Z",
            "updates": {"end_time": "2026-10-02T13:00:00Z"},
        },
        headers=adult_a_headers,
    )
    assert end_only.status_code == 200
    assert end_only.json()["end_time"] == "2026-10-01T13:00:00Z"


async def test_moving_entire_weekly_series_moves_its_weekday_constraint(
    client,
    adult_a_headers,
):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Swimming",
            "start_time": "2026-10-06T16:00:00Z",
            "end_time": "2026-10-06T17:00:00Z",
            "recurrence_rule": "FREQ=WEEKLY;BYDAY=TU;COUNT=3",
        },
        headers=adult_a_headers,
    )
    series_id = created.json()["id"]

    edited = await client.patch(
        f"/api/calendar/{series_id}/occurrences",
        json={
            "scope": "entire_series",
            "occurrence_start": "2026-10-13T16:00:00Z",
            "updates": {
                "start_time": "2026-10-14T16:00:00Z",
                "end_time": "2026-10-14T17:00:00Z",
                "all_day": False,
            },
        },
        headers=adult_a_headers,
    )

    assert edited.status_code == 200
    assert edited.json()["start_time"] == "2026-10-07T16:00:00Z"
    assert edited.json()["recurrence_rule"] == "FREQ=WEEKLY;BYDAY=WE;COUNT=3"
    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-10-01", "end": "2026-10-31", "limit": 200},
        headers=adult_a_headers,
    )
    occurrences = [event for event in listed.json() if event.get("series_id") == series_id]
    assert [event["start_time"] for event in occurrences] == [
        "2026-10-07T16:00:00Z",
        "2026-10-14T16:00:00Z",
        "2026-10-21T16:00:00Z",
    ]


async def test_delete_entire_series_also_retires_isolated_replacements(
    client,
    initialized_db,
    adult_a_headers,
):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Dog walk",
            "start_time": "2026-10-01T09:00:00Z",
            "recurrence_rule": "FREQ=DAILY;COUNT=3",
        },
        headers=adult_a_headers,
    )
    series_id = created.json()["id"]
    isolated = await client.patch(
        f"/api/calendar/{series_id}/occurrences",
        json={
            "scope": "only_this",
            "occurrence_start": "2026-10-02T09:00:00Z",
            "updates": {"title": "Morgan dog walk"},
        },
        headers=adult_a_headers,
    )
    replacement_id = isolated.json()["id"]

    deleted = await client.post(
        f"/api/calendar/{series_id}/occurrences/delete",
        json={
            "scope": "entire_series",
            "occurrence_start": "2026-10-03T09:00:00Z",
        },
        headers=adult_a_headers,
    )

    assert deleted.status_code == 204
    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-10-01", "end": "2026-10-04", "limit": 200},
        headers=adult_a_headers,
    )
    assert not [event for event in listed.json() if "dog walk" in event["title"].lower()]
    async with aiosqlite.connect(initialized_db) as db:
        parent_deleted = (
            await (await db.execute("SELECT deleted_at FROM calendar_events WHERE id = ?", (series_id,))).fetchone()
        )[0]
        replacement_deleted = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM calendar_events WHERE id = ?",
                    (replacement_id,),
                )
            ).fetchone()
        )[0]
        exception_deleted = (
            await (
                await db.execute(
                    "SELECT deleted_at FROM calendar_event_exceptions WHERE series_id = ?",
                    (series_id,),
                )
            ).fetchone()
        )[0]
    assert parent_deleted is not None
    assert replacement_deleted is not None
    assert exception_deleted is not None


async def test_timestamp_range_end_must_be_after_start(client, adult_a_headers):
    response = await client.get(
        "/api/calendar/",
        params={
            "start": "2026-09-10T12:00:00Z",
            "end": "2026-09-10T12:00:00Z",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Calendar end must be after start"


# ---------------------------------------------------------------------------
# Update event
# ---------------------------------------------------------------------------


async def test_update_event(client, adult_a_user, adult_a_headers):
    """PUT /api/calendar/{id} updates an existing event."""
    # Create
    payload = {
        "title": "Original title",
        "start_time": "2026-02-12T14:00:00Z",
        "end_time": "2026-02-12T15:00:00Z",
    }
    create_resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    event_id = create_resp.json()["id"]

    # Update
    update_resp = await client.put(
        f"/api/calendar/{event_id}",
        json={"title": "Updated title", "location": "Home"},
        headers=adult_a_headers,
    )
    assert update_resp.status_code == 200
    data = update_resp.json()
    assert data["title"] == "Updated title"
    assert data["location"] == "Home"
    # Unchanged fields should remain
    assert data["start_time"] == "2026-02-12T14:00:00Z"


async def test_update_read_only_event_creates_stable_editable_override(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    """Editing imported/generated data must never mutate its source row."""
    source_id = "00000000-0000-0000-0000-00000000a001"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO calendar_events
                (id, title, description, start_time, end_time, all_day,
                 event_type, read_only, source_term_date_id, term_boundary,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, 'Wrong term date', 'Automatically generated', '2026-09-03',
                    '2026-09-04', 1, 'school', 1, 'source-term', 'first', ?,
                    '2026-07-17T08:00:00Z', '2026-07-17T08:00:00Z', 'term-calendar')
            """,
            (source_id, adult_a_user["family_id"]),
        )
        await db.commit()

    first_edit = await client.put(
        f"/api/calendar/{source_id}",
        json={"title": "Correct term date", "start_time": "2026-09-07", "end_time": "2026-09-08"},
        headers=adult_a_headers,
    )

    assert first_edit.status_code == 200
    override = first_edit.json()
    assert override["id"] != source_id
    assert override["read_only"] is False
    assert override["overridden_event_id"] == source_id
    assert override["title"] == "Correct term date"
    assert override["start_time"] == "2026-09-07"

    # A stale client editing the original ID reuses the same override.
    second_edit = await client.put(
        f"/api/calendar/{source_id}",
        json={"location": "School gate"},
        headers=adult_a_headers,
    )
    assert second_edit.status_code == 200
    assert second_edit.json()["id"] == override["id"]
    assert second_edit.json()["location"] == "School gate"

    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-09-01", "end": "2026-09-10", "limit": 200},
        headers=adult_a_headers,
    )
    listed_ids = {event["id"] for event in listed.json()}
    assert override["id"] in listed_ids
    assert source_id not in listed_ids

    async with aiosqlite.connect(initialized_db) as db:
        source = await (
            await db.execute(
                "SELECT title, start_time, read_only, deleted_at FROM calendar_events WHERE id = ?",
                (source_id,),
            )
        ).fetchone()
    assert source == ("Wrong term date", "2026-09-03", 1, None)


async def test_deleting_override_reveals_unchanged_source_event(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    source_id = "00000000-0000-0000-0000-00000000a002"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO calendar_events
                (id, title, start_time, all_day, read_only, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, 'Imported inset day', '2026-10-02', 1, 1, ?,
                    '2026-07-17T08:00:00Z', '2026-07-17T08:00:00Z', 'calendar-sync')
            """,
            (source_id, adult_a_user["family_id"]),
        )
        await db.commit()

    edited = await client.put(
        f"/api/calendar/{source_id}",
        json={"title": "Corrected inset day"},
        headers=adult_a_headers,
    )
    override_id = edited.json()["id"]
    deleted = await client.delete(f"/api/calendar/{override_id}", headers=adult_a_headers)
    assert deleted.status_code == 204

    listed = await client.get(
        "/api/calendar/",
        params={"start": "2026-10-02", "end": "2026-10-02", "limit": 200},
        headers=adult_a_headers,
    )
    assert {event["id"] for event in listed.json()} >= {source_id}


async def test_update_event_rejects_end_before_start(client, adult_a_headers):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Appointment",
            "start_time": "2026-09-02T10:00:00Z",
            "end_time": "2026-09-02T10:15:00Z",
        },
        headers=adult_a_headers,
    )

    response = await client.put(
        f"/api/calendar/{created.json()['id']}",
        json={"end_time": "2026-09-02T09:45:00Z"},
        headers=adult_a_headers,
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Calendar end time must be after start time"


# ---------------------------------------------------------------------------
# Delete event (soft delete)
# ---------------------------------------------------------------------------


async def test_delete_event(client, adult_a_user, adult_a_headers):
    """DELETE /api/calendar/{id} soft-deletes the event (204). It should not appear in GET."""
    # Create
    payload = {
        "title": "To be deleted",
        "start_time": "2026-02-13T08:00:00Z",
        "end_time": "2026-02-13T09:00:00Z",
    }
    create_resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    event_id = create_resp.json()["id"]

    # Delete
    del_resp = await client.delete(f"/api/calendar/{event_id}", headers=adult_a_headers)
    assert del_resp.status_code == 204

    # Verify it no longer appears in GET
    list_resp = await client.get("/api/calendar/", headers=adult_a_headers)
    ids = [e["id"] for e in list_resp.json()]
    assert event_id not in ids


# ---------------------------------------------------------------------------
# Auth required
# ---------------------------------------------------------------------------


async def test_create_event_no_auth(client):
    """POST /api/calendar without auth returns 401 or 403."""
    payload = {
        "title": "Unauthorized event",
        "start_time": "2026-02-14T12:00:00Z",
        "end_time": "2026-02-14T13:00:00Z",
    }
    resp = await client.post("/api/calendar/", json=payload)
    assert resp.status_code in (401, 403)


# ---------------------------------------------------------------------------
# assigned_to field
# ---------------------------------------------------------------------------


async def test_create_event_with_assigned_to(client, adult_a_user, adult_a_headers, child1):
    """POST /api/calendar with assigned_to returns it in the response."""
    member_uuid = child1["id"]
    payload = {
        "title": "Pick up dry cleaning",
        "start_time": "2026-02-15T09:00:00Z",
        "end_time": "2026-02-15T09:30:00Z",
        "assigned_to": member_uuid,
    }
    resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["title"] == "Pick up dry cleaning"
    assert data["assigned_to"] == member_uuid


async def test_create_event_without_assigned_to(client, adult_a_user, adult_a_headers):
    """POST /api/calendar without assigned_to returns it as null."""
    payload = {
        "title": "Team meeting",
        "start_time": "2026-02-16T14:00:00Z",
        "end_time": "2026-02-16T15:00:00Z",
    }
    resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["title"] == "Team meeting"
    assert data["assigned_to"] is None


# ---------------------------------------------------------------------------
# All-day event (no end_time)
# ---------------------------------------------------------------------------


async def test_create_all_day_event_no_end_time(client, adult_a_user, adult_a_headers):
    """POST /api/calendar with all_day=true and no end_time succeeds."""
    payload = {
        "title": "Half-term holiday",
        "start_time": "2026-02-16",
        "all_day": True,
    }
    resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["title"] == "Half-term holiday"
    assert data["start_time"] == "2026-02-16"
    assert data["end_time"] is None
    assert data["all_day"] is True


# ---------------------------------------------------------------------------
# Start-time only event (no end_time, not all-day)
# ---------------------------------------------------------------------------


async def test_create_event_start_time_only(client, adult_a_user, adult_a_headers):
    """POST /api/calendar with start_time only (no end_time, all_day=false)."""
    payload = {
        "title": "Quick reminder",
        "start_time": "2026-02-18T09:30:00Z",
    }
    resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    assert resp.status_code == 201
    data = resp.json()
    assert data["title"] == "Quick reminder"
    assert data["start_time"] == "2026-02-18T09:30:00Z"
    assert data["end_time"] is None
    assert data["all_day"] is False


async def test_create_event_rejects_zero_duration(client, adult_a_headers):
    response = await client.post(
        "/api/calendar/",
        json={
            "title": "Zero duration",
            "start_time": "2026-09-08T10:00:00Z",
            "end_time": "2026-09-08T10:00:00Z",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Calendar end time must be after start time"


# ---------------------------------------------------------------------------
# List filter works with null end_time
# ---------------------------------------------------------------------------


async def test_list_events_includes_null_end_time(client, adult_a_user, adult_a_headers):
    """GET /api/calendar?start=...&end=... includes events with null end_time."""
    # Create an all-day event in March with no end_time
    payload = {
        "title": "March all-day",
        "start_time": "2026-03-05",
        "all_day": True,
    }
    await client.post("/api/calendar/", json=payload, headers=adult_a_headers)

    # Filter to March — event should appear
    resp = await client.get(
        "/api/calendar/",
        params={"start": "2026-03-01", "end": "2026-03-31"},
        headers=adult_a_headers,
    )
    assert resp.status_code == 200
    titles = [e["title"] for e in resp.json()]
    assert "March all-day" in titles


async def test_update_event_assigned_to_set_then_clear(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
):
    """PUT /api/calendar/{id} can set assigned_to, then clear it to null."""
    member_uuid = child1["id"]

    # Create event without assigned_to
    payload = {
        "title": "Grocery shopping",
        "start_time": "2026-02-17T10:00:00Z",
        "end_time": "2026-02-17T11:00:00Z",
    }
    create_resp = await client.post("/api/calendar/", json=payload, headers=adult_a_headers)
    assert create_resp.status_code == 201
    event_id = create_resp.json()["id"]
    assert create_resp.json()["assigned_to"] is None

    # Update to set assigned_to
    set_resp = await client.put(
        f"/api/calendar/{event_id}",
        json={"assigned_to": member_uuid},
        headers=adult_a_headers,
    )
    assert set_resp.status_code == 200
    assert set_resp.json()["assigned_to"] == member_uuid

    # Update to clear assigned_to
    clear_resp = await client.put(
        f"/api/calendar/{event_id}",
        json={"assigned_to": None},
        headers=adult_a_headers,
    )
    assert clear_resp.status_code == 200
    assert clear_resp.json()["assigned_to"] is None


async def test_create_event_rejects_high_frequency_recurrence(client, adult_a_headers):
    """Second-level recurrence must never reach the range expansion path."""
    response = await client.post(
        "/api/calendar/",
        json={
            "title": "Too frequent",
            "start_time": "2026-02-17T10:00:00Z",
            "recurrence_rule": "FREQ=SECONDLY;INTERVAL=1",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 422


async def test_list_events_rejects_range_over_400_days(client, adult_a_headers):
    """Authenticated callers cannot request unbounded recurrence expansion."""
    response = await client.get(
        "/api/calendar/",
        params={"start": "2026-01-01", "end": "2027-02-06"},
        headers=adult_a_headers,
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Calendar range cannot exceed 400 days"


async def test_list_events_accepts_later_range_pages(client, adult_a_headers):
    """Calendar clients can page through the full bounded occurrence result."""
    response = await client.get(
        "/api/calendar/",
        params={
            "start": "2026-08-01T00:00:00Z",
            "end": "2026-09-12T00:00:00Z",
            "offset": 400,
            "limit": 200,
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json() == []
