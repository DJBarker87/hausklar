from datetime import date

import pytest

from app.database import standalone_db
from app.services.finance import monthly_overview
from app.services.finance.foundation import accessible_finance_spaces

AS_OF = date(2026, 8, 10)
NOW = "2026-08-10T08:00:00+00:00"


async def _spaces(db_path: str, user: dict) -> dict[str, str]:
    async with standalone_db(db_path) as db:
        spaces = await accessible_finance_spaces(db, user=user)
    return {space.kind: space.id for space in spaces}


async def _connection(db, *, identifier: str, space_id: str, family_id: str) -> None:
    await db.execute(
        """
        INSERT INTO finance_connections
            (id, space_id, provider, status, family_id, created_at, updated_at)
        VALUES (?, ?, 'test-bank', 'CONNECTED', ?, ?, ?)
        """,
        (identifier, space_id, family_id, NOW, NOW),
    )


async def _account(
    db,
    *,
    identifier: str,
    space_id: str,
    family_id: str,
    connection_id: str | None,
    account_type: str = "CURRENT",
    purpose: str = "OPERATING_CURRENT",
    include_in_cashflow: bool = True,
) -> None:
    await db.execute(
        """
        INSERT INTO finance_accounts
            (id, space_id, connection_id, label, account_type, purpose, currency,
             include_in_cashflow, family_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 'GBP', ?, ?, ?, ?)
        """,
        (
            identifier,
            space_id,
            connection_id,
            identifier,
            account_type,
            purpose,
            int(include_in_cashflow),
            family_id,
            NOW,
            NOW,
        ),
    )


async def _balance(
    db,
    *,
    identifier: str,
    space_id: str,
    account_id: str,
    family_id: str,
    booked_minor: int,
    observed_at: str,
    available_minor: int | None = None,
) -> None:
    await db.execute(
        """
        INSERT INTO finance_balance_snapshots
            (id, space_id, account_id, booked_minor, available_minor, currency,
             observed_at, family_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'GBP', ?, ?, ?, ?)
        """,
        (
            identifier,
            space_id,
            account_id,
            booked_minor,
            available_minor,
            observed_at,
            family_id,
            observed_at,
            observed_at,
        ),
    )


async def _category(
    db,
    *,
    identifier: str,
    space_id: str,
    family_id: str,
    name: str,
    spending_type: str,
) -> None:
    await db.execute(
        """
        INSERT INTO finance_categories
            (id, space_id, name, spending_type, family_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (identifier, space_id, name, spending_type, family_id, NOW, NOW),
    )


async def _transaction(
    db,
    *,
    identifier: str,
    space_id: str,
    account_id: str,
    family_id: str,
    amount_minor: int,
    description: str,
    category_id: str | None = None,
    canonical_date: str = "2026-08-05",
) -> None:
    await db.execute(
        """
        INSERT INTO finance_transactions
            (id, space_id, account_id, canonical_date, amount_minor, currency,
             state, source_kind, description, cleaned_description,
             primary_category_id, data_through_at, family_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'GBP', 'POSTED', 'MANUAL', ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            identifier,
            space_id,
            account_id,
            canonical_date,
            amount_minor,
            description,
            description.upper(),
            category_id,
            NOW,
            family_id,
            NOW,
            NOW,
        ),
    )


async def _salary(
    db,
    *,
    identifier: str,
    space_id: str,
    family_id: str,
    amount_minor: int,
) -> None:
    await db.execute(
        """
        INSERT INTO finance_recurring_series
            (id, space_id, name, series_type, interval_kind, expected_minor,
             currency, next_expected_date, confidence_bps, status, confirmed_at,
             family_id, created_at, updated_at)
        VALUES (?, ?, 'Salary', 'SALARY', 'MONTHLY', ?, 'GBP', '2026-08-25',
                10000, 'CONFIRMED', ?, ?, ?, ?)
        """,
        (identifier, space_id, amount_minor, NOW, family_id, NOW, NOW),
    )


