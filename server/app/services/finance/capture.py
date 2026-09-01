"""Ephemeral natural-language Finance capture with reviewed, typed writes."""

from __future__ import annotations

import json
import hashlib
import re
import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Mapping

import httpx
from pydantic import TypeAdapter, ValidationError

from app.config import settings
from app.models.finance import (
    FinanceCommitmentCreate,
    FinanceFactCreate,
    FinanceGoalCreate,
    FinancePreferenceCreate,
    FinancePurchaseEvidenceIngest,
    FinancePurchaseMatchAllocation,
    FinancePurchaseMatchReview,
    FinanceSplitInput,
    NormalisedSourceTransaction,
)
from app.models.finance_capture import (
    FinanceCaptureConfirmRequest,
    FinanceCaptureConfirmResponse,
    FinanceCaptureContent,
    FinanceCaptureDraftResponse,
    FinanceCaptureInterpretRequest,
    FinanceCaptureInterpretResponse,
    FinanceCaptureLine,
    FinanceCaptureTargetOption,
    FinanceCashSpendCapture,
    FinanceCommitmentCapture,
    FinanceFactCapture,
    FinanceGoalCapture,
    FinanceHabitCapture,
    FinanceItemOutcomeCapture,
    FinancePreferenceCapture,
    FinancePurchaseDetailsCapture,
    FinancePurchasePlanCapture,
    FinanceTransactionCorrectionCapture,
)
from app.models.finance_coaching import (
    FinanceHabitCreate,
    FinancePurchaseProposalCreate,
)
from app.models.finance_understanding import FinancePurchaseLineAssessmentUpdate
from app.services.finance.ai import FinanceAnswer, FinanceAnswerClaim, run_finance_reasoning
from app.services.finance.ai.openai import _extract_output_text
from app.services.finance.coach import (
    FinanceLedgerQueryExecutor,
    build_finance_reasoning_adapter,
    finance_ai_consent_allows_space,
)
from app.services.finance.coaching import create_habit, create_purchase_proposal
from app.services.finance.dates import household_zone
from app.services.finance.foundation import require_finance_access, require_finance_space
from app.services.finance.ledger import import_source_transactions, replace_transaction_splits
from app.services.finance.planning import (
    create_commitment,
    create_fact,
    create_goal,
    create_preference,
    set_fact_status,
    set_preference_status,
)
from app.services.finance.purchase_evidence import ingest_purchase_evidence, review_purchase_match
from app.services.finance.understanding import update_purchase_line_assessment
from app.services.idempotency import serialized_create

_CONTENT_ADAPTER = TypeAdapter(FinanceCaptureContent)
_CONTENT_LIST_ADAPTER = TypeAdapter(list[FinanceCaptureContent])
_DRAFT_LIFETIME = timedelta(hours=1)
_CASH_PURCHASE_ONLY_TARGET = "cash-spend:purchase-only"
_MONTHS = {
    "january": 1,
    "february": 2,
    "march": 3,
    "april": 4,
    "may": 5,
    "june": 6,
    "july": 7,
    "august": 8,
    "september": 9,
    "october": 10,
    "november": 11,
    "december": 12,
}


class FinanceCaptureError(ValueError):
    """A capture draft could not be interpreted or confirmed safely."""


class FinanceCaptureNotFoundError(FinanceCaptureError):
    """A creator-bound active capture draft was not found."""


class FinanceCaptureConflictError(FinanceCaptureError):
    """A capture draft is expired, used, ambiguous, or no longer valid."""


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _confirmation_digest(body: FinanceCaptureConfirmRequest) -> str:
    canonical = {
        "content": body.content.model_dump(mode="json"),
        "selected_target_id": body.selected_target_id,
        "selected_account_id": body.selected_account_id,
    }
    return hashlib.sha256(_json(canonical).encode("utf-8")).hexdigest()


def _minor(text: str) -> int:
    cleaned = text.strip().replace(" ", "")
    if "," in cleaned and "." in cleaned:
        if cleaned.rfind(",") > cleaned.rfind("."):
            cleaned = cleaned.replace(".", "").replace(",", ".")
        else:
            cleaned = cleaned.replace(",", "")
    elif "," in cleaned:
        cleaned = (
            cleaned.replace(",", ".")
            if re.search(r",\d{1,2}$", cleaned)
            else cleaned.replace(",", "")
        )
    amount = Decimal(cleaned)
    if not amount.is_finite() or amount < 0 or amount.as_tuple().exponent < -2:
        raise FinanceCaptureError("Money must use pounds with at most two decimal places")
    return int(amount * 100)


def _knowledge_key(value: str, prefix: str) -> str:
    """Derive a collision-resistant identity in trusted code, never in model output."""
    normalized = " ".join(re.findall(r"[a-z0-9]+", value.casefold()))
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:10]
    stem = "_".join(normalized.split()[:5]) or "note"
    leading = f"{prefix}.capture."
    stem = stem[: 100 - len(leading) - len(digest) - 1]
    return f"{leading}{stem}.{digest}"


def _month_date(today: date, month_name: str, *, explicitly_next: bool = False) -> date:
    month = _MONTHS[month_name.casefold()]
    year = today.year + int(explicitly_next or month < today.month)
    return date(year, month, 1)


def _line_parts(text: str) -> list[tuple[int, str]]:
    matches = list(re.finditer(r"(?:about\s+|an?\s+)?£([\d,]+(?:\.\d{1,2})?)\s+", text, re.I))
    result = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        description = text[match.end() : end]
        description = re.sub(r"^[,;:\s]*(?:and\s+)?", "", description, flags=re.I)
        description = re.sub(r"[.;]+$", "", description.strip())
        result.append((_minor(match.group(1)), description))
    return result


async def _local_today(db, family_id: str) -> date:
    row = await (
        await db.execute(
            "SELECT household_timezone FROM finance_settings WHERE family_id = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (family_id,),
        )
    ).fetchone()
    if row is None:
        raise FinanceCaptureConflictError("Finance settings are not available")
    return _now().astimezone(household_zone(row["household_timezone"])).date()


def _is_question(text: str) -> bool:
    lowered = text.casefold().strip()
    if re.search(r"\bcan we buy\b", lowered):
        return False
    return text.rstrip().endswith("?") or lowered.startswith(
        ("why ", "what ", "how ", "when ", "where ", "which ", "are we ")
    )


