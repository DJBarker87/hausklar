import json
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import aiosqlite

LOCAL = ZoneInfo("Europe/London")


async def _seed(db_path: str, adult_a_user: dict, child1: dict) -> dict:
    now = datetime.now(LOCAL)
    today = now.date()
    ids = {
        "morning": "glance-event-morning",
        "recurring": "glance-event-recurring",
        "tomorrow": "glance-event-tomorrow",
        "task": "glance-task",
        "old_task": "glance-task-done",
        "nap": "glance-active-nap",
        "dog_walk": "glance-active-dog-walk",
        "star_chart": "glance-star-chart",
    }
    async with aiosqlite.connect(db_path) as db:
        await db.executemany(
            """INSERT INTO calendar_events
               (id, title, start_time, all_day, recurrence_rule, assigned_to, family_id, created_by)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                (
                    ids["morning"],
                    "Swimming",
                    datetime.combine(today, datetime.min.time(), tzinfo=LOCAL)
                    .replace(hour=8, minute=30)
                    .isoformat(),
                    0,
                    None,
                    child1["id"],
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
                (
                    ids["recurring"],
                    "Weekly club",
                    (
                        datetime.combine(today, datetime.min.time(), tzinfo=LOCAL)
                        .replace(hour=16)
                        - timedelta(days=14)
                    ).isoformat(),
                    0,
                    "FREQ=WEEKLY",
                    None,
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
                (
                    ids["tomorrow"],
                    "Dentist",
                    datetime.combine(today + timedelta(days=1), datetime.min.time(), tzinfo=LOCAL)
                    .replace(hour=14)
                    .isoformat(),
                    0,
                    None,
                    None,
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            ],
        )
        await db.execute(
            "UPDATE calendar_events SET assigned_to = NULL, family_member_ids = ? WHERE id = ?",
            (json.dumps([adult_a_user["id"], child1["id"]]), ids["morning"]),
        )
        await db.execute(
            """INSERT INTO tasks (id, title, due_date, family_id, created_by)
               VALUES (?, ?, ?, ?, ?)""",
            (ids["task"], "Book photos", today.isoformat(), adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO meals (id, name, family_id, created_by) VALUES (?, ?, ?, ?)""",
            ("glance-meal", "Spaghetti", adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO meal_plans (id, meal_id, date, meal_type, family_id, created_by)
               VALUES (?, ?, ?, 'dinner', ?, ?)""",
            ("glance-plan", "glance-meal", today.isoformat(), adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO illnesses (id, child_id, started_at, family_id, created_by)
               VALUES (?, ?, ?, ?, ?)""",
            (
                "glance-illness",
                child1["id"],
                (datetime.now(timezone.utc) - timedelta(hours=6)).isoformat(),
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO medicine_types
               (id, child_id, name, min_hours_between_doses, max_doses_24h, family_id, created_by)
               VALUES (?, ?, 'Calpol', 4, 4, ?, ?)""",
            ("glance-medicine", child1["id"], adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO medicine_doses
               (id, child_id, medicine_type_id, given_at, given_by, family_id, created_by)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (
                "glance-dose",
                child1["id"],
                "glance-medicine",
                (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
                adult_a_user["id"],
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO naps
               (id, child_id, started_at, sleep_type, family_id, created_by)
               VALUES (?, ?, ?, 'nap', ?, ?)""",
            (
                ids["nap"],
                child1["id"],
                (datetime.now(timezone.utc) - timedelta(minutes=40)).isoformat(),
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO dog_profiles (id, name, family_id, created_by)
               VALUES ('glance-dog-profile', 'Otto', ?, ?)""",
            (adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """INSERT INTO dog_activities
               (id, activity_type, started_at, is_active, family_id, created_by)
               VALUES (?, 'walk', ?, 1, ?, ?)""",
            (
                ids["dog_walk"],
                (datetime.now(timezone.utc) - timedelta(minutes=8)).isoformat(),
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO star_charts
               (id, child_id, title, grid_rows, grid_columns, family_id, created_by)
               VALUES (?, ?, 'Kind choices', 2, 5, ?, ?)""",
            (
                ids["star_chart"],
                child1["id"],
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """INSERT INTO star_chart_stars
               (id, chart_id, row_index, col_index, family_id, created_by)
               VALUES ('glance-star', ?, 0, 0, ?, ?)""",
            (ids["star_chart"], adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()
    return ids


async def test_glance_requires_authentication(client):
    response = await client.get("/api/briefing/glance")
    assert response.status_code == 401


async def test_glance_snapshot(client, adult_a_headers, adult_a_user, child1, initialized_db):
    ids = await _seed(initialized_db, adult_a_user, child1)

    response = await client.get(
        "/api/briefing/glance",
        params={"timezone": "Europe/London"},
        headers=adult_a_headers,
    )
    assert response.status_code == 200
    glance = response.json()

    event_ids = [event["id"] for event in glance["events"]]
    assert ids["morning"] in event_ids
    assert any(
        event_id.startswith(f"{ids['recurring']}::") for event_id in event_ids
    ), "weekly recurrence should expand into today with an exact occurrence identity"
    assert ids["tomorrow"] not in event_ids
    swimming = next(event for event in glance["events"] if event["id"] == ids["morning"])
    assert swimming["person_name"] == f"{adult_a_user['name']} & {child1['name']}"
    assert not swimming["all_day"]

    assert [task["id"] for task in glance["tasks_due"]] == [ids["task"]]
    assert glance["dinner"] == {"title": "Spaghetti"}

    assert len(glance["medicine"]) == 1
    dose = glance["medicine"][0]
    assert dose["child_name"] == child1["name"]
    assert dose["medicine_name"] == "Calpol"
    assert dose["medicine_type_id"] == "glance-medicine"
    assert dose["is_safe_now"] is False
    assert dose["next_safe_at"] is not None

    assert len(glance["active_naps"]) == 1
    nap = glance["active_naps"][0]
    assert nap["id"] == ids["nap"]
    assert nap["child_id"] == child1["id"]
    assert nap["child_name"] == child1["name"]
    assert nap["sleep_type"] == "nap"
    assert datetime.fromisoformat(nap["started_at"])
    assert glance["dog_care"]["dog_name"] == "Otto"
    assert glance["dog_care"]["active_walk_id"] == ids["dog_walk"]
    assert glance["star_chart"] == {
        "chart_id": ids["star_chart"],
        "child_id": child1["id"],
        "child_name": child1["name"],
        "title": "Kind choices",
        "total_cells": 10,
        "stars_count": 1,
    }

    assert glance["tomorrow"]["first_event"]["id"] == ids["tomorrow"]
    assert glance["tomorrow"]["event_count"] >= 1


async def test_glance_excludes_a_cancelled_recurring_occurrence(
    client, adult_a_headers
):
    today = datetime.now(LOCAL).date().isoformat()
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Cancelled family club",
            "start_time": today,
            "all_day": True,
            "recurrence_rule": "FREQ=DAILY;COUNT=2",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    cancelled = await client.post(
        f"/api/calendar/{created.json()['id']}/occurrences/delete",
        json={"scope": "only_this", "occurrence_start": today},
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 204

    response = await client.get(
        "/api/briefing/glance",
        params={"timezone": "Europe/London"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert "Cancelled family club" not in {
        event["title"] for event in response.json()["events"]
    }


async def test_glance_includes_early_morning_utc_event(
    client, adult_a_headers, adult_a_user, initialized_db
):
    """An event just after local midnight, stored as previous-day UTC, is today."""
    now = datetime.now(LOCAL)
    today = now.date()
    # 00:30 local today == 23:30 UTC yesterday during BST.
    local_0030 = datetime.combine(today, datetime.min.time(), tzinfo=LOCAL).replace(hour=0, minute=30)
    stored_utc = local_0030.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """INSERT INTO calendar_events (id, title, start_time, all_day, family_id, created_by)
               VALUES (?, ?, ?, 0, ?, ?)""",
            ("glance-early", "Night feed", stored_utc, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    response = await client.get(
        "/api/briefing/glance", params={"timezone": "Europe/London"}, headers=adult_a_headers
    )
    assert response.status_code == 200
    assert "glance-early" in [event["id"] for event in response.json()["events"]]


async def test_glance_is_family_scoped_and_handles_empty(client, other_family_headers):
    response = await client.get("/api/briefing/glance", headers=other_family_headers)
    assert response.status_code == 200
    glance = response.json()
    assert glance["events"] == []
    assert glance["tasks_due"] == []
    assert glance["dinner"] is None
    assert glance["medicine"] == []
    assert glance["active_naps"] == []
    assert glance["dog_care"] is None
    assert glance["star_chart"] is None
    assert glance["tomorrow"] == {"first_event": None, "event_count": 0}


async def test_glance_medicine_ignores_children_without_active_illness(
    client, adult_a_headers, adult_a_user, child1, initialized_db
):
    await _seed(initialized_db, adult_a_user, child1)
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE illnesses SET ended_at = ? WHERE id = 'glance-illness'", (now,)
        )
        await db.commit()

    response = await client.get("/api/briefing/glance", headers=adult_a_headers)
    assert response.status_code == 200
    assert response.json()["medicine"] == []
