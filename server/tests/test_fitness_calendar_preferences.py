"""Owner-private Fitness calendar preference and layer contracts."""

from datetime import date, timedelta

import aiosqlite
import pytest

from app.database import init_db


pytestmark = pytest.mark.asyncio

PREFERENCE_KEYS = {"show_planned", "show_completed"}
CALENDAR_LAYER_KEYS = {
    "id",
    "owner_user_id",
    "layer_kind",
    "display_title",
    "sport_key",
    "status",
    "scheduled_start_utc",
    "scheduled_date",
    "time_window_start_utc",
    "time_window_end_utc",
    "duration_s",
    "detail_id",
}


async def _create_plan(client, headers, *, title: str) -> dict:
    response = await client.post(
        "/api/fitness/planned-sessions",
        headers=headers,
        json={
            "sport_key": "running",
            "title": title,
            "local_timezone": "Europe/London",
            "status": "accepted",
            "scheduled_date": (date.today() + timedelta(days=1)).isoformat(),
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


async def test_existing_settings_rows_gain_safe_calendar_defaults(tmp_path):
    legacy_path = str(tmp_path / "legacy-calendar-preferences.db")
    async with aiosqlite.connect(legacy_path) as db:
        await db.execute(
            "CREATE TABLE health_user_settings ("
            "id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, "
            "nutrition_day_start_minutes INTEGER NOT NULL DEFAULT 240, "
            "timezone TEXT NOT NULL DEFAULT 'Europe/London', "
            "revision INTEGER NOT NULL DEFAULT 1, family_id TEXT NOT NULL, "
            "created_at TEXT NOT NULL, updated_at TEXT NOT NULL, created_by TEXT, "
            "client_id TEXT, client_timestamp TEXT, deleted_at TEXT)"
        )
        await db.execute(
            "INSERT INTO health_user_settings "
            "(id, owner_user_id, family_id, created_at, updated_at) "
            "VALUES ('settings-1', 'dom-1', 'family-1', '2026-08-01', '2026-08-01')"
        )
        await db.commit()

    await init_db(legacy_path)

    async with aiosqlite.connect(legacy_path) as db:
        columns = {
            row[1]: row
            for row in await (
                await db.execute("PRAGMA table_info(health_user_settings)")
            ).fetchall()
        }
        row = await (
            await db.execute(
                "SELECT show_planned, show_completed FROM health_user_settings "
                "WHERE id = 'settings-1'"
            )
        ).fetchone()

    assert {"show_planned", "show_completed"}.issubset(columns)
    assert columns["show_planned"][4] == "1"
    assert columns["show_completed"][4] == "0"
    assert row == (1, 0)


async def test_calendar_preferences_default_per_owner_and_return_only_contract_fields(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    adult_b_user,
    initialized_db,
):
    dom = await client.get("/api/fitness/calendar-preferences", headers=adult_a_headers)
    kat = await client.get("/api/fitness/calendar-preferences", headers=adult_b_headers)

    assert dom.status_code == 200, dom.text
    assert kat.status_code == 200, kat.text
    assert dom.json() == {"show_planned": True, "show_completed": False}
    assert kat.json() == {"show_planned": True, "show_completed": False}
    assert set(dom.json()) == PREFERENCE_KEYS
    assert set(kat.json()) == PREFERENCE_KEYS

    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT owner_user_id, family_id, show_planned, show_completed "
                "FROM health_user_settings ORDER BY owner_user_id"
            )
        ).fetchall()
    assert rows == [
        (adult_a_user["id"], adult_a_user["family_id"], 1, 0),
        (adult_b_user["id"], adult_b_user["family_id"], 1, 0),
    ]


