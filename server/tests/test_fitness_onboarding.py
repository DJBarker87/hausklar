"""First-run Fitness setup remains private, useful and exactly-once."""

from datetime import datetime
from zoneinfo import ZoneInfo

import aiosqlite
import pytest


pytestmark = pytest.mark.asyncio


def _forbidden_internal_detail(payload: object) -> set[str]:
    forbidden = {"metric_key", "model", "provider", "confidence", "evidence"}
    found: set[str] = set()
    if isinstance(payload, dict):
        for key, value in payload.items():
            if key.lower() in forbidden:
                found.add(key.lower())
            found.update(_forbidden_internal_detail(value))
    elif isinstance(payload, list):
        for value in payload:
            found.update(_forbidden_internal_detail(value))
    return found


async def _counts(db_path: str, owner_id: str) -> tuple[int, int]:
    async with aiosqlite.connect(db_path) as db:
        goals = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_goals WHERE owner_user_id = ? AND deleted_at IS NULL",
                (owner_id,),
            )
        ).fetchone()
        sessions = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_planned_sessions WHERE owner_user_id = ? "
                "AND deleted_at IS NULL",
                (owner_id,),
            )
        ).fetchone()
    return int(goals[0]), int(sessions[0])


async def test_onboarding_preview_is_private_deterministic_and_confirmation_is_exactly_once(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    initialized_db,
):
    adult_a_initial = await client.get("/api/fitness/onboarding", headers=adult_a_headers)
    adult_b_initial = await client.get("/api/fitness/onboarding", headers=adult_b_headers)
    assert adult_a_initial.status_code == adult_b_initial.status_code == 200
    assert adult_a_initial.json()["id"] != adult_b_initial.json()["id"]

    event = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "School run",
            "start_time": "2026-08-03T07:00:00+01:00",
            "end_time": "2026-08-03T08:00:00+01:00",
        },
    )
    assert event.status_code == 201, event.text

    saved = await client.put(
        "/api/fitness/onboarding",
        headers=adult_a_headers,
        json={
            "main_outcome": "Run further",
            "availability": [
                {
                    "day": "Monday",
                    "time_of_day": "Morning",
                    "duration_minutes": 40,
                }
            ],
            "activities": ["Running"],
            "equipment": ["Running shoes"],
            "food_preferences": ["Family dinners"],
            "source_connections": ["Garmin"],
            "coach_style": "Direct and challenging",
            "use_family_calendar": True,
            "use_household_meals": True,
            "use_weather": True,
            "memory_enabled": True,
        },
    )
    assert saved.status_code == 200, saved.text
    assert saved.json()["status"] == "draft"
    assert (await client.get("/api/fitness/onboarding", headers=adult_b_headers)).json()[
        "main_outcome"
    ] is None

    preview = await client.post(
        "/api/fitness/onboarding/preview-week",
        headers=adult_a_headers,
        json={"week_start": "2026-08-03"},
    )
    assert preview.status_code == 200, preview.text
    week = preview.json()
    assert week["week_start"] == "2026-08-03"
    assert week["sessions"] == [
        {
            "day": "Monday",
            "date": "2026-08-03",
            "start_time": "08:00",
            "activity": "Running",
            "title": "Easy run",
            "duration_minutes": 40,
            "reason": "Fits around your family calendar.",
        }
    ]
    repeated_preview = await client.post(
        "/api/fitness/onboarding/preview-week",
        headers=adult_a_headers,
        json={"week_start": "2026-08-05"},
    )
    assert repeated_preview.status_code == 200
    assert repeated_preview.json() == week
    assert _forbidden_internal_detail(week) == set()
    assert await _counts(initialized_db, adult_a_user["id"]) == (0, 0)

    confirmed = await client.post(
        "/api/fitness/onboarding/confirm",
        headers=adult_a_headers,
        json={"preview_id": week["preview_id"]},
    )
    assert confirmed.status_code == 200, confirmed.text
    result = confirmed.json()
    assert result["status"] == "complete"
    assert result["week"] == week
    assert len(result["session_ids"]) == 1
    assert _forbidden_internal_detail(result) == set()

    replay = await client.post(
        "/api/fitness/onboarding/confirm",
        headers=adult_a_headers,
        json={"preview_id": week["preview_id"]},
    )
    assert replay.status_code == 200, replay.text
    assert replay.json() == result

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        goals = await (
            await db.execute(
                "SELECT * FROM health_goals WHERE owner_user_id = ? AND deleted_at IS NULL",
                (adult_a_user["id"],),
            )
        ).fetchall()
        sessions = await (
            await db.execute(
                "SELECT * FROM health_planned_sessions WHERE owner_user_id = ? "
                "AND deleted_at IS NULL",
                (adult_a_user["id"],),
            )
        ).fetchall()
        settings = await (
            await db.execute(
                "SELECT * FROM health_user_settings WHERE owner_user_id = ? AND deleted_at IS NULL",
                (adult_a_user["id"],),
            )
        ).fetchone()
        profile = await (
            await db.execute(
                "SELECT * FROM health_onboarding_profiles WHERE owner_user_id = ? "
                "AND deleted_at IS NULL",
                (adult_a_user["id"],),
            )
        ).fetchone()
    assert len(goals) == len(sessions) == 1
    assert goals[0]["id"] == result["goal_id"]
    assert goals[0]["revision"] == sessions[0]["revision"] == 1
    assert sessions[0]["id"] == result["session_ids"][0]
    assert sessions[0]["status"] == "accepted"
    local_start = datetime.fromisoformat(sessions[0]["scheduled_start_utc"]).astimezone(
        ZoneInfo("Europe/London")
    )
    assert local_start.strftime("%Y-%m-%d %H:%M") == "2026-08-03 08:00"
    # Coach style and memory are deliberately deferred until after the first
    # useful week. Legacy fields remain resumable, but confirmation cannot opt
    # the adult into specialist behavior they have not configured in context.
    assert settings is None
    assert profile["use_family_calendar"] == 1
    assert profile["use_household_meals"] == 1
    assert profile["use_weather"] == 1


