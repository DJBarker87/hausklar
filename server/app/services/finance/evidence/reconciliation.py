"""Deterministic purchase-to-payment candidate scoring and exact allocation checks."""

import re
from dataclasses import dataclass
from datetime import date

from app.services.finance.evidence.types import PurchaseDraft, TenderKind
from app.services.finance.money import normalise_currency

_NORMALISE_MERCHANT = re.compile(r"[^a-z0-9]+")


def _normalise_merchant(value: str) -> str:
    return _NORMALISE_MERCHANT.sub("", value.casefold())


def _require_int(value: int, *, label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{label} must be exact integer minor units")


@dataclass(frozen=True, slots=True)
class CanonicalPayment:
    """One canonical bank transaction; negative is a charge and positive a refund."""

    payment_id: str
    merchant: str
    booked_on: date
    amount_minor: int
    currency: str
    description: str = ""
    order_reference: str | None = None
    card_suffix: str | None = None

    def __post_init__(self) -> None:
        if (
            not isinstance(self.payment_id, str)
            or not self.payment_id
            or not isinstance(self.merchant, str)
            or not self.merchant
        ):
            raise ValueError("Payment ID and merchant are required")
        if not isinstance(self.booked_on, date):
            raise ValueError("Payment booking date must be a date")
        if not isinstance(self.description, str):
            raise ValueError("Payment description must be text")
        _require_int(self.amount_minor, label="Payment amount")
        if self.amount_minor == 0:
            raise ValueError("A canonical payment cannot have a zero amount")
        object.__setattr__(self, "currency", normalise_currency(self.currency))
        if self.card_suffix is not None and (
            not self.card_suffix.isdigit() or not 2 <= len(self.card_suffix) <= 8
        ):
            raise ValueError("Card suffix must contain 2 to 8 digits")


@dataclass(frozen=True, slots=True)
class MatchCandidate:
    purchase_ref: str
    payment_id: str
    score_bps: int
    exact_amount: bool
    reasons: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class MatchSuggestion:
    purchase_ref: str
    candidates: tuple[MatchCandidate, ...]
    selected_payment_id: str | None
    requires_review: bool


def _expected_payment_amounts(purchase: PurchaseDraft, *, is_refund: bool) -> set[int]:
    if is_refund:
        amounts = {refund.amount_minor for refund in purchase.refunds}
        if purchase.refunded_minor:
            amounts.add(purchase.refunded_minor)
        return amounts

    bank_claims = {
        tender.amount_minor
        for tender in purchase.tenders
        if tender.kind in {TenderKind.BANK, TenderKind.CARD}
    }
    if bank_claims:
        bank_claims.add(sum(bank_claims))
        return bank_claims
    known_non_bank = sum(
        tender.amount_minor
        for tender in purchase.tenders
        if tender.kind in {TenderKind.CASH, TenderKind.GIFT_CARD, TenderKind.CREDIT}
    )
    return {max(0, purchase.final_total_minor - known_non_bank)}


def _score_candidate(purchase: PurchaseDraft, payment: CanonicalPayment) -> MatchCandidate:
    score = 0
    reasons: list[str] = []
    purchase_merchant = _normalise_merchant(purchase.merchant)
    payment_merchant = _normalise_merchant(payment.merchant)
    if purchase_merchant == payment_merchant:
        score += 2_500
        reasons.append("merchant_exact")
    elif purchase_merchant in payment_merchant or payment_merchant in purchase_merchant:
        score += 1_600
        reasons.append("merchant_related")

    distance = abs((payment.booked_on - purchase.purchased_on).days)
    if distance == 0:
        score += 2_000
        reasons.append("date_same_day")
    elif distance <= 3:
        score += 1_300
        reasons.append("date_within_three_days")
    elif distance <= 7:
        score += 600
        reasons.append("date_within_seven_days")

    expected_amounts = _expected_payment_amounts(
        purchase, is_refund=payment.amount_minor > 0
    )
    payment_magnitude = abs(payment.amount_minor)
    exact_amount = payment_magnitude in expected_amounts and payment_magnitude != 0
    if exact_amount:
        score += 4_000
        reasons.append("amount_exact")
    elif any(expected and payment_magnitude > expected for expected in expected_amounts):
        score += 700
        reasons.append("amount_can_group_purchases")

    order_reference = purchase.order_reference
    if order_reference and (
        order_reference == payment.order_reference
        or order_reference.casefold() in payment.description.casefold()
    ):
        score += 1_200
        reasons.append("order_reference")

    expected_suffixes = {
        tender.card_suffix for tender in purchase.tenders if tender.card_suffix is not None
    }
    if payment.card_suffix and payment.card_suffix in expected_suffixes:
        score += 300
        reasons.append("card_suffix")

    return MatchCandidate(
        purchase_ref=purchase.purchase_ref,
        payment_id=payment.payment_id,
        score_bps=min(score, 10_000),
        exact_amount=exact_amount,
        reasons=tuple(reasons),
    )


def suggest_payment_matches(
    purchases: tuple[PurchaseDraft, ...] | list[PurchaseDraft],
    payments: tuple[CanonicalPayment, ...] | list[CanonicalPayment],
) -> tuple[MatchSuggestion, ...]:
    """Rank candidates and only select an exact, high-confidence, unique winner."""

    suggestions: list[MatchSuggestion] = []
    for purchase in purchases:
        candidates = [
            _score_candidate(purchase, payment)
            for payment in payments
            if payment.currency == purchase.currency
            and ((payment.amount_minor > 0) == bool(purchase.refunds) or payment.amount_minor < 0)
        ]
        candidates.sort(key=lambda candidate: (-candidate.score_bps, candidate.payment_id))
        top = candidates[0] if candidates else None
        runner_up = candidates[1] if len(candidates) > 1 else None
        margin = top.score_bps - runner_up.score_bps if top and runner_up else 10_000
        selected = (
            top.payment_id
            if top and top.exact_amount and top.score_bps >= 7_000 and margin >= 750
            else None
        )
        suggestions.append(
            MatchSuggestion(
                purchase_ref=purchase.purchase_ref,
                candidates=tuple(candidates),
                selected_payment_id=selected,
                requires_review=selected is None,
            )
        )
    return tuple(suggestions)


@dataclass(frozen=True, slots=True)
class PaymentAllocation:
    """A signed allocation: purchases are positive and refunds are negative."""

    allocation_ref: str
    purchase_ref: str
    tender_kind: TenderKind
    allocated_minor: int
    payment_id: str | None = None
    line_ref: str | None = None


@dataclass(frozen=True, slots=True)
class PurchaseRemainder:
    purchase_ref: str
    unallocated_purchase_minor: int
    unallocated_refund_minor: int


@dataclass(frozen=True, slots=True)
class PaymentRemainder:
    payment_id: str
    unallocated_minor: int


@dataclass(frozen=True, slots=True)
class ReconciliationIssue:
    code: str
    message: str


@dataclass(frozen=True, slots=True)
class ReconciliationResult:
    quarantined: bool
    allocations: tuple[PaymentAllocation, ...]
    purchase_remainders: tuple[PurchaseRemainder, ...]
    payment_remainders: tuple[PaymentRemainder, ...]
    cashflow_net_spend_minor: int
    behavioural_net_spend_minor: int
    total_spending_minor: int
    currency: str | None
    issues: tuple[ReconciliationIssue, ...]


def reconcile_allocations(
    purchases: tuple[PurchaseDraft, ...] | list[PurchaseDraft],
    payments: tuple[CanonicalPayment, ...] | list[CanonicalPayment],
    allocations: tuple[PaymentAllocation, ...] | list[PaymentAllocation],
) -> ReconciliationResult:
    """Validate many-to-many allocations without changing canonical cashflow totals."""

    purchase_by_id = {purchase.purchase_ref: purchase for purchase in purchases}
    payment_by_id = {payment.payment_id: payment for payment in payments}
    issues: list[ReconciliationIssue] = []

    if len(purchase_by_id) != len(purchases):
        issues.append(
            ReconciliationIssue("duplicate_purchase", "Purchase references must be unique.")
        )
    if len(payment_by_id) != len(payments):
        issues.append(ReconciliationIssue("duplicate_payment", "Payment IDs must be unique."))
    allocation_refs = [allocation.allocation_ref for allocation in allocations]
    malformed_allocation_ref = any(
        not isinstance(ref, str) or not ref for ref in allocation_refs
    )
    if malformed_allocation_ref or len(set(allocation_refs)) != len(allocation_refs):
        issues.append(
            ReconciliationIssue("duplicate_allocation", "Allocation references must be unique.")
        )

    currencies = {purchase.currency for purchase in purchases} | {
        payment.currency for payment in payments
    }
    if len(currencies) > 1:
        issues.append(
            ReconciliationIssue(
                "currency_mismatch",
                "A reconciliation run cannot combine currencies without conversion.",
            )
        )
    currency = next(iter(currencies)) if len(currencies) == 1 else None

    purchase_funding = {purchase.purchase_ref: 0 for purchase in purchases}
    purchase_refunds = {purchase.purchase_ref: 0 for purchase in purchases}
    payment_usage = {payment.payment_id: 0 for payment in payments}
    line_refunds: dict[tuple[str, str], int] = {}

    for allocation in allocations:
        purchase = purchase_by_id.get(allocation.purchase_ref)
        if purchase is None:
            issues.append(
                ReconciliationIssue(
                    "unknown_purchase", "An allocation references an unknown purchase."
                )
            )
            continue
        try:
            _require_int(allocation.allocated_minor, label="Allocated amount")
        except TypeError:
            issues.append(
                ReconciliationIssue(
                    "malformed_allocation", "Allocated amounts must use exact integer minor units."
                )
            )
            continue
        if allocation.allocated_minor == 0:
            issues.append(
                ReconciliationIssue("zero_allocation", "An allocation cannot have a zero amount.")
            )
            continue
        if not isinstance(allocation.tender_kind, TenderKind):
            issues.append(
                ReconciliationIssue(
                    "malformed_tender", "An allocation has an unsupported tender kind."
                )
            )
            continue

        payment = None
        if allocation.payment_id is not None:
            payment = payment_by_id.get(allocation.payment_id)
            if payment is None:
                issues.append(
                    ReconciliationIssue(
                        "unknown_payment", "An allocation references an unknown payment."
                    )
                )
                continue
            if allocation.tender_kind in {
                TenderKind.CASH,
                TenderKind.GIFT_CARD,
                TenderKind.CREDIT,
            }:
                issues.append(
                    ReconciliationIssue(
                        "tender_payment_mismatch",
                        "Cash, gift-card and credit allocations cannot consume a bank payment.",
                    )
                )
            if payment.currency != purchase.currency:
                issues.append(
                    ReconciliationIssue(
                        "currency_mismatch", "An allocation cannot cross currencies."
                    )
                )
            if payment.amount_minor < 0 and allocation.allocated_minor < 0:
                issues.append(
                    ReconciliationIssue(
                        "direction_mismatch", "A charge cannot fund a refund allocation."
                    )
                )
            if payment.amount_minor > 0 and allocation.allocated_minor > 0:
                issues.append(
                    ReconciliationIssue(
                        "direction_mismatch", "A refund cannot fund a purchase allocation."
                    )
                )
            payment_usage[payment.payment_id] += abs(allocation.allocated_minor)
        elif allocation.tender_kind in {TenderKind.BANK, TenderKind.CARD}:
            issues.append(
                ReconciliationIssue(
                    "missing_payment", "Bank and card allocations require a canonical payment."
                )
            )

        if allocation.allocated_minor > 0:
            purchase_funding[purchase.purchase_ref] += allocation.allocated_minor
        else:
            refund_magnitude = -allocation.allocated_minor
            purchase_refunds[purchase.purchase_ref] += refund_magnitude
            if allocation.line_ref is not None:
                if allocation.line_ref not in {line.line_ref for line in purchase.lines}:
                    issues.append(
                        ReconciliationIssue(
                            "unknown_line", "A refund allocation references an unknown line."
                        )
                    )
                key = (purchase.purchase_ref, allocation.line_ref)
                line_refunds[key] = line_refunds.get(key, 0) + refund_magnitude

    for payment in payments:
        if payment_usage[payment.payment_id] > abs(payment.amount_minor):
            issues.append(
                ReconciliationIssue(
                    "payment_overallocated",
                    "Allocations exceed a canonical payment's amount.",
                )
            )

    for purchase in purchases:
        if purchase_funding[purchase.purchase_ref] > purchase.final_total_minor:
            issues.append(
                ReconciliationIssue(
                    "purchase_overallocated", "Allocations exceed a purchase's final total."
                )
            )
        if purchase_refunds[purchase.purchase_ref] > purchase.refunded_minor:
            issues.append(
                ReconciliationIssue(
                    "refund_overallocated", "Allocations exceed the evidenced refund total."
                )
            )
        evidenced_by_line: dict[str, int] = {}
        for refund in purchase.refunds:
            evidenced_by_line[refund.line_ref] = (
                evidenced_by_line.get(refund.line_ref, 0) + refund.amount_minor
            )
        for line_ref, allocated in (
            (line_ref, amount)
            for (purchase_ref, line_ref), amount in line_refunds.items()
            if purchase_ref == purchase.purchase_ref
        ):
            if allocated > evidenced_by_line.get(line_ref, 0):
                issues.append(
                    ReconciliationIssue(
                        "line_refund_overallocated",
                        "A line refund allocation exceeds its evidenced refund.",
                    )
                )

    cashflow = sum(-payment.amount_minor for payment in payment_by_id.values())
    behavioural = sum(purchase.behavioural_net_minor for purchase in purchases)
    quarantined = bool(issues)
    if quarantined:
        safe_purchase_funding = {purchase.purchase_ref: 0 for purchase in purchases}
        safe_purchase_refunds = {purchase.purchase_ref: 0 for purchase in purchases}
        safe_payment_usage = {payment.payment_id: 0 for payment in payments}
    else:
        safe_purchase_funding = purchase_funding
        safe_purchase_refunds = purchase_refunds
        safe_payment_usage = payment_usage

    return ReconciliationResult(
        quarantined=quarantined,
        allocations=() if quarantined else tuple(allocations),
        purchase_remainders=tuple(
            PurchaseRemainder(
                purchase_ref=purchase.purchase_ref,
                unallocated_purchase_minor=(
                    purchase.final_total_minor - safe_purchase_funding[purchase.purchase_ref]
                ),
                unallocated_refund_minor=(
                    purchase.refunded_minor - safe_purchase_refunds[purchase.purchase_ref]
                ),
            )
            for purchase in purchases
        ),
        payment_remainders=tuple(
            PaymentRemainder(
                payment_id=payment.payment_id,
                unallocated_minor=(
                    abs(payment.amount_minor) - safe_payment_usage[payment.payment_id]
                ),
            )
            for payment in payments
        ),
        cashflow_net_spend_minor=cashflow,
        behavioural_net_spend_minor=behavioural,
        total_spending_minor=cashflow,
        currency=currency,
        issues=tuple(issues),
    )
