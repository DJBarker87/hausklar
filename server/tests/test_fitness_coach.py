"""Focused Fitness Coach boundary, proposal and owner-isolation contracts."""

import asyncio
import io
import json
import uuid
import zipfile
from datetime import datetime, timedelta, timezone

import aiosqlite
import pytest

from app.database import standalone_db
from app.services.fitness.coach import (
    _family_calendar_context,
    ensure_weekly_review_markers,
)
from app.services.hermes import (
    FitnessHermesProposal,
    FitnessHermesRecommendation,
    FitnessHermesResponse,
)


pytestmark = pytest.mark.asyncio


def _run_proposal() -> dict:
    return {
        "title": "Easy 5 km",
        "purpose": "Build consistency without adding hard training.",
        "scheduled_date": "2026-08-09",
        "local_timezone": "Europe/London",
        "estimated_duration_s": 1800,
        "estimated_distance_m": 5000,
        "expected_difficulty": "Easy",
        "route_assumption": "Flat local route",
        "terrain_assumption": "Road",
        "goal_reason": "A conservative next session.",
        "goal_ids": [],
        "intended_gear_ids": [],
        "steps": [
            {
                "sequence": 0,
                "step_kind": "step",
                "duration_type": "distance_m",
                "duration_value": 5000,
                "target_type": "none",
                "display_name": "Easy 5 km",
            }
        ],
        "cues": [],
        "garmin_limitations": [],
    }


async def _count(db_path: str, table: str) -> int:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(f"SELECT COUNT(*) FROM {table}")).fetchone()
        return int(row[0])


async def test_status_is_read_only_and_global_consent_gates_only_explicit_messages(
    client, adult_a_headers, monkeypatch
):
    calls = {"status": 0, "message": 0}

    async def fake_status():
        calls["status"] += 1
        return {"provider": "openai-codex", "model": "fitness-test"}

    async def must_not_call(**_kwargs):
        calls["message"] += 1
        raise AssertionError("The model must run only for an explicit consented message")

    monkeypatch.setattr("app.routers.fitness_coach.fitness_coach_bridge_status", fake_status)
    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", must_not_call)

    status = await client.get("/api/fitness/coach/status", headers=adult_a_headers)
    assert status.status_code == 200
    assert status.json() == {
        "status": "available",
        "provider": "openai-codex",
        "model": "fitness-test",
        "message": None,
        "intents": [
            "discussion",
            "morning",
            "post_workout",
            "evening",
            "weekly",
            "run_plan",
            "strength_plan",
        ],
    }
    assert (
        await client.get("/api/fitness/coach/recommendations", headers=adult_a_headers)
    ).status_code == 200
    assert calls == {"status": 1, "message": 0}

    revoked = await client.delete("/api/auth/ai-consent", headers=adult_a_headers)
    assert revoked.status_code == 200
    blocked = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "What should I train?", "intent": "discussion"},
    )
    assert blocked.status_code == 428
    assert calls["message"] == 0


async def test_unavailable_bridge_is_a_normal_empty_result(
    client, adult_a_headers, initialized_db, monkeypatch
):
    async def unavailable(**_kwargs):
        return None

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", unavailable)
    response = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Give me a morning briefing", "intent": "morning"},
    )
    assert response.status_code == 200
    assert response.json()["status"] == "unavailable"
    assert response.json()["proposal"] is None
    assert response.json()["recommendation"] is None
    assert await _count(initialized_db, "health_coach_proposals") == 0
    assert await _count(initialized_db, "health_coach_recommendations") == 0


async def test_run_draft_is_owner_private_and_confirmed_exactly_once(
    client,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    monkeypatch,
):
    async def propose_run(**_kwargs):
        return FitnessHermesResponse(
            answer="I have prepared a conservative 5 km draft for review.",
            evidence_ids=[],
            proposal=FitnessHermesProposal(kind="run_workout", payload=_run_proposal()),
            provider="openai-codex",
            model="fitness-test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", propose_run)
    response = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Plan an easy 5 km next Sunday", "intent": "run_plan"},
    )
    assert response.status_code == 200, response.text
    proposal = response.json()["proposal"]
    assert proposal["kind"] == "run_workout"
    assert proposal["validation"] == {"valid": True, "issues": []}
    for table in (
        "health_workout_definitions",
        "health_workout_versions",
        "health_planned_sessions",
    ):
        assert await _count(initialized_db, table) == 0

    hidden = await client.post(
        f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
        headers=adult_b_headers,
    )
    assert hidden.status_code == 404

    first, second = await asyncio.gather(
        client.post(
            f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
            headers=adult_a_headers,
        ),
        client.post(
            f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
            headers=adult_a_headers,
        ),
    )
    assert first.status_code == second.status_code == 200
    assert first.json()["status"] == second.json()["status"] == "confirmed"
    assert first.json()["result_ids"] == second.json()["result_ids"]
    for table in (
        "health_workout_definitions",
        "health_workout_versions",
        "health_planned_sessions",
    ):
        assert await _count(initialized_db, table) == 1

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        version = await (
            await db.execute(
                "SELECT version_source, accepted_at FROM health_workout_versions"
            )
        ).fetchone()
        session = await (
            await db.execute(
                "SELECT session_source, status FROM health_planned_sessions"
            )
        ).fetchone()
        transcript_tables = await (
            await db.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' "
                "AND name LIKE 'health_coach%transcript%'"
            )
        ).fetchall()
    assert version["version_source"] == "coach"
    assert version["accepted_at"] is not None
    assert dict(session) == {"session_source": "coach", "status": "scheduled"}
    assert transcript_tables == []


