"""Family-aware Fitness Coach context and deterministic cross-module actions."""

import json
import uuid
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import aiosqlite
import pytest

from app.database import init_db
from app.services.hermes import FitnessHermesProposal, FitnessHermesResponse


pytestmark = pytest.mark.asyncio


def _future(*, days: int = 2, hours: int = 0) -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0) + timedelta(days=days, hours=hours)


def _short_date(value: date) -> str:
    weekdays = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    months = (
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    )
    return f"{weekdays[value.weekday()]} {value.day} {months[value.month - 1]} {value.year}"


def _short_datetime(value: datetime, *, timezone_name: str | None = None) -> str:
    displayed = value.astimezone(ZoneInfo(timezone_name)) if timezone_name else value
    return f"{_short_date(displayed.date())}, {displayed:%H:%M} {displayed.tzname()}"


async def test_family_context_is_opt_in_owner_scoped_and_removed_immediately(
    client,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    monkeypatch,
):
    assert (
        await client.get("/api/fitness/coach/context-preferences", headers=adult_a_headers)
    ).json() == {
        "family_calendar": False,
        "household_meals": False,
        "weather": False,
    }
    async with aiosqlite.connect(initialized_db) as db:
        profile_count = (
            await (await db.execute("SELECT COUNT(*) FROM health_onboarding_profiles")).fetchone()
        )[0]
    assert profile_count == 0

    weather_calls = 0

    async def weather():
        nonlocal weather_calls
        weather_calls += 1
        return {
            "description": "light rain",
            "temp_high": 17.0,
            "temp_low": 9.0,
            "rain_chance": 70,
        }

    monkeypatch.setattr("app.services.fitness.coach.get_weather_summary", weather)
    updated = await client.patch(
        "/api/fitness/coach/context-preferences",
        headers=adult_a_headers,
        json={"family_calendar": True, "weather": True},
    )
    assert updated.status_code == 200
    assert updated.json() == {
        "family_calendar": True,
        "household_meals": False,
        "weather": True,
    }
    assert weather_calls == 0
    assert (
        await client.get("/api/fitness/coach/context-preferences", headers=adult_b_headers)
    ).json() == {
        "family_calendar": False,
        "household_meals": False,
        "weather": False,
    }

    start = _future(days=1)
    event = await client.post(
        "/api/calendar/",
        headers=adult_a_headers,
        json={
            "title": "School concert",
            "start_time": start.isoformat(),
            "end_time": (start + timedelta(hours=2)).isoformat(),
        },
    )
    assert event.status_code == 201, event.text

    contexts: list[dict] = []

    async def answer(**kwargs):
        contexts.append(kwargs["context"])
        return FitnessHermesResponse(
            answer="Keep the session clear of the concert.",
            provider="test",
            model="test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", answer)
    first = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "Fit my run around the family week.",
            "intent": "run_plan",
            "timezone": "Europe/Berlin",
            "client_now": datetime.now(timezone.utc).isoformat(),
        },
    )
    assert first.status_code == 200, first.text
    assert weather_calls == 1
    kinds = {item["kind"] for item in contexts[-1]["evidence"]}
    assert {"family_calendar", "weather"} <= kinds
    calendar = next(item for item in contexts[-1]["evidence"] if item["kind"] == "family_calendar")
    assert calendar["facts"]["events"][0]["title"] == "School concert"
    assert "description" not in calendar["facts"]["events"][0]

    disabled = await client.patch(
        "/api/fitness/coach/context-preferences",
        headers=adult_a_headers,
        json={"family_calendar": False, "weather": False},
    )
    assert disabled.status_code == 200
    second = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "What should I train?", "intent": "discussion"},
    )
    assert second.status_code == 200
    assert weather_calls == 1
    kinds = {item["kind"] for item in contexts[-1]["evidence"]}
    assert "family_calendar" not in kinds
    assert "weather" not in kinds


