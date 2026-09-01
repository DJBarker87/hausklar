"""Calm, aggregate Finance answers for the current household month."""

from __future__ import annotations

import calendar
import json
import unicodedata
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Literal

from app.models.finance import (
    FinanceOverviewBudgetBucket,
    FinanceOverviewCommitment,
    FinanceOverviewResponse,
    FinanceOverviewSavingsPoint,
    FinanceOverviewSpendingCategory,
)
from app.services.finance.dates import household_zone
from app.services.finance.foundation import accessible_finance_spaces, get_finance_settings

_SPENDING_TYPES = {"FIXED", "FLEXIBLE", "DISCRETIONARY"}
_NEUTRAL_RELATIONS = {"INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT", "FX_LEG"}


@dataclass(frozen=True, slots=True)
class _ScopeSelection:
    personal_space_id: str
    household_space_id: str
    planning_space_ids: tuple[str, ...]
    accounts: tuple[dict, ...]


def _today(timezone_name: str) -> date:
    return datetime.now(timezone.utc).astimezone(household_zone(timezone_name)).date()


def _placeholders(values: list[object] | tuple[object, ...]) -> str:
    return ",".join("?" for _ in values)


def _safe_slug(value: str) -> str:
    normalised = unicodedata.normalize("NFKC", value).casefold()
    pieces: list[str] = []
    current: list[str] = []
    for character in normalised:
        if character.isalnum():
            current.append(character)
        elif current:
            pieces.append("".join(current))
            current = []
    if current:
        pieces.append("".join(current))
    return "-".join(pieces) or "other"


def _category_identity(
    name: str | None,
    spending_type: str | None,
    *,
    uncategorised: bool = False,
) -> tuple[str, str, str]:
    if uncategorised or not name or spending_type not in _SPENDING_TYPES:
        return "uncategorised", "Uncategorised", "UNCATEGORISED"
    display_name = " ".join(name.split())
    return (
        f"{spending_type.casefold()}:{_safe_slug(display_name)}",
        display_name,
        spending_type,
    )


async def _scope_selection(
    db,
    *,
    user: dict,
    scope: Literal["mine", "household"],
    currency: str,
) -> _ScopeSelection:
    visible_spaces = await accessible_finance_spaces(db, user=user)
    personal_space_id = next(space.id for space in visible_spaces if space.kind == "personal")
    household_space_id = next(space.id for space in visible_spaces if space.kind == "household")
    selected_space_ids = (
        (personal_space_id, household_space_id) if scope == "mine" else (household_space_id,)
    )
    rows = [
        dict(row)
        for row in await (
            await db.execute(
                f"""
                SELECT account.*
                FROM finance_accounts account
                JOIN finance_spaces space
                  ON space.id = account.space_id
                 AND space.family_id = account.family_id
                 AND space.deleted_at IS NULL
                WHERE account.family_id = ? AND account.currency = ?
                  AND account.space_id IN ({_placeholders(selected_space_ids)})
                  AND account.provider_presence_status = 'ACTIVE'
                  AND account.purpose NOT IN ('IGNORED', 'INVESTMENT_LIKE')
                  AND account.deleted_at IS NULL
                ORDER BY account.space_id, account.id
                """,
                (user["family_id"], currency, *selected_space_ids),
            )
        ).fetchall()
    ]

    account_links = await (
        await db.execute(
            """
            SELECT link.source_record_id, link.household_record_id
            FROM finance_share_copy_links link
            JOIN finance_share_actions share
              ON share.id = link.share_action_id
             AND share.family_id = link.family_id
             AND share.deleted_at IS NULL
            WHERE link.family_id = ? AND link.source_record_type = 'account'
              AND link.household_record_type = 'account'
              AND link.deleted_at IS NULL
            """,
            (user["family_id"],),
        )
    ).fetchall()
    selected_by_id = {row["id"]: row for row in rows}
    for link in account_links:
        if (
            link["source_record_id"] in selected_by_id
            and link["household_record_id"] in selected_by_id
        ):
            selected_by_id.pop(link["household_record_id"], None)
    return _ScopeSelection(
        personal_space_id=personal_space_id,
        household_space_id=household_space_id,
        planning_space_ids=selected_space_ids,
        accounts=tuple(selected_by_id.values()),
    )