async def _commitment(
    db,
    *,
    identifier: str,
    space_id: str,
    family_id: str,
    name: str,
    amount_minor: int,
    due_date: str,
) -> None:
    await db.execute(
        """
        INSERT INTO finance_commitments
            (id, space_id, name, amount_mode, exact_minor, currency, recurrence,
             reviewed_dates_json, priority, status, family_id, created_at, updated_at)
        VALUES (?, ?, ?, 'EXACT', ?, 'GBP', 'ONE_OFF', ?, 'IMPORTANT', 'ACTIVE',
                ?, ?, ?)
        """,
        (
            identifier,
            space_id,
            name,
            amount_minor,
            f'["{due_date}"]',
            family_id,
            NOW,
            NOW,
        ),
    )


async def _active_budget(
    db,
    *,
    space_id: str,
    family_id: str,
    category_id: str,
    category_name: str,
    budget_minor: int,
    plan_id: str = "active-plan",
) -> None:
    await db.execute(
        """
        INSERT INTO finance_plans
            (id, space_id, proposal_group_id, version, strategy, currency, goal_id,
             target_date, monthly_change_minor, household_buffer_minor,
             required_reduction_minor, achieved_reduction_minor, shortfall_minor,
             feasible, protected_category_count, input_snapshot_json, rationale,
             status, activated_at, family_id, created_at, updated_at)
        VALUES (?, ?, ?, 1, 'TARGET_DATE', 'GBP', ?,
                '2027-01-01', 0, 0, 0, 0, 0, 1, 0, '{}', 'Saved plan',
                'ACTIVE', ?, ?, ?, ?)
        """,
        (plan_id, space_id, f"{plan_id}-group", f"{plan_id}-goal", NOW, family_id, NOW, NOW),
    )
    await db.execute(
        """
        INSERT INTO finance_plan_categories
            (id, space_id, plan_id, category_id, name, baseline_minor,
             floor_minor, protected, weight, reduction_minor, budget_minor,
             family_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 0, 0, 1, 0, ?,
                ?, ?, ?)
        """,
        (
            f"{plan_id}-category",
            space_id,
            plan_id,
            category_id,
            category_name,
            budget_minor,
            budget_minor,
            family_id,
            NOW,
            NOW,
        ),
    )