async def test_cross_module_actions_confirm_once_and_undo_once(
    client,
    adult_a_headers,
    adult_b_headers,
    other_family_headers,
    initialized_db,
    monkeypatch,
):
    session_start = _future(days=2)
    session_id = str(uuid.uuid4())
    session = await client.post(
        "/api/fitness/planned-sessions",
        headers=adult_a_headers,
        json={
            "id": session_id,
            "sport_key": "running",
            "title": "Easy run",
            "local_timezone": "Europe/Berlin",
            "status": "scheduled",
            "session_source": "user",
            "scheduled_start_utc": session_start.isoformat(),
        },
    )
    assert session.status_code == 201, session.text

    proposals = {
        "calendar": (
            "family_calendar_event",
            {
                "title": "Alex training",
                "start_time": session_start.isoformat(),
                "end_time": (session_start + timedelta(hours=1)).isoformat(),
                "all_day": False,
                "location": "Home",
                "planned_session_id": session_id,
                "family_visible": True,
            },
            "calendar_events",
        ),
        "shopping": (
            "shopping_list",
            {
                "items": [
                    {"name": "Bananas", "quantity": "6", "category": "Fruit"},
                    {"name": "Resistance band", "quantity": "1", "category": "Gear"},
                ],
                "family_visible": True,
            },
            "shopping_items",
        ),
        "task": (
            "family_task",
            {
                "title": "Put the running buggy by the door",
                "description": "Needed for tomorrow's run.",
                "due_date": _future(days=1).isoformat(),
                "priority": 2,
                "family_visible": True,
            },
            "tasks",
        ),
        "reminder": (
            "fitness_reminder",
            {
                "title": "Pack running shoes",
                "remind_at_utc": _future(days=1).isoformat(),
                "planned_session_id": session_id,
                "private_to_you": True,
            },
            "health_fitness_reminders",
        ),
    }

    async def propose(**kwargs):
        kind, payload, _ = proposals[kwargs["message"]]
        return FitnessHermesResponse(
            answer="Review this exact change, then confirm it if it is right.",
            proposal=FitnessHermesProposal(kind=kind, payload=payload),
            provider="test",
            model="test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", propose)

    expected_visibility = {
        "family_calendar_event": "Visible to your family",
        "planned_meal_log": "Private to you",
        "shopping_list": "Visible to your family",
        "family_task": "Visible to your family",
        "fitness_reminder": "Private to you",
    }

    for index, (message, (kind, _payload, table)) in enumerate(proposals.items()):
        drafted = await client.post(
            "/api/fitness/coach/message",
            headers=adult_a_headers,
            json={"message": message, "intent": "discussion"},
        )
        assert drafted.status_code == 200, drafted.text
        proposal = drafted.json()["proposal"]
        assert proposal["kind"] == kind
        assert proposal["validation"] == {"valid": True, "issues": []}
        assert set(proposal["preview"]) == {"change", "visibility"}
        assert proposal["preview"]["visibility"] == expected_visibility[kind]
        assert proposal["preview"]["change"]
        assert all(isinstance(line, str) and line.strip() for line in proposal["preview"]["change"])
        preview_json = json.dumps(proposal["preview"])
        assert "evidence" not in preview_json
        assert "_id" not in preview_json
        assert session_id not in preview_json
        if kind == "family_calendar_event":
            assert proposal["payload"]["title"] == "Training"
            assert proposal["preview"]["change"][0] == "Add “Training” to Calendar"
            assert proposal["preview"]["change"][1] == (f"Starts {_short_datetime(session_start)}")
            assert _payload["start_time"] not in preview_json
            assert _payload["end_time"] not in preview_json
        elif kind == "family_task":
            assert proposal["payload"]["priority"] == 2
            assert proposal["preview"]["change"][-1] == "Priority Normal"
            assert _payload["due_date"] not in preview_json
        elif kind == "fitness_reminder":
            assert _payload["remind_at_utc"] not in preview_json

        async with aiosqlite.connect(initialized_db) as db:
            count_before = (
                await (
                    await db.execute(f"SELECT COUNT(*) FROM {table} WHERE deleted_at IS NULL")
                ).fetchone()
            )[0]
        assert count_before == 0
        if index == 0:
            hidden = await client.post(
                f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
                headers=adult_b_headers,
            )
            assert hidden.status_code == 404

        first = await client.post(
            f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
            headers=adult_a_headers,
        )
        replay = await client.post(
            f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
            headers=adult_a_headers,
        )
        assert first.status_code == replay.status_code == 200
        assert first.json()["status"] == replay.json()["status"] == "confirmed"
        assert first.json()["result_ids"] == replay.json()["result_ids"]
        result_ids = first.json()["result_ids"]
        assert len(result_ids) == (2 if kind == "shopping_list" else 1)

        async with aiosqlite.connect(initialized_db) as db:
            placeholders = ",".join("?" for _ in result_ids)
            rows = await (
                await db.execute(
                    f"SELECT * FROM {table} WHERE id IN ({placeholders})",
                    result_ids,
                )
            ).fetchall()
        assert len(rows) == len(result_ids)

        if kind == "family_calendar_event":
            family_calendar = await client.get(
                "/api/calendar/",
                params={
                    "start": (session_start - timedelta(hours=1)).isoformat(),
                    "end": (session_start + timedelta(hours=2)).isoformat(),
                },
                headers=adult_b_headers,
            )
            assert result_ids[0] in {item["id"] for item in family_calendar.json()}
            isolated = await client.get(
                "/api/calendar/",
                params={
                    "start": (session_start - timedelta(hours=1)).isoformat(),
                    "end": (session_start + timedelta(hours=2)).isoformat(),
                },
                headers=other_family_headers,
            )
            assert result_ids[0] not in {item["id"] for item in isolated.json()}
        elif kind == "shopping_list":
            shared = await client.get("/api/meals/shopping", headers=adult_b_headers)
            assert set(result_ids) <= {item["id"] for item in shared.json()}
            isolated = await client.get("/api/meals/shopping", headers=other_family_headers)
            assert set(result_ids).isdisjoint({item["id"] for item in isolated.json()})
        elif kind == "family_task":
            shared = await client.get("/api/tasks/", headers=adult_b_headers)
            assert result_ids[0] in {item["id"] for item in shared.json()}
            isolated = await client.get("/api/tasks/", headers=other_family_headers)
            assert result_ids[0] not in {item["id"] for item in isolated.json()}
        elif kind == "fitness_reminder":
            private = await client.get("/api/fitness/coach/reminders", headers=adult_a_headers)
            assert result_ids[0] in {item["id"] for item in private.json()}
            for headers in (adult_b_headers, other_family_headers):
                hidden = await client.get("/api/fitness/coach/reminders", headers=headers)
                assert result_ids[0] not in {item["id"] for item in hidden.json()}

        if kind == "family_calendar_event":
            async with aiosqlite.connect(initialized_db) as db:
                await db.execute(
                    "UPDATE health_planned_sessions SET title = ?, updated_at = ? WHERE id = ?",
                    ("Changed after confirmation", _future(days=3).isoformat(), session_id),
                )
                await db.commit()
            replay_after_source_change = await client.post(
                f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
                headers=adult_a_headers,
            )
            assert replay_after_source_change.json()["result_ids"] == result_ids
        elif kind == "fitness_reminder":
            async with aiosqlite.connect(initialized_db) as db:
                await db.execute(
                    "UPDATE health_planned_sessions SET status = 'completed', "
                    "updated_at = ? WHERE id = ?",
                    (_future(days=3).isoformat(), session_id),
                )
                await db.commit()
            replay_after_source_change = await client.post(
                f"/api/fitness/coach/proposals/{proposal['id']}/confirm",
                headers=adult_a_headers,
            )
            assert replay_after_source_change.json()["result_ids"] == result_ids

        undone = await client.post(
            f"/api/fitness/coach/proposals/{proposal['id']}/undo",
            headers=adult_a_headers,
        )
        repeated = await client.post(
            f"/api/fitness/coach/proposals/{proposal['id']}/undo",
            headers=adult_a_headers,
        )
        assert undone.status_code == repeated.status_code == 200
        assert undone.json()["status"] == "undone"
        assert repeated.json()["status"] == "already_undone"


