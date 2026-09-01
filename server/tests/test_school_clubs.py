"""First-class school club schedules and Calendar projections."""

import aiosqlite


async def _term(client, headers, child_id: str):
    response = await client.post(
        "/api/routines/terms",
        json={
            "person_id": child_id,
            "label": "Autumn Term 1",
            "start_date": "2026-09-03",
            "end_date": "2026-10-23",
        },
        headers=headers,
    )
    assert response.status_code == 201, response.text


async def _club(client, headers, child_id: str, **overrides):
    body = {
        "name": "Football",
        "child_id": child_id,
        "weekday": 2,
        "start_time": "16:00",
        "end_time": "16:45",
        "active_from": "2026-09-01",
        "client_id": "ios:football",
        "client_timestamp": "2026-08-13T09:00:00Z",
    }
    body.update(overrides)
    response = await client.post("/api/clubs/", json=body, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


async def test_club_is_entered_once_and_projected_only_in_child_term(
    client, child1, adult_a_headers
):
    await _term(client, adult_a_headers, child1["id"])
    club = await _club(client, adult_a_headers, child1["id"])
    assert club["child_name"] == "Child 1"
    assert club["weekday"] == 2

    calendar = await client.get(
        "/api/calendar/?start=2026-09-07&end=2026-09-14&limit=200",
        headers=adult_a_headers,
    )
    assert calendar.status_code == 200, calendar.text
    projected = [item for item in calendar.json() if item["event_type"] == "school_club"]
    assert len(projected) == 1
    assert projected[0]["title"] == "Football"
    assert projected[0]["start_time"] == "2026-09-09T16:00:00+01:00"
    assert projected[0]["end_time"] == "2026-09-09T16:45:00+01:00"
    assert projected[0]["family_member_ids"] == [child1["id"]]
    assert projected[0]["read_only"] is True
    assert projected[0]["managed_source"]["kind"] == "school_club"

    half_term = await client.get(
        "/api/calendar/?start=2026-10-26&end=2026-10-30&limit=200",
        headers=adult_a_headers,
    )
    assert not any(item["event_type"].startswith("school_club") for item in half_term.json())


async def test_cancelled_club_stays_visible_and_can_be_restored(
    client, child1, adult_a_headers
):
    await _term(client, adult_a_headers, child1["id"])
    club = await _club(client, adult_a_headers, child1["id"])
    cancelled = await client.put(
        f"/api/clubs/{club['id']}/dates/2026-09-09/cancel",
        json={"client_id": "web:cancel", "client_timestamp": "2026-09-08T17:00:00Z"},
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 200, cancelled.text
    assert cancelled.json()["cancelled"] is True

    calendar = (
        await client.get(
            "/api/calendar/?start=2026-09-09&end=2026-09-10&limit=200",
            headers=adult_a_headers,
        )
    ).json()
    event = next(item for item in calendar if item["event_type"] == "school_club_cancelled")
    assert event["title"] == "Football cancelled"

    restored = await client.delete(
        f"/api/clubs/{club['id']}/dates/2026-09-09/cancel",
        headers=adult_a_headers,
    )
    assert restored.status_code == 200, restored.text
    assert restored.json()["cancelled"] is False
    calendar = (
        await client.get(
            "/api/calendar/?start=2026-09-09&end=2026-09-10&limit=200",
            headers=adult_a_headers,
        )
    ).json()
    assert any(item["event_type"] == "school_club" for item in calendar)


async def test_clubs_are_family_scoped(
    client,
    child1,
    adult_a_headers,
    other_family_user,
    other_family_headers,
):
    await _term(client, adult_a_headers, child1["id"])
    club = await _club(client, adult_a_headers, child1["id"])
    assert (await client.get("/api/clubs/", headers=other_family_headers)).json() == []
    response = await client.put(
        f"/api/clubs/{club['id']}",
        json={"end_time": "17:00"},
        headers=other_family_headers,
    )
    assert response.status_code == 404


async def test_kat_wins_a_recent_club_schedule_conflict(
    client, child1, adult_a_headers, adult_b_headers
):
    await _term(client, adult_a_headers, child1["id"])
    club = await _club(
        client,
        adult_b_headers,
        child1["id"],
        client_timestamp="2026-08-13T09:01:00Z",
    )
    adult_a_change = await client.put(
        f"/api/clubs/{club['id']}",
        json={"end_time": "17:00", "client_timestamp": "2026-08-13T09:02:00Z"},
        headers=adult_a_headers,
    )
    assert adult_a_change.status_code == 200, adult_a_change.text
    assert adult_a_change.json()["end_time"] == "16:45"


async def test_deleting_club_is_a_soft_delete(
    client, child1, adult_a_headers, initialized_db
):
    await _term(client, adult_a_headers, child1["id"])
    club = await _club(client, adult_a_headers, child1["id"])
    response = await client.delete(f"/api/clubs/{club['id']}", headers=adult_a_headers)
    assert response.status_code == 204
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute("SELECT deleted_at FROM school_clubs WHERE id = ?", (club["id"],))
        ).fetchone()
    assert row is not None and row[0] is not None
