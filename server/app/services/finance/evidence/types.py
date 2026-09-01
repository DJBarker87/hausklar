"""Immutable purchase-evidence drafts shared by deterministic import adapters."""

from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from enum import StrEnum

from app.services.finance.money import normalise_currency


class EvidenceValidationError(ValueError):
    """A draft cannot satisfy the purchase-evidence accounting invariants."""


class EvidenceSourceKind(StrEnum):
    TESCO_BATCH = "tesco_batch"
    AMAZON_EMAIL = "amazon_email"
    E_RECEIPT = "e_receipt"
    SERVICE_INVOICE = "service_invoice"
    NATURAL_LANGUAGE = "natural_language"


class EvidenceStatus(StrEnum):
    OBSERVED_STRUCTURED = "observed_structured"
    OBSERVED_DOCUMENT = "observed_document"
    USER_CONFIRMED = "user_confirmed"
    INFERRED = "inferred"
    UNITEMISED = "unitemised"


class PurchaseLineKind(StrEnum):
    PRODUCT = "product"
    SERVICE = "service"
    DELIVERY = "delivery"
    FEE = "fee"
    TAX = "tax"
    UNKNOWN = "unknown"


class PurchaseStatus(StrEnum):
    PENDING = "pending"
    PARTLY_FULFILLED = "partly_fulfilled"
    FULFILLED = "fulfilled"
    PARTLY_REFUNDED = "partly_refunded"
    REFUNDED = "refunded"
    CANCELLED = "cancelled"


class TenderKind(StrEnum):
    BANK = "bank"
    CARD = "card"
    CASH = "cash"
    GIFT_CARD = "gift_card"
    CREDIT = "credit"
    UNKNOWN = "unknown"


def _require_minor_units(value: int, *, label: str, allow_zero: bool = True) -> None:
    if isinstance(value, bool) or not isinstance(value, int):
        raise EvidenceValidationError(f"{label} must be exact integer minor units")
    if value < 0 or (not allow_zero and value == 0):
        qualifier = "positive" if not allow_zero else "non-negative"
        raise EvidenceValidationError(f"{label} must be {qualifier}")


def _require_text(value: str, *, label: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise EvidenceValidationError(f"{label} must be non-empty text")
    if len(value) > 2_000:
        raise EvidenceValidationError(f"{label} is too long")


@dataclass(frozen=True, slots=True)
class EvidenceReference:
    """A stable pointer into the source, without interpreting source content."""

    source_id: str
    locator: str

    def __post_init__(self) -> None:
        _require_text(self.source_id, label="Evidence source ID")
        _require_text(self.locator, label="Evidence locator")


@dataclass(frozen=True, slots=True)
class EvidenceProvenance:
    source_kind: EvidenceSourceKind
    source_id: str
    parser_version: str
    confidence_bps: int

    def __post_init__(self) -> None:
        if not isinstance(self.source_kind, EvidenceSourceKind):
            raise EvidenceValidationError("Evidence source kind is not supported")
        _require_text(self.source_id, label="Evidence source ID")
        _require_text(self.parser_version, label="Parser version")
        if (
            isinstance(self.confidence_bps, bool)
            or not isinstance(self.confidence_bps, int)
            or not 0 <= self.confidence_bps <= 10_000
        ):
            raise EvidenceValidationError("Confidence must be between 0 and 10,000 basis points")


@dataclass(frozen=True, slots=True)
class PurchaseLineDraft:
    line_ref: str
    kind: PurchaseLineKind
    raw_description: str
    quantity: Decimal
    unit: str | None
    unit_price_minor: int | None
    gross_minor: int | None
    discount_minor: int | None
    net_minor: int | None
    evidence_status: EvidenceStatus
    source_refs: tuple[EvidenceReference, ...]
    seller: str | None = None
    product_reference: str | None = None
    replaces_description: str | None = None
    shipment_reference: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.kind, PurchaseLineKind):
            raise EvidenceValidationError("Line kind is not supported")
        if not isinstance(self.evidence_status, EvidenceStatus):
            raise EvidenceValidationError("Line evidence status is not supported")
        _require_text(self.line_ref, label="Line reference")
        _require_text(self.raw_description, label="Line description")
        for label, value in (
            ("Line unit", self.unit),
            ("Seller", self.seller),
            ("Product reference", self.product_reference),
            ("Substitution description", self.replaces_description),
            ("Shipment reference", self.shipment_reference),
        ):
            if value is not None:
                _require_text(value, label=label)
        if not isinstance(self.quantity, Decimal) or not self.quantity.is_finite():
            raise EvidenceValidationError("Line quantity must be an exact finite decimal")
        if self.quantity <= 0:
            raise EvidenceValidationError("Line quantity must be positive")
        if not isinstance(self.source_refs, tuple) or not self.source_refs:
            raise EvidenceValidationError("Each line must retain a source reference")
        if not all(isinstance(reference, EvidenceReference) for reference in self.source_refs):
            raise EvidenceValidationError("Line source references are malformed")

        money_fields = (
            self.unit_price_minor,
            self.gross_minor,
            self.discount_minor,
            self.net_minor,
        )
        known_fields = tuple(value is not None for value in money_fields)
        if any(known_fields) and not all(known_fields[1:]):
            raise EvidenceValidationError(
                "Gross, discount and net must either all be known or all be unknown"
            )
        if self.gross_minor is not None:
            _require_minor_units(self.gross_minor, label="Line gross")
            assert self.discount_minor is not None
            assert self.net_minor is not None
            _require_minor_units(self.discount_minor, label="Line discount")
            _require_minor_units(self.net_minor, label="Line net")
            if self.discount_minor > self.gross_minor:
                raise EvidenceValidationError("Line discount cannot exceed line gross")
            if self.net_minor != self.gross_minor - self.discount_minor:
                raise EvidenceValidationError("Line net must equal gross minus line discount")
        elif self.unit_price_minor is not None:
            raise EvidenceValidationError(
                "Unit price cannot be known when the line total is unknown"
            )

        if self.unit_price_minor is not None:
            _require_minor_units(self.unit_price_minor, label="Unit price")
        if self.evidence_status is EvidenceStatus.UNITEMISED:
            if self.net_minor is None or self.net_minor <= 0:
                raise EvidenceValidationError("An unitemised remainder must have a positive amount")


