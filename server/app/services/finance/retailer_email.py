"""Deterministic parsing for a small set of redacted sample email layouts.

The parsers deliberately recognise labelled facts rather than trying to infer the
contents of arbitrary prose. A recognised retailer whose layout no longer matches
raises ``RetailerEmailFormatError`` so intake can retain the source as a review
exception under the correct adapter instead of pretending the source is unsupported.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation
from email.utils import parseaddr


_AMAZON_DOMAINS = ("amazon.co.uk", "amazon.example.invalid")
_TESCO_DOMAINS = ("tesco.com", "tesco.example.invalid")
_ORDER_REFERENCE = re.compile(
    r"^(?:order(?:\s+(?:number|no\.?))?|order\s*#)\s*:\s*(\S(?:.*\S)?)$",
    re.IGNORECASE,
)
_RECEIPT_REFERENCE = re.compile(
    r"^(?:receipt(?:\s+(?:number|no\.?))?|receipt\s*#)\s*:\s*(\S(?:.*\S)?)$",
    re.IGNORECASE,
)
_DATE_LABEL = re.compile(
    r"^(?:order date|purchase date|receipt date|date)\s*:\s*(.+)$",
    re.IGNORECASE,
)
_SHIPMENT = re.compile(
    r"^shipment(?:\s+\d+\s+of\s+\d+)?\s*:\s*(\S(?:.*\S)?)$",
    re.IGNORECASE,
)
_AMAZON_ITEM = re.compile(
    r"^(?:item\s*:\s*(?P<labelled>\S(?:.*\S)?)|"
    r"(?P<count>\d+(?:\.\d{1,3})?)\s+of\s*:\s*(?P<counted>\S(?:.*\S)?))$",
    re.IGNORECASE,
)
_QUANTITY = re.compile(r"^(?:qty|quantity)\s*:\s*(\d+(?:\.\d{1,3})?)$", re.IGNORECASE)
_TESCO_ITEM = re.compile(r"^(\d+(?:\.\d{1,3})?)\s*[x×]\s*(\S(?:.*\S)?)$", re.IGNORECASE)
_GENERIC_ITEM = re.compile(r"^(\S(?:.*?\S)?)\s*\|\s*(\d+(?:\.\d{1,3})?)\s*\|\s*([^|]+)$")
_CARD_CHARGE = re.compile(
    r"^charge\s*:\s*.+?ending\s+in\s+(\d{2,8})\s*\|\s*(.+)$",
    re.IGNORECASE,
)
_LABELLED_MONEY = re.compile(r"^([^:]{1,80})\s*:\s*(.+)$")
_CURRENCY_SYMBOLS = {"£": "GBP", "$": "USD", "€": "EUR"}
_MAX_LINES = 2_000
_MAX_LINE_CHARS = 4_000
_MAX_ITEMS = 200


@dataclass(frozen=True, slots=True)
class RetailerEmailFormatError(ValueError):
    """A supported sender was recognised but its facts were not safe to parse."""

    adapter: str
    code: str
    safe_message: str

    def __str__(self) -> str:  # pragma: no cover - defensive logging only
        return self.safe_message


def _fail(adapter: str, code: str, message: str) -> RetailerEmailFormatError:
    return RetailerEmailFormatError(adapter=adapter, code=code, safe_message=message)


def _lines(body_text: str) -> list[str]:
    result = [
        re.sub(r"\s+", " ", value.replace("\xa0", " ")).strip() for value in body_text.splitlines()
    ]
    return [value[:_MAX_LINE_CHARS] for value in result if value][:_MAX_LINES]


def _sender_domain(sender: str) -> str:
    address = (parseaddr(sender)[1] or sender).strip().casefold()
    return address.rpartition("@")[2].rstrip(".")


def _matches_domain(domain: str, expected: tuple[str, ...]) -> bool:
    return any(domain == item or domain.endswith(f".{item}") for item in expected)


def _first_match(lines: list[str], pattern: re.Pattern[str]) -> str | None:
    for line in lines:
        match = pattern.fullmatch(line)
        if match:
            return match.group(1).strip()
    return None


def _date(value: str, *, adapter: str) -> str:
    cleaned = value.strip().replace(",", "")
    for pattern in ("%Y-%m-%d", "%d %B %Y", "%d %b %Y", "%d/%m/%Y"):
        try:
            return datetime.strptime(cleaned, pattern).date().isoformat()
        except ValueError:
            continue
    raise _fail(
        adapter,
        "retailer_email_date_unrecognised",
        "The retailer email date needs review before its items can be saved.",
    )


def _money(value: str, *, adapter: str) -> tuple[int, str]:
    cleaned = value.strip().replace("\xa0", " ")
    sign = -1 if cleaned.startswith("-") else 1
    cleaned = cleaned.lstrip("+-").strip()
    symbol = next((item for item in _CURRENCY_SYMBOLS if item in cleaned), None)
    if symbol is None:
        raise _fail(
            adapter,
            "retailer_email_currency_missing",
            "The retailer email amount has no supported currency symbol.",
        )
    currency = _CURRENCY_SYMBOLS[symbol]
    number = cleaned.replace(symbol, "").replace(" ", "")
    if re.fullmatch(r"\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?", number):
        number = number.replace(",", "")
    elif re.fullmatch(r"\d+(?:\.\d{1,2})?", number):
        pass
    elif re.fullmatch(r"\d{1,3}(?:\.\d{3})*(?:,\d{1,2})?", number):
        number = number.replace(".", "").replace(",", ".")
    elif re.fullmatch(r"\d+(?:,\d{1,2})?", number):
        number = number.replace(",", ".")
    else:
        raise _fail(
            adapter,
            "retailer_email_amount_unrecognised",
            "A retailer email amount needs review before its items can be saved.",
        )
    try:
        amount = Decimal(number)
    except InvalidOperation as exc:  # pragma: no cover - guarded by regex
        raise _fail(
            adapter,
            "retailer_email_amount_unrecognised",
            "A retailer email amount needs review before its items can be saved.",
        ) from exc
    if amount.as_tuple().exponent < -2:
        raise _fail(
            adapter,
            "retailer_email_amount_unrecognised",
            "A retailer email amount needs review before its items can be saved.",
        )
    return sign * int(amount * 100), currency


def _labelled_amount(
    lines: list[str],
    labels: tuple[str, ...],
    *,
    adapter: str,
    required: bool = False,
) -> tuple[int, str] | None:
    expected = {value.casefold() for value in labels}
    for line in lines:
        match = _LABELLED_MONEY.fullmatch(line)
        if match and match.group(1).strip().casefold() in expected:
            return _money(match.group(2), adapter=adapter)
    if required:
        raise _fail(
            adapter,
            "retailer_email_total_missing",
            "The retailer email total is missing or has changed format.",
        )
    return None


def _same_currency(values: list[tuple[int, str]], *, adapter: str) -> str:
    currencies = {currency for _, currency in values}
    if len(currencies) != 1:
        raise _fail(
            adapter,
            "retailer_email_currency_mismatch",
            "The retailer email contains mixed currencies and needs review.",
        )
    return next(iter(currencies))


def _is_amazon_refund(*, subject: str, lines: list[str]) -> bool:
    """Recognise a refund from explicit event labels, not incidental policy prose."""
    subject_text = subject.casefold()
    if any(
        marker in subject_text
        for marker in ("refund has been processed", "refund processed", "your refund")
    ):
        return True
    labels = {
        match.group(1).strip().casefold()
        for line in lines
        if (match := _LABELLED_MONEY.fullmatch(line)) is not None
    }
    return "total refund" in labels or "refund amount" in labels


def _amazon_payload(*, source_id: str, subject: str, lines: list[str]) -> dict[str, object]:
    adapter = "amazon_email"
    order_reference = _first_match(lines, _ORDER_REFERENCE)
    purchased_at = _first_match(lines, _DATE_LABEL)
    if not order_reference or not purchased_at:
        raise _fail(
            adapter,
            "retailer_email_reference_missing",
            "The Amazon order reference or date is missing and needs review.",
        )

    lower = f"{subject} {' '.join(lines[:30])}".casefold()
    is_refund = _is_amazon_refund(subject=subject, lines=lines)
    event_type = "refund" if is_refund else "dispatch" if "dispatched" in lower else "order"
    status = (
        "refunded" if is_refund else "partly_fulfilled" if event_type == "dispatch" else "pending"
    )
    parsed_lines: list[dict[str, object]] = []
    values: list[tuple[int, str]] = []
    current_shipment: str | None = None
    index = 0
    while index < len(lines):
        shipment_match = _SHIPMENT.fullmatch(lines[index])
        if shipment_match:
            current_shipment = shipment_match.group(1).strip()
            index += 1
            continue
        item_match = _AMAZON_ITEM.fullmatch(lines[index])
        if not item_match:
            index += 1
            continue
        if len(parsed_lines) >= _MAX_ITEMS:
            raise _fail(
                adapter,
                "retailer_email_too_many_items",
                "The Amazon email contains too many item rows for automatic review.",
            )
        description = (item_match.group("labelled") or item_match.group("counted")).strip()
        block_end = next(
            (
                offset
                for offset in range(index + 1, min(len(lines), index + 9))
                if _AMAZON_ITEM.fullmatch(lines[offset]) or _SHIPMENT.fullmatch(lines[offset])
            ),
            min(len(lines), index + 9),
        )
        block = lines[index + 1 : block_end]
        quantity_text = item_match.group("count") or _first_match(block, _QUANTITY)
        amount = _labelled_amount(
            block,
            ("item subtotal", "refund amount" if is_refund else "item total"),
            adapter=adapter,
            required=True,
        )
        assert amount is not None
        amount_minor, currency = amount
        if amount_minor < 0:
            raise _fail(
                adapter,
                "retailer_email_amount_unrecognised",
                "Amazon item values must be shown as positive amounts.",
            )
        discount = _labelled_amount(block, ("item discount",), adapter=adapter)
        discount_minor = abs(discount[0]) if discount else 0
        if discount and discount[1] != currency:
            raise _fail(
                adapter,
                "retailer_email_currency_mismatch",
                "The Amazon item and discount currencies do not match.",
            )
        gross_minor = amount_minor + discount_minor
        line_reference = f"{order_reference}:line:{len(parsed_lines) + 1}"
        row: dict[str, object] = {
            "line_reference": line_reference,
            "description": description,
            "quantity": quantity_text or "1",
            "gross_minor": gross_minor,
            "discount_minor": discount_minor,
            "net_minor": amount_minor,
        }
        for value in block:
            if value.casefold().startswith("asin:"):
                row["product_reference"] = value.split(":", 1)[1].strip()
            elif value.casefold().startswith("sold by:"):
                row["seller"] = value.split(":", 1)[1].strip()
        if current_shipment:
            row["shipment_reference"] = current_shipment
        parsed_lines.append(row)
        values.append((amount_minor, currency))
        index = block_end

    if not parsed_lines:
        raise _fail(
            adapter,
            "retailer_email_items_missing",
            "No confidently labelled Amazon item rows were found.",
        )
    total = _labelled_amount(
        lines,
        ("total refund",) if is_refund else ("order total", "total charged"),
        adapter=adapter,
        required=True,
    )
    assert total is not None
    shipping = _labelled_amount(lines, ("postage & packing", "delivery"), adapter=adapter) or (
        0,
        total[1],
    )
    discount = _labelled_amount(
        lines, ("promotion applied", "order discount"), adapter=adapter
    ) or (0, total[1])
    vat = _labelled_amount(lines, ("vat included",), adapter=adapter) or (0, total[1])
    values.extend((total, shipping, discount, vat))
    currency = _same_currency(values, adapter=adapter)
    final_total = abs(total[0])
    payload: dict[str, object] = {
        "source_id": source_id,
        "purchase_reference": (
            f"{order_reference}:refund:{source_id}" if is_refund else order_reference
        ),
        "order_reference": order_reference,
        "event_type": event_type,
        "merchant": "Amazon UK",
        "purchased_at": _date(purchased_at, adapter=adapter),
        "currency": currency,
        "lines": parsed_lines,
        "shipping_minor": abs(shipping[0]),
        "vat_included_minor": abs(vat[0]),
        "order_discount_minor": abs(discount[0]),
        "final_total_minor": final_total,
        "status": status,
        "confidence_bps": 9400,
    }
    shipment_refs = list(
        dict.fromkeys(
            str(row["shipment_reference"]) for row in parsed_lines if row.get("shipment_reference")
        )
    )
    if shipment_refs:
        payload["shipment_references"] = shipment_refs
    charges: list[dict[str, object]] = []
    for charge_index, line in enumerate(lines):
        match = _CARD_CHARGE.fullmatch(line)
        if not match:
            continue
        amount_minor, charge_currency = _money(match.group(2), adapter=adapter)
        if charge_currency != currency or amount_minor <= 0:
            raise _fail(
                adapter,
                "retailer_email_currency_mismatch",
                "An Amazon payment charge does not match the order currency.",
            )
        charges.append(
            {
                "id": f"{source_id}:charge:{charge_index + 1}",
                "kind": "card",
                "card_suffix": match.group(1),
                "amount_minor": amount_minor,
            }
        )
    if charges:
        payload["charges"] = charges
    if is_refund:
        payload["refunds"] = [
            {
                "refund_reference": f"{source_id}:refund:{position + 1}",
                "line_reference": row["line_reference"],
                "amount_minor": row["net_minor"],
                "quantity": row["quantity"],
            }
            for position, row in enumerate(parsed_lines)
        ]
    return payload


def _tesco_payload(*, source_id: str, lines: list[str]) -> dict[str, object]:
    adapter = "tesco_batch"
    order_reference = _first_match(lines, _ORDER_REFERENCE)
    purchased_at = _first_match(lines, _DATE_LABEL)
    if not order_reference or not purchased_at:
        raise _fail(
            adapter,
            "retailer_email_reference_missing",
            "The Tesco order reference or date is missing and needs review.",
        )
    try:
        start = next(index for index, line in enumerate(lines) if line.casefold() == "items") + 1
    except StopIteration as exc:
        raise _fail(
            adapter,
            "retailer_email_items_missing",
            "The Tesco items section is missing or has changed format.",
        ) from exc
    stop = next(
        (
            index
            for index in range(start, len(lines))
            if lines[index].casefold().startswith("subtotal:")
        ),
        len(lines),
    )
    parsed_lines: list[dict[str, object]] = []
    values: list[tuple[int, str]] = []
    index = start
    while index < stop:
        match = _TESCO_ITEM.fullmatch(lines[index])
        if not match:
            index += 1
            continue
        if index + 1 >= stop:
            raise _fail(
                adapter,
                "retailer_email_item_amount_missing",
                "A Tesco item amount is missing and needs review.",
            )
        amount_minor, currency = _money(lines[index + 1], adapter=adapter)
        if amount_minor < 0:
            raise _fail(
                adapter,
                "retailer_email_amount_unrecognised",
                "Tesco item values must be shown as positive amounts.",
            )
        parsed_lines.append(
            {
                "line_reference": f"{order_reference}:line:{len(parsed_lines) + 1}",
                "description": match.group(2),
                "quantity": match.group(1),
                "net_minor": amount_minor,
            }
        )
        values.append((amount_minor, currency))
        index += 2
    if not parsed_lines:
        raise _fail(
            adapter,
            "retailer_email_items_missing",
            "No confidently labelled Tesco item rows were found.",
        )
    total = _labelled_amount(lines, ("total paid", "order total"), adapter=adapter, required=True)
    assert total is not None
    shipping = _labelled_amount(lines, ("delivery charge",), adapter=adapter) or (0, total[1])
    discount = _labelled_amount(lines, ("clubcard savings", "discounts"), adapter=adapter) or (
        0,
        total[1],
    )
    vat = _labelled_amount(lines, ("vat included",), adapter=adapter) or (0, total[1])
    values.extend((total, shipping, discount, vat))
    currency = _same_currency(values, adapter=adapter)
    return {
        "id": source_id,
        "purchase_reference": order_reference,
        "order_reference": order_reference,
        "merchant": "Tesco",
        "purchased_at": _date(purchased_at, adapter=adapter),
        "currency": currency,
        "lines": parsed_lines,
        "shipping_minor": abs(shipping[0]),
        "vat_included_minor": abs(vat[0]),
        "order_discount_minor": abs(discount[0]),
        "final_total_minor": abs(total[0]),
        "confidence_bps": 9400,
    }


def _generic_payload(*, source_id: str, lines: list[str]) -> dict[str, object]:
    adapter = "e_receipt"
    reference = _first_match(lines, _RECEIPT_REFERENCE) or _first_match(lines, _ORDER_REFERENCE)
    purchased_at = _first_match(lines, _DATE_LABEL)
    merchant = next(
        (
            line.split(":", 1)[1].strip()
            for line in lines
            if line.casefold().startswith("merchant:") and line.split(":", 1)[1].strip()
        ),
        None,
    )
    if not reference or not purchased_at or not merchant:
        raise _fail(
            adapter,
            "retailer_email_reference_missing",
            "The receipt merchant, reference, or date is missing and needs review.",
        )
    parsed_lines: list[dict[str, object]] = []
    values: list[tuple[int, str]] = []
    for line in lines:
        match = _GENERIC_ITEM.fullmatch(line)
        if not match:
            continue
        amount_minor, currency = _money(match.group(3), adapter=adapter)
        if amount_minor < 0:
            raise _fail(
                adapter,
                "retailer_email_amount_unrecognised",
                "Receipt item values must be shown as positive amounts.",
            )
        parsed_lines.append(
            {
                "line_reference": f"{reference}:line:{len(parsed_lines) + 1}",
                "description": match.group(1),
                "quantity": match.group(2),
                "net_minor": amount_minor,
            }
        )
        values.append((amount_minor, currency))
    if not parsed_lines:
        raise _fail(
            adapter,
            "retailer_email_items_missing",
            "No complete receipt item rows were found.",
        )
    total = _labelled_amount(lines, ("total paid", "total"), adapter=adapter, required=True)
    assert total is not None
    shipping = _labelled_amount(lines, ("delivery", "shipping"), adapter=adapter) or (0, total[1])
    discount = _labelled_amount(lines, ("discount",), adapter=adapter) or (0, total[1])
    vat = _labelled_amount(lines, ("vat included", "tax included"), adapter=adapter) or (
        0,
        total[1],
    )
    values.extend((total, shipping, discount, vat))
    currency = _same_currency(values, adapter=adapter)
    return {
        "source_id": source_id,
        "purchase_reference": reference,
        "order_reference": reference,
        "merchant": merchant,
        "purchased_at": _date(purchased_at, adapter=adapter),
        "currency": currency,
        "lines": parsed_lines,
        "shipping_minor": abs(shipping[0]),
        "vat_included_minor": abs(vat[0]),
        "order_discount_minor": abs(discount[0]),
        "final_total_minor": abs(total[0]),
        "confidence_bps": 8800,
    }


def parse_retailer_email(
    *,
    source_id: str,
    subject: str,
    body_text: str,
    sender: str,
) -> tuple[str, dict[str, object]] | None:
    """Return one strictly parsed adapter payload, or ``None`` for an unknown source.

    ``RetailerEmailFormatError`` means the sender is supported but this particular
    message cannot be saved automatically without risking false line items.
    """

    lines = _lines(body_text)
    domain = _sender_domain(sender)
    if _matches_domain(domain, _AMAZON_DOMAINS):
        delivery_only = (
            any(
                marker in " ".join(lines[:30]).casefold()
                for marker in ("expected delivery date", "delivery window")
            )
            and _first_match(lines, _ORDER_REFERENCE) is None
        )
        if delivery_only:
            return None
        return "amazon_email", _amazon_payload(
            source_id=source_id,
            subject=subject,
            lines=lines,
        )
    if _matches_domain(domain, _TESCO_DOMAINS):
        return "tesco_batch", _tesco_payload(source_id=source_id, lines=lines)
    identity = f"{subject} {' '.join(lines[:12])}".casefold()
    if any(marker in identity for marker in ("receipt", "order confirmation")):
        return "e_receipt", _generic_payload(
            source_id=source_id,
            lines=lines,
        )
    return None