async def test_proposal_undo_refuses_descendant_edits_and_handles_partial_repeats(
    client, adult_a_headers, initialized_db, monkeypatch
):
    async def propose_run(**_kwargs):
        return FitnessHermesResponse(
            answer="Here is the run draft.",
            proposal=FitnessHermesProposal(
                kind="run_workout", payload=_run_proposal()
            ),
            provider="openai-codex",
            model="fitness-test",
        )

    monkeypatch.setattr(
        "app.routers.fitness_coach.ask_fitness_coach", propose_run
    )

    async def create_and_confirm() -> tuple[str, list[str]]:
        drafted = await client.post(
            "/api/fitness/coach/message",
            headers=adult_a_headers,
            json={"message": "Draft a run", "intent": "run_plan"},
        )
        proposal_id = drafted.json()["proposal"]["id"]
        confirmed = await client.post(
            f"/api/fitness/coach/proposals/{proposal_id}/confirm",
            headers=adult_a_headers,
        )
        assert confirmed.status_code == 200, confirmed.text
        return proposal_id, confirmed.json()["result_ids"]

    edited_proposal, edited_ids = await create_and_confirm()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_run_workout_steps SET instruction_text = ?, updated_at = ? "
            "WHERE workout_version_id = ?",
            (
                "A user edit that must survive",
                (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat(),
                edited_ids[1],
            ),
        )
        await db.commit()
    conflict = await client.post(
        f"/api/fitness/coach/proposals/{edited_proposal}/undo",
        headers=adult_a_headers,
    )
    assert conflict.status_code == 200, conflict.text
    assert conflict.json()["status"] == "conflict"
    assert await _count(initialized_db, "health_workout_definitions") == 1

    partial_proposal, partial_ids = await create_and_confirm()
    deleted_at = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_planned_sessions SET deleted_at = ?, updated_at = ?, "
            "revision = revision + 1 WHERE id = ?",
            (deleted_at, deleted_at, partial_ids[2]),
        )
        await db.commit()
    undone = await client.post(
        f"/api/fitness/coach/proposals/{partial_proposal}/undo",
        headers=adult_a_headers,
    )
    assert undone.status_code == 200, undone.text
    assert undone.json() == {
        "status": "undone",
        "message": "The records created by this proposal were removed.",
        "affected_ids": partial_ids,
    }
    repeated = await client.post(
        f"/api/fitness/coach/proposals/{partial_proposal}/undo",
        headers=adult_a_headers,
    )
    assert repeated.json()["status"] == "already_undone"
    async with aiosqlite.connect(initialized_db) as db:
        remaining = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_workout_definitions "
                "WHERE id = ? AND deleted_at IS NULL",
                (partial_ids[0],),
            )
        ).fetchone()
    assert remaining[0] == 0