async def test_coach_logs_linked_household_meal_privately_and_revalidates_link(
    client,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    monkeypatch,
):
    meal_date = datetime.now(timezone.utc).date()
    meal = await client.post("/api/meals/", headers=adult_a_headers, json={"name": "Family pasta"})
    assert meal.status_code == 201, meal.text
    meal_id = meal.json()["id"]
    plan = await client.post(
        "/api/meals/plan",
        headers=adult_a_headers,
        json={
            "meal_id": meal_id,
            "date": meal_date.isoformat(),
            "meal_type": "dinner",
        },
    )
    assert plan.status_code == 201, plan.text
    plan_id = plan.json()["id"]
    recipe = await client.post(
        "/api/fitness/recipes",
        headers=adult_a_headers,
        json={
            "name": "Pasta recipe",
            "household_shared": True,
            "version": {
                "servings": 4,
                "finished_weight_g": 800,
                "calories_kcal": 800,
                "protein_g": 80,
            },
        },
    )
    assert recipe.status_code == 201, recipe.text
    recipe_version_id = recipe.json()["versions"][0]["id"]
    link = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=adult_a_headers,
        json={"recipe_version_id": recipe_version_id},
    )
    assert link.status_code == 200, link.text
    link_id = link.json()["id"]
    logged_at = datetime.now(timezone.utc)
    payload = {
        "meal_plan_id": plan_id,
        "meal_name": "Family pasta",
        "link_id": link_id,
        "recipe_version_id": recipe_version_id,
        "portion": 1,
        "unit": "serving",
        "logged_at_utc": logged_at.isoformat(),
        "local_timezone": "Europe/Berlin",
        "private_to_you": True,
    }

    async def propose(**_kwargs):
        return FitnessHermesResponse(
            answer="This will add one serving to your private diary.",
            proposal=FitnessHermesProposal(kind="planned_meal_log", payload=payload),
            provider="test",
            model="test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", propose)
    drafted = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Log dinner", "intent": "discussion"},
    )
    assert drafted.status_code == 200, drafted.text
    draft = drafted.json()["proposal"]
    assert draft["preview"] == {
        "change": [
            "Add 1 serving of Family pasta to your diary",
            f"Dinner planned for {_short_date(meal_date)}",
            f"Logged {_short_datetime(logged_at, timezone_name='Europe/Berlin')}",
        ],
        "visibility": "Private to you",
    }
    assert link_id not in json.dumps(draft["preview"])
    async with aiosqlite.connect(initialized_db) as db:
        count_before = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM health_food_log_entries "
                    "WHERE owner_user_id = ? AND deleted_at IS NULL",
                    ("00000000-0000-0000-0000-000000000001",),
                )
            ).fetchone()
        )[0]
    assert count_before == 0

    original_meal_date = meal_date.isoformat()
    changed_meal_date = (meal_date + timedelta(days=1)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE meal_plans SET date = ?, meal_type = 'lunch', updated_at = ? WHERE id = ?",
            (changed_meal_date, datetime.now(timezone.utc).isoformat(), plan_id),
        )
        await db.commit()
    changed_plan = await client.post(
        f"/api/fitness/coach/proposals/{draft['id']}/confirm",
        headers=adult_a_headers,
    )
    assert changed_plan.status_code == 200
    assert changed_plan.json() == {
        "status": "invalid",
        "message": "The linked source changed. Review a fresh proposal before saving.",
        "result_ids": None,
        "next_destinations": [],
    }
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE meal_plans SET date = ?, meal_type = 'dinner', updated_at = ? WHERE id = ?",
            (original_meal_date, datetime.now(timezone.utc).isoformat(), plan_id),
        )
        await db.commit()

    drafted = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Log dinner", "intent": "discussion"},
    )
    assert drafted.status_code == 200, drafted.text
    draft = drafted.json()["proposal"]

    unlinked = await client.delete(f"/api/fitness/household-meals/{meal_id}", headers=adult_a_headers)
    assert unlinked.status_code == 204
    stale = await client.post(
        f"/api/fitness/coach/proposals/{draft['id']}/confirm",
        headers=adult_a_headers,
    )
    assert stale.status_code == 200
    assert stale.json()["status"] == "invalid"
    async with aiosqlite.connect(initialized_db) as db:
        assert (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM health_food_log_entries "
                    "WHERE owner_user_id = ? AND deleted_at IS NULL",
                    ("00000000-0000-0000-0000-000000000001",),
                )
            ).fetchone()
        )[0] == 0

    relinked = await client.put(
        f"/api/fitness/household-meals/{meal_id}",
        headers=adult_a_headers,
        json={"recipe_version_id": recipe_version_id},
    )
    assert relinked.status_code == 200, relinked.text
    payload["link_id"] = relinked.json()["id"]
    drafted = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Log dinner", "intent": "discussion"},
    )
    assert drafted.status_code == 200, drafted.text
    proposal_id = drafted.json()["proposal"]["id"]
    confirmed = await client.post(
        f"/api/fitness/coach/proposals/{proposal_id}/confirm",
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 200, confirmed.text
    entry_id = confirmed.json()["result_ids"][0]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        row = await (
            await db.execute(
                "SELECT owner_user_id, source_meal_plan_id, household_meal_link_id "
                "FROM health_food_log_entries WHERE id = ?",
                (entry_id,),
            )
        ).fetchone()
    assert row["source_meal_plan_id"] == plan_id
    assert row["household_meal_link_id"] == payload["link_id"]
    adult_b_diary = await client.get(
        "/api/fitness/food-log",
        params={"date": datetime.now(timezone.utc).date().isoformat()},
        headers=adult_b_headers,
    )
    assert adult_b_diary.status_code == 200
    assert adult_b_diary.json()["entries"] == []

    already_logged = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Log dinner", "intent": "discussion"},
    )
    assert already_logged.status_code == 200
    duplicate = already_logged.json()["proposal"]
    assert duplicate["validation"]["valid"] is False
    assert duplicate["confirmable"] is False

    changed_source = await client.delete(
        f"/api/fitness/household-meals/{meal_id}", headers=adult_a_headers
    )
    assert changed_source.status_code == 204
    replay = await client.post(
        f"/api/fitness/coach/proposals/{proposal_id}/confirm",
        headers=adult_a_headers,
    )
    assert replay.status_code == 200
    assert replay.json()["status"] == "confirmed"
    assert replay.json()["result_ids"] == [entry_id]

    undo = await client.post(
        f"/api/fitness/coach/proposals/{proposal_id}/undo", headers=adult_a_headers
    )
    assert undo.status_code == 200
    assert undo.json()["status"] == "undone"
    repeated = await client.post(
        f"/api/fitness/coach/proposals/{proposal_id}/undo", headers=adult_a_headers
    )
    assert repeated.status_code == 200
    assert repeated.json()["status"] == "already_undone"


