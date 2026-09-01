"""Deterministic adapters from structured purchase evidence into immutable drafts.

All values in these payloads are data. Descriptions, notes, and other free text are
copied as evidence only and are never evaluated as commands or parser instructions.
"""

from collections.abc import Callable, Mapping, Sequence
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from typing import TypeVar

from app.services.finance.evidence.types import (
    EvidenceIssue,
    EvidenceParseResult,
    EvidenceProvenance,
    EvidenceReference,
    EvidenceSourceKind,
    EvidenceStatus,
    EvidenceValidationError,
    LineRefundDraft,
    PurchaseDraft,
    PurchaseLineDraft,
    PurchaseLineKind,
    PurchaseStatus,
    TenderClaim,
    TenderKind,
)

_PARSER_VERSION = "finance-evidence-v1"
_T = TypeVar("_T")


def _text(value: object, *, label: str, fallback: str | None = None) -> str:
    if value is None and fallback is not None:
        return fallback
    if not isinstance(value, str) or not value.strip():
        raise EvidenceValidationError(f"{label} must be non-empty text")
    if len(value) > 2_000:
        raise EvidenceValidationError(f"{label} is too long")
    return value


def _optional_text(value: object, *, label: str) -> str | None:
    if value is None:
        return None
    return _text(value, label=label)


def _minor(value: object, *, label: str, default: int | None = None) -> int:
    if value is None and default is not None:
        return default
    if isinstance(value, bool) or not isinstance(value, int):
        raise EvidenceValidationError(f"{label} must be exact integer minor units")
    return value


def _quantity(value: object, *, label: str, default: str = "1") -> Decimal:
    if value is None:
        value = default
    if isinstance(value, bool):
        raise EvidenceValidationError(f"{label} must be numeric")
    try:
        quantity = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise EvidenceValidationError(f"{label} must be numeric") from exc
    if not quantity.is_finite():
        raise EvidenceValidationError(f"{label} must be finite")
    return quantity


def _date(value: object, *, label: str) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).date()
        except ValueError:
            try:
                return date.fromisoformat(value)
            except ValueError as exc:
                raise EvidenceValidationError(f"{label} must be an ISO date") from exc
    raise EvidenceValidationError(f"{label} must be an ISO date")


def _sequence(value: object, *, label: str) -> Sequence[object]:
    if isinstance(value, (str, bytes)) or not isinstance(value, Sequence):
        raise EvidenceValidationError(f"{label} must be a list")
    return value