async def test_proposal_undo_restores_exact_goal_and_calendar_state(
    client, adult_a_headers, monkeypatch
):
    pending: dict = {}

    async def proposal_response(**_kwargs):
        return FitnessHermesResponse(
            answer="Here is the exact reversible draft.",
            proposal=FitnessHermesProposal(
                kind=pending["kind"], payload=pending["payload"]
            ),
            provider="openai-codex",
            model="fitness-test",
        )

    monkeypatch.setattr(
        "app.routers.fitness_coach.ask_fitness_coach", proposal_response
    )

    async def confirm(kind: str, payload: dict) -> str:
        pending.update(kind=kind, payload=payload)
        drafted = await client.post(
            "/api/fitness/coach/message",
            headers=adult_a_headers,
            json={"message": f"Draft {kind}"},
        )
        proposal_id = drafted.json()["proposal"]["id"]
        result = await client.post(
            f"/api/fitness/coach/proposals/{proposal_id}/confirm",
            headers=adult_a_headers,
        )
        assert result.status_code == 200, result.text
        assert result.json()["status"] == "confirmed"
        return proposal_id

    goal_id = str(uuid.uuid4())
    goal = await client.post(
        "/api/fitness/goals",
        headers=adult_a_headers,
        json={
            "id": goal_id,
            "goal_type": "running",
            "metric_key": "running.5k_seconds",
            "name": "Five kilometre",
            "target_value": 1500,
            "unit_key": "s",
            "starts_on": "2026-08-01",
            "target_date": "2026-10-01",
        },
    )
    assert goal.status_code == 201, goal.text
    goal_proposal = await confirm(
        "goal_adjustment",
        {
            "action_type": "adjust_target",
            "goal_id": goal_id,
            "goal_name": "Five kilometre",
            "current_target_value": 1500,
            "proposed_target_value": 1470,
            "current_target_date": "2026-10-01",
            "proposed_target_date": "2026-10-15",
            "unit_key": "s",
            "reason": "Use a realistic progression window.",
        },
    )
    goal_undo = await client.post(
        f"/api/fitness/coach/proposals/{goal_proposal}/undo",
        headers=adult_a_headers,
    )
    assert goal_undo.json()["status"] == "undone"
    goals = await client.get("/api/fitness/goals", headers=adult_a_headers)
    restored_goal = next(item for item in goals.json() if item["id"] == goal_id)
    assert restored_goal["target_value"] == 1500
    assert restored_goal["target_date"] == "2026-10-01"
    assert (
        await client.post(
            f"/api/fitness/coach/proposals/{goal_proposal}/undo",
            headers=adult_a_headers,
        )
    ).json()["status"] == "already_undone"

    plan_id = str(uuid.uuid4())
    plan = await client.post(
        "/api/fitness/planned-sessions",
        headers=adult_a_headers,
        json={
            "id": plan_id,
            "sport_key": "running",
            "title": "Windowed run",
            "local_timezone": "Europe/London",
            "status": "scheduled",
            "session_source": "user",
            "scheduled_date": "2026-08-08",
            "time_window_start_utc": "2026-08-08T07:00:00+00:00",
            "time_window_end_utc": "2026-08-08T09:00:00+00:00",
        },
    )
    assert plan.status_code == 201, plan.text
    calendar_proposal = await confirm(
        "calendar_change",
        {
            "planned_session_id": plan_id,
            "title": "Windowed run",
            "current_start_utc": None,
            "current_scheduled_date": "2026-08-08",
            "current_window_start_utc": "2026-08-08T07:00:00+00:00",
            "current_window_end_utc": "2026-08-08T09:00:00+00:00",
            "proposed_start_utc": "2026-08-08T10:00:00+00:00",
            "reason": "Avoid a family commitment.",
        },
    )
    calendar_undo = await client.post(
        f"/api/fitness/coach/proposals/{calendar_proposal}/undo",
        headers=adult_a_headers,
    )
    assert calendar_undo.json()["status"] == "undone"
    planned = await client.get("/api/fitness/planned-sessions", headers=adult_a_headers)
    restored_plan = next(item for item in planned.json() if item["id"] == plan_id)
    assert restored_plan["scheduled_start_utc"] is None
    assert restored_plan["scheduled_date"] == "2026-08-08"
    assert restored_plan["time_window_start_utc"] == "2026-08-08T07:00:00+00:00"
    assert restored_plan["time_window_end_utc"] == "2026-08-08T09:00:00+00:00"


