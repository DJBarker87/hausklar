"""Dated product prices, sanitised retailer research and overlap-safe actions."""

import json
import re
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal, ROUND_CEILING, ROUND_FLOOR

from app.models.finance import FinancePreferenceCreate
from app.models.finance_products_assets import (
    FinanceOpportunityActionResponse,
    FinanceProductComparisonCreate,
    FinanceProductComparisonResponse,
    FinanceProductHistoryResponse,
    FinanceProductOpportunityAccept,
    FinanceProductPriceObservationResponse,
    FinanceRetailerResearchRequest,
    FinanceRetailerResearchRequestResponse,
    FinanceRetailerResearchResultCreate,
    FinanceRetailerResearchResultResponse,
)
from app.services.finance.foundation import require_finance_space
from app.services.finance.planning import create_preference, set_preference_status
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

_MAX_HISTORY_ROWS = 2_000
_PACK_SIZE = re.compile(
    r"^\s*(?P<size>[0-9]+(?:\.[0-9]+)?)\s*(?P<unit>kg|g|l|litre|liter|ml)\s*$",
    re.IGNORECASE,
)
_TEXT_TOKENS = re.compile(r"[^\W_]+", re.UNICODE)


class FinanceProductError(ValueError):
    """A product comparison request cannot be supported by the saved evidence."""


class FinanceProductNotFoundError(FinanceProductError):
    """An authorised product comparison record was not found."""


