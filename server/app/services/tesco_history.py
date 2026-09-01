"""Bounded Tesco purchase-history parsing and household trend summaries.

The portability file is treated as transient input. HausKlar keeps only the
small set of transaction facts useful to the family and never stores the raw
report, account profile, addresses, payment details, or Tesco credentials.
"""

from __future__ import annotations

import hashlib
import io
import json
import re
import uuid
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import PurePath
from typing import Any, Iterable

from app.models.grocery import TescoHistorySummary, TescoHistoryUsual


MAX_JSON_FILES = 40
MAX_JSON_DEPTH = 14
MAX_ORDERS = 25_000
MAX_LINES = 250_000


class TescoHistoryError(ValueError):
    """A safe, user-facing portability-file validation error."""


@dataclass(frozen=True)
class TescoHistoryLine:
    product_name: str
    normalized_name: str
    quantity: float
    unit: str | None
    unit_price_pence: int | None
    line_total_pence: int | None
    external_product_id: str | None


@dataclass(frozen=True)
class TescoHistoryOrder:
    external_order_id: str | None
    purchased_at: str
    channel: str | None
    store_name: str | None
    total_pence: int | None
    currency: str
    lines: tuple[TescoHistoryLine, ...]
    fingerprint: str


@dataclass(frozen=True)
class ParsedTescoHistory:
    filename: str
    sha256: str
    orders: tuple[TescoHistoryOrder, ...]
    issues: tuple[str, ...]

    @property
    def line_count(self) -> int:
        return sum(len(order.lines) for order in self.orders)

    @property
    def first_purchased_at(self) -> str | None:
        return min((order.purchased_at for order in self.orders), default=None)

    @property
    def last_purchased_at(self) -> str | None:
        return max((order.purchased_at for order in self.orders), default=None)

    @property
    def sample_items(self) -> list[str]:
        counts = Counter(
            line.product_name
            for order in self.orders
            for line in order.lines
        )
        return [name for name, _ in counts.most_common(5)]


def _key(value: object) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).casefold())


def _clean_text(value: object, *, limit: int) -> str | None:
    if value is None or isinstance(value, (dict, list, bool)):
        return None
    cleaned = re.sub(r"\s+", " ", str(value)).strip()
    return cleaned[:limit] if cleaned else None


def _field(mapping: dict[str, Any], aliases: Iterable[str]) -> Any:
    wanted = {_key(alias) for alias in aliases}
    for name, value in mapping.items():
        if _key(name) in wanted:
            return value
    return None


def _nested_field(mapping: dict[str, Any], aliases: Iterable[str]) -> Any:
    direct = _field(mapping, aliases)
    if direct is not None:
        return direct
    for container_name in ("product", "item", "article", "sku", "details"):
        nested = _field(mapping, (container_name,))
        if isinstance(nested, dict):
            value = _field(nested, aliases)
            if value is not None:
                return value
    return None


def _date_value(value: object) -> str | None:
    text = _clean_text(value, limit=80)
    if not text:
        return None
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        try:
            return date.fromisoformat(text).isoformat()
        except ValueError:
            return None
    iso_candidate = text.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(iso_candidate)
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone(timezone.utc)
        return parsed.isoformat().replace("+00:00", "Z")
    except ValueError:
        pass
    for pattern in (
        "%d/%m/%Y",
        "%d-%m-%Y",
        "%d %B %Y",
        "%d %b %Y",
        "%d/%m/%Y %H:%M",
        "%d %B %Y %H:%M",
    ):
        try:
            parsed = datetime.strptime(text, pattern)
            return parsed.isoformat() if any(token in pattern for token in ("%H", "%M")) else parsed.date().isoformat()
        except ValueError:
            continue
    return None


def _decimal(value: object) -> Decimal | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float, Decimal)):
        text = str(value)
    else:
        text = str(value).strip()
        match = re.search(r"-?\d[\d,]*(?:\.\d+)?", text)
        if not match:
            return None
        text = match.group(0).replace(",", "")
    try:
        result = Decimal(text)
    except InvalidOperation:
        return None
    return result if result.is_finite() else None


def _money(mapping: dict[str, Any], aliases: Iterable[str]) -> int | None:
    aliases = tuple(aliases)
    value = _nested_field(mapping, aliases)
    amount = _decimal(value)
    if amount is None or amount < 0:
        return None
    matched_key = ""
    wanted = {_key(alias) for alias in aliases}
    for name in mapping:
        if _key(name) in wanted:
            matched_key = _key(name)
            break
    if any(marker in matched_key for marker in ("minor", "pence", "pennies")):
        return int(amount)
    return int((amount * 100).quantize(Decimal("1")))


