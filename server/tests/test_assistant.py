import asyncio
import json
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import aiosqlite
import pytest

from app.config import settings
from app.models.assistant import (
    HermesActionEvidence,
    HermesAssistantResponse,
    HermesCalendarAction,
    HermesCompleteTaskAction,
    HermesCreateTaskAction,
    HermesLightsAction,
    HermesShoppingAction,
)
from app.routers.assistant import assistant_rate_limiter
from app.routers import assistant as assistant_router
from app.services import assistant as assistant_service
from app.services.hermes import HermesBusyError, HermesUsageLimitError


@pytest.mark.parametrize(
    "field",
    [
        "account_number",
        "sortCode",
        "provider_account_id",
        "public_address",
        "wallet-address",
        "wifi_password",
        "refresh_token",
    ],
)
def test_assistant_context_redaction_fails_closed_for_identifiers_and_secrets(field):
    with pytest.raises(RuntimeError, match="forbidden field"):
        assistant_service._assert_assistant_context_is_redacted(
            {"nested": [{field: "must-not-leave-hausklar"}]}
        )


@pytest.mark.parametrize(
    "identifier",
    [
        "12345678",
        "12-34-56",
        "GB29NWBK60161331926819",
        "0x1111111111111111111111111111111111111111",
        "11111111111111111111111111111111",
    ],
)
def test_assistant_context_redacts_identifiers_embedded_in_text(identifier):
    context = assistant_service.redact_assistant_context(
        {"notes": f"Private identifier: {identifier}", "date": "2026-08-12"}
    )
    assert identifier not in context["notes"]
    assert context["notes"] == "Private identifier: [identifier redacted]"
    assert context["date"] == "2026-08-12"


async def test_assistant_requires_authentication(client):
    response = await client.post("/api/assistant/message", json={"message": "Hello"})
    assert response.status_code == 401


async def test_assistant_is_rate_limited_per_user(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(assistant_rate_limiter, "max_attempts", 1)
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(return_value=HermesAssistantResponse(answer="Nothing urgent.", actions=[])),
    )

    first = await client.post(
        "/api/assistant/message",
        json={"message": "What needs attention?"},
        headers=adult_a_headers,
    )
    second = await client.post(
        "/api/assistant/message",
        json={"message": "What needs attention now?"},
        headers=adult_a_headers,
    )

    assert first.status_code == 200
    assert second.status_code == 429
    assert second.headers["retry-after"]


async def test_assistant_global_budget_survives_memory_reset(
    client,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(settings, "assistant_global_rate_limit_requests", 1)
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(return_value=HermesAssistantResponse(answer="Nothing urgent.", actions=[])),
    )

    first = await client.post(
        "/api/assistant/message",
        json={"message": "What needs attention?"},
        headers=adult_a_headers,
    )
    assistant_rate_limiter.reset()
    second = await client.post(
        "/api/assistant/message",
        json={"message": "And now?"},
        headers=adult_a_headers,
    )

    assert first.status_code == 200
    assert second.status_code == 429


async def test_assistant_reports_private_bridge_unavailable(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(return_value=None),
    )

    response = await client.post(
        "/api/assistant/message",
        json={"message": "What is on today?"},
        headers=adult_a_headers,
    )

    assert response.status_code == 503
    assert "Bismarck" in response.json()["detail"]


async def test_assistant_reports_provider_usage_limit(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(side_effect=HermesUsageLimitError("quota spent")),
    )

    response = await client.post(
        "/api/assistant/message",
        json={"message": "What is on today?"},
        headers=adult_a_headers,
    )

    assert response.status_code == 503
    assert "usage limit" in response.json()["detail"]


async def test_assistant_reports_bridge_busy(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(side_effect=HermesBusyError("busy")),
    )

    response = await client.post(
        "/api/assistant/message",
        json={"message": "What is on today?"},
        headers=adult_a_headers,
    )

    assert response.status_code == 503
    assert "helping someone else" in response.json()["detail"]


async def test_calendar_action_is_pending_and_writes_nothing(
    client,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    response_model = HermesAssistantResponse(
        answer="I have prepared weekly football for confirmation.",
        actions=[
            HermesCalendarAction(
                kind="create_calendar_event",
                title="Football",
                start_time="2026-07-14T17:00:00+01:00",
                end_time="2026-07-14T18:00:00+01:00",
                recurrence_rule="FREQ=WEEKLY;BYDAY=TU",
                assigned_to=child1["id"],
                evidence=HermesActionEvidence(
                    subject="football",
                    date_or_day="every Tuesday",
                    time="5pm",
                    recurrence="weekly football",
                    person="Child 1",
                ),
            )
        ],
    )
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(return_value=response_model),
    )

    response = await client.post(
        "/api/assistant/message",
        json={
            "message": "Add weekly football for Child 1 every Tuesday at 5pm",
            "client_now": "2026-07-10T12:00:00+01:00",
            "timezone": "Europe/London",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    action = response.json()["actions"][0]
    assert action["status"] == "pending"
    assert "Football" in action["summary"]
    assert "Tuesday" in action["summary"]
    assert "Child 1" in action["summary"]

    async with aiosqlite.connect(initialized_db) as db:
        event_count = (await (await db.execute("SELECT COUNT(*) FROM calendar_events")).fetchone())[0]
        pending_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM assistant_actions WHERE status = 'pending'"
                )
            ).fetchone()
        )[0]
    assert event_count == 0
    assert pending_count == 1


