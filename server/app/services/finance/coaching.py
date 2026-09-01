"""Deterministic saved Finance plans, actions, habits, proposals, and reports."""

from __future__ import annotations

import calendar
import hashlib
import json
import uuid
from dataclasses import asdict
from datetime import date, datetime, timedelta, timezone

from app.models.finance_coaching import (
    FinanceCoachingReportResponse,
    FinanceHabitCreate,
    FinanceHabitResponse,
    FinanceHabitReview,
    FinancePaydayActionCreate,
    FinancePaydayActionResolve,
    FinancePaydayActionResponse,
    FinancePlanCategoryResponse,
    FinancePlanGenerate,
    FinancePlanResponse,
    FinancePlanSetResponse,
    FinancePurchaseApprove,
    FinancePurchaseEvaluationRequest,
    FinancePurchaseEvaluationResponse,
    FinancePurchaseProposalCreate,
    FinancePurchaseProposalResponse,
    FinanceReportPreferenceUpdate,
    FinanceReportPreferenceResponse,
)
from app.services.finance.budget import BudgetCategory, allocate_minimal_disruption_budget
from app.services.finance.coach import finance_ai_consent_version, finance_ai_identity
from app.services.finance.dates import household_zone
from app.services.finance.forecast import (
    ForecastAccount,
    ForecastEvent,
    ForecastSnapshot,
    run_forecast,
)
from app.services.finance.foundation import (
    accessible_finance_spaces,
    require_finance_access,
    require_finance_space,
)
from app.services.finance.money import Money
from app.services.finance.report_watermark import finance_space_watermark
from app.models.finance import FinanceSafeToSpendRequest
from app.services.finance.safe_to_spend_api import (
    FinanceSafeToSpendError,
    safe_to_spend_from_forecast,
)
from app.services.finance.understanding import purchase_itemisation_coverage
from app.services.finance.understanding import list_high_impact_purchase_review
from app.services.idempotency import serialized_create
from app.services.record_history import save_history
from app.services.reminders import (
    deliver_finance_report_notification,
    in_quiet_hours,
)

_NEUTRAL_RELATIONS = {"INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT", "FX_LEG"}


class FinanceCoachingError(ValueError):
    """Safe deterministic coaching failure."""


class FinanceCoachingNotFoundError(FinanceCoachingError):
    """An authorised coaching record was not found."""


