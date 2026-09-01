"""Persist deterministic recurring, opportunity, and material-question scans."""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from fractions import Fraction

from app.models.finance import (
    FinanceCommitmentCreate,
    FinanceFactCreate,
    FinanceFactUpdate,
    FinanceFindingDisposition,
    FinanceFindingResponse,
    FinanceMaterialQuestionAnswer,
    FinanceMaterialQuestionCorrection,
    FinanceMaterialQuestionResponse,
    FinancePatternScanResponse,
    FinanceRecurringCorrection,
    FinanceRecurringSeriesResponse,
)
from app.services.finance.analytics import PurchaseLineRecord, TransactionRecord
from app.services.finance.dates import household_zone
from app.services.finance.foundation import require_finance_access, require_finance_space
from app.services.finance.money import Money, normalise_currency
from app.services.finance.opportunities import (
    OpportunityCandidate,
    ProductPriceObservation,
    detect_repeated_purchase_patterns,
    detect_seasonal_patterns,
    detect_unit_price_drift,
    rank_opportunities,
)
from app.services.finance.recurring import (
    RecurringSeries,
    detect_recurring_series,
    england_wales_bank_holidays,
)
from app.services.finance.planning import (
    create_commitment,
    create_fact,
    set_fact_status,
    update_fact,
)
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

_NUMBER_TOKEN = re.compile(r"\b\d+\b")
_SPACE = re.compile(r"\s+")
_DIRECT_DEBIT = re.compile(r"\b(?:DIRECT\s+DEBIT|DD)\b", re.IGNORECASE)
_SUBSCRIPTION_WORDS = (
    "ADOBE",
    "APPLE.COM/BILL",
    "DISNEY",
    "GOOGLE ONE",
    "NETFLIX",
    "PRIME",
    "SPOTIFY",
    "SUBSCRIPTION",
)
_SALARY_WORDS = ("SALARY", "PAYROLL", "WAGES", "PAYE PAY", "EMPLOYER PAY")
_CARD_REPAYMENT = re.compile(
    r"\b(?:AMEX|BARCLAYCARD|CREDIT\s+CARD\s+(?:PAYMENT|REPAYMENT)|CARD\s+REPAYMENT)\b",
    re.IGNORECASE,
)


class FinancePatternError(ValueError):
    """Base error safe to expose from pattern routes."""


class FinancePatternNotFoundError(FinancePatternError):
    """A caller-visible saved pattern was not found."""


class FinancePatternConflictError(FinancePatternError):
    """A saved pattern cannot accept the requested transition."""


@dataclass(frozen=True, slots=True)
class _FindingDraft:
    key: str
    finding_type: str
    title: str
    observation: str
    evidence_ids: tuple[str, ...]
    baseline: dict[str, object]
    saving_low_minor: int
    saving_high_minor: int
    confidence_bps: int
    effort: int
    overlap_group: str | None