async def test_calendar_action_accepts_explicit_german_schedule(
    client,
    adult_a_headers,
    child1,
    monkeypatch,
):
    response_model = HermesAssistantResponse(
        answer="Gern, ich habe Klavier für dich zur Bestätigung vorbereitet.",
        language="de",
        actions=[
            HermesCalendarAction(
                kind="create_calendar_event",
                title="Klavier",
                start_time="2026-07-16T16:00:00+01:00",
                recurrence_rule="FREQ=WEEKLY;BYDAY=TH",
                assigned_to=child1["id"],
                evidence=HermesActionEvidence(
                    subject="Klavier",
                    date_or_day="jeden Donnerstag",
                    time="16 Uhr",
                    recurrence="jeden Donnerstag",
                    person="Child 1",
                ),
            )
        ],
    )
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(return_value=response_model),
    )

    response = await client.post(
        "/api/assistant/message",
        json={
            "message": (
                "Füge Klavier für Child 1 jeden Donnerstag um 16 Uhr hinzu, "
                "beginnend nächsten Donnerstag."
            ),
            "client_now": "2026-07-10T12:00:00+01:00",
            "timezone": "Europe/London",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    assert response.json()["answer"].startswith("Gern")
    assert response.json()["actions"][0]["kind"] == "calendar_event"
    assert "hinzufügen" in response.json()["actions"][0]["summary"]
    assert "Donnerstag" in response.json()["actions"][0]["summary"]
    confirmation = await client.post(
        f"/api/assistant/actions/{response.json()['actions'][0]['id']}/execute",
        headers=adult_a_headers,
    )
    assert confirmation.status_code == 200, confirmation.text
    assert confirmation.json()["message"] == "Zum Familienkalender hinzugefügt."


async def test_calendar_action_cannot_invent_missing_weekday(
    client,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    inferred_action = HermesAssistantResponse(
        answer="Weekly football on Wednesday is ready.",
        actions=[
            HermesCalendarAction(
                kind="create_calendar_event",
                title="Football",
                start_time="2026-07-15T17:00:00+01:00",
                recurrence_rule="FREQ=WEEKLY;BYDAY=WE",
                assigned_to=child1["id"],
                evidence=HermesActionEvidence(
                    subject="football",
                    date_or_day="Wednesday",
                    time="5",
                    recurrence="Wednesday",
                    person="Child 1",
                ),
            )
        ],
    )
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(return_value=inferred_action),
    )

    ambiguous = await client.post(
        "/api/assistant/message",
        json={"message": "Add weekly football for Child 1 at 5"},
        headers=adult_a_headers,
    )
    grounded_follow_up = await client.post(
        "/api/assistant/message",
        json={
            "message": "Every Wednesday",
            "history": [
                {"role": "user", "content": "Add weekly football for Child 1 at 5"},
                {"role": "assistant", "content": "Which day?"},
            ],
            "dry_run": True,
        },
        headers=adult_a_headers,
    )

    assert ambiguous.json()["actions"] == []
    assert "more detail" in ambiguous.json()["answer"]
    assert grounded_follow_up.json()["actions"][0]["kind"] == "calendar_event"
    assert grounded_follow_up.json()["actions"][0]["editable"] is False
    assert grounded_follow_up.json()["actions"][0]["preview"]["title"] == "Football"
    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute("SELECT COUNT(*) FROM assistant_actions")
            ).fetchone()
        )[0]
    assert count == 0


async def test_confirm_calendar_action_executes_once(
    client,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready for confirmation.",
                actions=[
                    HermesCalendarAction(
                        kind="create_calendar_event",
                        title="Football",
                        start_time="2026-07-14T17:00:00",
                        recurrence_rule="FREQ=WEEKLY;BYDAY=TU",
                        assigned_to=child1["id"],
                        evidence=HermesActionEvidence(
                            subject="football",
                            date_or_day="every Tuesday",
                            time="5pm",
                            recurrence="weekly football",
                            person="Child 1",
                        ),
                    )
                ],
            )
        ),
    )
    proposal = await client.post(
        "/api/assistant/message",
        json={
            "message": "Add weekly football for Child 1 every Tuesday at 5pm",
            "client_now": "2026-07-10T12:00:00+01:00",
        },
        headers=adult_a_headers,
    )
    action_id = proposal.json()["actions"][0]["id"]

    confirmed = await client.post(
        f"/api/assistant/actions/{action_id}/execute",
        headers=adult_a_headers,
    )
    repeated = await client.post(
        f"/api/assistant/actions/{action_id}/execute",
        headers=adult_a_headers,
    )

    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()["status"] == "executed"
    assert confirmed.json()["result_id"]
    assert repeated.status_code == 200
    assert repeated.json() == confirmed.json()
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        row = await (
            await db.execute(
                "SELECT * FROM calendar_events WHERE id = ?",
                (confirmed.json()["result_id"],),
            )
        ).fetchone()
    assert row["start_time"] == "2026-07-14T17:00:00+01:00"
    assert row["recurrence_rule"] == "FREQ=WEEKLY;BYDAY=TU"
    assert row["assigned_to"] == child1["id"]


async def test_only_action_creator_can_confirm(
    client,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready.",
                actions=[HermesLightsAction(kind="set_all_lights", state="off")],
            )
        ),
    )
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Turn off all lights"},
        headers=adult_a_headers,
    )
    action_id = proposal.json()["actions"][0]["id"]

    response = await client.post(
        f"/api/assistant/actions/{action_id}/execute",
        headers=adult_b_headers,
    )
    assert response.status_code == 404


async def test_home_action_maps_to_fixed_all_lights_command(
    client,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready to turn them off.",
                actions=[HermesLightsAction(kind="set_all_lights", state="off")],
            )
        ),
    )
    call_lights = AsyncMock()
    monkeypatch.setattr("app.routers.assistant.call_all_lights", call_lights)
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Turn off all the house lights"},
        headers=adult_a_headers,
    )

    response = await client.post(
        f"/api/assistant/actions/{proposal.json()['actions'][0]['id']}/execute",
        headers=adult_a_headers,
    )

    assert response.json()["status"] == "executed"
    call_lights.assert_awaited_once()
    assert call_lights.await_args.kwargs["state"] == "off"


async def test_create_task_action_uses_family_assignment(
    client,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="I have prepared the task.",
                actions=[
                    HermesCreateTaskAction(
                        kind="create_task",
                        title="Return nursery form",
                        due_date="2026-07-13",
                        assigned_to=child1["id"],
                        category="admin",
                        priority=2,
                        evidence=HermesActionEvidence(
                            subject="nursery form",
                            date_or_day="Monday",
                            person="Child 1",
                        ),
                    )
                ],
            )
        ),
    )
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Remind Child 1 to return the nursery form by Monday"},
        headers=adult_a_headers,
    )
    action_id = proposal.json()["actions"][0]["id"]
    response = await client.post(
        f"/api/assistant/actions/{action_id}/execute",
        headers=adult_a_headers,
    )

    assert response.json()["status"] == "executed"
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        task = await (
            await db.execute("SELECT * FROM tasks WHERE id = ?", (response.json()["result_id"],))
        ).fetchone()
        assignment = await (
            await db.execute(
                "SELECT * FROM task_assignments WHERE task_id = ?",
                (response.json()["result_id"],),
            )
        ).fetchone()
    assert task["title"] == "Return nursery form"
    assert task["due_date"] == "2026-07-13"
    assert task["category"] == "admin"
    assert assignment["assignee_id"] == child1["id"]