async def _monthly_transactions(
    db,
    *,
    user: dict,
    selection: _ScopeSelection,
    currency: str,
    month_start: date,
    through_date: date,
) -> tuple[
    int,
    list[FinanceOverviewSpendingCategory],
    dict[str, dict[str, int]],
]:
    account_ids = [row["id"] for row in selection.accounts if bool(row["include_in_cashflow"])]
    # Ordinary ledger rows follow the account's cashflow setting.  A directly
    # shared transaction is stored against a synthetic, non-cashflow Household
    # envelope, so admit that one row only when its live copy provenance exists.
    scope_clauses = [
        """
        (tx.space_id = ? AND EXISTS (
            SELECT 1
            FROM finance_share_copy_links visible_copy
            JOIN finance_share_actions visible_share
              ON visible_share.id = visible_copy.share_action_id
             AND visible_share.family_id = visible_copy.family_id
             AND visible_share.deleted_at IS NULL
            WHERE visible_copy.family_id = tx.family_id
              AND visible_copy.household_space_id = tx.space_id
              AND visible_copy.household_record_type = 'transaction'
              AND visible_copy.household_record_id = tx.id
              AND visible_copy.deleted_at IS NULL
        ))
        """
    ]
    parameters: list[object] = [selection.household_space_id]
    if account_ids:
        scope_clauses.append(f"tx.account_id IN ({_placeholders(account_ids)})")
        parameters.extend(account_ids)
    scope_clause = f"({' OR '.join(scope_clauses)})"
    parameters.extend(
        (
            user["family_id"],
            currency,
            month_start.isoformat(),
            through_date.isoformat(),
        )
    )
    rows = [
        dict(row)
        for row in await (
            await db.execute(
                f"""
                SELECT tx.id, tx.space_id, tx.amount_minor, tx.primary_category_id,
                       category.name AS category_name,
                       category.spending_type AS category_spending_type,
                       category.counts_as_spending AS category_counts_as_spending
                FROM finance_transactions tx
                LEFT JOIN finance_categories category
                  ON category.id = tx.primary_category_id
                 AND category.space_id = tx.space_id
                 AND category.family_id = tx.family_id
                 AND category.deleted_at IS NULL
                WHERE {scope_clause} AND tx.family_id = ? AND tx.currency = ?
                  AND tx.state = 'POSTED'
                  AND tx.canonical_date BETWEEN ? AND ?
                  AND tx.deleted_at IS NULL
                ORDER BY tx.canonical_date, tx.id
                """,
                parameters,
            )
        ).fetchall()
    ]
    if not rows:
        return 0, [], {}

    row_ids = {row["id"] for row in rows}
    row_id_list = sorted(row_ids)
    copy_links = await (
        await db.execute(
            f"""
            SELECT source_record_id, household_record_id, accounting_treatment
            FROM finance_share_copy_links
            WHERE family_id = ? AND household_record_type = 'transaction'
              AND household_record_id IN ({_placeholders(row_id_list)})
              AND deleted_at IS NULL
            """,
            (user["family_id"], *row_id_list),
        )
    ).fetchall()
    duplicate_ids = {
        link["household_record_id"] for link in copy_links if link["source_record_id"] in row_ids
    }
    rows = [row for row in rows if row["id"] not in duplicate_ids]
    rows_by_id = {row["id"]: row for row in rows}
    final_ids = sorted(rows_by_id)
    if not final_ids:
        return 0, [], {}

    split_rows = await (
        await db.execute(
            f"""
            SELECT split.transaction_id, split.amount_minor, split.category_id,
                   category.name AS category_name,
                   category.spending_type AS category_spending_type,
                   category.counts_as_spending AS category_counts_as_spending
            FROM finance_transaction_splits split
            LEFT JOIN finance_categories category
              ON category.id = split.category_id
             AND category.space_id = split.space_id
             AND category.family_id = split.family_id
             AND category.deleted_at IS NULL
            WHERE split.transaction_id IN ({_placeholders(final_ids)})
              AND split.family_id = ? AND split.deleted_at IS NULL
            ORDER BY split.transaction_id, split.created_at, split.id
            """,
            (*final_ids, user["family_id"]),
        )
    ).fetchall()
    split_candidates: dict[
        str, list[tuple[tuple[str, str, str], int, bool]]
    ] = {}
    for split in split_rows:
        split_candidates.setdefault(split["transaction_id"], []).append(
            (
                _category_identity(
                    split["category_name"],
                    split["category_spending_type"],
                    uncategorised=split["category_id"] is None,
                ),
                split["amount_minor"],
                split["category_counts_as_spending"] != 0,
            )
        )
    allocations: dict[str, list[tuple[tuple[str, str, str], int, bool]]] = {}
    for transaction_id, candidates in split_candidates.items():
        parent_amount = rows_by_id[transaction_id]["amount_minor"]
        signs_match = all(
            amount != 0 and (amount > 0) == (parent_amount > 0)
            for _, amount, _ in candidates
        )
        if signs_match and sum(amount for _, amount, _ in candidates) == parent_amount:
            allocations[transaction_id] = candidates

    def transaction_allocations(
        transaction_id: str,
    ) -> list[tuple[tuple[str, str, str], int, bool]]:
        if transaction_id in allocations:
            return allocations[transaction_id]
        row = rows_by_id[transaction_id]
        return [
            (
                _category_identity(
                    row["category_name"],
                    row["category_spending_type"],
                    uncategorised=row["primary_category_id"] is None,
                ),
                row["amount_minor"],
                row["category_counts_as_spending"] != 0,
            )
        ]

    relation_rows = await (
        await db.execute(
            f"""
            SELECT relation.from_transaction_id, relation.to_transaction_id,
                   relation.relation_type
            FROM finance_transaction_relations relation
            WHERE relation.family_id = ? AND relation.status = 'CONFIRMED'
              AND relation.deleted_at IS NULL
              AND (
                  relation.from_transaction_id IN ({_placeholders(final_ids)})
                  OR relation.to_transaction_id IN ({_placeholders(final_ids)})
              )
            """,
            (user["family_id"], *final_ids, *final_ids),
        )
    ).fetchall()
    neutral_ids: set[str] = set()
    linked_credits: dict[str, str | None] = {}
    for relation in relation_rows:
        if relation["relation_type"] in _NEUTRAL_RELATIONS:
            neutral_ids.update((relation["from_transaction_id"], relation["to_transaction_id"]))
        elif relation["relation_type"] in {"REFUND", "REIMBURSEMENT"}:
            linked_credits[relation["to_transaction_id"]] = (
                relation["from_transaction_id"]
                if relation["from_transaction_id"] in rows_by_id
                else None
            )

    shared_treatments = {
        link["household_record_id"]: link["accounting_treatment"]
        for link in copy_links
        if link["household_record_id"] in rows_by_id
    }
    for transaction_id, treatment in shared_treatments.items():
        if treatment == "NEUTRAL_TRANSFER":
            neutral_ids.add(transaction_id)
        elif treatment in {"REFUND", "REIMBURSEMENT"}:
            linked_credits.setdefault(transaction_id, None)

    income_minor = 0
    spending_by_space: dict[str, dict[str, dict[str, object]]] = {}

    def adjust_spending(
        space_id: str,
        identity: tuple[str, str, str],
        amount_minor: int,
    ) -> None:
        category_key, name, spending_type = identity
        bucket = spending_by_space.setdefault(space_id, {}).setdefault(
            category_key,
            {"name": name, "spending_type": spending_type, "spent_minor": 0},
        )
        bucket["spent_minor"] = int(bucket["spent_minor"]) + amount_minor

    for row in rows:
        if row["id"] in neutral_ids or row["amount_minor"] >= 0:
            continue
        for identity, amount_minor, counts_as_spending in transaction_allocations(row["id"]):
            if not counts_as_spending:
                continue
            adjust_spending(row["space_id"], identity, -amount_minor)

    for row in rows:
        if row["id"] in neutral_ids or row["amount_minor"] <= 0:
            continue
        if row["id"] not in linked_credits:
            if not any(
                counts_as_spending
                for _, _, counts_as_spending in transaction_allocations(row["id"])
            ):
                continue
            income_minor += row["amount_minor"]
            continue
        original_id = linked_credits[row["id"]]
        if original_id is None or rows_by_id[original_id]["amount_minor"] >= 0:
            continue
        original_allocations = [
            (identity, -amount_minor)
            for identity, amount_minor, counts_as_spending in transaction_allocations(
                original_id
            )
            if amount_minor < 0 and counts_as_spending
        ]
        original_total = sum(amount for _, amount in original_allocations)
        credit_minor = min(row["amount_minor"], original_total)
        if credit_minor <= 0:
            continue
        allocated_refunds: list[int] = []
        remainders: list[int] = []
        for _, amount_minor in original_allocations:
            allocated, remainder = divmod(credit_minor * amount_minor, original_total)
            allocated_refunds.append(allocated)
            remainders.append(remainder)
        for index in sorted(
            range(len(original_allocations)),
            key=lambda item: (remainders[item], original_allocations[item][1]),
            reverse=True,
        )[: credit_minor - sum(allocated_refunds)]:
            allocated_refunds[index] += 1
        original_space_id = rows_by_id[original_id]["space_id"]
        for index, (identity, _) in enumerate(original_allocations):
            adjust_spending(original_space_id, identity, -allocated_refunds[index])

    spending: dict[str, dict[str, object]] = {}
    simple_spending_by_space: dict[str, dict[str, int]] = {}
    for space_id, categories in spending_by_space.items():
        simple_spending_by_space[space_id] = {}
        for category_key, value in categories.items():
            spent_minor = int(value["spent_minor"])
            if spent_minor <= 0:
                continue
            simple_spending_by_space[space_id][category_key] = spent_minor
            bucket = spending.setdefault(
                category_key,
                {
                    "name": value["name"],
                    "spending_type": value["spending_type"],
                    "spent_minor": 0,
                },
            )
            bucket["spent_minor"] = int(bucket["spent_minor"]) + spent_minor

    ordered = sorted(
        (
            (category_key, value)
            for category_key, value in spending.items()
            if int(value["spent_minor"]) > 0
        ),
        key=lambda item: (-int(item[1]["spent_minor"]), str(item[1]["name"]), item[0]),
    )
    spending_total = sum(int(value["spent_minor"]) for _, value in ordered)
    base_shares: list[int] = []
    remainders: list[int] = []
    for _, value in ordered:
        numerator = int(value["spent_minor"]) * 10_000
        base, remainder = divmod(numerator, spending_total)
        base_shares.append(base)
        remainders.append(remainder)
    for index in sorted(
        range(len(ordered)),
        key=lambda item: (remainders[item], int(ordered[item][1]["spent_minor"])),
        reverse=True,
    )[: 10_000 - sum(base_shares)]:
        base_shares[index] += 1
    categories = [
        FinanceOverviewSpendingCategory(
            category_key=category_key,
            name=str(value["name"]),
            spending_type=str(value["spending_type"]),
            spent_minor=int(value["spent_minor"]),
            share_bps=base_shares[index],
        )
        for index, (category_key, value) in enumerate(ordered)
    ]
    return income_minor, categories, simple_spending_by_space