async def _split(
    db,
    *,
    identifier: str,
    space_id: str,
    transaction_id: str,
    family_id: str,
    amount_minor: int,
    category_id: str | None,
) -> None:
    await db.execute(
        """
        INSERT INTO finance_transaction_splits
            (id, space_id, transaction_id, amount_minor, category_id,
             family_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            identifier,
            space_id,
            transaction_id,
            amount_minor,
            category_id,
            family_id,
            NOW,
            NOW,
        ),
    )


async def _relation(
    db,
    *,
    identifier: str,
    space_id: str,
    from_transaction_id: str,
    to_transaction_id: str,
    family_id: str,
    relation_type: str = "REFUND",
) -> None:
    await db.execute(
        """
        INSERT INTO finance_transaction_relations
            (id, space_id, from_transaction_id, to_transaction_id, relation_type,
             status, method, confidence_bps, family_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'CONFIRMED', 'MANUAL', 10000, ?, ?, ?)
        """,
        (
            identifier,
            space_id,
            from_transaction_id,
            to_transaction_id,
            relation_type,
            family_id,
            NOW,
            NOW,
        ),
    )


@pytest.mark.asyncio
async def test_mine_overview_answers_the_month_without_counting_savings_as_spendable(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(monthly_overview, "_today", lambda _timezone: AS_OF)
    spaces = await _spaces(initialized_db, adult_a_user)
    async with standalone_db(initialized_db) as db:
        await _connection(
            db,
            identifier="dom-connection",
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
        )
        await _account(
            db,
            identifier="dom-current",
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
            connection_id="dom-connection",
        )
        await _account(
            db,
            identifier="dom-savings",
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
            connection_id="dom-connection",
            account_type="SAVINGS",
            purpose="SAVINGS",
        )
        await _balance(
            db,
            identifier="current-balance",
            space_id=spaces["personal"],
            account_id="dom-current",
            family_id=adult_a_user["family_id"],
            booked_minor=100_000,
            available_minor=90_000,
            observed_at="2026-08-09T09:00:00+00:00",
        )
        await _balance(
            db,
            identifier="savings-before",
            space_id=spaces["personal"],
            account_id="dom-savings",
            family_id=adult_a_user["family_id"],
            booked_minor=45_000,
            observed_at="2026-07-31T09:00:00+00:00",
        )
        await _balance(
            db,
            identifier="savings-now",
            space_id=spaces["personal"],
            account_id="dom-savings",
            family_id=adult_a_user["family_id"],
            booked_minor=50_000,
            observed_at="2026-08-09T09:00:00+00:00",
        )
        await _category(
            db,
            identifier="groceries",
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
            name="Food shopping",
            spending_type="FLEXIBLE",
        )
        await _transaction(
            db,
            identifier="salary-credit",
            space_id=spaces["personal"],
            account_id="dom-current",
            family_id=adult_a_user["family_id"],
            amount_minor=200_000,
            description="Salary payment",
        )
        await _transaction(
            db,
            identifier="grocery-spend",
            space_id=spaces["personal"],
            account_id="dom-current",
            family_id=adult_a_user["family_id"],
            amount_minor=-30_000,
            description="Private supermarket row",
            category_id="groceries",
        )
        await _transaction(
            db,
            identifier="uncategorised-spend",
            space_id=spaces["personal"],
            account_id="dom-current",
            family_id=adult_a_user["family_id"],
            amount_minor=-2_000,
            description="Unsorted purchase",
        )
        await _salary(
            db,
            identifier="next-salary",
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
            amount_minor=200_000,
        )
        await _commitment(
            db,
            identifier="before-payday",
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
            name="School bill",
            amount_minor=30_000,
            due_date="2026-08-20",
        )
        await _commitment(
            db,
            identifier="after-payday-this-month",
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
            name="End-of-month bill",
            amount_minor=20_000,
            due_date="2026-08-28",
        )
        await _commitment(
            db,
            identifier="after-payday",
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
            name="September bill",
            amount_minor=40_000,
            due_date="2026-09-01",
        )
        await _active_budget(
            db,
            space_id=spaces["personal"],
            family_id=adult_a_user["family_id"],
            category_id="groceries",
            category_name="Food shopping",
            budget_minor=40_000,
        )
        await db.commit()

    response = await client.get(
        "/api/finance/overview",
        params={"scope": "mine"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    overview = response.json()
    assert overview["month_start"] == "2026-08-01"
    assert overview["through_date"] == "2026-08-10"
    assert overview["account_count"] == 2
    assert overview["income_minor"] == 200_000
    assert overview["spending_minor"] == 32_000
    assert sum(item["share_bps"] for item in overview["spending_by_category"]) == 10_000
    assert overview["spending_by_category"] == [
        {
            "category_key": "flexible:food-shopping",
            "name": "Food shopping",
            "spending_type": "FLEXIBLE",
            "spent_minor": 30_000,
            "share_bps": 9_375,
        },
        {
            "category_key": "uncategorised",
            "name": "Uncategorised",
            "spending_type": "UNCATEGORISED",
            "spent_minor": 2_000,
            "share_bps": 625,
        },
    ]
    assert overview["budget_buckets"] == [
        {
            "category_key": "flexible:food-shopping",
            "name": "Food shopping",
            "budget_minor": 40_000,
            "spent_minor": 30_000,
            "remaining_minor": 10_000,
        }
    ]
    assert overview["current_available_minor"] == 90_000
    assert overview["next_paycheck_date"] == "2026-08-25"
    assert overview["next_paycheck_minor"] == 200_000
    assert overview["commitments_before_payday_minor"] == 30_000
    assert overview["left_until_payday_minor"] == 60_000
    assert overview["upcoming_commitments"] == [
        {"name": "School bill", "due_date": "2026-08-20", "amount_minor": 30_000},
        {"name": "End-of-month bill", "due_date": "2026-08-28", "amount_minor": 20_000},
    ]
    assert overview["savings_balance_minor"] == 50_000
    assert overview["savings_change_minor"] == 5_000
    assert overview["savings_series"][-1] == {
        "date": "2026-08-10",
        "balance_minor": 50_000,
    }

    transactions = await client.get(
        "/api/finance/transactions",
        params={"space_id": spaces["personal"]},
        headers=adult_a_headers,
    )
    assert transactions.status_code == 200
    by_id = {item["id"]: item for item in transactions.json()}
    assert by_id["grocery-spend"]["primary_category_name"] == "Food shopping"
    assert by_id["grocery-spend"]["primary_spending_type"] == "FLEXIBLE"
    assert by_id["uncategorised-spend"]["primary_category_name"] == "Uncategorised"
    assert by_id["uncategorised-spend"]["primary_spending_type"] == "UNCATEGORISED"


@pytest.mark.asyncio
async def test_overview_uses_complete_splits_and_only_nets_current_month_refunds(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(monthly_overview, "_today", lambda _timezone: AS_OF)
    spaces = await _spaces(initialized_db, adult_a_user)
    space_id = spaces["personal"]
    async with standalone_db(initialized_db) as db:
        await _account(
            db,
            identifier="split-current",
            space_id=space_id,
            family_id=adult_a_user["family_id"],
            connection_id=None,
        )
        await _category(
            db,
            identifier="essentials",
            space_id=space_id,
            family_id=adult_a_user["family_id"],
            name="Essentials",
            spending_type="FIXED",
        )
        await _category(
            db,
            identifier="fun",
            space_id=space_id,
            family_id=adult_a_user["family_id"],
            name="Fun",
            spending_type="DISCRETIONARY",
        )
        await _transaction(
            db,
            identifier="current-original",
            space_id=space_id,
            account_id="split-current",
            family_id=adult_a_user["family_id"],
            amount_minor=-10_000,
            description="Mixed family purchase",
            category_id="essentials",
        )
        await _transaction(
            db,
            identifier="current-refund",
            space_id=space_id,
            account_id="split-current",
            family_id=adult_a_user["family_id"],
            amount_minor=5_000,
            description="Partial refund",
        )
        await _relation(
            db,
            identifier="current-refund-relation",
            space_id=space_id,
            from_transaction_id="current-original",
            to_transaction_id="current-refund",
            family_id=adult_a_user["family_id"],
        )
        await _transaction(
            db,
            identifier="incomplete-parent",
            space_id=space_id,
            account_id="split-current",
            family_id=adult_a_user["family_id"],
            amount_minor=-3_000,
            description="Partially saved split",
            category_id="essentials",
        )
        await _split(
            db,
            identifier="incomplete-line",
            space_id=space_id,
            transaction_id="incomplete-parent",
            family_id=adult_a_user["family_id"],
            amount_minor=-1_000,
            category_id="fun",
        )
        await _transaction(
            db,
            identifier="old-original",
            space_id=space_id,
            account_id="split-current",
            family_id=adult_a_user["family_id"],
            amount_minor=-8_000,
            description="July purchase",
            category_id="fun",
            canonical_date="2026-07-20",
        )
        await _transaction(
            db,
            identifier="old-purchase-refund",
            space_id=space_id,
            account_id="split-current",
            family_id=adult_a_user["family_id"],
            amount_minor=8_000,
            description="Refund for July purchase",
        )
        await _relation(
            db,
            identifier="old-refund-relation",
            space_id=space_id,
            from_transaction_id="old-original",
            to_transaction_id="old-purchase-refund",
            family_id=adult_a_user["family_id"],
        )
        await _active_budget(
            db,
            space_id=space_id,
            family_id=adult_a_user["family_id"],
            category_id="essentials",
            category_name="Essentials",
            budget_minor=10_000,
            plan_id="split-plan",
        )
        await db.commit()

    split_response = await client.put(
        "/api/finance/transactions/current-original/splits",
        json={
            "splits": [
                {"amount_minor": -6_000, "category_id": "essentials"},
                {"amount_minor": -4_000, "category_id": "fun"},
            ]
        },
        headers=adult_a_headers,
    )
    assert split_response.status_code == 200, split_response.text
    assert {(item["category_name"], item["spending_type"]) for item in split_response.json()} == {
        ("Essentials", "FIXED"),
        ("Fun", "DISCRETIONARY"),
    }

    response = await client.get(
        "/api/finance/overview",
        params={"scope": "mine"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    overview = response.json()
    assert overview["income_minor"] == 0
    assert overview["spending_minor"] == 8_000
    assert overview["spending_by_category"] == [
        {
            "category_key": "fixed:essentials",
            "name": "Essentials",
            "spending_type": "FIXED",
            "spent_minor": 6_000,
            "share_bps": 7_500,
        },
        {
            "category_key": "discretionary:fun",
            "name": "Fun",
            "spending_type": "DISCRETIONARY",
            "spent_minor": 2_000,
            "share_bps": 2_500,
        },
    ]
    assert overview["budget_buckets"] == [
        {
            "category_key": "fixed:essentials",
            "name": "Essentials",
            "budget_minor": 10_000,
            "spent_minor": 6_000,
            "remaining_minor": 4_000,
        }
    ]

    transactions = await client.get(
        "/api/finance/transactions",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert transactions.status_code == 200
    by_id = {item["id"]: item for item in transactions.json()}
    assert {
        (item["category_name"], item["spending_type"])
        for item in by_id["current-original"]["splits"]
    } == {("Essentials", "FIXED"), ("Fun", "DISCRETIONARY")}


@pytest.mark.asyncio
async def test_household_overview_uses_only_explicit_household_and_shared_copy_rows(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(monthly_overview, "_today", lambda _timezone: AS_OF)
    adult_a_spaces = await _spaces(initialized_db, adult_a_user)
    adult_b_spaces = await _spaces(initialized_db, adult_b_user)
    household_id = adult_a_spaces["household"]
    async with standalone_db(initialized_db) as db:
        for prefix, owner, spaces, balance_minor, spend_minor, budget_minor in (
            ("dom", adult_a_user, adult_a_spaces, 100_000, -1_000, 5_000),
            ("kat", adult_b_user, adult_b_spaces, 900_000, -90_000, 70_000),
        ):
            await _connection(
                db,
                identifier=f"{prefix}-connection",
                space_id=spaces["personal"],
                family_id=owner["family_id"],
            )
            await _account(
                db,
                identifier=f"{prefix}-current",
                space_id=spaces["personal"],
                family_id=owner["family_id"],
                connection_id=f"{prefix}-connection",
            )
            await _balance(
                db,
                identifier=f"{prefix}-balance",
                space_id=spaces["personal"],
                account_id=f"{prefix}-current",
                family_id=owner["family_id"],
                booked_minor=balance_minor,
                observed_at="2026-08-09T09:00:00+00:00",
            )
            await _category(
                db,
                identifier=f"{prefix}-food",
                space_id=spaces["personal"],
                family_id=owner["family_id"],
                name="Food",
                spending_type="FLEXIBLE",
            )
            await _transaction(
                db,
                identifier=f"{prefix}-private-transaction",
                space_id=spaces["personal"],
                account_id=f"{prefix}-current",
                family_id=owner["family_id"],
                amount_minor=spend_minor,
                description=f"{prefix} private merchant details",
                category_id=f"{prefix}-food",
            )
            await _active_budget(
                db,
                space_id=spaces["personal"],
                family_id=owner["family_id"],
                category_id=f"{prefix}-food",
                category_name="Food",
                budget_minor=budget_minor,
                plan_id=f"{prefix}-plan",
            )
            await _salary(
                db,
                identifier=f"{prefix}-salary",
                space_id=spaces["personal"],
                family_id=owner["family_id"],
                amount_minor=100_000 if prefix == "dom" else 120_000,
            )
            await _commitment(
                db,
                identifier=f"{prefix}-private-commitment",
                space_id=spaces["personal"],
                family_id=owner["family_id"],
                name=f"{prefix.title()} private commitment name",
                amount_minor=3_000 if prefix == "dom" else 40_000,
                due_date="2026-08-20",
            )

        await _account(
            db,
            identifier="shared-envelope",
            space_id=household_id,
            family_id=adult_a_user["family_id"],
            connection_id=None,
            purpose="IGNORED",
            include_in_cashflow=False,
        )
        await _category(
            db,
            identifier="household-food",
            space_id=household_id,
            family_id=adult_a_user["family_id"],
            name="Food",
            spending_type="FLEXIBLE",
        )
        await _transaction(
            db,
            identifier="shared-copy-transaction",
            space_id=household_id,
            account_id="shared-envelope",
            family_id=adult_a_user["family_id"],
            amount_minor=-2_000,
            description="Explicitly shared purchase",
            category_id="household-food",
        )
        await db.execute(
            """
            INSERT INTO finance_share_actions
                (id, owner_user_id, source_space_id, household_space_id,
                 share_kind, source_record_type, source_record_id, selection_json,
                 selection_digest, status, household_record_type, household_record_id,
                 family_id, created_at, updated_at)
            VALUES ('kat-share', ?, ?, ?, 'TRANSACTION', 'transaction',
                    'kat-private-transaction', '[]', '', 'COMPLETED', 'transaction',
                    'shared-copy-transaction', ?, ?, ?)
            """,
            (
                adult_b_user["id"],
                adult_b_spaces["personal"],
                household_id,
                adult_b_user["family_id"],
                NOW,
                NOW,
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_share_copy_links
                (id, share_action_id, source_space_id, source_record_type,
                 source_record_id, household_space_id, household_record_type,
                 household_record_id, family_id, created_at, updated_at)
            VALUES ('kat-share-link', 'kat-share', ?, 'transaction',
                    'kat-private-transaction', ?, 'transaction',
                    'shared-copy-transaction', ?, ?, ?)
            """,
            (adult_b_spaces["personal"], household_id, adult_b_user["family_id"], NOW, NOW),
        )
        await _active_budget(
            db,
            space_id=household_id,
            family_id=adult_a_user["family_id"],
            category_id="household-food",
            category_name="Food",
            budget_minor=5_000,
            plan_id="household-plan",
        )
        await _salary(
            db,
            identifier="household-salary",
            space_id=household_id,
            family_id=adult_a_user["family_id"],
            amount_minor=150_000,
        )
        await _commitment(
            db,
            identifier="household-commitment",
            space_id=household_id,
            family_id=adult_a_user["family_id"],
            name="Family council tax",
            amount_minor=1_000,
            due_date="2026-08-20",
        )
        await db.commit()

    household_response = await client.get(
        "/api/finance/overview",
        params={"scope": "household"},
        headers=adult_a_headers,
    )

    assert household_response.status_code == 200, household_response.text
    household = household_response.json()
    assert household["account_count"] == 0
    assert household["spending_minor"] == 2_000
    assert household["spending_by_category"] == [
        {
            "category_key": "flexible:food",
            "name": "Food",
            "spending_type": "FLEXIBLE",
            "spent_minor": 2_000,
            "share_bps": 10_000,
        }
    ]
    assert household["budget_buckets"] == [
        {
            "category_key": "flexible:food",
            "name": "Food",
            "budget_minor": 5_000,
            "spent_minor": 2_000,
            "remaining_minor": 3_000,
        }
    ]
    assert household["current_available_minor"] is None
    assert household["next_paycheck_minor"] == 150_000
    assert household["commitments_before_payday_minor"] == 1_000
    assert household["commitments_before_payday_count"] == 1
    assert household["left_until_payday_minor"] is None
    assert household["upcoming_commitments"] == [
        {
            "name": "Family council tax",
            "due_date": "2026-08-20",
            "amount_minor": 1_000,
        }
    ]

    mine_response = await client.get(
        "/api/finance/overview",
        params={"scope": "mine"},
        headers=adult_a_headers,
    )

    assert mine_response.status_code == 200, mine_response.text
    mine = mine_response.json()
    assert mine["account_count"] == 1
    assert mine["spending_minor"] == 3_000
    assert mine["current_available_minor"] == 100_000
    assert mine["next_paycheck_minor"] == 250_000
    assert mine["commitments_before_payday_minor"] == 4_000
    assert mine["commitments_before_payday_count"] == 2
    assert mine["left_until_payday_minor"] == 96_000
    assert mine["budget_buckets"] == [
        {
            "category_key": "flexible:food",
            "name": "Food",
            "budget_minor": 10_000,
            "spent_minor": 3_000,
            "remaining_minor": 7_000,
        }
    ]

    for body in (household_response.text, mine_response.text):
        assert "kat-private-transaction" not in body
        assert "kat private merchant details" not in body
        assert "Morgan private commitment name" not in body