async def test_monthly_task_action_accepts_an_explicit_day_of_month(
    client,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="I have prepared the monthly task.",
                actions=[
                    HermesCreateTaskAction(
                        kind="create_task",
                        title="Pay Little Gym",
                        due_date="2026-09-04",
                        recurrence_rule="FREQ=MONTHLY;BYMONTHDAY=4",
                        assigned_to=adult_a_user["id"],
                        category="admin",
                        evidence=HermesActionEvidence(
                            subject="pay little gym",
                            date_or_day="the 4th",
                            recurrence="every month",
                            person="Alex",
                        ),
                    )
                ],
            )
        ),
    )

    response = await client.post(
        "/api/assistant/message",
        json={
            "message": (
                "Add a recurring task every month on the 4th "
                "to pay Little Gym to Alex"
            ),
            "client_now": "2026-08-10T12:23:00+01:00",
            "timezone": "Europe/London",
            "dry_run": True,
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    action = response.json()["actions"][0]
    assert action["kind"] == "create_task"
    assert action["preview"]["due_date"] == "2026-09-04"
    assert action["preview"]["recurrence_rule"] == "FREQ=MONTHLY;BYMONTHDAY=4"
    assert action["preview"]["assigned_to"] == adult_a_user["id"]


async def test_explicit_task_request_normalises_calendar_shaped_model_action(
    client,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="The weekly review is ready for confirmation.",
                actions=[
                    HermesCalendarAction(
                        kind="create_calendar_event",
                        title="Review homework",
                        start_time="2026-07-12T18:00:00+01:00",
                        recurrence_rule="FREQ=WEEKLY;BYDAY=SU",
                        evidence=HermesActionEvidence(
                            subject="review homework",
                            date_or_day="every Sunday",
                            time="6pm",
                            recurrence="every Sunday",
                        ),
                    )
                ],
            )
        ),
    )

    response = await client.post(
        "/api/assistant/message",
        json={
            "message": "Create a task to review homework every Sunday at 6pm",
            "client_now": "2026-07-10T12:00:00+01:00",
            "timezone": "Europe/London",
            "dry_run": True,
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    assert response.json()["actions"][0]["kind"] == "create_task"
    assert "Review homework" in response.json()["actions"][0]["summary"]


async def test_term_time_calendar_action_uses_model_evidence_and_expands_terms(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE children SET name = 'Child One' WHERE id = ?",
            (child1["id"],),
        )
        await db.executemany(
            """
            INSERT INTO term_dates
                (id, person_id, label, start_date, end_date, family_id, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    "summer-term",
                    child1["id"],
                    "Summer",
                    "2026-07-15",
                    "2026-07-17",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
                (
                    "autumn-term",
                    child1["id"],
                    "Autumn",
                    "2026-09-02",
                    "2026-09-16",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            ],
        )
        await db.execute(
            """
            INSERT INTO holiday_dates
                (id, person_id, date, label, family_id, created_by)
            VALUES ('inset-day', ?, '2026-09-09', 'INSET', ?, ?)
            """,
            (child1["id"], adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="I have prepared Child One's term-time football.",
                actions=[
                    HermesCalendarAction(
                        kind="create_calendar_event",
                        title="Football",
                        start_time="2026-07-15T15:00:00+01:00",
                        end_time="2026-07-15T16:15:00+01:00",
                        recurrence_rule="FREQ=WEEKLY;BYDAY=WE",
                        assigned_to=child1["id"],
                        term_time_only=True,
                        evidence=HermesActionEvidence(
                            subject="football",
                            date_or_day="wednesdays",
                            time="3 till 4.15",
                            recurrence="wednesdays",
                            person="max",
                            term_time="term time",
                        ),
                    )
                ],
            )
        ),
    )

    proposal = await client.post(
        "/api/assistant/message",
        json={
            "message": "add max football from 3 till 4.15 on wednesdays in term time",
            "client_now": "2026-07-10T12:00:00+01:00",
            "timezone": "Europe/London",
        },
        headers=adult_a_headers,
    )

    assert proposal.status_code == 200, proposal.text
    assert proposal.json()["actions"][0]["kind"] == "calendar_event"
    assert "for Child One" in proposal.json()["actions"][0]["summary"]
    assert "during configured term time" in proposal.json()["actions"][0]["summary"]
    confirmed = await client.post(
        f"/api/assistant/actions/{proposal.json()['actions'][0]['id']}/execute",
        headers=adult_a_headers,
    )
    assert confirmed.status_code == 200, confirmed.text

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                """
                SELECT start_time, end_time, recurrence_rule
                FROM calendar_events
                WHERE title = 'Football'
                ORDER BY start_time
                """
            )
        ).fetchall()
    assert [row["start_time"] for row in rows] == [
        "2026-07-15T15:00:00+01:00",
        "2026-09-02T15:00:00+01:00",
        "2026-09-16T15:00:00+01:00",
    ]
    assert all(row["end_time"].endswith("16:15:00+01:00") for row in rows)
    assert all(row["recurrence_rule"] is None for row in rows)


async def test_complete_task_action_can_only_target_open_family_task(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO tasks (id, title, family_id, created_by)
            VALUES ('task-to-complete', 'Pay nursery invoice', ?, ?)
            """,
            (adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()
    async def fake_assistant(*, message, history, context):
        target = next(item for item in context["open_tasks"] if item["id"] == "task-to-complete")
        assert target["title"] == "Pay nursery invoice"
        return HermesAssistantResponse(
            answer="I found the open task.",
            actions=[
                HermesCompleteTaskAction(
                    kind="complete_task",
                    task_id="task-to-complete",
                )
            ],
        )

    monkeypatch.setattr("app.routers.assistant.ask_family_assistant", fake_assistant)

    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Mark the nursery invoice as done"},
        headers=adult_a_headers,
    )
    confirmed = await client.post(
        f"/api/assistant/actions/{proposal.json()['actions'][0]['id']}/execute",
        headers=adult_a_headers,
    )

    assert confirmed.json()["status"] == "executed"
    async with aiosqlite.connect(initialized_db) as db:
        completed_at = (
            await (
                await db.execute(
                    "SELECT completed_at FROM tasks WHERE id = 'task-to-complete'"
                )
            ).fetchone()
        )[0]
        history_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM record_history WHERE record_id = 'task-to-complete'"
                )
            ).fetchone()
        )[0]
    assert completed_at is not None
    assert history_count == 1


async def test_complete_task_action_requires_unique_due_date_for_duplicate_titles(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """
            INSERT INTO tasks (id, title, due_date, family_id, created_by)
            VALUES (?, 'Order groceries', ?, ?, ?)
            """,
            [
                ("groceries-friday", "2026-07-11", adult_a_user["family_id"], adult_a_user["id"]),
                ("groceries-sunday", "2026-07-13", adult_a_user["family_id"], adult_a_user["id"]),
            ],
        )
        await db.commit()

    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="I found one to complete.",
                actions=[
                    HermesCompleteTaskAction(
                        kind="complete_task",
                        task_id="groceries-friday",
                    )
                ],
            )
        ),
    )

    ambiguous = await client.post(
        "/api/assistant/message",
        json={"message": "Mark one Order groceries task done", "dry_run": True},
        headers=adult_a_headers,
    )
    exact = await client.post(
        "/api/assistant/message",
        json={"message": "Mark Order groceries due 11 July 2026 done", "dry_run": True},
        headers=adult_a_headers,
    )

    assert ambiguous.json()["actions"] == []
    assert "Which due date" in ambiguous.json()["answer"]
    assert exact.json()["actions"][0]["kind"] == "complete_task"