@dataclass(frozen=True, slots=True)
class _QuestionDraft:
    key: str
    kind: str
    prompt: str
    evidence_ids: tuple[str, ...]
    priority_minor: int
    action_kind: str
    action_target_id: str | None


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _round_fraction(value: Fraction) -> int:
    return (value.numerator + value.denominator // 2) // value.denominator


def _format_money(minor_units: int, currency: str) -> str:
    """Format an exact stored amount for ordinary user-facing sentences."""
    sign = "-" if minor_units < 0 else ""
    major, remainder = divmod(abs(minor_units), 100)
    amount = f"{major:,}.{remainder:02d}"
    symbol = {"GBP": "£", "EUR": "€", "USD": "$"}.get(currency)
    return f"{sign}{symbol}{amount}" if symbol else f"{sign}{currency} {amount}"


def _normalised_key(value: str) -> str:
    without_numbers = _NUMBER_TOKEN.sub(" ", value.upper())
    return _SPACE.sub(" ", without_numbers).strip(" -")[:180]


def _transaction_type(row: dict) -> str:
    description = f"{row['cleaned_description']} {row['merchant_text'] or ''}"
    if _DIRECT_DEBIT.search(description):
        return "direct_debit"
    if row["amount_minor"] > 0:
        return "bank_transfer"
    if row["account_type"] == "CREDIT_CARD":
        return "card"
    return "bank_payment"


def _series_name(key: str) -> str:
    return key.rsplit(":", 1)[-1].title()


def _series_type(series: RecurringSeries) -> str | None:
    upper = series.key.upper()
    if series.key.startswith("income:"):
        return "SALARY" if any(word in upper for word in _SALARY_WORDS) else None
    if any(word in upper for word in _SUBSCRIPTION_WORDS):
        return "SUBSCRIPTION"
    if ":DIRECT_DEBIT:" in upper:
        return "BILL"
    return "RECURRING_COST"


def _recurring_response(row: dict) -> FinanceRecurringSeriesResponse:
    return FinanceRecurringSeriesResponse(
        id=row["id"],
        space_id=row["space_id"],
        detection_key=row["detection_key"],
        name=row["name"],
        series_type=row["series_type"],
        interval_kind=row["interval_kind"],
        expected_minor=row["expected_minor"],
        low_minor=row["low_minor"],
        high_minor=row["high_minor"],
        currency=row["currency"],
        next_expected_date=row["next_expected_date"],
        working_day_adjustment=row["working_day_adjustment"],
        evidence_refs=json.loads(row["evidence_json"]),
        confidence_bps=row["confidence_bps"],
        status=row["status"],
        confirmed_at=row["confirmed_at"],
        updated_at=row["updated_at"],
    )


def _finding_response(row: dict) -> FinanceFindingResponse:
    return FinanceFindingResponse(
        id=row["id"],
        space_id=row["space_id"],
        finding_type=row["finding_type"],
        title=row["title"],
        observation=row["observation"],
        evidence_refs=json.loads(row["evidence_json"]),
        baseline=json.loads(row["baseline_json"]),
        saving_low_minor=row["saving_low_minor"],
        saving_high_minor=row["saving_high_minor"],
        currency=row["currency"],
        confidence_bps=row["confidence_bps"],
        effort=row["effort"],
        overlap_group=row["overlap_group"],
        status=row["status"],
        data_through_date=row["data_through_date"],
        updated_at=row["updated_at"],
    )


def _question_response(row: dict) -> FinanceMaterialQuestionResponse:
    if row["action_kind"] == "CONFIRM_RECURRING":
        method = "POST"
        route = f"/api/finance/questions/{row['id']}/confirm"
    elif row["action_kind"] == "IDENTIFY_SALARY":
        method = "PUT"
        route = f"/api/finance/questions/{row['id']}/correct"
    elif row["action_kind"] == "SAVE_NURSERY_PLAN":
        method = "PUT"
        route = f"/api/finance/questions/{row['id']}/correct"
    elif row["action_kind"] == "ADD_CREDIT_CARD":
        method = "GET"
        route = "/?view=finance&section=setup"
    else:
        method = "GET"
        route = f"/api/finance/purchases/evidence/{row['action_target_id']}"
    return FinanceMaterialQuestionResponse(
        id=row["id"],
        space_id=row["space_id"],
        question_kind=row["question_kind"],
        prompt=row["prompt"],
        evidence_refs=json.loads(row["evidence_json"]),
        action_kind=row["action_kind"],
        action_target_id=row["action_target_id"],
        next_action_method=method,
        next_action_route=route,
        priority_minor=row["priority_minor"],
        currency=row["currency"],
        status=row["status"],
        answer_text=row["answer_text"],
        resolved_at=row["resolved_at"],
        updated_at=row["updated_at"],
    )


async def _transactions(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
) -> tuple[list[dict], list[TransactionRecord]]:
    rows = await (
        await db.execute(
            """
            SELECT tx.*, account.account_type, category.name AS category_name
            FROM finance_transactions tx
            JOIN finance_accounts account
              ON account.id = tx.account_id AND account.space_id = tx.space_id
             AND account.family_id = tx.family_id AND account.deleted_at IS NULL
            LEFT JOIN finance_categories category
              ON category.id = tx.primary_category_id
             AND category.space_id = tx.space_id AND category.deleted_at IS NULL
            WHERE tx.space_id = ? AND tx.family_id = ? AND tx.currency = ?
              AND tx.state = 'POSTED' AND tx.deleted_at IS NULL
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
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    raw = [dict(row) for row in rows]
    records = []
    for row in raw:
        base = _normalised_key(row["merchant_text"] or row["cleaned_description"])
        records.append(
            TransactionRecord(
                id=row["id"],
                space_id=space_id,
                day=date.fromisoformat(row["canonical_date"]),
                amount=Money(row["amount_minor"], currency),
                account_id=row["account_id"],
                merchant=row["merchant_text"] or row["cleaned_description"],
                category=row["category_name"],
                transaction_type=_transaction_type(row),
                evidence_ids=(row["id"],),
                recurring_key=base or None,
            )
        )
    return raw, records


async def _purchase_lines(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
) -> tuple[list[dict], list[PurchaseLineRecord]]:
    rows = await (
        await db.execute(
            """
            SELECT line.*, purchase.purchased_on, purchase.currency,
                   purchase.merchant_name, item.identity_key,
                   item.display_name AS normalized_item_name,
                   assessment.beneficiary, assessment.purpose,
                   assessment.plannedness, assessment.utility,
                   assessment.decision_quality, assessment.value_for_money,
                   assessment.outcome_state,
                   EXISTS (
                       SELECT 1 FROM finance_line_refunds refund
                       WHERE refund.line_id = line.id AND refund.space_id = line.space_id
                         AND refund.deleted_at IS NULL
                   ) AS was_returned
            FROM finance_purchase_lines line
            JOIN finance_purchase_records purchase
              ON purchase.id = line.purchase_id AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id AND purchase.deleted_at IS NULL
             AND purchase.superseded_by_id IS NULL
            LEFT JOIN finance_purchase_line_assessments assessment
              ON assessment.line_id = line.id AND assessment.space_id = line.space_id
             AND assessment.family_id = line.family_id
             AND assessment.review_status = 'CONFIRMED'
             AND assessment.deleted_at IS NULL
            LEFT JOIN finance_normalized_purchase_items item
              ON item.id = assessment.normalized_item_id
             AND item.space_id = line.space_id AND item.family_id = line.family_id
             AND item.deleted_at IS NULL
            WHERE line.space_id = ? AND line.family_id = ?
              AND purchase.currency = ? AND line.deleted_at IS NULL
              AND line.line_net_minor IS NOT NULL
            ORDER BY purchase.purchased_on, line.id
            """,
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    raw = [dict(row) for row in rows]
    records = []
    for row in raw:
        if row["line_net_minor"] < 0 or row["identity_key"] is None:
            continue
        outcome = row["outcome_state"]
        if row["was_returned"]:
            outcome = "returned"
        records.append(
            PurchaseLineRecord(
                id=row["id"],
                space_id=space_id,
                day=date.fromisoformat(row["purchased_on"]),
                net_amount=Money(row["line_net_minor"], currency),
                merchant=row["merchant_name"],
                line_kind=row["line_kind"],
                normalized_item=row["identity_key"],
                purpose=row["purpose"],
                recipient=row["beneficiary"],
                plannedness=row["plannedness"],
                utility=row["utility"],
                decision_quality=row["decision_quality"],
                outcome=outcome,
                tags=("replacement",) if row["replaces_description"] else (),
                evidence_ids=(row["source_id"], row["id"]),
            )
        )
    return raw, records


async def _protected_knowledge_tokens(
    db,
    *,
    user: dict,
    space_id: str,
) -> set[str]:
    rows = await (
        await db.execute(
            """
            SELECT preference_key AS knowledge_key FROM finance_preferences
            WHERE space_id = ? AND family_id = ? AND status = 'CONFIRMED'
              AND value_kind IN ('PROTECTED', 'VALUED') AND deleted_at IS NULL
            UNION ALL
            SELECT fact_key AS knowledge_key FROM finance_facts
            WHERE space_id = ? AND family_id = ? AND status = 'CONFIRMED'
              AND (fact_key LIKE 'expected_cost.%' OR fact_key LIKE 'annual_cost.%')
              AND deleted_at IS NULL
            """,
            (space_id, user["family_id"], space_id, user["family_id"]),
        )
    ).fetchall()
    tokens = set()
    for row in rows:
        key = row["knowledge_key"].lower()
        token = key.split(".", 1)[-1].replace("_", " ").strip()
        if token:
            tokens.add(token)
    return tokens


def _is_protected(value: str, protected_tokens: set[str]) -> bool:
    normalised = value.lower().replace("_", " ")
    return any(token in normalised or normalised in token for token in protected_tokens)


def _bank_holidays(records: list[TransactionRecord], as_of: date) -> tuple[date, ...]:
    years = {as_of.year, as_of.year + 1}
    years.update(record.day.year for record in records)
    return tuple(
        sorted(
            holiday
            for year in years
            for holiday in england_wales_bank_holidays(year)
        )
    )


async def _save_recurring(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    series: tuple[RecurringSeries, ...],
) -> None:
    now = _now()
    eligible = [
        (item, detected_type)
        for item in series
        if (detected_type := _series_type(item)) is not None
    ]
    detected_keys = {item.key for item, _ in eligible}
    async with serialized_create(db):
        for item, detected_type in eligible:
            existing = await (
                await db.execute(
                    """
                    SELECT * FROM finance_recurring_series
                    WHERE space_id = ? AND detection_key = ? AND family_id = ?
                      AND deleted_at IS NULL
                    """,
                    (space_id, item.key, user["family_id"]),
                )
            ).fetchone()
            expected = _round_fraction(item.average_amount_minor)
            confidence_bps = _round_fraction(item.confidence * 10_000)
            evidence = _json(list(item.transaction_ids))
            if existing is None:
                await db.execute(
                    """
                    INSERT INTO finance_recurring_series
                        (id, space_id, detection_key, name, series_type,
                         interval_kind, expected_minor, low_minor, high_minor,
                         currency, next_expected_date, working_day_adjustment,
                         evidence_json, confidence_bps, status, family_id,
                         created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            'CANDIDATE', ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        space_id,
                        item.key,
                        _series_name(item.key),
                        detected_type,
                        item.cadence,
                        expected,
                        item.minimum_amount_minor,
                        item.maximum_amount_minor,
                        currency,
                        item.expected_next_date.isoformat(),
                        item.weekend_adjustment,
                        evidence,
                        confidence_bps,
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
                continue
            if existing["status"] == "REJECTED":
                continue
            await save_history(
                db,
                "finance_recurring_series",
                existing["id"],
                user["id"],
                family_id=user["family_id"],
            )
            if existing["status"] == "CONFIRMED":
                await db.execute(
                    """
                    UPDATE finance_recurring_series
                    SET evidence_json = ?, updated_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    (evidence, now, existing["id"]),
                )
                continue
            await db.execute(
                """
                UPDATE finance_recurring_series
                SET name = ?, series_type = ?, interval_kind = ?,
                    expected_minor = ?, low_minor = ?, high_minor = ?,
                    currency = ?, next_expected_date = ?,
                    working_day_adjustment = ?, evidence_json = ?,
                    confidence_bps = ?, status = 'CANDIDATE', updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                (
                    _series_name(item.key),
                    detected_type,
                    item.cadence,
                    expected,
                    item.minimum_amount_minor,
                    item.maximum_amount_minor,
                    currency,
                    item.expected_next_date.isoformat(),
                    item.weekend_adjustment,
                    evidence,
                    confidence_bps,
                    now,
                    existing["id"],
                ),
            )
        rows = await (
            await db.execute(
                """
                SELECT id, detection_key FROM finance_recurring_series
                WHERE space_id = ? AND family_id = ? AND status = 'CANDIDATE'
                  AND detection_key IS NOT NULL AND deleted_at IS NULL
                """,
                (space_id, user["family_id"]),
            )
        ).fetchall()
        for row in rows:
            if row["detection_key"] not in detected_keys:
                await save_history(
                    db,
                    "finance_recurring_series",
                    row["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    "UPDATE finance_recurring_series "
                    "SET status = 'EXPIRED', updated_at = ? WHERE id = ?",
                    (now, row["id"]),
                )


def _trend_findings(
    transactions: list[TransactionRecord],
    *,
    as_of: date,
    currency: str,
    protected_tokens: set[str],
) -> list[_FindingDraft]:
    recent_start = as_of - timedelta(days=89)
    prior_start = recent_start - timedelta(days=90)
    prior_end = recent_start - timedelta(days=1)
    year_end = as_of - timedelta(days=365)
    year_start = year_end - timedelta(days=89)
    baseline_start = as_of - timedelta(days=364)
    grouped: dict[str, list[TransactionRecord]] = {}
    for transaction in transactions:
        if transaction.amount.minor_units >= 0:
            continue
        key = _normalised_key(transaction.merchant or transaction.category or "")
        if key:
            grouped.setdefault(key, []).append(transaction)
    findings = []
    for key, records in sorted(grouped.items()):
        if _is_protected(key, protected_tokens):
            continue
        recent = [item for item in records if recent_start <= item.day <= as_of]
        if len(recent) < 2:
            continue
        recent_total = sum(-item.amount.minor_units for item in recent)
        if recent_total < 5_000:
            continue
        prior_total = sum(
            -item.amount.minor_units
            for item in records
            if prior_start <= item.day <= prior_end
        )
        year_total = sum(
            -item.amount.minor_units
            for item in records
            if year_start <= item.day <= year_end
        )
        baseline_records = [
            item for item in records if baseline_start <= item.day < recent_start
        ]
        baseline_total = sum(-item.amount.minor_units for item in baseline_records)
        baseline_days = max(1, (recent_start - baseline_start).days)
        baseline_90 = baseline_total * 90 // baseline_days
        references = [value for value in (prior_total, year_total, baseline_90) if value]
        if not references:
            continue
        reference = sorted(references)[len(references) // 2]
        increase = recent_total - reference
        if increase < 2_500 or recent_total * 4 < reference * 5:
            continue
        evidence = tuple(item.id for item in recent)
        findings.append(
            _FindingDraft(
                key=f"trend:{key.lower()}",
                finding_type="TREND_CHANGE",
                title=f"{key.title()} has risen",
                observation=(
                    f"The latest 90 days total {_format_money(recent_total, currency)}, "
                    f"compared with {_format_money(prior_total, currency)} in the prior "
                    f"period, {_format_money(year_total, currency)} in the same period "
                    f"a year earlier and a {_format_money(baseline_90, currency)} baseline."
                ),
                evidence_ids=evidence,
                baseline={
                    "recent_minor": recent_total,
                    "prior_minor": prior_total,
                    "same_period_last_year_minor": year_total,
                    "baseline_90_day_minor": baseline_90,
                },
                saving_low_minor=0,
                saving_high_minor=0,
                confidence_bps=8_000 if prior_total and year_total else 6_500,
                effort=2,
                overlap_group=f"cost:{key.lower()}",
            )
        )
    return findings


def _line_findings(
    raw_lines: list[dict],
    lines: list[PurchaseLineRecord],
    *,
    currency: str,
    protected_tokens: set[str],
) -> list[_FindingDraft]:
    findings: list[_FindingDraft] = []
    for pattern in detect_seasonal_patterns(
        lines,
        allowed_space_ids=tuple({line.space_id for line in lines}),
        currency=currency,
    ) if lines else ():
        typical_amount = _format_money(
            _round_fraction(pattern.typical_other_month_minor), currency
        )
        findings.append(
            _FindingDraft(
                key=f"seasonal:{pattern.key}",
                finding_type="SEASONAL",
                title=f"{pattern.key.title()} is seasonal",
                observation=(
                    f"Months {', '.join(map(str, pattern.peak_months))} total "
                    f"{_format_money(pattern.peak_total_minor, currency)} versus a typical "
                    f"{typical_amount}."
                ),
                evidence_ids=pattern.evidence_ids,
                baseline={
                    "peak_months": list(pattern.peak_months),
                    "peak_minor": pattern.peak_total_minor,
                    "typical_other_month_minor": _round_fraction(
                        pattern.typical_other_month_minor
                    ),
                },
                saving_low_minor=0,
                saving_high_minor=0,
                confidence_bps=8_000,
                effort=1,
                overlap_group=f"item:{pattern.key}",
            )
        )

    repeated = detect_repeated_purchase_patterns(
        lines,
        allowed_space_ids=tuple({line.space_id for line in lines}),
        currency=currency,
    ) if lines else ()
    by_item: dict[str, list[PurchaseLineRecord]] = {}
    for line in lines:
        if line.normalized_item:
            by_item.setdefault(line.normalized_item, []).append(line)
    raw_by_id = {row["id"]: row for row in raw_lines}
    for pattern in repeated:
        item_lines = sorted(by_item[pattern.item], key=lambda item: (item.day, item.id))
        protected = _is_protected(pattern.item, protected_tokens) or any(
            line.utility == "essential" or line.outcome == "valued"
            for line in item_lines
        )
        close_repeats = [
            later
            for earlier, later in zip(item_lines, item_lines[1:])
            if (later.day - earlier.day).days <= 45
            and (
                later.plannedness == "replacement"
                or later.decision_quality in {"questionable", "poor_value"}
                or later.outcome in {"regretted", "unused"}
            )
        ]
        explicit_replacements = [
            line for line in item_lines if raw_by_id[line.id]["replaces_description"]
        ]
        if (close_repeats or explicit_replacements) and not protected:
            findings.append(
                _FindingDraft(
                    key=f"duplicate:{pattern.item}",
                    finding_type="DUPLICATE_REPLACEMENT",
                    title=f"Review repeated {pattern.item}",
                    observation=(
                        f"{pattern.purchase_count} matching items include "
                        f"{len(close_repeats)} close repeat(s) and "
                        f"{len(explicit_replacements)} recorded replacement(s)."
                    ),
                    evidence_ids=pattern.evidence_ids,
                    baseline={
                        "purchase_count": pattern.purchase_count,
                        "close_repeat_count": len(close_repeats),
                        "replacement_count": len(explicit_replacements),
                    },
                    saving_low_minor=0,
                    saving_high_minor=0,
                    confidence_bps=7_000 if explicit_replacements else 5_500,
                    effort=1,
                    overlap_group=f"item:{pattern.item}",
                )
            )
        if pattern.returned_count >= 2:
            findings.append(
                _FindingDraft(
                    key=f"returns:{pattern.item}",
                    finding_type="REPEATED_RETURN",
                    title=f"{pattern.item.title()} is often returned",
                    observation=(
                        f"{pattern.returned_count} of {pattern.purchase_count} recorded "
                        "purchases have line-level return evidence."
                    ),
                    evidence_ids=pattern.evidence_ids,
                    baseline={
                        "purchase_count": pattern.purchase_count,
                        "returned_count": pattern.returned_count,
                    },
                    saving_low_minor=0,
                    saving_high_minor=0,
                    confidence_bps=9_000,
                    effort=1,
                    overlap_group=f"item:{pattern.item}",
                )
            )

    observations = []
    for row in raw_lines:
        if (
            row["identity_key"] is None
            or not row["unit_price_minor"]
            or not row["unit_description"]
        ):
            continue
        observations.append(
            ProductPriceObservation(
                id=row["id"],
                normalized_item=row["identity_key"],
                retailer=row["merchant_name"],
                brand=None,
                observed_on=date.fromisoformat(row["purchased_on"]),
                price=Money(row["unit_price_minor"], currency),
                pack_quantity=1,
                unit=row["unit_description"],
                evidence_ids=(row["source_id"], row["id"]),
            )
        )
    for drift in detect_unit_price_drift(observations):
        if _is_protected(drift.normalized_item, protected_tokens):
            continue
        findings.append(
            _FindingDraft(
                key=f"price:{drift.retailer}:{drift.normalized_item}:{drift.unit}",
                finding_type="PRICE_DRIFT",
                title=f"{drift.normalized_item.title()} costs more",
                observation=(
                    f"The observed unit price at {drift.retailer} rose from "
                    f"{_format_money(_round_fraction(drift.first_unit_price_minor), currency)} "
                    f"to {_format_money(_round_fraction(drift.latest_unit_price_minor), currency)}."
                ),
                evidence_ids=drift.evidence_ids,
                baseline={
                    "first_observed_on": drift.first_observed_on.isoformat(),
                    "latest_observed_on": drift.latest_observed_on.isoformat(),
                    "first_unit_price_minor": _round_fraction(
                        drift.first_unit_price_minor
                    ),
                    "latest_unit_price_minor": _round_fraction(
                        drift.latest_unit_price_minor
                    ),
                },
                saving_low_minor=0,
                saving_high_minor=0,
                confidence_bps=9_000,
                effort=2,
                overlap_group=f"item:{drift.normalized_item}",
            )
        )
    return findings


def _transaction_findings(
    transactions: list[TransactionRecord],
    recurring: tuple[RecurringSeries, ...],
    *,
    as_of: date,
    currency: str,
    protected_tokens: set[str],
) -> list[_FindingDraft]:
    findings: list[_FindingDraft] = []
    records_by_key: dict[str, list[TransactionRecord]] = {}
    for transaction in transactions:
        if transaction.amount.minor_units >= 0:
            continue
        key = _normalised_key(transaction.recurring_key or transaction.merchant or "")
        if key:
            records_by_key.setdefault(key, []).append(transaction)

    for series in recurring:
        if series.cadence != "IRREGULAR" or not series.key.startswith("cost:"):
            continue
        annualised = _annualised_total(
            [item for item in transactions if item.id in series.transaction_ids]
        )
        if annualised < 20_000:
            continue
        key = series.key.rsplit(":", 1)[-1]
        if _is_protected(key, protected_tokens):
            continue
        findings.append(
            _FindingDraft(
                key=f"one-off:{series.key}",
                finding_type="REPEATED_ONE_OFF",
                title=f"{key.title()} keeps recurring",
                observation=(
                    f"{len(series.transaction_ids)} irregular payments now annualise "
                    f"to about {_format_money(annualised, currency)}."
                ),
                evidence_ids=series.transaction_ids,
                baseline={
                    "cadence": "IRREGULAR",
                    "annualised_minor": annualised,
                    "as_of": as_of.isoformat(),
                },
                saving_low_minor=0,
                saving_high_minor=0,
                confidence_bps=5_500,
                effort=2,
                overlap_group=f"cost:{key.lower()}",
            )
        )

    for key, records in sorted(records_by_key.items()):
        if _is_protected(key, protected_tokens):
            continue
        if len(records) < 4 or max(-item.amount.minor_units for item in records) > 2_500:
            continue
        annualised = _annualised_total(records)
        if annualised < 12_000:
            continue
        findings.append(
            _FindingDraft(
                key=f"small-cost:{key.lower()}",
                finding_type="ANNUALISED_SMALL_COST",
                title=f"Small {key.title()} payments add up",
                observation=(
                    f"{len(records)} payments of at most {_format_money(2_500, currency)} "
                    f"add up to about {_format_money(annualised, currency)} a year."
                ),
                evidence_ids=tuple(item.id for item in records),
                baseline={
                    "payment_count": len(records),
                    "annualised_minor": annualised,
                },
                saving_low_minor=0,
                saving_high_minor=0,
                confidence_bps=7_000,
                effort=1,
                overlap_group=f"cost:{key.lower()}",
            )
        )
    return findings


def _annualised_total(records: list[TransactionRecord]) -> int:
    if not records:
        return 0
    ordered = sorted(records, key=lambda item: item.day)
    total = sum(abs(item.amount.minor_units) for item in ordered)
    span_days = max(30, (ordered[-1].day - ordered[0].day).days + 1)
    return total * 365 // span_days


async def _save_findings(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    as_of: date,
    drafts: list[_FindingDraft],
) -> None:
    now = _now()
    unique = {draft.key: draft for draft in drafts}
    async with serialized_create(db):
        for draft in unique.values():
            existing = await (
                await db.execute(
                    "SELECT * FROM finance_findings WHERE space_id = ? "
                    "AND finding_key = ? AND family_id = ? AND deleted_at IS NULL",
                    (space_id, draft.key, user["family_id"]),
                )
            ).fetchone()
            values = (
                draft.finding_type,
                draft.title,
                draft.observation,
                _json(list(draft.evidence_ids)),
                _json(draft.baseline),
                draft.saving_low_minor,
                draft.saving_high_minor,
                currency,
                draft.confidence_bps,
                draft.effort,
                draft.overlap_group,
                as_of.isoformat(),
                now,
                now,
            )
            if existing is None:
                await db.execute(
                    """
                    INSERT INTO finance_findings
                        (id, space_id, finding_key, finding_type, title,
                         observation, evidence_json, baseline_json,
                         saving_low_minor, saving_high_minor, currency,
                         confidence_bps, effort, overlap_group, status,
                         data_through_date, detected_at, family_id,
                         created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'OPEN',
                            ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        space_id,
                        draft.key,
                        *values[:-1],
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
            elif existing["status"] == "OPEN":
                await save_history(
                    db,
                    "finance_findings",
                    existing["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    """
                    UPDATE finance_findings
                    SET finding_type = ?, title = ?, observation = ?,
                        evidence_json = ?, baseline_json = ?, saving_low_minor = ?,
                        saving_high_minor = ?, currency = ?, confidence_bps = ?,
                        effort = ?, overlap_group = ?, data_through_date = ?,
                        detected_at = ?, updated_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    (*values, existing["id"]),
                )
        existing_open = await (
            await db.execute(
                "SELECT id, finding_key FROM finance_findings "
                "WHERE space_id = ? AND family_id = ? AND status = 'OPEN' "
                "AND deleted_at IS NULL",
                (space_id, user["family_id"]),
            )
        ).fetchall()
        for row in existing_open:
            if row["finding_key"] not in unique:
                await save_history(
                    db,
                    "finance_findings",
                    row["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    "UPDATE finance_findings SET status = 'EXPIRED', updated_at = ? "
                    "WHERE id = ?",
                    (now, row["id"]),
                )


async def _question_drafts(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    raw_transactions: list[dict],
    detected_recurring: tuple[RecurringSeries, ...],
) -> list[_QuestionDraft]:
    questions = []
    salary = await (
        await db.execute(
            """
            SELECT * FROM finance_recurring_series
            WHERE space_id = ? AND family_id = ? AND series_type = 'SALARY'
              AND status = 'CANDIDATE' AND deleted_at IS NULL
            ORDER BY expected_minor DESC LIMIT 1
            """,
            (space_id, user["family_id"]),
        )
    ).fetchone()
    confirmed_salary = await (
        await db.execute(
            "SELECT 1 FROM finance_recurring_series WHERE space_id = ? "
            "AND family_id = ? AND series_type = 'SALARY' "
            "AND status = 'CONFIRMED' AND deleted_at IS NULL LIMIT 1",
            (space_id, user["family_id"]),
        )
    ).fetchone()
    if salary is not None and confirmed_salary is None:
        questions.append(
            _QuestionDraft(
                key=f"salary:{salary['detection_key']}",
                kind="SALARY",
                prompt=(
                    f"Is {salary['name']} your salary, normally around "
                    f"{_format_money(salary['expected_minor'], currency)}?"
                ),
                evidence_ids=tuple(json.loads(salary["evidence_json"])),
                priority_minor=salary["expected_minor"],
                action_kind="CONFIRM_RECURRING",
                action_target_id=salary["id"],
            )
        )
    elif confirmed_salary is None:
        uncertain_income = [
            series
            for series in detected_recurring
            if series.key.startswith("income:") and _series_type(series) is None
        ]
        if uncertain_income:
            candidate = max(
                uncertain_income,
                key=lambda item: (item.average_amount_minor, item.key),
            )
            questions.append(
                _QuestionDraft(
                    key=f"salary-identity:{candidate.key}",
                    kind="SALARY",
                    prompt=(
                        f"Is the regular incoming payment {_series_name(candidate.key)} "
                        "salary, a benefit, a refund or something else?"
                    ),
                    evidence_ids=candidate.transaction_ids,
                    priority_minor=_round_fraction(candidate.average_amount_minor),
                    action_kind="IDENTIFY_SALARY",
                    action_target_id=candidate.key,
                )
            )

    nursery_rows = [
        row
        for row in raw_transactions
        if row["amount_minor"] < 0 and "NURSERY" in row["cleaned_description"]
    ]
    nursery_fact = await (
        await db.execute(
            "SELECT 1 FROM finance_facts WHERE space_id = ? AND family_id = ? "
            "AND fact_key LIKE 'nursery.%' AND status = 'CONFIRMED' "
            "AND deleted_at IS NULL LIMIT 1",
            (space_id, user["family_id"]),
        )
    ).fetchone()
    if nursery_rows and nursery_fact is None:
        total = sum(-row["amount_minor"] for row in nursery_rows)
        questions.append(
            _QuestionDraft(
                key="nursery:schedule",
                kind="NURSERY",
                prompt="What is the nursery payment schedule and when will it change?",
                evidence_ids=tuple(row["id"] for row in nursery_rows),
                priority_minor=total,
                action_kind="SAVE_NURSERY_PLAN",
                action_target_id=None,
            )
        )

    card_account = await (
        await db.execute(
            "SELECT 1 FROM finance_accounts WHERE space_id = ? AND family_id = ? "
            "AND account_type = 'CREDIT_CARD' AND deleted_at IS NULL LIMIT 1",
            (space_id, user["family_id"]),
        )
    ).fetchone()
    possible_repayments = [
        row
        for row in raw_transactions
        if row["amount_minor"] < 0
        and _CARD_REPAYMENT.search(row["cleaned_description"])
    ]
    if possible_repayments and card_account is None:
        questions.append(
            _QuestionDraft(
                key="missing-card:repayments",
                kind="MISSING_CARD",
                prompt=(
                    "These look like credit-card repayments, but the card account is "
                    "missing. Add or identify the card so spending is not overstated."
                ),
                evidence_ids=tuple(row["id"] for row in possible_repayments),
                priority_minor=max(-row["amount_minor"] for row in possible_repayments),
                action_kind="ADD_CREDIT_CARD",
                action_target_id=None,
            )
        )

    unitemised = await (
        await db.execute(
            """
            SELECT line.id, line.source_id, line.line_net_minor,
                   line.raw_description
            FROM finance_purchase_lines line
            JOIN finance_purchase_records purchase
              ON purchase.id = line.purchase_id AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id AND purchase.deleted_at IS NULL
            WHERE line.space_id = ? AND line.family_id = ?
              AND line.evidence_status = 'unitemised'
              AND line.line_net_minor >= 10000 AND line.deleted_at IS NULL
            ORDER BY line.line_net_minor DESC LIMIT 1
            """,
            (space_id, user["family_id"]),
        )
    ).fetchone()
    if unitemised is not None:
        questions.append(
            _QuestionDraft(
                key=f"unitemised:{unitemised['source_id']}",
                kind="LARGE_UNITEMISED_PURCHASE",
                prompt=(
                    "What was in the "
                    f"{_format_money(unitemised['line_net_minor'], currency)} purchase?"
                ),
                evidence_ids=(unitemised["source_id"], unitemised["id"]),
                priority_minor=unitemised["line_net_minor"],
                action_kind="ITEMISE_PURCHASE",
                action_target_id=unitemised["source_id"],
            )
        )
    return sorted(questions, key=lambda item: (-item.priority_minor, item.key))[:4]


async def _save_questions(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    drafts: list[_QuestionDraft],
) -> None:
    now = _now()
    keys = {draft.key for draft in drafts}
    async with serialized_create(db):
        for draft in drafts:
            existing = await (
                await db.execute(
                    "SELECT * FROM finance_material_questions WHERE space_id = ? "
                    "AND question_key = ? AND family_id = ? AND deleted_at IS NULL",
                    (space_id, draft.key, user["family_id"]),
                )
            ).fetchone()
            if existing is None:
                await db.execute(
                    """
                    INSERT INTO finance_material_questions
                        (id, space_id, question_key, question_kind, prompt,
                         evidence_json, action_kind, action_target_id,
                         priority_minor, currency, status,
                         family_id, created_at, updated_at, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'OPEN', ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        space_id,
                        draft.key,
                        draft.kind,
                        draft.prompt,
                        _json(list(draft.evidence_ids)),
                        draft.action_kind,
                        draft.action_target_id,
                        draft.priority_minor,
                        currency,
                        user["family_id"],
                        now,
                        now,
                        user["id"],
                    ),
                )
            elif existing["status"] == "OPEN":
                await save_history(
                    db,
                    "finance_material_questions",
                    existing["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    """
                    UPDATE finance_material_questions
                    SET prompt = ?, evidence_json = ?, action_kind = ?,
                        action_target_id = ?, priority_minor = ?, updated_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    (
                        draft.prompt,
                        _json(list(draft.evidence_ids)),
                        draft.action_kind,
                        draft.action_target_id,
                        draft.priority_minor,
                        now,
                        existing["id"],
                    ),
                )
        open_rows = await (
            await db.execute(
                "SELECT id, question_key FROM finance_material_questions "
                "WHERE space_id = ? AND family_id = ? AND status = 'OPEN' "
                "AND deleted_at IS NULL",
                (space_id, user["family_id"]),
            )
        ).fetchall()
        for row in open_rows:
            if row["question_key"] not in keys:
                await save_history(
                    db,
                    "finance_material_questions",
                    row["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    "UPDATE finance_material_questions "
                    "SET status = 'EXPIRED', updated_at = ? WHERE id = ?",
                    (now, row["id"]),
                )


async def list_recurring_series(
    db,
    *,
    user: dict,
    space_id: str,
    include_inactive: bool = False,
) -> list[FinanceRecurringSeriesResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_inactive else "AND status IN ('CANDIDATE', 'CONFIRMED')"
    rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_recurring_series
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL {clause}
            ORDER BY CASE series_type WHEN 'SALARY' THEN 0 ELSE 1 END,
                     expected_minor DESC, name
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_recurring_response(dict(row)) for row in rows]


async def _authorised_row(db, *, user: dict, table: str, record_id: str) -> dict:
    if table not in {
        "finance_recurring_series",
        "finance_findings",
        "finance_material_questions",
    }:
        raise ValueError("Unsupported Finance pattern table")
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
        raise FinancePatternNotFoundError("Finance pattern not found")
    return dict(row)


async def confirm_recurring_series(
    db, *, user: dict, series_id: str
) -> FinanceRecurringSeriesResponse:
    row = await _authorised_row(
        db,
        user=user,
        table="finance_recurring_series",
        record_id=series_id,
    )
    if row["status"] in {"REJECTED", "EXPIRED"}:
        raise FinancePatternConflictError("Inactive recurring series cannot be confirmed")
    if not row["next_expected_date"]:
        raise FinancePatternConflictError(
            "Set the next expected date before confirming this recurring series"
        )
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_recurring_series",
            series_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_recurring_series SET status = 'CONFIRMED', "
            "confirmed_at = COALESCE(confirmed_at, ?), updated_at = ? WHERE id = ?",
            (now, now, series_id),
        )
    row.update(status="CONFIRMED", confirmed_at=row["confirmed_at"] or now, updated_at=now)
    return _recurring_response(row)


async def correct_recurring_series(
    db,
    *,
    user: dict,
    series_id: str,
    body: FinanceRecurringCorrection,
) -> FinanceRecurringSeriesResponse:
    row = await _authorised_row(
        db,
        user=user,
        table="finance_recurring_series",
        record_id=series_id,
    )
    if row["status"] in {"REJECTED", "EXPIRED"}:
        raise FinancePatternConflictError("Inactive recurring series cannot be corrected")
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_recurring_series",
            series_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_recurring_series
            SET name = ?, series_type = ?, interval_kind = ?, expected_minor = ?,
                low_minor = ?, high_minor = ?, currency = ?, next_expected_date = ?,
                working_day_adjustment = ?, confidence_bps = 10000,
                status = 'CONFIRMED', confirmed_at = COALESCE(confirmed_at, ?),
                updated_at = ?
            WHERE id = ? AND deleted_at IS NULL
            """,
            (
                body.name,
                body.series_type,
                body.interval_kind,
                body.expected_minor,
                body.low_minor,
                body.high_minor,
                body.currency,
                body.next_expected_date.isoformat(),
                body.working_day_adjustment,
                now,
                now,
                series_id,
            ),
        )
    fresh = await (
        await db.execute("SELECT * FROM finance_recurring_series WHERE id = ?", (series_id,))
    ).fetchone()
    return _recurring_response(dict(fresh))


async def dismiss_recurring_series(
    db, *, user: dict, series_id: str
) -> FinanceRecurringSeriesResponse:
    row = await _authorised_row(
        db,
        user=user,
        table="finance_recurring_series",
        record_id=series_id,
    )
    if row["status"] == "CONFIRMED":
        raise FinancePatternConflictError("Correct or expire a confirmed recurring series")
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_recurring_series",
            series_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_recurring_series SET status = 'REJECTED', updated_at = ? "
            "WHERE id = ?",
            (now, series_id),
        )
    row.update(status="REJECTED", updated_at=now)
    return _recurring_response(row)


async def list_findings(
    db,
    *,
    user: dict,
    space_id: str,
    include_inactive: bool = False,
) -> list[FinanceFindingResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_inactive else "AND status IN ('OPEN', 'ACCEPTED', 'SNOOZED')"
    rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_findings
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL {clause}
            ORDER BY saving_high_minor DESC, confidence_bps DESC, title
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_finding_response(dict(row)) for row in rows]


async def set_finding_disposition(
    db,
    *,
    user: dict,
    finding_id: str,
    body: FinanceFindingDisposition,
) -> FinanceFindingResponse:
    row = await _authorised_row(
        db,
        user=user,
        table="finance_findings",
        record_id=finding_id,
    )
    if row["status"] == "EXPIRED":
        raise FinancePatternConflictError("Expired finding cannot be changed")
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_findings",
            finding_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_findings SET status = ?, updated_at = ? WHERE id = ?",
            (body.status, now, finding_id),
        )
    row.update(status=body.status, updated_at=now)
    return _finding_response(row)


async def list_material_questions(
    db,
    *,
    user: dict,
    space_id: str,
    include_resolved: bool = False,
) -> list[FinanceMaterialQuestionResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    clause = "" if include_resolved else "AND status = 'OPEN'"
    rows = await (
        await db.execute(
            f"""
            SELECT * FROM finance_material_questions
            WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL {clause}
            ORDER BY priority_minor DESC, created_at LIMIT 4
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [_question_response(dict(row)) for row in rows]


async def _resolve_question(
    db,
    *,
    user: dict,
    question_id: str,
    status: str,
    answer_text: str | None,
) -> FinanceMaterialQuestionResponse:
    row = await _authorised_row(
        db,
        user=user,
        table="finance_material_questions",
        record_id=question_id,
    )
    if row["status"] != "OPEN":
        raise FinancePatternConflictError("Material question has already been resolved")
    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_material_questions",
            question_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE finance_material_questions SET status = ?, answer_text = ?, "
            "resolved_at = ?, updated_at = ? WHERE id = ?",
            (status, answer_text, now, now, question_id),
        )
    row.update(status=status, answer_text=answer_text, resolved_at=now, updated_at=now)
    return _question_response(row)


async def _question_for_action(db, *, user: dict, question_id: str) -> dict:
    row = await _authorised_row(
        db,
        user=user,
        table="finance_material_questions",
        record_id=question_id,
    )
    if row["status"] != "OPEN":
        raise FinancePatternConflictError("Material question has already been resolved")
    return row


async def _create_confirmed_recurring_from_question(
    db,
    *,
    user: dict,
    question: dict,
    body: FinanceRecurringCorrection,
) -> FinanceRecurringSeriesResponse:
    if body.series_type != "SALARY":
        raise FinancePatternConflictError(
            "A salary question can only create a salary series; dismiss it if this is not salary"
        )
    if body.currency != question["currency"]:
        raise FinancePatternConflictError(
            "The salary currency must match the question currency"
        )
    existing = await (
        await db.execute(
            "SELECT id FROM finance_recurring_series WHERE space_id = ? "
            "AND family_id = ? AND detection_key = ? AND deleted_at IS NULL",
            (
                question["space_id"],
                user["family_id"],
                question["action_target_id"],
            ),
        )
    ).fetchone()
    if existing is not None:
        return await correct_recurring_series(
            db,
            user=user,
            series_id=existing["id"],
            body=body,
        )

    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_recurring_series
                (id, space_id, detection_key, name, series_type, interval_kind,
                 expected_minor, low_minor, high_minor, currency,
                 next_expected_date, working_day_adjustment, evidence_json,
                 confidence_bps, status, confirmed_at, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 10000,
                    'CONFIRMED', ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                question["space_id"],
                question["action_target_id"],
                body.name,
                body.series_type,
                body.interval_kind,
                body.expected_minor,
                body.low_minor,
                body.high_minor,
                body.currency,
                body.next_expected_date.isoformat(),
                body.working_day_adjustment,
                question["evidence_json"],
                now,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    row = await (
        await db.execute(
            "SELECT * FROM finance_recurring_series WHERE id = ?", (identifier,)
        )
    ).fetchone()
    return _recurring_response(dict(row))


async def _save_nursery_plan(
    db,
    *,
    user: dict,
    question: dict,
    body: FinanceMaterialQuestionCorrection,
) -> None:
    if body.nursery_expected_minor is None or body.nursery_due_dates is None:
        raise FinancePatternConflictError(
            "Nursery correction needs an amount and reviewed due dates"
        )
    due_dates = sorted(set(body.nursery_due_dates))
    statement = body.answer_text or (
        f"Nursery is expected to cost "
        f"{_format_money(body.nursery_expected_minor, question['currency'])} on "
        f"{', '.join(day.isoformat() for day in due_dates)}."
    )
    evidence_refs = json.loads(question["evidence_json"])
    latest = await (
        await db.execute(
            "SELECT id FROM finance_facts WHERE space_id = ? AND family_id = ? "
            "AND fact_key = 'nursery.schedule' AND status <> 'EXPIRED' "
            "AND deleted_at IS NULL ORDER BY version DESC LIMIT 1",
            (question["space_id"], user["family_id"]),
        )
    ).fetchone()
    if latest is None:
        fact = await create_fact(
            db,
            user=user,
            space_id=question["space_id"],
            body=FinanceFactCreate(
                fact_key="nursery.schedule",
                statement=statement,
                evidence_refs=evidence_refs,
            ),
        )
    else:
        fact = await update_fact(
            db,
            user=user,
            fact_id=latest["id"],
            body=FinanceFactUpdate(
                statement=statement,
                evidence_refs=evidence_refs,
            ),
        )
    await set_fact_status(db, user=user, fact_id=fact.id, status="CONFIRMED")

    marker = f"material-question:{question['id']}"
    commitment = await (
        await db.execute(
            "SELECT * FROM finance_commitments WHERE space_id = ? AND family_id = ? "
            "AND notes = ? AND deleted_at IS NULL LIMIT 1",
            (question["space_id"], user["family_id"], marker),
        )
    ).fetchone()
    if commitment is None:
        await create_commitment(
            db,
            user=user,
            space_id=question["space_id"],
            body=FinanceCommitmentCreate(
                name="Nursery",
                amount_mode="EXACT",
                exact_minor=body.nursery_expected_minor,
                currency=question["currency"],
                recurrence="CUSTOM",
                reviewed_dates=due_dates,
                priority="PROTECTED",
                notes=marker,
            ),
        )
        return

    now = _now()
    async with serialized_create(db):
        await save_history(
            db,
            "finance_commitments",
            commitment["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_commitments
            SET name = 'Nursery', amount_mode = 'EXACT', exact_minor = ?,
                expected_minor = NULL, low_minor = NULL, high_minor = NULL,
                currency = ?, recurrence = 'CUSTOM', reviewed_dates_json = ?,
                priority = 'PROTECTED', status = 'ACTIVE', updated_at = ?
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                body.nursery_expected_minor,
                question["currency"],
                _json([day.isoformat() for day in due_dates]),
                now,
                commitment["id"],
                question["space_id"],
                user["family_id"],
            ),
        )


async def confirm_material_question(
    db,
    *,
    user: dict,
    question_id: str,
    body: FinanceMaterialQuestionAnswer,
) -> FinanceMaterialQuestionResponse:
    question = await _question_for_action(
        db, user=user, question_id=question_id
    )
    action = question["action_kind"]
    if action == "CONFIRM_RECURRING":
        if not question["action_target_id"]:
            raise FinancePatternConflictError(
                "The linked recurring series is missing; correct this question instead"
            )
        await confirm_recurring_series(
            db,
            user=user,
            series_id=question["action_target_id"],
        )
    elif action == "ADD_CREDIT_CARD":
        card = await (
            await db.execute(
                "SELECT 1 FROM finance_accounts WHERE space_id = ? AND family_id = ? "
                "AND account_type = 'CREDIT_CARD' AND deleted_at IS NULL LIMIT 1",
                (question["space_id"], user["family_id"]),
            )
        ).fetchone()
        if card is None:
            raise FinancePatternConflictError(
                "Add a credit-card account using the question's next action; the question remains open"
            )
    elif action == "ITEMISE_PURCHASE":
        remaining = await (
            await db.execute(
                "SELECT 1 FROM finance_purchase_lines WHERE space_id = ? "
                "AND family_id = ? AND source_id = ? "
                "AND evidence_status = 'unitemised' AND line_net_minor >= 10000 "
                "AND deleted_at IS NULL LIMIT 1",
                (
                    question["space_id"],
                    user["family_id"],
                    question["action_target_id"],
                ),
            )
        ).fetchone()
        if remaining is not None:
            raise FinancePatternConflictError(
                "Review and itemise the linked purchase evidence first; the question remains open"
            )
    elif action == "IDENTIFY_SALARY":
        raise FinancePatternConflictError(
            "Identify the salary with a typed recurring correction; the question remains open"
        )
    else:
        raise FinancePatternConflictError(
            "Save the nursery amount and due dates with the correction route; the question remains open"
        )
    return await _resolve_question(
        db,
        user=user,
        question_id=question_id,
        status="CONFIRMED",
        answer_text=body.answer_text,
    )


async def correct_material_question(
    db,
    *,
    user: dict,
    question_id: str,
    body: FinanceMaterialQuestionCorrection,
) -> FinanceMaterialQuestionResponse:
    question = await _question_for_action(
        db, user=user, question_id=question_id
    )
    if question["action_kind"] in {"CONFIRM_RECURRING", "IDENTIFY_SALARY"}:
        if body.recurring is None:
            raise FinancePatternConflictError(
                "A complete recurring correction is required; the question remains open"
            )
        if question["action_kind"] == "CONFIRM_RECURRING":
            if not question["action_target_id"]:
                raise FinancePatternConflictError(
                    "The linked recurring series is missing; the question remains open"
                )
            await correct_recurring_series(
                db,
                user=user,
                series_id=question["action_target_id"],
                body=body.recurring,
            )
        else:
            await _create_confirmed_recurring_from_question(
                db,
                user=user,
                question=question,
                body=body.recurring,
            )
    elif question["action_kind"] == "SAVE_NURSERY_PLAN":
        await _save_nursery_plan(db, user=user, question=question, body=body)
    else:
        raise FinancePatternConflictError(
            "Complete the question's linked next action, then confirm it; the question remains open"
        )
    return await _resolve_question(
        db,
        user=user,
        question_id=question_id,
        status="CORRECTED",
        answer_text=body.answer_text,
    )


async def dismiss_material_question(
    db, *, user: dict, question_id: str
) -> FinanceMaterialQuestionResponse:
    return await _resolve_question(
        db,
        user=user,
        question_id=question_id,
        status="DISMISSED",
        answer_text=None,
    )


async def refresh_recurring_series(
    db,
    *,
    user: dict,
    space_id: str,
    as_of: date | None,
    currency: str,
) -> int:
    """Refresh the deterministic recurring layer without running opportunities."""
    await require_finance_space(db, user=user, space_id=space_id)
    if as_of is None:
        settings = await (
            await db.execute(
                "SELECT household_timezone FROM finance_settings "
                "WHERE family_id = ? AND deleted_at IS NULL LIMIT 1",
                (user["family_id"],),
            )
        ).fetchone()
        if settings is None:
            raise FinancePatternConflictError("Finance settings are not available")
        as_of = datetime.now(timezone.utc).astimezone(
            household_zone(settings["household_timezone"])
        ).date()
    currency = normalise_currency(currency)
    _, transactions = await _transactions(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
    )
    recurring = detect_recurring_series(
        transactions,
        allowed_space_ids=(space_id,),
        currency=currency,
        bank_holidays=_bank_holidays(transactions, as_of),
    )
    await _save_recurring(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        series=recurring,
    )
    return len(recurring)


async def scan_finance_patterns(
    db,
    *,
    user: dict,
    space_id: str,
    as_of: date | None,
    currency: str,
) -> FinancePatternScanResponse:
    """Scan only the caller-authorised saved ledger and purchase evidence."""
    await require_finance_space(db, user=user, space_id=space_id)
    if as_of is None:
        settings = await (
            await db.execute(
                "SELECT household_timezone FROM finance_settings "
                "WHERE family_id = ? AND deleted_at IS NULL LIMIT 1",
                (user["family_id"],),
            )
        ).fetchone()
        if settings is None:
            raise FinancePatternConflictError("Finance settings are not available")
        as_of = datetime.now(timezone.utc).astimezone(
            household_zone(settings["household_timezone"])
        ).date()
    currency = normalise_currency(currency)
    raw_transactions, transactions = await _transactions(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
    )
    recurring = detect_recurring_series(
        transactions,
        allowed_space_ids=(space_id,),
        currency=currency,
        bank_holidays=_bank_holidays(transactions, as_of),
    )
    await _save_recurring(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        series=recurring,
    )

    raw_lines, lines = await _purchase_lines(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
    )
    protected_tokens = await _protected_knowledge_tokens(
        db,
        user=user,
        space_id=space_id,
    )
    finding_drafts = [
        *_trend_findings(
            transactions,
            as_of=as_of,
            currency=currency,
            protected_tokens=protected_tokens,
        ),
        *_transaction_findings(
            transactions,
            recurring,
            as_of=as_of,
            currency=currency,
            protected_tokens=protected_tokens,
        ),
        *_line_findings(
            raw_lines,
            lines,
            currency=currency,
            protected_tokens=protected_tokens,
        ),
    ]
    data_dates = [transaction.day for transaction in transactions]
    data_dates.extend(date.fromisoformat(row["purchased_on"]) for row in raw_lines)
    data_through = max(data_dates, default=None)
    await _save_findings(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        as_of=data_through or as_of,
        drafts=finding_drafts,
    )
    question_drafts = await _question_drafts(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        raw_transactions=raw_transactions,
        detected_recurring=recurring,
    )
    await _save_questions(
        db,
        user=user,
        space_id=space_id,
        currency=currency,
        drafts=question_drafts,
    )

    recurring_rows = await list_recurring_series(
        db,
        user=user,
        space_id=space_id,
    )
    findings = await list_findings(db, user=user, space_id=space_id)
    questions = await list_material_questions(db, user=user, space_id=space_id)
    open_candidates = [
        OpportunityCandidate(
            id=finding.id,
            saving_low_minor=finding.saving_low_minor,
            saving_high_minor=finding.saving_high_minor,
            confidence=Fraction(finding.confidence_bps, 10_000),
            effort=finding.effort,
            evidence_ids=tuple(finding.evidence_refs),
            overlap_group=finding.overlap_group,
        )
        for finding in findings
        if finding.status == "OPEN" and finding.saving_high_minor > 0
    ]
    ranking = rank_opportunities(open_candidates)
    return FinancePatternScanResponse(
        space_id=space_id,
        data_through_date=data_through,
        recurring_series=recurring_rows,
        findings=findings,
        questions=questions,
        selected_finding_ids=[item.id for item in ranking.selected],
        suppressed_finding_ids=list(ranking.suppressed_ids),
        combined_saving_low_minor=ranking.combined_saving_low_minor,
        combined_saving_high_minor=ranking.combined_saving_high_minor,
    )