def _quantity(value: object) -> float:
    amount = _decimal(value)
    if amount is None or amount <= 0:
        return 1.0
    return min(float(amount), 100_000.0)


def normalize_product_name(name: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", " ", name.casefold()).strip()
    return re.sub(r"\s+", " ", normalized)[:300]


_ITEM_NAME_ALIASES = (
    "product_name",
    "productName",
    "item_name",
    "itemName",
    "description",
    "product_description",
    "productDescription",
    "title",
)
_ITEM_CONTAINER_ALIASES = (
    "items",
    "products",
    "lines",
    "order_items",
    "orderItems",
    "transaction_items",
    "transactionItems",
    "basket_items",
    "basketItems",
    "basket",
)
_DATE_ALIASES = (
    "purchased_at",
    "purchasedAt",
    "purchase_date",
    "purchaseDate",
    "transaction_date",
    "transactionDate",
    "transaction_datetime",
    "transactionDateTime",
    "order_date",
    "orderDate",
    "date",
)
_ORDER_ID_ALIASES = (
    "order_id",
    "orderId",
    "order_number",
    "orderNumber",
    "order_reference",
    "orderReference",
    "transaction_id",
    "transactionId",
    "transaction_number",
    "receipt_id",
    "receiptId",
)


def _item_rows(value: object) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [row for row in value if isinstance(row, dict)]
    if isinstance(value, dict):
        direct = [row for row in value.values() if isinstance(row, dict)]
        if direct:
            return direct
        for nested in value.values():
            if isinstance(nested, list):
                return [row for row in nested if isinstance(row, dict)]
    return []


def _parse_line(row: dict[str, Any]) -> TescoHistoryLine | None:
    name = _clean_text(_nested_field(row, _ITEM_NAME_ALIASES), limit=300)
    if not name:
        return None
    normalized = normalize_product_name(name)
    if not normalized:
        return None
    quantity = _quantity(
        _nested_field(row, ("quantity", "qty", "count", "item_count", "itemCount"))
    )
    unit = _clean_text(
        _nested_field(row, ("unit", "unit_description", "unitDescription", "measure")),
        limit=50,
    )
    line_total = _money(
        row,
        (
            "line_total_pence",
            "lineTotalPence",
            "line_total_minor",
            "lineTotalMinor",
            "line_total",
            "lineTotal",
            "net_amount",
            "netAmount",
            "amount",
            "total_price",
            "totalPrice",
        ),
    )
    unit_price = _money(
        row,
        (
            "unit_price_pence",
            "unitPricePence",
            "unit_price_minor",
            "unitPriceMinor",
            "unit_price",
            "unitPrice",
            "price",
        ),
    )
    if unit_price is None and line_total is not None and quantity > 0:
        unit_price = int(round(line_total / quantity))
    product_id = _clean_text(
        _nested_field(
            row,
            ("product_id", "productId", "product_code", "productCode", "sku", "gtin", "ean"),
        ),
        limit=120,
    )
    return TescoHistoryLine(
        product_name=name,
        normalized_name=normalized,
        quantity=quantity,
        unit=unit,
        unit_price_pence=unit_price,
        line_total_pence=line_total,
        external_product_id=product_id,
    )


def _order_fingerprint(
    *,
    external_order_id: str | None,
    purchased_at: str,
    store_name: str | None,
    total_pence: int | None,
    lines: Iterable[TescoHistoryLine],
) -> str:
    if external_order_id:
        identity = re.sub(r"\s+", "", external_order_id.casefold())
        return hashlib.sha256(f"tesco-order:{identity}".encode()).hexdigest()
    facts = {
        "purchased_at": purchased_at,
        "store": store_name or "",
        "total": total_pence,
        "lines": sorted(
            (
                line.normalized_name,
                line.quantity,
                line.line_total_pence,
            )
            for line in lines
        ),
    }
    return hashlib.sha256(
        json.dumps(facts, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def _parse_order(row: dict[str, Any]) -> TescoHistoryOrder | None:
    item_value = _field(row, _ITEM_CONTAINER_ALIASES)
    raw_items = _item_rows(item_value)
    if not raw_items:
        return None
    purchased_at = _date_value(_field(row, _DATE_ALIASES))
    if not purchased_at:
        return None
    lines = tuple(line for item in raw_items if (line := _parse_line(item)) is not None)
    if not lines:
        return None
    external_order_id = _clean_text(_field(row, _ORDER_ID_ALIASES), limit=200)
    channel = _clean_text(
        _field(row, ("channel", "fulfilment_type", "fulfilmentType", "order_type", "orderType")),
        limit=80,
    )
    store_name = _clean_text(
        _field(row, ("store_name", "storeName", "store", "location_name", "locationName")),
        limit=200,
    )
    total_pence = _money(
        row,
        (
            "total_pence",
            "totalPence",
            "total_minor",
            "totalMinor",
            "final_total",
            "finalTotal",
            "order_total",
            "orderTotal",
            "transaction_total",
            "transactionTotal",
            "total",
        ),
    )
    currency = (_clean_text(_field(row, ("currency", "currency_code", "currencyCode")), limit=3) or "GBP").upper()
    if not re.fullmatch(r"[A-Z]{3}", currency):
        currency = "GBP"
    return TescoHistoryOrder(
        external_order_id=external_order_id,
        purchased_at=purchased_at,
        channel=channel,
        store_name=store_name,
        total_pence=total_pence,
        currency=currency,
        lines=lines,
        fingerprint=_order_fingerprint(
            external_order_id=external_order_id,
            purchased_at=purchased_at,
            store_name=store_name,
            total_pence=total_pence,
            lines=lines,
        ),
    )


def _flat_line(row: dict[str, Any]) -> tuple[str, str | None, TescoHistoryLine] | None:
    # Some reports emit one product per transaction row instead of nesting an
    # items array. Requiring a transaction id and product-specific name keeps
    # profile/address records from being mistaken for purchases.
    purchased_at = _date_value(_field(row, _DATE_ALIASES))
    external_order_id = _clean_text(_field(row, _ORDER_ID_ALIASES), limit=200)
    name = _clean_text(
        _nested_field(
            row,
            ("product_name", "productName", "item_name", "itemName", "product_description"),
        ),
        limit=300,
    )
    if not purchased_at or not external_order_id or not name:
        return None
    candidate = dict(row)
    candidate.setdefault("product_name", name)
    line = _parse_line(candidate)
    return (purchased_at, external_order_id, line) if line else None


def _orders_from_document(document: object) -> list[TescoHistoryOrder]:
    found: dict[str, TescoHistoryOrder] = {}
    flat: dict[tuple[str, str], list[TescoHistoryLine]] = defaultdict(list)
    visited = 0

    def walk(value: object, depth: int) -> None:
        nonlocal visited
        visited += 1
        if visited > 1_000_000:
            raise TescoHistoryError("The Tesco report contains too many records")
        if depth > MAX_JSON_DEPTH:
            return
        if isinstance(value, dict):
            parsed = _parse_order(value)
            if parsed is not None:
                found.setdefault(parsed.fingerprint, parsed)
                return
            flat_line = _flat_line(value)
            if flat_line is not None:
                purchased_at, external_id, line = flat_line
                flat[(purchased_at, external_id)].append(line)
            for nested in value.values():
                if isinstance(nested, (dict, list)):
                    walk(nested, depth + 1)
        elif isinstance(value, list):
            for nested in value:
                if isinstance(nested, (dict, list)):
                    walk(nested, depth + 1)

    walk(document, 0)
    for (purchased_at, external_id), lines in flat.items():
        fingerprint = _order_fingerprint(
            external_order_id=external_id,
            purchased_at=purchased_at,
            store_name=None,
            total_pence=None,
            lines=lines,
        )
        found.setdefault(
            fingerprint,
            TescoHistoryOrder(
                external_order_id=external_id,
                purchased_at=purchased_at,
                channel=None,
                store_name=None,
                total_pence=sum(
                    line.line_total_pence for line in lines if line.line_total_pence is not None
                ) or None,
                currency="GBP",
                lines=tuple(lines),
                fingerprint=fingerprint,
            ),
        )
    return list(found.values())


def _json_documents(data: bytes, filename: str, *, max_uncompressed_bytes: int) -> list[object]:
    documents: list[object] = []
    if zipfile.is_zipfile(io.BytesIO(data)):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                entries = [entry for entry in archive.infolist() if not entry.is_dir()]
                json_entries = [entry for entry in entries if entry.filename.casefold().endswith(".json")]
                if not json_entries:
                    raise TescoHistoryError("The Tesco archive does not contain a JSON report")
                if len(json_entries) > MAX_JSON_FILES:
                    raise TescoHistoryError("The Tesco archive contains too many files")
                total = sum(entry.file_size for entry in json_entries)
                if total > max_uncompressed_bytes:
                    raise TescoHistoryError("The uncompressed Tesco report is too large")
                for entry in json_entries:
                    if entry.flag_bits & 0x1:
                        raise TescoHistoryError("Password-protected Tesco archives are not supported")
                    try:
                        documents.append(json.loads(archive.read(entry).decode("utf-8-sig")))
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        raise TescoHistoryError("A JSON file in the Tesco archive could not be read") from exc
        except zipfile.BadZipFile as exc:
            raise TescoHistoryError("The Tesco archive could not be read") from exc
        return documents
    if not filename.casefold().endswith(".json"):
        raise TescoHistoryError("Choose the Tesco JSON file or ZIP archive")
    try:
        return [json.loads(data.decode("utf-8-sig"))]
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise TescoHistoryError("The Tesco JSON file could not be read") from exc


def parse_history_file(
    data: bytes,
    *,
    filename: str,
    max_uncompressed_bytes: int,
) -> ParsedTescoHistory:
    if not data:
        raise TescoHistoryError("The Tesco file is empty")
    safe_name = PurePath(filename or "tesco-history.json").name[:255]
    stored_name = "tesco-history.zip" if zipfile.is_zipfile(io.BytesIO(data)) else "tesco-history.json"
    documents = _json_documents(
        data,
        safe_name,
        max_uncompressed_bytes=max_uncompressed_bytes,
    )
    orders_by_fingerprint: dict[str, TescoHistoryOrder] = {}
    for document in documents:
        for order in _orders_from_document(document):
            orders_by_fingerprint.setdefault(order.fingerprint, order)
            if len(orders_by_fingerprint) > MAX_ORDERS:
                raise TescoHistoryError("The Tesco report contains too many shops")
    orders = sorted(orders_by_fingerprint.values(), key=lambda order: order.purchased_at)
    line_count = sum(len(order.lines) for order in orders)
    if line_count > MAX_LINES:
        raise TescoHistoryError("The Tesco report contains too many item lines")
    if not orders:
        raise TescoHistoryError(
            "No Tesco shops were recognised. Download the transactional data report and try again"
        )
    issues: list[str] = []
    without_totals = sum(order.total_pence is None for order in orders)
    if without_totals:
        issues.append(
            f"{without_totals} {'shop has' if without_totals == 1 else 'shops have'} no order total"
        )
    return ParsedTescoHistory(
        # The original export name can contain the account holder's name. It
        # is useful only while validating the upload, so persist a neutral one.
        filename=stored_name,
        sha256=hashlib.sha256(data).hexdigest(),
        orders=tuple(orders),
        issues=tuple(issues),
    )


async def import_history(
    db,
    *,
    family_id: str,
    user_id: str,
    parsed: ParsedTescoHistory,
) -> tuple[str, int, int]:
    """Import only new orders, atomically. Returns import id/new/skipped."""
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        existing_import = await (
            await db.execute(
                "SELECT id FROM tesco_history_imports WHERE family_id = ? "
                "AND source_sha256 = ? AND deleted_at IS NULL",
                (family_id, parsed.sha256),
            )
        ).fetchone()
        if existing_import is not None:
            await db.commit()
            return existing_import["id"], 0, len(parsed.orders)

        import_id = str(uuid.uuid4())
        imported = 0
        skipped = 0
        imported_lines = 0
        for order in parsed.orders:
            existing_order = await (
                await db.execute(
                    "SELECT id FROM tesco_history_orders WHERE family_id = ? "
                    "AND source_fingerprint = ? AND deleted_at IS NULL",
                    (family_id, order.fingerprint),
                )
            ).fetchone()
            if existing_order is not None:
                skipped += 1
                continue
            order_id = str(uuid.uuid4())
            await db.execute(
                """
                INSERT INTO tesco_history_orders
                    (id, import_id, source_kind, external_order_id, purchased_at,
                     channel, store_name, total_pence, currency, source_fingerprint,
                     family_id, created_at, updated_at, created_by, client_id)
                VALUES (?, ?, 'data_export', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    order_id,
                    import_id,
                    order.external_order_id,
                    order.purchased_at,
                    order.channel,
                    order.store_name,
                    order.total_pence,
                    order.currency,
                    order.fingerprint,
                    family_id,
                    now,
                    now,
                    user_id,
                    f"tesco-export:{parsed.sha256}",
                ),
            )
            for line in order.lines:
                await db.execute(
                    """
                    INSERT INTO tesco_history_lines
                        (id, order_id, external_product_id, product_name,
                         normalized_name, quantity, unit, unit_price_pence,
                         line_total_pence, family_id, created_at, updated_at,
                         created_by, client_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        order_id,
                        line.external_product_id,
                        line.product_name,
                        line.normalized_name,
                        line.quantity,
                        line.unit,
                        line.unit_price_pence,
                        line.line_total_pence,
                        family_id,
                        now,
                        now,
                        user_id,
                        f"tesco-order:{order.fingerprint}",
                    ),
                )
                imported_lines += 1
            imported += 1
        await db.execute(
            """
            INSERT INTO tesco_history_imports
                (id, source_sha256, filename, parsed_order_count,
                 imported_order_count, line_count, first_purchased_at,
                 last_purchased_at, family_id, created_at, updated_at,
                 created_by, client_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                import_id,
                parsed.sha256,
                parsed.filename,
                len(parsed.orders),
                imported,
                imported_lines,
                parsed.first_purchased_at,
                parsed.last_purchased_at,
                family_id,
                now,
                now,
                user_id,
                f"tesco-export:{parsed.sha256}",
            ),
        )
        await db.commit()
        return import_id, imported, skipped
    except BaseException:
        await db.rollback()
        raise


async def import_receipt_payload(
    db,
    *,
    family_id: str,
    actor_id: str | None,
    payload: dict[str, object],
) -> bool:
    """Add one already-verified household Tesco receipt to shared history."""
    purchased_at = _date_value(payload.get("purchased_at"))
    raw_lines = payload.get("lines")
    if not purchased_at or not isinstance(raw_lines, list):
        return False
    lines: list[TescoHistoryLine] = []
    for raw in raw_lines:
        if not isinstance(raw, dict):
            continue
        description = _clean_text(raw.get("description"), limit=300)
        if not description:
            continue
        quantity = _quantity(raw.get("quantity"))
        line_total = raw.get("net_minor")
        if not isinstance(line_total, int) or line_total < 0:
            line_total = None
        lines.append(
            TescoHistoryLine(
                product_name=description,
                normalized_name=normalize_product_name(description),
                quantity=quantity,
                unit=None,
                unit_price_pence=(int(round(line_total / quantity)) if line_total is not None else None),
                line_total_pence=line_total,
                external_product_id=None,
            )
        )
    if not lines:
        return False
    external_id = _clean_text(
        payload.get("order_reference") or payload.get("purchase_reference"),
        limit=200,
    )
    total = payload.get("final_total_minor")
    total_pence = total if isinstance(total, int) and total >= 0 else None
    fingerprint = _order_fingerprint(
        external_order_id=external_id,
        purchased_at=purchased_at,
        store_name=None,
        total_pence=total_pence,
        lines=lines,
    )
    existing = await (
        await db.execute(
            "SELECT 1 FROM tesco_history_orders WHERE family_id = ? "
            "AND source_fingerprint = ? AND deleted_at IS NULL",
            (family_id, fingerprint),
        )
    ).fetchone()
    if existing is not None:
        return False
    now = datetime.now(timezone.utc).isoformat()
    order_id = str(uuid.uuid4())
    currency = str(payload.get("currency") or "GBP").upper()
    if not re.fullmatch(r"[A-Z]{3}", currency):
        currency = "GBP"
    await db.execute(
        """
        INSERT INTO tesco_history_orders
            (id, import_id, source_kind, external_order_id, purchased_at,
             channel, store_name, total_pence, currency, source_fingerprint,
             family_id, created_at, updated_at, created_by, client_id)
        VALUES (?, NULL, 'receipt_email', ?, ?, 'online', NULL, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            order_id,
            external_id,
            purchased_at,
            total_pence,
            currency,
            fingerprint,
            family_id,
            now,
            now,
            actor_id,
            f"tesco-receipt:{external_id or fingerprint}",
        ),
    )
    for line in lines:
        await db.execute(
            """
            INSERT INTO tesco_history_lines
                (id, order_id, product_name, normalized_name, quantity,
                 unit_price_pence, line_total_pence, family_id, created_at,
                 updated_at, created_by, client_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                order_id,
                line.product_name,
                line.normalized_name,
                line.quantity,
                line.unit_price_pence,
                line.line_total_pence,
                family_id,
                now,
                now,
                actor_id,
                f"tesco-receipt:{external_id or fingerprint}",
            ),
        )
    return True


async def history_summary(db, *, family_id: str) -> TescoHistorySummary:
    totals = await (
        await db.execute(
            """
            SELECT COUNT(*) AS shops, MIN(purchased_at) AS first_shop,
                   MAX(purchased_at) AS last_shop
            FROM tesco_history_orders
            WHERE family_id = ? AND deleted_at IS NULL
            """,
            (family_id,),
        )
    ).fetchone()
    line_count = await (
        await db.execute(
            "SELECT COUNT(*) AS lines FROM tesco_history_lines "
            "WHERE family_id = ? AND deleted_at IS NULL",
            (family_id,),
        )
    ).fetchone()
    latest_import = await (
        await db.execute(
            "SELECT created_at FROM tesco_history_imports WHERE family_id = ? "
            "AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1",
            (family_id,),
        )
    ).fetchone()
    monitoring = await (
        await db.execute(
            """
            SELECT 1
            FROM finance_email_enrollments enrollment
            JOIN finance_email_aliases alias
              ON alias.id = enrollment.alias_id
             AND alias.family_id = enrollment.family_id
             AND alias.deleted_at IS NULL
            WHERE enrollment.family_id = ?
              AND alias.alias_kind = 'HOUSEHOLD'
              AND enrollment.status = 'ACTIVE'
              AND enrollment.deleted_at IS NULL
              AND (LOWER(enrollment.retailer_domain) = 'tesco.com'
                   OR LOWER(enrollment.retailer_domain) LIKE '%.tesco.com')
            LIMIT 1
            """,
            (family_id,),
        )
    ).fetchone()
    rows = await (
        await db.execute(
            """
            SELECT line.normalized_name, line.product_name, line.quantity,
                   line.unit_price_pence, line.line_total_pence,
                   orders.id AS order_id, orders.purchased_at
            FROM tesco_history_lines line
            JOIN tesco_history_orders orders
              ON orders.id = line.order_id
             AND orders.family_id = line.family_id
             AND orders.deleted_at IS NULL
            WHERE line.family_id = ? AND line.deleted_at IS NULL
            ORDER BY orders.purchased_at DESC, line.created_at DESC
            LIMIT 50000
            """,
            (family_id,),
        )
    ).fetchall()
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        grouped[row["normalized_name"]].append(dict(row))
    usuals: list[TescoHistoryUsual] = []
    for item_rows in grouped.values():
        order_ids = {str(row["order_id"]) for row in item_rows}
        if len(order_ids) < 2:
            continue
        prices: list[int] = []
        seen_price_orders: set[str] = set()
        for row in item_rows:
            order_id = str(row["order_id"])
            if order_id in seen_price_orders:
                continue
            price = row["unit_price_pence"]
            if price is None and row["line_total_pence"] is not None and row["quantity"]:
                price = int(round(int(row["line_total_pence"]) / float(row["quantity"])))
            if price is not None:
                prices.append(int(price))
                seen_price_orders.add(order_id)
        usuals.append(
            TescoHistoryUsual(
                name=str(item_rows[0]["product_name"]),
                shop_count=len(order_ids),
                last_bought=str(item_rows[0]["purchased_at"]),
                latest_price_pence=prices[0] if prices else None,
                previous_price_pence=prices[1] if len(prices) > 1 else None,
            )
        )
    usuals.sort(key=lambda item: (-item.shop_count, item.name.casefold()))
    visible_usuals = usuals[:8]
    rises = sum(
        item.latest_price_pence is not None
        and item.previous_price_pence is not None
        and item.latest_price_pence > item.previous_price_pence
        for item in visible_usuals
    )
    return TescoHistorySummary(
        shop_count=int(totals["shops"] or 0),
        line_count=int(line_count["lines"] or 0),
        first_purchased_at=totals["first_shop"],
        last_purchased_at=totals["last_shop"],
        last_imported_at=latest_import["created_at"] if latest_import else None,
        receipt_monitoring=monitoring is not None,
        price_rise_count=rises,
        usuals=visible_usuals,
    )