async def test_validation_feedback_decline_and_expiry_are_deterministic(
    client, adult_a_headers, initialized_db, monkeypatch
):
    responses = [
        FitnessHermesResponse(
            answer="This draft still needs deterministic validation.",
            recommendation=FitnessHermesRecommendation(
                recommendation_type="fuel_consistency",
                recommendation_text="Compare complete breakfast logs for one week.",
                expected_effect="Reduce uncertainty before changing intake.",
            ),
            proposal=FitnessHermesProposal(
                kind="nutrition_change",
                payload={
                    "food_or_meal": "Breakfast",
                    "observation_period": "Seven days",
                    "proposed_change": "Add a protein source.",
                    "expected_effect": "Test satiety.",
                    "uncertainty": "Three days are incomplete.",
                    "unregistered_action": "write now",
                },
            ),
            provider="openai-codex",
            model="fitness-test",
        ),
        FitnessHermesResponse(
            answer="Here is a review-only nutrition draft.",
            proposal=FitnessHermesProposal(
                kind="nutrition_change",
                payload={
                    "food_or_meal": "Breakfast",
                    "observation_period": "Seven days",
                    "proposed_change": "Add a protein source.",
                    "expected_effect": "Test satiety.",
                    "uncertainty": "Evidence is limited.",
                },
            ),
            provider="openai-codex",
            model="fitness-test",
        ),
        FitnessHermesResponse(
            answer="Your earlier feedback is included in the evidence.",
            provider="openai-codex",
            model="fitness-test",
        ),
    ]

    async def next_response(**_kwargs):
        return responses.pop(0)

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", next_response)
    first = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Review my breakfast", "intent": "discussion"},
    )
    assert first.status_code == 200, first.text
    invalid = first.json()["proposal"]
    assert invalid["validation"]["valid"] is False
    assert invalid["validation"]["issues"][0]["code"] == "extra_forbidden"
    rejected_confirm = await client.post(
        f"/api/fitness/coach/proposals/{invalid['id']}/confirm", headers=adult_a_headers
    )
    assert rejected_confirm.json()["status"] == "invalid"

    recommendation = first.json()["recommendation"]
    feedback = await client.post(
        f"/api/fitness/coach/recommendations/{recommendation['id']}/feedback",
        headers=adult_a_headers,
        json={
            "feedback": "tried_worked",
            "followed_state": "followed_once",
            "outcome_review": "It kept me fuller until lunch.",
        },
    )
    assert feedback.status_code == 200
    assert feedback.json()["model_provider"] == "openai-codex"
    assert feedback.json()["model_id"] == "fitness-test"
    assert feedback.json()["status"] == "followed"

    second = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Suggest another breakfast test", "intent": "discussion"},
    )
    draft_id = second.json()["proposal"]["id"]
    declined = await client.post(
        f"/api/fitness/coach/proposals/{draft_id}/decline", headers=adult_a_headers
    )
    assert declined.json()["status"] == "declined"
    assert await _count(initialized_db, "health_planned_sessions") == 0

    third = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Use my previous feedback", "intent": "discussion"},
    )
    assert any(
        item["id"] == "recommendation-history" for item in third.json()["evidence"]
    )

    expired_at = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_coach_proposals SET status = 'pending', expires_at = ? "
            "WHERE id = ?",
            (expired_at, draft_id),
        )
        await db.commit()
    expired = await client.post(
        f"/api/fitness/coach/proposals/{draft_id}/confirm", headers=adult_a_headers
    )
    assert expired.json()["status"] == "expired"