class FinanceProductConflictError(FinanceProductError):
    """A product comparison or accepted action conflicts with existing state."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _decimal_text(value: Decimal | str) -> str:
    parsed = Decimal(value)
    if not parsed.is_finite():
        raise FinanceProductError("Comparable quantities must be finite")
    return format(parsed.normalize(), "f")


def _ceil(value: Decimal) -> int:
    return int(value.to_integral_value(rounding=ROUND_CEILING))


def _floor(value: Decimal) -> int:
    return int(value.to_integral_value(rounding=ROUND_FLOOR))


def _normalise_line_quantity(
    quantity: Decimal, unit_description: str | None
) -> tuple[Decimal, str, str]:
    """Return comparable quantity, basis and display unit without guessing opaque packs."""
    raw = (unit_description or "each").strip().casefold()
    match = _PACK_SIZE.fullmatch(raw)
    if match:
        size = Decimal(match.group("size"))
        unit = match.group("unit").casefold()
        factor = Decimal(1_000) if unit in {"kg", "l", "litre", "liter"} else Decimal(1)
        basis = "g" if unit in {"kg", "g"} else "ml"
        return quantity * size * factor, basis, raw
    if raw in {"kg", "kilogram", "kilograms"}:
        return quantity * Decimal(1_000), "g", raw
    if raw in {"g", "gram", "grams"}:
        return quantity, "g", raw
    if raw in {"l", "litre", "litres", "liter", "liters"}:
        return quantity * Decimal(1_000), "ml", raw
    if raw in {"ml", "millilitre", "millilitres", "milliliter", "milliliters"}:
        return quantity, "ml", raw
    if raw in {"each", "item", "items", "pack", "packs"}:
        return quantity, "each", raw
    return quantity, "opaque", raw


async def _item(db, *, user: dict, space_id: str, item_id: str) -> dict:
    await require_finance_space(db, user=user, space_id=space_id)
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_normalized_purchase_items
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (item_id, space_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceProductNotFoundError("Finance product not found")
    return dict(row)


def _observation_response(row: dict) -> FinanceProductPriceObservationResponse:
    return FinanceProductPriceObservationResponse(
        id=row["id"],
        normalized_item_id=row["normalized_item_id"],
        normalized_item_name=row["normalized_item_name"],
        source_kind=row["source_kind"],
        source_line_id=row["source_line_id"],
        retailer_name=row["retailer_name"],
        product_name=row["product_name"],
        pack_quantity=row["pack_quantity_decimal"],
        pack_unit=row["pack_unit"],
        comparable_quantity=row["comparable_quantity_decimal"],
        unit_basis=row["unit_basis"],
        price_minor=row["price_minor"],
        currency=row["currency"],
        observed_on=row["observed_on"],
        confidence_bps=row["confidence_bps"],
        evidence_refs=json.loads(row["evidence_json"]),
    )


async def rebuild_product_price_history(
    db, *, user: dict, space_id: str
) -> int:
    """Persist exact source-line prices for confirmed normalized products."""
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT line.id AS source_line_id, line.raw_description,
                   line.quantity_decimal, line.unit_description,
                   line.line_net_minor, line.evidence_status,
                   purchase.merchant_name, purchase.currency, purchase.purchased_on,
                   assessment.normalized_item_id, assessment.confidence_bps,
                   item.display_name AS normalized_item_name,
                   COALESCE(refund.refunded_minor, 0) AS refunded_minor,
                   refund.refunded_quantities
            FROM finance_purchase_lines line
            JOIN finance_purchase_records purchase
              ON purchase.id = line.purchase_id AND purchase.space_id = line.space_id
             AND purchase.family_id = line.family_id AND purchase.deleted_at IS NULL
             AND purchase.superseded_by_id IS NULL
            JOIN finance_purchase_line_assessments assessment
              ON assessment.line_id = line.id AND assessment.space_id = line.space_id
             AND assessment.family_id = line.family_id
             AND assessment.review_status = 'CONFIRMED' AND assessment.deleted_at IS NULL
            JOIN finance_normalized_purchase_items item
              ON item.id = assessment.normalized_item_id AND item.space_id = line.space_id
             AND item.family_id = line.family_id AND item.deleted_at IS NULL
            LEFT JOIN (
                SELECT line_id, space_id, family_id, SUM(amount_minor) AS refunded_minor,
                       GROUP_CONCAT(quantity_decimal, '|') AS refunded_quantities
                FROM finance_line_refunds WHERE deleted_at IS NULL
                GROUP BY line_id, space_id, family_id
            ) refund ON refund.line_id = line.id AND refund.space_id = line.space_id
                    AND refund.family_id = line.family_id
            WHERE line.space_id = ? AND line.family_id = ? AND line.deleted_at IS NULL
              AND line.line_net_minor IS NOT NULL
            ORDER BY purchase.purchased_on, line.id LIMIT ?
            """,
            (space_id, user["family_id"], _MAX_HISTORY_ROWS + 1),
        )
    ).fetchall()
    if len(rows) > _MAX_HISTORY_ROWS:
        raise FinanceProductError("Product history is too large to rebuild in one request")
    inserted = 0
    current_source_line_ids: set[str] = set()
    now = _now()
    async with serialized_create(db):
        for row in rows:
            quantity = Decimal(row["quantity_decimal"])
            returned_quantity = sum(
                (
                    Decimal(value)
                    for value in (row["refunded_quantities"] or "").split("|")
                    if value
                ),
                Decimal(0),
            )
            quantity -= returned_quantity
            price_minor = row["line_net_minor"] - row["refunded_minor"]
            if not quantity.is_finite() or quantity <= 0 or price_minor < 0:
                continue
            current_source_line_ids.add(row["source_line_id"])
            comparable_quantity, unit_basis, pack_unit = _normalise_line_quantity(
                quantity, row["unit_description"]
            )
            evidence_json = json.dumps([f"purchase-line:{row['source_line_id']}"])
            current_values = (
                row["normalized_item_id"],
                row["merchant_name"],
                row["normalized_item_name"],
                _decimal_text(quantity),
                pack_unit,
                _decimal_text(comparable_quantity),
                unit_basis,
                price_minor,
                row["currency"],
                row["purchased_on"],
                row["confidence_bps"],
                evidence_json,
            )
            existing = await (
                await db.execute(
                    """
                    SELECT * FROM finance_product_price_observations
                    WHERE source_line_id = ? AND deleted_at IS NULL
                    """,
                    (row["source_line_id"],),
                )
            ).fetchone()
            if existing is not None:
                saved_values = (
                    existing["normalized_item_id"],
                    existing["retailer_name"],
                    existing["product_name"],
                    existing["pack_quantity_decimal"],
                    existing["pack_unit"],
                    existing["comparable_quantity_decimal"],
                    existing["unit_basis"],
                    existing["price_minor"],
                    existing["currency"],
                    existing["observed_on"],
                    existing["confidence_bps"],
                    existing["evidence_json"],
                )
                if saved_values != current_values:
                    await save_history(
                        db,
                        "finance_product_price_observations",
                        existing["id"],
                        user["id"],
                        family_id=user["family_id"],
                    )
                    await db.execute(
                        """
                        UPDATE finance_product_price_observations
                        SET normalized_item_id = ?, retailer_name = ?, product_name = ?,
                            pack_quantity_decimal = ?, pack_unit = ?,
                            comparable_quantity_decimal = ?, unit_basis = ?,
                            price_minor = ?, currency = ?, observed_on = ?,
                            confidence_bps = ?, evidence_json = ?, updated_at = ?
                        WHERE id = ?
                        """,
                        (*current_values, now, existing["id"]),
                    )
                    inserted += 1
                continue
            await db.execute(
                """
                INSERT INTO finance_product_price_observations
                    (id, space_id, normalized_item_id, source_kind, source_line_id,
                     retailer_name, product_name, pack_quantity_decimal, pack_unit,
                     comparable_quantity_decimal, unit_basis, price_minor, currency,
                     observed_on, confidence_bps, evidence_json, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, 'PURCHASE_LINE', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    space_id,
                    row["normalized_item_id"],
                    row["source_line_id"],
                    row["merchant_name"],
                    row["normalized_item_name"],
                    _decimal_text(quantity),
                    pack_unit,
                    _decimal_text(comparable_quantity),
                    unit_basis,
                    price_minor,
                    row["currency"],
                    row["purchased_on"],
                    row["confidence_bps"],
                    evidence_json,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
            inserted += 1
        existing_rows = await (
            await db.execute(
                """
                SELECT id, source_line_id FROM finance_product_price_observations
                WHERE space_id = ? AND family_id = ? AND source_kind = 'PURCHASE_LINE'
                  AND deleted_at IS NULL
                """,
                (space_id, user["family_id"]),
            )
        ).fetchall()
        for existing in existing_rows:
            if existing["source_line_id"] in current_source_line_ids:
                continue
            await save_history(
                db,
                "finance_product_price_observations",
                existing["id"],
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                """
                UPDATE finance_product_price_observations
                SET deleted_at = ?, updated_at = ? WHERE id = ?
                """,
                (now, now, existing["id"]),
            )
            inserted += 1
    return inserted


async def product_price_history(
    db, *, user: dict, space_id: str, item_id: str, limit: int
) -> FinanceProductHistoryResponse:
    item = await _item(db, user=user, space_id=space_id, item_id=item_id)
    rows = await (
        await db.execute(
            """
            SELECT observation.*, item.display_name AS normalized_item_name
            FROM finance_product_price_observations observation
            JOIN finance_normalized_purchase_items item
              ON item.id = observation.normalized_item_id
             AND item.space_id = observation.space_id
             AND item.family_id = observation.family_id
             AND item.deleted_at IS NULL
            WHERE observation.space_id = ? AND observation.normalized_item_id = ?
              AND observation.family_id = ? AND observation.deleted_at IS NULL
            ORDER BY observation.observed_on DESC, observation.id DESC LIMIT ?
            """,
            (space_id, item_id, user["family_id"], limit),
        )
    ).fetchall()
    observations = [_observation_response(dict(row)) for row in rows]
    return FinanceProductHistoryResponse(
        normalized_item_id=item_id,
        normalized_item_name=item["display_name"],
        data_through=max((item.observed_on for item in observations), default=None),
        observations=observations,
    )


async def create_retailer_research_request(
    db,
    *,
    user: dict,
    space_id: str,
    normalized_item_id: str,
    body: FinanceRetailerResearchRequest,
) -> FinanceRetailerResearchRequestResponse:
    item = await _item(
        db, user=user, space_id=space_id, item_id=normalized_item_id
    )
    if body.normalized_need.strip().casefold() != item["display_name"].strip().casefold():
        raise FinanceProductError(
            "Retailer research need must match the authorised saved product"
        )
    try:
        review_body = FinanceRetailerResearchRequest.model_validate(
            {
                **body.model_dump(mode="python"),
                "normalized_need": item["display_name"].strip(),
            }
        )
    except ValueError as exc:
        raise FinanceProductError(
            "The saved product name is not safe for retailer research"
        ) from exc
    family_names = await (
        await db.execute(
            """
            SELECT name FROM users
            WHERE family_id = ? AND deleted_at IS NULL
            UNION ALL
            SELECT name FROM children
            WHERE family_id = ? AND deleted_at IS NULL
            """,
            (user["family_id"], user["family_id"]),
        )
    ).fetchall()
    protected_tokens = {
        token.casefold()
        for row in family_names
        for token in _TEXT_TOKENS.findall(row["name"])
        if len(token) >= 2
    }
    outbound_text = (
        review_body.normalized_need,
        review_body.brand_variant or "",
        review_body.pack_unit,
        *review_body.quality_constraints,
        *review_body.substitution_constraints,
    )
    if any(
        protected_tokens
        & {token.casefold() for token in _TEXT_TOKENS.findall(value)}
        for value in outbound_text
    ):
        raise FinanceProductError(
            "Retailer research text must not contain a family member's name"
        )
    identifier = str(uuid.uuid4())
    now = _now()
    review_json = json.dumps(
        review_body.model_dump(mode="json"), sort_keys=True, separators=(",", ":")
    )
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_retailer_research_requests
                (id, space_id, normalized_item_id, request_json, status, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, 'REQUESTED', ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                normalized_item_id,
                review_json,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    return FinanceRetailerResearchRequestResponse(
        request_id=identifier,
        review_payload=review_body,
        status="REQUESTED",
        fulfilment_mode="MANUAL_REVIEW",
        message=(
            "Automatic retailer lookup is not configured. This request needs a "
            "person to review dated retailer evidence before results can appear."
        ),
        created_at=now,
    )


def _research_result_response(row: dict) -> FinanceRetailerResearchResultResponse:
    return FinanceRetailerResearchResultResponse(
        id=row["id"],
        request_id=row["request_id"],
        match_kind=row["match_kind"],
        retailer_name=row["retailer_name"],
        product_name=row["product_name"],
        brand_variant=row["brand_variant"],
        pack_quantity=row["pack_quantity_decimal"],
        pack_unit=row["pack_unit"],
        comparable_quantity=row["comparable_quantity_decimal"],
        unit_basis=row["unit_basis"],
        price_minor=row["price_minor"],
        currency=row["currency"],
        observed_on=row["observed_on"],
        delivery_low_minor=row["delivery_low_minor"],
        delivery_high_minor=row["delivery_high_minor"],
        travel_low_minor=row["travel_low_minor"],
        travel_high_minor=row["travel_high_minor"],
        likely_waste_low_bps=row["likely_waste_low_bps"],
        likely_waste_high_bps=row["likely_waste_high_bps"],
        inconvenience_note=row["inconvenience_note"],
        confidence_bps=row["confidence_bps"],
        source_label=row["source_label"],
    )


async def list_retailer_research_results(
    db,
    *,
    user: dict,
    space_id: str,
    item_id: str,
    limit: int,
) -> list[FinanceRetailerResearchResultResponse]:
    """Return saved reviewed retailer results for one authorised product."""
    await _item(db, user=user, space_id=space_id, item_id=item_id)
    rows = await (
        await db.execute(
            """
            SELECT result.*
            FROM finance_retailer_research_results result
            JOIN finance_retailer_research_requests request
              ON request.id = result.request_id
             AND request.space_id = result.space_id
             AND request.family_id = result.family_id
             AND request.deleted_at IS NULL
            WHERE result.space_id = ? AND result.family_id = ?
              AND request.normalized_item_id = ?
              AND request.status = 'RESULT_READY'
              AND result.deleted_at IS NULL
            ORDER BY result.observed_on DESC, result.confidence_bps DESC,
                     result.created_at DESC, result.id
            LIMIT ?
            """,
            (space_id, user["family_id"], item_id, limit),
        )
    ).fetchall()
    return [_research_result_response(dict(row)) for row in rows]


async def save_retailer_research_result(
    db,
    *,
    user: dict,
    request_id: str,
    body: FinanceRetailerResearchResultCreate,
) -> FinanceRetailerResearchResultResponse:
    request = await (
        await db.execute(
            """
            SELECT request.* FROM finance_retailer_research_requests request
            JOIN finance_spaces space
              ON space.id = request.space_id AND space.family_id = request.family_id
             AND space.deleted_at IS NULL
            WHERE request.id = ? AND request.family_id = ? AND request.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            """,
            (request_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if request is None:
        raise FinanceProductNotFoundError("Retailer research request not found")
    if request["status"] == "CANCELLED":
        raise FinanceProductConflictError("Cancelled retailer research cannot accept results")
    identifier = str(uuid.uuid4())
    now = _now()
    stored_values = (
        body.match_kind,
        body.retailer_name,
        body.product_name,
        body.brand_variant,
        _decimal_text(body.pack_quantity),
        body.pack_unit.casefold(),
        _decimal_text(body.comparable_quantity),
        body.unit_basis.casefold(),
        body.price_minor,
        body.currency,
        body.observed_on.isoformat(),
        body.delivery_low_minor,
        body.delivery_high_minor,
        body.travel_low_minor,
        body.travel_high_minor,
        body.likely_waste_low_bps,
        body.likely_waste_high_bps,
        body.inconvenience_note,
        body.confidence_bps,
        body.source_label,
    )
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_retailer_research_results
                WHERE request_id = ? AND match_kind = ? AND retailer_name = ?
                  AND product_name = ? AND brand_variant IS ?
                  AND pack_quantity_decimal = ? AND pack_unit = ?
                  AND comparable_quantity_decimal = ? AND unit_basis = ?
                  AND price_minor = ? AND currency = ? AND observed_on = ?
                  AND delivery_low_minor = ? AND delivery_high_minor = ?
                  AND travel_low_minor = ? AND travel_high_minor = ?
                  AND likely_waste_low_bps = ? AND likely_waste_high_bps = ?
                  AND inconvenience_note = ? AND confidence_bps = ?
                  AND source_label = ? AND family_id = ? AND deleted_at IS NULL
                LIMIT 1
                """,
                (request_id, *stored_values, user["family_id"]),
            )
        ).fetchone()
        if existing is not None:
            return _research_result_response(dict(existing))
        await db.execute(
            """
            INSERT INTO finance_retailer_research_results
                (id, space_id, request_id, match_kind, retailer_name, product_name,
                 brand_variant, pack_quantity_decimal, pack_unit,
                 comparable_quantity_decimal, unit_basis, price_minor, currency,
                 observed_on, delivery_low_minor, delivery_high_minor,
                 travel_low_minor, travel_high_minor, likely_waste_low_bps,
                 likely_waste_high_bps, inconvenience_note, confidence_bps,
                 source_label, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                request["space_id"],
                request_id,
                *stored_values,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        await save_history(
            db,
            "finance_retailer_research_requests",
            request_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_retailer_research_requests
            SET status = 'RESULT_READY', updated_at = ? WHERE id = ?
            """,
            (now, request_id),
        )
    row = await (
        await db.execute(
            "SELECT * FROM finance_retailer_research_results "
            "WHERE id = ? AND request_id = ? AND space_id = ? AND family_id = ?",
            (identifier, request_id, request["space_id"], user["family_id"]),
        )
    ).fetchone()
    return _research_result_response(dict(row))