@dataclass(frozen=True, slots=True)
class LineRefundDraft:
    refund_ref: str
    line_ref: str
    amount_minor: int
    quantity: Decimal | None
    source_refs: tuple[EvidenceReference, ...]

    def __post_init__(self) -> None:
        _require_text(self.refund_ref, label="Refund reference")
        _require_text(self.line_ref, label="Refund line reference")
        _require_minor_units(self.amount_minor, label="Refund amount", allow_zero=False)
        if self.quantity is not None:
            if not isinstance(self.quantity, Decimal) or not self.quantity.is_finite():
                raise EvidenceValidationError("Refund quantity must be an exact finite decimal")
            if self.quantity <= 0:
                raise EvidenceValidationError("Refund quantity must be positive")
        if not isinstance(self.source_refs, tuple) or not self.source_refs:
            raise EvidenceValidationError("Each refund must retain a source reference")
        if not all(isinstance(reference, EvidenceReference) for reference in self.source_refs):
            raise EvidenceValidationError("Refund source references are malformed")


@dataclass(frozen=True, slots=True)
class TenderClaim:
    tender_ref: str
    kind: TenderKind
    amount_minor: int
    source_refs: tuple[EvidenceReference, ...]
    provider_transaction_id: str | None = None
    card_suffix: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.kind, TenderKind):
            raise EvidenceValidationError("Tender kind is not supported")
        _require_text(self.tender_ref, label="Tender reference")
        _require_minor_units(self.amount_minor, label="Tender amount", allow_zero=False)
        if not isinstance(self.source_refs, tuple) or not self.source_refs:
            raise EvidenceValidationError("Each tender claim must retain a source reference")
        if not all(isinstance(reference, EvidenceReference) for reference in self.source_refs):
            raise EvidenceValidationError("Tender source references are malformed")
        if self.provider_transaction_id is not None:
            _require_text(self.provider_transaction_id, label="Provider transaction ID")
        if self.card_suffix is not None:
            if not self.card_suffix.isdigit() or not 2 <= len(self.card_suffix) <= 8:
                raise EvidenceValidationError("Card suffix must contain 2 to 8 digits")