async def test_household_meal_context_is_explicit_and_never_exposes_another_diary(
    client,
    adult_a_headers,
    adult_b_headers,
    adult_b_user,
    monkeypatch,
):
    meal_date = datetime.now(timezone.utc).date().isoformat()
    meal = await client.post("/api/meals/", headers=adult_a_headers, json={"name": "Family curry"})
    plan = await client.post(
        "/api/meals/plan",
        headers=adult_a_headers,
        json={
            "meal_id": meal.json()["id"],
            "date": meal_date,
            "meal_type": "dinner",
            "notes": "Eat after the school run",
        },
    )
    recipe = await client.post(
        "/api/fitness/recipes",
        headers=adult_a_headers,
        json={
            "name": "Shared curry recipe",
            "household_shared": True,
            "version": {
                "servings": 4,
                "calories_kcal": 1200,
                "protein_g": 80,
            },
        },
    )
    linked = await client.put(
        f"/api/fitness/household-meals/{meal.json()['id']}",
        headers=adult_a_headers,
        json={"recipe_version_id": recipe.json()["versions"][0]["id"]},
    )
    assert linked.status_code == 200, linked.text
    adult_b_entry_id = str(uuid.uuid4())
    adult_b_log = await client.post(
        f"/api/fitness/planned-meals/{plan.json()['id']}/log",
        headers=adult_b_headers,
        json={
            "id": adult_b_entry_id,
            "portion": 1,
            "unit": "serving",
            "logged_at_utc": datetime.now(timezone.utc).isoformat(),
            "local_timezone": "Europe/Berlin",
        },
    )
    assert adult_b_log.status_code == 201, adult_b_log.text

    contexts: list[dict] = []

    async def answer(**kwargs):
        contexts.append(kwargs["context"])
        return FitnessHermesResponse(
            answer="Dinner is already planned.", provider="test", model="test"
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", answer)
    enabled = await client.patch(
        "/api/fitness/coach/context-preferences",
        headers=adult_a_headers,
        json={"household_meals": True},
    )
    assert enabled.status_code == 200
    assert contexts == []
    sent = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "Help around tonight's meal", "intent": "discussion"},
    )
    assert sent.status_code == 200, sent.text
    assert len(contexts[-1]["evidence"]) <= 12
    household = next(item for item in contexts[-1]["evidence"] if item["kind"] == "household_meals")
    planned = household["facts"]["meals"][0]
    assert planned["meal_name"] == "Family curry"
    assert planned["already_logged_by_you"] is False
    serialized = json.dumps(household)
    assert adult_b_entry_id not in serialized
    assert adult_b_user["id"] not in serialized

    disabled = await client.patch(
        "/api/fitness/coach/context-preferences",
        headers=adult_a_headers,
        json={"household_meals": False},
    )
    assert disabled.status_code == 200
    sent = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "What should I do?", "intent": "discussion"},
    )
    assert sent.status_code == 200
    assert "household_meals" not in {item["kind"] for item in contexts[-1]["evidence"]}


