"""Focused authoritative Fitness next-action contracts."""

import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import aiosqlite
import pytest

from app.database import standalone_db
from app.services.fitness.coach import store_recommendation


pytestmark = pytest.mark.asyncio


async def test_today_and_coach_share_session_specific_fresh_next_action(
    client, adult_a_headers, adult_a_user, initialized_db
):
    now = datetime.now(timezone.utc)
    local_day = now.astimezone(ZoneInfo("Europe/London")).date()
    plan_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    for index, plan_id in enumerate(plan_ids):
        created = await client.post(
            "/api/fitness/planned-sessions",
            headers=adult_a_headers,
            json={
                "id": plan_id,
                "sport_key": "running",
                "title": f"Run {index + 1}",
                "local_timezone": "Europe/London",
                "status": "scheduled",
                "session_source": "user",
                "scheduled_start_utc": datetime.combine(
                    local_day,
                    datetime.min.time(),
                    tzinfo=ZoneInfo("Europe/London"),
                )
                .replace(hour=8 + index * 2)
                .astimezone(timezone.utc)
                .isoformat(),
            },
        )
        assert created.status_code == 201, created.text

    unrelated = await client.post(
        "/api/fitness/session-checkins",
        headers=adult_a_headers,
        json={
            "planned_session_id": plan_ids[1],
            "timing": "pre",
            "captured_at_utc": now.isoformat(),
            "capture_quality": "contemporaneous",
            "readiness_1_5": 4,
        },
    )
    assert unrelated.status_code == 201, unrelated.text
    missing = await client.get("/api/fitness/next-action", headers=adult_a_headers)
    assert missing.status_code == 200, missing.text
    assert missing.json()["source"] == f"readiness:{plan_ids[0]}"
    today_missing = await client.get("/api/fitness/today", headers=adult_a_headers)
    assert today_missing.json()["recovery"]["readiness"] is None

    matching = await client.post(
        "/api/fitness/session-checkins",
        headers=adult_a_headers,
        json={
            "planned_session_id": plan_ids[0],
            "timing": "pre",
            "captured_at_utc": (now + timedelta(seconds=1)).isoformat(),
            "capture_quality": "contemporaneous",
            "readiness_1_5": 3,
        },
    )
    assert matching.status_code == 201, matching.text
    async with standalone_db(initialized_db) as db:
        recommendation = await store_recommendation(
            db,
            user=adult_a_user,
            recommendation_type="fuel_consistency",
            text="Keep breakfast protein consistent before changing the target.",
            expected_effect="Maintain a stable comparison point.",
            evidence=[],
            provider="openai-codex",
            model="fitness-test",
            proposal_id=None,
        )
        await db.commit()

    low_issue = await client.post(
        "/api/fitness/body-issues",
        headers=adult_a_headers,
        json={
            "observed_at_utc": now.isoformat(),
            "timing": "standalone",
            "issue_type_key": "tightness",
            "body_location_key": "calf_shin",
            "side": "left",
            "severity_0_10": 2,
            "changed_session": False,
            "session_change_key": "none",
        },
    )
    assert low_issue.status_code == 201, low_issue.text
    coach_action = await client.get("/api/fitness/next-action", headers=adult_a_headers)
    assert coach_action.status_code == 200, coach_action.text
    action = coach_action.json()
    assert action["source"] == f"coach_recommendation:{recommendation['id']}"
    assert action["action"] == {
        "kind": "open_coach",
        "target": recommendation["id"],
        "label": "Open Coach advice",
    }
    assert action["secondary_action"]["kind"] == "open_body_issue"
    today = await client.get("/api/fitness/today", headers=adult_a_headers)
    assert today.status_code == 200, today.text
    assert today.json()["next_action"] == action
    assert today.json()["recovery"]["readiness"] == 3

    async with standalone_db(initialized_db) as db:
        await store_recommendation(
            db,
            user=adult_a_user,
            recommendation_type="weekly_review_draft",
            text="Your optional weekly review is ready.",
            expected_effect={"week_start": local_day.isoformat()},
            evidence=[],
            provider="deterministic",
            model="hausklar-scheduler",
            proposal_id=None,
        )
        await db.execute(
            "UPDATE health_coach_recommendations SET status = 'accepted', "
            "created_at = ? WHERE id = ?",
            ((now - timedelta(days=30)).isoformat(), recommendation["id"]),
        )
        await db.commit()
    fresh_plan = await client.get("/api/fitness/next-action", headers=adult_a_headers)
    assert fresh_plan.status_code == 200, fresh_plan.text
    assert fresh_plan.json()["source"] == f"planned_session:{plan_ids[0]}"

    high_issue = await client.post(
        "/api/fitness/body-issues",
        headers=adult_a_headers,
        json={
            "observed_at_utc": (now + timedelta(seconds=2)).isoformat(),
            "timing": "standalone",
            "issue_type_key": "pain",
            "body_location_key": "knee",
            "side": "right",
            "severity_0_10": 8,
            "changed_session": True,
            "session_change_key": "prevented_start",
        },
    )
    assert high_issue.status_code == 201, high_issue.text
    urgent = await client.get("/api/fitness/next-action", headers=adult_a_headers)
    assert urgent.json()["source"] == f"body_issue:{high_issue.json()['id']}"
    assert urgent.json()["urgency"] == "urgent"
    assert urgent.json()["action"]["kind"] == "open_body_issue"

    async with aiosqlite.connect(initialized_db) as db:
        accepted_old = await (
            await db.execute(
                "SELECT status FROM health_coach_recommendations WHERE id = ?",
                (recommendation["id"],),
            )
        ).fetchone()
    assert accepted_old[0] == "accepted"