async def _active_budget_buckets(
    db,
    *,
    user: dict,
    scope: Literal["mine", "household"],
    selection: _ScopeSelection,
    currency: str,
    spending: list[FinanceOverviewSpendingCategory],
    spending_by_space: dict[str, dict[str, int]],
) -> list[FinanceOverviewBudgetBucket]:
    async def latest_plan(space_id: str):
        return await (
            await db.execute(
                """
                SELECT * FROM finance_plans
                WHERE space_id = ? AND family_id = ? AND currency = ?
                  AND status = 'ACTIVE' AND deleted_at IS NULL
                ORDER BY activated_at DESC, updated_at DESC, id DESC LIMIT 1
                """,
                (space_id, user["family_id"], currency),
            )
        ).fetchone()

    spend_keys_by_name: dict[str, list[str]] = {}
    for item in spending:
        spend_keys_by_name.setdefault(item.name.casefold(), []).append(item.category_key)
    buckets: dict[str, dict[str, object]] = {}

    async def add_plan(plan, spend_by_key: dict[str, int]) -> None:
        rows = await (
            await db.execute(
                """
                SELECT plan_category.*, category.name AS canonical_name,
                       category.spending_type AS canonical_spending_type
                FROM finance_plan_categories plan_category
                LEFT JOIN finance_categories category
                  ON category.id = plan_category.category_id
                 AND category.space_id = plan_category.space_id
                 AND category.family_id = plan_category.family_id
                 AND category.deleted_at IS NULL
                WHERE plan_category.plan_id = ? AND plan_category.space_id = ?
                  AND plan_category.family_id = ? AND plan_category.deleted_at IS NULL
                ORDER BY plan_category.name, plan_category.category_id
                """,
                (plan["id"], plan["space_id"], user["family_id"]),
            )
        ).fetchall()
        plan_budgets: dict[str, dict[str, object]] = {}
        for row in rows:
            if row["canonical_name"] and row["canonical_spending_type"]:
                category_key, name, _ = _category_identity(
                    row["canonical_name"], row["canonical_spending_type"]
                )
            elif row["category_id"] == "uncategorised" or row["name"].casefold() == "uncategorised":
                category_key, name, _ = _category_identity(None, None, uncategorised=True)
            else:
                name = " ".join(row["name"].split())
                matches = spend_keys_by_name.get(name.casefold(), [])
                category_key = matches[0] if len(matches) == 1 else f"budget:{_safe_slug(name)}"
            plan_bucket = plan_budgets.setdefault(category_key, {"name": name, "budget_minor": 0})
            plan_bucket["budget_minor"] = int(plan_bucket["budget_minor"]) + row["budget_minor"]
        for category_key, value in plan_budgets.items():
            bucket = buckets.setdefault(
                category_key,
                {"name": value["name"], "budget_minor": 0, "spent_minor": 0},
            )
            bucket["budget_minor"] = int(bucket["budget_minor"]) + int(value["budget_minor"])
            bucket["spent_minor"] = int(bucket["spent_minor"]) + spend_by_key.get(category_key, 0)

    combined_spend = {item.category_key: item.spent_minor for item in spending}
    if scope == "household":
        household_plan = await latest_plan(selection.household_space_id)
        if household_plan is not None:
            await add_plan(household_plan, combined_spend)
    else:
        for space_id in selection.planning_space_ids:
            plan = await latest_plan(space_id)
            if plan is not None:
                await add_plan(plan, spending_by_space.get(space_id, {}))

    return [
        FinanceOverviewBudgetBucket(
            category_key=category_key,
            name=str(value["name"]),
            budget_minor=int(value["budget_minor"]),
            spent_minor=int(value["spent_minor"]),
            remaining_minor=int(value["budget_minor"]) - int(value["spent_minor"]),
        )
        for category_key, value in sorted(
            buckets.items(), key=lambda item: (str(item[1]["name"]), item[0])
        )
    ]