async def test_add_shopping_item_action(client, adult_a_headers, initialized_db, monkeypatch):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="I can add it.",
                actions=[
                    HermesShoppingAction(
                        kind="add_shopping_item",
                        name="Milk",
                        quantity="2 pints",
                        category="Dairy",
                    )
                ],
            )
        ),
    )
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Add two pints of milk to the shopping list"},
        headers=adult_a_headers,
    )
    confirmed = await client.post(
        f"/api/assistant/actions/{proposal.json()['actions'][0]['id']}/execute",
        headers=adult_a_headers,
    )

    assert confirmed.json()["status"] == "executed"
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT name, quantity, category FROM shopping_items WHERE id = ?",
                (confirmed.json()["result_id"],),
            )
        ).fetchone()
    assert row == ("Milk", "2 pints", "Dairy")


async def test_model_cannot_inject_unrequested_light_or_shopping_actions(
    client,
    adult_a_headers,
    monkeypatch,
):
    responses = [
        HermesAssistantResponse(
            answer="The calendar is clear.",
            actions=[HermesLightsAction(kind="set_all_lights", state="off")],
        ),
        HermesAssistantResponse(
            answer="The letter has been summarised.",
            actions=[
                HermesShoppingAction(
                    kind="add_shopping_item",
                    name="Milk",
                    quantity="12 bottles",
                )
            ],
        ),
    ]
    model = AsyncMock(side_effect=responses)
    monkeypatch.setattr("app.routers.assistant.ask_family_assistant", model)

    calendar = await client.post(
        "/api/assistant/message",
        json={"message": "What is on the calendar today?", "dry_run": True},
        headers=adult_a_headers,
    )
    document = await client.post(
        "/api/assistant/message",
        json={"message": "Summarise the nursery letter", "dry_run": True},
        headers=adult_a_headers,
    )

    assert calendar.status_code == 200
    assert document.status_code == 200
    assert calendar.json()["actions"] == []
    assert document.json()["actions"] == []


async def test_questions_cannot_be_reinterpreted_as_shopping_commands(
    client,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Milk is already listed.",
                actions=[
                    HermesShoppingAction(kind="add_shopping_item", name="Milk")
                ],
            )
        ),
    )

    response = await client.post(
        "/api/assistant/message",
        json={"message": "Is milk on the shopping list?", "dry_run": True},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json()["actions"] == []


async def test_terse_shopping_item_remains_a_grounded_quick_add(
    client,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Milk is ready to add.",
                actions=[
                    HermesShoppingAction(kind="add_shopping_item", name="Milk")
                ],
            )
        ),
    )

    response = await client.post(
        "/api/assistant/message",
        json={"message": "Milk.", "dry_run": True},
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json()["actions"][0]["kind"] == "shopping_item"


async def test_action_can_be_declined(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready.",
                actions=[HermesLightsAction(kind="set_all_lights", state="on")],
            )
        ),
    )
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Turn on all lights"},
        headers=adult_a_headers,
    )
    action_id = proposal.json()["actions"][0]["id"]

    declined = await client.post(
        f"/api/assistant/actions/{action_id}/decline",
        headers=adult_a_headers,
    )
    execute = await client.post(
        f"/api/assistant/actions/{action_id}/execute",
        headers=adult_a_headers,
    )

    assert declined.json()["status"] == "declined"
    assert execute.status_code == 409

    replay = await client.post(
        f"/api/assistant/actions/{action_id}/decline",
        headers=adult_a_headers,
    )
    assert replay.status_code == 200
    assert replay.json()["status"] == "declined"


async def test_executed_action_replays_terminal_result_after_response_loss(
    client,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready.",
                actions=[HermesLightsAction(kind="set_all_lights", state="off")],
            )
        ),
    )
    call_lights = AsyncMock()
    monkeypatch.setattr("app.routers.assistant.call_all_lights", call_lights)
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Turn off all lights"},
        headers=adult_a_headers,
    )
    action_id = proposal.json()["actions"][0]["id"]

    first = await client.post(
        f"/api/assistant/actions/{action_id}/execute",
        headers=adult_a_headers,
    )
    replay = await client.post(
        f"/api/assistant/actions/{action_id}/execute",
        headers=adult_a_headers,
    )

    assert first.status_code == 200
    assert replay.status_code == 200
    assert replay.json() == first.json()
    call_lights.assert_awaited_once()


async def test_execute_and_decline_race_reports_exactly_one_winner(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready.",
                actions=[HermesLightsAction(kind="set_all_lights", state="on")],
            )
        ),
    )
    call_lights = AsyncMock()
    monkeypatch.setattr("app.routers.assistant.call_all_lights", call_lights)
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Turn on all lights"},
        headers=adult_a_headers,
    )
    action_id = proposal.json()["actions"][0]["id"]

    original_owned_action = assistant_router._owned_action
    both_read_pending = asyncio.Event()
    reads = 0
    reads_lock = asyncio.Lock()

    async def synchronize_pending_reads(db, requested_action_id, current_user):
        nonlocal reads
        row = await original_owned_action(db, requested_action_id, current_user)
        async with reads_lock:
            reads += 1
            if reads == 2:
                both_read_pending.set()
        await both_read_pending.wait()
        return row

    monkeypatch.setattr("app.routers.assistant._owned_action", synchronize_pending_reads)
    executed, declined = await asyncio.gather(
        client.post(f"/api/assistant/actions/{action_id}/execute", headers=adult_a_headers),
        client.post(f"/api/assistant/actions/{action_id}/decline", headers=adult_a_headers),
    )

    assert sorted([executed.status_code, declined.status_code]) == [200, 409]
    async with aiosqlite.connect(initialized_db) as db:
        status = (
            await (
                await db.execute(
                    "SELECT status FROM assistant_actions WHERE id = ?",
                    (action_id,),
                )
            ).fetchone()
        )[0]

    if executed.status_code == 200:
        assert executed.json()["status"] == "executed"
        assert status == "executed"
        call_lights.assert_awaited_once()
    else:
        assert declined.json()["status"] == "declined"
        assert status == "declined"
        call_lights.assert_not_awaited()


async def test_expired_action_is_not_executed(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready.",
                actions=[HermesLightsAction(kind="set_all_lights", state="off")],
            )
        ),
    )
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Turn off all lights"},
        headers=adult_a_headers,
    )
    action_id = proposal.json()["actions"][0]["id"]
    expired = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE assistant_actions SET expires_at = ? WHERE id = ?",
            (expired, action_id),
        )
        await db.commit()

    response = await client.post(
        f"/api/assistant/actions/{action_id}/execute",
        headers=adult_a_headers,
    )
    assert response.json()["status"] == "expired"