class FinanceCoachingConflictError(FinanceCoachingError):
    """A coaching state transition is not currently valid."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _digest(value: object) -> str:
    return hashlib.sha256(_json(value).encode("utf-8")).hexdigest()


def _add_months(day: date, months: int) -> date:
    month_number = day.year * 12 + day.month - 1 + months
    year, zero_month = divmod(month_number, 12)
    month = zero_month + 1
    return date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def _ceil_div(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise ValueError("Exact division needs a positive denominator")
    return (numerator + denominator - 1) // denominator


def _money_text(amount_minor: int, currency: str) -> str:
    sign = "-" if amount_minor < 0 else ""
    absolute = abs(amount_minor)
    symbol = "£" if currency == "GBP" else f"{currency} "
    return f"{sign}{symbol}{absolute // 100:,}.{absolute % 100:02d}"


async def _settings(db, *, family_id: str) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM finance_settings WHERE family_id = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (family_id,),
        )
    ).fetchone()
    if row is None:
        raise FinanceCoachingConflictError("Finance settings are not available")
    household_zone(row["household_timezone"])
    return dict(row)


async def _local_today(db, *, family_id: str) -> date:
    settings = await _settings(db, family_id=family_id)
    return datetime.now(timezone.utc).astimezone(
        household_zone(settings["household_timezone"])
    ).date()


async def _authorised_row(db, *, user: dict, table: str, record_id: str) -> dict:
    allowed = {
        "finance_plans",
        "finance_payday_actions",
        "finance_habits",
        "finance_purchase_proposals",
        "finance_purchase_evaluations",
        "finance_coaching_reports",
    }
    if table not in allowed:
        raise ValueError("Unsupported Finance coaching table")
    require_finance_access(user)
    row = await (
        await db.execute(
            f"""
            SELECT record.* FROM {table} record
            JOIN finance_spaces space
              ON space.id = record.space_id AND space.family_id = record.family_id
             AND space.deleted_at IS NULL
            WHERE record.id = ? AND record.family_id = ?
              AND record.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            """,
            (record_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceCoachingNotFoundError("Finance coaching record not found")
    return dict(row)


async def _goal(db, *, user: dict, space_id: str, goal_id: str) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM finance_goals WHERE id = ? AND space_id = ? "
            "AND family_id = ? AND deleted_at IS NULL",
            (goal_id, space_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceCoachingNotFoundError("Finance goal not found")
    if row["status"] != "ACTIVE":
        raise FinanceCoachingConflictError("Only an active goal can produce a plan")
    return dict(row)


async def _plan_inputs(
    db,
    *,
    user: dict,
    space_id: str,
    goal: dict,
    currency: str,
    as_of: date,
) -> dict:
    analysis_end = as_of.replace(day=1) - timedelta(days=1)
    lookback_start = _add_months(analysis_end.replace(day=1), -5)
    rows = await (
        await db.execute(
            """
            SELECT tx.id, tx.amount_minor, tx.primary_category_id,
                   tx.canonical_date,
                   tx.cleaned_description,
                   COALESCE(category.name, 'Uncategorised') AS category_name
            FROM finance_transactions tx
            LEFT JOIN finance_categories category
              ON category.id = tx.primary_category_id
             AND category.space_id = tx.space_id
             AND category.family_id = tx.family_id
             AND category.deleted_at IS NULL
            WHERE tx.space_id = ? AND tx.family_id = ? AND tx.currency = ?
              AND tx.state = 'POSTED' AND tx.deleted_at IS NULL
              AND tx.canonical_date >= ? AND tx.canonical_date <= ?
              AND NOT EXISTS (
                  SELECT 1 FROM finance_transaction_relations relation
                  WHERE relation.space_id = tx.space_id
                    AND relation.family_id = tx.family_id
                    AND relation.status = 'CONFIRMED'
                    AND relation.relation_type IN (
                        'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                    )
                    AND relation.deleted_at IS NULL
                    AND relation.from_transaction_id = tx.id
              )
              AND NOT EXISTS (
                  SELECT 1 FROM finance_transaction_relations relation
                  WHERE relation.space_id = tx.space_id
                    AND relation.family_id = tx.family_id
                    AND relation.status = 'CONFIRMED'
                    AND relation.relation_type IN (
                        'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                    )
                    AND relation.deleted_at IS NULL
                    AND relation.to_transaction_id = tx.id
              )
            ORDER BY tx.canonical_date, tx.id
            """,
            (
                space_id,
                user["family_id"],
                currency,
                lookback_start.isoformat(),
                analysis_end.isoformat(),
            ),
        )
    ).fetchall()
    month_count = 6
    positive_ids = [row["id"] for row in rows if row["amount_minor"] > 0]
    refund_ids: set[str] = set()
    refunds_by_category: dict[str, int] = {}
    if positive_ids:
        placeholders = ",".join("?" for _ in positive_ids)
        relations = await (
            await db.execute(
                f"""
                SELECT relation.to_transaction_id, original.primary_category_id,
                       repayment.amount_minor
                FROM finance_transaction_relations relation
                JOIN finance_transactions original
                  ON original.id = relation.from_transaction_id
                 AND original.space_id = relation.space_id
                 AND original.family_id = relation.family_id
                 AND original.deleted_at IS NULL
                JOIN finance_transactions repayment
                  ON repayment.id = relation.to_transaction_id
                 AND repayment.space_id = relation.space_id
                 AND repayment.family_id = relation.family_id
                 AND repayment.deleted_at IS NULL
                WHERE relation.space_id = ? AND relation.family_id = ?
                  AND relation.status = 'CONFIRMED'
                  AND relation.relation_type IN ('REFUND', 'REIMBURSEMENT')
                  AND relation.to_transaction_id IN ({placeholders})
                  AND relation.deleted_at IS NULL
                """,
                (space_id, user["family_id"], *positive_ids),
            )
        ).fetchall()
        for relation in relations:
            refund_ids.add(relation["to_transaction_id"])
            category_id = relation["primary_category_id"] or "uncategorised"
            refunds_by_category[category_id] = (
                refunds_by_category.get(category_id, 0) + relation["amount_minor"]
            )
    # Plans may rely only on income that has already passed the strict recurring
    # salary review.  A tax refund, gift or isolated credit must never make a
    # target appear affordable merely because it landed in the lookback window.
    salary_rows = await (
        await db.execute(
            "SELECT id, expected_minor, interval_kind, next_expected_date, evidence_json "
            "FROM finance_recurring_series WHERE space_id = ? AND family_id = ? "
            "AND currency = ? AND series_type = 'SALARY' AND status = 'CONFIRMED' "
            "AND deleted_at IS NULL ORDER BY id",
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    salary_monthly_minor = 0
    salary_evidence: list[str] = []
    salary_next_dates: list[date] = []
    for salary in salary_rows:
        if salary["interval_kind"] == "MONTHLY":
            monthly = salary["expected_minor"]
        elif salary["interval_kind"] == "FOUR_WEEKLY":
            monthly = salary["expected_minor"] * 13 // 12
        elif salary["interval_kind"] == "ANNUAL":
            monthly = salary["expected_minor"] // 12
        else:
            # Irregular receipts cannot support a repeatable monthly plan.
            continue
        salary_monthly_minor += max(0, monthly)
        salary_evidence.append(salary["id"])
        if salary["next_expected_date"]:
            candidate = date.fromisoformat(salary["next_expected_date"])
            if candidate >= as_of:
                salary_next_dates.append(candidate)
    by_category: dict[str, dict[str, object]] = {}
    for row in rows:
        if row["amount_minor"] >= 0:
            continue
        category_id = row["primary_category_id"] or "uncategorised"
        current = by_category.setdefault(
            category_id,
            {"name": row["category_name"], "total_minor": 0, "evidence": []},
        )
        current["total_minor"] += -row["amount_minor"]
        current["evidence"].append(row["id"])
    for category_id, refunded_minor in refunds_by_category.items():
        if category_id in by_category:
            by_category[category_id]["total_minor"] = max(
                0,
                int(by_category[category_id]["total_minor"]) - refunded_minor,
            )

    preferences = [
        dict(row)
        for row in await (
            await db.execute(
                "SELECT * FROM finance_preferences WHERE space_id = ? AND family_id = ? "
                "AND status = 'CONFIRMED' AND deleted_at IS NULL ORDER BY preference_key",
                (space_id, user["family_id"]),
            )
        ).fetchall()
    ]
    facts = [
        dict(row)
        for row in await (
            await db.execute(
                "SELECT * FROM finance_facts WHERE space_id = ? AND family_id = ? "
                "AND status = 'CONFIRMED' AND deleted_at IS NULL ORDER BY fact_key",
                (space_id, user["family_id"]),
            )
        ).fetchall()
    ]

    def preference_for(category_id: str, name: str) -> str:
        tokens = {category_id.casefold(), name.casefold()}
        for preference in preferences:
            key = preference["preference_key"].casefold().replace("_", " ")
            statement = preference["statement"].casefold()
            if any(token in key or token in statement for token in tokens):
                return preference["value_kind"]
        return "NEUTRAL"

    categories = []
    for category_id, value in sorted(by_category.items()):
        baseline = int(value["total_minor"]) // month_count
        if baseline <= 0:
            continue
        value_kind = preference_for(category_id, str(value["name"]))
        protected = value_kind == "PROTECTED"
        floor_ratio = {
            "PROTECTED": (1, 1),
            "VALUED": (4, 5),
            "NEUTRAL": (3, 5),
            "NEGOTIABLE": (2, 5),
            "REGRETTED": (1, 4),
        }.get(value_kind, (3, 5))
        weight = {"PROTECTED": 10, "VALUED": 4, "NEUTRAL": 2}.get(value_kind, 1)
        floor = baseline * floor_ratio[0] // floor_ratio[1]
        categories.append(
            {
                "category_id": category_id,
                "name": value["name"],
                "baseline_minor": baseline,
                "floor_minor": floor,
                "aggressive_floor_minor": floor if protected else floor // 2,
                "weight": weight,
                "protected": protected,
                "value_kind": value_kind,
                "evidence_refs": value["evidence"],
            }
        )
    commitments = [
        dict(row)
        for row in await (
            await db.execute(
                "SELECT * FROM finance_commitments WHERE space_id = ? AND family_id = ? "
                "AND status = 'ACTIVE' AND currency = ? AND deleted_at IS NULL",
                (space_id, user["family_id"], currency),
            )
        ).fetchall()
    ]
    commitment_annual_minor = 0
    commitment_inputs: list[dict[str, object]] = []
    for commitment in commitments:
        if commitment["amount_mode"] == "EXACT":
            amount = commitment["exact_minor"]
        elif commitment["amount_mode"] == "RANGE":
            amount = commitment["high_minor"]
        else:
            amount = commitment["expected_minor"]
        dates = [date.fromisoformat(item) for item in json.loads(commitment["reviewed_dates_json"])]
        upcoming = sum(as_of <= item <= _add_months(as_of, 12) for item in dates)
        # Monthly costs and other ordinary recurring spend are already present
        # in the completed-month baseline.  Only exceptional scheduled costs
        # are added, unless the same cost is narrowly evidenced in the baseline.
        words = " ".join(
            part for part in "".join(
                char.casefold() if char.isalnum() else " " for char in commitment["name"]
            ).split() if len(part) >= 3
        )
        represented = False
        if words and len(words) >= 8:
            represented = any(
                words
                == " ".join(
                    part for part in "".join(
                        char.casefold() if char.isalnum() else " "
                        for char in str(row["cleaned_description"] or "")
                    ).split() if len(part) >= 3
                )
                and abs(-row["amount_minor"] - amount) <= max(100, amount // 100)
                for row in rows
                if row["amount_minor"] < 0
            )
        if commitment["recurrence"] == "ANNUAL" and not represented:
            # For annual bills, amount plus the saved reviewed date is stronger
            # evidence than a bank description ("Admiral" need not say "car
            # insurance").  Only a tight date/amount match counts.
            prior_due_dates = [_add_months(item, -12) for item in dates]
            represented = any(
                abs((date.fromisoformat(row["canonical_date"]) - prior_due).days) <= 10
                and abs(-row["amount_minor"] - amount) <= max(100, amount // 100)
                for prior_due in prior_due_dates
                for row in rows
                if row["amount_minor"] < 0
            )
        exceptional = commitment["recurrence"] in {
            "ONE_OFF",
            "ANNUAL",
            "TERMLY",
            "CUSTOM",
        }
        additional = amount * upcoming if exceptional and not represented else 0
        commitment_annual_minor += additional
        commitment_inputs.append(
            {
                "id": commitment["id"],
                "recurrence": commitment["recurrence"],
                "upcoming_count": upcoming,
                "represented_in_baseline": represented,
                "additional_annual_minor": additional,
            }
        )
    commitment_monthly_minor = commitment_annual_minor // 12

    reserves = await (
        await db.execute(
            "SELECT allocated_minor, target_minor FROM finance_reserves "
            "WHERE space_id = ? AND family_id = ? AND status = 'ACTIVE' "
            "AND currency = ? AND deleted_at IS NULL",
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    account_floor = await (
        await db.execute(
            "SELECT COALESCE(SUM(minimum_balance_minor), 0) FROM finance_accounts "
            "WHERE space_id = ? AND family_id = ? AND currency = ? "
            "AND include_in_cashflow = 1 AND deleted_at IS NULL",
            (space_id, user["family_id"], currency),
        )
    ).fetchone()
    reserve_gap = sum(
        max(0, (row["target_minor"] or row["allocated_minor"]) - row["allocated_minor"])
        for row in reserves
    )
    household_buffer_minor = account_floor[0] + reserve_gap
    monthly_income_minor = salary_monthly_minor
    monthly_spend_minor = sum(item["baseline_minor"] for item in categories)
    monthly_surplus_minor = monthly_income_minor - monthly_spend_minor - commitment_monthly_minor
    return {
        "as_of": as_of.isoformat(),
        "lookback_start": lookback_start.isoformat(),
        "analysis_end": analysis_end.isoformat(),
        "month_count": month_count,
        "observed_month_count": len(
            {str(row["canonical_date"])[:7] for row in rows}
        ),
        "posted_transaction_count": len(rows),
        "currency": currency,
        "monthly_income_minor": monthly_income_minor,
        "salary_evidence_refs": salary_evidence,
        "next_contribution_date": (
            min(salary_next_dates).isoformat() if salary_next_dates else as_of.isoformat()
        ),
        "monthly_spend_minor": monthly_spend_minor,
        "commitment_monthly_minor": commitment_monthly_minor,
        "monthly_surplus_minor": monthly_surplus_minor,
        "household_buffer_minor": household_buffer_minor,
        "categories": categories,
        "facts": [
            {
                "id": item["id"],
                "key": item["fact_key"],
                "version": item["version"],
                "statement": item["statement"],
            }
            for item in facts
        ],
        "preferences": [
            {
                "id": item["id"],
                "key": item["preference_key"],
                "version": item["version"],
                "value_kind": item["value_kind"],
            }
            for item in preferences
        ],
        "commitments": commitment_inputs,
        "goal": {
            "id": goal["id"],
            "target_minor": goal["target_minor"],
            "allocated_minor": goal["currently_allocated_minor"],
            "deadline": goal["deadline"],
        },
    }


def _stored_plan_monthly_saving(plan: dict) -> int:
    """Read both current and first-release plan rows without losing their value."""
    planned = max(0, int(plan.get("planned_monthly_saving_minor") or 0))
    if planned == 0:
        planned = max(0, int(plan.get("monthly_change_minor") or 0))
    return planned


def _uncommitted_monthly_surplus(
    raw_monthly_surplus: int,
    active_plan_monthly_total: int,
) -> int:
    """Keep every active goal's transfer reserved as spending improves."""
    return max(0, raw_monthly_surplus - active_plan_monthly_total)


async def _other_active_plan_commitments(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    exclude_goal_id: str,
) -> dict[str, object]:
    """Return an immutable fingerprint of promises made to other active goals."""
    plans = [
        dict(row)
        for row in await (
            await db.execute(
                "SELECT * FROM finance_plans WHERE space_id = ? AND family_id = ? "
                "AND currency = ? AND goal_id <> ? AND status = 'ACTIVE' "
                "AND deleted_at IS NULL ORDER BY id",
                (space_id, user["family_id"], currency, exclude_goal_id),
            )
        ).fetchall()
    ]
    if not plans:
        return {
            "plan_ids": [],
            "planned_monthly_minor": 0,
            "assigned_by_category": {},
            "state_digest": _digest([]),
        }

    plan_ids = [str(plan["id"]) for plan in plans]
    placeholders = ",".join("?" for _ in plan_ids)
    rows = await (
        await db.execute(
            f"SELECT plan_id, category_id, reduction_minor "
            f"FROM finance_plan_categories "
            f"WHERE plan_id IN ({placeholders}) AND space_id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (*plan_ids, space_id, user["family_id"]),
        )
    ).fetchall()
    assigned_by_category: dict[str, int] = {}
    assigned_by_plan: dict[str, list[dict[str, object]]] = {
        plan_id: [] for plan_id in plan_ids
    }
    for row in rows:
        category_id = str(row["category_id"])
        assigned_by_category[category_id] = assigned_by_category.get(category_id, 0) + max(
            0, int(row["reduction_minor"])
        )
        assigned_by_plan[str(row["plan_id"])].append(
            {
                "category_id": category_id,
                "reduction_minor": max(0, int(row["reduction_minor"])),
            }
        )
    state = [
        {
            "id": str(plan["id"]),
            "planned_monthly_minor": _stored_plan_monthly_saving(plan),
            "category_reductions": sorted(
                assigned_by_plan[str(plan["id"])],
                key=lambda item: str(item["category_id"]),
            ),
        }
        for plan in plans
    ]
    return {
        "plan_ids": plan_ids,
        "planned_monthly_minor": sum(
            _stored_plan_monthly_saving(plan) for plan in plans
        ),
        "assigned_by_category": assigned_by_category,
        "state_digest": _digest(state),
    }


async def _other_active_plan_usage(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    exclude_goal_id: str,
    categories: list[dict[str, object]],
) -> dict[str, object]:
    """Return currency-scoped cash and cut capacity already promised elsewhere."""
    commitments = await _other_active_plan_commitments(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        exclude_goal_id=exclude_goal_id,
    )
    assigned_by_category = commitments["assigned_by_category"]

    # A changed lookback can make an old category smaller or remove it entirely.
    # Only the cut capacity still evidenced by the current baseline is reusable as
    # cashflow; the active plan's full transfer remains committed either way.
    category_reductions: dict[str, int] = {}
    for category in categories:
        category_id = str(category["category_id"])
        maximum_cut = max(
            0,
            int(category["baseline_minor"])
            - int(category["aggressive_floor_minor"]),
        )
        committed = min(assigned_by_category.get(category_id, 0), maximum_cut)
        if committed:
            category_reductions[category_id] = committed

    return {
        "plan_ids": commitments["plan_ids"],
        "planned_monthly_minor": commitments["planned_monthly_minor"],
        "achieved_reduction_minor": sum(category_reductions.values()),
        "category_reductions": category_reductions,
        "state_digest": commitments["state_digest"],
    }


def _remaining_categories(
    categories: list[dict[str, object]],
    committed_reductions: dict[str, int],
) -> list[dict[str, object]]:
    """Reduce each allocator baseline by cuts already owned by active goals."""
    remaining: list[dict[str, object]] = []
    for category in categories:
        original = dict(category)
        committed = max(
            0,
            int(committed_reductions.get(str(category["category_id"]), 0)),
        )
        baseline = max(0, int(category["baseline_minor"]) - committed)
        original.update(
            {
                "source_baseline_minor": int(category["baseline_minor"]),
                "source_floor_minor": int(category["floor_minor"]),
                "source_aggressive_floor_minor": int(
                    category["aggressive_floor_minor"]
                ),
                "committed_reduction_minor": committed,
                "baseline_minor": baseline,
                "floor_minor": min(baseline, int(category["floor_minor"])),
                "aggressive_floor_minor": min(
                    baseline, int(category["aggressive_floor_minor"])
                ),
            }
        )
        remaining.append(original)
    return remaining


def _monthly_contribution_dates(first: date, deadline: date) -> tuple[date, ...]:
    """Enumerate contribution dates while retaining the original calendar day."""
    dates: list[date] = []
    offset = 0
    while True:
        contribution = _add_months(first, offset)
        if contribution > deadline:
            break
        dates.append(contribution)
        offset += 1
    return tuple(dates)


def _months_to_deadline(
    as_of: date,
    deadline: date,
    *,
    first_contribution_date: date | None = None,
) -> int:
    first = max(as_of, first_contribution_date or as_of)
    # Keep one immediate planning chunk for an elapsed deadline so legacy saved
    # plans remain displayable. Future arithmetic counts only actual scheduled
    # contribution dates on or before the deadline.
    return max(1, len(_monthly_contribution_dates(first, deadline)))


def _supported_date(
    as_of: date,
    remaining_minor: int,
    contribution_minor: int,
    *,
    first_contribution_date: date | None = None,
) -> date | None:
    if remaining_minor <= 0:
        return as_of
    if contribution_minor <= 0:
        return None
    first = max(as_of, first_contribution_date or as_of)
    payment_count = _ceil_div(remaining_minor, contribution_minor)
    return _add_months(first, payment_count - 1)


async def _plan_forecast_context(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    goal: dict,
    as_of: date,
) -> dict[str, object]:
    """Load available dated evidence without making it a long-term plan gate."""
    row = await (
        await db.execute(
            "SELECT * FROM finance_forecast_snapshots WHERE space_id = ? "
            "AND family_id = ? AND currency = ? AND deleted_at IS NULL "
            "ORDER BY created_at DESC, id DESC LIMIT 1",
            (space_id, user["family_id"], currency),
        )
    ).fetchone()
    if row is None:
        return {
            "usable": False,
            "answer_basis": "BOUNDED",
            "confidence_bps": 6000,
            "reason": (
                "The monthly figures use confirmed income and observed spending; "
                "the next transfer will be checked against current balances."
            ),
        }
    forecast = dict(row)
    try:
        persisted = json.loads(forecast["canonical_input_json"])
        snapshot = _forecast_from_row(forecast)
    except (FinanceCoachingConflictError, TypeError, json.JSONDecodeError):
        return {
            "usable": False,
            "answer_basis": "BOUNDED",
            "confidence_bps": 5500,
            "reason": (
                "The monthly figures use confirmed income and observed spending; "
                "the next transfer will be checked against current balances."
            ),
            "forecast_id": forecast["id"],
        }
    coverage_end = snapshot.end_date.isoformat()
    data_status = persisted.get("data_status")
    raw_data_through = forecast.get("data_through_at")
    through_day = None
    if raw_data_through:
        try:
            through_day = datetime.fromisoformat(
                str(raw_data_through).replace("Z", "+00:00")
            ).date()
        except ValueError:
            through_day = None
    if through_day is None or (as_of - through_day).days > 7:
        dated_note = (
            f"Account records run through {through_day.strftime('%-d %B %Y')}; "
            if through_day is not None
            else "The account record date is not available; "
        )
        return {
            "usable": False,
            "answer_basis": "BOUNDED",
            "confidence_bps": 7000,
            "reason": (
                f"{dated_note}the monthly figures continue from confirmed income and "
                "observed spending."
            ),
            "forecast_id": forecast["id"],
            "coverage_end": coverage_end,
            "data_status": data_status,
        }
    if persisted.get("source") != "SAVED" or data_status != "CURRENT":
        return {
            "usable": False,
            "answer_basis": "BOUNDED",
            "confidence_bps": 6500,
            "reason": (
                f"Account detail is available through {coverage_end}. Later months use "
                "the same confirmed income and observed spending pattern."
            ),
            "forecast_id": forecast["id"],
            "coverage_end": coverage_end,
            "data_status": data_status,
        }
    if not snapshot.start_date <= as_of <= snapshot.end_date:
        return {
            "usable": False,
            "answer_basis": "BOUNDED",
            "confidence_bps": 6500,
            "reason": (
                f"Account detail is available through {coverage_end}. The monthly "
                "figures continue from confirmed income and observed spending."
            ),
            "forecast_id": forecast["id"],
            "coverage_end": coverage_end,
            "data_status": data_status,
        }
    snapshot_ids = {account.id for account in snapshot.accounts}
    try:
        allowed = set(json.loads(goal["allowed_funding_sources_json"]))
    except (TypeError, json.JSONDecodeError):
        allowed = set()
    rows = await (
        await db.execute(
            "SELECT id FROM finance_accounts WHERE space_id = ? AND family_id = ? "
            "AND currency = ? AND account_type IN ('CURRENT', 'CASH') "
            "AND purpose = 'OPERATING_CURRENT' AND include_in_cashflow = 1 "
            "AND provider_presence_status = 'ACTIVE' AND deleted_at IS NULL "
            "ORDER BY primary_spending_account DESC, id",
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    source_ids = [
        row["id"] for row in rows
        if row["id"] in snapshot_ids and (not allowed or row["id"] in allowed)
    ]
    salary = await (
        await db.execute(
            "SELECT next_expected_date FROM finance_recurring_series "
            "WHERE space_id = ? AND family_id = ? AND currency = ? "
            "AND series_type = 'SALARY' AND status = 'CONFIRMED' "
            "AND next_expected_date IS NOT NULL AND deleted_at IS NULL "
            "ORDER BY next_expected_date LIMIT 1",
            (space_id, user["family_id"], currency),
        )
    ).fetchone()
    first_contribution = max(as_of, snapshot.start_date)
    if salary is not None:
        candidate = date.fromisoformat(salary["next_expected_date"])
        if candidate >= first_contribution:
            first_contribution = candidate
    commitment_ids = sorted(
        {
            event.id.split(":", 2)[1]
            for event in snapshot.events
            if event.id.startswith("commitment:") and event.id.count(":") >= 2
        }
    )
    return {
        "usable": True,
        "answer_basis": (
            "ESTIMATED"
            if date.fromisoformat(goal["deadline"]) <= snapshot.end_date
            else "BOUNDED"
        ),
        "confidence_bps": (
            8500 if date.fromisoformat(goal["deadline"]) <= snapshot.end_date else 8000
        ),
        "reason": (
            "The dated account detail covers the requested date."
            if date.fromisoformat(goal["deadline"]) <= snapshot.end_date
            else (
                f"Account detail is available through {coverage_end}. Later months use "
                "the same confirmed income and observed spending pattern."
            )
        ),
        "coverage_end": coverage_end,
        "data_status": data_status,
        "forecast": forecast,
        "snapshot": snapshot,
        "source_account_ids": source_ids,
        "first_contribution_date": first_contribution,
        "active_commitment_ids": commitment_ids,
    }


def _plan_forecast_feasibility(
    context: dict[str, object],
    *,
    monthly_change_minor: int,
    target_date: date,
    household_buffer_minor: int,
    plan_key: str,
) -> dict[str, object]:
    if not context.get("usable"):
        return {
            "passed": False,
            "reason": context.get("reason", "The saved forecast is not usable."),
            "forecast_id": context.get("forecast_id"),
            "shortfall_minor": 0,
        }
    snapshot = context["snapshot"]
    assert isinstance(snapshot, ForecastSnapshot)
    source_ids = list(context["source_account_ids"])
    if monthly_change_minor > 0 and not source_ids:
        return {
            "passed": False,
            "reason": "No eligible operating account is present in the saved forecast.",
            "forecast_id": context["forecast"]["id"],
            "shortfall_minor": monthly_change_minor,
        }
    first_date = context["first_contribution_date"]
    assert isinstance(first_date, date)
    dates = list(
        _monthly_contribution_dates(
            first_date,
            min(target_date, snapshot.end_date),
        )
    )
    candidates = source_ids if monthly_change_minor > 0 else [None]
    best_failure = None
    for source_id in candidates:
        injected = tuple(
            ForecastEvent(
                id=f"plan:{plan_key}:{source_id}:{day.isoformat()}",
                day=day,
                account_id=source_id,
                amount=Money(-monthly_change_minor, snapshot.currency),
                kind="goal",
                sequence=850,
            )
            for day in dates
            if source_id is not None and monthly_change_minor > 0
        )
        result = run_forecast(ForecastSnapshot(
            start_date=snapshot.start_date,
            end_date=snapshot.end_date,
            timezone=snapshot.timezone,
            currency=snapshot.currency,
            accounts=snapshot.accounts,
            events=(*snapshot.events, *injected),
            household_buffer_minor=max(
                snapshot.household_buffer_minor, household_buffer_minor
            ),
            engine_version=snapshot.engine_version,
            non_monotone_rule_ids=snapshot.non_monotone_rule_ids,
        ))
        if result.passed:
            forecast = context["forecast"]
            return {
                "passed": True,
                "reason": "The dated saved forecast passes all account, buffer, and commitment constraints.",
                "forecast_id": forecast["id"],
                "forecast_digest": forecast["input_snapshot_digest"],
                "data_through_at": forecast["data_through_at"],
                "source_account_ids": source_ids,
                "selected_feasible_source_account_id": source_id,
                "active_commitment_ids": context["active_commitment_ids"],
                "shortfall_minor": 0,
            }
        if best_failure is None or (
            result.limiting_event is not None
            and result.limiting_event.shortfall_minor < best_failure.shortfall_minor
        ):
            best_failure = result.limiting_event
    forecast = context["forecast"]
    return {
        "passed": False,
        "reason": "The dated saved forecast breaches an account floor or household buffer.",
        "forecast_id": forecast["id"],
        "forecast_digest": forecast["input_snapshot_digest"],
        "data_through_at": forecast["data_through_at"],
        "source_account_ids": source_ids,
        "active_commitment_ids": context["active_commitment_ids"],
        "shortfall_minor": best_failure.shortfall_minor if best_failure else 0,
    }


async def _plan_response(db, row: dict) -> FinancePlanResponse:
    categories = await (
        await db.execute(
            "SELECT * FROM finance_plan_categories WHERE plan_id = ? "
            "AND space_id = ? AND family_id = ? AND deleted_at IS NULL "
            "ORDER BY category_id",
            (row["id"], row["space_id"], row["family_id"]),
        )
    ).fetchall()
    try:
        assumptions = json.loads(row.get("assumptions_json") or "[]")
    except (TypeError, json.JSONDecodeError):
        assumptions = []
    try:
        input_snapshot = json.loads(row.get("input_snapshot_json") or "{}")
    except (TypeError, json.JSONDecodeError):
        input_snapshot = {}
    planned_monthly = int(row.get("planned_monthly_saving_minor") or 0)
    if planned_monthly == 0 and row["monthly_change_minor"] > 0:
        planned_monthly = row["monthly_change_minor"]
    required_monthly = int(row.get("required_monthly_minor") or 0)
    projected_amount = int(row.get("projected_amount_at_target_minor") or 0)
    goal_shortfall = int(
        row.get("goal_shortfall_at_target_minor") or row["shortfall_minor"]
    )
    supported_goal_date = row["supported_goal_date"]
    # Columns added after the first planning release default to zero. Rebuild
    # those display figures from the plan's own saved inputs so an older active
    # plan never appears to require or accumulate £0.
    if "planned_monthly_saving_minor" not in input_snapshot:
        goal_snapshot = input_snapshot.get("goal")
        if isinstance(goal_snapshot, dict):
            target_minor = int(goal_snapshot.get("target_minor") or 0)
            allocated_minor = int(goal_snapshot.get("allocated_minor") or 0)
            deadline_value = str(goal_snapshot.get("deadline") or row["target_date"])
            try:
                start_date = date.fromisoformat(
                    str(input_snapshot.get("as_of") or row["created_at"][:10])
                )
                deadline = date.fromisoformat(deadline_value)
            except ValueError:
                start_date = date.fromisoformat(row["created_at"][:10])
                deadline = date.fromisoformat(row["target_date"])
            months = _months_to_deadline(start_date, deadline)
            remaining_minor = max(0, target_minor - allocated_minor)
            required_monthly = _ceil_div(remaining_minor, months) if remaining_minor else 0
            planned_monthly = max(
                0,
                int(input_snapshot.get("monthly_surplus_minor") or 0)
                + max(0, int(row["monthly_change_minor"])),
            )
            projected_amount = max(0, allocated_minor + planned_monthly * months)
            goal_shortfall = max(0, target_minor - projected_amount)
            if supported_goal_date is None:
                supported = _supported_date(start_date, remaining_minor, planned_monthly)
                supported_goal_date = supported.isoformat() if supported else None
    return FinancePlanResponse(
        id=row["id"],
        proposal_group_id=row["proposal_group_id"],
        space_id=row["space_id"],
        version=row["version"],
        strategy=row["strategy"],
        effort_level=row.get("effort_level") or {
            "MINIMAL_DISRUPTION": "EASY",
            "TARGET_DATE": "MEDIUM",
            "AGGRESSIVE": "HARD",
            "RESILIENT": "MEDIUM",
        }[row["strategy"]],
        answer_basis=row.get("answer_basis") or "ESTIMATED",
        confidence_bps=int(row.get("confidence_bps") or 5000),
        currency=row["currency"],
        goal_id=row["goal_id"],
        source_plan_id=row["source_plan_id"],
        recovery_mode=row["recovery_mode"],
        target_date=row["target_date"],
        supported_goal_date=supported_goal_date,
        forecast_coverage_end=row.get("forecast_coverage_end"),
        required_monthly_minor=required_monthly,
        planned_monthly_saving_minor=planned_monthly,
        projected_amount_at_target_minor=projected_amount,
        goal_shortfall_at_target_minor=goal_shortfall,
        monthly_change_minor=row["monthly_change_minor"],
        household_buffer_minor=row["household_buffer_minor"],
        required_reduction_minor=row["required_reduction_minor"],
        achieved_reduction_minor=row["achieved_reduction_minor"],
        shortfall_minor=row["shortfall_minor"],
        feasible=bool(row["feasible"]),
        protected_category_count=row["protected_category_count"],
        status=row["status"],
        rationale=row["rationale"],
        assumptions=[str(item) for item in assumptions if str(item).strip()],
        categories=[
            FinancePlanCategoryResponse(
                category_id=item["category_id"],
                name=item["name"],
                baseline_minor=item["baseline_minor"],
                floor_minor=item["floor_minor"],
                protected=bool(item["protected"]),
                weight=item["weight"],
                reduction_minor=item["reduction_minor"],
                budget_minor=item["budget_minor"],
            )
            for item in categories
        ],
        activated_at=row["activated_at"],
        created_at=row["created_at"],
    )


def _tier_reduction_targets(
    categories: list[dict[str, object]],
    *,
    required_reduction_minor: int,
) -> dict[str, int]:
    """Return increasing cuts without asking for more than the goal needs."""
    required_reduction_minor = max(0, required_reduction_minor)
    normal_capacity = sum(
        max(0, int(item["baseline_minor"]) - int(item["floor_minor"]))
        for item in categories
        if not item["protected"]
    )
    hard_capacity = sum(
        max(0, int(item["baseline_minor"]) - int(item["aggressive_floor_minor"]))
        for item in categories
        if not item["protected"]
    )

    def portion(capacity: int, numerator: int, denominator: int) -> int:
        if capacity <= 0:
            return 0
        return max(1, capacity * numerator // denominator)

    easy = min(required_reduction_minor, portion(normal_capacity, 1, 3))
    medium = min(
        required_reduction_minor,
        normal_capacity,
        max(
            easy,
            portion(normal_capacity, 2, 3),
        ),
    )
    hard = max(medium, min(required_reduction_minor, hard_capacity))
    return {
        "MINIMAL_DISRUPTION": easy,
        "TARGET_DATE": medium,
        "AGGRESSIVE": hard,
    }


def _plan_result_text(
    *,
    effort_level: str,
    planned_monthly_minor: int,
    projected_amount_minor: int,
    shortfall_minor: int,
    supported_date: date | None,
    target_date: date,
    currency: str,
) -> str:
    prefix = {
        "EASY": "Easy keeps the changes light.",
        "MEDIUM": "Medium is the recommended balance of progress and family life.",
        "HARD": "Hard uses every spending cut the figures support while keeping essentials protected.",
    }[effort_level]
    pace = f" It saves {_money_text(planned_monthly_minor, currency)} a month."
    if shortfall_minor == 0:
        finish = supported_date or target_date
        return f"{prefix}{pace} It reaches the target by {finish.strftime('%-d %B %Y')}."
    result = (
        f" By {target_date.strftime('%-d %B %Y')} it builds "
        f"{_money_text(projected_amount_minor, currency)}, leaving "
        f"{_money_text(shortfall_minor, currency)} still to find."
    )
    if supported_date is not None:
        result += f" At this pace the full target is reached by {supported_date.strftime('%-d %B %Y')}."
    else:
        result += " Any monthly contribution will bring the completion date forward."
    return f"{prefix}{pace}{result}"


async def generate_plan_strategies(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinancePlanGenerate,
) -> FinancePlanSetResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    goal = await _goal(db, user=user, space_id=space_id, goal_id=body.goal_id)
    currency = goal["currency"]
    as_of = await _local_today(db, family_id=user["family_id"])
    inputs = await _plan_inputs(
        db,
        user=user,
        space_id=space_id,
        goal=goal,
        currency=currency,
        as_of=as_of,
    )
    raw_monthly_surplus = int(inputs["monthly_surplus_minor"])
    other_usage = await _other_active_plan_usage(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        exclude_goal_id=goal["id"],
        categories=inputs["categories"],
    )
    other_planned_monthly = int(other_usage["planned_monthly_minor"])
    other_achieved_reduction = int(other_usage["achieved_reduction_minor"])
    available_monthly_surplus = _uncommitted_monthly_surplus(
        raw_monthly_surplus,
        other_planned_monthly,
    )
    inputs.update(
        {
            "raw_monthly_surplus_minor": raw_monthly_surplus,
            "monthly_surplus_minor": available_monthly_surplus,
            "other_active_plan_ids": other_usage["plan_ids"],
            "other_active_plan_digest": other_usage["state_digest"],
            "other_active_planned_monthly_minor": other_planned_monthly,
            "other_active_achieved_reduction_minor": other_achieved_reduction,
            "other_active_category_reductions": other_usage[
                "category_reductions"
            ],
            "categories": _remaining_categories(
                inputs["categories"],
                other_usage["category_reductions"],
            ),
        }
    )
    source_plan = None
    if body.source_plan_id:
        source_plan = await _authorised_row(
            db, user=user, table="finance_plans", record_id=body.source_plan_id
        )
        if source_plan["space_id"] != space_id:
            raise FinanceCoachingNotFoundError("Source plan not found")
        if source_plan["currency"] != currency:
            raise FinanceCoachingConflictError(
                "Recovery plans must use the saved goal currency"
            )
    remaining_goal = max(0, goal["target_minor"] - goal["currently_allocated_minor"])
    months = _months_to_deadline(
        as_of,
        date.fromisoformat(goal["deadline"]),
        first_contribution_date=date.fromisoformat(inputs["next_contribution_date"]),
    )
    required_contribution = _ceil_div(remaining_goal, months) if remaining_goal else 0
    monthly_surplus = inputs["monthly_surplus_minor"]
    required_reduction = max(0, required_contribution - monthly_surplus)
    forecast_context = await _plan_forecast_context(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        goal=goal,
        as_of=as_of,
    )
    if source_plan is not None:
        source_categories = await (
            await db.execute(
                "SELECT category_id, budget_minor FROM finance_plan_categories "
                "WHERE plan_id = ? AND deleted_at IS NULL",
                (source_plan["id"],),
            )
        ).fetchall()
        current_month_start = as_of.replace(day=1).isoformat()
        actual_rows = await (
            await db.execute(
                """
                SELECT COALESCE(primary_category_id, 'uncategorised') AS category_id,
                       SUM(-amount_minor) AS spend_minor
                FROM finance_transactions
                WHERE space_id = ? AND family_id = ? AND currency = ?
                  AND state = 'POSTED' AND amount_minor < 0
                  AND canonical_date BETWEEN ? AND ? AND deleted_at IS NULL
                GROUP BY COALESCE(primary_category_id, 'uncategorised')
                """,
                (
                    space_id,
                    user["family_id"],
                    currency,
                    current_month_start,
                    as_of.isoformat(),
                ),
            )
        ).fetchall()
        budgets = {row["category_id"]: row["budget_minor"] for row in source_categories}
        drift = sum(
            max(0, row["spend_minor"] - budgets.get(row["category_id"], row["spend_minor"]))
            for row in actual_rows
        )
        if body.recovery_mode == "CURRENT_CYCLE":
            required_reduction += drift
        elif body.recovery_mode == "SPREAD_CYCLES":
            required_reduction += _ceil_div(drift, 3)
        elif body.recovery_mode == "USE_UNDERSPEND":
            required_reduction += max(0, drift // 2)
        elif body.recovery_mode == "DEFER_PURCHASE":
            required_reduction += max(0, drift - inputs["commitment_monthly_minor"])
        elif body.recovery_mode == "ACCEPT_NEW_DATE":
            required_reduction = max(0, required_reduction * 4 // 5)

    tier_reductions = _tier_reduction_targets(
        inputs["categories"],
        required_reduction_minor=required_reduction,
    )
    strategy_inputs = {
        "MINIMAL_DISRUPTION": ("EASY", False),
        "TARGET_DATE": ("MEDIUM", False),
        "AGGRESSIVE": ("HARD", True),
    }
    version_row = await (
        await db.execute(
            "SELECT COALESCE(MAX(version), 0) FROM finance_plans WHERE space_id = ?",
            (space_id,),
        )
    ).fetchone()
    version = version_row[0] + 1
    proposal_group_id = str(uuid.uuid4())
    now = _now()
    saved_rows = []
    async with serialized_create(db):
        for strategy, (effort_level, aggressive) in strategy_inputs.items():
            strategy_required = tier_reductions[strategy]
            buffer_minor = inputs["household_buffer_minor"]
            budget_categories = tuple(
                BudgetCategory(
                    id=item["category_id"],
                    baseline_minor=item["baseline_minor"],
                    floor_minor=(
                        item["aggressive_floor_minor"] if aggressive else item["floor_minor"]
                    ),
                    weight=item["weight"],
                    protected=item["protected"],
                )
                for item in inputs["categories"]
            )
            result = allocate_minimal_disruption_budget(
                budget_categories,
                strategy_required,
            )
            # A plan is a contribution towards this goal, not permission to move
            # every spare pound into it. Never propose more per month than is
            # required to meet the saved target date.
            planned_monthly = min(
                required_contribution,
                max(0, monthly_surplus + result.achieved_reduction_minor),
            )
            supported = _supported_date(
                as_of,
                remaining_goal,
                planned_monthly,
                first_contribution_date=date.fromisoformat(
                    inputs["next_contribution_date"]
                ),
            )
            projected_amount = max(
                0,
                goal["currently_allocated_minor"] + planned_monthly * months,
            )
            goal_shortfall = max(0, goal["target_minor"] - projected_amount)
            forecast_feasibility = _plan_forecast_feasibility(
                forecast_context,
                monthly_change_minor=planned_monthly,
                target_date=date.fromisoformat(goal["deadline"]),
                household_buffer_minor=buffer_minor,
                plan_key=f"{proposal_group_id}:{strategy}",
            )
            answer_basis = str(forecast_context.get("answer_basis", "BOUNDED"))
            confidence_bps = int(forecast_context.get("confidence_bps", 6000))
            if inputs["observed_month_count"] < 4:
                answer_basis = "BOUNDED"
                confidence_bps -= 1000
            if not inputs["salary_evidence_refs"]:
                answer_basis = "BOUNDED"
                confidence_bps -= 1500
            if not inputs["categories"]:
                answer_basis = "BOUNDED"
                confidence_bps -= 1500
            confidence_bps += {"EASY": 300, "MEDIUM": 0, "HARD": -500}[effort_level]
            confidence_bps = max(3000, min(9500, confidence_bps))
            target_date = date.fromisoformat(goal["deadline"])
            rationale = _plan_result_text(
                effort_level=effort_level,
                planned_monthly_minor=planned_monthly,
                projected_amount_minor=projected_amount,
                shortfall_minor=goal_shortfall,
                supported_date=supported,
                target_date=target_date,
                currency=currency,
            )
            assumptions = [
                (
                    f"The required monthly amount divides the remaining "
                    f"{_money_text(remaining_goal, currency)} across {months} monthly contributions."
                ),
                (
                    f"Income uses {len(inputs['salary_evidence_refs'])} confirmed recurring "
                    f"salary source{'s' if len(inputs['salary_evidence_refs']) != 1 else ''}."
                ),
            ]
            if other_planned_monthly:
                assumptions.append(
                    "Other active goals already use "
                    f"{_money_text(other_planned_monthly, currency)} a month."
                )
            if inputs["categories"]:
                assumptions.append(
                    f"Spending uses {inputs['observed_month_count']} observed month"
                    f"{'s' if inputs['observed_month_count'] != 1 else ''} and "
                    f"{inputs['posted_transaction_count']} posted transactions."
                )
                assumptions.append(
                    {
                        "EASY": "Easy uses one third of the ordinary room in non-protected categories.",
                        "MEDIUM": "Medium uses roughly two thirds of the ordinary room in non-protected categories.",
                        "HARD": "Hard uses all the room found in spending that is not protected.",
                    }[effort_level]
                )
            else:
                assumptions.append(
                    "With the spending listed so far, this plan counts the existing monthly surplus and no category cuts."
                )
            if forecast_feasibility.get("passed"):
                assumptions.append(
                    "This monthly amount fits the dated account detail currently available."
                )
            else:
                assumptions.append(
                    "The next transfer will be checked against balances, bills and the cash buffer and reduced if needed."
                )
            evidence_note = forecast_context.get("reason")
            if evidence_note:
                assumptions.append(str(evidence_note))
            plan_id = str(uuid.uuid4())
            snapshot = {
                **inputs,
                "required_goal_contribution_minor": required_contribution,
                "remaining_goal_minor": remaining_goal,
                "recovery_mode": body.recovery_mode,
                "source_plan_id": body.source_plan_id,
                "strategy": strategy,
                "effort_level": effort_level,
                "answer_basis": answer_basis,
                "confidence_bps": confidence_bps,
                "required_monthly_minor": required_contribution,
                "planned_monthly_saving_minor": planned_monthly,
                "projected_amount_at_target_minor": projected_amount,
                "goal_shortfall_at_target_minor": goal_shortfall,
                "forecast_coverage_end": forecast_context.get("coverage_end"),
                "assumptions": assumptions,
                "forecast_feasibility": forecast_feasibility,
            }
            await db.execute(
                """
                INSERT INTO finance_plans
                    (id, space_id, proposal_group_id, version, strategy, effort_level,
                     answer_basis, confidence_bps, currency, goal_id,
                     source_plan_id, recovery_mode, target_date, supported_goal_date,
                     forecast_coverage_end, required_monthly_minor,
                     planned_monthly_saving_minor, projected_amount_at_target_minor,
                     goal_shortfall_at_target_minor,
                     monthly_change_minor, household_buffer_minor,
                     required_reduction_minor, achieved_reduction_minor,
                     shortfall_minor, feasible, protected_category_count,
                     input_snapshot_json, rationale, assumptions_json, status, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PROPOSED', ?, ?, ?, ?)
                """,
                (
                    plan_id,
                    space_id,
                    proposal_group_id,
                    version,
                    strategy,
                    effort_level,
                    answer_basis,
                    confidence_bps,
                    currency,
                    goal["id"],
                    body.source_plan_id,
                    body.recovery_mode,
                    goal["deadline"],
                    supported.isoformat() if supported else None,
                    forecast_context.get("coverage_end"),
                    required_contribution,
                    planned_monthly,
                    projected_amount,
                    goal_shortfall,
                    planned_monthly,
                    buffer_minor,
                    required_reduction,
                    result.achieved_reduction_minor,
                    goal_shortfall,
                    1,
                    sum(item["protected"] for item in inputs["categories"]),
                    _json(snapshot),
                    rationale,
                    _json(assumptions),
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
            allocation_by_id = {item.category_id: item for item in result.allocations}
            for item in inputs["categories"]:
                allocation = allocation_by_id[item["category_id"]]
                source_baseline = int(item["source_baseline_minor"])
                source_floor = int(
                    item[
                        "source_aggressive_floor_minor"
                        if aggressive
                        else "source_floor_minor"
                    ]
                )
                await db.execute(
                    """
                    INSERT INTO finance_plan_categories
                        (id, space_id, plan_id, category_id, name, baseline_minor,
                         floor_minor, protected, weight, reduction_minor,
                         budget_minor, family_id, created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        space_id,
                        plan_id,
                        item["category_id"],
                        item["name"],
                        source_baseline,
                        source_floor,
                        int(item["protected"]),
                        item["weight"],
                        allocation.reduction_minor,
                        max(0, source_baseline - allocation.reduction_minor),
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
            saved = await (
                await db.execute("SELECT * FROM finance_plans WHERE id = ?", (plan_id,))
            ).fetchone()
            saved_rows.append(dict(saved))
    plans = [await _plan_response(db, row) for row in saved_rows]
    return FinancePlanSetResponse(
        proposal_group_id=proposal_group_id,
        version=version,
        recommendation_strategy="TARGET_DATE",
        recommendation_effort_level="MEDIUM",
        plans=plans,
    )


async def list_plans(
    db, *, user: dict, space_id: str, include_inactive: bool = False
) -> list[FinancePlanResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_inactive else "AND status IN ('PROPOSED', 'ACTIVE')"
    rows = await (
        await db.execute(
            f"SELECT * FROM finance_plans WHERE space_id = ? AND family_id = ? "
            f"AND deleted_at IS NULL {clause} ORDER BY version DESC, strategy",
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [await _plan_response(db, dict(row)) for row in rows]


async def activate_plan(db, *, user: dict, plan_id: str) -> FinancePlanResponse:
    row = await _authorised_row(db, user=user, table="finance_plans", record_id=plan_id)
    if row["status"] != "PROPOSED":
        raise FinanceCoachingConflictError("Only a proposed plan can be activated")
    now = _now()
    async with serialized_create(db):
        try:
            snapshot = json.loads(row.get("input_snapshot_json") or "{}")
        except (TypeError, json.JSONDecodeError):
            snapshot = {}
        current_other = await _other_active_plan_commitments(
            db,
            user=user,
            space_id=row["space_id"],
            currency=row["currency"],
            exclude_goal_id=row["goal_id"],
        )
        expected_other_ids = sorted(
            str(active_id)
            for active_id in snapshot.get("other_active_plan_ids", [])
        )
        current_other_ids = sorted(
            str(active_id) for active_id in current_other["plan_ids"]
        )
        expected_digest = snapshot.get("other_active_plan_digest")
        commitments_changed = expected_other_ids != current_other_ids
        if expected_digest is not None:
            commitments_changed = commitments_changed or (
                str(expected_digest) != str(current_other["state_digest"])
            )
        if commitments_changed:
            raise FinanceCoachingConflictError(
                "Another savings goal changed the available monthly budget; "
                "generate these choices again"
            )
        active = await (
            await db.execute(
                "SELECT id FROM finance_plans WHERE space_id = ? AND family_id = ? "
                "AND goal_id = ? AND status = 'ACTIVE' AND deleted_at IS NULL",
                (row["space_id"], user["family_id"], row["goal_id"]),
            )
        ).fetchall()
        for current in active:
            await save_history(
                db,
                "finance_plans",
                current["id"],
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                "UPDATE finance_plans SET status = 'SUPERSEDED', updated_at = ? "
                "WHERE id = ?",
                (now, current["id"]),
            )
        await save_history(
            db,
            "finance_plans",
            plan_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_plans SET status = 'ACTIVE', activated_at = ?, "
            "updated_at = ? WHERE id = ?",
            (now, now, plan_id),
        )
    row.update(status="ACTIVE", activated_at=now, updated_at=now)
    return await _plan_response(db, row)


def _payday_response(row: dict) -> FinancePaydayActionResponse:
    return FinancePaydayActionResponse(
        id=row["id"],
        space_id=row["space_id"],
        plan_id=row["plan_id"],
        due_date=row["due_date"],
        source_account_id=row["source_account_id"],
        destination_account_id=row["destination_account_id"],
        amount_minor=row["amount_minor"],
        safe_after_transfer_minor=row["safe_after_transfer_minor"],
        answer_mode=row.get("answer_mode") or "CURRENT_EXACT",
        data_through_at=row.get("data_through_at"),
        currency=row["currency"],
        date_tolerance_days=row["date_tolerance_days"],
        grace_days=row["grace_days"],
        status=row["status"],
        matched_relation_id=row["matched_relation_id"],
        matched_at=row["matched_at"],
        changed_amount_minor=row["changed_amount_minor"],
        recalculated_action_id=row["recalculated_action_id"],
        resolution_note=row["resolution_note"],
        updated_at=row["updated_at"],
    )


async def _latest_forecast(db, *, family_id: str, space_id: str) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM finance_forecast_snapshots WHERE space_id = ? "
            "AND family_id = ? AND deleted_at IS NULL "
            "ORDER BY created_at DESC, id DESC LIMIT 1",
            (space_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise FinanceCoachingConflictError(
            "Generate a saved forecast before creating a payday action"
        )
    return dict(row)


async def _payday_forecast_evidence(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    current_date: date,
) -> tuple[dict, ForecastSnapshot, str, str]:
    """Return complete saved evidence suitable for an exact payday simulation."""
    forecast = await _latest_forecast(
        db,
        family_id=user["family_id"],
        space_id=space_id,
    )
    try:
        persisted = json.loads(forecast["canonical_input_json"])
        saved_snapshot = _forecast_from_row(forecast)
    except (FinanceCoachingConflictError, TypeError, json.JSONDecodeError):
        raise FinanceCoachingConflictError("The saved forecast is not usable") from None
    if saved_snapshot.currency != currency:
        raise FinanceCoachingConflictError(
            "Refresh the saved forecast for the payday action currency"
        )
    if persisted.get("source") != "SAVED" or persisted.get("data_status") != "CURRENT":
        raise FinanceCoachingConflictError(
            "Refresh the complete saved forecast before creating a payday transfer"
        )
    raw_data_through = forecast.get("data_through_at")
    if not raw_data_through:
        raise FinanceCoachingConflictError(
            "The saved forecast has no account data-through time"
        )
    try:
        data_through = datetime.fromisoformat(
            str(raw_data_through).replace("Z", "+00:00")
        )
        if data_through.tzinfo is None or data_through.utcoffset() is None:
            raise ValueError
    except ValueError:
        raise FinanceCoachingConflictError(
            "The saved forecast has no usable account data-through time"
        ) from None
    through_day = data_through.astimezone(
        household_zone(saved_snapshot.timezone)
    ).date()
    age_days = max(0, (current_date - through_day).days)
    if age_days > 7:
        raise FinanceCoachingConflictError(
            "Account data is too old for a payday transfer; refresh it first"
        )
    answer_mode = "CURRENT_EXACT" if age_days <= 1 else "DATED_EXACT"
    if answer_mode == "DATED_EXACT":
        preference = await (
            await db.execute(
                "SELECT allow_dated_estimates FROM finance_report_preferences "
                "WHERE member_user_id = ? AND space_id = ? AND family_id = ? "
                "AND deleted_at IS NULL",
                (user["id"], space_id, user["family_id"]),
            )
        ).fetchone()
        if preference is not None and not preference["allow_dated_estimates"]:
            raise FinanceCoachingConflictError(
                "Dated Finance estimates are disabled; refresh account data first"
            )
    return forecast, saved_snapshot, answer_mode, str(raw_data_through)


def _payday_transfer_simulation(
    snapshot: ForecastSnapshot,
    *,
    source_account_id: str,
    destination_account_id: str,
    due_date: date,
    requested_minor: int,
) -> tuple[int, int]:
    """Find the exact transfer supported by the selected source account."""
    if due_date < snapshot.start_date or due_date > snapshot.end_date:
        raise FinanceCoachingConflictError(
            "The proposed payday falls outside the saved forecast"
        )
    snapshot_ids = {account.id for account in snapshot.accounts}
    if source_account_id not in snapshot_ids or destination_account_id not in snapshot_ids:
        raise FinanceCoachingConflictError(
            "Both payday accounts must be present in the saved forecast"
        )

    def evaluate(amount_minor: int):
        event = ForecastEvent(
            id=f"payday:{source_account_id}:{destination_account_id}:{due_date.isoformat()}",
            day=due_date,
            account_id=source_account_id,
            destination_account_id=destination_account_id,
            amount=Money(-amount_minor, snapshot.currency),
            kind="transfer",
            sequence=840,
        )
        return run_forecast(ForecastSnapshot(
            start_date=snapshot.start_date,
            end_date=snapshot.end_date,
            timezone=snapshot.timezone,
            currency=snapshot.currency,
            accounts=snapshot.accounts,
            events=(*snapshot.events, event),
            household_buffer_minor=snapshot.household_buffer_minor,
            engine_version=snapshot.engine_version,
            non_monotone_rule_ids=snapshot.non_monotone_rule_ids,
        ))

    baseline = run_forecast(snapshot)
    if not baseline.passed:
        raise FinanceCoachingConflictError(
            "The saved forecast already breaches a dated account constraint"
        )
    low, high = 0, requested_minor
    best = None
    while low <= high:
        candidate = (low + high) // 2
        if candidate == 0:
            passed = True
            result = baseline
        else:
            result = evaluate(candidate)
            passed = result.passed
        if passed:
            best = result
            low = candidate + 1
        else:
            high = candidate - 1
    amount_minor = high
    if amount_minor <= 0:
        raise FinanceCoachingConflictError(
            "The selected source account cannot safely fund this transfer"
        )
    if amount_minor != requested_minor or best is None:
        best = evaluate(amount_minor)
    source_headroom = min(
        account.headroom_minor
        for day_result in best.days
        for account in day_result.accounts
        if account.account_id == source_account_id
    )
    return amount_minor, source_headroom


async def create_payday_action(
    db,
    *,
    user: dict,
    body: FinancePaydayActionCreate,
) -> FinancePaydayActionResponse:
    plan = await _authorised_row(
        db, user=user, table="finance_plans", record_id=body.plan_id
    )
    if plan["status"] != "ACTIVE":
        raise FinanceCoachingConflictError("Payday actions require an active plan")
    if plan["monthly_change_minor"] <= 0:
        raise FinanceCoachingConflictError("The active plan has no payday saving action")
    currency = plan["currency"]
    accounts = await (
        await db.execute(
            "SELECT id, currency, account_type, purpose, include_in_cashflow, "
            "provider_presence_status "
            "FROM finance_accounts WHERE id IN (?, ?) "
            "AND space_id = ? AND family_id = ? AND deleted_at IS NULL",
            (
                body.source_account_id,
                body.destination_account_id,
                plan["space_id"],
                user["family_id"],
            ),
        )
    ).fetchall()
    if {row["id"] for row in accounts} != {
        body.source_account_id,
        body.destination_account_id,
    } or any(row["currency"] != currency for row in accounts):
        raise FinanceCoachingNotFoundError("Payday action accounts are not available")
    accounts_by_id = {row["id"]: dict(row) for row in accounts}
    source = accounts_by_id[body.source_account_id]
    destination = accounts_by_id[body.destination_account_id]
    if (
        source["account_type"] != "CURRENT"
        or source["purpose"] != "OPERATING_CURRENT"
        or not source["include_in_cashflow"]
        or source["provider_presence_status"] != "ACTIVE"
    ):
        raise FinanceCoachingConflictError(
            "Payday transfers must start from an included operating current account"
        )
    if (
        destination["purpose"] not in {"SAVINGS", "GOAL"}
        or destination["account_type"] in {"CREDIT_CARD", "INVESTMENT", "CRYPTO"}
        or not destination["include_in_cashflow"]
        or destination["provider_presence_status"] != "ACTIVE"
    ):
        raise FinanceCoachingConflictError(
            "Payday transfers must end in a savings or goal account"
        )
    salary = await (
        await db.execute(
            "SELECT next_expected_date FROM finance_recurring_series "
            "WHERE space_id = ? AND family_id = ? AND series_type = 'SALARY' "
            "AND status = 'CONFIRMED' AND next_expected_date IS NOT NULL "
            "AND deleted_at IS NULL ORDER BY next_expected_date LIMIT 1",
            (plan["space_id"], user["family_id"]),
        )
    ).fetchone()
    local_today = await _local_today(db, family_id=user["family_id"])
    due_date = (
        date.fromisoformat(salary["next_expected_date"])
        if salary is not None
        and date.fromisoformat(salary["next_expected_date"]) >= local_today
        else local_today
    )
    _, saved_snapshot, answer_mode, raw_data_through = (
        await _payday_forecast_evidence(
            db,
            user=user,
            space_id=plan["space_id"],
            currency=currency,
            current_date=local_today,
        )
    )
    amount_minor, safe_after_transfer_minor = _payday_transfer_simulation(
        saved_snapshot,
        source_account_id=source["id"],
        destination_account_id=destination["id"],
        due_date=due_date,
        requested_minor=plan["monthly_change_minor"],
    )
    existing = await (
        await db.execute(
            "SELECT * FROM finance_payday_actions WHERE plan_id = ? AND due_date = ? "
            "AND source_account_id = ? AND destination_account_id = ? "
            "AND status = 'PENDING' AND deleted_at IS NULL LIMIT 1",
            (
                plan["id"],
                due_date.isoformat(),
                body.source_account_id,
                body.destination_account_id,
            ),
        )
    ).fetchone()
    if existing is not None:
        return _payday_response(dict(existing))
    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_payday_actions
                (id, space_id, plan_id, due_date, source_account_id,
                 destination_account_id, amount_minor, safe_after_transfer_minor,
                 answer_mode, data_through_at, currency, date_tolerance_days,
                 grace_days, status, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 3, 2, 'PENDING', ?, ?, ?, ?)
            """,
            (
                identifier,
                plan["space_id"],
                plan["id"],
                due_date.isoformat(),
                body.source_account_id,
                body.destination_account_id,
                amount_minor,
                safe_after_transfer_minor,
                answer_mode,
                raw_data_through,
                currency,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    row = await (
        await db.execute("SELECT * FROM finance_payday_actions WHERE id = ?", (identifier,))
    ).fetchone()
    return _payday_response(dict(row))


async def list_payday_actions(
    db, *, user: dict, space_id: str, include_resolved: bool = False
) -> list[FinancePaydayActionResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_resolved else "AND status = 'PENDING'"
    rows = await (
        await db.execute(
            f"SELECT * FROM finance_payday_actions WHERE space_id = ? "
            f"AND family_id = ? AND deleted_at IS NULL {clause} "
            "ORDER BY due_date, created_at",
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_payday_response(dict(row)) for row in rows]


async def match_payday_actions(
    db,
    *,
    user: dict,
    space_id: str,
    as_of: date | None = None,
) -> list[FinancePaydayActionResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    current_date = as_of or await _local_today(db, family_id=user["family_id"])
    actions = await (
        await db.execute(
            "SELECT * FROM finance_payday_actions WHERE space_id = ? AND family_id = ? "
            "AND status IN ('PENDING', 'DONE', 'SKIPPED', 'CHANGED') "
            "AND deleted_at IS NULL ORDER BY due_date, id",
            (space_id, user["family_id"]),
        )
    ).fetchall()
    changed: list[FinancePaydayActionResponse] = []
    for raw in actions:
        action = dict(raw)
        due = date.fromisoformat(action["due_date"])
        start = (due - timedelta(days=action["date_tolerance_days"])).isoformat()
        end = (due + timedelta(days=action["date_tolerance_days"])).isoformat()
        matched_amount = (
            action["changed_amount_minor"]
            if action["status"] == "CHANGED" and action["changed_amount_minor"]
            else action["amount_minor"]
        )
        relation = await (
            await db.execute(
                """
                SELECT relation.id
                FROM finance_transaction_relations relation
                JOIN finance_transactions outgoing
                  ON outgoing.id = relation.from_transaction_id
                 AND outgoing.space_id = relation.space_id
                 AND outgoing.family_id = relation.family_id
                 AND outgoing.deleted_at IS NULL
                JOIN finance_transactions incoming
                  ON incoming.id = relation.to_transaction_id
                 AND incoming.space_id = relation.space_id
                 AND incoming.family_id = relation.family_id
                 AND incoming.deleted_at IS NULL
                WHERE relation.space_id = ? AND relation.family_id = ?
                  AND relation.relation_type = 'INTERNAL_TRANSFER'
                  AND relation.status = 'CONFIRMED' AND relation.deleted_at IS NULL
                  AND outgoing.account_id = ? AND incoming.account_id = ?
                  AND outgoing.amount_minor = ? AND incoming.amount_minor = ?
                  AND outgoing.currency = ? AND incoming.currency = ?
                  AND outgoing.canonical_date BETWEEN ? AND ?
                  AND incoming.canonical_date BETWEEN ? AND ?
                ORDER BY relation.created_at LIMIT 1
                """,
                (
                    space_id,
                    user["family_id"],
                    action["source_account_id"],
                    action["destination_account_id"],
                    -matched_amount,
                    matched_amount,
                    action["currency"],
                    action["currency"],
                    start,
                    end,
                    start,
                    end,
                ),
            )
        ).fetchone()
        if relation is not None:
            now = _now()
            async with serialized_create(db):
                await save_history(
                    db,
                    "finance_payday_actions",
                    action["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    "UPDATE finance_payday_actions SET status = 'MATCHED', "
                    "matched_relation_id = ?, matched_at = ?, updated_at = ? WHERE id = ?",
                    (relation["id"], now, now, action["id"]),
                )
            action.update(
                status="MATCHED",
                matched_relation_id=relation["id"],
                matched_at=now,
                updated_at=now,
            )
            changed.append(_payday_response(action))
            continue
        if action["status"] != "PENDING":
            # Manual resolution remains saved, but later bank evidence above is
            # allowed to override it as the stronger confirmation.
            continue
        if current_date <= due + timedelta(days=action["grace_days"]):
            continue
        accounts = await (
            await db.execute(
                "SELECT id, account_type, purpose, include_in_cashflow, "
                "provider_presence_status FROM finance_accounts "
                "WHERE id IN (?, ?) AND space_id = ? AND family_id = ? "
                "AND currency = ? AND deleted_at IS NULL",
                (
                    action["source_account_id"],
                    action["destination_account_id"],
                    space_id,
                    user["family_id"],
                    action["currency"],
                ),
            )
        ).fetchall()
        by_id = {row["id"]: dict(row) for row in accounts}
        source = by_id.get(action["source_account_id"])
        destination = by_id.get(action["destination_account_id"])
        if (
            source is None
            or destination is None
            or source["account_type"] != "CURRENT"
            or source["purpose"] != "OPERATING_CURRENT"
            or not source["include_in_cashflow"]
            or source["provider_presence_status"] != "ACTIVE"
            or destination["purpose"] not in {"SAVINGS", "GOAL"}
            or destination["account_type"] in {"CREDIT_CARD", "INVESTMENT", "CRYPTO"}
            or not destination["include_in_cashflow"]
            or destination["provider_presence_status"] != "ACTIVE"
        ):
            raise FinanceCoachingConflictError(
                "The selected payday accounts are no longer eligible"
            )
        _, saved_snapshot, answer_mode, raw_data_through = (
            await _payday_forecast_evidence(
                db,
                user=user,
                space_id=space_id,
                currency=action["currency"],
                current_date=current_date,
            )
        )
        try:
            revised_amount, safe_after_transfer_minor = _payday_transfer_simulation(
                saved_snapshot,
                source_account_id=action["source_account_id"],
                destination_account_id=action["destination_account_id"],
                due_date=current_date,
                requested_minor=action["amount_minor"],
            )
        except FinanceCoachingConflictError as exc:
            if "cannot safely fund" not in str(exc):
                raise
            revised_amount = 0
            safe_after_transfer_minor = 0
        replacement_id = None
        now = _now()
        async with serialized_create(db):
            if revised_amount > 0:
                replacement_id = str(uuid.uuid4())
                await db.execute(
                    """
                    INSERT INTO finance_payday_actions
                        (id, space_id, plan_id, due_date, source_account_id,
                         destination_account_id, amount_minor,
                         safe_after_transfer_minor, answer_mode, data_through_at,
                         currency, date_tolerance_days, grace_days, status,
                         family_id, created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?, ?, ?)
                    """,
                    (
                        replacement_id,
                        space_id,
                        action["plan_id"],
                        current_date.isoformat(),
                        action["source_account_id"],
                        action["destination_account_id"],
                        revised_amount,
                        safe_after_transfer_minor,
                        answer_mode,
                        raw_data_through,
                        action["currency"],
                        action["date_tolerance_days"],
                        action["grace_days"],
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
            await save_history(
                db,
                "finance_payday_actions",
                action["id"],
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                "UPDATE finance_payday_actions SET status = ?, recalculated_action_id = ?, "
                "resolution_note = ?, updated_at = ? WHERE id = ?",
                (
                    "RECALCULATED" if replacement_id else "EXPIRED",
                    replacement_id,
                    "Recalculated from the latest saved forecast after the grace period.",
                    now,
                    action["id"],
                ),
            )
        action.update(
            status="RECALCULATED" if replacement_id else "EXPIRED",
            recalculated_action_id=replacement_id,
            resolution_note="Recalculated from the latest saved forecast after the grace period.",
            updated_at=now,
        )
        changed.append(_payday_response(action))
    return changed


async def resolve_payday_action(
    db,
    *,
    user: dict,
    action_id: str,
    body: FinancePaydayActionResolve,
) -> FinancePaydayActionResponse:
    row = await _authorised_row(
        db, user=user, table="finance_payday_actions", record_id=action_id
    )
    if row["status"] != "PENDING":
        raise FinanceCoachingConflictError("Only a pending payday action can be resolved")
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_payday_actions",
            action_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_payday_actions SET status = ?, changed_amount_minor = ?, "
            "resolution_note = ?, updated_at = ? WHERE id = ?",
            (body.status, body.changed_amount_minor, body.note, now, action_id),
        )
    row.update(
        status=body.status,
        changed_amount_minor=body.changed_amount_minor,
        resolution_note=body.note,
        updated_at=now,
    )
    return _payday_response(row)


def _habit_response(row: dict) -> FinanceHabitResponse:
    return FinanceHabitResponse(
        id=row["id"],
        space_id=row["space_id"],
        finding_id=row["finding_id"],
        slot=row["slot"],
        name=row["name"],
        trigger=row["trigger_text"],
        filters=json.loads(row["filters_json"]),
        baseline_start=row["baseline_start"],
        baseline_end=row["baseline_end"],
        baseline_minor=row["baseline_minor"],
        start_date=row["start_date"],
        review_date=row["review_date"],
        expected_saving_low_minor=row["expected_saving_low_minor"],
        expected_saving_high_minor=row["expected_saving_high_minor"],
        actual_spend_minor=row["actual_spend_minor"],
        realised_saving_minor=row["realised_saving_minor"],
        displacement_minor=row["displacement_minor"],
        friction_rating=row["friction_rating"],
        fallback=row["fallback"],
        currency=row["currency"],
        status=row["status"],
        review_decision=row["review_decision"],
        evidence_refs=json.loads(row["evidence_json"]),
        updated_at=row["updated_at"],
    )


async def _reviewed_lines(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    start: date,
    end: date,
) -> list[dict]:
    rows = await (
        await db.execute(
            """
            SELECT line.id, purchase.purchased_on,
                   MAX(0, COALESCE(line.line_net_minor, 0)
                       - COALESCE(refund.refunded_minor, 0)) AS net_minor,
                   item.identity_key, assessment.purpose, assessment.beneficiary,
                   assessment.plannedness, assessment.utility,
                   assessment.outcome_state
            FROM finance_purchase_lines line
            JOIN finance_purchase_records purchase
              ON purchase.id = line.purchase_id AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id AND purchase.deleted_at IS NULL
             AND purchase.superseded_by_id IS NULL
            JOIN finance_purchase_line_assessments assessment
              ON assessment.line_id = line.id AND assessment.space_id = line.space_id
             AND assessment.family_id = line.family_id
             AND assessment.review_status = 'CONFIRMED'
             AND assessment.deleted_at IS NULL
            LEFT JOIN finance_normalized_purchase_items item
              ON item.id = assessment.normalized_item_id
             AND item.space_id = line.space_id AND item.family_id = line.family_id
             AND item.deleted_at IS NULL
            LEFT JOIN (
                SELECT line_id, SUM(amount_minor) AS refunded_minor
                FROM finance_line_refunds WHERE deleted_at IS NULL GROUP BY line_id
            ) refund ON refund.line_id = line.id
            WHERE line.space_id = ? AND line.family_id = ? AND purchase.currency = ?
              AND purchase.purchased_on BETWEEN ? AND ?
              AND line.deleted_at IS NULL
            ORDER BY purchase.purchased_on, line.id
            """,
            (
                space_id,
                user["family_id"],
                currency,
                start.isoformat(),
                end.isoformat(),
            ),
        )
    ).fetchall()
    return [dict(row) for row in rows]


def _line_matches_habit(row: dict, filters: dict) -> bool:
    return (
        row["net_minor"] >= filters["minimum_line_minor"]
        and (
            not filters["normalized_items"]
            or row["identity_key"] in filters["normalized_items"]
        )
        and (not filters["purposes"] or row["purpose"] in filters["purposes"])
        and (
            not filters["beneficiaries"]
            or row["beneficiary"] in filters["beneficiaries"]
        )
        and (
            not filters["plannedness"]
            or row["plannedness"] in filters["plannedness"]
        )
        and (not filters["utilities"] or row["utility"] in filters["utilities"])
        and (not filters["outcomes"] or row["outcome_state"] in filters["outcomes"])
    )


def _line_is_related_displacement(row: dict, filters: dict) -> bool:
    if _line_matches_habit(row, filters):
        return False
    if row["net_minor"] < filters["minimum_line_minor"]:
        return False
    if filters["purposes"] and row["purpose"] in filters["purposes"]:
        return True
    if filters["beneficiaries"] and row["beneficiary"] in filters["beneficiaries"]:
        return True
    return bool(
        filters["utilities"]
        and row["utility"] in filters["utilities"]
        and row["plannedness"] in {"impulse", "replacement"}
    )


def _habit_filters(body: FinanceHabitCreate) -> dict[str, object]:
    return {
        "normalized_items": sorted(set(body.normalized_items)),
        "purposes": sorted(set(body.purposes)),
        "beneficiaries": sorted(set(body.beneficiaries)),
        "plannedness": sorted(set(body.plannedness)),
        "utilities": sorted(set(body.utilities)),
        "outcomes": sorted(set(body.outcomes)),
        "minimum_line_minor": body.minimum_line_minor,
    }


async def create_habit(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceHabitCreate,
) -> FinanceHabitResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    settings = await _settings(db, family_id=user["family_id"])
    currency = settings["default_currency"]
    if body.finding_id:
        finding = await (
            await db.execute(
                "SELECT status, currency FROM finance_findings WHERE id = ? AND space_id = ? "
                "AND family_id = ? AND deleted_at IS NULL",
                (body.finding_id, space_id, user["family_id"]),
            )
        ).fetchone()
        if finding is None:
            raise FinanceCoachingNotFoundError("Accepted finding not found")
        if finding["status"] != "ACCEPTED":
            raise FinanceCoachingConflictError(
                "A finding must be accepted before it becomes a habit"
            )
        currency = finding["currency"]
    existing_slot = await (
        await db.execute(
            "SELECT 1 FROM finance_habits WHERE space_id = ? AND family_id = ? "
            "AND slot = ? AND status = 'ACTIVE' AND deleted_at IS NULL LIMIT 1",
            (space_id, user["family_id"], body.slot),
        )
    ).fetchone()
    if existing_slot is not None:
        raise FinanceCoachingConflictError(
            f"The {body.slot.casefold()} habit slot is already active"
        )
    duration_days = max(28, (body.review_date - body.start_date).days + 1)
    baseline_end = body.start_date - timedelta(days=1)
    baseline_start = baseline_end - timedelta(days=duration_days - 1)
    filters = _habit_filters(body)
    baseline_lines = await _reviewed_lines(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        start=baseline_start,
        end=baseline_end,
    )
    qualifying = [row for row in baseline_lines if _line_matches_habit(row, filters)]
    baseline_minor = sum(row["net_minor"] for row in qualifying)
    # Expected savings are claims, not a generic percentage of history.  Use
    # only the already accepted finding's saved estimate; otherwise leave the
    # expectation unknown (zero) until the experiment produces measurements.
    expected_low = 0
    expected_high = 0
    if body.finding_id:
        finding_estimate = await (
            await db.execute(
                "SELECT saving_low_minor, saving_high_minor FROM finance_findings "
                "WHERE id = ? AND space_id = ? AND family_id = ? "
                "AND status = 'ACCEPTED' AND deleted_at IS NULL",
                (body.finding_id, space_id, user["family_id"]),
            )
        ).fetchone()
        if finding_estimate is not None:
            expected_low = finding_estimate["saving_low_minor"]
            expected_high = finding_estimate["saving_high_minor"]
    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_habits
                (id, space_id, finding_id, slot, name, trigger_text, filters_json,
                 baseline_start, baseline_end, baseline_minor, start_date,
                 review_date, expected_saving_low_minor,
                 expected_saving_high_minor, fallback, currency, status,
                 evidence_json, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ACTIVE',
                    ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                body.finding_id,
                body.slot,
                body.name,
                body.trigger,
                _json(filters),
                baseline_start.isoformat(),
                baseline_end.isoformat(),
                baseline_minor,
                body.start_date.isoformat(),
                body.review_date.isoformat(),
                expected_low,
                expected_high,
                body.fallback,
                currency,
                _json([row["id"] for row in qualifying]),
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    row = await (
        await db.execute("SELECT * FROM finance_habits WHERE id = ?", (identifier,))
    ).fetchone()
    return _habit_response(dict(row))


async def list_habits(
    db, *, user: dict, space_id: str, include_inactive: bool = False
) -> list[FinanceHabitResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_inactive else "AND status IN ('ACTIVE', 'PAUSED')"
    rows = await (
        await db.execute(
            f"SELECT * FROM finance_habits WHERE space_id = ? AND family_id = ? "
            f"AND deleted_at IS NULL {clause} ORDER BY slot, created_at",
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_habit_response(dict(row)) for row in rows]


async def measure_habit(
    db,
    *,
    user: dict,
    habit_id: str,
    as_of: date | None = None,
) -> FinanceHabitResponse:
    row = await _authorised_row(db, user=user, table="finance_habits", record_id=habit_id)
    current_date = as_of or await _local_today(db, family_id=user["family_id"])
    start_date = date.fromisoformat(row["start_date"])
    if current_date < start_date:
        return _habit_response(row)
    filters = json.loads(row["filters_json"])
    current_lines = await _reviewed_lines(
        db,
        user=user,
        space_id=row["space_id"],
        currency=row["currency"],
        start=start_date,
        end=current_date,
    )
    qualifying = [item for item in current_lines if _line_matches_habit(item, filters)]
    actual_spend = sum(item["net_minor"] for item in qualifying)
    baseline_days = (
        date.fromisoformat(row["baseline_end"])
        - date.fromisoformat(row["baseline_start"])
    ).days + 1
    observed_days = (current_date - start_date).days + 1
    baseline_expected = row["baseline_minor"] * observed_days // baseline_days

    baseline_lines = await _reviewed_lines(
        db,
        user=user,
        space_id=row["space_id"],
        currency=row["currency"],
        start=date.fromisoformat(row["baseline_start"]),
        end=date.fromisoformat(row["baseline_end"]),
    )
    baseline_related = sum(
        item["net_minor"]
        for item in baseline_lines
        if _line_is_related_displacement(item, filters)
    )
    current_related = sum(
        item["net_minor"]
        for item in current_lines
        if _line_is_related_displacement(item, filters)
    )
    expected_related = baseline_related * observed_days // baseline_days
    displacement = max(0, current_related - expected_related)
    realised = max(0, baseline_expected - actual_spend - displacement)
    evidence = [item["id"] for item in qualifying]
    now = _now()
    existing_observation = await (
        await db.execute(
            "SELECT id FROM finance_habit_observations WHERE habit_id = ? "
            "AND observed_through = ? AND deleted_at IS NULL",
            (habit_id, current_date.isoformat()),
        )
    ).fetchone()
    async with serialized_create(db):
        if existing_observation is None:
            await db.execute(
                """
                INSERT INTO finance_habit_observations
                    (id, space_id, habit_id, observed_through,
                     qualifying_spend_minor, baseline_expected_minor,
                     realised_saving_minor, displacement_minor, evidence_json,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    row["space_id"],
                    habit_id,
                    current_date.isoformat(),
                    actual_spend,
                    baseline_expected,
                    realised,
                    displacement,
                    _json(evidence),
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
        else:
            await save_history(
                db,
                "finance_habit_observations",
                existing_observation["id"],
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                "UPDATE finance_habit_observations SET qualifying_spend_minor = ?, "
                "baseline_expected_minor = ?, realised_saving_minor = ?, "
                "displacement_minor = ?, evidence_json = ?, updated_at = ? WHERE id = ?",
                (
                    actual_spend,
                    baseline_expected,
                    realised,
                    displacement,
                    _json(evidence),
                    now,
                    existing_observation["id"],
                ),
            )
        await save_history(
            db,
            "finance_habits",
            habit_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_habits SET actual_spend_minor = ?, realised_saving_minor = ?, "
            "displacement_minor = ?, evidence_json = ?, updated_at = ? WHERE id = ?",
            (actual_spend, realised, displacement, _json(evidence), now, habit_id),
        )
    row.update(
        actual_spend_minor=actual_spend,
        realised_saving_minor=realised,
        displacement_minor=displacement,
        evidence_json=_json(evidence),
        updated_at=now,
    )
    return _habit_response(row)


async def review_habit(
    db,
    *,
    user: dict,
    habit_id: str,
    body: FinanceHabitReview,
) -> FinanceHabitResponse:
    measured = await measure_habit(db, user=user, habit_id=habit_id)
    row = await _authorised_row(db, user=user, table="finance_habits", record_id=habit_id)
    status = {"KEEP": "ACTIVE", "ADJUST": "PAUSED", "STOP": "ABANDONED"}[
        body.decision
    ]
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_habits",
            habit_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_habits SET status = ?, review_decision = ?, "
            "friction_rating = ?, review_note = ?, updated_at = ? WHERE id = ?",
            (
                status,
                body.decision,
                body.friction_rating,
                body.note,
                now,
                habit_id,
            ),
        )
    row.update(
        status=status,
        review_decision=body.decision,
        friction_rating=body.friction_rating,
        review_note=body.note,
        actual_spend_minor=measured.actual_spend_minor,
        realised_saving_minor=measured.realised_saving_minor,
        displacement_minor=measured.displacement_minor,
        evidence_json=_json(measured.evidence_refs),
        updated_at=now,
    )
    return _habit_response(row)


def _proposal_response(row: dict) -> FinancePurchaseProposalResponse:
    return FinancePurchaseProposalResponse(
        id=row["id"],
        space_id=row["space_id"],
        source_kind=row["source_kind"],
        name=row["name"],
        amount_low_minor=row["amount_low_minor"],
        amount_high_minor=row["amount_high_minor"],
        desired_date=row["desired_date"],
        recurrence=row["recurrence"],
        payment_account_id=row["payment_account_id"],
        purpose=row["purpose"],
        beneficiary=row["beneficiary"],
        lines=json.loads(row["lines_json"]),
        cheaper_alternative_minor=row["cheaper_alternative_minor"],
        later_date=row["later_date"],
        uncertainties=json.loads(row["uncertainties_json"]),
        currency=row["currency"],
        status=row["status"],
        approved_scenario=row["approved_scenario"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def _evaluation_response(row: dict) -> FinancePurchaseEvaluationResponse:
    return FinancePurchaseEvaluationResponse(
        id=row["id"],
        proposal_id=row["proposal_id"],
        forecast_id=row["forecast_id"],
        verdict=row["verdict"],
        rationale=row["rationale"],
        scenarios=json.loads(row["scenarios_json"]),
        historical_context=json.loads(row["historical_context_json"]),
        evidence_refs=json.loads(row["evidence_json"]),
        data_through_at=row["data_through_at"],
        created_at=row["created_at"],
    )


async def create_purchase_proposal(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinancePurchaseProposalCreate,
) -> FinancePurchaseProposalResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    account = await (
        await db.execute(
            "SELECT account_type, purpose, include_in_cashflow FROM finance_accounts "
            "WHERE id = ? AND space_id = ? "
            "AND family_id = ? AND currency = ? AND deleted_at IS NULL",
            (body.payment_account_id, space_id, user["family_id"], body.currency),
        )
    ).fetchone()
    if account is None:
        raise FinanceCoachingNotFoundError("Proposal payment account not found")
    if (
        account["account_type"] not in {"CURRENT", "CASH"}
        or account["purpose"] != "OPERATING_CURRENT"
        or not account["include_in_cashflow"]
    ):
        raise FinanceCoachingConflictError(
            "Proposal payment account must be an included current or cash account"
        )
    line_payload = [line.model_dump(mode="json") for line in body.lines]
    if body.unitemised_remainder_minor:
        line_payload.append(
            {
                "name": "Unitemised remainder",
                "amount_minor": body.unitemised_remainder_minor,
                "normalized_item": None,
                "purpose": None,
                "beneficiary": None,
                "replacement_for": None,
                "unitemised": True,
            }
        )
    source_metadata_json = _json(body.source_metadata)
    lines_json = _json(line_payload)
    uncertainties_json = _json(body.uncertainties)

    def same_reviewed_input(row) -> bool:
        return all(
            (
                row["source_kind"] == body.source_kind,
                row["source_text"] == body.source_text,
                row["source_url"] == body.source_url,
                row["source_metadata_json"] == source_metadata_json,
                row["name"] == body.name,
                row["amount_low_minor"] == body.amount_low_minor,
                row["amount_high_minor"] == body.amount_high_minor,
                row["desired_date"] == body.desired_date.isoformat(),
                row["recurrence"] == body.recurrence,
                row["payment_account_id"] == body.payment_account_id,
                row["purpose"] == body.purpose,
                row["beneficiary"] == body.beneficiary,
                row["lines_json"] == lines_json,
                row["cheaper_alternative_minor"] == body.cheaper_alternative_minor,
                row["later_date"]
                == (body.later_date.isoformat() if body.later_date else None),
                row["uncertainties_json"] == uncertainties_json,
                row["currency"] == body.currency,
            )
        )

    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        candidates = await (
            await db.execute(
                "SELECT * FROM finance_purchase_proposals WHERE space_id = ? "
                "AND family_id = ? AND created_by = ? AND deleted_at IS NULL "
                "ORDER BY created_at DESC",
                (space_id, user["family_id"], user["id"]),
            )
        ).fetchall()
        replay = next((row for row in candidates if same_reviewed_input(row)), None)
        if replay is not None:
            return _proposal_response(dict(replay))
        await db.execute(
            """
            INSERT INTO finance_purchase_proposals
                (id, space_id, source_kind, source_text, source_url,
                 source_metadata_json, name, amount_low_minor, amount_high_minor,
                 desired_date, recurrence, payment_account_id, purpose, beneficiary,
                 lines_json, cheaper_alternative_minor, later_date,
                 uncertainties_json, currency, status, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    'CONFIRMED', ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                body.source_kind,
                body.source_text,
                body.source_url,
                source_metadata_json,
                body.name,
                body.amount_low_minor,
                body.amount_high_minor,
                body.desired_date.isoformat(),
                body.recurrence,
                body.payment_account_id,
                body.purpose,
                body.beneficiary,
                lines_json,
                body.cheaper_alternative_minor,
                body.later_date.isoformat() if body.later_date else None,
                uncertainties_json,
                body.currency,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    row = await (
        await db.execute("SELECT * FROM finance_purchase_proposals WHERE id = ?", (identifier,))
    ).fetchone()
    return _proposal_response(dict(row))


async def list_purchase_proposals(
    db, *, user: dict, space_id: str, include_resolved: bool = False
) -> list[FinancePurchaseProposalResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_resolved else "AND status IN ('CONFIRMED', 'EVALUATED')"
    rows = await (
        await db.execute(
            f"SELECT * FROM finance_purchase_proposals WHERE space_id = ? "
            f"AND family_id = ? AND deleted_at IS NULL {clause} "
            "ORDER BY desired_date, created_at",
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_proposal_response(dict(row)) for row in rows]


def _forecast_from_row(row: dict) -> ForecastSnapshot:
    try:
        persisted = json.loads(row["canonical_input_json"])
        payload = persisted["engine_input"]
        currency = payload["currency"]
        return ForecastSnapshot(
            start_date=date.fromisoformat(payload["start_date"]),
            end_date=date.fromisoformat(payload["end_date"]),
            timezone=payload["timezone"],
            currency=currency,
            accounts=tuple(
                ForecastAccount(
                    id=item["id"],
                    opening_balance=Money(item["opening_balance_minor"], currency),
                    floor_minor=item["floor_minor"],
                    include_in_household=item["include_in_household"],
                )
                for item in payload["accounts"]
            ),
            events=tuple(
                ForecastEvent(
                    id=item["id"],
                    day=date.fromisoformat(item["day"]),
                    account_id=item["account_id"],
                    amount=Money(item["amount_minor"], currency),
                    kind=item["kind"],
                    destination_account_id=item["destination_account_id"],
                    sequence=item["sequence"],
                )
                for item in payload["events"]
            ),
            household_buffer_minor=payload["household_buffer_minor"],
            engine_version=payload["engine_version"],
            non_monotone_rule_ids=tuple(payload["non_monotone_rule_ids"]),
        )
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise FinanceCoachingConflictError("Saved forecast input is not usable") from exc


def _proposal_dates(proposal: dict, snapshot: ForecastSnapshot, day: date) -> list[date]:
    if not snapshot.start_date <= day <= snapshot.end_date:
        return []
    dates = [day]
    if proposal["recurrence"] == "ONE_OFF":
        return dates
    offset = 1
    while True:
        candidate = (
            _add_months(day, offset)
            if proposal["recurrence"] == "MONTHLY"
            else _add_months(day, offset * 12)
        )
        if candidate > snapshot.end_date:
            break
        dates.append(candidate)
        offset += 1
    return dates


async def _active_plans_for_currency(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
) -> list[dict]:
    return [
        dict(row)
        for row in await (
            await db.execute(
                "SELECT * FROM finance_plans WHERE space_id = ? AND family_id = ? "
                "AND currency = ? AND status = 'ACTIVE' AND deleted_at IS NULL "
                "ORDER BY id",
                (space_id, user["family_id"], currency),
            )
        ).fetchall()
    ]


def _active_plan_state(plans: list[dict]) -> tuple[list[str], str]:
    plan_ids = sorted(str(plan["id"]) for plan in plans)
    state = [
        {
            "id": str(plan["id"]),
            "planned_monthly_minor": _stored_plan_monthly_saving(plan),
            "updated_at": plan.get("updated_at"),
        }
        for plan in sorted(plans, key=lambda item: str(item["id"]))
    ]
    return plan_ids, _digest(state)


def _purchase_scenario(
    proposal: dict,
    snapshot: ForecastSnapshot,
    *,
    scenario: str,
    day: date | None,
    amount_minor: int,
    active_planned_monthly_minor: int,
    freshness: dict[str, object],
) -> dict[str, object]:
    if scenario == "DO_NOTHING":
        result = run_forecast(snapshot)
        dates: list[date] = []
        used_nearest_day = False
    else:
        assert day is not None
        effective_day = min(max(day, snapshot.start_date), snapshot.end_date)
        used_nearest_day = effective_day != day
        dates = _proposal_dates(proposal, snapshot, effective_day)
        injected = tuple(
            ForecastEvent(
                id=f"proposal:{proposal['id']}:{scenario}:{event_day.isoformat()}",
                day=event_day,
                account_id=proposal["payment_account_id"],
                amount=Money(-amount_minor, snapshot.currency),
                kind="planned",
                sequence=900,
            )
            for event_day in dates
        )
        result = run_forecast(
            ForecastSnapshot(
                start_date=snapshot.start_date,
                end_date=snapshot.end_date,
                timezone=snapshot.timezone,
                currency=snapshot.currency,
                accounts=snapshot.accounts,
                events=(*snapshot.events, *injected),
                household_buffer_minor=snapshot.household_buffer_minor,
                engine_version=snapshot.engine_version,
                non_monotone_rule_ids=snapshot.non_monotone_rule_ids,
            )
        )
    limiting = asdict(result.limiting_event) if result.limiting_event else None
    if limiting and isinstance(limiting.get("day"), date):
        limiting["day"] = limiting["day"].isoformat()
    delay_months = (
        _ceil_div(amount_minor, active_planned_monthly_minor)
        if amount_minor and active_planned_monthly_minor
        else None
    )
    commitment_failures = []
    if limiting and str(limiting.get("event_id") or "").startswith("commitment:"):
        commitment_failures.append(limiting["event_id"])
    estimated_allowance = int(freshness["unobserved_allowance_minor"])
    saved_minimum = result.minimum_household_free_minor
    estimated_minimum = saved_minimum - estimated_allowance
    passed = result.passed and estimated_minimum >= 0
    assumptions: list[str] = []
    if used_nearest_day:
        assumptions.append(
            f"The account outlook ends on {snapshot.end_date.isoformat()}, so the nearest "
            "saved day is used for this estimate."
        )
    if freshness["mode"] == "ESTIMATED_RANGE":
        if freshness["data_through_date"]:
            assumptions.append(
                f"Uses spending through {freshness['data_through_date']} and allows "
                f"{_money_text(estimated_allowance, snapshot.currency)} for day-to-day spending "
                "after that."
            )
        else:
            assumptions.append(
                "Uses saved balances and bills with a small allowance for day-to-day spending."
            )
    elif freshness["mode"] == "UNKNOWN_FRESHNESS":
        assumptions.append(
            "Uses saved balances and bills with a small allowance for day-to-day spending."
        )
    return {
        "scenario": scenario,
        "status": "FEASIBLE" if passed else "INFEASIBLE",
        "freshness_mode": freshness["mode"],
        "data_through_date": freshness["data_through_date"],
        "purchase_date": day.isoformat() if day else None,
        "amount_minor": amount_minor,
        "minimum_household_free_minor": estimated_minimum,
        "saved_minimum_household_free_minor": saved_minimum,
        "estimated_household_free_range_minor": [estimated_minimum, saved_minimum],
        "minimum_household_free_date": result.minimum_household_free_date.isoformat(),
        "passed": passed,
        "limiting_event": limiting,
        "commitment_funding_failures": commitment_failures,
        "category_budget_impact_minor": amount_minor,
        "estimated_goal_delay_months": delay_months,
        "assumptions": assumptions,
    }


async def _forecast_freshness(
    db,
    *,
    user: dict,
    proposal: dict,
    forecast_row: dict,
    snapshot: ForecastSnapshot,
) -> dict[str, object]:
    raw = forecast_row.get("data_through_at")
    if not raw:
        baseline = run_forecast(snapshot)
        return {
            "mode": "ESTIMATED_RANGE",
            "data_through_date": None,
            "age_days": None,
            "unobserved_allowance_minor": max(
                0, baseline.minimum_household_free_minor // 10
            ),
        }
    try:
        through = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
        if through.tzinfo is None:
            through = through.replace(tzinfo=timezone.utc)
        through_day = through.astimezone(household_zone(snapshot.timezone)).date()
    except ValueError:
        through_day = date.fromisoformat(str(raw)[:10])
    local_today = datetime.now(timezone.utc).astimezone(
        household_zone(snapshot.timezone)
    ).date()
    age_days = max(0, (local_today - through_day).days)
    if age_days <= 1:
        return {
            "mode": "CURRENT_EXACT",
            "data_through_date": through_day.isoformat(),
            "age_days": age_days,
            "unobserved_allowance_minor": 0,
        }
    history_start = through_day - timedelta(days=27)
    spend_row = await (
        await db.execute(
            """
            SELECT COALESCE(SUM(-tx.amount_minor), 0)
            FROM finance_transactions tx
            WHERE tx.space_id = ? AND tx.family_id = ? AND tx.currency = ?
              AND tx.state = 'POSTED' AND tx.amount_minor < 0
              AND tx.canonical_date BETWEEN ? AND ? AND tx.deleted_at IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM finance_transaction_relations relation
                  WHERE relation.space_id = tx.space_id
                    AND relation.family_id = tx.family_id
                    AND relation.status = 'CONFIRMED'
                    AND relation.relation_type IN (
                        'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                    )
                    AND relation.deleted_at IS NULL
                    AND relation.from_transaction_id = tx.id
              )
              AND NOT EXISTS (
                  SELECT 1 FROM finance_transaction_relations relation
                  WHERE relation.space_id = tx.space_id
                    AND relation.family_id = tx.family_id
                    AND relation.status = 'CONFIRMED'
                    AND relation.relation_type IN (
                        'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                    )
                    AND relation.deleted_at IS NULL
                    AND relation.to_transaction_id = tx.id
              )
            """,
            (
                proposal["space_id"],
                user["family_id"],
                proposal["currency"],
                history_start.isoformat(),
                through_day.isoformat(),
            ),
        )
    ).fetchone()
    daily_allowance = _ceil_div(max(0, spend_row[0]), 28)
    return {
        "mode": "ESTIMATED_RANGE",
        "data_through_date": through_day.isoformat(),
        "age_days": age_days,
        "unobserved_allowance_minor": daily_allowance * age_days,
    }


async def _proposal_history(db, *, user: dict, proposal: dict) -> tuple[dict, list[str]]:
    lines = json.loads(proposal["lines_json"])
    identities = {
        str(item.get("normalized_item") or "").strip().casefold()
        for item in lines
        if item.get("normalized_item")
    }
    fallback_names = {
        " ".join(str(item.get("name") or "").casefold().split())
        for item in lines
        if len(" ".join(str(item.get("name") or "").casefold().split())) >= 12
    }
    if not identities and not fallback_names:
        name = " ".join(proposal["name"].casefold().split())
        if len(name) >= 12:
            fallback_names = {name}
    rows = await (
        await db.execute(
            """
            SELECT line.id, line.raw_description, item.identity_key,
                   item.display_name, assessment.outcome_state,
                   assessment.utility, assessment.plannedness,
                   purchase.purchased_on, line.line_net_minor
            FROM finance_purchase_lines line
            JOIN finance_purchase_records purchase
              ON purchase.id = line.purchase_id AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id AND purchase.deleted_at IS NULL
            JOIN finance_purchase_line_assessments assessment
              ON assessment.line_id = line.id AND assessment.space_id = line.space_id
             AND assessment.family_id = line.family_id
             AND assessment.review_status = 'CONFIRMED'
             AND assessment.deleted_at IS NULL
            LEFT JOIN finance_normalized_purchase_items item
              ON item.id = assessment.normalized_item_id
             AND item.space_id = line.space_id AND item.family_id = line.family_id
             AND item.deleted_at IS NULL
            WHERE line.space_id = ? AND line.family_id = ? AND line.deleted_at IS NULL
            ORDER BY purchase.purchased_on DESC, line.id DESC LIMIT 500
            """,
            (proposal["space_id"], user["family_id"]),
        )
    ).fetchall()
    matching = []
    used_fallback = False
    for raw in rows:
        row = dict(raw)
        identity = str(row["identity_key"] or "").strip().casefold()
        if identity and identity in identities:
            matching.append(row)
            continue
        descriptions = {
            " ".join(str(row[key] or "").casefold().split())
            for key in ("raw_description", "display_name")
        }
        if fallback_names.intersection(descriptions):
            matching.append(row)
            used_fallback = True
    preferences = await (
        await db.execute(
            "SELECT preference_key, statement, value_kind FROM finance_preferences "
            "WHERE space_id = ? AND family_id = ? AND status = 'CONFIRMED' "
            "AND deleted_at IS NULL ORDER BY preference_key",
            (proposal["space_id"], user["family_id"]),
        )
    ).fetchall()
    relevant_preferences = [
        dict(row)
        for row in preferences
        if any(
            token == " ".join(str(row["preference_key"] or "").casefold().split())
            or token == " ".join(str(row["statement"] or "").casefold().split())
            for token in identities | fallback_names
        )
    ]
    evidence = [row["id"] for row in matching]
    return (
        {
            "matching_line_count": len(matching),
            "valued_count": sum(row["outcome_state"] == "valued" for row in matching),
            "regretted_count": sum(
                row["outcome_state"] in {"regretted", "unused"} for row in matching
            ),
            "returned_count": sum(row["outcome_state"] == "returned" for row in matching),
            "replacement_count": sum(
                row["plannedness"] == "replacement" for row in matching
            ),
            "match_mode": (
                "NARROW_DESCRIPTION" if used_fallback else "EXACT_IDENTITY"
                if matching else "NONE"
            ),
            "match_uncertainty": (
                "Description fallback is an exact full-phrase match, not saved item identity."
                if used_fallback else None
            ),
            "relevant_preferences": relevant_preferences,
        },
        evidence,
    )


async def evaluate_purchase_proposal(
    db,
    *,
    user: dict,
    proposal_id: str,
    body: FinancePurchaseEvaluationRequest,
) -> FinancePurchaseEvaluationResponse:
    proposal = await _authorised_row(
        db, user=user, table="finance_purchase_proposals", record_id=proposal_id
    )
    if proposal["status"] not in {"CONFIRMED", "EVALUATED"}:
        raise FinanceCoachingConflictError("This proposal cannot be evaluated")
    forecast_row = await (
        await db.execute(
            "SELECT * FROM finance_forecast_snapshots WHERE id = ? AND space_id = ? "
            "AND family_id = ? AND deleted_at IS NULL",
            (body.forecast_id, proposal["space_id"], user["family_id"]),
        )
    ).fetchone()
    if forecast_row is None:
        raise FinanceCoachingNotFoundError("Saved forecast not found")
    snapshot = _forecast_from_row(dict(forecast_row))
    if proposal["currency"] != snapshot.currency:
        raise FinanceCoachingConflictError("Proposal currency does not match the forecast")
    active_plans = await _active_plans_for_currency(
        db,
        user=user,
        space_id=proposal["space_id"],
        currency=proposal["currency"],
    )
    active_plan_ids, active_plan_digest = _active_plan_state(active_plans)
    active_planned_monthly = sum(
        _stored_plan_monthly_saving(plan) for plan in active_plans
    )
    freshness = await _forecast_freshness(
        db,
        user=user,
        proposal=proposal,
        forecast_row=dict(forecast_row),
        snapshot=snapshot,
    )
    desired = date.fromisoformat(proposal["desired_date"])
    scenarios = [
        _purchase_scenario(
            proposal,
            snapshot,
            scenario="BUY_NOW",
            day=desired,
            amount_minor=proposal["amount_high_minor"],
            active_planned_monthly_minor=active_planned_monthly,
            freshness=freshness,
        ),
        _purchase_scenario(
            proposal,
            snapshot,
            scenario="DO_NOTHING",
            day=None,
            amount_minor=0,
            active_planned_monthly_minor=active_planned_monthly,
            freshness=freshness,
        ),
    ]
    if proposal["later_date"]:
        scenarios.append(
            _purchase_scenario(
                proposal,
                snapshot,
                scenario="BUY_LATER",
                day=date.fromisoformat(proposal["later_date"]),
                amount_minor=proposal["amount_high_minor"],
                active_planned_monthly_minor=active_planned_monthly,
                freshness=freshness,
            )
        )
    if proposal["cheaper_alternative_minor"] is not None:
        scenarios.append(
            _purchase_scenario(
                proposal,
                snapshot,
                scenario="CHEAPER",
                day=desired,
                amount_minor=proposal["cheaper_alternative_minor"],
                active_planned_monthly_minor=active_planned_monthly,
                freshness=freshness,
            )
        )
    by_name = {item["scenario"]: item for item in scenarios}
    buy_now_passed = bool(by_name["BUY_NOW"].get("passed"))
    later_passed = bool(by_name.get("BUY_LATER", {}).get("passed"))
    cheaper_passed = bool(by_name.get("CHEAPER", {}).get("passed"))
    historical, evidence = await _proposal_history(db, user=user, proposal=proposal)
    historical["active_plan_ids"] = active_plan_ids
    historical["active_plan_digest"] = active_plan_digest
    historical["active_planned_monthly_minor"] = active_planned_monthly
    # Preserve the original field for clients and saved evaluations that only
    # understand the singular-plan contract.
    historical["active_plan_id"] = (
        active_plan_ids[0] if len(active_plan_ids) == 1 else None
    )
    historical["confidence_bps"] = (
        8000
        if freshness["mode"] == "ESTIMATED_RANGE" and freshness["data_through_date"]
        else 7000
        if freshness["mode"] in {"ESTIMATED_RANGE", "UNKNOWN_FRESHNESS"}
        else 9500
    )
    duplicate_risk = historical["replacement_count"] or historical["regretted_count"]
    if buy_now_passed and not duplicate_risk:
        verdict = "YES"
        remaining = int(by_name["BUY_NOW"].get("minimum_household_free_minor") or 0)
        rationale = (
            f"Yes. Buying it now still leaves about {_money_text(remaining, snapshot.currency)} "
            "at the lowest point after saved bills and plans."
        )
    elif buy_now_passed:
        verdict = "YES_IF"
        rationale = (
            "Yes, if this is genuinely different from the similar item that was replaced "
            "or regretted before. The money fits the current plan."
        )
    elif later_passed:
        verdict = "NOT_YET"
        rationale = (
            f"Not yet. Buying on {proposal['later_date']} fits; buying now uses money needed "
            "for saved bills or plans."
        )
    elif cheaper_passed:
        verdict = "YES_IF"
        rationale = (
            f"Yes, at {_money_text(int(proposal['cheaper_alternative_minor']), snapshot.currency)}. "
            "The current price uses money needed for saved bills or plans."
        )
    else:
        verdict = "NO_UNDER_CURRENT_PLAN"
        rationale = (
            "I don't recommend buying it under the current plan. Buying now, later, or at the "
            "cheaper saved price still uses money needed for bills or planned saving."
        )
    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_purchase_evaluations
                (id, space_id, proposal_id, forecast_id, verdict, rationale,
                 scenarios_json, historical_context_json, evidence_json,
                 data_through_at, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                proposal["space_id"],
                proposal["id"],
                forecast_row["id"],
                verdict,
                rationale,
                _json(scenarios),
                _json(historical),
                _json(evidence),
                forecast_row["data_through_at"],
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        await save_history(
            db,
            "finance_purchase_proposals",
            proposal["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_purchase_proposals SET status = 'EVALUATED', updated_at = ? "
            "WHERE id = ?",
            (now, proposal["id"]),
        )
    row = await (
        await db.execute(
            "SELECT * FROM finance_purchase_evaluations WHERE id = ?", (identifier,)
        )
    ).fetchone()
    return _evaluation_response(dict(row))


async def approve_purchase_proposal(
    db,
    *,
    user: dict,
    proposal_id: str,
    body: FinancePurchaseApprove,
) -> FinancePurchaseProposalResponse:
    proposal = await _authorised_row(
        db, user=user, table="finance_purchase_proposals", record_id=proposal_id
    )
    if proposal["status"] != "EVALUATED":
        raise FinanceCoachingConflictError("Evaluate the proposal before approval")
    evaluation = await _authorised_row(
        db,
        user=user,
        table="finance_purchase_evaluations",
        record_id=body.evaluation_id,
    )
    if evaluation["proposal_id"] != proposal_id:
        raise FinanceCoachingNotFoundError("Proposal evaluation not found")
    latest_evaluation = await (
        await db.execute(
            "SELECT id FROM finance_purchase_evaluations WHERE proposal_id = ? "
            "AND family_id = ? AND deleted_at IS NULL "
            "ORDER BY created_at DESC, id DESC LIMIT 1",
            (proposal_id, user["family_id"]),
        )
    ).fetchone()
    if latest_evaluation is None or latest_evaluation["id"] != evaluation["id"]:
        raise FinanceCoachingConflictError(
            "This evaluation was superseded; approve the latest saved evaluation"
        )
    current_plans = await _active_plans_for_currency(
        db,
        user=user,
        space_id=proposal["space_id"],
        currency=proposal["currency"],
    )
    current_plan_ids, current_plan_digest = _active_plan_state(current_plans)
    evaluated_context = json.loads(evaluation["historical_context_json"])
    if "active_plan_ids" in evaluated_context:
        evaluated_plan_ids = sorted(
            str(plan_id) for plan_id in evaluated_context["active_plan_ids"]
        )
        plan_state_changed = (
            evaluated_plan_ids != current_plan_ids
            or evaluated_context.get("active_plan_digest") != current_plan_digest
        )
    else:
        # Evaluations saved before simultaneous plans used a nullable scalar.
        legacy_current_id = current_plan_ids[0] if len(current_plan_ids) == 1 else None
        plan_state_changed = (
            evaluated_context.get("active_plan_id") != legacy_current_id
        )
    if plan_state_changed:
        raise FinanceCoachingConflictError(
            "The active plan changed; evaluate this purchase again before approval"
        )
    scenario = next(
        (
            item
            for item in json.loads(evaluation["scenarios_json"])
            if item["scenario"] == body.scenario
        ),
        None,
    )
    if scenario is None or (body.scenario != "DO_NOTHING" and not scenario.get("passed")):
        raise FinanceCoachingConflictError("The selected scenario is not approvable")
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_purchase_proposals",
            proposal_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_purchase_proposals SET status = 'APPROVED', "
            "approved_evaluation_id = ?, approved_scenario = ?, updated_at = ? "
            "WHERE id = ?",
            (body.evaluation_id, body.scenario, now, proposal_id),
        )
    proposal.update(
        status="APPROVED",
        approved_evaluation_id=body.evaluation_id,
        approved_scenario=body.scenario,
        updated_at=now,
    )
    return _proposal_response(proposal)


def _report_response(row: dict) -> FinanceCoachingReportResponse:
    summary = json.loads(row["summary_json"])
    return FinanceCoachingReportResponse(
        id=row["id"],
        space_id=row["space_id"],
        member_user_id=row["member_user_id"],
        report_kind=row["report_kind"],
        local_date=row["local_date"],
        household_timezone=row["household_timezone"],
        locale=row["locale"],
        currency=summary["current"]["currency"],
        input_digest=row["input_digest"],
        data_through_at=row["data_through_at"],
        itemised_coverage_bps=row["itemised_coverage_bps"],
        trajectory_status=row["trajectory_status"],
        expected_durable_saving_minor=row["expected_durable_saving_minor"],
        primary_action=(
            json.loads(row["primary_action_json"])
            if row["primary_action_json"]
            else None
        ),
        optional_observation=(
            json.loads(row["optional_observation_json"])
            if row["optional_observation_json"]
            else None
        ),
        summary=summary,
        explanation=row["explanation"],
        created_at=row["created_at"],
    )


async def set_report_preference(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceReportPreferenceUpdate,
) -> FinanceReportPreferenceResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    if body.default_spend_account_id:
        account = await (
            await db.execute(
                "SELECT account_type, purpose, include_in_cashflow "
                "FROM finance_accounts WHERE id = ? AND space_id = ? "
                "AND family_id = ? AND deleted_at IS NULL",
                (
                    body.default_spend_account_id,
                    space_id,
                    user["family_id"],
                ),
            )
        ).fetchone()
        if (
            account is None
            or account["account_type"] not in {"CURRENT", "CASH"}
            or account["purpose"] != "OPERATING_CURRENT"
            or not account["include_in_cashflow"]
        ):
            raise FinanceCoachingConflictError(
                "The default spending account must be an included current or cash account"
            )
    if body.writing_mode == "CLOUD_WITH_CONSENT":
        provider, model = finance_ai_identity()
        consent = None
        if provider != "off":
            consent = await (
                await db.execute(
                    "SELECT id FROM finance_ai_consents WHERE user_id = ? "
                    "AND space_id = ? AND family_id = ? AND consent_version = ? "
                    "AND provider = ? AND model = ? AND store_response = 0 "
                    "AND background_processing = 0 AND revoked_at IS NULL "
                    "AND deleted_at IS NULL ORDER BY accepted_at DESC, id DESC LIMIT 1",
                    (
                        user["id"],
                        space_id,
                        user["family_id"],
                        finance_ai_consent_version(),
                        provider,
                        model,
                    ),
                )
            ).fetchone()
        if consent is None:
            raise FinanceCoachingConflictError(
                "Cloud writing requires current Finance AI consent for this space"
            )
    existing = await (
        await db.execute(
            "SELECT * FROM finance_report_preferences WHERE member_user_id = ? "
            "AND space_id = ? AND family_id = ? AND deleted_at IS NULL",
            (user["id"], space_id, user["family_id"]),
        )
    ).fetchone()
    now = _now()
    daily_time = body.daily_time.replace(microsecond=0).isoformat()
    quiet_start = (
        body.quiet_hours_start.replace(microsecond=0).isoformat()
        if body.quiet_hours_start
        else None
    )
    quiet_end = (
        body.quiet_hours_end.replace(microsecond=0).isoformat()
        if body.quiet_hours_end
        else None
    )
    async with serialized_create(db):
        if existing is None:
            identifier = str(uuid.uuid4())
            await db.execute(
                """
                INSERT INTO finance_report_preferences
                    (id, space_id, member_user_id, locale, daily_time, enabled,
                     notification_channel, notification_mode,
                     show_more_by_default, quiet_hours_start, quiet_hours_end,
                     underfunded_commitment_threshold_minor,
                     goal_movement_threshold_minor, missed_payday_alerts,
                     selected_return_deadline_alerts, tone,
                     default_spend_account_id, extra_cash_buffer_minor,
                     writing_mode, allow_dated_estimates,
                     ordinary_purchase_alerts, group_related_alerts,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        0, 1, ?, ?, ?, ?)
                """,
                (
                    identifier,
                    space_id,
                    user["id"],
                    body.locale,
                    daily_time,
                    int(body.enabled),
                    body.notification_channel,
                    body.notification_mode,
                    int(body.show_more_by_default),
                    quiet_start,
                    quiet_end,
                    body.underfunded_commitment_threshold_minor,
                    body.goal_movement_threshold_minor,
                    int(body.missed_payday_alerts),
                    int(body.selected_return_deadline_alerts),
                    body.tone,
                    body.default_spend_account_id,
                    body.extra_cash_buffer_minor,
                    body.writing_mode,
                    int(body.allow_dated_estimates),
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
        else:
            identifier = existing["id"]
            await save_history(
                db,
                "finance_report_preferences",
                identifier,
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                "UPDATE finance_report_preferences SET locale = ?, daily_time = ?, "
                "enabled = ?, notification_channel = ?, notification_mode = ?, "
                "show_more_by_default = ?, quiet_hours_start = ?, "
                "quiet_hours_end = ?, underfunded_commitment_threshold_minor = ?, "
                "goal_movement_threshold_minor = ?, missed_payday_alerts = ?, "
                "selected_return_deadline_alerts = ?, tone = ?, "
                "default_spend_account_id = ?, extra_cash_buffer_minor = ?, "
                "writing_mode = ?, allow_dated_estimates = ?, "
                "ordinary_purchase_alerts = 0, group_related_alerts = 1, "
                "updated_at = ? WHERE id = ?",
                (
                    body.locale,
                    daily_time,
                    int(body.enabled),
                    body.notification_channel,
                    body.notification_mode,
                    int(body.show_more_by_default),
                    quiet_start,
                    quiet_end,
                    body.underfunded_commitment_threshold_minor,
                    body.goal_movement_threshold_minor,
                    int(body.missed_payday_alerts),
                    int(body.selected_return_deadline_alerts),
                    body.tone,
                    body.default_spend_account_id,
                    body.extra_cash_buffer_minor,
                    body.writing_mode,
                    int(body.allow_dated_estimates),
                    now,
                    identifier,
                ),
            )
    row = await (
        await db.execute(
            "SELECT * FROM finance_report_preferences WHERE id = ?", (identifier,)
        )
    ).fetchone()
    return _report_preference_response(dict(row))


def _report_preference_response(row: dict) -> FinanceReportPreferenceResponse:
    return FinanceReportPreferenceResponse(
        id=row["id"],
        space_id=row["space_id"],
        member_user_id=row["member_user_id"],
        locale=row["locale"],
        daily_time=row["daily_time"],
        enabled=bool(row["enabled"]),
        notification_channel=row["notification_channel"],
        notification_mode=row["notification_mode"],
        show_more_by_default=bool(row["show_more_by_default"]),
        quiet_hours_start=row["quiet_hours_start"],
        quiet_hours_end=row["quiet_hours_end"],
        underfunded_commitment_threshold_minor=row[
            "underfunded_commitment_threshold_minor"
        ],
        goal_movement_threshold_minor=row["goal_movement_threshold_minor"],
        missed_payday_alerts=bool(row["missed_payday_alerts"]),
        selected_return_deadline_alerts=bool(
            row["selected_return_deadline_alerts"]
        ),
        tone=row["tone"],
        default_spend_account_id=row["default_spend_account_id"],
        extra_cash_buffer_minor=row["extra_cash_buffer_minor"],
        writing_mode=row["writing_mode"],
        allow_dated_estimates=bool(row["allow_dated_estimates"]),
        ordinary_purchase_alerts=False,
        group_related_alerts=True,
        updated_at=row["updated_at"],
    )


async def get_report_preference(
    db,
    *,
    user: dict,
    space_id: str,
) -> FinanceReportPreferenceResponse:
    await require_finance_space(db, user=user, space_id=space_id)
    row = await (
        await db.execute(
            "SELECT * FROM finance_report_preferences WHERE member_user_id = ? "
            "AND space_id = ? AND family_id = ? AND deleted_at IS NULL",
            (user["id"], space_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        return await set_report_preference(
            db,
            user=user,
            space_id=space_id,
            body=FinanceReportPreferenceUpdate(),
        )
    return _report_preference_response(dict(row))


def _period_bounds(report_kind: str, local_date: date) -> tuple[date, date, date, date]:
    if report_kind == "MONTHLY":
        current_end = local_date.replace(day=1) - timedelta(days=1)
        current_start = current_end.replace(day=1)
        previous_end = current_start - timedelta(days=1)
        previous_start = previous_end.replace(day=1)
        return current_start, current_end, previous_start, previous_end
    if report_kind == "WEEKLY":
        # Weekly reports are always the last completed Monday-Sunday period.
        current_end = local_date - timedelta(days=local_date.weekday() + 1)
        current_start = current_end - timedelta(days=6)
        previous_end = current_start - timedelta(days=1)
        previous_start = previous_end - timedelta(days=6)
        return current_start, current_end, previous_start, previous_end
    days = 1
    current_start = local_date
    previous_end = current_start - timedelta(days=1)
    previous_start = previous_end - timedelta(days=days - 1)
    return current_start, local_date, previous_start, previous_end


async def _load_shared_period_evidence(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    observed_through: date,
) -> dict[str, object]:
    """Load report evidence that does not change between compared date ranges."""
    recurring = await (
        await db.execute(
            "SELECT series_type, evidence_json FROM finance_recurring_series "
            "WHERE space_id = ? AND family_id = ? AND currency = ? "
            "AND status = 'CONFIRMED' AND deleted_at IS NULL",
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    planned_rows = await (
        await db.execute(
            "SELECT source_metadata_json, approved_scenario "
            "FROM finance_purchase_proposals WHERE space_id = ? "
            "AND family_id = ? AND status = 'APPROVED' AND currency = ? "
            "AND deleted_at IS NULL",
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    proposal_purchase_ids: list[str] = []
    for proposal in planned_rows:
        if proposal["approved_scenario"] == "DO_NOTHING":
            continue
        try:
            observed_purchase_id = json.loads(proposal["source_metadata_json"]).get(
                "observed_purchase_id"
            )
        except (TypeError, json.JSONDecodeError):
            observed_purchase_id = None
        if isinstance(observed_purchase_id, str):
            proposal_purchase_ids.append(observed_purchase_id)
    observed_purchases: dict[str, object] = {}
    unique_purchase_ids = list(dict.fromkeys(proposal_purchase_ids))
    for offset in range(0, len(unique_purchase_ids), 400):
        batch = unique_purchase_ids[offset : offset + 400]
        placeholders = ",".join("?" for _ in batch)
        purchase_rows = await (
            await db.execute(
                "SELECT id, purchased_on, final_total_minor, refunded_minor FROM "
                f"finance_purchase_records WHERE id IN ({placeholders}) "
                "AND space_id = ? AND family_id = ? AND currency = ? "
                "AND superseded_by_id IS NULL AND deleted_at IS NULL",
                (*batch, space_id, user["family_id"], currency),
            )
        ).fetchall()
        observed_purchases.update({row["id"]: row for row in purchase_rows})
    habit_rows = await (
        await db.execute(
            "SELECT habit_id, observed_through, realised_saving_minor, displacement_minor "
            "FROM finance_habit_observations WHERE space_id = ? AND family_id = ? "
            "AND observed_through <= ? AND deleted_at IS NULL "
            "ORDER BY habit_id, observed_through",
            (space_id, user["family_id"], observed_through.isoformat()),
        )
    ).fetchall()
    return {
        "recurring": recurring,
        "proposal_purchase_ids": proposal_purchase_ids,
        "observed_purchases": observed_purchases,
        "habit_rows": habit_rows,
    }


async def _period_summary(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    start: date,
    end: date,
    shared_evidence: dict[str, object] | None = None,
) -> dict[str, object]:
    evidence = shared_evidence or await _load_shared_period_evidence(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        observed_through=end,
    )
    rows = await (
        await db.execute(
            """
            SELECT tx.id, tx.amount_minor, tx.data_through_at,
                   COALESCE(tx.primary_category_id, 'uncategorised') AS category_id
            FROM finance_transactions tx
            WHERE tx.space_id = ? AND tx.family_id = ? AND tx.currency = ?
              AND tx.state = 'POSTED'
              AND tx.canonical_date BETWEEN ? AND ? AND tx.deleted_at IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM finance_transaction_relations relation
                  WHERE relation.space_id = tx.space_id
                    AND relation.family_id = tx.family_id
                    AND relation.status = 'CONFIRMED'
                    AND relation.relation_type IN (
                        'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                    )
                    AND relation.deleted_at IS NULL
                    AND relation.from_transaction_id = tx.id
              )
              AND NOT EXISTS (
                  SELECT 1 FROM finance_transaction_relations relation
                  WHERE relation.space_id = tx.space_id
                    AND relation.family_id = tx.family_id
                    AND relation.status = 'CONFIRMED'
                    AND relation.relation_type IN (
                        'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'FX_LEG'
                    )
                    AND relation.deleted_at IS NULL
                    AND relation.to_transaction_id = tx.id
              )
            ORDER BY tx.canonical_date, tx.id
            """,
            (
                space_id,
                user["family_id"],
                currency,
                start.isoformat(),
                end.isoformat(),
            ),
        )
    ).fetchall()
    transaction_ids = [row["id"] for row in rows]
    refund_ids: set[str] = set()
    refunds_by_category: dict[str, int] = {}
    if transaction_ids:
        placeholders = ",".join("?" for _ in transaction_ids)
        relations = await (
            await db.execute(
                f"""
                SELECT relation.to_transaction_id,
                       COALESCE(original.primary_category_id, 'uncategorised') category_id,
                       repayment.amount_minor
                FROM finance_transaction_relations relation
                JOIN finance_transactions original
                  ON original.id = relation.from_transaction_id
                 AND original.family_id = relation.family_id
                JOIN finance_transactions repayment
                  ON repayment.id = relation.to_transaction_id
                 AND repayment.family_id = relation.family_id
                WHERE relation.space_id = ? AND relation.family_id = ?
                  AND relation.status = 'CONFIRMED'
                  AND relation.relation_type IN ('REFUND', 'REIMBURSEMENT')
                  AND relation.to_transaction_id IN ({placeholders})
                  AND relation.deleted_at IS NULL
                """,
                (space_id, user["family_id"], *transaction_ids),
            )
        ).fetchall()
        for relation in relations:
            refund_ids.add(relation["to_transaction_id"])
            category_id = relation["category_id"]
            refunds_by_category[category_id] = (
                refunds_by_category.get(category_id, 0)
                + max(0, relation["amount_minor"])
            )
    recurring = evidence["recurring"]
    salary_ids: set[str] = set()
    recurring_expense_ids: set[str] = set()
    for recurring_row in recurring:
        try:
            evidence_ids = {
                str(item) for item in json.loads(recurring_row["evidence_json"])
            }
        except (TypeError, json.JSONDecodeError):
            continue
        if recurring_row["series_type"] == "SALARY":
            salary_ids.update(evidence_ids)
        else:
            recurring_expense_ids.update(evidence_ids)
    # Report income uses the same strict saved salary evidence as plans.  Other
    # positive credits remain visible in the ledger but cannot become income or
    # improve the income-variance story.
    income = sum(
        row["amount_minor"]
        for row in rows
        if row["amount_minor"] > 0
        and row["id"] in salary_ids
        and row["id"] not in refund_ids
    )
    spend_by_category: dict[str, int] = {}
    for row in rows:
        if row["amount_minor"] < 0:
            spend_by_category[row["category_id"]] = (
                spend_by_category.get(row["category_id"], 0) - row["amount_minor"]
            )
    for category_id, amount in refunds_by_category.items():
        if category_id in spend_by_category:
            spend_by_category[category_id] = max(
                0, spend_by_category[category_id] - amount
            )
    spend = sum(spend_by_category.values())
    fixed = min(
        spend,
        sum(
            -row["amount_minor"]
            for row in rows
            if row["id"] in recurring_expense_ids and row["amount_minor"] < 0
        ),
    )
    coverage = await purchase_itemisation_coverage(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        start_date=start,
        end_date=end,
    )
    itemised = coverage.itemised_minor
    planned_exceptional = 0
    proposal_purchase_ids = evidence["proposal_purchase_ids"]
    observed_purchases = evidence["observed_purchases"]
    for observed_purchase_id in proposal_purchase_ids:
        observed_purchase = observed_purchases.get(observed_purchase_id)
        if observed_purchase and start <= date.fromisoformat(
            observed_purchase["purchased_on"]
        ) <= end:
            planned_exceptional += max(
                0,
                observed_purchase["final_total_minor"]
                - observed_purchase["refunded_minor"],
            )
    habit_rows = [
        row for row in evidence["habit_rows"] if row["observed_through"] <= end.isoformat()
    ]
    habit_before: dict[str, tuple[int, int]] = {}
    habit_through: dict[str, tuple[int, int]] = {}
    for observation in habit_rows:
        values = (
            observation["realised_saving_minor"],
            observation["displacement_minor"],
        )
        habit_through[observation["habit_id"]] = values
        if observation["observed_through"] < start.isoformat():
            habit_before[observation["habit_id"]] = values
    realised_habit = sum(
        max(0, values[0] - habit_before.get(habit_id, (0, 0))[0])
        for habit_id, values in habit_through.items()
    )
    shifted_spending = sum(
        max(0, values[1] - habit_before.get(habit_id, (0, 0))[1])
        for habit_id, values in habit_through.items()
    )
    return {
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        "currency": currency,
        "income_minor": income,
        "spend_minor": spend,
        "net_minor": income - spend,
        "fixed_cost_minor": fixed,
        "known_item_minor": itemised,
        "planned_exceptional_minor": planned_exceptional,
        "realised_habit_saving_minor": realised_habit,
        "shifted_spending_minor": shifted_spending,
        "spend_by_category": spend_by_category,
        "ledger_latest_transaction_at": max(
            (row["data_through_at"] for row in rows if row["data_through_at"]),
            default=None,
        ),
        "retail_eligible_minor": coverage.eligible_minor,
        "itemised_coverage_bps": coverage.coverage_bps,
        "evidence_transaction_count": len(rows),
    }


async def _account_freshness(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
) -> dict[str, object]:
    rows = await (
        await db.execute(
            """
            SELECT account.id, account.label, account.data_through_at,
                   account.fresh_through_date,
                   MAX(source.observed_at) AS source_observed_at
            FROM finance_accounts account
            LEFT JOIN finance_source_transactions source
              ON source.account_id = account.id AND source.space_id = account.space_id
             AND source.family_id = account.family_id AND source.deleted_at IS NULL
            WHERE account.space_id = ? AND account.family_id = ?
              AND account.currency = ? AND account.include_in_cashflow = 1
              AND account.purpose <> 'IGNORED' AND account.deleted_at IS NULL
            GROUP BY account.id, account.label, account.data_through_at,
                     account.fresh_through_date
            ORDER BY account.id
            """,
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    account_times: list[tuple[dict, str]] = []
    missing: list[dict[str, str]] = []
    for raw in rows:
        row = dict(raw)
        effective = (
            row["data_through_at"]
            or row["source_observed_at"]
            or row["fresh_through_date"]
        )
        if effective:
            account_times.append((row, effective))
        else:
            missing.append({"account_id": row["id"], "label": row["label"]})
    oldest = min((item[1] for item in account_times), default=None)
    newest = max((item[1] for item in account_times), default=None)
    older_accounts = [
        {
            "account_id": row["id"],
            "label": row["label"],
            "data_through_at": effective,
        }
        for row, effective in account_times
        if newest is not None and effective < newest
    ]
    return {
        "oldest_data_through_at": None if missing else oldest,
        "newest_data_through_at": newest,
        "older_accounts": older_accounts,
        "missing_accounts": missing,
        "is_mixed_freshness": bool(older_accounts or missing),
    }


async def _saved_report_context(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    local_date: date,
    period_start: date,
    period_end: date,
    default_spend_account_id: str | None,
    extra_cash_buffer_minor: int,
    allow_dated_estimates: bool,
) -> dict[str, object]:
    safe_spend: dict[str, object] = {
        "status": "NO_SAFE_AMOUNT",
        "answer_mode": "ESTIMATED_RANGE",
        "currency": currency,
        "amount_minor": None,
        "low_minor": 0,
        "high_minor": 0,
        "refusal_reasons": ["NO_INCLUDED_CASH_ACCOUNT_ZERO_ESTIMATE"],
    }
    forecast = await (
        await db.execute(
            "SELECT * FROM finance_forecast_snapshots WHERE space_id = ? "
            "AND family_id = ? AND currency = ? AND deleted_at IS NULL "
            "ORDER BY created_at DESC, id DESC LIMIT 1",
            (space_id, user["family_id"], currency),
        )
    ).fetchone()
    if default_spend_account_id:
        operating = await (
            await db.execute(
                "SELECT id, minimum_balance_minor FROM finance_accounts WHERE id = ? AND space_id = ? "
                "AND family_id = ? AND currency = ? "
                "AND account_type IN ('CURRENT', 'CASH') "
                "AND purpose = 'OPERATING_CURRENT' AND include_in_cashflow = 1 "
                "AND deleted_at IS NULL",
                (
                    default_spend_account_id,
                    space_id,
                    user["family_id"],
                    currency,
                ),
            )
        ).fetchone()
    else:
        operating = await (
            await db.execute(
                "SELECT id, minimum_balance_minor FROM finance_accounts WHERE space_id = ? AND family_id = ? "
                "AND currency = ? AND account_type = 'CURRENT' "
                "AND purpose = 'OPERATING_CURRENT' AND include_in_cashflow = 1 "
                "AND deleted_at IS NULL ORDER BY primary_spending_account DESC, id LIMIT 1",
                (space_id, user["family_id"], currency),
            )
        ).fetchone()
    if operating is not None:
        balance = await (
            await db.execute(
                "SELECT booked_minor, available_minor, observed_at FROM "
                "finance_balance_snapshots WHERE account_id = ? AND space_id = ? "
                "AND family_id = ? AND currency = ? AND deleted_at IS NULL "
                "ORDER BY observed_at DESC, id DESC LIMIT 1",
                (operating["id"], space_id, user["family_id"], currency),
            )
        ).fetchone()
        if balance is not None:
            known_minor = max(
                0,
                int(
                    balance["available_minor"]
                    if balance["available_minor"] is not None
                    else balance["booked_minor"]
                )
                - int(operating["minimum_balance_minor"])
                - extra_cash_buffer_minor,
            )
            safe_spend = {
                "status": "OK" if known_minor else "NO_SAFE_AMOUNT",
                "answer_mode": "ESTIMATED_RANGE",
                "currency": currency,
                "amount_minor": None,
                "low_minor": max(0, known_minor - max(1, known_minor // 10))
                if known_minor
                else 0,
                "high_minor": known_minor,
                "data_through": str(balance["observed_at"])[:10],
                "refusal_reasons": ["LATEST_BALANCE_SMALL_RANGE_ESTIMATE"],
                "extra_cash_buffer_minor": extra_cash_buffer_minor,
                "account_id": operating["id"],
            }
    if forecast is not None and operating is not None:
        try:
            answer = await safe_to_spend_from_forecast(
                db,
                user=user,
                body=FinanceSafeToSpendRequest(
                    forecast_id=forecast["id"],
                    route="direct",
                    spend_date=local_date,
                    account_id=operating["id"],
                ),
            )
            safe_spend = answer.model_dump(mode="json")
            for key in ("amount_minor", "low_minor", "high_minor"):
                if safe_spend.get(key) is not None:
                    safe_spend[key] = max(
                        0,
                        int(safe_spend[key]) - extra_cash_buffer_minor,
                    )
            safe_spend["extra_cash_buffer_minor"] = extra_cash_buffer_minor
            safe_spend["account_id"] = operating["id"]
        except (FinanceSafeToSpendError, TypeError, ValueError):
            # The latest-balance range above remains useful if a saved forecast row
            # is damaged or from an older engine version.
            pass
    commitment_rows = await (
        await db.execute(
            "SELECT id, name, amount_mode, exact_minor, expected_minor, high_minor, "
            "reviewed_dates_json FROM finance_commitments WHERE space_id = ? "
            "AND family_id = ? AND currency = ? AND priority = 'PROTECTED' "
            "AND status = 'ACTIVE' AND deleted_at IS NULL",
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    candidates = []
    for row in commitment_rows:
        amount = (
            row["exact_minor"]
            if row["amount_mode"] == "EXACT"
            else row["high_minor"]
            if row["amount_mode"] == "RANGE"
            else row["expected_minor"]
        )
        for raw_date in json.loads(row["reviewed_dates_json"]):
            due = date.fromisoformat(raw_date)
            if due >= local_date:
                candidates.append((due, row, amount))
    next_commitment = None
    if candidates:
        due, commitment, amount = min(candidates, key=lambda item: (item[0], item[1]["id"]))
        next_commitment = {
            "id": commitment["id"],
            "name": commitment["name"],
            "due_date": due.isoformat(),
            "amount_minor": amount,
            "currency": currency,
        }
    purchases = await (
        await db.execute(
            "SELECT id, merchant_name, purchased_on, final_total_minor, refunded_minor "
            "FROM finance_purchase_records WHERE space_id = ? AND family_id = ? "
            "AND currency = ? AND purchased_on BETWEEN ? AND ? "
            "AND superseded_by_id IS NULL AND deleted_at IS NULL "
            "ORDER BY final_total_minor DESC, id LIMIT 50",
            (
                space_id,
                user["family_id"],
                currency,
                period_start.isoformat(),
                period_end.isoformat(),
            ),
        )
    ).fetchall()
    lines_by_purchase: dict[str, list[object]] = {}
    if purchases:
        purchase_ids = [purchase["id"] for purchase in purchases]
        placeholders = ",".join("?" for _ in purchase_ids)
        line_rows = await (
            await db.execute(
                f"""
                SELECT line.purchase_id, line.id, line.raw_description,
                       line.line_net_minor, assessment.utility,
                       assessment.outcome_state, assessment.plannedness
                FROM finance_purchase_lines line
                JOIN finance_purchase_line_assessments assessment
                  ON assessment.line_id = line.id AND assessment.space_id = line.space_id
                 AND assessment.family_id = line.family_id
                 AND assessment.review_status = 'CONFIRMED'
                 AND assessment.deleted_at IS NULL
                WHERE line.purchase_id IN ({placeholders}) AND line.space_id = ?
                  AND line.family_id = ? AND line.deleted_at IS NULL
                ORDER BY line.purchase_id, COALESCE(line.line_net_minor, 0) DESC,
                         line.id
                """,
                (*purchase_ids, space_id, user["family_id"]),
            )
        ).fetchall()
        for line in line_rows:
            lines_by_purchase.setdefault(line["purchase_id"], []).append(line)
    material_lines = None
    for purchase in purchases:
        lines = lines_by_purchase.get(purchase["id"], [])
        useful = any(row["utility"] in {"essential", "useful"} for row in lines)
        questionable = any(
            row["utility"] == "optional"
            or row["outcome_state"] in {"regretted", "unused", "returned"}
            for row in lines
        )
        if useful and questionable:
            material_lines = {
                "purchase_id": purchase["id"],
                "merchant": purchase["merchant_name"],
                "purchased_on": purchase["purchased_on"],
                "net_total_minor": max(
                    0, purchase["final_total_minor"] - purchase["refunded_minor"]
                ),
                "currency": currency,
                "context": "MIXED_USEFUL_AND_OPTIONAL",
                "lines": [dict(row) for row in lines[:5]],
            }
            break
    return {
        "safe_to_spend": safe_spend,
        "next_protected_commitment": next_commitment,
        "material_purchase_line_context": material_lines,
    }


async def _trajectory(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    local_date: date,
    shared_evidence: dict[str, object] | None = None,
) -> tuple[str, int, list[dict]]:
    plans = await _active_plans_for_currency(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
    )
    if not plans:
        return "UNKNOWN", 0, []
    plan_ids = [str(plan["id"]) for plan in plans]
    placeholders = ",".join("?" for _ in plan_ids)
    budgets = await (
        await db.execute(
            f"SELECT category_id, baseline_minor, reduction_minor "
            f"FROM finance_plan_categories WHERE plan_id IN ({placeholders}) "
            "AND space_id = ? AND family_id = ? AND deleted_at IS NULL",
            (*plan_ids, space_id, user["family_id"]),
        )
    ).fetchall()
    month_start = local_date.replace(day=1)
    month = await _period_summary(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        start=month_start,
        end=local_date,
        shared_evidence=shared_evidence,
    )
    # Each plan stores a category's household baseline. Add the distinct
    # baselines once and subtract each goal's own assigned cut once.
    category_budgets: dict[str, dict[str, int]] = {}
    for row in budgets:
        state = category_budgets.setdefault(
            str(row["category_id"]),
            {"baseline_minor": 0, "reduction_minor": 0},
        )
        state["baseline_minor"] = max(
            state["baseline_minor"], int(row["baseline_minor"])
        )
        state["reduction_minor"] += max(0, int(row["reduction_minor"]))
    full_budget = sum(
        max(0, state["baseline_minor"] - state["reduction_minor"])
        for state in category_budgets.values()
    )
    elapsed_budget = full_budget * local_date.day // calendar.monthrange(
        local_date.year, local_date.month
    )[1]
    overspend = int(month["spend_minor"]) - elapsed_budget
    tolerance = max(2_500, full_budget // 20)
    status = "ON_PLAN" if overspend <= 0 else "WATCH" if overspend <= tolerance else "OFF_PLAN"
    # The habit is commonly the mechanism used to achieve the active plan, so
    # adding both would double-count the same expected saving.
    expected = sum(_stored_plan_monthly_saving(plan) for plan in plans)
    return status, expected, plans


async def _coaching_choices(
    db,
    *,
    user: dict,
    space_id: str,
    local_date: date,
) -> tuple[dict | None, dict | None]:
    payday = await (
        await db.execute(
            "SELECT action.id, action.due_date, action.amount_minor, action.currency, "
            "action.source_account_id, action.destination_account_id, "
            "source.label AS source_account_label, destination.label AS destination_account_label "
            "FROM finance_payday_actions action "
            "LEFT JOIN finance_accounts source ON source.id = action.source_account_id "
            "AND source.space_id = action.space_id AND source.deleted_at IS NULL "
            "LEFT JOIN finance_accounts destination ON destination.id = action.destination_account_id "
            "AND destination.space_id = action.space_id AND destination.deleted_at IS NULL "
            "WHERE action.space_id = ? AND action.family_id = ? AND action.status = 'PENDING' "
            "AND action.due_date <= ? AND action.deleted_at IS NULL "
            "ORDER BY action.due_date, action.created_at LIMIT 1",
            (
                space_id,
                user["family_id"],
                local_date.isoformat(),
            ),
        )
    ).fetchone()
    primary: dict | None = None
    if payday is not None:
        primary = {
            "kind": "PAYDAY_TRANSFER",
            "record_id": payday["id"],
            "due_date": payday["due_date"],
            "amount_minor": payday["amount_minor"],
            "currency": payday["currency"],
            "source_account_id": payday["source_account_id"],
            "destination_account_id": payday["destination_account_id"],
            "source_account_label": payday["source_account_label"],
            "destination_account_label": payday["destination_account_label"],
            "route": f"/finance/payday-actions/{payday['id']}",
        }
    else:
        purchase_reviews = await list_high_impact_purchase_review(
            db,
            user=user,
            space_id=space_id,
            minimum_impact_minor=10_000,
            limit=1,
        )
        if purchase_reviews:
            review = purchase_reviews[0]
            primary = {
                "kind": "PURCHASE_REVIEW",
                "record_id": review.line_id,
                "line_id": review.line_id,
                "purchase_id": review.purchase_id,
                "source_id": review.source_id,
                "title": f"Review {review.merchant}: {review.source_description}",
                "amount_minor": review.amount_minor,
                "currency": review.currency,
                "route": review.deep_link,
            }
        else:
            habit = await (
                await db.execute(
                    "SELECT id, name, review_date FROM finance_habits WHERE space_id = ? "
                    "AND family_id = ? AND status IN ('ACTIVE', 'PAUSED') "
                    "AND review_date <= ? AND deleted_at IS NULL "
                    "ORDER BY review_date, slot LIMIT 1",
                    (space_id, user["family_id"], local_date.isoformat()),
                )
            ).fetchone()
            if habit is not None:
                primary = {
                    "kind": "HABIT_REVIEW",
                    "record_id": habit["id"],
                    "title": habit["name"],
                    "review_date": habit["review_date"],
                    "route": f"/finance/habits/{habit['id']}",
                }
    future_payday = await (
        await db.execute(
            "SELECT id, due_date, amount_minor, currency FROM finance_payday_actions "
            "WHERE space_id = ? AND family_id = ? AND status = 'PENDING' "
            "AND due_date > ? AND due_date <= ? AND deleted_at IS NULL "
            "ORDER BY due_date, created_at LIMIT 1",
            (
                space_id,
                user["family_id"],
                local_date.isoformat(),
                (local_date + timedelta(days=7)).isoformat(),
            ),
        )
    ).fetchone()
    finding = await (
        await db.execute(
            "SELECT id, title, observation, data_through_date FROM finance_findings "
            "WHERE space_id = ? AND family_id = ? AND status = 'OPEN' "
            "AND deleted_at IS NULL ORDER BY confidence_bps DESC, created_at LIMIT 1",
            (space_id, user["family_id"]),
        )
    ).fetchone()
    observation = None
    if future_payday is not None:
        observation = {
            "kind": "UPCOMING_PAYDAY_TRANSFER",
            "record_id": future_payday["id"],
            "due_date": future_payday["due_date"],
            "amount_minor": future_payday["amount_minor"],
            "currency": future_payday["currency"],
            "route": f"/finance/payday-actions/{future_payday['id']}",
        }
    elif finding is not None:
        observation = {
            "kind": "SAVED_FINDING",
            "record_id": finding["id"],
            "title": finding["title"],
            "observation": finding["observation"],
            "data_through_date": finding["data_through_date"],
            "route": f"/finance/opportunities/{finding['id']}",
        }
    return primary, observation


async def finance_today_action(db, user: dict) -> dict | None:
    """Return one authorised, finishable Finance action for this adult's Today view."""
    if not user.get("family_id"):
        return None
    # A family may open Today before ever opening Finance. Resolving the visible
    # spaces first creates the ordinary Finance defaults, including the timezone
    # settings used below, so the optional Today card can simply be empty rather
    # than reporting Finance as unavailable.
    spaces = await accessible_finance_spaces(db, user=user)
    local_date = await _local_today(db, family_id=user["family_id"])
    choices: list[dict] = []
    for space in spaces:
        primary, _ = await _coaching_choices(
            db,
            user=user,
            space_id=space.id,
            local_date=local_date,
        )
        if primary is None:
            continue
        choices.append(
            {
                "id": primary["record_id"],
                "kind": primary["kind"],
                "space_id": space.id,
                "space_kind": space.kind.upper(),
                "space_name": space.name,
                "due_date": primary.get("due_date"),
                "review_date": primary.get("review_date"),
                "title": primary.get("title"),
                "amount_minor": primary.get("amount_minor"),
                "currency": primary.get("currency"),
                "source_account_id": primary.get("source_account_id"),
                "source_account_label": primary.get("source_account_label"),
                "destination_account_id": primary.get("destination_account_id"),
                "destination_account_label": primary.get("destination_account_label"),
                "line_id": primary.get("line_id"),
                "purchase_id": primary.get("purchase_id"),
                "source_id": primary.get("source_id"),
            }
        )
    if not choices:
        return None
    choices.sort(
        key=lambda item: (
            {"PAYDAY_TRANSFER": 0, "PURCHASE_REVIEW": 1, "HABIT_REVIEW": 2}.get(item["kind"], 3),
            item.get("due_date") or item.get("review_date") or "9999-12-31",
            item["id"],
        )
    )
    return choices[0]


async def refresh_coaching_report(
    db,
    *,
    user: dict,
    space_id: str,
    report_kind: str,
    as_of: date | None = None,
    source_watermark: str | None = None,
) -> FinanceCoachingReportResponse:
    if report_kind not in {"DAILY", "DRIFT", "WEEKLY", "MONTHLY"}:
        raise FinanceCoachingError("Unsupported coaching report kind")
    await require_finance_space(db, user=user, space_id=space_id)
    report_watermark = source_watermark or await finance_space_watermark(
        db,
        family_id=user["family_id"],
        space_id=space_id,
    )
    settings = await _settings(db, family_id=user["family_id"])
    local_date = as_of or await _local_today(db, family_id=user["family_id"])
    unchanged = await (
        await db.execute(
            "SELECT * FROM finance_coaching_reports WHERE member_user_id = ? "
            "AND space_id = ? AND report_kind = ? AND local_date = ? "
            "AND source_watermark = ? AND deleted_at IS NULL "
            "ORDER BY created_at DESC, id DESC LIMIT 1",
            (
                user["id"],
                space_id,
                report_kind,
                local_date.isoformat(),
                report_watermark,
            ),
        )
    ).fetchone()
    if unchanged is not None:
        return _report_response(dict(unchanged))
    preference = await (
        await db.execute(
            "SELECT * FROM finance_report_preferences WHERE member_user_id = ? "
            "AND space_id = ? AND family_id = ? AND deleted_at IS NULL",
            (user["id"], space_id, user["family_id"]),
        )
    ).fetchone()
    locale = preference["locale"] if preference else "en"
    currency = settings["default_currency"]
    current_start, current_end, previous_start, previous_end = _period_bounds(
        report_kind, local_date
    )
    shared_evidence = await _load_shared_period_evidence(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        observed_through=max(current_end, previous_end, local_date),
    )
    current = await _period_summary(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        start=current_start,
        end=current_end,
        shared_evidence=shared_evidence,
    )
    previous = await _period_summary(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        start=previous_start,
        end=previous_end,
        shared_evidence=shared_evidence,
    )
    trajectory, expected, active_plans = await _trajectory(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        local_date=local_date,
        shared_evidence=shared_evidence,
    )
    primary, observation = await _coaching_choices(
        db, user=user, space_id=space_id, local_date=local_date
    )
    freshness = await _account_freshness(
        db, user=user, space_id=space_id, currency=currency
    )
    saved_context = await _saved_report_context(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        local_date=local_date,
        period_start=current_start,
        period_end=current_end,
        default_spend_account_id=(
            preference["default_spend_account_id"] if preference else None
        ),
        extra_cash_buffer_minor=(
            preference["extra_cash_buffer_minor"] if preference else 0
        ),
        allow_dated_estimates=(
            bool(preference["allow_dated_estimates"]) if preference else True
        ),
    )
    net_variance = int(current["net_minor"]) - int(previous["net_minor"])
    components = {
        "income_variance_minor": int(current["income_minor"])
        - int(previous["income_minor"]),
        "fixed_cost_variance_minor": -(
            int(current["fixed_cost_minor"]) - int(previous["fixed_cost_minor"])
        ),
        "planned_exceptional_variance_minor": -(
            int(current["planned_exceptional_minor"])
            - int(previous["planned_exceptional_minor"])
        ),
        "known_item_variance_minor": -(
            int(current["known_item_minor"]) - int(previous["known_item_minor"])
        ),
        "realised_habit_saving_variance_minor": int(
            current["realised_habit_saving_minor"]
        )
        - int(previous["realised_habit_saving_minor"]),
        "shifted_spending_variance_minor": -(
            int(current["shifted_spending_minor"])
            - int(previous["shifted_spending_minor"])
        ),
        "corrections_minor": 0,
        "transfers_minor": 0,
    }
    components["unresolved_variance_minor"] = net_variance - sum(components.values())
    summary = {
        "current": current,
        "previous": previous,
        "net_variance_minor": net_variance,
        "variance_components": components,
        "active_plan_ids": [plan["id"] for plan in active_plans],
        "active_plan_id": (
            active_plans[0]["id"] if len(active_plans) == 1 else None
        ),
        "freshness": freshness,
        **saved_context,
    }
    digest = _digest(
        {
            "member_user_id": user["id"],
            "space_id": space_id,
            "report_kind": report_kind,
            "local_date": local_date.isoformat(),
            "summary": summary,
            "trajectory": trajectory,
            "expected": expected,
            "primary": primary,
            "observation": observation,
        }
    )
    existing = await (
        await db.execute(
            "SELECT * FROM finance_coaching_reports WHERE member_user_id = ? "
            "AND space_id = ? AND report_kind = ? AND local_date = ? "
            "AND input_digest = ? AND deleted_at IS NULL",
            (user["id"], space_id, report_kind, local_date.isoformat(), digest),
        )
    ).fetchone()
    if existing is not None:
        return _report_response(dict(existing))
    safe = saved_context["safe_to_spend"]
    safe_date = safe.get("data_through")
    if safe.get("amount_minor") is not None:
        safe_text = _money_text(int(safe["amount_minor"]), currency)
    elif safe.get("low_minor") is not None and safe.get("high_minor") is not None:
        safe_text = (
            f"{_money_text(int(safe['low_minor']), currency)}–"
            f"{_money_text(int(safe['high_minor']), currency)} "
            "(rough range)"
        )
    else:
        safe_text = _money_text(0, currency)
    commitment = saved_context["next_protected_commitment"]
    commitment_text = (
        f"{commitment['name']} "
        f"{_money_text(int(commitment['amount_minor']), currency)} "
        f"on {commitment['due_date']}"
        if commitment
        else "none saved"
    )
    action_names = {
        "PAYDAY_TRANSFER": "move the money you planned",
        "HABIT_REVIEW": "check how your habit is going",
        "PURCHASE_REVIEW": "check a planned buy",
        "PLAN_REVIEW": "check your active plan",
        "DATA_REVIEW": "add some missing money details",
    }
    action_text = (
        f"One thing to do: {action_names.get(primary['kind'], 'check a money detail')}."
        if primary
        else "Nothing to do today."
    )
    line_context = saved_context["material_purchase_line_context"]
    line_text = (
        f" The {line_context['merchant']} order mixed useful and optional items; "
        "the confirmed ones are kept separate."
        if line_context
        else ""
    )
    confidence = 80 if safe.get("answer_mode") == "ESTIMATED_RANGE" else 95
    basis_text = (
        f" Based on spending through {safe_date}; about {confidence}% sure."
        if safe_date
        else f" Based on saved balances, bills and spending; about {confidence}% sure."
    )
    if locale == "de":
        if safe.get("amount_minor") is not None:
            safe_text_de = _money_text(int(safe["amount_minor"]), currency)
        elif safe.get("low_minor") is not None and safe.get("high_minor") is not None:
            safe_text_de = (
                f"{_money_text(int(safe['low_minor']), currency)}–"
                f"{_money_text(int(safe['high_minor']), currency)} "
                "(geschätzter Bereich)"
            )
        else:
            safe_text_de = _money_text(0, currency)
        commitment_text_de = (
            f"{commitment['name']} "
            f"{_money_text(int(commitment['amount_minor']), currency)} "
            f"am {commitment['due_date']}"
            if commitment
            else "keine gespeichert"
        )
        action_names_de = {
            "PAYDAY_TRANSFER": "Sparüberweisung am Zahltag",
            "HABIT_REVIEW": "Gewohnheit überprüfen",
        }
        action_text_de = (
            f"Hauptaktion: {action_names_de.get(primary['kind'], 'Finanzaktion prüfen')}."
            if primary
            else "Heute ist keine Hauptaktion fällig."
        )
        line_text_de = (
            f" Die Bestellung bei {line_context['merchant']} enthielt sowohl nützliche "
            "als auch optionale Artikel; die bestätigten Positionen bleiben getrennt."
            if line_context
            else ""
        )
        basis_text_de = (
            f" Basierend auf Ausgaben bis {safe_date}; ungefähr {confidence}% sicher."
            if safe_date
            else (
                " Basierend auf gespeicherten Kontoständen, Rechnungen und Ausgaben; "
                f"ungefähr {confidence}% sicher."
            )
        )
        explanation = (
            f"Sicher auszugeben: {safe_text_de}. Nächste geschützte Ausgabe: "
            f"{commitment_text_de}. {action_text_de}{line_text_de}{basis_text_de}"
        )
    else:
        explanation = (
            f"Safe to spend: {safe_text}. Next big bill: "
            f"{commitment_text}. {action_text}{line_text}{basis_text}"
        )
    identifier = str(uuid.uuid4())
    now = _now()
    data_through = freshness["oldest_data_through_at"]
    coverage = current["itemised_coverage_bps"]
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_coaching_reports
                (id, space_id, member_user_id, report_kind, local_date,
                 household_timezone, locale, input_digest, source_watermark,
                 data_through_at,
                 itemised_coverage_bps, trajectory_status,
                 expected_durable_saving_minor, primary_action_json,
                 optional_observation_json, summary_json, explanation,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                user["id"],
                report_kind,
                local_date.isoformat(),
                settings["household_timezone"],
                locale,
                digest,
                report_watermark,
                data_through,
                coverage,
                trajectory,
                expected,
                _json(primary) if primary else None,
                _json(observation) if observation else None,
                _json(summary),
                explanation,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    row = await (
        await db.execute("SELECT * FROM finance_coaching_reports WHERE id = ?", (identifier,))
    ).fetchone()
    return _report_response(dict(row))


async def refresh_drift_monitor(
    db,
    *,
    user: dict,
    space_id: str,
    as_of: date | None = None,
    materiality_minor: int = 2_500,
) -> FinanceCoachingReportResponse | None:
    await require_finance_space(db, user=user, space_id=space_id)
    settings = await _settings(db, family_id=user["family_id"])
    local_date = as_of or await _local_today(db, family_id=user["family_id"])
    latest = await (
        await db.execute(
            "SELECT summary_json FROM finance_coaching_reports WHERE member_user_id = ? "
            "AND space_id = ? AND report_kind IN ('DRIFT', 'DAILY') "
            "AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1",
            (user["id"], space_id),
        )
    ).fetchone()
    if latest is None:
        return None
    before = json.loads(latest["summary_json"])
    current = await _period_summary(
        db,
        user=user,
        space_id=space_id,
        currency=settings["default_currency"],
        start=local_date,
        end=local_date,
    )
    prior_net = int(before.get("current", {}).get("net_minor", 0))
    if abs(int(current["net_minor"]) - prior_net) < materiality_minor:
        return None
    return await refresh_coaching_report(
        db,
        user=user,
        space_id=space_id,
        report_kind="DRIFT",
        as_of=local_date,
    )


async def list_coaching_reports(
    db,
    *,
    user: dict,
    space_id: str,
    report_kind: str | None = None,
    limit: int = 50,
) -> list[FinanceCoachingReportResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    kind_clause = "" if report_kind is None else "AND report_kind = ?"
    params: tuple[object, ...] = (
        (user["id"], space_id, user["family_id"], limit)
        if report_kind is None
        else (user["id"], space_id, user["family_id"], report_kind, limit)
    )
    rows = await (
        await db.execute(
            f"SELECT * FROM finance_coaching_reports WHERE member_user_id = ? "
            f"AND space_id = ? AND family_id = ? {kind_clause} "
            "AND deleted_at IS NULL ORDER BY local_date DESC, created_at DESC LIMIT ?",
            params,
        )
    ).fetchall()
    return [_report_response(dict(row)) for row in rows]


async def run_finance_coaching_schedule(
    db,
    *,
    now: datetime | None = None,
) -> int:
    instant = now or datetime.now(timezone.utc)
    if instant.tzinfo is None:
        instant = instant.replace(tzinfo=timezone.utc)
    users = await (
        await db.execute(
            "SELECT * FROM users WHERE family_id IS NOT NULL AND deleted_at IS NULL "
            "ORDER BY family_id, id"
        )
    ).fetchall()
    generated = 0
    for raw_user in users:
        user = dict(raw_user)
        settings = await _settings(db, family_id=user["family_id"])
        local_now = instant.astimezone(household_zone(settings["household_timezone"]))
        reminder_preference = await (
            await db.execute(
                "SELECT quiet_start, quiet_end FROM reminder_preferences "
                "WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL",
                (user["id"], user["family_id"]),
            )
        ).fetchone()
        quiet_start = reminder_preference["quiet_start"] if reminder_preference else "21:00"
        quiet_end = reminder_preference["quiet_end"] if reminder_preference else "07:00"
        spaces = await accessible_finance_spaces(db, user=user)
        for space in spaces:
            preference = await (
                await db.execute(
                    "SELECT * FROM finance_report_preferences "
                    "WHERE member_user_id = ? AND space_id = ? AND family_id = ? "
                    "AND deleted_at IS NULL",
                    (user["id"], space.id, user["family_id"]),
                )
            ).fetchone()
            if preference is not None and not preference["enabled"]:
                continue
            due_text = preference["daily_time"] if preference else "07:00:00"
            due_time = datetime.strptime(due_text, "%H:%M:%S").time()
            if local_now.time().replace(tzinfo=None) < due_time:
                continue
            kinds = ["DAILY"]
            if local_now.weekday() == 0:
                kinds.append("WEEKLY")
            if local_now.day == 1:
                kinds.append("MONTHLY")
            source_watermark = await finance_space_watermark(
                db,
                family_id=user["family_id"],
                space_id=space.id,
            )
            for report_kind in kinds:
                unchanged = await (
                    await db.execute(
                        "SELECT * FROM finance_coaching_reports "
                        "WHERE member_user_id = ? AND space_id = ? "
                        "AND report_kind = ? AND local_date = ? "
                        "AND source_watermark = ? AND deleted_at IS NULL "
                        "ORDER BY created_at DESC, id DESC LIMIT 1",
                        (
                            user["id"],
                            space.id,
                            report_kind,
                            local_now.date().isoformat(),
                            source_watermark,
                        ),
                    )
                ).fetchone()
                before = (1,) if unchanged is not None else await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_coaching_reports "
                        "WHERE member_user_id = ? AND space_id = ? "
                        "AND report_kind = ? AND local_date = ? "
                        "AND deleted_at IS NULL",
                        (
                            user["id"],
                            space.id,
                            report_kind,
                            local_now.date().isoformat(),
                        ),
                    )
                ).fetchone()
                report = (
                    _report_response(dict(unchanged))
                    if unchanged is not None
                    else await refresh_coaching_report(
                        db,
                        user=user,
                        space_id=space.id,
                        report_kind=report_kind,
                        as_of=local_now.date(),
                        source_watermark=source_watermark,
                    )
                )
                if before[0] == 0:
                    generated += 1
                if (
                    report_kind == "DAILY"
                    and preference is not None
                    and preference["notification_channel"] == "BROWSER"
                    and preference["notification_mode"] != "NEVER"
                    and (
                        preference["notification_mode"] == "DAILY"
                        or report.primary_action is not None
                    )
                ):
                    if in_quiet_hours(local_now, quiet_start[:5], quiet_end[:5]):
                        continue
                    # One key across all of this member's Finance spaces groups
                    # due commitments, goal movement, payday status, and the
                    # daily report into at most one privacy-safe push. Ordinary
                    # purchases never enter this delivery path.
                    await deliver_finance_report_notification(
                        user_id=user["id"],
                        family_id=user["family_id"],
                        reminder_key=(
                            f"finance:daily:{user['id']}:"
                            f"{local_now.date().isoformat()}"
                        ),
                        locale=preference["locale"],
                        notification_mode=preference["notification_mode"],
                        action_id=(
                            report.primary_action.get("record_id")
                            if report.primary_action
                            else None
                        ),
                        action_scope=(
                            "household" if space.kind == "household" else "mine"
                        ),
                    )
    return generated
