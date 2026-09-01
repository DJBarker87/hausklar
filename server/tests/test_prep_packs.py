"""Event Prep Packs: matching, confirmation, customization and deduplication."""

from datetime import date

import aiosqlite


async def _event(client, headers, *, title="Swimming lesson", start=None, recurrence=None):
    response = await client.post(
        "/api/calendar/",
        headers=headers,
        json={
            "title": title,
            "start_time": start or date.today().isoformat(),
            "all_day": True,
            "recurrence_rule": recurrence,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _action(suggestion: dict, **overrides) -> dict:
    value = {
        "template_id": suggestion["template_id"],
        "event_id": suggestion["event_id"],
        "occurrence_start": suggestion["occurrence_start"],
        "timezone": "Europe/London",
    }
    value.update(overrides)
    return value


async def test_defaults_match_event_and_apply_exactly_once(
    client, adult_a_headers, adult_a_user, initialized_db
):
    event = await _event(client, adult_a_headers)
    templates = await client.get("/api/prep-packs/templates", headers=adult_a_headers)
    assert templates.status_code == 200
    swimming = next(item for item in templates.json() if item["name"] == "Swimming")
    assert swimming["items"] == ["Pack swim kit", "Pack goggles", "Pack towels"]

    response = await client.get("/api/prep-packs/suggestions", headers=adult_a_headers)
    assert response.status_code == 200
    suggestion = response.json()[0]
    assert suggestion["event_id"] == event["id"]
    assert suggestion["event_title"] == "Swimming lesson"
    assert suggestion["items"] == swimming["items"]

    first = await client.post(
        "/api/prep-packs/apply", headers=adult_a_headers, json=_action(suggestion)
    )
    assert first.status_code == 200, first.text
    assert first.json()["task_count"] == 3
    replay = await client.post(
        "/api/prep-packs/apply", headers=adult_a_headers, json=_action(suggestion)
    )
    assert replay.status_code == 200
    assert replay.json()["task_ids"] == first.json()["task_ids"]

    assert (await client.get("/api/prep-packs/suggestions", headers=adult_a_headers)).json() == []
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        tasks = await (
            await db.execute(
                "SELECT title, due_date, source_event_id, prep_occurrence_id "
                "FROM tasks WHERE source_event_id = ? ORDER BY title",
                (event["id"],),
            )
        ).fetchall()
    assert len(tasks) == 3
    assert {row["title"] for row in tasks} == set(swimming["items"])
    assert all(row["source_event_id"] == event["id"] for row in tasks)
    assert len({row["prep_occurrence_id"] for row in tasks}) == 1


async def test_pack_can_assign_all_created_tasks(
    client, adult_a_headers, adult_b_user, initialized_db
):
    await _event(client, adult_a_headers)
    suggestion = (await client.get("/api/prep-packs/suggestions", headers=adult_a_headers)).json()[0]
    applied = await client.post(
        "/api/prep-packs/apply",
        headers=adult_a_headers,
        json=_action(suggestion, assigned_to=adult_b_user["id"]),
    )
    assert applied.status_code == 200
    async with aiosqlite.connect(initialized_db) as db:
        assignments = await (
            await db.execute(
                "SELECT assignee_id, assignee_type FROM task_assignments "
                "WHERE task_id IN ({})".format(
                    ",".join("?" for _ in applied.json()["task_ids"])
                ),
                applied.json()["task_ids"],
            )
        ).fetchall()
    assert assignments == [(adult_b_user["id"], "user")] * 3


async def test_template_edit_changes_future_suggestions(client, adult_a_headers, initialized_db):
    await _event(client, adult_a_headers, title="Swim lesson")
    templates = (await client.get("/api/prep-packs/templates", headers=adult_a_headers)).json()
    swimming = next(item for item in templates if item["name"] == "Swimming")
    updated = await client.patch(
        f"/api/prep-packs/templates/{swimming['id']}",
        headers=adult_a_headers,
        json={
            "match_terms": ["swim", "swimming"],
            "items": ["Pack costume", "Pack two towels"],
            "lead_hours": 48,
        },
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["items"] == ["Pack costume", "Pack two towels"]
    suggestion = (await client.get("/api/prep-packs/suggestions", headers=adult_a_headers)).json()[0]
    assert suggestion["items"] == ["Pack costume", "Pack two towels"]


async def test_dismiss_is_per_occurrence_for_recurring_event(client, adult_a_headers):
    start = date.today().isoformat()
    await _event(
        client,
        adult_a_headers,
        start=start,
        recurrence="FREQ=DAILY;COUNT=2",
    )
    suggestions = (
        await client.get(
            "/api/prep-packs/suggestions", params={"horizon_days": 2}, headers=adult_a_headers
        )
    ).json()
    assert len(suggestions) == 2
    dismissed = await client.post(
        "/api/prep-packs/dismiss", headers=adult_a_headers, json=_action(suggestions[0])
    )
    assert dismissed.json() == {"status": "dismissed"}
    remaining = (
        await client.get(
            "/api/prep-packs/suggestions", params={"horizon_days": 2}, headers=adult_a_headers
        )
    ).json()
    assert [item["occurrence_start"] for item in remaining] == [suggestions[1]["occurrence_start"]]


async def test_cancelled_recurring_occurrence_cannot_create_a_stale_prep_pack(
    client, adult_a_headers
):
    event = await _event(
        client,
        adult_a_headers,
        start=date.today().isoformat(),
        recurrence="FREQ=DAILY;COUNT=2",
    )
    before = (
        await client.get(
            "/api/prep-packs/suggestions",
            params={"horizon_days": 2},
            headers=adult_a_headers,
        )
    ).json()
    assert len(before) == 2

    cancelled = await client.post(
        f"/api/calendar/{event['id']}/occurrences/delete",
        json={
            "scope": "only_this",
            "occurrence_start": before[0]["event_start"],
        },
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 204

    remaining = (
        await client.get(
            "/api/prep-packs/suggestions",
            params={"horizon_days": 2},
            headers=adult_a_headers,
        )
    ).json()
    assert [item["occurrence_start"] for item in remaining] == [
        before[1]["occurrence_start"]
    ]
    stale_apply = await client.post(
        "/api/prep-packs/apply",
        headers=adult_a_headers,
        json=_action(before[0]),
    )
    assert stale_apply.status_code == 409


async def test_custom_template_crud_and_family_isolation(
    client, adult_a_headers, other_family_headers
):
    created = await client.post(
        "/api/prep-packs/templates",
        headers=adult_a_headers,
        json={
            "name": "Ballet",
            "match_terms": ["ballet"],
            "items": ["Pack ballet shoes", "Pack water bottle"],
            "lead_hours": 12,
        },
    )
    assert created.status_code == 201
    template_id = created.json()["id"]
    other = await client.get("/api/prep-packs/templates", headers=other_family_headers)
    assert template_id not in {item["id"] for item in other.json()}
    stolen = await client.patch(
        f"/api/prep-packs/templates/{template_id}",
        headers=other_family_headers,
        json={"name": "Stolen"},
    )
    assert stolen.status_code == 404
    removed = await client.delete(
        f"/api/prep-packs/templates/{template_id}", headers=adult_a_headers
    )
    assert removed.status_code == 204


async def test_invalid_or_nonmatching_action_is_rejected(client, adult_a_headers):
    event = await _event(client, adult_a_headers, title="Dentist")
    templates = (await client.get("/api/prep-packs/templates", headers=adult_a_headers)).json()
    swimming = next(item for item in templates if item["name"] == "Swimming")
    response = await client.post(
        "/api/prep-packs/apply",
        headers=adult_a_headers,
        json={
            "template_id": swimming["id"],
            "event_id": event["id"],
            "occurrence_start": date.today().isoformat() + "T00:00:00+00:00",
        },
    )
    assert response.status_code == 409


async def test_prep_pack_endpoints_require_authentication(client):
    assert (await client.get("/api/prep-packs/templates")).status_code == 401
    assert (await client.get("/api/prep-packs/suggestions")).status_code == 401


async def test_template_and_occurrence_inputs_are_normalized(client, adult_a_headers):
    blank = await client.post(
        "/api/prep-packs/templates",
        headers=adult_a_headers,
        json={"name": "   ", "match_terms": ["club"], "items": ["Pack bag"]},
    )
    assert blank.status_code == 422
    naive_time = await client.post(
        "/api/prep-packs/apply",
        headers=adult_a_headers,
        json={
            "template_id": "template",
            "event_id": "event",
            "occurrence_start": "2026-07-12T10:00:00",
        },
    )
    assert naive_time.status_code == 422
