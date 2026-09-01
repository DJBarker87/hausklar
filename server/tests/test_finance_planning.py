import json
import uuid
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

import aiosqlite
import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate
from app.services.finance.ledger import (
    create_finance_account,
    record_balance_snapshot,
)
from app.services.finance.coaching import (
    FinanceCoachingConflictError,
    _payday_transfer_simulation,
)
from app.services.finance.forecast import ForecastAccount, ForecastSnapshot
from app.services.finance.money import Money



async def _spaces(client, headers: dict) -> dict[str, str]:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200
    return {item["kind"]: item["id"] for item in response.json()}


async def _account(
    db_path: str,
    *,
    user: dict,
    space_id: str,
    label: str = "Planning current account",
    account_type: str = "CURRENT",
    include_in_cashflow: bool = True,
    minimum_balance_minor: int = 0,
):
    async with standalone_db(db_path) as db:
        return await create_finance_account(
            db,
            user=user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label=label,
                institution="Fixture Bank",
                account_type=account_type,
                currency="GBP",
                include_in_cashflow=include_in_cashflow,
                minimum_balance_minor=minimum_balance_minor,
            ),
        )


@pytest.mark.asyncio
async def test_plan_generation_without_spending_or_forecast_still_answers(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    async def fixture_local_today(db, *, family_id: str) -> date:
        del db, family_id
        return date(2026, 8, 1)

    monkeypatch.setattr(
        "app.services.finance.coaching._local_today",
        fixture_local_today,
    )
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    goal = await client.post(
        "/api/finance/goals",
        params={"space_id": space_id},
        json={
            "name": "House deposit",
            "target_minor": 1_000_000,
            "deadline": "2027-08-01",
            "currently_allocated_minor": 100_000,
            "currency": "GBP",
            "priority": "IMPORTANT",
            "allowed_funding_sources": [],
            "emergency_buffer_minor": 0,
        },
        headers=adult_a_headers,
    )
    assert goal.status_code == 201, goal.text

    response = await client.post(
        "/api/finance/plans/generate",
        params={"space_id": space_id},
        json={"goal_id": goal.json()["id"]},
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    plans = response.json()["plans"]
    assert [item["effort_level"] for item in plans] == ["EASY", "MEDIUM", "HARD"]
    assert {item["required_monthly_minor"] for item in plans} == {69_231}
    assert all(item["answer_basis"] == "BOUNDED" for item in plans)
    assert all(item["confidence_bps"] >= 3000 for item in plans)
    assert all(item["planned_monthly_saving_minor"] == 0 for item in plans)
    assert all(item["projected_amount_at_target_minor"] == 100_000 for item in plans)
    assert all(item["goal_shortfall_at_target_minor"] == 900_000 for item in plans)
    assert all(item["feasible"] is True for item in plans)
    assert all(
        "counts the existing monthly surplus" in " ".join(item["assumptions"])
        for item in plans
    )

    medium = next(item for item in plans if item["effort_level"] == "MEDIUM")
    activated = await client.post(
        f"/api/finance/plans/{medium['id']}/activate",
        headers=adult_a_headers,
    )
    assert activated.status_code == 200, activated.text


def test_payday_transfer_still_rejects_an_unsafe_amount() -> None:
    snapshot = ForecastSnapshot(
        start_date=date(2026, 8, 1),
        end_date=date(2026, 8, 31),
        timezone="Europe/London",
        currency="GBP",
        accounts=(
            ForecastAccount("current", Money(10_000, "GBP"), floor_minor=10_000),
            ForecastAccount("savings", Money(0, "GBP")),
        ),
        events=(),
    )

    with pytest.raises(
        FinanceCoachingConflictError,
        match="cannot safely fund this transfer",
    ):
        _payday_transfer_simulation(
            snapshot,
            source_account_id="current",
            destination_account_id="savings",
            due_date=date(2026, 8, 1),
            requested_minor=1,
        )


@pytest.mark.asyncio
async def test_personal_planning_records_are_not_discoverable_by_partner(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    adult_a_space = (await _spaces(client, adult_a_headers))["personal"]
    await _spaces(client, adult_b_headers)
    fact = await client.post(
        "/api/finance/facts",
        params={"space_id": adult_a_space},
        json={
            "fact_key": "private.salary_day",
            "statement": "Salary arrives on the last working day.",
        },
        headers=adult_a_headers,
    )
    assert fact.status_code == 201
    reserve = await client.post(
        "/api/finance/reserves",
        params={"space_id": adult_a_space},
        json={
            "name": "Private reserve",
            "allocated_minor": 1000,
            "target_minor": 5000,
            "currency": "GBP",
        },
        headers=adult_a_headers,
    )
    assert reserve.status_code == 201

    for collection in ("facts", "preferences", "commitments", "reserves", "goals"):
        response = await client.get(
            f"/api/finance/{collection}",
            params={"space_id": adult_a_space},
            headers=adult_b_headers,
        )
        assert response.status_code == 404
        assert "salary" not in response.text.lower()
    guessed = await client.put(
        f"/api/finance/facts/{fact.json()['id']}",
        json={"statement": "Changed", "evidence_refs": []},
        headers=adult_b_headers,
    )
    assert guessed.status_code == 404
    guessed_reserve = await client.patch(
        f"/api/finance/reserves/{reserve.json()['id']}",
        json={"allocated_minor": 2000},
        headers=adult_b_headers,
    )
    assert guessed_reserve.status_code == 404


@pytest.mark.asyncio
async def test_termly_reviewed_dates_and_underfunding_are_explicit(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["household"]
    response = await client.post(
        "/api/finance/commitments",
        params={"space_id": space_id},
        json={
            "name": "Nursery fees",
            "amount_mode": "EXACT",
            "exact_minor": 320000,
            "currency": "GBP",
            "recurrence": "TERMLY",
            "reviewed_dates": ["2026-09-03", "2026-01-02", "2026-04-15"],
            "priority": "PROTECTED",
            "already_reserved_minor": 100000,
        },
        headers=adult_a_headers,
    )
    assert response.status_code == 201

    listed = await client.get(
        "/api/finance/commitments",
        params={"space_id": space_id, "as_of": "2026-01-02"},
        headers=adult_a_headers,
    )
    commitment = listed.json()[0]
    assert commitment["reviewed_dates"] == [
        "2026-01-02",
        "2026-04-15",
        "2026-09-03",
    ]
    assert commitment["next_due_date"] == "2026-01-02"
    assert commitment["required_minor"] == 320000
    assert commitment["remaining_minor"] == 220000
    assert commitment["funding_status"] == "UNDERFUNDED"


@pytest.mark.asyncio
async def test_past_goal_keeps_exact_infeasible_shortfall(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    account = await _account(initialized_db, user=adult_a_user, space_id=space_id)
    created = await client.post(
        "/api/finance/goals",
        params={"space_id": space_id},
        json={
            "name": "Emergency fund",
            "target_minor": 100000,
            "deadline": "2026-01-01",
            "currently_allocated_minor": 20000,
            "currency": "GBP",
            "priority": "PROTECTED",
            "allowed_funding_sources": [account.id],
            "emergency_buffer_minor": 10000,
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    listed = await client.get(
        "/api/finance/goals",
        params={"space_id": space_id, "as_of": "2026-01-02"},
        headers=adult_a_headers,
    )
    goal = listed.json()[0]
    assert goal["remaining_minor"] == 80000
    assert goal["feasibility"] == "INFEASIBLE"
    assert goal["shortfall_minor"] == 80000
    assert goal["allowed_funding_sources"] == [account.id]


@pytest.mark.asyncio
async def test_reserve_reports_exact_remaining_and_overfunding(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["household"]
    account = await _account(initialized_db, user=adult_a_user, space_id=space_id)
    created = await client.post(
        "/api/finance/reserves",
        params={"space_id": space_id},
        json={
            "name": "Car reserve",
            "allocated_minor": 60000,
            "target_minor": 100000,
            "currency": "GBP",
            "linked_account_id": account.id,
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201
    assert created.json()["remaining_minor"] == 40000
    assert created.json()["funding_status"] == "PARTLY_FUNDED"

    updated = await client.patch(
        f"/api/finance/reserves/{created.json()['id']}",
        json={"allocated_minor": 110000},
        headers=adult_a_headers,
    )
    assert updated.status_code == 200
    assert updated.json()["remaining_minor"] == 0
    assert updated.json()["funding_status"] == "OVERFUNDED"
    invalid = await client.post(
        "/api/finance/reserves",
        params={"space_id": space_id},
        json={"name": "Invalid", "allocated_minor": -1, "currency": "GBP"},
        headers=adult_a_headers,
    )
    assert invalid.status_code == 422

    deleted = await client.delete(
        f"/api/finance/reserves/{created.json()['id']}", headers=adult_a_headers
    )
    assert deleted.status_code == 204
    listed = await client.get(
        "/api/finance/reserves",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert listed.json() == []


@pytest.mark.asyncio
async def test_fact_and_preference_versions_are_confirmable_and_expirable(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    space_id = (await _spaces(client, adult_a_headers))["personal"]
    fact = await client.post(
        "/api/finance/facts",
        params={"space_id": space_id},
        json={"fact_key": "nursery.schedule", "statement": "Nursery is termly."},
        headers=adult_a_headers,
    )
    confirmed = await client.post(
        f"/api/finance/facts/{fact.json()['id']}/confirm",
        headers=adult_a_headers,
    )
    assert confirmed.json()["status"] == "CONFIRMED"
    revised = await client.put(
        f"/api/finance/facts/{fact.json()['id']}",
        json={
            "statement": "Nursery is due in January, April and September.",
            "evidence_refs": ["commitment:nursery"],
        },
        headers=adult_a_headers,
    )
    assert revised.json()["version"] == 2
    assert revised.json()["supersedes_id"] == fact.json()["id"]
    expired = await client.post(
        f"/api/finance/facts/{revised.json()['id']}/expire",
        headers=adult_a_headers,
    )
    assert expired.json()["status"] == "EXPIRED"

    preference = await client.post(
        "/api/finance/preferences",
        params={"space_id": space_id},
        json={
            "preference_key": "children.activities",
            "statement": "Protect children's activities.",
            "value_kind": "PROTECTED",
        },
        headers=adult_a_headers,
    )
    await client.post(
        f"/api/finance/preferences/{preference.json()['id']}/confirm",
        headers=adult_a_headers,
    )
    revised_preference = await client.put(
        f"/api/finance/preferences/{preference.json()['id']}",
        json={
            "statement": "Protect swimming and music lessons.",
            "value_kind": "VALUED",
            "evidence_refs": [],
        },
        headers=adult_a_headers,
    )
    assert revised_preference.json()["version"] == 2
    assert revised_preference.json()["value_kind"] == "VALUED"

    facts = await client.get(
        "/api/finance/facts",
        params={"space_id": space_id, "include_expired": True},
        headers=adult_a_headers,
    )
    assert [(row["version"], row["status"]) for row in facts.json()] == [
        (2, "EXPIRED"),
        (1, "EXPIRED"),
    ]


@pytest.mark.asyncio
async def test_saved_forecast_uses_visible_balances_plans_and_confirmed_series_only(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = await _spaces(client, adult_a_headers)
    await _spaces(client, adult_b_headers)
    space_id = spaces["personal"]
    today = datetime.now(timezone.utc).astimezone(ZoneInfo("Europe/London")).date()
    tomorrow = today + timedelta(days=1)
    end_date = today + timedelta(days=2)

    current = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        minimum_balance_minor=10_000,
    )
    card = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        label="Full repayment card",
        account_type="CREDIT_CARD",
    )
    await _account(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        label="Included without balance",
        account_type="SAVINGS",
    )
    excluded = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=space_id,
        label="Excluded savings",
        account_type="SAVINGS",
        include_in_cashflow=False,
    )
    household_account = await _account(
        initialized_db,
        user=adult_a_user,
        space_id=spaces["household"],
        label="Household-only balance",
    )
    stale_observed = datetime.combine(today - timedelta(days=2), time(8), tzinfo=timezone.utc)
    async with standalone_db(initialized_db) as db:
        enabled_dom = adult_a_user
        await record_balance_snapshot(
            db,
            user=enabled_dom,
            space_id=space_id,
            account_id=current.id,
            booked_minor=100_000,
            available_minor=95_000,
            credit_limit_minor=None,
            currency="GBP",
            observed_at=stale_observed,
            provider_at=stale_observed,
        )
        await record_balance_snapshot(
            db,
            user=enabled_dom,
            space_id=space_id,
            account_id=card.id,
            booked_minor=2_000,
            available_minor=None,
            credit_limit_minor=10_000,
            currency="GBP",
            observed_at=stale_observed,
            provider_at=stale_observed,
        )
        await record_balance_snapshot(
            db,
            user=enabled_dom,
            space_id=space_id,
            account_id=excluded.id,
            booked_minor=500_000,
            available_minor=500_000,
            credit_limit_minor=None,
            currency="GBP",
            observed_at=stale_observed,
        )
        await record_balance_snapshot(
            db,
            user=enabled_dom,
            space_id=spaces["household"],
            account_id=household_account.id,
            booked_minor=900_000,
            available_minor=900_000,
            credit_limit_minor=None,
            currency="GBP",
            observed_at=stale_observed,
        )
        await db.execute(
            "UPDATE finance_accounts SET primary_spending_account = 1 WHERE id = ?",
            (current.id,),
        )
        now_text = datetime.now(timezone.utc).isoformat()
        recurring_rows = [
            (
                str(uuid.uuid4()),
                space_id,
                "Confirmed salary",
                "SALARY",
                "MONTHLY",
                20_000,
                None,
                None,
                "GBP",
                tomorrow.isoformat(),
                json.dumps([f"account:{current.id}"]),
                10_000,
                "CONFIRMED",
                now_text,
                adult_a_user["family_id"],
                now_text,
                now_text,
                adult_a_user["id"],
            ),
            (
                str(uuid.uuid4()),
                space_id,
                "Variable bill not guessed",
                "BILL",
                "MONTHLY",
                10_000,
                8_000,
                12_000,
                "GBP",
                tomorrow.isoformat(),
                json.dumps([f"account:{current.id}"]),
                10_000,
                "CONFIRMED",
                now_text,
                adult_a_user["family_id"],
                now_text,
                now_text,
                adult_a_user["id"],
            ),
        ]
        await db.executemany(
            """
            INSERT INTO finance_recurring_series
                (id, space_id, name, series_type, interval_kind, expected_minor,
                 low_minor, high_minor, currency, next_expected_date, evidence_json,
                 confidence_bps, status, confirmed_at, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            recurring_rows,
        )
        await db.commit()

    commitment = await client.post(
        "/api/finance/commitments",
        params={"space_id": space_id},
        json={
            "name": "Saved insurance",
            "amount_mode": "EXACT",
            "exact_minor": 30_000,
            "currency": "GBP",
            "recurrence": "ONE_OFF",
            "reviewed_dates": [tomorrow.isoformat()],
            "priority": "PROTECTED",
            "funding_account_id": current.id,
            "already_reserved_minor": 5_000,
        },
        headers=adult_a_headers,
    )
    assert commitment.status_code == 201
    reserve = await client.post(
        "/api/finance/reserves",
        params={"space_id": space_id},
        json={
            "name": "Insurance reserve",
            "allocated_minor": 5_000,
            "currency": "GBP",
            "linked_account_id": current.id,
        },
        headers=adult_a_headers,
    )
    assert reserve.status_code == 201
    goal = await client.post(
        "/api/finance/goals",
        params={"space_id": space_id},
        json={
            "name": "Emergency goal",
            "target_minor": 50_000,
            "deadline": (today + timedelta(days=30)).isoformat(),
            "currently_allocated_minor": 4_000,
            "currency": "GBP",
            "priority": "PROTECTED",
            "allowed_funding_sources": [current.id],
            "emergency_buffer_minor": 1_000,
        },
        headers=adult_a_headers,
    )
    assert goal.status_code == 201
    card_settings = await client.patch(
        f"/api/finance/accounts/{card.id}",
        params={"space_id": space_id},
        json={
            "card_paid_in_full": True,
            "card_settlement_account_id": current.id,
            "card_statement_close_day": today.day,
            "card_repayment_day": tomorrow.day,
        },
        headers=adult_a_headers,
    )
    assert card_settings.status_code == 200, card_settings.text
    assert card_settings.json()["card_settlement_account_id"] == current.id

    made_up = await client.post(
        "/api/finance/forecasts",
        params={"space_id": space_id},
        json={
            "end_date": end_date.isoformat(),
            "accounts": [{"account_id": current.id, "opening_balance_minor": 999_999}],
        },
        headers=adult_a_headers,
    )
    assert made_up.status_code == 422

    created = await client.post(
        "/api/finance/forecasts",
        params={"space_id": space_id},
        json={
            "end_date": end_date.isoformat(),
            "currency": "GBP",
            "household_buffer_minor": 2_000,
        },
        headers=adult_a_headers,
    )
    assert created.status_code == 201, created.text
    forecast = created.json()
    assert forecast["source"] == "SAVED"
    assert forecast["data_status"] == "PARTIAL"
    assert forecast["household_buffer_minor"] == 3_000
    requested_events = [
        event for event in forecast["events"]
        if event["day"] <= end_date.isoformat()
    ]
    assert [event["kind"] for event in requested_events] == [
        "income",
        "expense",
        "transfer",
        "commitment",
    ]
    assert [event["amount_minor"] for event in requested_events] == [
        20_000,
        -12_000,
        -2_000,
        -30_000,
    ]
    first_accounts = {row["account_id"]: row for row in forecast["days"][0]["accounts"]}
    assert first_accounts[current.id] == {
        "account_id": current.id,
        "balance_minor": 95_000,
        "floor_minor": 19_000,
        "headroom_minor": 76_000,
    }
    assert first_accounts[card.id]["balance_minor"] == -2_000
    assert first_accounts[card.id]["floor_minor"] == -10_000
    assert excluded.id not in first_accounts
    assert household_account.id not in first_accounts
    assert [day["household_liquid_minor"] for day in forecast["days"][:3]] == [
        95_000,
        71_000,
        71_000,
    ]
    assert [day["household_free_minor"] for day in forecast["days"][:3]] == [
        73_000,
        49_000,
        49_000,
    ]
    assert forecast["minimum_household_free_minor"] == 49_000
    notes = " ".join(forecast["input_notes"])
    assert date.fromisoformat(forecast["end_date"]) >= today + timedelta(days=540)
    assert "standard 18-month outlook" in notes
    assert "only current through" in notes
    assert "variable repeating" in notes
    assert "no balance has been saved" in notes
    assert "second reserve" in notes

    safe = await client.post(
        "/api/finance/safe-to-spend",
        json={
            "forecast_id": forecast["id"],
            "route": "direct",
            "spend_date": today.isoformat(),
            "account_id": current.id,
        },
        headers=adult_a_headers,
    )
    assert safe.status_code == 200
    safe_body = safe.json()
    assert safe_body["answer_mode"] == "ESTIMATED_RANGE"
    assert safe_body["amount_minor"] is None
    assert safe_body["low_minor"] is not None
    assert safe_body["high_minor"] is not None
    assert 0 <= safe_body["low_minor"] <= safe_body["high_minor"]
    assert "SAVED_OUTLOOK_GAPS_SMALL_RANGE_ESTIMATE" in safe_body["refusal_reasons"]

    card_estimate = await client.post(
        "/api/finance/safe-to-spend",
        json={
            "forecast_id": forecast["id"],
            "route": "full_repayment_card",
            "spend_date": today.isoformat(),
            "card_account_id": "card-without-saved-timing",
        },
        headers=adult_a_headers,
    )
    assert card_estimate.status_code == 200
    card_estimate_body = card_estimate.json()
    assert card_estimate_body["answer_mode"] == "ESTIMATED_RANGE"
    assert 0 <= card_estimate_body["low_minor"] <= card_estimate_body["high_minor"]
    assert (
        "CARD_TIMING_NOT_INCLUDED_DIRECT_ACCOUNT_ESTIMATE"
        in card_estimate_body["refusal_reasons"]
    )

    overview_response = await client.post(
        "/api/finance/forecasts/overview",
        params={"space_id": space_id},
        json={
            "end_date": end_date.isoformat(),
            "currency": "GBP",
            "household_buffer_minor": 2_000,
        },
        headers=adult_a_headers,
    )
    assert overview_response.status_code == 201, overview_response.text
    overview = overview_response.json()
    assert overview["id"] == forecast["id"]
    assert overview["events"] == forecast["events"]
    assert overview["opening_accounts"] == forecast["days"][0]["accounts"]
    assert overview["days"] == [
        {
            "day": day["day"],
            "household_liquid_minor": day["household_liquid_minor"],
            "household_free_minor": day["household_free_minor"],
            "constraints_passed_through_day": day["constraints_passed_through_day"],
        }
        for day in forecast["days"]
    ]

    stored = await client.get(
        f"/api/finance/forecasts/{forecast['id']}",
        headers=adult_a_headers,
    )
    assert stored.status_code == 200
    assert stored.json() == forecast
    private_attempt = await client.get(
        f"/api/finance/forecasts/{forecast['id']}", headers=adult_b_headers
    )
    assert private_attempt.status_code == 404
    assert household_account.id not in created.text
    async with aiosqlite.connect(initialized_db) as db:
        snapshots = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM finance_forecast_snapshots WHERE space_id = ?",
                    (space_id,),
                )
            ).fetchone()
        )[0]
        events = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM finance_forecast_events WHERE space_id = ?",
                    (space_id,),
                )
            ).fetchone()
        )[0]
        days = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM finance_forecast_days WHERE space_id = ?",
                    (space_id,),
                )
            ).fetchone()
        )[0]
    assert (snapshots, events, days) == (
        1,
        len(forecast["events"]),
        len(forecast["days"]),
    )
