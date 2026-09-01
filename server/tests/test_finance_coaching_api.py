import json
from datetime import date, datetime, timezone

import aiosqlite
import pytest

from app.database import standalone_db
from app.models.finance import FinanceAccountCreate, NormalisedSourceTransaction
from app.services.finance.forecast import (
    ForecastAccount,
    ForecastEvent,
    ForecastSnapshot,
    canonical_snapshot_payload,
    run_forecast,
)
from app.services.finance.ledger import create_finance_account, import_source_transactions
from app.services.finance.money import Money


@pytest.mark.asyncio
async def test_saved_coaching_loop_is_evidence_bound_and_idempotent(
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
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    space_id = next(item["id"] for item in spaces if item["kind"] == "personal")
    user = adult_a_user
    observed = datetime(2026, 8, 1, 8, tzinfo=timezone.utc)

    async with standalone_db(initialized_db) as db:
        current = await create_finance_account(
            db,
            user=user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="Operating current",
                institution="Fixture Bank",
                account_type="CURRENT",
                currency="GBP",
            ),
        )
        savings = await create_finance_account(
            db,
            user=user,
            space_id=space_id,
            body=FinanceAccountCreate(
                label="House goal",
                institution="Fixture Bank",
                account_type="SAVINGS",
                currency="GBP",
            ),
        )
        source_rows = []
        for month in range(2, 8):
            source_rows.extend(
                (
                    NormalisedSourceTransaction(
                        source_kind="PROVIDER",
                        source_batch_id="coaching-fixture",
                        source_transaction_id=f"salary-{month}",
                        booking_date=date(2026, month, 1),
                        pending_status="POSTED",
                        amount_minor=400_000,
                        currency="GBP",
                        description="Example School payroll",
                        observed_at=observed,
                    ),
                    NormalisedSourceTransaction(
                        source_kind="PROVIDER",
                        source_batch_id="coaching-fixture",
                        source_transaction_id=f"spend-{month}",
                        booking_date=date(2026, month, 15),
                        pending_status="POSTED",
                        amount_minor=-250_000,
                        currency="GBP",
                        description="Ordinary household spend",
                        observed_at=observed,
                    ),
                )
            )
        source_rows.extend(
            (
                NormalisedSourceTransaction(
                    source_kind="PROVIDER",
                    source_batch_id="coaching-fixture",
                    source_transaction_id="annual-insurance",
                    booking_date=date(2026, 4, 15),
                    pending_status="POSTED",
                    amount_minor=-85_000,
                    currency="GBP",
                    description="Admiral",
                    observed_at=observed,
                ),
                NormalisedSourceTransaction(
                    source_kind="PROVIDER",
                    source_batch_id="coaching-fixture",
                    source_transaction_id="windfall",
                    booking_date=date(2026, 7, 20),
                    pending_status="POSTED",
                    amount_minor=1_000_000,
                    currency="GBP",
                    description="One-off gift",
                    observed_at=observed,
                ),
            )
        )
        await import_source_transactions(
            db,
            user=user,
            space_id=space_id,
            account_id=current.id,
            observations=source_rows,
        )
        salary_ids = [
            row[0]
            for row in await (
                await db.execute(
                    "SELECT id FROM finance_transactions WHERE space_id = ? "
                    "AND amount_minor = 400000 ORDER BY canonical_date",
                    (space_id,),
                )
            ).fetchall()
        ]
        now = observed.isoformat()
        await db.execute(
            "INSERT INTO finance_categories "
            "(id, space_id, name, spending_type, family_id, created_at, updated_at, created_by) "
            "VALUES ('household-category', ?, 'Household', 'FLEXIBLE', ?, ?, ?, ?)",
            (space_id, user["family_id"], now, now, user["id"]),
        )
        await db.execute(
            "UPDATE finance_transactions SET primary_category_id = 'household-category' "
            "WHERE space_id = ? AND amount_minor < 0",
            (space_id,),
        )
        await db.execute(
            """
            INSERT INTO finance_recurring_series
                (id, space_id, detection_key, name, series_type, interval_kind,
                 expected_minor, currency, next_expected_date, evidence_json,
                 confidence_bps, status, confirmed_at, family_id,
                 created_at, updated_at, created_by)
            VALUES ('confirmed-salary', ?, 'salary', 'Example School salary', 'SALARY',
                    'MONTHLY', 400000, 'GBP', '2026-08-01', ?, 10000,
                    'CONFIRMED', ?, ?, ?, ?, ?)
            """,
            (space_id, json.dumps(salary_ids), now, user["family_id"], now, now, user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_commitments
                (id, space_id, name, amount_mode, exact_minor, currency,
                 recurrence, reviewed_dates_json, priority, status, family_id,
                 created_at, updated_at, created_by)
            VALUES ('car-insurance', ?, 'Car insurance', 'EXACT', 85000, 'GBP',
                    'ANNUAL', '["2027-04-15"]', 'PROTECTED', 'ACTIVE', ?, ?, ?, ?)
            """,
            (space_id, user["family_id"], now, now, user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_goals
                (id, space_id, name, target_minor, deadline,
                 currently_allocated_minor, currency, priority,
                 allowed_funding_sources_json, emergency_buffer_minor,
                 status, family_id, created_at, updated_at, created_by)
            VALUES ('house-goal', ?, 'House fund', 12000000, '2030-08-01', 0,
                    'GBP', 'IMPORTANT', '[]', 0, 'ACTIVE', ?, ?, ?, ?)
            """,
            (space_id, user["family_id"], now, now, user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_findings
                (id, space_id, finding_key, finding_type, title, observation,
                 saving_low_minor, saving_high_minor, currency, confidence_bps,
                 effort, status, data_through_date, detected_at, family_id,
                 created_at, updated_at, created_by)
            VALUES ('accepted-habit-finding', ?, 'habit-fixture',
                    'ANNUALISED_SMALL_COST', 'Pause optional gadgets',
                    'Reviewed optional gadget lines can be paused.', 10000, 20000,
                    'GBP', 9000, 1, 'ACCEPTED', '2026-07-31', ?, ?, ?, ?, ?)
            """,
            (space_id, now, user["family_id"], now, now, user["id"]),
        )
        snapshot = ForecastSnapshot(
            start_date=date(2026, 8, 1),
            end_date=date(2027, 2, 1),
            timezone="Europe/London",
            currency="GBP",
            accounts=(
                ForecastAccount(current.id, Money(500_000, "GBP")),
                ForecastAccount(savings.id, Money(100_000, "GBP")),
            ),
            events=tuple(
                ForecastEvent(
                    id=f"salary:{month}",
                    day=date(2026 if month >= 8 else 2027, month, 1),
                    account_id=current.id,
                    amount=Money(400_000, "GBP"),
                    kind="income",
                    sequence=100,
                )
                for month in (8, 9, 10, 11, 12, 1, 2)
            ),
        )
        result = run_forecast(snapshot)
        await db.execute(
            "UPDATE finance_accounts SET data_through_at = ?, updated_at = ? "
            "WHERE id IN (?, ?)",
            (now, now, current.id, savings.id),
        )
        await db.execute(
            """
            INSERT INTO finance_forecast_snapshots
                (id, space_id, input_snapshot_digest, engine_version,
                 household_timezone, currency, start_date, end_date,
                 household_buffer_minor, canonical_input_json, passed,
                 minimum_household_free_minor, minimum_household_free_date,
                 data_through_at, family_id, created_at, updated_at, created_by)
            VALUES ('saved-forecast', ?, ?, ?, 'Europe/London', 'GBP',
                    '2026-08-01', '2027-02-01', 0, ?, 1, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                space_id,
                result.snapshot_digest,
                result.engine_version,
                json.dumps(
                    {
                        "engine_input": canonical_snapshot_payload(snapshot),
                        "source": "SAVED",
                        "data_status": "CURRENT",
                        "input_notes": [],
                        "unsafe_safe_to_spend_routes": [],
                        "card_routes": [],
                    }
                ),
                result.minimum_household_free_minor,
                result.minimum_household_free_date.isoformat(),
                now,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        await db.commit()

    generated = await client.post(
        "/api/finance/plans/generate",
        params={"space_id": space_id},
        json={"goal_id": "house-goal"},
        headers=adult_a_headers,
    )
    assert generated.status_code == 200, generated.text
    plan_set = generated.json()
    plans = plan_set["plans"]
    assert plan_set["recommendation_effort_level"] == "MEDIUM"
    assert plan_set["recommendation_strategy"] == "TARGET_DATE"
    assert [item["effort_level"] for item in plans] == ["EASY", "MEDIUM", "HARD"]
    assert [item["strategy"] for item in plans] == [
        "MINIMAL_DISRUPTION",
        "TARGET_DATE",
        "AGGRESSIVE",
    ]
    assert {item["required_monthly_minor"] for item in plans} == {244_898}
    assert all(item["answer_basis"] == "BOUNDED" for item in plans)
    assert all(item["forecast_coverage_end"] == "2027-02-01" for item in plans)
    assert all(item["feasible"] is True for item in plans)
    assert [item["planned_monthly_saving_minor"] for item in plans] == sorted(
        item["planned_monthly_saving_minor"] for item in plans
    )
    assert all(
        item["planned_monthly_saving_minor"] <= item["required_monthly_minor"]
        for item in plans
    )
    for item in plans:
        assert item["projected_amount_at_target_minor"] == (
            item["planned_monthly_saving_minor"] * 49
        )
        assert item["goal_shortfall_at_target_minor"] == max(
            0, 12_000_000 - item["projected_amount_at_target_minor"]
        )
        assert item["shortfall_minor"] == item["goal_shortfall_at_target_minor"]
        assert item["monthly_change_minor"] == item["planned_monthly_saving_minor"]
        assert sum(category["reduction_minor"] for category in item["categories"]) == (
            item["achieved_reduction_minor"]
        )
        assert all(
            not category["protected"] or category["reduction_minor"] == 0
            for category in item["categories"]
        )
        if item["goal_shortfall_at_target_minor"] == 0:
            assert item["supported_goal_date"] <= item["target_date"]
        elif item["planned_monthly_saving_minor"] > 0:
            assert item["supported_goal_date"] > item["target_date"]
        copy = " ".join([item["rationale"], *item["assumptions"]]).casefold()
        assert all(
            phrase not in copy
            for phrase in ("refuse", "cannot model", "stale", "refresh")
        )
    target = next(item for item in plans if item["strategy"] == "TARGET_DATE")
    assert target["feasible"] is True
    async with aiosqlite.connect(initialized_db) as check:
        check.row_factory = aiosqlite.Row
        plan_row = await (
            await check.execute(
                "SELECT input_snapshot_json FROM finance_plans WHERE id = ?", (target["id"],)
            )
        ).fetchone()
    plan_inputs = json.loads(plan_row["input_snapshot_json"])
    assert plan_inputs["monthly_income_minor"] == 400_000  # windfall excluded
    assert plan_inputs["commitment_monthly_minor"] == 0  # prior annual payment not doubled

    activated = await client.post(
        f"/api/finance/plans/{target['id']}/activate", headers=adult_a_headers
    )
    assert activated.status_code == 200, activated.text
    reversed_transfer = await client.post(
        "/api/finance/payday-actions",
        json={
            "plan_id": target["id"],
            "source_account_id": savings.id,
            "destination_account_id": current.id,
        },
        headers=adult_a_headers,
    )
    assert reversed_transfer.status_code == 409
    payday = await client.post(
        "/api/finance/payday-actions",
        json={
            "plan_id": target["id"],
            "source_account_id": current.id,
            "destination_account_id": savings.id,
        },
        headers=adult_a_headers,
    )
    assert payday.status_code == 200, payday.text
    payday_body = payday.json()
    assert payday_body["amount_minor"] == target["monthly_change_minor"]
    assert payday_body["answer_mode"] == "CURRENT_EXACT"
    assert payday_body["data_through_at"] == observed.isoformat()

    habit = await client.post(
        "/api/finance/habits",
        params={"space_id": space_id},
        json={
            "finding_id": "accepted-habit-finding",
            "slot": "PRIMARY",
            "name": "Pause optional gadgets",
            "trigger": "An optional gadget is proposed",
            "normalized_items": ["optional_gadget"],
            "start_date": "2026-08-01",
            "review_date": "2026-08-28",
            "fallback": "Keep only the duplicate-gadget pause",
        },
        headers=adult_a_headers,
    )
    assert habit.status_code == 200, habit.text
    assert habit.json()["expected_saving_low_minor"] == 10_000
    unknown_habit = await client.post(
        "/api/finance/habits",
        params={"space_id": space_id},
        json={
            "slot": "SECONDARY",
            "name": "Review optional extras",
            "trigger": "An optional extra is proposed",
            "purposes": ["extras"],
            "start_date": "2026-08-01",
            "review_date": "2026-08-28",
            "fallback": "Stop if it adds friction",
        },
        headers=adult_a_headers,
    )
    assert unknown_habit.status_code == 200, unknown_habit.text
    assert unknown_habit.json()["expected_saving_high_minor"] == 0

    invalid_proposal = await client.post(
        "/api/finance/proposals",
        params={"space_id": space_id},
        json={
            "reviewed": True,
            "source_kind": "BASKET",
            "name": "Garden shade",
            "amount_low_minor": 10_000,
            "amount_high_minor": 10_000,
            "desired_date": "2026-08-10",
            "payment_account_id": current.id,
            "lines": [{"name": "Garden shade", "amount_minor": 9_000}],
        },
        headers=adult_a_headers,
    )
    assert invalid_proposal.status_code == 422
    proposal_body = {
        "reviewed": True,
        "source_kind": "BASKET",
        "source_metadata": {"quoted_by": "Fixture retailer"},
        "name": "Garden shade",
        "amount_low_minor": 10_000,
        "amount_high_minor": 10_000,
        "desired_date": "2026-08-10",
        "later_date": "2026-09-01",
        "cheaper_alternative_minor": 8_000,
        "payment_account_id": current.id,
        "lines": [
            {
                "name": "Garden shade",
                "amount_minor": 10_000,
                "normalized_item": "garden_shade_v1",
            }
        ],
    }
    unsuitable_account = await client.post(
        "/api/finance/proposals",
        params={"space_id": space_id},
        json={**proposal_body, "payment_account_id": savings.id},
        headers=adult_a_headers,
    )
    assert unsuitable_account.status_code == 409
    proposal = await client.post(
        "/api/finance/proposals",
        params={"space_id": space_id},
        json=proposal_body,
        headers=adult_a_headers,
    )
    assert proposal.status_code == 200, proposal.text
    proposal_replay = await client.post(
        "/api/finance/proposals",
        params={"space_id": space_id},
        json=proposal_body,
        headers=adult_a_headers,
    )
    assert proposal_replay.status_code == 200, proposal_replay.text
    assert proposal_replay.json()["id"] == proposal.json()["id"]
    async with aiosqlite.connect(initialized_db) as stale:
        await stale.execute(
            "UPDATE finance_forecast_snapshots SET data_through_at = '2026-07-20T08:00:00+00:00' "
            "WHERE id = 'saved-forecast'"
        )
        await stale.commit()
    evaluated = await client.post(
        f"/api/finance/proposals/{proposal.json()['id']}/evaluate",
        json={"forecast_id": "saved-forecast"},
        headers=adult_a_headers,
    )
    assert evaluated.status_code == 200, evaluated.text
    rationale = evaluated.json()["rationale"]
    assert rationale.startswith("Yes.")
    assert "confidence" not in rationale.lower()
    assert evaluated.json()["historical_context"]["confidence_bps"] == 8000
    assert all(
        scenario["freshness_mode"] == "ESTIMATED_RANGE"
        for scenario in evaluated.json()["scenarios"]
    )

    later_proposal = await client.post(
        "/api/finance/proposals",
        params={"space_id": space_id},
        json={
            **proposal_body,
            "source_metadata": {"quoted_by": "Later fixture retailer"},
            "name": "Garden shade for next summer",
            "desired_date": "2028-06-10",
            "later_date": "2028-07-01",
            "lines": [
                {
                    "name": "Garden shade for next summer",
                    "amount_minor": 10_000,
                    "normalized_item": "garden_shade_v2",
                }
            ],
        },
        headers=adult_a_headers,
    )
    assert later_proposal.status_code == 200, later_proposal.text
    later_evaluation = await client.post(
        f"/api/finance/proposals/{later_proposal.json()['id']}/evaluate",
        json={"forecast_id": "saved-forecast"},
        headers=adult_a_headers,
    )
    assert later_evaluation.status_code == 200, later_evaluation.text
    assert later_evaluation.json()["verdict"] in {
        "YES",
        "YES_IF",
        "NOT_YET",
        "NO_UNDER_CURRENT_PLAN",
    }
    assert all(
        scenario["status"] != "OUTSIDE_FORECAST"
        for scenario in later_evaluation.json()["scenarios"]
    )
    assert "nearest saved day" in " ".join(
        assumption
        for scenario in later_evaluation.json()["scenarios"]
        for assumption in scenario.get("assumptions", [])
    ).lower()

    default_preference = await client.get(
        "/api/finance/report-preferences",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert default_preference.status_code == 200, default_preference.text
    assert default_preference.json()["notification_channel"] == "IN_APP"
    preference_body = {
        "locale": "en",
        "daily_time": "07:00:00",
        "enabled": True,
        "notification_channel": "BROWSER",
        "quiet_hours_start": "22:00:00",
        "quiet_hours_end": "07:00:00",
        "underfunded_commitment_threshold_minor": 12_500,
        "goal_movement_threshold_minor": 20_000,
        "missed_payday_alerts": True,
        "selected_return_deadline_alerts": False,
        "tone": "GENTLE",
        "default_spend_account_id": current.id,
        "extra_cash_buffer_minor": 5_000,
        "writing_mode": "LOCAL",
        "allow_dated_estimates": False,
    }
    preference = await client.put(
        "/api/finance/report-preferences",
        params={"space_id": space_id},
        json=preference_body,
        headers=adult_a_headers,
    )
    assert preference.status_code == 200, preference.text
    loaded_preference = await client.get(
        "/api/finance/report-preferences",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert loaded_preference.status_code == 200, loaded_preference.text
    for key, value in preference_body.items():
        assert loaded_preference.json()[key] == value
    assert loaded_preference.json()["ordinary_purchase_alerts"] is False
    assert loaded_preference.json()["group_related_alerts"] is True
    daily = await client.post(
        "/api/finance/reports/DAILY/refresh",
        params={"space_id": space_id, "as_of": "2026-08-01"},
        headers=adult_a_headers,
    )
    async def fail_if_report_is_rebuilt(*args, **kwargs):
        del args, kwargs
        raise AssertionError("an unchanged report should be served without rebuilding it")

    with monkeypatch.context() as replay_patch:
        replay_patch.setattr(
            "app.services.finance.coaching._period_summary",
            fail_if_report_is_rebuilt,
        )
        replay = await client.post(
            "/api/finance/reports/DAILY/refresh",
            params={"space_id": space_id, "as_of": "2026-08-01"},
            headers=adult_a_headers,
        )
    assert daily.status_code == replay.status_code == 200
    assert daily.json()["id"] == replay.json()["id"]
    assert daily.json()["primary_action"]["kind"] == "PAYDAY_TRANSFER"
    safe_answer = daily.json()["summary"]["safe_to_spend"]
    assert safe_answer["answer_mode"] == "ESTIMATED_RANGE"
    assert safe_answer["low_minor"] is not None
    assert safe_answer["high_minor"] is not None
    for kind in ("WEEKLY", "MONTHLY"):
        report = await client.post(
            f"/api/finance/reports/{kind}/refresh",
            params={"space_id": space_id, "as_of": "2026-08-01"},
            headers=adult_a_headers,
        )
        assert report.status_code == 200, report.text
        components = report.json()["summary"]["variance_components"]
        assert sum(components.values()) == report.json()["summary"]["net_variance_minor"]

    transfer_amount = payday_body["amount_minor"]
    async with standalone_db(initialized_db) as db:
        imported = await import_source_transactions(
            db,
            user=user,
            space_id=space_id,
            account_id=current.id,
            observations=[
                NormalisedSourceTransaction(
                    source_kind="PROVIDER",
                    source_batch_id="payday-transfer",
                    source_transaction_id="payday-out",
                    booking_date=date(2026, 8, 1),
                    pending_status="POSTED",
                    amount_minor=-transfer_amount,
                    currency="GBP",
                    description="Transfer to savings",
                    observed_at=observed,
                )
            ],
        )
        incoming = await import_source_transactions(
            db,
            user=user,
            space_id=space_id,
            account_id=savings.id,
            observations=[
                NormalisedSourceTransaction(
                    source_kind="PROVIDER",
                    source_batch_id="payday-transfer",
                    source_transaction_id="payday-in",
                    booking_date=date(2026, 8, 1),
                    pending_status="POSTED",
                    amount_minor=transfer_amount,
                    currency="GBP",
                    description="Transfer from current",
                    observed_at=observed,
                )
            ],
        )
        await db.execute(
            """
            UPDATE finance_transaction_relations
            SET status = 'CONFIRMED', method = 'USER', confidence_bps = 10000,
                updated_at = CURRENT_TIMESTAMP, created_by = ?
            WHERE space_id = ? AND family_id = ?
              AND from_transaction_id = ? AND to_transaction_id = ?
              AND relation_type = 'INTERNAL_TRANSFER'
            """,
            (
                user["id"],
                space_id,
                user["family_id"],
                imported.transaction_ids[0],
                incoming.transaction_ids[0],
            ),
        )
        await db.commit()
    matched = await client.post(
        "/api/finance/payday-actions/match",
        params={"space_id": space_id, "as_of": "2026-08-01"},
        headers=adult_a_headers,
    )
    assert matched.status_code == 200, matched.text
    assert matched.json()[0]["status"] == "MATCHED"
    after_match = await client.post(
        "/api/finance/reports/DAILY/refresh",
        params={"space_id": space_id, "as_of": "2026-08-01"},
        headers=adult_a_headers,
    )
    assert after_match.status_code == 200, after_match.text
    assert after_match.json()["summary"]["current"]["spend_minor"] == 0
    assert after_match.json()["summary"]["current"]["income_minor"] == 0

    dated_guidance = await client.post(
        "/api/finance/plans/generate",
        params={"space_id": space_id},
        json={"goal_id": "house-goal"},
        headers=adult_a_headers,
    )
    assert dated_guidance.status_code == 200, dated_guidance.text
    dated_plans = dated_guidance.json()["plans"]
    assert len(dated_plans) == 3
    assert all(item["answer_basis"] == "BOUNDED" for item in dated_plans)
    for item in dated_plans:
        copy = " ".join([item["rationale"], *item["assumptions"]]).casefold()
        assert all(
            phrase not in copy
            for phrase in ("refuse", "cannot model", "stale", "refresh")
        )
    dated_medium = next(
        item for item in dated_plans if item["effort_level"] == "MEDIUM"
    )
    selected = await client.post(
        f"/api/finance/plans/{dated_medium['id']}/activate", headers=adult_a_headers
    )
    assert selected.status_code == 200, selected.text

    async with aiosqlite.connect(initialized_db) as evidence_db:
        row = await (
            await evidence_db.execute(
                "SELECT canonical_input_json FROM finance_forecast_snapshots "
                "WHERE id = 'saved-forecast'"
            )
        ).fetchone()
        partial_payload = json.loads(row[0])
        partial_payload["data_status"] = "PARTIAL"
        await evidence_db.execute(
            "UPDATE finance_forecast_snapshots SET canonical_input_json = ?, "
            "data_through_at = ? WHERE id = 'saved-forecast'",
            (json.dumps(partial_payload), observed.isoformat()),
        )
        await evidence_db.commit()
    partial = await client.post(
        "/api/finance/plans/generate",
        params={"space_id": space_id},
        json={"goal_id": "house-goal"},
        headers=adult_a_headers,
    )
    assert partial.status_code == 200, partial.text
    partial_plans = partial.json()["plans"]
    assert len(partial_plans) == 3
    assert all(item["answer_basis"] == "BOUNDED" for item in partial_plans)
    assert all(item["feasible"] is True for item in partial_plans)
    partial_medium = next(
        item for item in partial_plans if item["effort_level"] == "MEDIUM"
    )
    selected = await client.post(
        f"/api/finance/plans/{partial_medium['id']}/activate", headers=adult_a_headers
    )
    assert selected.status_code == 200, selected.text

    async with aiosqlite.connect(initialized_db) as evidence_db:
        await evidence_db.execute(
            "UPDATE finance_forecast_snapshots SET deleted_at = ? "
            "WHERE id = 'saved-forecast'",
            (observed.isoformat(),),
        )
        await evidence_db.commit()
    without_forecast = await client.post(
        "/api/finance/plans/generate",
        params={"space_id": space_id},
        json={"goal_id": "house-goal"},
        headers=adult_a_headers,
    )
    assert without_forecast.status_code == 200, without_forecast.text
    no_forecast_plans = without_forecast.json()["plans"]
    assert len(no_forecast_plans) == 3
    assert all(item["answer_basis"] == "BOUNDED" for item in no_forecast_plans)
    no_forecast_medium = next(
        item for item in no_forecast_plans if item["effort_level"] == "MEDIUM"
    )
    selected = await client.post(
        f"/api/finance/plans/{no_forecast_medium['id']}/activate",
        headers=adult_a_headers,
    )
    assert selected.status_code == 200, selected.text
