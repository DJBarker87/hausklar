"""Focused contracts for reviewed Finance projections into Calendar and Tasks."""

import json
import uuid
from datetime import date, datetime, timedelta, timezone

import aiosqlite
import pytest

from app.models.finance import FinanceCommitmentCreate
from app.services.account_deletion import delete_account_data
from app.services.finance.foundation import get_finance_settings
from app.services.finance.planning import create_commitment
from app.services.finance.projections import set_projection_preference


async def _spaces(client, headers: dict) -> dict[str, str]:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200, response.text
    return {row["kind"]: row["id"] for row in response.json()}


async def _calendar(client, headers: dict, *, start: date, end: date, assigned_to=None):
    params = {"start": start.isoformat(), "end": end.isoformat(), "limit": 200}
    if assigned_to is not None:
        params["assigned_to"] = assigned_to
    response = await client.get("/api/calendar/", params=params, headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


async def _insert_purchase_source(
    db_path: str,
    *,
    family_id: str,
    space_id: str,
    user_id: str,
    source_kind: str,
    payload: dict | None = None,
) -> str:
    source_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """
            INSERT INTO finance_purchase_sources
                (id, space_id, external_source_id, source_kind,
                 extraction_status, raw_payload_json, issues_json, received_at,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, 'PARSED', ?, '[]', ?, ?, ?, ?, ?)
            """,
            (
                source_id,
                space_id,
                f"test-{source_id}",
                source_kind,
                json.dumps(payload or {"reviewed": True}),
                now,
                family_id,
                now,
                now,
                user_id,
            ),
        )
        await db.commit()
    return source_id


@pytest.mark.asyncio
async def test_household_commitment_has_stable_amount_free_managed_occurrences(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    first_due = date.today() + timedelta(days=20)
    second_due = date.today() + timedelta(days=80)
    personal = await client.post(
        "/api/finance/commitments",
        params={"space_id": spaces["personal"]},
        json={
            "name": "Private bill",
            "amount_mode": "EXACT",
            "exact_minor": 12345,
            "recurrence": "ONE_OFF",
            "reviewed_dates": [first_due.isoformat()],
            "payment_handling": "MANUAL",
            "show_in_calendar": True,
        },
        headers=adult_a_headers,
    )
    assert personal.status_code == 422

    created = await client.post(
        "/api/finance/commitments",
        params={"space_id": spaces["household"]},
        json={
            "name": "School fees",
            "amount_mode": "EXACT",
            "exact_minor": 320000,
            "recurrence": "TERMLY",
            "reviewed_dates": [first_due.isoformat(), second_due.isoformat()],
            "payment_handling": "MANUAL",
            "show_in_calendar": True,
            "show_in_tasks": True,
            "responsible_user_id": adult_a_user["id"],
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    commitment_id = created.json()["id"]

    events = await _calendar(
        client,
        adult_a_headers,
        start=date.today(),
        end=date.today() + timedelta(days=120),
    )
    money = [event for event in events if event["event_type"] == "finance_commitment"]
    assert len(money) == 2
    assert {event["title"] for event in money} == {"School fees due"}
    assert {event["assigned_to"] for event in money} == {adult_a_user["id"]}
    assert all(event["read_only"] is True for event in money)
    assert all(event["managed_source"]["source_id"] == commitment_id for event in money)
    assert all("320000" not in json.dumps(event) and "GBP" not in json.dumps(event) for event in money)

    tasks = (await client.get("/api/tasks/", headers=adult_a_headers)).json()
    projected_tasks = [task for task in tasks if task["id"].startswith("finance-task-")]
    assert len(projected_tasks) == 2
    assert {task["title"] for task in projected_tasks} == {"Pay School fees"}
    assert all(task["assigned_to"] == adult_a_user["id"] for task in projected_tasks)

    original_event_ids = {event["id"] for event in money}
    original_task_ids = {task["id"] for task in projected_tasks}
    moved_due = second_due + timedelta(days=2)
    changed = await client.patch(
        f"/api/finance/commitments/{commitment_id}",
        json={"reviewed_dates": [first_due.isoformat(), moved_due.isoformat()]},
        headers=adult_a_headers,
    )
    assert changed.status_code == 200, changed.text
    changed_events = await _calendar(
        client,
        adult_a_headers,
        start=date.today(),
        end=date.today() + timedelta(days=120),
    )
    changed_money = [event for event in changed_events if event["event_type"] == "finance_commitment"]
    assert {event["id"] for event in changed_money} == original_event_ids
    changed_tasks = (await client.get("/api/tasks/", headers=adult_a_headers)).json()
    assert {
        task["id"] for task in changed_tasks if task["id"].startswith("finance-task-")
    } == original_task_ids

    paused = await client.patch(
        f"/api/finance/commitments/{commitment_id}",
        json={"status": "PAUSED"},
        headers=adult_a_headers,
    )
    assert paused.status_code == 200
    assert not [
        event
        for event in await _calendar(
            client,
            adult_a_headers,
            start=date.today(),
            end=date.today() + timedelta(days=120),
        )
        if event["event_type"] == "finance_commitment"
    ]
    resumed = await client.patch(
        f"/api/finance/commitments/{commitment_id}",
        json={"status": "ACTIVE"},
        headers=adult_a_headers,
    )
    assert resumed.status_code == 200
    resumed_events = await _calendar(
        client,
        adult_a_headers,
        start=date.today(),
        end=date.today() + timedelta(days=120),
    )
    assert {
        event["id"] for event in resumed_events if event["event_type"] == "finance_commitment"
    } == original_event_ids

    async with aiosqlite.connect(initialized_db) as db:
        count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM finance_commitment_occurrences WHERE commitment_id = ?",
                    (commitment_id,),
                )
            ).fetchone()
        )[0]
    assert count == 2