async def test_cross_module_drafts_revalidate_every_link_before_first_confirm(
    client,
    adult_a_headers,
    adult_b_user,
    initialized_db,
    monkeypatch,
):
    start = _future(days=3)
    session_id = str(uuid.uuid4())
    session = await client.post(
        "/api/fitness/planned-sessions",
        headers=adult_a_headers,
        json={
            "id": session_id,
            "sport_key": "running",
            "title": "Steady run",
            "local_timezone": "Europe/Berlin",
            "status": "scheduled",
            "session_source": "user",
            "scheduled_start_utc": start.isoformat(),
            "expected_duration_s": 3600,
        },
    )
    assert session.status_code == 201, session.text
    meal = await client.post("/api/meals/", headers=adult_a_headers, json={"name": "Race breakfast"})
    plan = await client.post(
        "/api/meals/plan",
        headers=adult_a_headers,
        json={
            "meal_id": meal.json()["id"],
            "date": _future(days=2).date().isoformat(),
            "meal_type": "breakfast",
        },
    )
    assert plan.status_code == 201, plan.text

    proposals = {
        "calendar stale": (
            "family_calendar_event",
            {
                "title": "Detailed private run title",
                "start_time": start.isoformat(),
                "end_time": (start + timedelta(hours=1)).isoformat(),
                "all_day": False,
                "planned_session_id": session_id,
                "family_visible": True,
            },
        ),
        "reminder stale": (
            "fitness_reminder",
            {
                "title": "Get ready",
                "remind_at_utc": _future(days=2).isoformat(),
                "planned_session_id": session_id,
                "private_to_you": True,
            },
        ),
        "shopping stale": (
            "shopping_list",
            {
                "items": [
                    {
                        "name": "Oats",
                        "quantity": "1 bag",
                        "meal_plan_id": plan.json()["id"],
                    }
                ],
                "family_visible": True,
            },
        ),
        "task stale": (
            "family_task",
            {
                "title": "Put breakfast out",
                "assigned_to": adult_b_user["id"],
                "due_date": _future(days=1).isoformat(),
                "family_visible": True,
            },
        ),
    }

    async def propose(**kwargs):
        kind, payload = proposals[kwargs["message"]]
        return FitnessHermesResponse(
            answer="Review the change.",
            proposal=FitnessHermesProposal(kind=kind, payload=payload),
            provider="test",
            model="test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", propose)

    calendar = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "calendar stale"},
    )
    assert calendar.json()["proposal"]["validation"]["valid"] is True
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_planned_sessions SET expected_duration_s = 1800, "
            "updated_at = ? WHERE id = ?",
            (datetime.now(timezone.utc).isoformat(), session_id),
        )
        await db.commit()
    calendar_confirm = await client.post(
        f"/api/fitness/coach/proposals/{calendar.json()['proposal']['id']}/confirm",
        headers=adult_a_headers,
    )
    assert calendar_confirm.json()["status"] == "invalid"

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_planned_sessions SET expected_duration_s = 3600, "
            "status = 'scheduled', updated_at = ? WHERE id = ?",
            (datetime.now(timezone.utc).isoformat(), session_id),
        )
        await db.commit()
    reminder = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "reminder stale"},
    )
    assert reminder.json()["proposal"]["validation"]["valid"] is True
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_planned_sessions SET status = 'completed', updated_at = ? WHERE id = ?",
            (datetime.now(timezone.utc).isoformat(), session_id),
        )
        await db.commit()
    reminder_confirm = await client.post(
        f"/api/fitness/coach/proposals/{reminder.json()['proposal']['id']}/confirm",
        headers=adult_a_headers,
    )
    assert reminder_confirm.json()["status"] == "invalid"

    shopping = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "shopping stale"},
    )
    assert shopping.json()["proposal"]["validation"]["valid"] is True
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE meal_plans SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (
                datetime.now(timezone.utc).isoformat(),
                datetime.now(timezone.utc).isoformat(),
                plan.json()["id"],
            ),
        )
        await db.commit()
    shopping_confirm = await client.post(
        f"/api/fitness/coach/proposals/{shopping.json()['proposal']['id']}/confirm",
        headers=adult_a_headers,
    )
    assert shopping_confirm.json()["status"] == "invalid"

    task = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={"message": "task stale"},
    )
    assert task.json()["proposal"]["validation"]["valid"] is True
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE users SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (
                datetime.now(timezone.utc).isoformat(),
                datetime.now(timezone.utc).isoformat(),
                adult_b_user["id"],
            ),
        )
        await db.commit()
    task_confirm = await client.post(
        f"/api/fitness/coach/proposals/{task.json()['proposal']['id']}/confirm",
        headers=adult_a_headers,
    )
    assert task_confirm.json()["status"] == "invalid"

    async with aiosqlite.connect(initialized_db) as db:
        for table in (
            "calendar_events",
            "health_fitness_reminders",
            "shopping_items",
            "tasks",
        ):
            count = (
                await (
                    await db.execute(f"SELECT COUNT(*) FROM {table} WHERE deleted_at IS NULL")
                ).fetchone()
            )[0]
            assert count == 0, table


