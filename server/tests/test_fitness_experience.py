"""Compact Fitness overview and HausKlar Today-card contracts."""

import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import aiosqlite
import pytest


pytestmark = pytest.mark.asyncio


OVERVIEW_KEYS = {
    "date",
    "focus",
    "session",
    "primary_action",
    "secondary_action",
    "quick_actions",
    "coach_nudge",
    "safety_adjustment",
}
TODAY_CARD_KEYS = {
    "date",
    "has_completed_activity_today",
    "session",
    "primary_action",
    "secondary_action",
    "nutrition",
}
SESSION_KEYS = {
    "id",
    "kind",
    "title",
    "sport_key",
    "status",
    "starts_at",
    "scheduled_date",
    "duration_minutes",
    "movable",
}
ACTION_KEYS = {"kind", "label", "destination", "target_id"}
BANNED_INTERNAL_KEYS = {
    "body_issue",
    "confidence",
    "evidence",
    "expires_at",
    "freshness",
    "provider",
    "recovery",
    "route",
    "settings",
    "source",
    "sync_attention",
}


def _all_keys(value) -> set[str]:
    if isinstance(value, dict):
        return set(value) | set().union(*(_all_keys(item) for item in value.values()))
    if isinstance(value, list):
        return set().union(*(_all_keys(item) for item in value)) if value else set()
    return set()