@dataclass(frozen=True, slots=True)
class PurchaseDraft:
    purchase_ref: str
    merchant: str
    purchased_on: date
    currency: str
    lines: tuple[PurchaseLineDraft, ...]
    shipping_minor: int
    vat_included_minor: int
    order_discount_minor: int
    final_total_minor: int
    status: PurchaseStatus
    provenance: EvidenceProvenance
    order_reference: str | None = None
    shipment_refs: tuple[str, ...] = ()
    tenders: tuple[TenderClaim, ...] = ()
    refunds: tuple[LineRefundDraft, ...] = ()

    def __post_init__(self) -> None:
        _require_text(self.purchase_ref, label="Purchase reference")
        _require_text(self.merchant, label="Merchant")
        if not isinstance(self.purchased_on, date):
            raise EvidenceValidationError("Purchase date must be a date")
        if not isinstance(self.status, PurchaseStatus):
            raise EvidenceValidationError("Purchase status is not supported")
        if not isinstance(self.provenance, EvidenceProvenance):
            raise EvidenceValidationError("Purchase provenance is malformed")
        if not all(
            isinstance(value, tuple)
            for value in (self.lines, self.shipment_refs, self.tenders, self.refunds)
        ):
            raise EvidenceValidationError("Purchase collections must be immutable tuples")
        if not all(isinstance(line, PurchaseLineDraft) for line in self.lines):
            raise EvidenceValidationError("Purchase lines are malformed")
        if not all(isinstance(tender, TenderClaim) for tender in self.tenders):
            raise EvidenceValidationError("Purchase tender claims are malformed")
        if not all(isinstance(refund, LineRefundDraft) for refund in self.refunds):
            raise EvidenceValidationError("Purchase refunds are malformed")
        if self.order_reference is not None:
            _require_text(self.order_reference, label="Order reference")
        for shipment_ref in self.shipment_refs:
            _require_text(shipment_ref, label="Shipment reference")
        object.__setattr__(self, "currency", normalise_currency(self.currency))
        for label, value in (
            ("Shipping", self.shipping_minor),
            ("VAT memo", self.vat_included_minor),
            ("Order discount", self.order_discount_minor),
            ("Final total", self.final_total_minor),
        ):
            _require_minor_units(value, label=label)

        line_refs = [line.line_ref for line in self.lines]
        if len(line_refs) != len(set(line_refs)):
            raise EvidenceValidationError("Line references must be unique within a purchase")
        if len(self.shipment_refs) != len(set(self.shipment_refs)):
            raise EvidenceValidationError("Shipment references must be unique")
        if len({tender.tender_ref for tender in self.tenders}) != len(self.tenders):
            raise EvidenceValidationError("Tender references must be unique within a purchase")
        if len({refund.refund_ref for refund in self.refunds}) != len(self.refunds):
            raise EvidenceValidationError("Refund references must be unique within a purchase")

        has_unknown_amount = any(line.net_minor is None for line in self.lines)
        has_unitemised = any(
            line.evidence_status is EvidenceStatus.UNITEMISED for line in self.lines
        )
        if has_unknown_amount and not has_unitemised:
            raise EvidenceValidationError(
                "Unknown line values require an explicit unitemised remainder"
            )
        known_line_total = sum(line.net_minor or 0 for line in self.lines)
        calculated_total = known_line_total + self.shipping_minor - self.order_discount_minor
        if calculated_total != self.final_total_minor:
            raise EvidenceValidationError(
                "Line nets plus shipping minus order discount must equal the final total"
            )
        if self.vat_included_minor > self.final_total_minor:
            raise EvidenceValidationError("Included VAT cannot exceed the final total")
        if sum(tender.amount_minor for tender in self.tenders) > self.final_total_minor:
            raise EvidenceValidationError("Tender claims cannot exceed the final total")

        line_by_ref = {line.line_ref: line for line in self.lines}
        refunded_by_line: dict[str, int] = {}
        for refund in self.refunds:
            line = line_by_ref.get(refund.line_ref)
            if line is None:
                raise EvidenceValidationError("A refund references an unknown purchase line")
            if line.net_minor is None:
                raise EvidenceValidationError("A refund requires a known original line amount")
            refunded_by_line[refund.line_ref] = (
                refunded_by_line.get(refund.line_ref, 0) + refund.amount_minor
            )
            if refunded_by_line[refund.line_ref] > line.net_minor:
                raise EvidenceValidationError("Line refunds cannot exceed the original line net")

    @property
    def refunded_minor(self) -> int:
        return sum(refund.amount_minor for refund in self.refunds)

    @property
    def behavioural_net_minor(self) -> int:
        return self.final_total_minor - self.refunded_minor


@dataclass(frozen=True, slots=True)
class EvidenceIssue:
    code: str
    message: str


@dataclass(frozen=True, slots=True)
class EvidenceParseResult:
    draft: PurchaseDraft | None
    issues: tuple[EvidenceIssue, ...] = ()

    @property
    def quarantined(self) -> bool:
        return self.draft is None