async def test_family_target_edits_make_confirm_and_undo_replays_stable(
    client,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
):
    start = _future(days=2)
    proposals = {
        "calendar edit": (
            "family_calendar_event",
            {
                "title": "Private detail that is replaced",
                "start_time": start.isoformat(),
                "end_time": (start + timedelta(hours=1)).isoformat(),
                "family_visible": True,
            },
        ),
        "shopping edit": (
            "shopping_list",
            {
                "items": [{"name": "Bananas", "quantity": "6"}],
                "family_visible": True,
            },
        ),
        "task edit": (
            "family_task",
            {"title": "Pack the buggy", "family_visible": True},
        ),
    }

    async def propose(**kwargs):
        kind, payload = proposals[kwargs["message"]]
        return FitnessHermesResponse(
            answer="Review the exact change.",
            proposal=FitnessHermesProposal(kind=kind, payload=payload),
            provider="test",
            model="test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", propose)
    for message, (kind, _payload) in proposals.items():
        drafted = await client.post(
            "/api/fitness/coach/message",
            headers=adult_a_headers,
            json={"message": message},
        )
        proposal_id = drafted.json()["proposal"]["id"]
        confirmed = await client.post(
            f"/api/fitness/coach/proposals/{proposal_id}/confirm",
            headers=adult_a_headers,
        )
        assert confirmed.json()["status"] == "confirmed"
        result_ids = confirmed.json()["result_ids"]
        if kind == "family_calendar_event":
            edited = await client.put(
                f"/api/calendar/{result_ids[0]}",
                headers=adult_b_headers,
                json={"title": "Changed family logistics"},
            )
        elif kind == "shopping_list":
            edited = await client.patch(
                f"/api/meals/shopping/{result_ids[0]}/check", headers=adult_b_headers
            )
        else:
            edited = await client.put(
                f"/api/tasks/{result_ids[0]}",
                headers=adult_b_headers,
                json={"title": "Changed family task"},
            )
        assert edited.status_code == 200, edited.text

        for _ in range(2):
            replay = await client.post(
                f"/api/fitness/coach/proposals/{proposal_id}/confirm",
                headers=adult_a_headers,
            )
            assert replay.json()["status"] == "confirmed"
            assert replay.json()["result_ids"] == result_ids
        first_undo = await client.post(
            f"/api/fitness/coach/proposals/{proposal_id}/undo", headers=adult_a_headers
        )
        replayed_undo = await client.post(
            f"/api/fitness/coach/proposals/{proposal_id}/undo", headers=adult_a_headers
        )
        assert first_undo.json()["status"] == "conflict"
        assert replayed_undo.json() == first_undo.json()