async def _propose_editable_calendar(client, headers, monkeypatch, *, assigned_to=None):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready for review.",
                actions=[
                    HermesCalendarAction(
                        kind="create_calendar_event",
                        title="Football",
                        description="Bring boots",
                        start_time="2026-07-14T17:00:00+01:00",
                        end_time="2026-07-14T18:00:00+01:00",
                        recurrence_rule="FREQ=WEEKLY;BYDAY=TU",
                        assigned_to=assigned_to,
                        evidence=HermesActionEvidence(
                            subject="football",
                            date_or_day="Tuesday",
                            time="5pm",
                            recurrence="weekly",
                            person="Child 1" if assigned_to else None,
                        ),
                    )
                ],
            )
        ),
    )
    message = "Add weekly football every Tuesday at 5pm"
    if assigned_to:
        message = "Add weekly football for Child 1 every Tuesday at 5pm"
    response = await client.post(
        "/api/assistant/message",
        json={
            "message": message,
            "client_now": "2026-07-10T12:00:00+01:00",
            "timezone": "Europe/London",
        },
        headers=headers,
    )
    assert response.status_code == 200, response.text
    return response.json()["actions"][0]


async def _propose_editable_shopping(client, headers, monkeypatch):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready for review.",
                actions=[
                    HermesShoppingAction(
                        kind="add_shopping_item",
                        name="Milk",
                        quantity="2 pints",
                        category="Dairy",
                    )
                ],
            )
        ),
    )
    response = await client.post(
        "/api/assistant/message",
        json={"message": "Add two pints of milk to the shopping list"},
        headers=headers,
    )
    assert response.status_code == 200, response.text
    return response.json()["actions"][0]


async def test_action_response_exposes_only_typed_editable_preview(
    client,
    adult_a_headers,
    child1,
    monkeypatch,
):
    calendar = await _propose_editable_calendar(
        client,
        adult_a_headers,
        monkeypatch,
        assigned_to=child1["id"],
    )

    assert calendar["editable"] is True
    assert calendar["preview"] == {
        "kind": "calendar_event",
        "title": "Football",
        "description": "Bring boots",
        "start_time": "2026-07-14T17:00:00+01:00",
        "end_time": "2026-07-14T18:00:00+01:00",
        "all_day": False,
        "recurrence_rule": "FREQ=WEEKLY;BYDAY=TU",
        "assigned_to": child1["id"],
        "term_time_only": False,
    }
    assert "_language" not in calendar["preview"]
    assert "_timezone" not in calendar["preview"]

    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready.",
                actions=[HermesLightsAction(kind="set_all_lights", state="off")],
            )
        ),
    )
    lights = await client.post(
        "/api/assistant/message",
        json={"message": "Turn off all lights"},
        headers=adult_a_headers,
    )
    assert lights.status_code == 200
    assert lights.json()["actions"][0]["editable"] is False
    assert lights.json()["actions"][0]["preview"] is None
    rejected_edit = await client.patch(
        f"/api/assistant/actions/{lights.json()['actions'][0]['id']}",
        json={"kind": "calendar_event", "title": "Not a light action"},
        headers=adult_a_headers,
    )
    assert rejected_edit.status_code == 409
    assert "cannot be edited" in rejected_edit.json()["detail"]


async def test_calendar_patch_rebuilds_summary_and_execution_uses_edited_payload(
    client,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    action = await _propose_editable_calendar(client, adult_a_headers, monkeypatch)
    patched = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={
            "kind": "calendar_event",
            "title": "Swimming lesson",
            "description": "Take goggles",
            "start_time": "2026-07-16T16:30:00+01:00",
            "end_time": "2026-07-16T17:15:00+01:00",
            "recurrence_rule": None,
            "assigned_to": child1["id"],
        },
        headers=adult_a_headers,
    )

    assert patched.status_code == 200, patched.text
    assert patched.json()["preview"]["title"] == "Swimming lesson"
    assert patched.json()["preview"]["recurrence_rule"] is None
    assert patched.json()["preview"]["assigned_to"] == child1["id"]
    assert "Swimming lesson" in patched.json()["summary"]
    assert "Child 1" in patched.json()["summary"]
    assert "weekly" not in patched.json()["summary"]

    executed = await client.post(
        f"/api/assistant/actions/{action['id']}/execute",
        headers=adult_a_headers,
    )
    replay = await client.post(
        f"/api/assistant/actions/{action['id']}/execute",
        headers=adult_a_headers,
    )
    assert executed.status_code == 200, executed.text
    assert replay.json() == executed.json()
    assert executed.json()["result_id"]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        event = await (
            await db.execute(
                "SELECT * FROM calendar_events WHERE id = ?",
                (executed.json()["result_id"],),
            )
        ).fetchone()
    assert event["title"] == "Swimming lesson"
    assert event["description"] == "Take goggles"
    assert event["start_time"] == "2026-07-16T16:30:00+01:00"
    assert event["end_time"] == "2026-07-16T17:15:00+01:00"
    assert event["recurrence_rule"] is None
    assert event["assigned_to"] == child1["id"]


async def test_successful_patch_records_previous_action_once(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    action = await _propose_editable_shopping(client, adult_a_headers, monkeypatch)
    patched = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={"kind": "shopping_item", "name": "Oat milk"},
        headers=adult_a_headers,
    )
    assert patched.status_code == 200, patched.text
    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                """SELECT previous_values FROM record_history
                   WHERE table_name='assistant_actions' AND record_id=?""",
                (action["id"],),
            )
        ).fetchall()
    assert len(rows) == 1
    previous = json.loads(rows[0][0])
    assert json.loads(previous["payload"])["name"] == "Milk"


async def test_task_patch_validates_typed_fields_and_executes_edits(
    client,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(
        "app.routers.assistant.ask_family_assistant",
        AsyncMock(
            return_value=HermesAssistantResponse(
                answer="Ready.",
                actions=[
                    HermesCreateTaskAction(
                        kind="create_task",
                        title="Return form",
                        due_date="2026-07-14",
                        category="admin",
                        priority=2,
                        evidence=HermesActionEvidence(
                            subject="form",
                            date_or_day="Tuesday",
                        ),
                    )
                ],
            )
        ),
    )
    proposal = await client.post(
        "/api/assistant/message",
        json={"message": "Remind me to return the form by Tuesday"},
        headers=adult_a_headers,
    )
    action = proposal.json()["actions"][0]
    patched = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={
            "kind": "create_task",
            "title": "Return signed nursery form",
            "due_date": "2026-07-16",
            "assigned_to": child1["id"],
            "category": "household",
            "priority": 1,
        },
        headers=adult_a_headers,
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["preview"]["category"] == "household"
    assert patched.json()["preview"]["priority"] == 1
    assert "Child 1" in patched.json()["summary"]

    executed = await client.post(
        f"/api/assistant/actions/{action['id']}/execute",
        headers=adult_a_headers,
    )
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        task = await (
            await db.execute(
                "SELECT * FROM tasks WHERE id = ?",
                (executed.json()["result_id"],),
            )
        ).fetchone()
    assert task["title"] == "Return signed nursery form"
    assert task["due_date"] == "2026-07-16"
    assert task["assigned_to"] == child1["id"]
    assert task["category"] == "household"
    assert task["priority"] == 1


async def test_shopping_patch_can_clear_optional_values_and_executes_edits(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    action = await _propose_editable_shopping(client, adult_a_headers, monkeypatch)
    patched = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={
            "kind": "shopping_item",
            "name": "Oat milk",
            "quantity": None,
            "category": "Dairy alternatives",
        },
        headers=adult_a_headers,
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["preview"] == {
        "kind": "shopping_item",
        "name": "Oat milk",
        "quantity": None,
        "category": "Dairy alternatives",
    }
    assert patched.json()["summary"] == "Add 'Oat milk' to the shopping list"

    executed = await client.post(
        f"/api/assistant/actions/{action['id']}/execute",
        headers=adult_a_headers,
    )
    async with aiosqlite.connect(initialized_db) as db:
        item = await (
            await db.execute(
                "SELECT name, quantity, category FROM shopping_items WHERE id = ?",
                (executed.json()["result_id"],),
            )
        ).fetchone()
    assert item == ("Oat milk", None, "Dairy alternatives")


async def test_patch_isolated_by_creator_and_family(
    client,
    adult_a_headers,
    adult_b_headers,
    other_family_headers,
    monkeypatch,
):
    action = await _propose_editable_shopping(client, adult_a_headers, monkeypatch)
    body = {"kind": "shopping_item", "name": "Oat milk"}

    same_family_other_user = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json=body,
        headers=adult_b_headers,
    )
    other_family = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json=body,
        headers=other_family_headers,
    )

    assert same_family_other_user.status_code == 404
    assert other_family.status_code == 404