async def test_all_typed_coach_actions_confirm_and_prose_stays_review_only(
    client, adult_a_headers, initialized_db, monkeypatch
):
    pending: dict = {}

    async def proposal_response(**_kwargs):
        return FitnessHermesResponse(
            answer="Here is the exact draft for review.",
            proposal=FitnessHermesProposal(
                kind=pending["kind"], payload=pending["payload"]
            ),
            provider="openai-codex",
            model="fitness-test",
        )

    monkeypatch.setattr(
        "app.routers.fitness_coach.ask_fitness_coach", proposal_response
    )

    async def draft_and_confirm(kind: str, payload: dict) -> dict:
        pending.update({"kind": kind, "payload": payload})
        drafted = await client.post(
            "/api/fitness/coach/message",
            headers=adult_a_headers,
            json={"message": f"Draft {kind}", "intent": "discussion"},
        )
        assert drafted.status_code == 200, drafted.text
        proposal = drafted.json()["proposal"]
        assert proposal["validation"]["valid"] is True
        assert proposal["confirmable"] is True
        confirmed = await client.post(
            f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
            headers=adult_a_headers,
        )
        assert confirmed.status_code == 200, confirmed.text
        assert confirmed.json()["status"] == "confirmed"
        return confirmed.json()

    exercise = (
        await client.get("/api/fitness/exercises", headers=adult_a_headers)
    ).json()[0]
    setup = exercise["setups"][0]

    week = await draft_and_confirm(
        "training_week",
        {
            "name": "Simple week",
            "purpose": "Build consistency.",
            "starts_on": "2026-08-03",
            "local_timezone": "Europe/London",
            "sessions": [
                {
                    "title": "Easy run",
                    "sport_key": "running",
                    "scheduled_date": "2026-08-04",
                    "expected_duration_s": 1800,
                    "purpose": "Easy aerobic work.",
                    "steps": [
                        {
                            "sequence": 0,
                            "duration_type": "time_s",
                            "duration_value": 1800,
                            "target_type": "none",
                            "display_name": "Easy running",
                        }
                    ],
                },
                {
                    "title": "Strength",
                    "sport_key": "strength",
                    "scheduled_date": "2026-08-06",
                    "expected_duration_s": 2400,
                    "purpose": "Maintain strength.",
                    "exercises": [
                        {
                            "exercise_id": exercise["id"],
                            "exercise_name": exercise["name"],
                            "exercise_setup_id": setup["id"],
                            "setup_name": setup["name"],
                            "sequence": 0,
                            "sets": [
                                {
                                    "sequence": 0,
                                    "training_role": "working",
                                    "reps_min": 5,
                                    "reps_max": 8,
                                }
                            ],
                        }
                    ],
                },
            ],
        },
    )
    assert len(week["result_ids"]) == 6
    assert [item["target"] for item in week["next_destinations"]] == [
        week["result_ids"][2],
        week["result_ids"][5],
    ]
    assert all(
        item["kind"] == "planned_session" for item in week["next_destinations"]
    )

    goal_id = str(uuid.uuid4())
    goal = await client.post(
        "/api/fitness/goals",
        headers=adult_a_headers,
        json={
            "id": goal_id,
            "goal_type": "running",
            "metric_key": "running.5k_seconds",
            "name": "Faster 5 km",
            "target_value": 1500,
            "unit_key": "s",
            "starts_on": "2026-08-01",
            "target_date": "2026-10-01",
        },
    )
    assert goal.status_code == 201, goal.text
    await draft_and_confirm(
        "goal_adjustment",
        {
            "action_type": "adjust_target",
            "goal_id": goal_id,
            "goal_name": "Faster 5 km",
            "current_target_value": 1500,
            "proposed_target_value": 1470,
            "current_target_date": "2026-10-01",
            "proposed_target_date": "2026-10-15",
            "unit_key": "s",
            "reason": "Use the more realistic progression window.",
        },
    )

    plan_id = str(uuid.uuid4())
    plan = await client.post(
        "/api/fitness/planned-sessions",
        headers=adult_a_headers,
        json={
            "id": plan_id,
            "sport_key": "running",
            "title": "Tempo run",
            "local_timezone": "Europe/London",
            "status": "scheduled",
            "session_source": "user",
            "scheduled_start_utc": "2026-08-08T08:00:00+00:00",
        },
    )
    assert plan.status_code == 201, plan.text
    await draft_and_confirm(
        "calendar_change",
        {
            "planned_session_id": plan_id,
            "title": "Tempo run",
            "current_start_utc": "2026-08-08T08:00:00+00:00",
            "proposed_start_utc": "2026-08-08T10:00:00+00:00",
            "reason": "Avoid the earlier family commitment.",
        },
    )

    await draft_and_confirm(
        "nutrition_change",
        {
            "action_type": "nutrition_target",
            "food_or_meal": "Daily protein",
            "observation_period": "Next four weeks",
            "proposed_change": "Track a 130 g daily target.",
            "expected_effect": "Support recovery.",
            "nutrition_target": {
                "metric_key": "nutrition.protein_g",
                "target_type": "fixed",
                "target_value": 130,
                "effective_from": "2026-08-03",
            },
        },
    )
    await draft_and_confirm(
        "nutrition_change",
        {
            "action_type": "meal_template",
            "food_or_meal": "Post-workout meal",
            "observation_period": "Training days",
            "proposed_change": "Save an editable meal template.",
            "expected_effect": "Make consistent logging easier.",
            "meal_template": {
                "name": "Post-workout meal",
                "meal_key": "post_workout",
                "items": [],
            },
        },
    )

    pending.update(
        {
            "kind": "nutrition_change",
            "payload": {
                "food_or_meal": "Breakfast",
                "observation_period": "One week",
                "proposed_change": "Review protein consistency.",
                "expected_effect": "Learn before changing a target.",
            },
        }
    )
    review = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Review breakfast", "intent": "evening"},
    )
    assert review.status_code == 200, review.text
    proposal = review.json()["proposal"]
    assert proposal["confirmable"] is False
    assert proposal["review_only_reason"]

    async with aiosqlite.connect(initialized_db) as db:
        goal_row = await (
            await db.execute(
                "SELECT target_value, target_date FROM health_goals WHERE id = ?",
                (goal_id,),
            )
        ).fetchone()
        plan_row = await (
            await db.execute(
                "SELECT scheduled_start_utc FROM health_planned_sessions WHERE id = ?",
                (plan_id,),
            )
        ).fetchone()
        targets = await (
            await db.execute("SELECT COUNT(*) FROM health_nutrition_targets")
        ).fetchone()
        templates = await (
            await db.execute("SELECT COUNT(*) FROM health_meal_templates")
        ).fetchone()
        week_definitions = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_workout_definitions WHERE id IN (?, ?)",
                (week["result_ids"][0], week["result_ids"][3]),
            )
        ).fetchone()
        run_steps = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_run_workout_steps WHERE workout_version_id = ?",
                (week["result_ids"][1],),
            )
        ).fetchone()
        strength_exercises = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_strength_workout_exercises "
                "WHERE workout_version_id = ?",
                (week["result_ids"][4],),
            )
        ).fetchone()
    assert goal_row == (1470.0, "2026-10-15")
    assert plan_row[0] == "2026-08-08T10:00:00+00:00"
    assert targets[0] == 1
    assert templates[0] == 1
    assert week_definitions[0] == 2
    assert run_steps[0] == 1
    assert strength_exercises[0] == 1