def _builtin_interpret(text: str, *, today: date) -> list[FinanceCaptureContent]:
    lowered = text.casefold()
    money = re.search(r"£([\d,]+(?:\.\d{1,2})?)", text)

    german_cash = re.search(
        r"\b(?:ich\s+habe\s+)?(?:heute\s+)?([\d.]+(?:,\d{1,2})?)\s*€\s+bar\s+"
        r"(?:auf|bei|im)\s+(?:(?:dem|der|den)\s+)?(.+?)\s+ausgegeben\b",
        text,
        re.I,
    )
    if german_cash:
        total = _minor(german_cash.group(1))
        return [FinanceCashSpendCapture(
            kind="CASH_SPEND",
            merchant=german_cash.group(2).strip(" ."),
            spent_on=today,
            total_minor=total,
            currency="EUR",
            lines=[FinanceCaptureLine(name="Bargeldausgabe", amount_minor=total)],
        )]

    if re.search(r"\bsind\s+geschützte\s+ausgaben\b", lowered):
        return [FinancePreferenceCapture(
            kind="PREFERENCE",
            statement=text.rstrip("."),
            value_kind="PROTECTED",
        )]

    german_habit = re.search(
        r"\bvor\s+optionalen\s+einkäufen\s+über\s+([\d.]+(?:,\d{1,2})?)\s*€.*\bwarten",
        text,
        re.I,
    )
    if german_habit:
        return [FinanceHabitCapture(
            kind="HABIT",
            name="Vor optionalen Einkäufen warten",
            trigger=f"Vor optionalen Einkäufen über {german_habit.group(1)} €",
            minimum_line_minor=_minor(german_habit.group(1)),
            utilities=["optional"],
            start_date=today,
            review_date=today + timedelta(days=28),
            fallback="Erinnerung beenden, wenn sie mehr Aufwand als Nutzen bringt",
        )]

    cash = re.search(
        r"\bspent\s+£([\d,]+(?:\.\d{1,2})?)\s+cash\s+at\s+(?:the\s+)?([^:.;]+)",
        text,
        re.I,
    )
    if cash:
        total = _minor(cash.group(1))
        detail = text.split(":", 1)[1] if ":" in text else ""
        lines = [
            FinanceCaptureLine(name=description, amount_minor=amount)
            for amount, description in _line_parts(detail)
        ]
        known = sum(line.amount_minor for line in lines)
        return [
            FinanceCashSpendCapture(
                kind="CASH_SPEND",
                merchant=cash.group(2).strip(),
                spent_on=today,
                total_minor=total,
                lines=lines or [FinanceCaptureLine(name="Cash spend", amount_minor=total)],
                unassigned_remainder_minor=max(0, total - known) if lines else 0,
                uncertainties=["Check the spending date"] if "today" not in lowered else [],
            )
        ]

    payment = re.search(
        r"£([\d,]+(?:\.\d{1,2})?)\s+([A-Za-z][A-Za-z '&-]+?)\s+(?:payment|shop)\s+(?:contained|included)\s+",
        text,
        re.I,
    )
    if payment:
        total = _minor(payment.group(1))
        merchant = payment.group(2).strip()
        detail = text[payment.end() :]
        if "treat that as" in lowered or "rather than" in lowered:
            first = _line_parts(detail)[0] if _line_parts(detail) else None
            if first:
                special_amount, special_text = first
                category_match = re.search(r"treat that as (?:a |an )?([^.;]+?) cost", text, re.I)
                category = category_match.group(1).strip().title() if category_match else "Corrected"
                return [
                    FinanceTransactionCorrectionCapture(
                        kind="TRANSACTION_CORRECTION",
                        merchant_hint=merchant,
                        payment_amount_minor=total,
                        splits=[
                            FinanceCaptureLine(
                                name=special_text.split(";")[0].strip(),
                                amount_minor=special_amount,
                                category_name=category,
                            ),
                            FinanceCaptureLine(
                                name=f"Remaining {merchant} payment",
                                amount_minor=total - special_amount,
                                category_name="Food shopping" if "grocer" in lowered else None,
                            ),
                        ],
                        uncertainties=["Select the matching payment and check the categories"],
                    )
                ]
        parsed_lines = []
        for amount, description in _line_parts(detail):
            beneficiary_match = re.search(r"\bfor\s+([A-Z][A-Za-z-]+)", description)
            regretted = bool(re.search(r"\b(?:regret|regretted)\b", description, re.I))
            clean = re.sub(r"\s+I\s+regret(?:ted)?\b.*$", "", description, flags=re.I)
            parsed_lines.append(
                FinanceCaptureLine(
                    name=clean.strip(" ,and"),
                    amount_minor=amount,
                    beneficiary=beneficiary_match.group(1) if beneficiary_match else None,
                    purpose="birthday" if "birthday" in description.casefold() else None,
                    outcome_state="regretted" if regretted else None,
                )
            )
        known = sum(line.amount_minor for line in parsed_lines)
        return [
            FinancePurchaseDetailsCapture(
                kind="PURCHASE_DETAILS",
                merchant=merchant,
                payment_amount_minor=total,
                lines=parsed_lines,
                unassigned_remainder_minor=max(0, total - known),
                uncertainties=["Select the matching payment and check the purchase date"],
            )
        ]

    commitment = re.search(
        r"(.+?)\s+is due in\s+(January|February|March|April|May|June|July|August|September|October|November|December).*?£([\d,]+(?:\.\d{1,2})?)",
        text,
        re.I,
    )
    if commitment:
        approximate = bool(re.search(r"\b(?:probably|about|roughly|around)\b", text, re.I))
        amount = _minor(commitment.group(3))
        return [
            FinanceCommitmentCapture(
                kind="COMMITMENT",
                name=commitment.group(1).strip().capitalize(),
                amount_mode="FORECAST" if approximate else "EXACT",
                exact_minor=None if approximate else amount,
                expected_minor=amount if approximate else None,
                recurrence="ANNUAL",
                reviewed_date=_month_date(today, commitment.group(2)),
                uncertainties=["Check the exact due day"] + (["Amount is approximate"] if approximate else []),
            )
        ]

    goal = re.search(
        r"\bwant\s+(?:a\s+)?£([\d,]+(?:\.\d{1,2})?)\s+(.+?)\s+(?:by\s+)?(next\s+)?(January|February|March|April|May|June|July|August|September|October|November|December)",
        text,
        re.I,
    )
    if goal:
        return [
            FinanceGoalCapture(
                kind="GOAL",
                name=goal.group(2).strip().capitalize(),
                target_minor=_minor(goal.group(1)),
                deadline=_month_date(today, goal.group(4), explicitly_next=bool(goal.group(3))),
                uncertainties=["Check the exact deadline day"],
            )
        ]

    if re.search(r"\b(?:do not|don't|never)\s+(?:cut|reduce)\b", lowered):
        return [
            FinancePreferenceCapture(
                kind="PREFERENCE",
                statement=text.rstrip("."),
                value_kind="PROTECTED",
            )
        ]

    habit = re.search(
        r"(?:optional\s+)?(.+?)\s+over\s+£([\d,]+(?:\.\d{1,2})?).*?\b(?:wait|remind me to wait)\b",
        text,
        re.I,
    )
    if habit:
        return [
            FinanceHabitCapture(
                kind="HABIT",
                name="Wait before optional online purchases",
                trigger=f"Before {habit.group(1).strip()} over £{habit.group(2)}",
                minimum_line_minor=_minor(habit.group(2)),
                utilities=["optional"],
                start_date=today,
                review_date=today + timedelta(days=28),
                fallback="Stop the reminder if it adds more friction than value",
            )
        ]

    purchase_plan = re.search(
        r"\bcan we buy (?:this\s+)?£([\d,]+(?:\.\d{1,2})?)\s+(.+?)\s+in\s+(January|February|March|April|May|June|July|August|September|October|November|December)",
        text,
        re.I,
    )
    if purchase_plan:
        amount = _minor(purchase_plan.group(1))
        return [
            FinancePurchasePlanCapture(
                kind="PURCHASE_PLAN",
                name=purchase_plan.group(2).strip().capitalize(),
                amount_low_minor=amount,
                amount_high_minor=amount,
                desired_date=_month_date(today, purchase_plan.group(3)),
                uncertainties=["Select the payment account and check the exact purchase date"],
            )
        ]

    outcome = re.search(
        r"(?:I\s+)?(returned|regret(?:ted)?|never used|valued|loved)\s+(?:the\s+)?(.+)",
        text,
        re.I,
    )
    if outcome:
        state = {
            "returned": "returned",
            "regret": "regretted",
            "regretted": "regretted",
            "never used": "unused",
            "valued": "valued",
            "loved": "valued",
        }[outcome.group(1).casefold()]
        return [
            FinanceItemOutcomeCapture(
                kind="ITEM_OUTCOME",
                item_hint=outcome.group(2).strip(" ."),
                outcome_state=state,
                correction_reason=text.rstrip("."),
                uncertainties=["Select the matching purchase item"],
            )
        ]

    if money and re.search(r"\b(?:drop|rise|change|from|should)\b", lowered):
        return [
            FinanceFactCapture(
                kind="FACT",
                statement=text.rstrip("."),
                uncertainties=["Check when this starts"] if not re.search(r"\d{4}", text) else [],
            )
        ]
    return [
        FinanceFactCapture(
            kind="FACT",
            statement=text.rstrip("."),
            uncertainties=["Check that this should be saved as a Finance fact"],
        )
    ]