async def test_patch_rejects_non_family_assignee_without_changing_action(
    client,
    adult_a_headers,
    other_family_user,
    initialized_db,
    monkeypatch,
):
    action = await _propose_editable_calendar(client, adult_a_headers, monkeypatch)
    rejected = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={
            "kind": "calendar_event",
            "assigned_to": other_family_user["id"],
        },
        headers=adult_a_headers,
    )
    assert rejected.status_code == 422
    assert "active family member" in rejected.json()["detail"]

    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT payload, summary FROM assistant_actions WHERE id = ?",
                (action["id"],),
            )
        ).fetchone()
        history_count = (
            await (
                await db.execute(
                    """SELECT COUNT(*) FROM record_history
                       WHERE table_name='assistant_actions' AND record_id=?""",
                    (action["id"],),
                )
            ).fetchone()
        )[0]
    assert other_family_user["id"] not in row[0]
    assert row[1] == action["summary"]
    assert history_count == 0


@pytest.mark.parametrize("terminal_status", ["executed", "declined", "failed", "expired"])
async def test_patch_rejects_terminal_action_states(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
    terminal_status,
):
    action = await _propose_editable_shopping(client, adult_a_headers, monkeypatch)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE assistant_actions SET status = ? WHERE id = ?",
            (terminal_status, action["id"]),
        )
        await db.commit()

    response = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={"kind": "shopping_item", "name": "Oat milk"},
        headers=adult_a_headers,
    )
    assert response.status_code == 409


async def test_patch_marks_elapsed_pending_action_expired(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    action = await _propose_editable_shopping(client, adult_a_headers, monkeypatch)
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE assistant_actions SET expires_at = ? WHERE id = ?",
            ((datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat(), action["id"]),
        )
        await db.commit()

    response = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={"kind": "shopping_item", "name": "Oat milk"},
        headers=adult_a_headers,
    )
    assert response.status_code == 409
    assert "expired" in response.json()["detail"]
    async with aiosqlite.connect(initialized_db) as db:
        status = (
            await (
                await db.execute(
                    "SELECT status FROM assistant_actions WHERE id = ?",
                    (action["id"],),
                )
            ).fetchone()
        )[0]
    assert status == "expired"


async def test_patch_rejects_unsupported_kinds_fields_and_invalid_values(
    client,
    adult_a_headers,
    monkeypatch,
):
    action = await _propose_editable_calendar(client, adult_a_headers, monkeypatch)
    bad_requests = [
        {"kind": "home_lights", "state": "off"},
        {"kind": "calendar_event", "title": "Changed", "url": "https://example.test"},
        {"kind": "create_task", "title": "Wrong kind"},
        {
            "kind": "calendar_event",
            "start_time": "2026-07-14T18:00:00+01:00",
            "end_time": "2026-07-14T17:00:00+01:00",
        },
        {"kind": "calendar_event", "recurrence_rule": "FREQ=HOURLY"},
        {"kind": "calendar_event", "recurrence_rule": "FREQ=MONTHLY;BYMONTHDAY=0"},
        {"kind": "calendar_event", "recurrence_rule": "FREQ=MONTHLY;BYMONTHDAY=32"},
        {"kind": "calendar_event", "title": "x" * 301},
    ]
    for body in bad_requests:
        response = await client.patch(
            f"/api/assistant/actions/{action['id']}",
            json=body,
            headers=adult_a_headers,
        )
        assert response.status_code == 422, (body, response.text)


async def test_term_time_patch_requires_assignee_and_recurrence_and_can_be_cleared(
    client,
    adult_a_headers,
    child1,
    monkeypatch,
):
    action = await _propose_editable_calendar(
        client,
        adult_a_headers,
        monkeypatch,
        assigned_to=child1["id"],
    )
    enabled = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={"kind": "calendar_event", "term_time_only": True},
        headers=adult_a_headers,
    )
    assert enabled.status_code == 200, enabled.text
    assert enabled.json()["preview"]["term_time_only"] is True

    missing_recurrence = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={"kind": "calendar_event", "recurrence_rule": None},
        headers=adult_a_headers,
    )
    assert missing_recurrence.status_code == 422

    cleared = await client.patch(
        f"/api/assistant/actions/{action['id']}",
        json={
            "kind": "calendar_event",
            "description": None,
            "end_time": None,
            "recurrence_rule": None,
            "assigned_to": None,
            "term_time_only": False,
        },
        headers=adult_a_headers,
    )
    assert cleared.status_code == 200, cleared.text
    assert cleared.json()["preview"]["description"] is None
    assert cleared.json()["preview"]["end_time"] is None
    assert cleared.json()["preview"]["recurrence_rule"] is None
    assert cleared.json()["preview"]["assigned_to"] is None
    assert cleared.json()["preview"]["term_time_only"] is False