async def test_weekly_review_marker_is_deterministic_and_idempotent(
    client, adult_a_headers, initialized_db
):
    preferences = await client.get(
        "/api/fitness/coach/preferences", headers=adult_a_headers
    )
    assert preferences.status_code == 200
    reference = datetime(2026, 8, 2, 6, tzinfo=timezone.utc)
    async with standalone_db(initialized_db) as db:
        assert await ensure_weekly_review_markers(db, reference=reference) == 1
        assert await ensure_weekly_review_markers(db, reference=reference) == 0
        await db.commit()
    recommendations = await client.get(
        "/api/fitness/coach/recommendations", headers=adult_a_headers
    )
    assert recommendations.status_code == 200
    markers = [
        item
        for item in recommendations.json()
        if item["recommendation_type"] == "weekly_review_draft"
    ]
    assert len(markers) == 1
    assert markers[0]["model_provider"] == "deterministic"
    assert markers[0]["expected_effect"] == {"week_start": "2026-07-27"}


async def test_coach_calendar_context_excludes_a_cancelled_recurrence(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
):
    event = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "Family breakfast",
            "start_time": "2026-08-03T07:00:00+01:00",
            "end_time": "2026-08-03T08:00:00+01:00",
            "recurrence_rule": "FREQ=DAILY;COUNT=2",
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

    async with standalone_db(initialized_db) as db:
        context = await _family_calendar_context(
            db,
            user=adult_a_user,
            reference=datetime(2026, 8, 3, 0, tzinfo=timezone.utc),
        )

    assert context is not None
    events = context["facts"]["events"]
    assert len(events) == 1
    assert events[0]["title"] == "Family breakfast"
    assert events[0]["start_time"].startswith("2026-08-04T06:00:00")