def _parse_instant(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed


async def _balance_history(
    db,
    *,
    user: dict,
    accounts: tuple[dict, ...],
    timezone_name: str,
) -> dict[str, list[tuple[date, datetime, int, int | None]]]:
    account_ids = [row["id"] for row in accounts]
    if not account_ids:
        return {}
    rows = await (
        await db.execute(
            f"""
            SELECT account_id, booked_minor, available_minor, observed_at
            FROM finance_balance_snapshots
            WHERE account_id IN ({_placeholders(account_ids)}) AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY observed_at, created_at, id
            """,
            (*account_ids, user["family_id"]),
        )
    ).fetchall()
    zone = household_zone(timezone_name)
    histories: dict[str, list[tuple[date, datetime, int, int | None]]] = {}
    for row in rows:
        observed_at = _parse_instant(row["observed_at"])
        if observed_at is None:
            continue
        histories.setdefault(row["account_id"], []).append(
            (
                observed_at.astimezone(zone).date(),
                observed_at,
                row["booked_minor"],
                row["available_minor"],
            )
        )
    return histories


def _latest_balance(
    history: list[tuple[date, datetime, int, int | None]], day: date
) -> tuple[date, datetime, int, int | None] | None:
    eligible = [item for item in history if item[0] <= day]
    return max(eligible, key=lambda item: item[1]) if eligible else None


def _series_dates(through_date: date) -> list[date]:
    dates: list[date] = []
    month_number = through_date.year * 12 + through_date.month - 1
    for offset in range(-5, 0):
        year, zero_month = divmod(month_number + offset, 12)
        month = zero_month + 1
        dates.append(date(year, month, calendar.monthrange(year, month)[1]))
    dates.append(through_date)
    return dates


def _balance_answers(
    *,
    accounts: tuple[dict, ...],
    histories: dict[str, list[tuple[date, datetime, int, int | None]]],
    month_start: date,
    through_date: date,
) -> tuple[
    int | None,
    int | None,
    int | None,
    list[FinanceOverviewSavingsPoint],
]:
    cash_accounts = [
        row
        for row in accounts
        if row["account_type"] in {"CURRENT", "CASH"}
        and row["purpose"] == "OPERATING_CURRENT"
        and bool(row["include_in_cashflow"])
    ]
    cash_values: list[int] = []
    for account in cash_accounts:
        latest = _latest_balance(histories.get(account["id"], []), through_date)
        if latest is not None:
            cash_values.append(latest[3] if latest[3] is not None else latest[2])
    current_available = sum(cash_values) if cash_values else None

    savings_accounts = [
        row
        for row in accounts
        if bool(row["include_in_cashflow"])
        and (row["account_type"] == "SAVINGS" or row["purpose"] in {"SAVINGS", "GOAL"})
    ]
    latest_savings = {
        row["id"]: latest
        for row in savings_accounts
        if (latest := _latest_balance(histories.get(row["id"], []), through_date)) is not None
    }
    if not latest_savings:
        return current_available, None, None, []
    savings_balance = sum(item[2] for item in latest_savings.values())
    previous_day = month_start - timedelta(days=1)
    previous_savings = {
        account_id: _latest_balance(histories.get(account_id, []), previous_day)
        for account_id in latest_savings
    }
    savings_change = (
        savings_balance - sum(item[2] for item in previous_savings.values() if item)
        if all(item is not None for item in previous_savings.values())
        else None
    )
    series: list[FinanceOverviewSavingsPoint] = []
    for point_date in _series_dates(through_date):
        points = [
            _latest_balance(histories.get(account_id, []), point_date)
            for account_id in latest_savings
        ]
        if all(point is not None for point in points):
            series.append(
                FinanceOverviewSavingsPoint(
                    date=point_date,
                    balance_minor=sum(point[2] for point in points if point),
                )
            )
    return current_available, savings_balance, savings_change, series


async def _next_paycheck(
    db,
    *,
    user: dict,
    selection: _ScopeSelection,
    currency: str,
    through_date: date,
) -> tuple[date | None, int | None]:
    space_ids = selection.planning_space_ids
    row = await (
        await db.execute(
            f"""
            SELECT next_expected_date, SUM(expected_minor) AS amount_minor
            FROM finance_recurring_series
            WHERE space_id IN ({_placeholders(space_ids)}) AND family_id = ?
              AND currency = ? AND series_type = 'SALARY' AND status = 'CONFIRMED'
              AND next_expected_date >= ? AND deleted_at IS NULL
            GROUP BY next_expected_date
            ORDER BY next_expected_date LIMIT 1
            """,
            (*space_ids, user["family_id"], currency, through_date.isoformat()),
        )
    ).fetchone()
    if row is None:
        return None, None
    return date.fromisoformat(row["next_expected_date"]), row["amount_minor"]


def _commitment_amount(row: dict) -> int:
    if row["amount_mode"] == "EXACT":
        return row["exact_minor"]
    if row["amount_mode"] == "RANGE":
        return row["high_minor"]
    return row["expected_minor"]


async def _commitment_answers(
    db,
    *,
    user: dict,
    scope: Literal["mine", "household"],
    selection: _ScopeSelection,
    currency: str,
    through_date: date,
    paycheck_date: date | None,
) -> tuple[int, int, list[FinanceOverviewCommitment]]:
    space_ids = selection.planning_space_ids
    rows = {
        row["id"]: dict(row)
        for row in await (
            await db.execute(
                f"""
                SELECT * FROM finance_commitments
                WHERE space_id IN ({_placeholders(space_ids)}) AND family_id = ?
                  AND currency = ? AND status = 'ACTIVE' AND deleted_at IS NULL
                """,
                (*space_ids, user["family_id"], currency),
            )
        ).fetchall()
    }
    if rows:
        row_ids = sorted(rows)
        links = await (
            await db.execute(
                f"""
                SELECT source_record_id, household_record_id
                FROM finance_share_copy_links
                WHERE family_id = ? AND source_record_type = 'commitment'
                  AND household_record_type = 'commitment'
                  AND (source_record_id IN ({_placeholders(row_ids)})
                       OR household_record_id IN ({_placeholders(row_ids)}))
                  AND deleted_at IS NULL
                """,
                (user["family_id"], *row_ids, *row_ids),
            )
        ).fetchall()
        for link in links:
            if link["source_record_id"] in rows and link["household_record_id"] in rows:
                duplicate_id = (
                    link["source_record_id"]
                    if scope == "household"
                    else link["household_record_id"]
                )
                rows.pop(duplicate_id, None)

    occurrences: list[tuple[date, int, dict]] = []
    for row in rows.values():
        try:
            reviewed_dates = sorted(
                date.fromisoformat(value) for value in json.loads(row["reviewed_dates_json"])
            )
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        next_due = next((value for value in reviewed_dates if value >= through_date), None)
        if next_due is not None:
            occurrences.append((next_due, _commitment_amount(row), row))
    occurrences.sort(key=lambda item: (item[0], item[2]["name"], item[2]["id"]))
    before_payday = (
        [item for item in occurrences if item[0] <= paycheck_date]
        if paycheck_date is not None
        else []
    )
    month_end = through_date.replace(
        day=calendar.monthrange(through_date.year, through_date.month)[1]
    )
    visible_occurrences = [item for item in occurrences if item[0] <= month_end]
    named = [
        FinanceOverviewCommitment(
            name=row["name"],
            due_date=due_date,
            amount_minor=amount_minor,
        )
        for due_date, amount_minor, row in visible_occurrences
        if scope == "mine" or row["space_id"] == selection.household_space_id
    ][:12]
    return (
        sum(item[1] for item in before_payday),
        len(before_payday),
        named,
    )


async def finance_monthly_overview(
    db,
    *,
    user: dict,
    scope: Literal["mine", "household"],
    through_date: date | None = None,
) -> FinanceOverviewResponse:
    settings = await get_finance_settings(db, user=user)
    current_day = through_date or _today(settings.household_timezone)
    month_start = current_day.replace(day=1)
    selection = await _scope_selection(
        db,
        user=user,
        scope=scope,
        currency=settings.default_currency,
    )
    income_minor, spending_categories, spending_by_space = await _monthly_transactions(
        db,
        user=user,
        selection=selection,
        currency=settings.default_currency,
        month_start=month_start,
        through_date=current_day,
    )
    budgets = await _active_budget_buckets(
        db,
        user=user,
        scope=scope,
        selection=selection,
        currency=settings.default_currency,
        spending=spending_categories,
        spending_by_space=spending_by_space,
    )
    histories = await _balance_history(
        db,
        user=user,
        accounts=selection.accounts,
        timezone_name=settings.household_timezone,
    )
    (
        current_available,
        savings_balance,
        savings_change,
        savings_series,
    ) = _balance_answers(
        accounts=selection.accounts,
        histories=histories,
        month_start=month_start,
        through_date=current_day,
    )
    paycheck_date, paycheck_minor = await _next_paycheck(
        db,
        user=user,
        selection=selection,
        currency=settings.default_currency,
        through_date=current_day,
    )
    (
        commitments_minor,
        commitments_count,
        upcoming_commitments,
    ) = await _commitment_answers(
        db,
        user=user,
        scope=scope,
        selection=selection,
        currency=settings.default_currency,
        through_date=current_day,
        paycheck_date=paycheck_date,
    )
    return FinanceOverviewResponse(
        scope=scope,
        month_start=month_start,
        through_date=current_day,
        currency=settings.default_currency,
        account_count=len(selection.accounts),
        income_minor=income_minor,
        spending_minor=sum(item.spent_minor for item in spending_categories),
        spending_by_category=spending_categories,
        budget_buckets=budgets,
        current_available_minor=current_available,
        next_paycheck_date=paycheck_date,
        next_paycheck_minor=paycheck_minor,
        left_until_payday_minor=(
            current_available - commitments_minor
            if current_available is not None and paycheck_date is not None
            else None
        ),
        commitments_before_payday_minor=commitments_minor,
        commitments_before_payday_count=commitments_count,
        upcoming_commitments=upcoming_commitments,
        savings_balance_minor=savings_balance,
        savings_change_minor=savings_change,
        savings_series=savings_series,
    )
