import json
from datetime import date

import aiosqlite
import pytest

from app.database import _run_migrations, init_db, standalone_db
from app.services.finance.coaching import (
    _active_plan_state,
    _monthly_contribution_dates,
    _months_to_deadline,
    _purchase_scenario,
    _supported_date,
    _trajectory,
    _uncommitted_monthly_surplus,
)
from app.services.finance.forecast import ForecastAccount, ForecastSnapshot
from app.services.finance.money import Money


async def _personal_space_id(client, headers: dict) -> str:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200, response.text
    return next(item["id"] for item in response.json() if item["kind"] == "personal")


def test_improved_spending_does_not_release_an_active_goals_allocation() -> None:
    assert _uncommitted_monthly_surplus(400_000, 400_000) == 0
    assert _uncommitted_monthly_surplus(450_000, 400_000) == 50_000


async def _create_goal(
    client,
    *,
    headers: dict,
    space_id: str,
    name: str,
    target_minor: int,
    deadline: str,
    currency: str = "GBP",
) -> dict:
    response = await client.post(
        "/api/finance/goals",
        params={"space_id": space_id},
        json={
            "name": name,
            "target_minor": target_minor,
            "deadline": deadline,
            "currently_allocated_minor": 0,
            "currency": currency,
            "priority": "IMPORTANT",
            "allowed_funding_sources": [],
            "emergency_buffer_minor": 0,
        },
        headers=headers,
    )
    assert response.status_code == 201, response.text
    return response.json()


async def _generate_and_activate_medium(
    client,
    *,
    headers: dict,
    space_id: str,
    goal_id: str,
) -> tuple[dict, dict]:
    generated = await client.post(
        "/api/finance/plans/generate",
        params={"space_id": space_id},
        json={"goal_id": goal_id},
        headers=headers,
    )
    assert generated.status_code == 200, generated.text
    medium = next(
        plan for plan in generated.json()["plans"] if plan["effort_level"] == "MEDIUM"
    )
    activated = await client.post(
        f"/api/finance/plans/{medium['id']}/activate",
        headers=headers,
    )
    assert activated.status_code == 200, activated.text
    return generated.json(), medium