@pytest.mark.asyncio
async def test_household_overview_never_reads_unshared_partner_accounts(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(monthly_overview, "_today", lambda _timezone: AS_OF)
    adult_a_spaces = await _spaces(initialized_db, adult_a_user)
    adult_b_spaces = await _spaces(initialized_db, adult_b_user)
    async with standalone_db(initialized_db) as db:
        await _connection(
            db,
            identifier="kat-linked",
            space_id=adult_b_spaces["personal"],
            family_id=adult_b_user["family_id"],
        )
        await _account(
            db,
            identifier="kat-linked-account",
            space_id=adult_b_spaces["personal"],
            family_id=adult_b_user["family_id"],
            connection_id="kat-linked",
        )
        await _balance(
            db,
            identifier="kat-linked-balance",
            space_id=adult_b_spaces["personal"],
            account_id="kat-linked-account",
            family_id=adult_b_user["family_id"],
            booked_minor=900_000,
            observed_at="2026-08-09T09:00:00+00:00",
        )
        await _transaction(
            db,
            identifier="kat-linked-spend",
            space_id=adult_b_spaces["personal"],
            account_id="kat-linked-account",
            family_id=adult_b_user["family_id"],
            amount_minor=-90_000,
            description="Must not enter explicit household overview",
        )
        await _account(
            db,
            identifier="household-current",
            space_id=adult_a_spaces["household"],
            family_id=adult_a_user["family_id"],
            connection_id=None,
        )
        await _balance(
            db,
            identifier="household-balance",
            space_id=adult_a_spaces["household"],
            account_id="household-current",
            family_id=adult_a_user["family_id"],
            booked_minor=50_000,
            observed_at="2026-08-09T09:00:00+00:00",
        )
        await _transaction(
            db,
            identifier="household-spend",
            space_id=adult_a_spaces["household"],
            account_id="household-current",
            family_id=adult_a_user["family_id"],
            amount_minor=-500,
            description="Household spend",
        )
        await _active_budget(
            db,
            space_id=adult_b_spaces["personal"],
            family_id=adult_b_user["family_id"],
            category_id="uncategorised",
            category_name="Uncategorised",
            budget_minor=90_000,
            plan_id="kat-private-plan",
        )
        await _active_budget(
            db,
            space_id=adult_a_spaces["household"],
            family_id=adult_a_user["family_id"],
            category_id="uncategorised",
            category_name="Uncategorised",
            budget_minor=1_000,
            plan_id="household-plan",
        )
        await db.commit()

    response = await client.get(
        "/api/finance/overview",
        params={"scope": "household"},
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    assert response.json()["account_count"] == 1
    assert response.json()["current_available_minor"] == 50_000
    assert response.json()["spending_minor"] == 500
    assert response.json()["budget_buckets"] == [
        {
            "category_key": "uncategorised",
            "name": "Uncategorised",
            "budget_minor": 1_000,
            "spent_minor": 500,
            "remaining_minor": 500,
        }
    ]
    assert "Must not enter explicit household overview" not in response.text


@pytest.mark.asyncio
async def test_cashflow_excluded_accounts_do_not_affect_spending_budgets_or_balance(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    monkeypatch.setattr(monthly_overview, "_today", lambda _timezone: AS_OF)
    spaces = await _spaces(initialized_db, adult_a_user)
    async with standalone_db(initialized_db) as db:
        for prefix, space_id, included_balance, included_spend in (
            ("personal", spaces["personal"], 10_000, -1_000),
            ("household", spaces["household"], 20_000, -2_000),
        ):
            await _account(
                db,
                identifier=f"{prefix}-included",
                space_id=space_id,
                family_id=adult_a_user["family_id"],
                connection_id=None,
            )
            await _account(
                db,
                identifier=f"{prefix}-excluded",
                space_id=space_id,
                family_id=adult_a_user["family_id"],
                connection_id=None,
                include_in_cashflow=False,
            )
            await _balance(
                db,
                identifier=f"{prefix}-included-balance",
                space_id=space_id,
                account_id=f"{prefix}-included",
                family_id=adult_a_user["family_id"],
                booked_minor=included_balance,
                observed_at="2026-08-09T09:00:00+00:00",
            )
            await _balance(
                db,
                identifier=f"{prefix}-excluded-balance",
                space_id=space_id,
                account_id=f"{prefix}-excluded",
                family_id=adult_a_user["family_id"],
                booked_minor=900_000,
                observed_at="2026-08-09T09:00:00+00:00",
            )
            await _account(
                db,
                identifier=f"{prefix}-included-savings",
                space_id=space_id,
                family_id=adult_a_user["family_id"],
                connection_id=None,
                account_type="SAVINGS",
                purpose="SAVINGS",
            )
            await _account(
                db,
                identifier=f"{prefix}-excluded-savings",
                space_id=space_id,
                family_id=adult_a_user["family_id"],
                connection_id=None,
                account_type="SAVINGS",
                purpose="SAVINGS",
                include_in_cashflow=False,
            )
            await _balance(
                db,
                identifier=f"{prefix}-included-savings-balance",
                space_id=space_id,
                account_id=f"{prefix}-included-savings",
                family_id=adult_a_user["family_id"],
                booked_minor=1_000 if prefix == "personal" else 2_000,
                observed_at="2026-08-09T09:00:00+00:00",
            )
            await _balance(
                db,
                identifier=f"{prefix}-excluded-savings-balance",
                space_id=space_id,
                account_id=f"{prefix}-excluded-savings",
                family_id=adult_a_user["family_id"],
                booked_minor=800_000,
                observed_at="2026-08-09T09:00:00+00:00",
            )
            await _category(
                db,
                identifier=f"{prefix}-food",
                space_id=space_id,
                family_id=adult_a_user["family_id"],
                name="Food",
                spending_type="FLEXIBLE",
            )
            await _transaction(
                db,
                identifier=f"{prefix}-included-spend",
                space_id=space_id,
                account_id=f"{prefix}-included",
                family_id=adult_a_user["family_id"],
                amount_minor=included_spend,
                description="Included in cashflow",
                category_id=f"{prefix}-food",
            )
            await _transaction(
                db,
                identifier=f"{prefix}-excluded-spend",
                space_id=space_id,
                account_id=f"{prefix}-excluded",
                family_id=adult_a_user["family_id"],
                amount_minor=-80_000,
                description="Must not inflate overview spending",
                category_id=f"{prefix}-food",
            )
            await _active_budget(
                db,
                space_id=space_id,
                family_id=adult_a_user["family_id"],
                category_id=f"{prefix}-food",
                category_name="Food",
                budget_minor=5_000,
                plan_id=f"{prefix}-plan",
            )
        await db.commit()

    mine_response = await client.get(
        "/api/finance/overview",
        params={"scope": "mine"},
        headers=adult_a_headers,
    )

    assert mine_response.status_code == 200, mine_response.text
    mine = mine_response.json()
    assert mine["account_count"] == 8
    assert mine["current_available_minor"] == 30_000
    assert mine["spending_minor"] == 3_000
    assert mine["savings_balance_minor"] == 3_000
    assert mine["savings_series"] == [{"date": "2026-08-10", "balance_minor": 3_000}]
    assert mine["budget_buckets"] == [
        {
            "category_key": "flexible:food",
            "name": "Food",
            "budget_minor": 10_000,
            "spent_minor": 3_000,
            "remaining_minor": 7_000,
        }
    ]

    household_response = await client.get(
        "/api/finance/overview",
        params={"scope": "household"},
        headers=adult_a_headers,
    )

    assert household_response.status_code == 200, household_response.text
    household = household_response.json()
    assert household["account_count"] == 4
    assert household["current_available_minor"] == 20_000
    assert household["spending_minor"] == 2_000
    assert household["savings_balance_minor"] == 2_000
    assert household["savings_series"] == [{"date": "2026-08-10", "balance_minor": 2_000}]
    assert household["budget_buckets"] == [
        {
            "category_key": "flexible:food",
            "name": "Food",
            "budget_minor": 5_000,
            "spent_minor": 2_000,
            "remaining_minor": 3_000,
        }
    ]