@pytest.mark.asyncio
async def test_money_and_delivery_calendar_choices_are_independent_and_per_adult(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    delivery_day = date.today() + timedelta(days=7)
    commitment = await client.post(
        "/api/finance/commitments",
        params={"space_id": spaces["household"]},
        json={
            "name": "Car insurance",
            "amount_mode": "EXACT",
            "exact_minor": 62000,
            "recurrence": "ONE_OFF",
            "reviewed_dates": [delivery_day.isoformat()],
            "payment_handling": "RENEWAL",
            "show_in_calendar": True,
            "show_in_tasks": True,
            "responsible_user_id": adult_a_user["id"],
        },
        headers=adult_a_headers,
    )
    assert commitment.status_code == 201, commitment.text
    household_source = await _insert_purchase_source(
        initialized_db,
        family_id=adult_a_user["family_id"],
        space_id=spaces["household"],
        user_id=adult_a_user["id"],
        source_kind="tesco_batch",
        payload={
            "delivery_window": {
                "starts_at": f"{delivery_day.isoformat()}T14:00:00Z",
                "ends_at": f"{delivery_day.isoformat()}T15:00:00Z",
                "all_day": False,
            }
        },
    )
    prefill = await client.get(
        "/api/finance/calendar-items/prefill",
        params={"source_id": household_source},
        headers=adult_a_headers,
    )
    assert prefill.status_code == 200
    assert prefill.json() == {
        "item_kind": "GROCERY_DELIVERY",
        "starts_at": f"{delivery_day.isoformat()}T14:00:00Z",
        "ends_at": f"{delivery_day.isoformat()}T15:00:00Z",
        "all_day": False,
    }
    unreviewed = await client.post(
        "/api/finance/calendar-items",
        json={
            "reviewed": False,
            "space_id": spaces["household"],
            "item_kind": "GROCERY_DELIVERY",
            "source_id": household_source,
            "starts_at": f"{delivery_day.isoformat()}T14:00:00Z",
            "ends_at": f"{delivery_day.isoformat()}T15:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert unreviewed.status_code == 422
    delivery = await client.post(
        "/api/finance/calendar-items",
        json={
            "reviewed": True,
            "space_id": spaces["household"],
            "item_kind": "GROCERY_DELIVERY",
            "source_id": household_source,
            "starts_at": f"{delivery_day.isoformat()}T14:00:00Z",
            "ends_at": f"{delivery_day.isoformat()}T15:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert delivery.status_code == 201, delivery.text
    saved_deliveries = await client.get(
        "/api/finance/calendar-items",
        params={"source_id": household_source},
        headers=adult_a_headers,
    )
    assert saved_deliveries.status_code == 200
    assert [item["id"] for item in saved_deliveries.json()] == [delivery.json()["id"]]

    preference = await client.patch(
        "/api/finance/projection-preferences",
        json={"show_money": False, "show_deliveries": True},
        headers=adult_a_headers,
    )
    assert preference.json() == {"show_money": False, "show_deliveries": True}
    adult_a_events = await _calendar(
        client,
        adult_a_headers,
        start=date.today(),
        end=date.today() + timedelta(days=30),
    )
    assert [event["title"] for event in adult_a_events] == ["Tesco delivery"]
    assert adult_a_events[0]["managed_source"]["deep_link"] == (
        f"/?view=finance&section=activity&evidence={household_source}"
    )
    # The Planner Money switch does not turn off a deliberately-created task.
    assert any(
        task["title"] == "Review or renew Car insurance"
        for task in (await client.get("/api/tasks/", headers=adult_a_headers)).json()
    )

    adult_b_events = await _calendar(
        client,
        adult_b_headers,
        start=date.today(),
        end=date.today() + timedelta(days=30),
    )
    assert {event["title"] for event in adult_b_events} == {
        "Car insurance renewal due",
        "Tesco delivery",
    }
    # Filtering to Morgan hides Alex's accountable money date, but keeps a shared delivery.
    adult_b_filter = await _calendar(
        client,
        adult_a_headers,
        start=date.today(),
        end=date.today() + timedelta(days=30),
        assigned_to=adult_b_user["id"],
    )
    assert [event["title"] for event in adult_b_filter] == ["Tesco delivery"]

    cancelled = await client.delete(
        f"/api/finance/calendar-items/{delivery.json()['id']}", headers=adult_a_headers
    )
    assert cancelled.status_code == 204
    corrected_day = delivery_day + timedelta(days=1)
    reactivated = await client.post(
        "/api/finance/calendar-items",
        json={
            "reviewed": True,
            "space_id": spaces["household"],
            "item_kind": "GROCERY_DELIVERY",
            "source_id": household_source,
            "starts_at": f"{corrected_day.isoformat()}T16:00:00Z",
            "ends_at": f"{corrected_day.isoformat()}T17:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert reactivated.status_code == 201
    assert reactivated.json()["id"] == delivery.json()["id"]
    assert reactivated.json()["status"] == "ACTIVE"

    personal_source = await _insert_purchase_source(
        initialized_db,
        family_id=adult_a_user["family_id"],
        space_id=spaces["personal"],
        user_id=adult_a_user["id"],
        source_kind="natural_language",
    )
    no_guess = await client.get(
        "/api/finance/calendar-items/prefill",
        params={"source_id": personal_source},
        headers=adult_a_headers,
    )
    assert no_guess.status_code == 200
    assert no_guess.json() is None
    personal_delivery = await client.post(
        "/api/finance/calendar-items",
        json={
            "reviewed": True,
            "space_id": spaces["personal"],
            "item_kind": "PARCEL_DELIVERY",
            "source_id": personal_source,
            "starts_at": f"{corrected_day.isoformat()}T18:00:00Z",
        },
        headers=adult_a_headers,
    )
    assert personal_delivery.status_code == 201
    adult_a_all = await _calendar(
        client,
        adult_a_headers,
        start=date.today(),
        end=date.today() + timedelta(days=30),
    )
    parcel = next(event for event in adult_a_all if event["title"] == "Parcel delivery")
    assert parcel["assigned_to"] == adult_a_user["id"]
    filtered_to_kat = await _calendar(
        client,
        adult_a_headers,
        start=date.today(),
        end=date.today() + timedelta(days=30),
        assigned_to=adult_b_user["id"],
    )
    assert all(event["title"] != "Parcel delivery" for event in filtered_to_kat)
    adult_b_after_personal = await _calendar(
        client,
        adult_b_headers,
        start=date.today(),
        end=date.today() + timedelta(days=30),
    )
    assert all(event["title"] != "Parcel delivery" for event in adult_b_after_personal)

    shared_parcel_day = corrected_day + timedelta(days=1)
    shared_parcel = await client.post(
        "/api/finance/calendar-items",
        json={
            "reviewed": True,
            "space_id": spaces["household"],
            "item_kind": "PARCEL_DELIVERY",
            "source_id": personal_source,
            "starts_at": shared_parcel_day.isoformat(),
            "all_day": True,
        },
        headers=adult_a_headers,
    )
    assert shared_parcel.status_code == 201, shared_parcel.text
    source_items = await client.get(
        "/api/finance/calendar-items",
        params={"source_id": personal_source},
        headers=adult_a_headers,
    )
    assert source_items.status_code == 200
    assert {item["space_id"] for item in source_items.json()} == {
        spaces["personal"], spaces["household"]
    }
    assert {item["source_id"] for item in source_items.json()} == {personal_source}
    private_source_lookup = await client.get(
        "/api/finance/calendar-items",
        params={"source_id": personal_source},
        headers=adult_b_headers,
    )
    assert private_source_lookup.status_code == 404


@pytest.mark.asyncio
async def test_every_family_adult_receives_shared_finance_projections(
    client,
    adult_a_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    due = date.today() + timedelta(days=5)
    created = await client.post(
        "/api/finance/commitments",
        params={"space_id": spaces["household"]},
        json={
            "name": "Council tax",
            "amount_mode": "EXACT",
            "exact_minor": 10000,
            "recurrence": "ONE_OFF",
            "reviewed_dates": [due.isoformat()],
            "payment_handling": "MANUAL",
            "show_in_calendar": True,
            "show_in_tasks": True,
            "responsible_user_id": adult_a_user["id"],
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    events = await _calendar(
        client,
        adult_b_headers,
        start=date.today(),
        end=date.today() + timedelta(days=30),
    )
    finance_events = [event for event in events if event["event_type"] == "finance_commitment"]
    assert {event["title"] for event in finance_events} == {"Council tax due"}
    assert {event["assigned_to"] for event in finance_events} == {adult_a_user["id"]}
    tasks = (await client.get("/api/tasks/", headers=adult_b_headers)).json()
    finance_tasks = [task for task in tasks if task["id"].startswith("finance-task-")]
    assert {task["title"] for task in finance_tasks} == {"Pay Council tax"}
    assert {task["assigned_to"] for task in finance_tasks} == {adult_a_user["id"]}


@pytest.mark.asyncio
async def test_departing_adult_loses_personal_occurrences_and_projection_choices(
    initialized_db, adult_a_user, adult_b_user
):
    user = adult_a_user
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        settings = await get_finance_settings(db, user=user)
        await set_projection_preference(
            db, user=user, show_money=False, show_deliveries=True
        )
        commitment = await create_commitment(
            db,
            user=user,
            space_id=settings.personal_space_id,
            body=FinanceCommitmentCreate(
                name="Private annual cost",
                amount_mode="EXACT",
                exact_minor=1000,
                recurrence="ONE_OFF",
                reviewed_dates=[date.today() + timedelta(days=20)],
            ),
        )
        occurrence_id = (
            await (
                await db.execute(
                    "SELECT id FROM finance_commitment_occurrences WHERE commitment_id = ?",
                    (commitment.id,),
                )
            ).fetchone()
        )["id"]
        deletion = await delete_account_data(
            db, user_id=adult_a_user["id"], family_id=adult_a_user["family_id"]
        )
        assert deletion.final_family is False
        assert await (
            await db.execute(
                "SELECT 1 FROM finance_projection_preferences WHERE user_id = ?",
                (adult_a_user["id"],),
            )
        ).fetchone() is None
        assert await (
            await db.execute(
                "SELECT 1 FROM finance_commitment_occurrences WHERE id = ?",
                (occurrence_id,),
            )
        ).fetchone() is None
        assert await (
            await db.execute(
                "SELECT 1 FROM finance_spaces WHERE id = ?",
                (settings.personal_space_id,),
            )
        ).fetchone() is None