async def test_private_reminder_list_and_delete_are_owner_scoped_and_replay_safe(
    client,
    adult_a_headers,
    adult_b_headers,
    other_family_headers,
    monkeypatch,
):
    async def propose(**_kwargs):
        return FitnessHermesResponse(
            answer="Review the reminder.",
            proposal=FitnessHermesProposal(
                kind="fitness_reminder",
                payload={
                    "title": "Charge watch",
                    "remind_at_utc": _future(days=1).isoformat(),
                    "notes": "Before tomorrow's run",
                    "private_to_you": True,
                },
            ),
            provider="test",
            model="test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", propose)
    drafted = await client.post(
        "/api/fitness/coach/message", headers=adult_a_headers, json={"message": "remind"}
    )
    proposal_id = drafted.json()["proposal"]["id"]
    confirmed = await client.post(
        f"/api/fitness/coach/proposals/{proposal_id}/confirm", headers=adult_a_headers
    )
    reminder_id = confirmed.json()["result_ids"][0]
    assert reminder_id in {
        item["id"]
        for item in (await client.get("/api/fitness/coach/reminders", headers=adult_a_headers)).json()
    }
    for headers in (adult_b_headers, other_family_headers):
        assert reminder_id not in {
            item["id"]
            for item in (await client.get("/api/fitness/coach/reminders", headers=headers)).json()
        }
        hidden_delete = await client.delete(
            f"/api/fitness/coach/reminders/{reminder_id}", headers=headers
        )
        assert hidden_delete.status_code == 404

    removed = await client.delete(
        f"/api/fitness/coach/reminders/{reminder_id}", headers=adult_a_headers
    )
    assert removed.status_code == 204
    assert (
        await client.delete(f"/api/fitness/coach/reminders/{reminder_id}", headers=adult_a_headers)
    ).status_code == 204
    replay = await client.post(
        f"/api/fitness/coach/proposals/{proposal_id}/confirm", headers=adult_a_headers
    )
    assert replay.json()["status"] == "confirmed"
    assert replay.json()["result_ids"] == [reminder_id]
    undo = await client.post(
        f"/api/fitness/coach/proposals/{proposal_id}/undo", headers=adult_a_headers
    )
    assert undo.json()["status"] == "already_undone"