async def test_concurrent_patches_do_not_silently_overwrite_each_other(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    action = await _propose_editable_shopping(client, adult_a_headers, monkeypatch)
    original_owned_action = assistant_router._owned_action
    both_read_pending = asyncio.Event()
    reads = 0
    reads_lock = asyncio.Lock()

    async def synchronize_first_reads(db, requested_action_id, current_user):
        nonlocal reads
        row = await original_owned_action(db, requested_action_id, current_user)
        async with reads_lock:
            reads += 1
            read_number = reads
            if reads == 2:
                both_read_pending.set()
        if read_number <= 2:
            await both_read_pending.wait()
        return row

    monkeypatch.setattr("app.routers.assistant._owned_action", synchronize_first_reads)
    first, second = await asyncio.gather(
        client.patch(
            f"/api/assistant/actions/{action['id']}",
            json={"kind": "shopping_item", "name": "Oat milk"},
            headers=adult_a_headers,
        ),
        client.patch(
            f"/api/assistant/actions/{action['id']}",
            json={"kind": "shopping_item", "name": "Almond milk"},
            headers=adult_a_headers,
        ),
    )
    assert sorted((first.status_code, second.status_code)) == [200, 409]
    accepted = first if first.status_code == 200 else second
    async with aiosqlite.connect(initialized_db) as db:
        stored = await (
            await db.execute(
                "SELECT payload FROM assistant_actions WHERE id=?",
                (action["id"],),
            )
        ).fetchone()
        history_count = (
            await (
                await db.execute(
                    """SELECT COUNT(*) FROM record_history
                       WHERE table_name='assistant_actions' AND record_id=?""",
                    (action["id"],),
                )
            ).fetchone()
        )[0]
    assert f'"name":"{accepted.json()["preview"]["name"]}"' in stored[0]
    assert history_count == 1


async def test_patch_and_execute_race_never_loses_an_accepted_edit(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    action = await _propose_editable_calendar(client, adult_a_headers, monkeypatch)
    original_owned_action = assistant_router._owned_action
    both_read_pending = asyncio.Event()
    reads = 0
    reads_lock = asyncio.Lock()

    async def synchronize_first_reads(db, requested_action_id, current_user):
        nonlocal reads
        row = await original_owned_action(db, requested_action_id, current_user)
        async with reads_lock:
            reads += 1
            if reads == 2:
                both_read_pending.set()
        if reads <= 2:
            await both_read_pending.wait()
        return row

    monkeypatch.setattr("app.routers.assistant._owned_action", synchronize_first_reads)
    patched, executed = await asyncio.gather(
        client.patch(
            f"/api/assistant/actions/{action['id']}",
            json={"kind": "calendar_event", "title": "Edited football"},
            headers=adult_a_headers,
        ),
        client.post(
            f"/api/assistant/actions/{action['id']}/execute",
            headers=adult_a_headers,
        ),
    )

    assert executed.status_code == 200, executed.text
    assert patched.status_code in {200, 409}, patched.text
    async with aiosqlite.connect(initialized_db) as db:
        title = (
            await (
                await db.execute(
                    "SELECT title FROM calendar_events WHERE id = ?",
                    (executed.json()["result_id"],),
                )
            ).fetchone()
        )[0]
    if patched.status_code == 200:
        assert title == "Edited football"
    else:
        assert title == "Football"


async def test_context_includes_computed_shared_time_off(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """
            INSERT INTO term_dates
                (id, person_id, label, start_date, end_date, family_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                ("dom-summer", adult_a_user["id"], "Summer", "2026-04-20", "2026-07-03", adult_a_user["family_id"]),
                ("dom-autumn", adult_a_user["id"], "Autumn", "2026-09-01", "2026-12-18", adult_a_user["family_id"]),
                ("child-summer", child1["id"], "Summer", "2026-04-20", "2026-07-10", adult_a_user["family_id"]),
                ("child-autumn", child1["id"], "Autumn", "2026-09-05", "2026-12-18", adult_a_user["family_id"]),
            ],
        )
        await db.commit()

    captured_context = {}

    async def fake_assistant(*, message, history, context):
        captured_context.update(context)
        return HermesAssistantResponse(answer="You are all off from 11 July.", actions=[])

    monkeypatch.setattr("app.routers.assistant.ask_family_assistant", fake_assistant)
    response = await client.post(
        "/api/assistant/message",
        json={
            "message": "What is the first day in summer when we are all on holiday?",
            "client_now": "2026-07-10T12:00:00+01:00",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    shared = captured_context["shared_time_off"]
    assert set(shared["tracked_people"]) == {"Alex", "Child 1"}
    assert shared["periods"][0] == {"start": "2026-07-11", "end": "2026-08-31"}


async def test_calendar_context_marks_cancelled_recurring_occurrences(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    created = await client.post(
        "/api/calendar/",
        json={
            "title": "Daily summer club",
            "start_time": "2026-07-10T09:00:00Z",
            "recurrence_rule": "FREQ=DAILY;COUNT=3",
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    cancelled = await client.post(
        f"/api/calendar/{created.json()['id']}/occurrences/delete",
        json={
            "scope": "only_this",
            "occurrence_start": "2026-07-11T09:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert cancelled.status_code == 204

    captured_context: dict = {}

    async def fake_assistant(*, message, history, context):
        captured_context.update(context)
        return HermesAssistantResponse(answer="The middle club is cancelled.", actions=[])

    monkeypatch.setattr("app.routers.assistant.ask_family_assistant", fake_assistant)
    response = await client.post(
        "/api/assistant/message",
        json={
            "message": "What is on the family calendar this weekend?",
            "client_now": "2026-07-10T12:00:00+01:00",
        },
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    series = next(
        event
        for event in captured_context["calendar_events"]
        if event["id"] == created.json()["id"]
    )
    assert series["excluded_occurrence_starts"] == [
        "2026-07-11T09:00:00+00:00"
    ]


async def test_context_exposes_broad_read_snapshot_without_keyword_gating(
    client,
    adult_a_user,
    adult_a_headers,
    child1,
    initialized_db,
    monkeypatch,
):
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO documents
                (id, title, original_filename, media_type, storage_key, file_size,
                 sha256, category, extracted_text, family_id, created_by)
            VALUES ('private-document', 'Nursery invoice', 'invoice.pdf',
                    'application/pdf', 'private-document.pdf', 10, 'abc123',
                    'childcare', 'The nursery invoice is due on Friday.', ?, ?)
            """,
            (adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """
            INSERT INTO medicine_types
                (id, name, child_id, family_id, created_by)
            VALUES ('private-medicine', 'Calpol', ?, ?, ?)
            """,
            (child1["id"], adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.execute(
            """
            INSERT INTO medicine_doses
                (id, medicine_type_id, child_id, given_at, given_by,
                 family_id, created_by)
            VALUES ('private-dose', 'private-medicine', ?,
                    '2026-07-10T08:00:00+01:00', 'Alex', ?, ?)
            """,
            (child1["id"], adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.commit()

    captured: list[dict] = []

    async def fake_assistant(*, message, history, context):
        captured.append(context)
        return HermesAssistantResponse(answer="Done.", actions=[])

    monkeypatch.setattr("app.routers.assistant.ask_family_assistant", fake_assistant)

    default_response = await client.post(
        "/api/assistant/message",
        json={
            "message": "What is on the calendar today?",
            "client_now": "2026-07-10T12:00:00+01:00",
        },
        headers=adult_a_headers,
    )
    document_response = await client.post(
        "/api/assistant/message",
        json={
            "message": "What did it say?",
            "history": [
                {"role": "user", "content": "Find the nursery invoice"},
                {"role": "assistant", "content": "I found it."},
            ],
            "client_now": "2026-07-10T12:00:00+01:00",
        },
        headers=adult_a_headers,
    )
    medicine_response = await client.post(
        "/api/assistant/message",
        json={
            "message": "When was the last Calpol dose?",
            "client_now": "2026-07-10T12:00:00+01:00",
        },
        headers=adult_a_headers,
    )

    assert default_response.status_code == 200
    assert document_response.status_code == 200
    assert medicine_response.status_code == 200

    default_records = captured[0]["family_records"]
    assert set(captured[0]["context_categories"]) == set(assistant_service._CONTEXT_CATEGORY_WORDS)
    assert captured[0]["focus_categories"] == []
    assert default_records["recent_documents"][0]["id"] == "private-document"
    assert default_records["recent_documents"][0]["text_excerpt"] == (
        "The nursery invoice is due on Friday."
    )
    assert default_records["recent_medicine_doses"][0]["medicine"] == "Calpol"

    document_records = captured[1]["family_records"]
    assert captured[1]["focus_categories"] == ["documents"]
    assert document_records["recent_documents"][0]["id"] == "private-document"
    assert document_records["matching_document_text"][0]["id"] == "private-document"
    assert document_records["recent_medicine_doses"][0]["medicine"] == "Calpol"

    medicine_records = captured[2]["family_records"]
    assert captured[2]["focus_categories"] == ["medicine"]
    assert medicine_records["medicine_types"][0]["id"] == "private-medicine"
    assert medicine_records["recent_medicine_doses"][0]["medicine"] == "Calpol"
    assert medicine_records["recent_documents"][0]["id"] == "private-document"


async def test_assistant_reads_visible_finance_values_but_redacts_identifiers(
    client,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    monkeypatch,
):
    family_id = adult_a_user["family_id"]
    async with aiosqlite.connect(initialized_db) as db:
        await db.executemany(
            """
            INSERT INTO finance_spaces (id, kind, owner_user_id, family_id)
            VALUES (?, ?, ?, ?)
            """,
            [
                ("dom-money", "personal", adult_a_user["id"], family_id),
                ("kat-money", "personal", adult_b_user["id"], family_id),
                ("family-money", "household", None, family_id),
            ],
        )
        await db.execute(
            """
            INSERT INTO finance_accounts
                (id, space_id, provider_account_id, label, institution,
                 account_type, purpose, currency, last_four, family_id)
            VALUES ('dom-account', 'dom-money', 'provider-account-secret',
                    'Current 12345678 / 12-34-56', 'Bank', 'CURRENT', 'OPERATING_CURRENT',
                    'GBP', '9876', ?)
            """,
            (family_id,),
        )
        await db.execute(
            """
            INSERT INTO finance_balance_snapshots
                (id, space_id, account_id, booked_minor, available_minor,
                 currency, observed_at, family_id)
            VALUES ('dom-balance', 'dom-money', 'dom-account', 123456, 120000,
                    'GBP', '2026-08-12T08:00:00Z', ?)
            """,
            (family_id,),
        )
        await db.execute(
            """
            INSERT INTO finance_transactions
                (id, space_id, account_id, canonical_date, amount_minor, currency,
                 state, source_kind, description, cleaned_description,
                 data_through_at, family_id)
            VALUES ('dom-transaction', 'dom-money', 'dom-account', '2026-08-11',
                    -4321, 'GBP', 'POSTED', 'PROVIDER', 'Running shop',
                    'RUNNING SHOP', '2026-08-12T08:00:00Z', ?)
            """,
            (family_id,),
        )
        await db.execute(
            """
            INSERT INTO finance_asset_sources
                (id, space_id, source_kind, label, public_address, family_id)
            VALUES ('dom-wallet', 'dom-money', 'SOLANA_PUBLIC',
                    'Wallet 0x1111111111111111111111111111111111111111',
                    'wallet-address-secret', ?)
            """,
            (family_id,),
        )
        await db.execute(
            """
            INSERT INTO finance_asset_snapshots
                (id, space_id, source_id, as_of_at, snapshot_kind, data_status,
                 family_id)
            VALUES ('dom-wallet-snapshot', 'dom-money', 'dom-wallet',
                    '2026-08-12T08:00:00Z', 'WATCH_ONLY', 'COMPLETE', ?)
            """,
            (family_id,),
        )
        await db.execute(
            """
            INSERT INTO finance_positions
                (id, space_id, snapshot_id, asset_key, asset_name, asset_class,
                 position_kind, quantity_decimal, quantity_unit, quote_symbol,
                 family_id)
            VALUES ('dom-position', 'dom-money', 'dom-wallet-snapshot', 'SOL',
                    'Solana', 'VOLATILE_CRYPTO', 'HOLDING', '12.5', 'SOL',
                    'SOL-GBP', ?)
            """,
            (family_id,),
        )
        await db.execute(
            """
            INSERT INTO finance_valuations
                (id, space_id, position_id, valuation_status, value_minor,
                 currency, observed_at, family_id)
            VALUES ('dom-valuation', 'dom-money', 'dom-position', 'KNOWN',
                    250000, 'GBP', '2026-08-12T08:00:00Z', ?)
            """,
            (family_id,),
        )
        await db.commit()

    captured: list[dict] = []

    async def fake_assistant(*, message, history, context):
        captured.append(context)
        return HermesAssistantResponse(answer="I can see the values.", actions=[])

    monkeypatch.setattr("app.routers.assistant.ask_family_assistant", fake_assistant)
    for headers in (adult_a_headers, adult_b_headers):
        response = await client.post(
            "/api/assistant/message",
            json={
                "message": "How are things looking?",
                "client_now": "2026-08-12T09:00:00+01:00",
            },
            headers=headers,
        )
        assert response.status_code == 200, response.text

    adult_a_finance = captured[0]["family_records"]["visible_finance"][0]
    encoded = json.dumps(adult_a_finance)
    assert adult_a_finance["accounts_and_balances"][0]["booked_minor"] == 123456
    assert adult_a_finance["recent_transactions"][0]["amount_minor"] == -4321
    assert adult_a_finance["latest_positions_and_values"][0]["asset_name"] == "Solana"
    assert adult_a_finance["latest_positions_and_values"][0]["value_minor"] == 250000
    assert "provider-account-secret" not in encoded
    assert "wallet-address-secret" not in encoded
    assert "9876" not in encoded
    assert "12345678" not in encoded
    assert "12-34-56" not in encoded
    assert "0x1111111111111111111111111111111111111111" not in encoded
    assert "[identifier redacted]" in encoded

    adult_b_encoded = json.dumps(captured[1]["family_records"]["visible_finance"])
    assert "Running shop" not in adult_b_encoded
    assert "Solana" not in adult_b_encoded