async def test_onboarding_skip_is_idempotent_writes_no_plan_and_empty_put_resumes(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    first = await client.post("/api/fitness/onboarding/skip", headers=adult_a_headers)
    second = await client.post("/api/fitness/onboarding/skip", headers=adult_a_headers)
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    assert first.json()["status"] == "skipped"
    assert first.json()["preview"] is None
    assert await _counts(initialized_db, adult_a_user["id"]) == (0, 0)

    blocked = await client.post(
        "/api/fitness/onboarding/preview-week",
        headers=adult_a_headers,
        json={"week_start": "2026-08-03"},
    )
    assert blocked.status_code == 409

    resumed = await client.put(
        "/api/fitness/onboarding",
        headers=adult_a_headers,
        json={},
    )
    assert resumed.status_code == 200, resumed.text
    assert resumed.json()["status"] == "draft"
    preview = await client.post(
        "/api/fitness/onboarding/preview-week",
        headers=adult_a_headers,
        json={"week_start": "2026-08-03"},
    )
    assert preview.status_code == 200, preview.text
    assert len(preview.json()["sessions"]) == 3
    assert await _counts(initialized_db, adult_a_user["id"]) == (0, 0)


async def test_existing_fitness_adult_starts_skipped_without_affecting_new_adult(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_a_user,
    initialized_db,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "INSERT INTO health_goals "
            "(id, owner_user_id, goal_type, metric_key, name, starts_on, family_id, "
            "created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                "00000000-0000-0000-0000-00000000e001",
                adult_a_user["id"],
                "fitness",
                "activity.sessions_per_week",
                "Existing plan",
                "2026-07-01",
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()

    adult_a_profile = await client.get("/api/fitness/onboarding", headers=adult_a_headers)
    adult_b_profile = await client.get("/api/fitness/onboarding", headers=adult_b_headers)
    assert adult_a_profile.status_code == adult_b_profile.status_code == 200
    assert adult_a_profile.json()["status"] == "skipped"
    assert adult_b_profile.json()["status"] == "draft"
    assert adult_a_profile.json()["id"] != adult_b_profile.json()["id"]

    resumed = await client.put("/api/fitness/onboarding", headers=adult_a_headers, json={})
    assert resumed.status_code == 200
    assert resumed.json()["status"] == "draft"
    assert (await client.get("/api/fitness/onboarding", headers=adult_b_headers)).json()[
        "status"
    ] == "draft"


async def test_onboarding_confirmation_revalidates_family_calendar(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    saved = await client.put(
        "/api/fitness/onboarding",
        headers=adult_a_headers,
        json={
            "availability": [
                {
                    "day": "Tuesday",
                    "time_of_day": "Morning",
                    "duration_minutes": 30,
                }
            ],
            "use_family_calendar": True,
        },
    )
    assert saved.status_code == 200
    preview = await client.post(
        "/api/fitness/onboarding/preview-week",
        headers=adult_a_headers,
        json={"week_start": "2026-08-03"},
    )
    assert preview.status_code == 200, preview.text
    assert preview.json()["sessions"][0]["start_time"] == "07:00"

    event = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "New family commitment",
            "start_time": "2026-08-04T07:00:00+01:00",
            "end_time": "2026-08-04T08:00:00+01:00",
        },
    )
    assert event.status_code == 201, event.text
    confirmed = await client.post(
        "/api/fitness/onboarding/confirm",
        headers=adult_a_headers,
        json={"preview_id": preview.json()["preview_id"]},
    )
    assert confirmed.status_code == 409
    assert await _counts(initialized_db, adult_a_user["id"]) == (0, 0)


async def test_onboarding_does_not_schedule_around_a_cancelled_occurrence(
    client,
    adult_a_headers,
):
    event = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "Temporary Monday commitment",
            "start_time": "2026-08-03T07:00:00+01:00",
            "end_time": "2026-08-03T08:00:00+01:00",
            "recurrence_rule": "FREQ=WEEKLY;COUNT=2",
        },
    )
    assert event.status_code == 201
    cancelled = await client.post(
        f"/api/calendar/{event.json()['id']}/occurrences/delete",
        headers=adult_a_headers,
        json={
            "scope": "only_this",
            "occurrence_start": "2026-08-03T07:00:00+01:00",
        },
    )
    assert cancelled.status_code == 204
    saved = await client.put(
        "/api/fitness/onboarding",
        headers=adult_a_headers,
        json={
            "availability": [
                {
                    "day": "Monday",
                    "time_of_day": "Morning",
                    "duration_minutes": 40,
                }
            ],
            "use_family_calendar": True,
        },
    )
    assert saved.status_code == 200

    preview = await client.post(
        "/api/fitness/onboarding/preview-week",
        headers=adult_a_headers,
        json={"week_start": "2026-08-03"},
    )

    assert preview.status_code == 200, preview.text
    assert preview.json()["sessions"][0]["start_time"] == "07:00"