async def _comparison_row(db, *, user: dict, comparison_id: str) -> dict:
    row = await (
        await db.execute(
            """
            SELECT comparison.*, item.display_name AS normalized_item_name,
                   result.observed_on AS price_observed_on,
                   result.inconvenience_note, result.product_name AS candidate_name,
                   result.retailer_name AS candidate_retailer
            FROM finance_product_comparisons comparison
            JOIN finance_spaces space
              ON space.id = comparison.space_id AND space.family_id = comparison.family_id
             AND space.deleted_at IS NULL
            JOIN finance_normalized_purchase_items item
              ON item.id = comparison.normalized_item_id
             AND item.space_id = comparison.space_id
             AND item.family_id = comparison.family_id
             AND item.deleted_at IS NULL
            JOIN finance_retailer_research_results result
              ON result.id = comparison.research_result_id
             AND result.space_id = comparison.space_id
             AND result.family_id = comparison.family_id
             AND result.deleted_at IS NULL
            WHERE comparison.id = ? AND comparison.family_id = ?
              AND comparison.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            """,
            (comparison_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceProductNotFoundError("Product comparison not found")
    return dict(row)


def _comparison_response(row: dict) -> FinanceProductComparisonResponse:
    return FinanceProductComparisonResponse(
        id=row["id"],
        normalized_item_id=row["normalized_item_id"],
        normalized_item_name=row["normalized_item_name"],
        research_result_id=row["research_result_id"],
        period_start=row["period_start"],
        period_end=row["period_end"],
        actual_quantity=row["actual_quantity_decimal"],
        actual_spend_minor=row["actual_spend_minor"],
        currency=row["currency"],
        comparison_mode=row["comparison_mode"],
        candidate_low_minor=row["candidate_low_minor"],
        candidate_high_minor=row["candidate_high_minor"],
        saving_low_minor=row["saving_low_minor"],
        saving_high_minor=row["saving_high_minor"],
        unmatched_observation_count=row["unmatched_observation_count"],
        confidence_bps=row["confidence_bps"],
        overlap_group=row["overlap_group"],
        evidence_refs=json.loads(row["evidence_json"]),
        data_through=row["data_through_date"],
        price_observed_on=row["price_observed_on"],
        inconvenience_note=row["inconvenience_note"],
        status=row["status"],
    )


async def create_product_comparison(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinanceProductComparisonCreate,
) -> FinanceProductComparisonResponse:
    item = await _item(
        db, user=user, space_id=space_id, item_id=body.normalized_item_id
    )
    result = await (
        await db.execute(
            """
            SELECT result.* FROM finance_retailer_research_results result
            JOIN finance_retailer_research_requests request
              ON request.id = result.request_id AND request.space_id = result.space_id
             AND request.family_id = result.family_id AND request.deleted_at IS NULL
            WHERE result.id = ? AND result.space_id = ? AND result.family_id = ?
              AND request.normalized_item_id = ? AND result.deleted_at IS NULL
            """,
            (
                body.research_result_id,
                space_id,
                user["family_id"],
                body.normalized_item_id,
            ),
        )
    ).fetchone()
    if result is None:
        raise FinanceProductNotFoundError("Retailer research result not found")
    result = dict(result)
    observations = await (
        await db.execute(
            """
            SELECT * FROM finance_product_price_observations
            WHERE space_id = ? AND normalized_item_id = ? AND family_id = ?
              AND source_kind = 'PURCHASE_LINE' AND deleted_at IS NULL
              AND observed_on BETWEEN ? AND ? AND currency = ?
            ORDER BY observed_on, id LIMIT ?
            """,
            (
                space_id,
                body.normalized_item_id,
                user["family_id"],
                body.period_start.isoformat(),
                body.period_end.isoformat(),
                result["currency"],
                _MAX_HISTORY_ROWS + 1,
            ),
        )
    ).fetchall()
    if len(observations) > _MAX_HISTORY_ROWS:
        raise FinanceProductError("Comparison has too many observations")
    compatible = [
        row
        for row in observations
        if row["unit_basis"] in {"g", "ml", "each"}
        and row["unit_basis"] == result["unit_basis"]
    ]
    if not compatible:
        raise FinanceProductError("No pack-equivalent saved prices support this comparison")
    actual_quantity = sum(
        (Decimal(row["comparable_quantity_decimal"]) for row in compatible), Decimal(0)
    )
    actual_spend = sum(row["price_minor"] for row in compatible)
    unmatched_count = len(observations) - len(compatible)
    candidate_pack_quantity = Decimal(result["comparable_quantity_decimal"])
    if candidate_pack_quantity <= 0:
        raise FinanceProductError("Retailer result has an invalid comparable pack")
    age_days = max(0, (body.period_end - date.fromisoformat(result["observed_on"])).days)
    stale_uncertainty_bps = 0 if age_days <= 30 else 500 if age_days <= 180 else 1_500
    match_uncertainty_bps = {
        "EXACT": 0,
        "REALISTIC_SUBSTITUTE": 500,
        "BEHAVIOURAL_ALTERNATIVE": 1_500,
    }[result["match_kind"]]
    uncertainty_bps = max(stale_uncertainty_bps, match_uncertainty_bps)
    coverage_bps = len(compatible) * 10_000 // len(observations)
    comparison_confidence_bps = min(
        result["confidence_bps"],
        max(0, 10_000 - uncertainty_bps),
        coverage_bps,
    )

    def candidate_cost(waste_bps: int) -> int:
        needed = actual_quantity * (Decimal(10_000 + waste_bps) / Decimal(10_000))
        packs = _ceil(needed / candidate_pack_quantity)
        return packs * result["price_minor"]

    base_low = candidate_cost(result["likely_waste_low_bps"])
    base_high = candidate_cost(result["likely_waste_high_bps"])
    candidate_low = _floor(
        Decimal(base_low) * Decimal(10_000 - uncertainty_bps) / Decimal(10_000)
    ) + result["delivery_low_minor"] + result["travel_low_minor"]
    candidate_high = _ceil(
        Decimal(base_high) * Decimal(10_000 + uncertainty_bps) / Decimal(10_000)
    ) + result["delivery_high_minor"] + result["travel_high_minor"]
    exact = (
        result["match_kind"] == "EXACT"
        and uncertainty_bps == 0
        and unmatched_count == 0
        and result["likely_waste_low_bps"] == result["likely_waste_high_bps"] == 0
        and result["delivery_low_minor"] == result["delivery_high_minor"]
        and result["travel_low_minor"] == result["travel_high_minor"]
    )
    saving_low = actual_spend - candidate_high
    saving_high = actual_spend - candidate_low
    overlap_group = (
        f"product:{body.normalized_item_id}:{body.period_start.isoformat()}:"
        f"{body.period_end.isoformat()}"
    )
    evidence_refs = [
        *(f"product-price:{row['id']}" for row in compatible),
        f"retailer-result:{result['id']}",
    ]
    existing = await (
        await db.execute(
            """
            SELECT id FROM finance_product_comparisons
            WHERE space_id = ? AND normalized_item_id = ? AND research_result_id = ?
              AND period_start = ? AND period_end = ? AND deleted_at IS NULL
            """,
            (
                space_id,
                body.normalized_item_id,
                result["id"],
                body.period_start.isoformat(),
                body.period_end.isoformat(),
            ),
        )
    ).fetchone()
    if existing is not None:
        return _comparison_response(
            await _comparison_row(db, user=user, comparison_id=existing["id"])
        )
    accepted_overlap = await (
        await db.execute(
            """
            SELECT id FROM finance_opportunity_actions
            WHERE space_id = ? AND overlap_group = ? AND family_id = ?
              AND deleted_at IS NULL LIMIT 1
            """,
            (space_id, overlap_group, user["family_id"]),
        )
    ).fetchone()
    if accepted_overlap is not None:
        raise FinanceProductConflictError(
            "An overlapping product or basket action has already been accepted"
        )
    identifier = str(uuid.uuid4())
    finding_id = str(uuid.uuid4()) if saving_low > 0 else None
    now = _now()
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT id FROM finance_product_comparisons
                WHERE space_id = ? AND normalized_item_id = ? AND research_result_id = ?
                  AND period_start = ? AND period_end = ? AND deleted_at IS NULL
                """,
                (
                    space_id,
                    body.normalized_item_id,
                    result["id"],
                    body.period_start.isoformat(),
                    body.period_end.isoformat(),
                ),
            )
        ).fetchone()
        if existing is not None:
            return _comparison_response(
                await _comparison_row(db, user=user, comparison_id=existing["id"])
            )
        accepted_overlap = await (
            await db.execute(
                """
                SELECT id FROM finance_opportunity_actions
                WHERE space_id = ? AND overlap_group = ? AND family_id = ?
                  AND deleted_at IS NULL LIMIT 1
                """,
                (space_id, overlap_group, user["family_id"]),
            )
        ).fetchone()
        if accepted_overlap is not None:
            raise FinanceProductConflictError(
                "An overlapping product or basket action has already been accepted"
            )
        await db.execute(
            """
            INSERT INTO finance_product_price_observations
                (id, space_id, normalized_item_id, source_kind, research_result_id,
                 retailer_name, product_name, brand_variant, pack_quantity_decimal,
                 pack_unit, comparable_quantity_decimal, unit_basis, price_minor,
                 currency, observed_on, confidence_bps, evidence_json, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, 'RETAILER_RESEARCH', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?)
            ON CONFLICT(research_result_id, normalized_item_id) WHERE
                research_result_id IS NOT NULL AND deleted_at IS NULL DO NOTHING
            """,
            (
                str(uuid.uuid4()),
                space_id,
                body.normalized_item_id,
                result["id"],
                result["retailer_name"],
                result["product_name"],
                result["brand_variant"],
                result["pack_quantity_decimal"],
                result["pack_unit"],
                result["comparable_quantity_decimal"],
                result["unit_basis"],
                result["price_minor"],
                result["currency"],
                result["observed_on"],
                result["confidence_bps"],
                json.dumps([f"retailer-result:{result['id']}"]),
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_product_comparisons
                (id, space_id, normalized_item_id, research_result_id, period_start,
                 period_end, actual_quantity_decimal, actual_spend_minor, currency,
                 comparison_mode, candidate_low_minor, candidate_high_minor,
                 saving_low_minor, saving_high_minor, unmatched_observation_count,
                 confidence_bps, overlap_group, evidence_json, data_through_date,
                 status, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'OPEN', ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                body.normalized_item_id,
                result["id"],
                body.period_start.isoformat(),
                body.period_end.isoformat(),
                _decimal_text(actual_quantity),
                actual_spend,
                result["currency"],
                "EXACT" if exact else "RANGE",
                candidate_low,
                candidate_high,
                saving_low,
                saving_high,
                unmatched_count,
                comparison_confidence_bps,
                overlap_group,
                json.dumps(evidence_refs),
                max(row["observed_on"] for row in compatible),
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        if finding_id is not None:
            await db.execute(
                """
                INSERT INTO finance_findings
                    (id, space_id, finding_key, finding_type, title, observation,
                     evidence_json, baseline_json, saving_low_minor, saving_high_minor,
                     currency, confidence_bps, effort, overlap_group, status,
                     data_through_date, detected_at, family_id, created_at, updated_at,
                     created_by)
                VALUES (?, ?, ?, 'PRICE_DRIFT', ?, ?, ?, ?, ?, ?, ?, ?, 2, ?, 'OPEN',
                        ?, ?, ?, ?, ?, ?)
                """,
                (
                    finding_id,
                    space_id,
                    f"product-comparison:{identifier}",
                    f"Compare {item['display_name']} with {result['product_name']}",
                    (
                        f"Dated {result['observed_on']} comparison; "
                        f"{result['inconvenience_note']}"
                    ),
                    json.dumps(evidence_refs),
                    json.dumps({"comparison_id": identifier}),
                    max(0, saving_low),
                    max(0, saving_high),
                    result["currency"],
                    comparison_confidence_bps,
                    overlap_group,
                    max(row["observed_on"] for row in compatible),
                    now,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                ),
            )
    return _comparison_response(
        await _comparison_row(db, user=user, comparison_id=identifier)
    )


async def accept_product_opportunity(
    db,
    *,
    user: dict,
    comparison_id: str,
    body: FinanceProductOpportunityAccept,
) -> FinanceOpportunityActionResponse:
    comparison = await _comparison_row(db, user=user, comparison_id=comparison_id)
    existing = await (
        await db.execute(
            """
            SELECT * FROM finance_opportunity_actions
            WHERE comparison_id = ? AND deleted_at IS NULL
            """,
            (comparison_id,),
        )
    ).fetchone()
    if existing is not None:
        row = dict(existing)
        if row["action_kind"] != body.action_kind:
            raise FinanceProductConflictError(
                "This product opportunity already created a different action"
            )
        return FinanceOpportunityActionResponse(
            id=row["id"],
            comparison_id=row["comparison_id"],
            overlap_group=row["overlap_group"],
            action_kind=row["action_kind"],
            status=row["status"],
            action_payload=json.loads(row["action_payload_json"]),
            target_preference_id=row["target_preference_id"],
        )
    overlap = await (
        await db.execute(
            """
            SELECT id FROM finance_opportunity_actions
            WHERE space_id = ? AND overlap_group = ? AND deleted_at IS NULL
            """,
            (comparison["space_id"], comparison["overlap_group"]),
        )
    ).fetchone()
    if overlap is not None:
        raise FinanceProductConflictError(
            "An overlapping product or basket action has already been accepted"
        )
    identifier = str(uuid.uuid4())
    preference_id = None
    now = _now()
    if body.action_kind == "PREFERENCE":
        preference_key = f"substitution.{comparison['normalized_item_id']}"
        statement = (
            f"Prefer {comparison['candidate_name']} from {comparison['candidate_retailer']} "
            f"instead of {comparison['normalized_item_name']} when the dated price remains comparable."
        )
        payload = {
            "preference_key": preference_key,
            "statement": statement,
            "evidence_refs": json.loads(comparison["evidence_json"]),
        }
        status = "CREATED"
    else:
        payload = {
            "trigger": body.trigger,
            "target": body.target,
            "review_date": body.review_date.isoformat(),
            "candidate_product": comparison["candidate_name"],
            "baseline_comparison_id": comparison_id,
            "evidence_refs": json.loads(comparison["evidence_json"]),
        }
        status = "READY_FOR_CONFIRMATION"
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_opportunity_actions
                WHERE comparison_id = ? AND deleted_at IS NULL
                """,
                (comparison_id,),
            )
        ).fetchone()
        if existing is not None:
            row = dict(existing)
            if row["action_kind"] != body.action_kind:
                raise FinanceProductConflictError(
                    "This product opportunity already created a different action"
                )
            return FinanceOpportunityActionResponse(
                id=row["id"],
                comparison_id=row["comparison_id"],
                overlap_group=row["overlap_group"],
                action_kind=row["action_kind"],
                status=row["status"],
                action_payload=json.loads(row["action_payload_json"]),
                target_preference_id=row["target_preference_id"],
            )
        overlap = await (
            await db.execute(
                """
                SELECT id FROM finance_opportunity_actions
                WHERE space_id = ? AND overlap_group = ? AND deleted_at IS NULL
                """,
                (comparison["space_id"], comparison["overlap_group"]),
            )
        ).fetchone()
        if overlap is not None:
            raise FinanceProductConflictError(
                "An overlapping product or basket action has already been accepted"
            )
        if body.action_kind == "PREFERENCE":
            existing_preference = await (
                await db.execute(
                    """
                    SELECT id FROM finance_preferences
                    WHERE space_id = ? AND preference_key = ? AND status <> 'EXPIRED'
                      AND deleted_at IS NULL ORDER BY version DESC LIMIT 1
                    """,
                    (comparison["space_id"], payload["preference_key"]),
                )
            ).fetchone()
            if existing_preference is None:
                preference = await create_preference(
                    db,
                    user=user,
                    space_id=comparison["space_id"],
                    body=FinancePreferenceCreate(
                        preference_key=payload["preference_key"],
                        statement=payload["statement"],
                        value_kind="NEGOTIABLE",
                        evidence_refs=payload["evidence_refs"],
                    ),
                )
                confirmed = await set_preference_status(
                    db,
                    user=user,
                    preference_id=preference.id,
                    status="CONFIRMED",
                )
                preference_id = confirmed.id
            else:
                preference_id = existing_preference["id"]
        await db.execute(
            """
            INSERT INTO finance_opportunity_actions
                (id, space_id, comparison_id, overlap_group, action_kind,
                 action_payload_json, target_preference_id, status, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                comparison["space_id"],
                comparison_id,
                comparison["overlap_group"],
                body.action_kind,
                json.dumps(payload, sort_keys=True),
                preference_id,
                status,
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
        changed_comparisons = await (
            await db.execute(
                """
                SELECT id FROM finance_product_comparisons
                WHERE space_id = ? AND overlap_group = ? AND status = 'OPEN'
                  AND deleted_at IS NULL
                """,
                (comparison["space_id"], comparison["overlap_group"]),
            )
        ).fetchall()
        for changed in changed_comparisons:
            await save_history(
                db,
                "finance_product_comparisons",
                changed["id"],
                user["id"],
                family_id=user["family_id"],
            )
        changed_findings = await (
            await db.execute(
                """
                SELECT id FROM finance_findings
                WHERE space_id = ? AND overlap_group = ? AND status = 'OPEN'
                  AND deleted_at IS NULL
                """,
                (comparison["space_id"], comparison["overlap_group"]),
            )
        ).fetchall()
        for changed in changed_findings:
            await save_history(
                db,
                "finance_findings",
                changed["id"],
                user["id"],
                family_id=user["family_id"],
            )
        await db.execute(
            """
            UPDATE finance_product_comparisons
            SET status = CASE WHEN id = ? THEN 'ACCEPTED' ELSE 'SUPERSEDED' END,
                updated_at = ?
            WHERE space_id = ? AND overlap_group = ? AND status = 'OPEN'
              AND deleted_at IS NULL
            """,
            (
                comparison_id,
                now,
                comparison["space_id"],
                comparison["overlap_group"],
            ),
        )
        await db.execute(
            """
            UPDATE finance_findings
            SET status = CASE WHEN baseline_json = ? THEN 'ACCEPTED' ELSE 'DISMISSED' END,
                updated_at = ?
            WHERE space_id = ? AND overlap_group = ? AND status = 'OPEN'
              AND deleted_at IS NULL
            """,
            (
                json.dumps({"comparison_id": comparison_id}),
                now,
                comparison["space_id"],
                comparison["overlap_group"],
            ),
        )
    return FinanceOpportunityActionResponse(
        id=identifier,
        comparison_id=comparison_id,
        overlap_group=comparison["overlap_group"],
        action_kind=body.action_kind,
        status=status,
        action_payload=payload,
        target_preference_id=preference_id,
    )