async def test_coach_memory_opt_in_resume_candidates_privacy_export_and_clear(
    client,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    monkeypatch,
):
    calls = []
    responses = [
        FitnessHermesResponse(
            answer="Memory is still off.",
            memory_candidates=[
                {"content": "Prefers weekday runs.", "category": "schedule"}
            ],
            provider="openai-codex",
            model="fitness-test",
        ),
        None,
        FitnessHermesResponse(
            answer="I can remember that only if you confirm the candidate.",
            memory_candidates=[
                {
                    "content": "Prefers short weekday runs before breakfast.",
                    "category": "training_schedule",
                }
            ],
            provider="openai-codex",
            model="fitness-test",
        ),
        FitnessHermesResponse(
            answer="This one-shot answer is not stored.",
            recommendation=FitnessHermesRecommendation(
                recommendation_type="chart_explanation",
                recommendation_text="This must remain page-only.",
            ),
            proposal=FitnessHermesProposal(
                kind="chart",
                payload={"title": "Page-only chart draft"},
            ),
            memory_candidates=[
                {"content": "Do not retain this candidate.", "category": "private"}
            ],
            provider="openai-codex",
            model="fitness-test",
        ),
        FitnessHermesResponse(
            answer="Your confirmed weekday preference is relevant.",
            provider="openai-codex",
            model="fitness-test",
        ),
        FitnessHermesResponse(
            answer="This memory-off answer is not stored.",
            memory_candidates=[
                {"content": "Do not display this.", "category": "private"}
            ],
            provider="openai-codex",
            model="fitness-test",
        ),
        FitnessHermesResponse(
            answer="This starts a conversation after clearing while disabled.",
            provider="openai-codex",
            model="fitness-test",
        ),
        FitnessHermesResponse(
            answer="This starts a fresh conversation after clearing while enabled.",
            provider="openai-codex",
            model="fitness-test",
        ),
    ]

    async def memory_coach(**kwargs):
        calls.append(kwargs)
        return responses.pop(0)

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", memory_coach)
    preferences = await client.get(
        "/api/fitness/coach/preferences", headers=adult_a_headers
    )
    assert preferences.json()["coach_memory_enabled"] is False

    memory_off = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "Use this request only.",
            "history": [{"role": "user", "content": "Client-only history."}],
        },
    )
    assert memory_off.status_code == 200, memory_off.text
    assert memory_off.json()["conversation_id"] is None
    assert memory_off.json()["memory_candidates"] == []
    assert calls[0]["history"][0].content == "Client-only history."
    assert calls[0]["memories"] == []
    assert await _count(initialized_db, "health_coach_conversations") == 0
    assert await _count(initialized_db, "health_coach_messages") == 0
    assert await _count(initialized_db, "health_coach_memories") == 0

    enabled = await client.put(
        "/api/fitness/coach/memory/settings",
        headers=adult_a_headers,
        json={"enabled": True},
    )
    assert enabled.status_code == 200
    assert enabled.json()["enabled"] is True
    assert enabled.json()["enabled_at"] is not None
    assert len(calls) == 1  # The opt-in toggle never invokes Hermes.

    unavailable = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "This failed request must not be stored."},
    )
    assert unavailable.json()["status"] == "unavailable"
    assert unavailable.json()["conversation_id"] is None
    assert await _count(initialized_db, "health_coach_conversations") == 0
    assert await _count(initialized_db, "health_coach_messages") == 0

    first = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "I prefer short weekday runs before breakfast."},
    )
    assert first.status_code == 200, first.text
    conversation_id = first.json()["conversation_id"]
    candidate = first.json()["memory_candidates"][0]
    assert conversation_id
    assert await _count(initialized_db, "health_coach_conversations") == 1
    assert await _count(initialized_db, "health_coach_messages") == 2
    assert await _count(initialized_db, "health_coach_memories") == 0

    one_shot = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "Explain this chart without retaining the exchange.",
            "history": [{"role": "assistant", "content": "Page-only context."}],
            "ephemeral": True,
        },
    )
    assert one_shot.status_code == 200, one_shot.text
    assert one_shot.json()["conversation_id"] is None
    assert one_shot.json()["memory_candidates"] == []
    assert one_shot.json()["recommendation"] is None
    assert one_shot.json()["proposal"] is None
    assert [turn.content for turn in calls[-1]["history"]] == ["Page-only context."]
    assert calls[-1]["memories"] == []
    assert await _count(initialized_db, "health_coach_conversations") == 1
    assert await _count(initialized_db, "health_coach_messages") == 2
    assert await _count(initialized_db, "health_coach_recommendations") == 0
    assert await _count(initialized_db, "health_coach_proposals") == 0

    invalid_one_shot = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "Do not combine stored and ephemeral state.",
            "conversation_id": conversation_id,
            "ephemeral": True,
        },
    )
    assert invalid_one_shot.status_code == 422
    invalid_one_shot_intent = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "Do not discard an action draft.",
            "intent": "run_plan",
            "ephemeral": True,
        },
    )
    assert invalid_one_shot_intent.status_code == 422

    confirmed = await client.post(
        "/api/fitness/coach/memories",
        headers=adult_a_headers,
        json=candidate,
    )
    assert confirmed.status_code == 201, confirmed.text
    memory_id = confirmed.json()["id"]
    edited = await client.patch(
        f"/api/fitness/coach/memories/{memory_id}",
        headers=adult_a_headers,
        json={"content": "Prefers short weekday runs before breakfast."},
    )
    assert edited.status_code == 200
    assert edited.json()["revision"] == 2

    model_calls_before_cross_user = len(calls)
    assert (
        await client.get(
            f"/api/fitness/coach/conversations/{conversation_id}",
            headers=adult_b_headers,
        )
    ).status_code == 404
    cross_continue = await client.post(
        "/api/fitness/coach/message",
        headers=adult_b_headers,
        json={"message": "Continue this", "conversation_id": conversation_id},
    )
    assert cross_continue.status_code == 404
    assert len(calls) == model_calls_before_cross_user
    assert (
        await client.delete(
            f"/api/fitness/coach/conversations/{conversation_id}",
            headers=adult_b_headers,
        )
    ).status_code == 404
    assert (
        await client.patch(
            f"/api/fitness/coach/memories/{memory_id}",
            headers=adult_b_headers,
            json={"content": "not mine"},
        )
    ).status_code == 404
    assert (
        await client.delete(
            f"/api/fitness/coach/memories/{memory_id}", headers=adult_b_headers
        )
    ).status_code == 404

    resumed = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "What is my weekday preference?",
            "conversation_id": conversation_id,
            "history": [{"role": "user", "content": "Ignore server history."}],
        },
    )
    assert resumed.status_code == 200, resumed.text
    assert resumed.json()["conversation_id"] == conversation_id
    assert [turn.content for turn in calls[-1]["history"]] == [
        "I prefer short weekday runs before breakfast.",
        "I can remember that only if you confirm the candidate.",
    ]
    assert calls[-1]["memories"] == [
        {
            "content": "Prefers short weekday runs before breakfast.",
            "category": "training_schedule",
        }
    ]
    detail = await client.get(
        f"/api/fitness/coach/conversations/{conversation_id}", headers=adult_a_headers
    )
    assert detail.status_code == 200
    assert [item["sequence"] for item in detail.json()["messages"]] == [1, 2, 3, 4]
    adult_a_message_ids = {item["id"] for item in detail.json()["messages"]}

    explicit = await client.post(
        "/api/fitness/coach/conversations",
        headers=adult_a_headers,
        json={"title": "Temporary private thread"},
    )
    assert explicit.status_code == 201
    explicit_id = explicit.json()["id"]
    spare_memory = await client.post(
        "/api/fitness/coach/memories",
        headers=adult_a_headers,
        json={"content": "A disposable confirmed note.", "category": "test"},
    )
    assert spare_memory.status_code == 201
    spare_memory_id = spare_memory.json()["id"]

    disabled = await client.put(
        "/api/fitness/coach/memory/settings",
        headers=adult_a_headers,
        json={"enabled": False},
    )
    assert disabled.json() == {"enabled": False, "enabled_at": None}
    # Turning retention off never makes existing owner-private data inaccessible.
    assert (
        await client.get(
            f"/api/fitness/coach/conversations/{conversation_id}",
            headers=adult_a_headers,
        )
    ).status_code == 200
    assert {
        item["id"]
        for item in (
            await client.get("/api/fitness/coach/memories", headers=adult_a_headers)
        ).json()
    } == {memory_id, spare_memory_id}
    assert (
        await client.delete(
            f"/api/fitness/coach/conversations/{explicit_id}", headers=adult_a_headers
        )
    ).status_code == 204
    assert (
        await client.delete(
            f"/api/fitness/coach/memories/{spare_memory_id}", headers=adult_a_headers
        )
    ).status_code == 204
    assert (
        await client.get(
            f"/api/fitness/coach/conversations/{explicit_id}", headers=adult_a_headers
        )
    ).status_code == 404
    counts_before_ephemeral = {
        table: await _count(initialized_db, table)
        for table in (
            "health_coach_conversations",
            "health_coach_messages",
            "health_coach_memories",
        )
    }
    ephemeral = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "Memory is off again.",
            "history": [{"role": "assistant", "content": "Client-held context."}],
        },
    )
    assert ephemeral.status_code == 200, ephemeral.text
    assert ephemeral.json()["conversation_id"] is None
    assert ephemeral.json()["memory_candidates"] == []
    assert [turn.content for turn in calls[-1]["history"]] == ["Client-held context."]
    assert calls[-1]["memories"] == []
    assert {
        table: await _count(initialized_db, table)
        for table in counts_before_ephemeral
    } == counts_before_ephemeral

    adult_a_export = await client.get("/api/fitness/export", headers=adult_a_headers)
    adult_b_export = await client.get("/api/fitness/export", headers=adult_b_headers)
    for response, should_contain in ((adult_a_export, True), (adult_b_export, False)):
        with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
            exported = json.loads(archive.read("fitness-data.json"))
        exported_ids = {
            row["id"]
            for table in (
                "health_coach_conversations",
                "health_coach_messages",
                "health_coach_memories",
            )
            for row in exported["tables"][table]
        }
        assert ((conversation_id in exported_ids) is should_contain)
        assert (bool(adult_a_message_ids & exported_ids) is should_contain)
        assert ((memory_id in exported_ids) is should_contain)

    cleared = await client.post(
        "/api/fitness/coach/memory/clear", headers=adult_a_headers
    )
    assert cleared.status_code == 200
    assert cleared.json() == {"conversations": 1, "messages": 4, "memories": 1}
    assert (await client.get("/api/fitness/coach/conversations", headers=adult_a_headers)).json() == []
    assert (await client.get("/api/fitness/coach/memories", headers=adult_a_headers)).json() == []
    assert (
        await client.get("/api/fitness/coach/memory/settings", headers=adult_a_headers)
    ).json()["enabled"] is False

    reenabled = await client.put(
        "/api/fitness/coach/memory/settings",
        headers=adult_a_headers,
        json={"enabled": True},
    )
    assert reenabled.json()["enabled"] is True

    after_disabled_clear = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Start fresh after clearing."},
    )
    assert after_disabled_clear.status_code == 200, after_disabled_clear.text
    after_disabled_id = after_disabled_clear.json()["conversation_id"]
    assert after_disabled_id not in {None, conversation_id, explicit_id}

    cleared_while_enabled = await client.post(
        "/api/fitness/coach/memory/clear", headers=adult_a_headers
    )
    assert cleared_while_enabled.json() == {
        "conversations": 1,
        "messages": 2,
        "memories": 0,
    }
    assert (
        await client.get("/api/fitness/coach/memory/settings", headers=adult_a_headers)
    ).json()["enabled"] is True

    fresh = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Start fresh after clearing while enabled."},
    )
    assert fresh.status_code == 200, fresh.text
    assert fresh.json()["conversation_id"] not in {
        None,
        conversation_id,
        explicit_id,
        after_disabled_id,
    }
    assert await _count(initialized_db, "health_coach_messages") == 8