def _strict_capture_schema() -> dict[str, object]:
    schema = _CONTENT_LIST_ADAPTER.json_schema()

    def close(value):
        if isinstance(value, dict):
            if value.get("type") == "object" or "properties" in value:
                value["additionalProperties"] = False
                value["required"] = list(value.get("properties", {}).keys())
            for nested in value.values():
                close(nested)
        elif isinstance(value, list):
            for nested in value:
                close(nested)

    close(schema)
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {"drafts": schema},
        "required": ["drafts"],
        "$defs": schema.pop("$defs", {}),
    }


async def _openai_interpret(
    db,
    *,
    user: dict,
    space_id: str,
    text: str,
    conversation: list[Mapping[str, str]],
    today: date,
) -> list[FinanceCaptureContent] | None:
    if settings.finance_ai_provider != "openai" or not settings.finance_openai_api_key.strip():
        return None
    if not await finance_ai_consent_allows_space(
        db,
        user=user,
        space_id=space_id,
    ):
        return None
    history = "\n".join(f"{turn['role']}: {turn['text']}" for turn in conversation[-8:])
    prompt = f"""Interpret the explicit Finance entry into zero or more typed review drafts.
Today in the saved household timezone is {today.isoformat()}.
Never emit any ID, person identifier, link, URL, database command, secret, credential,
provider field, payment instruction, transfer, trade, deletion, or executable text.
Amounts are exact integer minor units. Dates are ISO dates. Do not invent an amount,
date, item, beneficiary, category, or remainder. Put consequential ambiguity in
uncertainties. Purchase and split lines plus unassigned_remainder_minor must reconcile
exactly to their displayed total. Conversation is temporary context only.

Temporary screen conversation:
{history or '(none)'}

Explicit entry:
{text}"""
    payload = {
        "model": settings.finance_openai_model,
        "store": False,
        "input": [
            {
                "role": "system",
                "content": (
                    "You create typed HausKlar Finance review drafts only. "
                    "You have no tools and cannot mutate or retrieve data."
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "hausklar_finance_capture",
                "strict": True,
                "schema": _strict_capture_schema(),
            }
        },
    }
    try:
        async with httpx.AsyncClient(timeout=settings.finance_ai_timeout_seconds) as client:
            response = await client.post(
                "https://api.openai.com/v1/responses",
                headers={
                    "Authorization": f"Bearer {settings.finance_openai_api_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
            response.raise_for_status()
        decoded = json.loads(_extract_output_text(response.json()))
        return _CONTENT_LIST_ADAPTER.validate_python(decoded["drafts"])
    except (httpx.HTTPError, KeyError, TypeError, ValueError, ValidationError):
        return None


def _title(content: FinanceCaptureContent) -> str:
    names = {
        "FACT": "Review this Finance fact",
        "PREFERENCE": "Review this preference",
        "TRANSACTION_CORRECTION": "Review this payment correction",
        "PURCHASE_DETAILS": "Review these purchase details",
        "ITEM_OUTCOME": "Review this item outcome",
        "CASH_SPEND": "Review this cash spend",
        "COMMITMENT": "Review this commitment",
        "GOAL": "Review this goal",
        "HABIT": "Review this habit",
        "PURCHASE_PLAN": "Review this planned purchase",
    }
    return names[content.kind]


def _normalised(value: str) -> str:
    return " ".join(re.findall(r"[A-Z0-9]+", value.upper()))


async def _transaction_options(
    db, *, user: dict, space_id: str, amount_minor: int, currency: str,
    merchant: str, on_date: date | None,
) -> list[FinanceCaptureTargetOption]:
    where = [
        "space_id = ?", "family_id = ?", "abs(amount_minor) = ?", "currency = ?",
        "state IN ('PENDING','POSTED')", "deleted_at IS NULL",
    ]
    params: list[object] = [space_id, user["family_id"], amount_minor, currency]
    if on_date:
        where.append("canonical_date = ?")
        params.append(on_date.isoformat())
    rows = await (
        await db.execute(
            f"SELECT id, canonical_date, amount_minor, currency, description, merchant_text "
            f"FROM finance_transactions WHERE {' AND '.join(where)} "
            "ORDER BY canonical_date DESC, id LIMIT 20",
            params,
        )
    ).fetchall()
    hint = _normalised(merchant)
    matches = [
        row for row in rows
        if hint in _normalised(row["merchant_text"] or row["description"])
        or _normalised(row["merchant_text"] or row["description"]) in hint
    ]
    return [
        FinanceCaptureTargetOption(
            id=row["id"], kind="TRANSACTION",
            label=row["merchant_text"] or row["description"],
            date=date.fromisoformat(row["canonical_date"]),
            amount_minor=abs(row["amount_minor"]), currency=row["currency"],
        )
        for row in matches[:5]
    ]


async def _account_options(
    db, *, user: dict, space_id: str, currency: str, cash_only: bool,
) -> list[FinanceCaptureTargetOption]:
    type_clause = "account_type = 'CASH'" if cash_only else "account_type IN ('CURRENT','CASH')"
    rows = await (
        await db.execute(
            f"SELECT id, label, currency FROM finance_accounts WHERE space_id = ? "
            f"AND family_id = ? AND currency = ? AND {type_clause} "
            "AND purpose = 'OPERATING_CURRENT' AND include_in_cashflow = 1 "
            "AND deleted_at IS NULL ORDER BY primary_spending_account DESC, label, id",
            (space_id, user["family_id"], currency),
        )
    ).fetchall()
    return [
        FinanceCaptureTargetOption(
            id=row["id"], kind="ACCOUNT", label=row["label"], currency=row["currency"]
        )
        for row in rows[:10]
    ]


async def _target_options(
    db, *, user: dict, space_id: str, content: FinanceCaptureContent, context,
) -> list[FinanceCaptureTargetOption]:
    def selected_first(options, selected_id):
        if not selected_id:
            return options
        return sorted(options, key=lambda item: item.id != selected_id)

    if isinstance(content, FinanceTransactionCorrectionCapture):
        options = await _transaction_options(
            db, user=user, space_id=space_id, amount_minor=content.payment_amount_minor,
            currency=content.currency, merchant=content.merchant_hint,
            on_date=content.transaction_date,
        )
        return selected_first(options, context.selected_transaction_id)
    if isinstance(content, FinancePurchaseDetailsCapture):
        if context.selected_purchase_id:
            row = await (
                await db.execute(
                    "SELECT id, merchant_name, purchased_on, final_total_minor, currency "
                    "FROM finance_purchase_records WHERE id = ? AND space_id = ? "
                    "AND family_id = ? AND deleted_at IS NULL AND superseded_by_id IS NULL",
                    (context.selected_purchase_id, space_id, user["family_id"]),
                )
            ).fetchone()
            if row:
                return [FinanceCaptureTargetOption(
                    id=row["id"], kind="PURCHASE", label=row["merchant_name"],
                    date=date.fromisoformat(row["purchased_on"]),
                    amount_minor=row["final_total_minor"], currency=row["currency"],
                )]
        options = await _transaction_options(
            db, user=user, space_id=space_id, amount_minor=content.payment_amount_minor,
            currency=content.currency, merchant=content.merchant,
            on_date=content.purchased_on,
        )
        return selected_first(options, context.selected_transaction_id)
    if isinstance(content, FinanceItemOutcomeCapture):
        if context.selected_purchase_line_id:
            selected = await (
                await db.execute(
                    "SELECT line.id, line.raw_description, line.line_net_minor, "
                    "purchase.purchased_on, purchase.currency FROM finance_purchase_lines line "
                    "JOIN finance_purchase_records purchase ON purchase.id = line.purchase_id "
                    "AND purchase.space_id = line.space_id "
                    "AND purchase.family_id = line.family_id "
                    "WHERE line.id = ? AND line.space_id = ? AND line.family_id = ? "
                    "AND line.deleted_at IS NULL AND purchase.deleted_at IS NULL",
                    (context.selected_purchase_line_id, space_id, user["family_id"]),
                )
            ).fetchone()
            rows = [selected] if selected else []
        else:
            rows = await (
                await db.execute(
                    "SELECT line.id, line.raw_description, line.line_net_minor, "
                    "purchase.purchased_on, purchase.currency FROM finance_purchase_lines line "
                    "JOIN finance_purchase_records purchase ON purchase.id = line.purchase_id "
                    "AND purchase.space_id = line.space_id "
                    "AND purchase.family_id = line.family_id "
                    "WHERE line.space_id = ? AND line.family_id = ? AND line.deleted_at IS NULL "
                    "AND purchase.deleted_at IS NULL ORDER BY purchase.purchased_on DESC LIMIT 50",
                    (space_id, user["family_id"]),
                )
            ).fetchall()
            hint = _normalised(content.item_hint)
            rows = [row for row in rows if hint in _normalised(row["raw_description"])]
        return [
            FinanceCaptureTargetOption(
                id=row["id"], kind="PURCHASE_LINE", label=row["raw_description"],
                date=date.fromisoformat(row["purchased_on"]),
                amount_minor=row["line_net_minor"], currency=row["currency"],
            )
            for row in rows[:5]
        ]
    if isinstance(content, FinanceCashSpendCapture):
        options = await _account_options(
            db, user=user, space_id=space_id, currency=content.currency, cash_only=True
        )
        if options:
            # account_hint is untrusted descriptive text. Only a selected account
            # from this server-filtered set can influence confirmation.
            return selected_first(options, context.selected_account_id)
        return [FinanceCaptureTargetOption(
            id=_CASH_PURCHASE_ONLY_TARGET,
            kind="PURCHASE_ONLY",
            label="Save purchase only (cash tender; no cashflow entry)",
            currency=content.currency,
        )]
    if isinstance(content, FinancePurchasePlanCapture):
        options = await _account_options(
            db, user=user, space_id=space_id, currency=content.currency, cash_only=False
        )
        return selected_first(options, context.selected_account_id)
    if isinstance(content, FinanceCommitmentCapture):
        space = await require_finance_space(db, user=user, space_id=space_id)
        if space["kind"] != "household":
            return []
        rows = await (
            await db.execute(
                """
                SELECT id, name FROM users
                WHERE family_id = ? AND deleted_at IS NULL
                ORDER BY priority DESC, name COLLATE NOCASE, id
                """,
                (user["family_id"],),
            )
        ).fetchall()
        return [
            FinanceCaptureTargetOption(id=row["id"], kind="ADULT", label=row["name"])
            for row in rows
        ]
    return []


async def _category_options(db, *, user: dict, space_id: str) -> list[str]:
    rows = await (
        await db.execute(
            "SELECT name FROM finance_categories WHERE space_id = ? AND family_id = ? "
            "AND deleted_at IS NULL ORDER BY name COLLATE NOCASE, id",
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [row["name"] for row in rows]


def _safe_category_content(
    content: FinanceCaptureContent, category_options: list[str]
) -> FinanceCaptureContent:
    if not isinstance(content, FinanceTransactionCorrectionCapture):
        return content
    saved = {name.casefold(): name for name in category_options}
    values = content.model_dump(mode="json")
    removed = False
    for line in values["splits"]:
        requested = line.get("category_name")
        if requested and requested.casefold() in saved:
            line["category_name"] = saved[requested.casefold()]
        elif requested:
            # Null is the explicit, confirmable no-category option. Preserve
            # what the user meant in the editable line label, not as a fake ID.
            line["category_name"] = None
            removed = True
    if removed:
        values["uncertainties"] = [
            *values.get("uncertainties", []),
            "Choose a saved category or leave the line uncategorised",
        ]
    return _CONTENT_ADAPTER.validate_python(values)


async def _answer_question(
    db, *, user: dict, space_id: str, question: str,
    conversation: list[Mapping[str, str]] | None = None,
) -> FinanceAnswer:
    adapter = None
    try:
        if await finance_ai_consent_allows_space(
            db,
            user=user,
            space_id=space_id,
        ):
            adapter = build_finance_reasoning_adapter()
            return await run_finance_reasoning(
                adapter=adapter,
                executor=FinanceLedgerQueryExecutor(db),
                question=question,
                conversation=conversation or [],
                principal=user,
                space_ids=(space_id,),
            )
    except Exception:
        # The deterministic, read-only answer below remains useful when the
        # temporary provider is unavailable; no transcript or failure detail is stored.
        pass
    finally:
        close_adapter = getattr(adapter, "aclose", None)
        if close_adapter is not None:
            try:
                await close_adapter()
            except Exception:
                # Cleanup cannot make the deterministic fallback unavailable.
                pass
    report = await (
        await db.execute(
            "SELECT id, explanation, data_through_at FROM finance_coaching_reports "
            "WHERE member_user_id = ? AND space_id = ? AND family_id = ? "
            "AND deleted_at IS NULL ORDER BY local_date DESC, created_at DESC LIMIT 1",
            (user["id"], space_id, user["family_id"]),
        )
    ).fetchone()
    if report:
        has_data_through = report["data_through_at"] is not None
        return FinanceAnswer(
            kind="answer", headline="Your latest saved Finance guide",
            answer=report["explanation"],
            answer_mode="DATED_EXACT" if has_data_through else "PARTIAL",
            data_through=report["data_through_at"],
            claims=[FinanceAnswerClaim(
                text="This answer comes from the latest saved Finance report.",
                evidence_ids=[f"report:{report['id']}"],
            )],
            estimates=[], suggested_actions=["Open the Finance Coach report for its evidence"],
            analysis_view_id=None, questions=[],
        )
    return FinanceAnswer(
        kind="partial", headline="I couldn't answer that just now",
        answer="Your Finance overview and transactions are still available.",
        answer_mode="PARTIAL", data_through=None, claims=[], estimates=[],
        suggested_actions=["Open Finance overview"],
        analysis_view_id=None, questions=[],
    )


async def interpret_finance_capture(
    db, *, user: dict, body: FinanceCaptureInterpretRequest
) -> FinanceCaptureInterpretResponse:
    require_finance_access(user)
    space = await require_finance_space(db, user=user, space_id=body.space_id)
    today = await _local_today(db, user["family_id"])
    if _is_question(body.text):
        return FinanceCaptureInterpretResponse(
            mode="ANSWER",
            answer=await _answer_question(
                db,
                user=user,
                space_id=body.space_id,
                question=body.text,
                conversation=[turn.model_dump() for turn in body.conversation],
            ),
        )
    content_items = await _openai_interpret(
        db, user=user, space_id=body.space_id, text=body.text,
        conversation=[turn.model_dump() for turn in body.conversation], today=today,
    )
    if not content_items:
        try:
            content_items = _builtin_interpret(body.text, today=today)
        except (ValidationError, ValueError):
            content_items = []
    if not content_items:
        return FinanceCaptureInterpretResponse(
            mode="CLARIFY", message="I could not make a safe editable Finance draft from that."
        )
    responses = []
    now = _now()
    expires_at = now + _DRAFT_LIFETIME
    for content in content_items[:5]:
        if isinstance(content, FinanceCommitmentCapture):
            # A model may describe reminder intent, but only the adult can pick
            # who gets a task. Personal dates never leave Finance.
            content = content.model_copy(update={
                "show_in_calendar": space["kind"] == "household",
                "show_in_tasks": False,
                "responsible_user_id": None,
            })
        categories = (
            await _category_options(db, user=user, space_id=body.space_id)
            if isinstance(content, FinanceTransactionCorrectionCapture)
            else []
        )
        content = _safe_category_content(content, categories)
        options = await _target_options(
            db, user=user, space_id=body.space_id, content=content, context=body.context
        )
        identifier = str(uuid.uuid4())
        async with serialized_create(db):
            await db.execute(
                """INSERT INTO finance_capture_drafts
                   (id, space_id, creator_user_id, draft_kind, payload_json,
                    target_options_json, status, expires_at, family_id,
                    created_at, updated_at, created_by)
                   VALUES (?, ?, ?, ?, ?, ?, 'PENDING', ?, ?, ?, ?, ?)""",
                (
                    identifier, body.space_id, user["id"], content.kind,
                    _json(content.model_dump(mode="json")),
                    _json([item.model_dump(mode="json") for item in options]),
                    expires_at.isoformat(), user["family_id"], now.isoformat(),
                    now.isoformat(), user["id"],
                ),
            )
        responses.append(FinanceCaptureDraftResponse(
            id=identifier, space_id=body.space_id, content=content,
            title=_title(content), target_options=options,
            category_options=categories,
            expires_at=expires_at.isoformat(),
        ))
    return FinanceCaptureInterpretResponse(mode="REVIEW", drafts=responses)


async def _draft_row(db, *, user: dict, draft_id: str) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM finance_capture_drafts WHERE id = ? AND creator_user_id = ? "
            "AND family_id = ? AND deleted_at IS NULL",
            (draft_id, user["id"], user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceCaptureNotFoundError("Finance review card not found")
    await require_finance_space(db, user=user, space_id=row["space_id"])
    return dict(row)


async def _transaction_for_confirmation(
    db, *, user: dict, space_id: str, target_id: str, amount_minor: int,
    currency: str, on_date: date | None,
) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM finance_transactions WHERE id = ? AND space_id = ? "
            "AND family_id = ? AND state IN ('PENDING','POSTED') AND deleted_at IS NULL",
            (target_id, space_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceCaptureNotFoundError("Selected Finance payment not found")
    if abs(row["amount_minor"]) != amount_minor or row["currency"] != currency:
        raise FinanceCaptureConflictError("The selected payment no longer matches the reviewed amount")
    if on_date and row["canonical_date"] != on_date.isoformat():
        raise FinanceCaptureConflictError("The selected payment date does not match the review card")
    return dict(row)


async def _category_id(db, *, family_id: str, space_id: str, name: str | None) -> str | None:
    if not name:
        return None
    rows = await (
        await db.execute(
            "SELECT id, name FROM finance_categories WHERE space_id = ? AND family_id = ? "
            "AND deleted_at IS NULL",
            (space_id, family_id),
        )
    ).fetchall()
    matches = [row["id"] for row in rows if row["name"].casefold() == name.casefold()]
    if len(matches) != 1:
        raise FinanceCaptureConflictError(
            f"Select one saved category for ‘{name}’ before confirming"
        )
    return matches[0]


async def _ingest_reviewed_purchase(
    db, *, user: dict, space_id: str, draft_id: str,
    content: FinancePurchaseDetailsCapture | FinanceCashSpendCapture,
    purchased_on: date, corrects_source_id: str | None = None,
    selected_transaction_id: str | None = None, cash_tender: bool = False,
):
    total = content.payment_amount_minor if isinstance(content, FinancePurchaseDetailsCapture) else content.total_minor
    line_rows = [
        {
            "line_reference": f"capture:{draft_id}:line:{index}",
            "description": line.name,
            "kind": "product",
            "quantity": "1",
            "gross_minor": line.amount_minor,
            "net_minor": line.amount_minor,
            "discount_minor": 0,
        }
        for index, line in enumerate(content.lines)
    ]
    result = await ingest_purchase_evidence(
        db,
        user=user,
        space_id=space_id,
        body=FinancePurchaseEvidenceIngest(
            external_source_id=f"capture:{draft_id}", adapter="natural_language",
            reviewed=True, corrects_source_id=corrects_source_id,
            payload={
                "source_id": f"capture:{draft_id}",
                "purchase_reference": f"capture:{draft_id}",
                "merchant": content.merchant,
                "purchased_at": purchased_on.isoformat(),
                "currency": content.currency,
                "lines": line_rows,
                "final_total_minor": total,
                "confidence_bps": 10_000,
                "tenders": ([{
                    "tender_reference": f"capture:{draft_id}:cash",
                    "kind": "cash",
                    "amount_minor": total,
                }] if cash_tender else []),
            },
        ),
    )
    if result.purchase and selected_transaction_id:
        reviewed = await review_purchase_match(
            db,
            user=user,
            purchase_id=result.purchase.id,
            body=FinancePurchaseMatchReview(
                reviewed=True,
                allocations=[FinancePurchaseMatchAllocation(
                    transaction_id=selected_transaction_id,
                    allocated_minor=total,
                )],
            ),
        )
        result.purchase = reviewed
    if result.purchase:
        for line_response, line in zip(result.purchase.lines, content.lines, strict=False):
            fields = {
                "normalized_item_name": line.normalized_item,
                "beneficiary": line.beneficiary,
                "purpose": line.purpose,
                "utility": line.utility,
                "outcome_state": line.outcome_state,
                "correction_reason": "Confirmed from Finance text capture",
            }
            selected = {key: value for key, value in fields.items() if value is not None}
            if len(selected) > 1:  # correction_reason alone is not a material assessment
                await update_purchase_line_assessment(
                    db, user=user, line_id=line_response.id,
                    body=FinancePurchaseLineAssessmentUpdate(**selected),
                )
    return result


async def _apply_content(
    db, *, user: dict, space_id: str, draft_id: str,
    body: FinanceCaptureConfirmRequest,
) -> tuple[str, str, dict[str, object]]:
    content = body.content
    if isinstance(content, FinanceFactCapture):
        created = await create_fact(
            db, user=user, space_id=space_id,
            body=FinanceFactCreate(
                fact_key=_knowledge_key(content.statement, "fact"),
                statement=content.statement,
                evidence_refs=[],
            ),
        )
        result = await set_fact_status(
            db, user=user, fact_id=created.id, status="CONFIRMED"
        )
        return "FACT", result.id, result.model_dump(mode="json")
    if isinstance(content, FinancePreferenceCapture):
        created = await create_preference(
            db, user=user, space_id=space_id,
            body=FinancePreferenceCreate(
                preference_key=_knowledge_key(content.statement, "preference"),
                statement=content.statement,
                value_kind=content.value_kind, evidence_refs=[],
            ),
        )
        result = await set_preference_status(
            db, user=user, preference_id=created.id, status="CONFIRMED"
        )
        return "PREFERENCE", result.id, result.model_dump(mode="json")
    if isinstance(content, FinanceTransactionCorrectionCapture):
        if not body.selected_target_id:
            raise FinanceCaptureConflictError("Select the payment this correction belongs to")
        transaction = await _transaction_for_confirmation(
            db, user=user, space_id=space_id, target_id=body.selected_target_id,
            amount_minor=content.payment_amount_minor, currency=content.currency,
            on_date=content.transaction_date,
        )
        sign = -1 if transaction["amount_minor"] < 0 else 1
        splits = [
            FinanceSplitInput(
                amount_minor=sign * line.amount_minor,
                category_id=await _category_id(
                    db, family_id=user["family_id"], space_id=space_id,
                    name=line.category_name,
                ),
                label=line.name,
            )
            for line in content.splits
        ]
        if content.unassigned_remainder_minor:
            splits.append(FinanceSplitInput(
                amount_minor=sign * content.unassigned_remainder_minor,
                label="Unassigned remainder",
            ))
        result = await replace_transaction_splits(
            db, user=user, transaction_id=transaction["id"], splits=splits
        )
        return "TRANSACTION_SPLITS", transaction["id"], {
            "transaction_id": transaction["id"],
            "splits": [item.model_dump(mode="json") for item in result],
        }
    if isinstance(content, FinancePurchaseDetailsCapture):
        purchased_on = content.purchased_on
        corrects_source_id = None
        selected_transaction_id = None
        if body.selected_target_id:
            purchase = await (
                await db.execute(
                    "SELECT id, source_id, purchased_on, final_total_minor, currency "
                    "FROM finance_purchase_records WHERE id = ? AND space_id = ? "
                    "AND family_id = ? AND superseded_by_id IS NULL AND deleted_at IS NULL",
                    (body.selected_target_id, space_id, user["family_id"]),
                )
            ).fetchone()
            if purchase:
                if purchase["final_total_minor"] != content.payment_amount_minor or purchase["currency"] != content.currency:
                    raise FinanceCaptureConflictError("The selected purchase no longer matches the reviewed amount")
                if purchased_on and purchase["purchased_on"] != purchased_on.isoformat():
                    raise FinanceCaptureConflictError("The selected purchase date does not match the review card")
                purchased_on = purchased_on or date.fromisoformat(purchase["purchased_on"])
                corrects_source_id = purchase["source_id"]
            else:
                transaction = await _transaction_for_confirmation(
                    db, user=user, space_id=space_id, target_id=body.selected_target_id,
                    amount_minor=content.payment_amount_minor, currency=content.currency,
                    on_date=content.purchased_on,
                )
                purchased_on = purchased_on or date.fromisoformat(transaction["canonical_date"])
                selected_transaction_id = transaction["id"]
        if purchased_on is None:
            raise FinanceCaptureConflictError("Check the purchase date before confirming")
        result = await _ingest_reviewed_purchase(
            db, user=user, space_id=space_id, draft_id=draft_id, content=content,
            purchased_on=purchased_on, corrects_source_id=corrects_source_id,
            selected_transaction_id=selected_transaction_id,
        )
        action_id = result.purchase.id if result.purchase else result.source.id
        return "PURCHASE_DETAILS", action_id, result.model_dump(mode="json")
    if isinstance(content, FinanceItemOutcomeCapture):
        if not body.selected_target_id:
            raise FinanceCaptureConflictError("Select the purchase item this outcome belongs to")
        line = await (
            await db.execute(
                "SELECT line.id, purchase.purchased_on FROM finance_purchase_lines line "
                "JOIN finance_purchase_records purchase ON purchase.id = line.purchase_id "
                "AND purchase.space_id = line.space_id "
                "AND purchase.family_id = line.family_id "
                "WHERE line.id = ? AND line.space_id = ? AND line.family_id = ? "
                "AND line.deleted_at IS NULL AND purchase.deleted_at IS NULL",
                (body.selected_target_id, space_id, user["family_id"]),
            )
        ).fetchone()
        if line is None:
            raise FinanceCaptureNotFoundError("Selected purchase item not found")
        if content.purchased_on and line["purchased_on"] != content.purchased_on.isoformat():
            raise FinanceCaptureConflictError("The selected item date does not match the review card")
        result = await update_purchase_line_assessment(
            db, user=user, line_id=line["id"],
            body=FinancePurchaseLineAssessmentUpdate(
                outcome_state=content.outcome_state,
                correction_reason=content.correction_reason,
            ),
        )
        return "ITEM_OUTCOME", result.id, result.model_dump(mode="json")
    if isinstance(content, FinanceCashSpendCapture):
        if body.selected_account_id and body.selected_target_id:
            raise FinanceCaptureConflictError("Choose one cash-spend posting option")
        if body.selected_target_id == _CASH_PURCHASE_ONLY_TARGET:
            purchase = await _ingest_reviewed_purchase(
                db, user=user, space_id=space_id, draft_id=draft_id, content=content,
                purchased_on=content.spent_on, cash_tender=True,
            )
            action_id = purchase.purchase.id if purchase.purchase else purchase.source.id
            return "CASH_SPEND_PURCHASE_ONLY", action_id, {
                "posting_mode": "PURCHASE_ONLY",
                "cashflow_posted": False,
                "transaction_id": None,
                "purchase_id": purchase.purchase.id if purchase.purchase else None,
                "tender_kind": "cash",
                "purchase": purchase.model_dump(mode="json"),
            }
        account_id = body.selected_account_id or body.selected_target_id
        if not account_id or account_id == _CASH_PURCHASE_ONLY_TARGET:
            raise FinanceCaptureConflictError(
                "Select a cash wallet or save this as purchase-only cash evidence"
            )
        account = await (
            await db.execute(
                "SELECT id, account_type, purpose, currency, include_in_cashflow "
                "FROM finance_accounts "
                "WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL",
                (account_id, space_id, user["family_id"]),
            )
        ).fetchone()
        if (
            account is None or account["account_type"] != "CASH"
            or account["purpose"] != "OPERATING_CURRENT"
            or account["currency"] != content.currency or not account["include_in_cashflow"]
        ):
            raise FinanceCaptureConflictError(
                "Select an included operating cash wallet in the reviewed currency"
            )
        imported = await import_source_transactions(
            db, user=user, space_id=space_id, account_id=account["id"],
            observations=[NormalisedSourceTransaction(
                source_kind="MANUAL", source_batch_id=f"capture:{draft_id}",
                source_transaction_id=f"capture:{draft_id}",
                booking_date=content.spent_on, pending_status="POSTED",
                amount_minor=-content.total_minor, currency=content.currency,
                description=f"Cash at {content.merchant}", merchant_text=content.merchant,
                observed_at=_now(),
            )],
        )
        purchase = await _ingest_reviewed_purchase(
            db, user=user, space_id=space_id, draft_id=draft_id, content=content,
            purchased_on=content.spent_on, cash_tender=True,
        )
        return "CASH_SPEND", imported.transaction_ids[0], {
            "posting_mode": "CASH_ACCOUNT_TRANSACTION",
            "cashflow_posted": True,
            "transaction_id": imported.transaction_ids[0],
            "account_id": account["id"],
            "purchase_id": purchase.purchase.id if purchase.purchase else None,
            "tender_kind": "cash",
            "purchase": purchase.model_dump(mode="json"),
        }
    if isinstance(content, FinanceCommitmentCapture):
        result = await create_commitment(
            db, user=user, space_id=space_id,
            body=FinanceCommitmentCreate(
                name=content.name, amount_mode=content.amount_mode,
                exact_minor=content.exact_minor, expected_minor=content.expected_minor,
                currency=content.currency, recurrence=content.recurrence,
                reviewed_dates=[content.reviewed_date], priority=content.priority,
                payment_handling=content.payment_handling,
                show_in_calendar=content.show_in_calendar,
                show_in_tasks=content.show_in_tasks,
                responsible_user_id=content.responsible_user_id,
            ),
        )
        return "COMMITMENT", result.id, result.model_dump(mode="json")
    if isinstance(content, FinanceGoalCapture):
        result = await create_goal(
            db, user=user, space_id=space_id,
            body=FinanceGoalCreate(
                name=content.name, target_minor=content.target_minor,
                deadline=content.deadline, currency=content.currency,
                priority=content.priority,
            ),
        )
        return "GOAL", result.id, result.model_dump(mode="json")
    if isinstance(content, FinanceHabitCapture):
        result = await create_habit(
            db, user=user, space_id=space_id,
            body=FinanceHabitCreate(
                slot=content.slot, name=content.name, trigger=content.trigger,
                purposes=content.purposes, utilities=content.utilities,
                minimum_line_minor=content.minimum_line_minor,
                start_date=content.start_date, review_date=content.review_date,
                fallback=content.fallback,
            ),
        )
        return "HABIT", result.id, result.model_dump(mode="json")
    if isinstance(content, FinancePurchasePlanCapture):
        account_id = body.selected_account_id or body.selected_target_id
        if not account_id:
            raise FinanceCaptureConflictError("Select the account for this planned purchase")
        result = await create_purchase_proposal(
            db, user=user, space_id=space_id,
            body=FinancePurchaseProposalCreate(
                reviewed=True, source_kind="TEXT",
                source_text=f"Reviewed Finance capture: {content.name}",
                name=content.name, amount_low_minor=content.amount_low_minor,
                amount_high_minor=content.amount_high_minor,
                desired_date=content.desired_date, recurrence=content.recurrence,
                payment_account_id=account_id, purpose=content.purpose,
                beneficiary=content.beneficiary, uncertainties=content.uncertainties,
                currency=content.currency,
            ),
        )
        return "PURCHASE_PLAN", result.id, result.model_dump(mode="json")
    raise FinanceCaptureError("Unsupported Finance review card")


async def confirm_finance_capture(
    db, *, user: dict, draft_id: str, body: FinanceCaptureConfirmRequest
) -> FinanceCaptureConfirmResponse:
    require_finance_access(user)
    initial = await _draft_row(db, user=user, draft_id=draft_id)
    confirmation_digest = _confirmation_digest(body)
    if initial["status"] == "CONFIRMED":
        if initial["confirmation_digest"] != confirmation_digest:
            raise FinanceCaptureConflictError(
                "This Finance review card was already confirmed with different details"
            )
        return FinanceCaptureConfirmResponse(
            draft_id=draft_id,
            status="CONFIRMED",
            action_kind=initial["confirmed_action_kind"],
            action_id=initial["confirmed_action_id"],
            result=json.loads(initial["confirmed_result_json"] or "{}"),
        )
    if initial["status"] == "EXPIRED":
        raise FinanceCaptureConflictError("This Finance review card has expired")
    checked_at = _now()
    if (
        initial["status"] == "PENDING"
        and datetime.fromisoformat(initial["expires_at"].replace("Z", "+00:00"))
        <= checked_at
    ):
        async with serialized_create(db):
            await db.execute(
                "UPDATE finance_capture_drafts SET status = 'EXPIRED', payload_json = '{}', "
                "target_options_json = '[]', updated_at = ? WHERE id = ? AND status = 'PENDING'",
                (checked_at.isoformat(), draft_id),
            )
        raise FinanceCaptureConflictError("This Finance review card has expired")
    async with serialized_create(db):
        row = await _draft_row(db, user=user, draft_id=draft_id)
        now = _now()
        if row["status"] == "CONFIRMED":
            if row["confirmation_digest"] != confirmation_digest:
                raise FinanceCaptureConflictError(
                    "This Finance review card was already confirmed with different details"
                )
            return FinanceCaptureConfirmResponse(
                draft_id=draft_id,
                status="CONFIRMED",
                action_kind=row["confirmed_action_kind"],
                action_id=row["confirmed_action_id"],
                result=json.loads(row["confirmed_result_json"] or "{}"),
            )
        if row["status"] != "PENDING":
            raise FinanceCaptureConflictError("This Finance review card has already been used")
        if datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00")) <= now:
            raise FinanceCaptureConflictError("This Finance review card has expired")
        if body.content.kind != row["draft_kind"]:
            raise FinanceCaptureConflictError("The review-card action type cannot be changed")
        action_kind, action_id, result = await _apply_content(
            db, user=user, space_id=row["space_id"], draft_id=draft_id, body=body
        )
        await db.execute(
            "UPDATE finance_capture_drafts SET status = 'CONFIRMED', payload_json = '{}', "
            "target_options_json = '[]', confirmed_action_kind = ?, "
            "confirmed_action_id = ?, confirmation_digest = ?, confirmed_result_json = ?, "
            "confirmed_at = ?, updated_at = ? WHERE id = ?",
            (
                action_kind, action_id, confirmation_digest, _json(result),
                now.isoformat(), now.isoformat(), draft_id,
            ),
        )
    return FinanceCaptureConfirmResponse(
        draft_id=draft_id, status="CONFIRMED", action_kind=action_kind,
        action_id=action_id, result=result,
    )


async def expire_finance_capture_drafts(db, *, now: datetime | None = None) -> int:
    instant = now or _now()
    cursor = await db.execute(
        "UPDATE finance_capture_drafts SET status = 'EXPIRED', payload_json = '{}', "
        "target_options_json = '[]', updated_at = ? WHERE status = 'PENDING' "
        "AND expires_at <= ? AND deleted_at IS NULL",
        (instant.isoformat(), instant.isoformat()),
    )
    await db.commit()
    return cursor.rowcount