def _mapping(value: object, *, label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise EvidenceValidationError(f"{label} must be an object")
    return value


def _enum(enum_type: Callable[[object], _T], value: object, *, label: str) -> _T:
    try:
        return enum_type(value)
    except (TypeError, ValueError) as exc:
        raise EvidenceValidationError(f"{label} is not supported") from exc


def _reference(source_id: str, locator: str) -> EvidenceReference:
    return EvidenceReference(source_id=source_id, locator=locator)


def _line_from_mapping(
    row: Mapping[str, object],
    *,
    source_id: str,
    locator: str,
    default_ref: str,
    default_kind: PurchaseLineKind,
    evidence_status: EvidenceStatus,
) -> PurchaseLineDraft:
    line_ref = _text(
        row.get("line_reference", row.get("id")),
        label="Line reference",
        fallback=default_ref,
    )
    description = _text(
        row.get("description", row.get("raw_name", row.get("grocery_item_name"))),
        label="Line description",
        fallback="Unknown item",
    )
    quantity = _quantity(row.get("quantity", row.get("qty")), label="Line quantity")
    discount = _minor(
        row.get("discount_minor", row.get("discount_pence")),
        label="Line discount",
        default=0,
    )
    gross_value = row.get("gross_minor")
    net_value = row.get("net_minor", row.get("price_pence"))
    if gross_value is None and net_value is None:
        gross = discount_value = net = None
        unit_price = None
    else:
        if gross_value is None:
            net = _minor(net_value, label="Line net")
            gross = net + discount
        else:
            gross = _minor(gross_value, label="Line gross")
            net = (
                gross - discount
                if net_value is None
                else _minor(net_value, label="Line net")
            )
        discount_value = discount
        unit_price_value = row.get("unit_price_minor")
        unit_price = (
            None
            if unit_price_value is None
            else _minor(unit_price_value, label="Unit price")
        )

    kind_value = row.get("kind", row.get("line_kind", default_kind.value))
    return PurchaseLineDraft(
        line_ref=line_ref,
        kind=_enum(PurchaseLineKind, kind_value, label="Line kind"),
        raw_description=description,
        quantity=quantity,
        unit=_optional_text(row.get("unit"), label="Line unit"),
        unit_price_minor=unit_price,
        gross_minor=gross,
        discount_minor=discount_value,
        net_minor=net,
        evidence_status=evidence_status,
        source_refs=(_reference(source_id, locator),),
        seller=_optional_text(row.get("seller"), label="Seller"),
        product_reference=_optional_text(
            row.get("product_reference", row.get("grocery_item_id")),
            label="Product reference",
        ),
        replaces_description=_optional_text(
            row.get("replaces_description", row.get("substitution_for")),
            label="Substitution description",
        ),
        shipment_reference=_optional_text(
            row.get("shipment_reference"),
            label="Shipment reference",
        ),
    )


def _complete_itemisation(
    lines: list[PurchaseLineDraft],
    *,
    source_id: str,
    purchase_ref: str,
    shipping_minor: int,
    order_discount_minor: int,
    declared_total_minor: int | None,
) -> tuple[tuple[PurchaseLineDraft, ...], int]:
    known_total = sum(line.net_minor or 0 for line in lines)
    calculated = known_total + shipping_minor - order_discount_minor
    has_unknown = any(line.net_minor is None for line in lines)
    if declared_total_minor is None:
        if has_unknown:
            raise EvidenceValidationError(
                "A declared final total is required when item prices are incomplete"
            )
        return tuple(lines), calculated

    if declared_total_minor < calculated:
        raise EvidenceValidationError("Itemised values exceed the declared final total")
    remainder = declared_total_minor - calculated
    if remainder:
        unitemised_ref = f"{purchase_ref}:unitemised"
        occupied = {line.line_ref for line in lines}
        suffix = 2
        while unitemised_ref in occupied:
            unitemised_ref = f"{purchase_ref}:unitemised:{suffix}"
            suffix += 1
        lines.append(
            PurchaseLineDraft(
                line_ref=unitemised_ref,
                kind=PurchaseLineKind.UNKNOWN,
                raw_description="Unitemised remainder",
                quantity=Decimal("1"),
                unit=None,
                unit_price_minor=remainder,
                gross_minor=remainder,
                discount_minor=0,
                net_minor=remainder,
                evidence_status=EvidenceStatus.UNITEMISED,
                source_refs=(_reference(source_id, "totals.final_total_minor"),),
            )
        )
    return tuple(lines), declared_total_minor


def _tenders(payload: Mapping[str, object], *, source_id: str) -> tuple[TenderClaim, ...]:
    raw_tenders = payload.get("tenders", payload.get("charges", ()))
    result: list[TenderClaim] = []
    for index, value in enumerate(_sequence(raw_tenders, label="Tenders")):
        row = _mapping(value, label="Tender")
        locator = f"tenders[{index}]"
        result.append(
            TenderClaim(
                tender_ref=_text(
                    row.get("tender_reference", row.get("id")),
                    label="Tender reference",
                    fallback=f"{source_id}:tender:{index}",
                ),
                kind=_enum(
                    TenderKind,
                    row.get("kind", TenderKind.UNKNOWN.value),
                    label="Tender kind",
                ),
                amount_minor=_minor(row.get("amount_minor"), label="Tender amount"),
                source_refs=(_reference(source_id, locator),),
                provider_transaction_id=_optional_text(
                    row.get("provider_transaction_id", row.get("transaction_id")),
                    label="Provider transaction ID",
                ),
                card_suffix=_optional_text(row.get("card_suffix"), label="Card suffix"),
            )
        )
    return tuple(result)


def _refunds(payload: Mapping[str, object], *, source_id: str) -> tuple[LineRefundDraft, ...]:
    result: list[LineRefundDraft] = []
    for index, value in enumerate(_sequence(payload.get("refunds", ()), label="Refunds")):
        row = _mapping(value, label="Refund")
        locator = f"refunds[{index}]"
        result.append(
            LineRefundDraft(
                refund_ref=_text(
                    row.get("refund_reference", row.get("id")),
                    label="Refund reference",
                    fallback=f"{source_id}:refund:{index}",
                ),
                line_ref=_text(row.get("line_reference"), label="Refund line reference"),
                amount_minor=_minor(row.get("amount_minor"), label="Refund amount"),
                quantity=(
                    None
                    if row.get("quantity") is None
                    else _quantity(row.get("quantity"), label="Refund quantity")
                ),
                source_refs=(_reference(source_id, locator),),
            )
        )
    return tuple(result)


def _status(payload: Mapping[str, object], *, default: PurchaseStatus) -> PurchaseStatus:
    return _enum(PurchaseStatus, payload.get("status", default.value), label="Purchase status")


def _result(adapter: Callable[[], PurchaseDraft]) -> EvidenceParseResult:
    try:
        return EvidenceParseResult(draft=adapter())
    except (EvidenceValidationError, TypeError, ValueError, KeyError):
        return EvidenceParseResult(
            draft=None,
            issues=(
                EvidenceIssue(
                    code="malformed_evidence",
                    message="The structured source failed deterministic purchase validation.",
                ),
            ),
        )


def parse_tesco_batch(payload: Mapping[str, object]) -> EvidenceParseResult:
    """Parse representative Tesco purchase-batch rows and signed adjustments."""

    def build() -> PurchaseDraft:
        source_id = _text(payload.get("id"), label="Tesco batch ID")
        purchase_ref = _text(
            payload.get("purchase_reference"),
            label="Purchase reference",
            fallback=source_id,
        )
        lines: list[PurchaseLineDraft] = []
        for index, value in enumerate(_sequence(payload.get("lines"), label="Tesco lines")):
            row = _mapping(value, label="Tesco line")
            lines.append(
                _line_from_mapping(
                    row,
                    source_id=source_id,
                    locator=f"lines[{index}]",
                    default_ref=f"{purchase_ref}:line:{index}",
                    default_kind=PurchaseLineKind.PRODUCT,
                    evidence_status=EvidenceStatus.OBSERVED_STRUCTURED,
                )
            )

        order_discount = _minor(
            payload.get("order_discount_minor"),
            label="Order discount",
            default=0,
        )
        adjustments = _sequence(payload.get("adjustments", ()), label="Adjustments")
        for index, value in enumerate(adjustments):
            row = _mapping(value, label="Adjustment")
            amount = _minor(row.get("amount_minor"), label="Adjustment amount")
            if amount < 0:
                order_discount += -amount
                continue
            if amount == 0:
                continue
            adjustment_row = dict(row)
            adjustment_row["gross_minor"] = amount
            adjustment_row["net_minor"] = amount
            adjustment_row["discount_minor"] = 0
            adjustment_row["kind"] = PurchaseLineKind.FEE.value
            lines.append(
                _line_from_mapping(
                    adjustment_row,
                    source_id=source_id,
                    locator=f"adjustments[{index}]",
                    default_ref=f"{purchase_ref}:adjustment:{index}",
                    default_kind=PurchaseLineKind.FEE,
                    evidence_status=EvidenceStatus.OBSERVED_STRUCTURED,
                )
            )

        shipping = _minor(payload.get("shipping_minor"), label="Shipping", default=0)
        declared = payload.get("final_total_minor")
        final_total = None if declared is None else _minor(declared, label="Final total")
        complete_lines, final_total = _complete_itemisation(
            lines,
            source_id=source_id,
            purchase_ref=purchase_ref,
            shipping_minor=shipping,
            order_discount_minor=order_discount,
            declared_total_minor=final_total,
        )
        return PurchaseDraft(
            purchase_ref=purchase_ref,
            merchant=_text(payload.get("merchant"), label="Merchant", fallback="Tesco"),
            purchased_on=_date(payload.get("purchased_at"), label="Purchase date"),
            currency=_text(payload.get("currency"), label="Currency", fallback="GBP"),
            lines=complete_lines,
            shipping_minor=shipping,
            vat_included_minor=_minor(
                payload.get("vat_included_minor"), label="Included VAT", default=0
            ),
            order_discount_minor=order_discount,
            final_total_minor=final_total,
            status=_status(payload, default=PurchaseStatus.FULFILLED),
            provenance=EvidenceProvenance(
                source_kind=EvidenceSourceKind.TESCO_BATCH,
                source_id=source_id,
                parser_version=_PARSER_VERSION,
                confidence_bps=_minor(
                    payload.get("confidence_bps"), label="Confidence", default=9_800
                ),
            ),
            order_reference=_optional_text(payload.get("order_reference"), label="Order reference"),
            tenders=_tenders(payload, source_id=source_id),
        )

    return _result(build)


def _parse_document_purchase(
    payload: Mapping[str, object],
    *,
    source_kind: EvidenceSourceKind,
    source_id_label: str,
    default_merchant: str | None,
    default_line_kind: PurchaseLineKind,
    line_collection: str = "lines",
    default_status: PurchaseStatus = PurchaseStatus.FULFILLED,
    default_confidence_bps: int = 9_000,
    line_evidence_status: EvidenceStatus = EvidenceStatus.OBSERVED_DOCUMENT,
) -> PurchaseDraft:
    source_id = _text(payload.get("source_id"), label=source_id_label)
    order_reference = _optional_text(
        payload.get("order_reference", payload.get("invoice_reference")),
        label="Order reference",
    )
    purchase_ref = _text(
        payload.get("purchase_reference"),
        label="Purchase reference",
        fallback=order_reference or source_id,
    )
    lines: list[PurchaseLineDraft] = []
    for index, value in enumerate(_sequence(payload.get(line_collection), label="Purchase lines")):
        lines.append(
            _line_from_mapping(
                _mapping(value, label="Purchase line"),
                source_id=source_id,
                locator=f"{line_collection}[{index}]",
                default_ref=f"{purchase_ref}:line:{index}",
                default_kind=default_line_kind,
                evidence_status=line_evidence_status,
            )
        )

    shipping = _minor(payload.get("shipping_minor"), label="Shipping", default=0)
    order_discount = _minor(
        payload.get("order_discount_minor"), label="Order discount", default=0
    )
    declared = payload.get("final_total_minor")
    final_total = None if declared is None else _minor(declared, label="Final total")
    complete_lines, final_total = _complete_itemisation(
        lines,
        source_id=source_id,
        purchase_ref=purchase_ref,
        shipping_minor=shipping,
        order_discount_minor=order_discount,
        declared_total_minor=final_total,
    )
    merchant = _text(
        payload.get("merchant"),
        label="Merchant",
        fallback=default_merchant,
    )

    shipment_values: list[object] = list(
        _sequence(payload.get("shipment_references", ()), label="Shipment references")
    )
    if payload.get("shipment_reference") is not None:
        shipment_values.append(payload["shipment_reference"])
    for value in _sequence(payload.get(line_collection), label="Purchase lines"):
        row = _mapping(value, label="Purchase line")
        if row.get("shipment_reference") is not None:
            shipment_values.append(row["shipment_reference"])
    shipment_refs = tuple(
        dict.fromkeys(_text(value, label="Shipment reference") for value in shipment_values)
    )

    return PurchaseDraft(
        purchase_ref=purchase_ref,
        merchant=merchant,
        purchased_on=_date(
            payload.get("purchased_at", payload.get("issued_at")), label="Purchase date"
        ),
        currency=_text(payload.get("currency"), label="Currency", fallback="GBP"),
        lines=complete_lines,
        shipping_minor=shipping,
        vat_included_minor=_minor(
            payload.get("vat_included_minor"), label="Included VAT", default=0
        ),
        order_discount_minor=order_discount,
        final_total_minor=final_total,
        status=_status(payload, default=default_status),
        provenance=EvidenceProvenance(
            source_kind=source_kind,
            source_id=source_id,
            parser_version=_PARSER_VERSION,
            confidence_bps=_minor(
                payload.get("confidence_bps"),
                label="Confidence",
                default=default_confidence_bps,
            ),
        ),
        order_reference=order_reference,
        shipment_refs=shipment_refs,
        tenders=_tenders(payload, source_id=source_id),
        refunds=_refunds(payload, source_id=source_id),
    )


def parse_amazon_payload(payload: Mapping[str, object]) -> EvidenceParseResult:
    """Parse structured fields extracted from representative Amazon evidence."""

    def build() -> PurchaseDraft:
        event_type = _text(payload.get("event_type"), label="Amazon event type")
        if event_type not in {"order", "dispatch", "invoice", "refund"}:
            raise EvidenceValidationError("Amazon event type is not supported")
        default_status = (
            PurchaseStatus.PARTLY_REFUNDED
            if event_type == "refund"
            else PurchaseStatus.FULFILLED
        )
        return _parse_document_purchase(
            payload,
            source_kind=EvidenceSourceKind.AMAZON_EMAIL,
            source_id_label="Amazon evidence ID",
            default_merchant="Amazon",
            default_line_kind=PurchaseLineKind.PRODUCT,
            default_status=default_status,
            default_confidence_bps=9_200,
        )

    return _result(build)


def parse_e_receipt(payload: Mapping[str, object]) -> EvidenceParseResult:
    """Parse a common structured e-receipt without merchant-specific inference."""

    return _result(
        lambda: _parse_document_purchase(
            payload,
            source_kind=EvidenceSourceKind.E_RECEIPT,
            source_id_label="Receipt evidence ID",
            default_merchant=None,
            default_line_kind=PurchaseLineKind.PRODUCT,
            default_confidence_bps=8_800,
        )
    )


def parse_service_invoice(payload: Mapping[str, object]) -> EvidenceParseResult:
    """Parse structured service-invoice fields; included VAT remains memo-only."""

    collection = "services" if "services" in payload else "lines"
    return _result(
        lambda: _parse_document_purchase(
            payload,
            source_kind=EvidenceSourceKind.SERVICE_INVOICE,
            source_id_label="Invoice evidence ID",
            default_merchant=None,
            default_line_kind=PurchaseLineKind.SERVICE,
            line_collection=collection,
            default_status=PurchaseStatus.FULFILLED,
            default_confidence_bps=9_000,
        )
    )


def parse_natural_language_payload(payload: Mapping[str, object]) -> EvidenceParseResult:
    """Validate already-reviewed user itemisation without inferring missing lines."""

    return _result(
        lambda: _parse_document_purchase(
            payload,
            source_kind=EvidenceSourceKind.NATURAL_LANGUAGE,
            source_id_label="Reviewed capture ID",
            default_merchant=None,
            default_line_kind=PurchaseLineKind.PRODUCT,
            default_status=PurchaseStatus.FULFILLED,
            default_confidence_bps=10_000,
            line_evidence_status=EvidenceStatus.USER_CONFIRMED,
        )
    )