async def test_calendar_preference_updates_are_partial_isolated_and_nutrition_safe(
    client,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_update = await client.patch(
        "/api/fitness/calendar-preferences",
        headers=adult_a_headers,
        json={"show_completed": True},
    )
    adult_b_update = await client.patch(
        "/api/fitness/calendar-preferences",
        headers=adult_b_headers,
        json={"show_planned": False},
    )
    assert adult_a_update.status_code == 200, adult_a_update.text
    assert adult_b_update.status_code == 200, adult_b_update.text
    assert adult_a_update.json() == {"show_planned": True, "show_completed": True}
    assert adult_b_update.json() == {"show_planned": False, "show_completed": False}

    nutrition = await client.patch(
        "/api/fitness/nutrition/settings",
        headers=adult_a_headers,
        json={
            "nutrition_day_start_minutes": 180,
            "timezone": "Europe/Berlin",
        },
    )
    assert nutrition.status_code == 200, nutrition.text
    adult_a_after_nutrition = await client.get("/api/fitness/calendar-preferences", headers=adult_a_headers)
    adult_b_after_dom_update = await client.get(
        "/api/fitness/calendar-preferences", headers=adult_b_headers
    )
    assert adult_a_after_nutrition.json() == {
        "show_planned": True,
        "show_completed": True,
    }
    assert adult_b_after_dom_update.json() == {
        "show_planned": False,
        "show_completed": False,
    }

    empty = await client.patch("/api/fitness/calendar-preferences", headers=adult_a_headers, json={})
    scope_injection = await client.patch(
        "/api/fitness/calendar-preferences",
        headers=adult_a_headers,
        json={"show_planned": True, "owner_user_id": "someone-else"},
    )
    assert empty.status_code == 422
    assert scope_injection.status_code == 422


async def test_calendar_layer_stays_owner_private_and_redacted(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    adult_b_user,
):
    adult_a_plan = await _create_plan(client, adult_a_headers, title="Alex private run")
    adult_b_plan = await _create_plan(client, adult_b_headers, title="Morgan private run")
    start = date.today().isoformat()
    end = (date.today() + timedelta(days=2)).isoformat()

    adult_a_response = await client.get(
        "/api/fitness/calendar-layer",
        headers=adult_a_headers,
        params={"start": start, "end": end},
    )
    adult_b_response = await client.get(
        "/api/fitness/calendar-layer",
        headers=adult_b_headers,
        params={"start": start, "end": end},
    )
    assert adult_a_response.status_code == 200, adult_a_response.text
    assert adult_b_response.status_code == 200, adult_b_response.text
    assert adult_a_response.json() == [
        {
            "id": adult_a_plan["id"],
            "owner_user_id": adult_a_user["id"],
            "layer_kind": "planned",
            "display_title": "Alex private run",
            "sport_key": "running",
            "status": "accepted",
            "scheduled_start_utc": None,
            "scheduled_date": adult_a_plan["scheduled_date"],
            "time_window_start_utc": None,
            "time_window_end_utc": None,
            "duration_s": None,
            "detail_id": adult_a_plan["id"],
        }
    ]
    assert adult_b_response.json()[0]["id"] == adult_b_plan["id"]
    assert adult_b_response.json()[0]["owner_user_id"] == adult_b_user["id"]
    assert adult_b_response.json()[0]["display_title"] == "Morgan private run"
    assert all(set(item) == CALENDAR_LAYER_KEYS for item in adult_a_response.json())
    assert all(set(item) == CALENDAR_LAYER_KEYS for item in adult_b_response.json())
    assert "Morgan private run" not in str(adult_a_response.json())
    assert "Alex private run" not in str(adult_b_response.json())


async def test_completed_activity_calendar_item_is_owned_by_the_person_who_logged_it(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
):
    today = date.today().isoformat()
    created = await client.post(
        "/api/fitness/activities/manual",
        headers=adult_a_headers,
        json={
            "sport_key": "running",
            "title": "Evening run",
            "started_at_utc": f"{today}T18:00:00Z",
            "local_timezone": "Europe/Berlin",
            "duration_s": 1_800,
            "estimate_energy": False,
        },
    )
    assert created.status_code == 201, created.text

    adult_a_response = await client.get(
        "/api/fitness/calendar-layer",
        headers=adult_a_headers,
        params={"start": today, "end": today, "include_completed": True},
    )
    adult_b_response = await client.get(
        "/api/fitness/calendar-layer",
        headers=adult_b_headers,
        params={"start": today, "end": today, "include_completed": True},
    )

    assert adult_a_response.status_code == 200, adult_a_response.text
    activity_item = next(
        item for item in adult_a_response.json() if item["id"] == created.json()["id"]
    )
    assert activity_item["owner_user_id"] == adult_a_user["id"]
    assert activity_item["layer_kind"] == "completed"
    assert all(set(item) == CALENDAR_LAYER_KEYS for item in adult_a_response.json())
    assert adult_b_response.status_code == 200, adult_b_response.text
    assert created.json()["id"] not in {item["id"] for item in adult_b_response.json()}