async def test_invalid_visibility_and_naive_times_stay_inert_drafts(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    cases = {
        "wrong visibility": (
            "family_task",
            {"title": "Private task", "family_visible": False},
        ),
        "naive reminder": (
            "fitness_reminder",
            {
                "title": "Naive reminder",
                "remind_at_utc": _future(days=1).replace(tzinfo=None).isoformat(),
                "private_to_you": True,
            },
        ),
    }

    async def propose(**kwargs):
        kind, payload = cases[kwargs["message"]]
        return FitnessHermesResponse(
            answer="Review this.",
            proposal=FitnessHermesProposal(kind=kind, payload=payload),
            provider="test",
            model="test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", propose)
    for message in cases:
        response = await client.post(
            "/api/fitness/coach/message",
            headers=adult_a_headers,
            json={"message": message},
        )
        assert response.status_code == 200, response.text
        proposal = response.json()["proposal"]
        assert proposal["validation"]["valid"] is False
        assert proposal["confirmable"] is False
        assert proposal["preview"] is None

    strict_context = await client.patch(
        "/api/fitness/coach/context-preferences",
        headers=adult_a_headers,
        json={"weather": 1},
    )
    assert strict_context.status_code == 422
    async with aiosqlite.connect(initialized_db) as db:
        for table in ("tasks", "health_fitness_reminders"):
            count = (
                await (
                    await db.execute(f"SELECT COUNT(*) FROM {table} WHERE deleted_at IS NULL")
                ).fetchone()
            )[0]
            assert count == 0


async def test_existing_onboarding_table_gains_coach_context_preferences(db_path):
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "CREATE TABLE health_onboarding_profiles ("
            "id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, status TEXT NOT NULL, "
            "family_id TEXT NOT NULL, deleted_at TEXT)"
        )
        await db.execute(
            "INSERT INTO health_onboarding_profiles "
            "(id, owner_user_id, status, family_id) VALUES ('profile-1','owner-1','skipped','family-1')"
        )
        await db.commit()

    await init_db(db_path)

    async with aiosqlite.connect(db_path) as db:
        columns = {
            row[1]
            for row in await (
                await db.execute("PRAGMA table_info(health_onboarding_profiles)")
            ).fetchall()
        }
        row = await (
            await db.execute(
                "SELECT use_family_calendar, use_household_meals, use_weather "
                "FROM health_onboarding_profiles WHERE id = 'profile-1'"
            )
        ).fetchone()
    assert {"use_family_calendar", "use_household_meals", "use_weather"} <= columns
    assert tuple(row) == (0, 0, 0)