async def _seed_cashflow(
    db_path: str,
    *,
    user: dict,
    space_id: str,
) -> None:
    now = "2026-08-01T08:00:00+00:00"
    async with standalone_db(db_path) as db:
        for category_id, name in (
            ("dining", "Dining out"),
            ("shopping", "Shopping"),
        ):
            await db.execute(
                "INSERT INTO finance_categories "
                "(id, space_id, name, spending_type, family_id, created_at, "
                "updated_at, created_by) VALUES (?, ?, ?, 'FLEXIBLE', ?, ?, ?, ?)",
                (
                    category_id,
                    space_id,
                    name,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
        for month in range(2, 8):
            for category_id, amount_minor in (("dining", -120_000), ("shopping", -80_000)):
                transaction_id = f"{category_id}-{month}"
                await db.execute(
                    """
                    INSERT INTO finance_transactions
                        (id, space_id, account_id, canonical_date, amount_minor,
                         currency, state, source_kind, description,
                         cleaned_description, primary_category_id, data_through_at,
                         family_id, created_at, updated_at, created_by)
                    VALUES (?, ?, 'cashflow-account', ?, ?, 'GBP', 'POSTED',
                            'MANUAL', ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        transaction_id,
                        space_id,
                        f"2026-{month:02d}-15",
                        amount_minor,
                        category_id,
                        category_id,
                        category_id,
                        now,
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
        await db.execute(
            """
            INSERT INTO finance_recurring_series
                (id, space_id, detection_key, name, series_type, interval_kind,
                 expected_minor, currency, next_expected_date, evidence_json,
                 confidence_bps, status, confirmed_at, family_id,
                 created_at, updated_at, created_by)
            VALUES ('multi-goal-salary', ?, 'multi-goal-salary', 'Salary',
                    'SALARY', 'MONTHLY', 400000, 'GBP', '2026-08-31', '[]',
                    10000, 'CONFIRMED', ?, ?, ?, ?, ?)
            """,
            (space_id, now, user["family_id"], now, now, user["id"]),
        )
        await db.commit()


def test_contribution_dates_keep_the_original_day_and_count_only_before_deadline() -> None:
    first = date(2026, 8, 31)
    deadline = date(2027, 8, 1)
    dates = _monthly_contribution_dates(first, deadline)

    assert len(dates) == 12
    assert dates[0] == date(2026, 8, 31)
    assert dates[-1] == date(2027, 7, 31)
    assert _months_to_deadline(
        date(2026, 8, 1),
        deadline,
        first_contribution_date=first,
    ) == 12

    january_dates = _monthly_contribution_dates(
        date(2027, 1, 31),
        date(2027, 4, 30),
    )
    assert january_dates == (
        date(2027, 1, 31),
        date(2027, 2, 28),
        date(2027, 3, 31),
        date(2027, 4, 30),
    )
    assert _supported_date(
        date(2027, 1, 1),
        400,
        100,
        first_contribution_date=date(2027, 1, 31),
    ) == date(2027, 4, 30)


def test_purchase_delay_uses_the_combined_active_monthly_amount() -> None:
    snapshot = ForecastSnapshot(
        start_date=date(2026, 8, 1),
        end_date=date(2026, 9, 30),
        timezone="Europe/London",
        currency="GBP",
        accounts=(ForecastAccount("current", Money(500_000, "GBP")),),
        events=(),
    )
    scenario = _purchase_scenario(
        {
            "id": "combined-delay",
            "recurrence": "ONE_OFF",
            "payment_account_id": "current",
        },
        snapshot,
        scenario="BUY_NOW",
        day=date(2026, 8, 2),
        amount_minor=60_000,
        active_planned_monthly_minor=30_000,
        freshness={
            "mode": "CURRENT_EXACT",
            "data_through_date": "2026-08-01",
            "unobserved_allowance_minor": 0,
        },
    )
    assert scenario["estimated_goal_delay_months"] == 2


@pytest.mark.asyncio
async def test_active_plan_index_migration_is_idempotent_and_goal_scoped(db_path: str) -> None:
    await init_db(db_path)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await db.execute("DROP INDEX IF EXISTS idx_finance_plan_one_active_per_goal")
        await db.execute(
            "CREATE UNIQUE INDEX idx_finance_plan_one_active "
            "ON finance_plans(space_id) "
            "WHERE status = 'ACTIVE' AND deleted_at IS NULL"
        )
        await db.commit()

        await _run_migrations(db)
        await _run_migrations(db)

    async with aiosqlite.connect(db_path) as db:
        indexes = {
            row[0]: row[1]
            for row in await (
                await db.execute(
                    "SELECT name, sql FROM sqlite_master "
                    "WHERE type = 'index' AND tbl_name = 'finance_plans'"
                )
            ).fetchall()
        }
    assert "idx_finance_plan_one_active" not in indexes
    scoped_sql = indexes["idx_finance_plan_one_active_per_goal"]
    assert "space_id, goal_id" in scoped_sql
    assert "status = 'ACTIVE'" in scoped_sql


@pytest.mark.asyncio
async def test_activation_reprices_choices_when_another_goal_claimed_the_budget(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
) -> None:
    async def fixture_local_today(db, *, family_id: str) -> date:
        del db, family_id
        return date(2026, 8, 1)

    monkeypatch.setattr(
        "app.services.finance.coaching._local_today",
        fixture_local_today,
    )
    space_id = await _personal_space_id(client, adult_a_headers)
    await _seed_cashflow(initialized_db, user=adult_a_user, space_id=space_id)
    first_goal = await _create_goal(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        name="First goal",
        target_minor=4_000_000,
        deadline="2030-08-01",
    )
    second_goal = await _create_goal(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        name="Second goal",
        target_minor=1_000_000,
        deadline="2028-08-01",
    )
    first_set = await client.post(
        "/api/finance/plans/generate",
        params={"space_id": space_id},
        json={"goal_id": first_goal["id"]},
        headers=adult_a_headers,
    )
    second_set = await client.post(
        "/api/finance/plans/generate",
        params={"space_id": space_id},
        json={"goal_id": second_goal["id"]},
        headers=adult_a_headers,
    )
    assert first_set.status_code == second_set.status_code == 200
    first_medium = next(
        plan for plan in first_set.json()["plans"] if plan["effort_level"] == "MEDIUM"
    )
    second_medium = next(
        plan for plan in second_set.json()["plans"] if plan["effort_level"] == "MEDIUM"
    )
    selected_first = await client.post(
        f"/api/finance/plans/{first_medium['id']}/activate",
        headers=adult_a_headers,
    )
    assert selected_first.status_code == 200, selected_first.text

    # Old saved evaluations only carried one nullable plan ID. They remain
    # approvable while that one relevant plan is unchanged.
    async with standalone_db(initialized_db) as db:
        now = "2026-08-01T09:00:00+00:00"
        await db.execute(
            """
            INSERT INTO finance_purchase_proposals
                (id, space_id, source_kind, name, amount_low_minor,
                 amount_high_minor, desired_date, recurrence, payment_account_id,
                 lines_json, currency, status, family_id, created_at, updated_at,
                 created_by)
            VALUES ('legacy-plan-proposal', ?, 'TEXT', 'Legacy proposal', 1000,
                    1000, '2026-09-01', 'ONE_OFF', 'cashflow-account', '[]',
                    'GBP', 'EVALUATED', ?, ?, ?, ?)
            """,
            (space_id, adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_purchase_evaluations
                (id, space_id, proposal_id, forecast_id, verdict, rationale,
                 scenarios_json, historical_context_json, evidence_json,
                 family_id, created_at, updated_at, created_by)
            VALUES ('legacy-plan-evaluation', ?, 'legacy-plan-proposal',
                    'legacy-forecast', 'YES', 'It fits.', ?, ?, '[]', ?, ?, ?, ?)
            """,
            (
                space_id,
                json.dumps([{"scenario": "DO_NOTHING", "passed": True}]),
                json.dumps({"active_plan_id": first_medium["id"]}),
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.commit()
    legacy_approval = await client.post(
        "/api/finance/proposals/legacy-plan-proposal/approve",
        json={
            "evaluation_id": "legacy-plan-evaluation",
            "scenario": "DO_NOTHING",
        },
        headers=adult_a_headers,
    )
    assert legacy_approval.status_code == 200, legacy_approval.text

    rejected_second = await client.post(
        f"/api/finance/plans/{second_medium['id']}/activate",
        headers=adult_a_headers,
    )
    assert rejected_second.status_code == 409
    assert rejected_second.json()["detail"] == (
        "Another savings goal changed the available monthly budget; "
        "generate these choices again"
    )

    regenerated, fresh_second = await _generate_and_activate_medium(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        goal_id=second_goal["id"],
    )
    assert fresh_second["id"] != second_medium["id"]
    assert any(
        assumption.startswith("Other active goals already use £")
        for plan in regenerated["plans"]
        for assumption in plan["assumptions"]
    )


@pytest.mark.asyncio
async def test_simultaneous_goals_share_surplus_and_cuts_without_reuse(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
) -> None:
    async def fixture_local_today(db, *, family_id: str) -> date:
        del db, family_id
        return date(2026, 8, 1)

    monkeypatch.setattr(
        "app.services.finance.coaching._local_today",
        fixture_local_today,
    )
    space_id = await _personal_space_id(client, adult_a_headers)
    await _seed_cashflow(initialized_db, user=adult_a_user, space_id=space_id)
    house = await _create_goal(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        name="House deposit",
        target_minor=10_000_000,
        deadline="2030-08-01",
    )
    holiday = await _create_goal(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        name="Synthetic public demo record 16",
        target_minor=1_200_000,
        deadline="2027-08-01",
    )

    _, first_house = await _generate_and_activate_medium(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        goal_id=house["id"],
    )
    holiday_set, first_holiday = await _generate_and_activate_medium(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        goal_id=holiday["id"],
    )
    assert any(
        assumption.startswith("Other active goals already use £")
        for plan in holiday_set["plans"]
        for assumption in plan["assumptions"]
    )

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        holiday_snapshot_row = await (
            await db.execute(
                "SELECT input_snapshot_json FROM finance_plans WHERE id = ?",
                (first_holiday["id"],),
            )
        ).fetchone()
        active_rows = await (
            await db.execute(
                "SELECT id, goal_id, planned_monthly_saving_minor "
                "FROM finance_plans WHERE space_id = ? AND status = 'ACTIVE' "
                "AND deleted_at IS NULL ORDER BY goal_id",
                (space_id,),
            )
        ).fetchall()
        cut_rows = await (
            await db.execute(
                """
                SELECT category.category_id,
                       MAX(category.baseline_minor) AS baseline_minor,
                       MAX(category.floor_minor) AS floor_minor,
                       SUM(category.reduction_minor) AS reduction_minor
                FROM finance_plan_categories category
                JOIN finance_plans plan ON plan.id = category.plan_id
                WHERE plan.space_id = ? AND plan.status = 'ACTIVE'
                  AND plan.currency = 'GBP' AND plan.deleted_at IS NULL
                  AND category.deleted_at IS NULL
                GROUP BY category.category_id
                """,
                (space_id,),
            )
        ).fetchall()

    holiday_snapshot = json.loads(holiday_snapshot_row["input_snapshot_json"])
    assert holiday_snapshot["other_active_plan_ids"] == [first_house["id"]]
    assert holiday_snapshot["monthly_surplus_minor"] == 0
    assert {row["goal_id"] for row in active_rows} == {house["id"], holiday["id"]}
    assert all(
        row["reduction_minor"] <= row["baseline_minor"] - row["floor_minor"]
        for row in cut_rows
    )
    combined_allocation = sum(row["planned_monthly_saving_minor"] for row in active_rows)
    unique_cuts = sum(row["reduction_minor"] for row in cut_rows)
    assert combined_allocation <= 200_000 + unique_cuts
    shared_budget = sum(
        max(0, row["baseline_minor"] - row["reduction_minor"])
        for row in cut_rows
    )
    off_plan_spend = shared_budget + max(2_500, shared_budget // 20) + 1

    # Spend beyond the one shared category envelope and its tolerance must be
    # off-plan. Summing each plan's full category budget would incorrectly call
    # this on-plan.
    async with standalone_db(initialized_db) as db:
        now = "2026-08-31T08:00:00+00:00"
        await db.execute(
            """
            INSERT INTO finance_transactions
                (id, space_id, account_id, canonical_date, amount_minor,
                 currency, state, source_kind, description,
                 cleaned_description, primary_category_id, data_through_at,
                 family_id, created_at, updated_at, created_by)
            VALUES ('august-shared-budget', ?, 'cashflow-account', '2026-08-15',
                    ?, 'GBP', 'POSTED', 'MANUAL', 'August spending',
                    'August spending', 'dining', ?, ?, ?, ?, ?)
            """,
            (
                space_id,
                -off_plan_spend,
                now,
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.commit()
        trajectory, expected, trajectory_plans = await _trajectory(
            db,
            user=adult_a_user,
            space_id=space_id,
            currency="GBP",
            local_date=date(2026, 8, 31),
        )
    assert trajectory == "OFF_PLAN"
    assert expected == combined_allocation
    assert {plan["id"] for plan in trajectory_plans} == {
        first_house["id"],
        first_holiday["id"],
    }

    replacement_set, replacement_house = await _generate_and_activate_medium(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        goal_id=house["id"],
    )
    replacement_assumptions = " ".join(replacement_house["assumptions"])
    assert "Other active goals already use" in replacement_assumptions
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        statuses = await (
            await db.execute(
                "SELECT id, goal_id, status FROM finance_plans "
                "WHERE id IN (?, ?, ?)",
                (first_house["id"], first_holiday["id"], replacement_house["id"]),
            )
        ).fetchall()
        history_count = await (
            await db.execute(
                "SELECT COUNT(*) FROM record_history "
                "WHERE table_name = 'finance_plans' AND record_id = ?",
                (first_house["id"],),
            )
        ).fetchone()
    status_by_id = {row["id"]: row["status"] for row in statuses}
    assert status_by_id == {
        first_house["id"]: "SUPERSEDED",
        first_holiday["id"]: "ACTIVE",
        replacement_house["id"]: "ACTIVE",
    }
    assert history_count[0] >= 1
    assert replacement_set["plans"][0]["target_date"] == "2030-08-01"

    euro_goal = await _create_goal(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        name="Euro school trip",
        target_minor=100_000,
        deadline="2028-08-01",
        currency="EUR",
    )
    euro_set, euro_plan = await _generate_and_activate_medium(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        goal_id=euro_goal["id"],
    )
    assert all(
        "Other active goals already use" not in " ".join(plan["assumptions"])
        for plan in euro_set["plans"]
    )
    async with aiosqlite.connect(initialized_db) as db:
        snapshot = await (
            await db.execute(
                "SELECT input_snapshot_json FROM finance_plans WHERE id = ?",
                (euro_plan["id"],),
            )
        ).fetchone()
        active_goal_count = await (
            await db.execute(
                "SELECT COUNT(DISTINCT goal_id) FROM finance_plans "
                "WHERE space_id = ? AND status = 'ACTIVE' AND deleted_at IS NULL",
                (space_id,),
            )
        ).fetchone()
    assert json.loads(snapshot[0])["other_active_plan_ids"] == []
    assert active_goal_count[0] == 3

    # Purchase approval snapshots the entire relevant active-plan set. Replacing
    # either GBP goal makes that evaluation obsolete; the unrelated EUR plan is
    # deliberately absent from the fingerprint.
    async with standalone_db(initialized_db) as db:
        current_gbp_plans = [
            dict(row)
            for row in await (
                await db.execute(
                    "SELECT * FROM finance_plans WHERE space_id = ? "
                    "AND family_id = ? AND currency = 'GBP' "
                    "AND status = 'ACTIVE' AND deleted_at IS NULL ORDER BY id",
                    (space_id, adult_a_user["family_id"]),
                )
            ).fetchall()
        ]
        evaluated_ids, evaluated_digest = _active_plan_state(current_gbp_plans)
        now = "2026-08-31T09:00:00+00:00"
        await db.execute(
            """
            INSERT INTO finance_purchase_proposals
                (id, space_id, source_kind, name, amount_low_minor,
                 amount_high_minor, desired_date, recurrence, payment_account_id,
                 lines_json, currency, status, family_id, created_at, updated_at,
                 created_by)
            VALUES ('multi-plan-proposal', ?, 'TEXT', 'Garden table', 50000,
                    50000, '2026-09-01', 'ONE_OFF', 'cashflow-account', '[]',
                    'GBP', 'EVALUATED', ?, ?, ?, ?)
            """,
            (space_id, adult_a_user["family_id"], now, now, adult_a_user["id"]),
        )
        await db.execute(
            """
            INSERT INTO finance_purchase_evaluations
                (id, space_id, proposal_id, forecast_id, verdict, rationale,
                 scenarios_json, historical_context_json, evidence_json,
                 family_id, created_at, updated_at, created_by)
            VALUES ('multi-plan-evaluation', ?, 'multi-plan-proposal',
                    'fixture-forecast', 'YES', 'It fits.', ?, ?, '[]', ?, ?, ?, ?)
            """,
            (
                space_id,
                json.dumps([{"scenario": "DO_NOTHING", "passed": True}]),
                json.dumps(
                    {
                        "active_plan_ids": evaluated_ids,
                        "active_plan_digest": evaluated_digest,
                    }
                ),
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.commit()

    _, replacement_holiday = await _generate_and_activate_medium(
        client,
        headers=adult_a_headers,
        space_id=space_id,
        goal_id=holiday["id"],
    )
    assert replacement_holiday["id"] != first_holiday["id"]
    rejected_approval = await client.post(
        "/api/finance/proposals/multi-plan-proposal/approve",
        json={
            "evaluation_id": "multi-plan-evaluation",
            "scenario": "DO_NOTHING",
        },
        headers=adult_a_headers,
    )
    assert rejected_approval.status_code == 409
    assert "active plan changed" in rejected_approval.text.lower()