async def _create_plan(
    client,
    headers,
    *,
    title: str,
    hour: int,
    sport_key: str = "running",
) -> dict:
    local_day = datetime.now(timezone.utc).astimezone(ZoneInfo("Europe/London")).date()
    starts_at = datetime.combine(
        local_day,
        datetime.min.time(),
        tzinfo=ZoneInfo("Europe/London"),
    ).replace(hour=hour)
    response = await client.post(
        "/api/fitness/planned-sessions",
        headers=headers,
        json={
            "sport_key": sport_key,
            "title": title,
            "local_timezone": "Europe/London",
            "status": "accepted",
            "session_source": "user",
            "scheduled_start_utc": starts_at.astimezone(timezone.utc).isoformat(),
            "expected_duration_s": 2_700,
            "movable": True,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


async def test_running_plan_round_trips_an_optional_target_pace(client, adult_a_headers):
    response = await client.post(
        "/api/fitness/planned-sessions",
        headers=adult_a_headers,
        json={
            "sport_key": "running",
            "title": "Five easy kilometres",
            "local_timezone": "Europe/London",
            "status": "accepted",
            "session_source": "user",
            "scheduled_start_utc": "2026-08-10T07:00:00Z",
            "expected_distance_m": 5_000,
            "expected_pace_s_per_km": 315,
            "movable": False,
        },
    )
    assert response.status_code == 201, response.text
    assert response.json()["expected_pace_s_per_km"] == 315
    listed = await client.get("/api/fitness/planned-sessions", headers=adult_a_headers)
    assert listed.status_code == 200, listed.text
    saved = next(item for item in listed.json() if item["id"] == response.json()["id"])
    assert saved["expected_pace_s_per_km"] == 315


async def test_compact_experience_contracts_are_action_first_and_keep_today_compatible(
    client,
    adult_a_headers,
):
    plan = await _create_plan(client, adult_a_headers, title="Easy 5 km", hour=8)
    local_day = datetime.now(timezone.utc).astimezone(ZoneInfo("Europe/London")).date()

    overview_response = await client.get(
        "/api/fitness/overview",
        params={"date": local_day.isoformat()},
        headers=adult_a_headers,
    )
    assert overview_response.status_code == 200, overview_response.text
    overview = overview_response.json()
    assert set(overview) == OVERVIEW_KEYS
    assert set(overview["session"]) == SESSION_KEYS
    assert overview["session"] == {
        "id": plan["id"],
        "kind": "planned_session",
        "title": "Easy 5 km",
        "sport_key": "running",
        "status": "accepted",
        "starts_at": plan["scheduled_start_utc"].replace("+00:00", "Z"),
        "scheduled_date": local_day.isoformat(),
        "duration_minutes": 45,
        "movable": True,
    }
    assert set(overview["primary_action"]) == ACTION_KEYS
    assert overview["primary_action"] == {
        "kind": "open_session",
        "label": "Open",
        "destination": "plan",
        "target_id": plan["id"],
    }
    assert overview["secondary_action"] == {
        "kind": "move_session",
        "label": "Move",
        "destination": "plan",
        "target_id": plan["id"],
    }
    assert [item["kind"] for item in overview["quick_actions"]] == ["record_readiness"]
    assert overview["focus"]["outcome"] == "Move consistently"
    assert "weight" not in str(overview["focus"]).lower()
    assert "food" not in str(overview["focus"]).lower()
    assert overview["coach_nudge"] is None
    assert overview["safety_adjustment"] is None
    assert _all_keys(overview).isdisjoint(BANNED_INTERNAL_KEYS)

    card_response = await client.get(
        "/api/fitness/today-card",
        params={"date": local_day.isoformat()},
        headers=adult_a_headers,
    )
    assert card_response.status_code == 200, card_response.text
    card = card_response.json()
    assert set(card) == TODAY_CARD_KEYS
    assert set(card["session"]) == SESSION_KEYS
    assert card["session"]["id"] == plan["id"]
    assert card["primary_action"] == overview["primary_action"]
    assert card["secondary_action"] == overview["secondary_action"]
    assert card["nutrition"] is None
    assert _all_keys(card).isdisjoint(BANNED_INTERNAL_KEYS)

    legacy = await client.get("/api/fitness/today", headers=adult_a_headers)
    assert legacy.status_code == 200, legacy.text
    assert {
        "settings",
        "planned_sessions",
        "nutrition",
        "recovery",
        "next_action",
        "sync_attention",
    }.issubset(legacy.json())


async def test_strength_plan_exposes_a_real_start_action(client, adult_a_headers):
    plan = await _create_plan(
        client,
        adult_a_headers,
        title="Full body strength",
        hour=7,
        sport_key="strength",
    )

    card = (await client.get("/api/fitness/today-card", headers=adult_a_headers)).json()
    assert card["session"]["id"] == plan["id"]
    assert card["primary_action"] == {
        "kind": "start_session",
        "label": "Start",
        "destination": "plan",
        "target_id": plan["id"],
    }


async def test_empty_today_card_offers_one_tap_live_strength_start(client, adult_a_headers):
    preference = await client.patch(
        "/api/fitness/workspace",
        headers=adult_a_headers,
        json={"enabled": True},
    )
    assert preference.status_code == 200, preference.text

    card_response = await client.get("/api/fitness/today-card", headers=adult_a_headers)

    assert card_response.status_code == 200, card_response.text
    card = card_response.json()
    assert card["has_completed_activity_today"] is False
    assert card["session"] is None
    assert card["primary_action"] == {
        "kind": "start_strength",
        "label": "Start workout",
        "destination": "plan",
        "target_id": None,
    }
    assert card["secondary_action"] is None

    tomorrow = datetime.now(timezone.utc).astimezone(ZoneInfo("Europe/London")).date() + timedelta(days=1)
    future_card = (
        await client.get(
            "/api/fitness/today-card",
            params={"date": tomorrow.isoformat()},
            headers=adult_a_headers,
        )
    ).json()
    assert future_card["primary_action"] is None


async def test_today_card_shows_opt_in_running_calorie_and_protein_totals(
    client,
    adult_a_headers,
    adult_b_headers,
):
    food = await client.post(
        "/api/fitness/foods",
        headers=adult_a_headers,
        json={
            "name": "Breakfast oats",
            "version": {
                "reference_amount": 100,
                "reference_unit": "g",
                "calories_kcal": 400,
                "protein_g": 20,
            },
        },
    )
    assert food.status_code == 201, food.text
    version_id = food.json()["versions"][0]["id"]
    for metric_key, target_value in (
        ("nutrition.calories_kcal", 2_000),
        ("nutrition.protein_g", 120),
    ):
        target = await client.post(
            "/api/fitness/nutrition/targets",
            headers=adult_a_headers,
            json={
                "metric_key": metric_key,
                "target_type": "fixed",
                "target_value": target_value,
                "effective_from": "2026-08-01",
            },
        )
        assert target.status_code == 201, target.text
    logged = await client.post(
        "/api/fitness/food-log",
        headers=adult_a_headers,
        json={
            "food_version_id": version_id,
            "logged_at_utc": "2026-08-12T07:30:00Z",
            "local_timezone": "Europe/London",
            "meal_key": "breakfast",
            "entered_amount": 75,
            "entered_unit": "g",
            "canonical_amount": 75,
            "canonical_unit": "g",
            "measurement_quality": "weighed",
        },
    )
    assert logged.status_code == 201, logged.text
    preference = await client.patch(
        "/api/fitness/workspace",
        headers=adult_a_headers,
        json={"show_nutrition_today": True},
    )
    assert preference.status_code == 200, preference.text

    card = (
        await client.get(
            "/api/fitness/today-card",
            params={"date": "2026-08-12"},
            headers=adult_a_headers,
        )
    ).json()
    assert card["nutrition"] == {
        "calories_kcal": pytest.approx(300),
        "calorie_target_kcal": pytest.approx(2_000),
        "protein_g": pytest.approx(15),
        "protein_target_g": pytest.approx(120),
        "entry_count": 1,
        "calories_complete": True,
        "protein_complete": True,
    }
    adult_b_card = (
        await client.get(
            "/api/fitness/today-card",
            params={"date": "2026-08-12"},
            headers=adult_b_headers,
        )
    ).json()
    assert adult_b_card["nutrition"] is None


async def test_overview_and_today_card_are_isolated_between_adults(
    client,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_plan = await _create_plan(client, adult_a_headers, title="Alex private run", hour=7)
    adult_b_plan = await _create_plan(client, adult_b_headers, title="Morgan private strength", hour=9)
    now = datetime.now(timezone.utc)
    issue = await client.post(
        "/api/fitness/body-issues",
        headers=adult_b_headers,
        json={
            "observed_at_utc": now.isoformat(),
            "timing": "standalone",
            "issue_type_key": "pain",
            "body_location_key": "knee",
            "side": "right",
            "severity_0_10": 8,
            "changed_session": True,
            "session_change_key": "prevented_start",
        },
    )
    assert issue.status_code == 201, issue.text

    adult_a_overview = (await client.get("/api/fitness/overview", headers=adult_a_headers)).json()
    adult_b_overview = (await client.get("/api/fitness/overview", headers=adult_b_headers)).json()
    assert adult_a_overview["session"]["id"] == adult_a_plan["id"]
    assert adult_a_overview["session"]["title"] == "Alex private run"
    assert adult_a_overview["safety_adjustment"] is None
    assert adult_b_overview["session"]["id"] == adult_b_plan["id"]
    assert adult_b_overview["session"]["title"] == "Morgan private strength"
    assert adult_b_overview["safety_adjustment"] is not None

    adult_a_card = (await client.get("/api/fitness/today-card", headers=adult_a_headers)).json()
    adult_b_card = (await client.get("/api/fitness/today-card", headers=adult_b_headers)).json()
    assert adult_a_card["session"]["id"] == adult_a_plan["id"]
    assert adult_b_card["session"]["id"] == adult_b_plan["id"]
    assert "Morgan private strength" not in str(adult_a_card)
    assert "knee" not in str(adult_a_card).lower()
    assert "knee" not in str(adult_b_card).lower()
    assert "severity" not in str(adult_b_card).lower()
    assert _all_keys(adult_a_card).isdisjoint(BANNED_INTERNAL_KEYS)
    assert _all_keys(adult_b_card).isdisjoint(BANNED_INTERNAL_KEYS)


async def test_active_workout_is_the_first_action_even_when_a_plan_exists(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    await _create_plan(client, adult_a_headers, title="Later run", hour=18)
    activity_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc) - timedelta(minutes=30)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO health_activities "
            "(id, owner_user_id, sport_key, title, status, started_at_utc, "
            "local_timezone, family_id, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                activity_id,
                adult_a_user["id"],
                "strength",
                "Strength in progress",
                "in_progress",
                started_at.isoformat(),
                "Europe/London",
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()

    overview = (await client.get("/api/fitness/overview", headers=adult_a_headers)).json()
    assert overview["session"]["id"] == activity_id
    assert overview["session"]["kind"] == "active_activity"
    assert overview["primary_action"] == {
        "kind": "resume_activity",
        "label": "Resume",
        "destination": "plan",
        "target_id": activity_id,
    }
    assert overview["secondary_action"] is None

    card = (await client.get("/api/fitness/today-card", headers=adult_a_headers)).json()
    assert card["session"]["id"] == activity_id
    assert card["primary_action"] == overview["primary_action"]


async def test_strength_workout_can_no_longer_resume_after_one_hour(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    plan = await _create_plan(
        client,
        adult_a_headers,
        title="Strength that was left open",
        hour=7,
        sport_key="strength",
    )
    activity_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc) - timedelta(minutes=61)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO health_activities "
            "(id, owner_user_id, sport_key, title, status, planned_session_id, "
            "started_at_utc, local_timezone, family_id, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                activity_id,
                adult_a_user["id"],
                "strength",
                "Strength that was left open",
                "in_progress",
                plan["id"],
                started_at.isoformat(),
                "Europe/London",
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.execute(
            "UPDATE health_planned_sessions SET status = 'in_progress', "
            "completion_activity_id = ? WHERE id = ?",
            (activity_id, plan["id"]),
        )
        await db.commit()

    card_response = await client.get("/api/fitness/today-card", headers=adult_a_headers)
    assert card_response.status_code == 200, card_response.text
    card = card_response.json()
    assert card["primary_action"] == {
        "kind": "start_strength",
        "label": "Start workout",
        "destination": "plan",
        "target_id": None,
    }
    assert card["session"] is None

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        activity = await (
            await db.execute(
                "SELECT status, ended_at_utc, revision, deleted_at "
                "FROM health_activities WHERE id = ?",
                (activity_id,),
            )
        ).fetchone()
        saved_plan = await (
            await db.execute(
                "SELECT status, completion_activity_id, completion_state, revision "
                "FROM health_planned_sessions WHERE id = ?",
                (plan["id"],),
            )
        ).fetchone()
        histories = await (
            await db.execute(
                "SELECT table_name FROM record_history WHERE record_id IN (?, ?) "
                "ORDER BY table_name",
                (activity_id, plan["id"]),
            )
        ).fetchall()

    assert activity["status"] == "aborted"
    assert activity["deleted_at"] is None
    assert activity["revision"] == 2
    assert datetime.fromisoformat(activity["ended_at_utc"]) == started_at + timedelta(hours=1)
    assert dict(saved_plan) == {
        "status": "cancelled",
        "completion_activity_id": activity_id,
        "completion_state": "aborted",
        "revision": 2,
    }
    assert [row["table_name"] for row in histories] == [
        "health_activities",
        "health_planned_sessions",
    ]

    replacement = await client.post(
        "/api/fitness/strength/sessions",
        headers=adult_a_headers,
        json={
            "title": "Fresh strength session",
            "started_at_utc": datetime.now(timezone.utc).isoformat(),
            "local_timezone": "Europe/London",
            "status": "in_progress",
        },
    )
    assert replacement.status_code == 201, replacement.text
    assert replacement.json()["status"] == "in_progress"


async def test_today_card_reports_a_completed_activity_without_exposing_its_details(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    local_now = datetime.now(timezone.utc).astimezone(ZoneInfo("Europe/London"))
    started_at = local_now.replace(hour=6, minute=30, second=0, microsecond=0)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO health_activities "
            "(id, owner_user_id, sport_key, title, status, started_at_utc, "
            "local_calendar_date, local_timezone, family_id, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                str(uuid.uuid4()),
                adult_a_user["id"],
                "running",
                "Private morning run",
                "completed",
                started_at.astimezone(timezone.utc).isoformat(),
                local_now.date().isoformat(),
                "Europe/London",
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()

    card = (await client.get("/api/fitness/today-card", headers=adult_a_headers)).json()

    assert card["has_completed_activity_today"] is True
    assert card["session"] is None
    assert card["primary_action"] is None
    assert "Private morning run" not in str(card)
