"""Broker-independent, user-entered securities portfolio tracking."""

import uuid
from collections import defaultdict
from datetime import datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.finance_products_assets import (
    FinanceAssetHoldingInput,
    FinancePortfolioHistoryPointResponse,
    FinancePortfolioPositionResponse,
    FinancePortfolioPositionSave,
    FinancePortfolioResponse,
)
from app.services.finance.assets import (
    FinanceAssetConflictError,
    FinanceAssetError,
    FinanceAssetNotFoundError,
    insert_asset_snapshot,
)
from app.services.finance.foundation import require_finance_space
from app.services.finance.money import normalise_currency
from app.services.idempotency import serialized_create

PORTFOLIO_KIND = "MANUAL_PORTFOLIO"
PORTFOLIO_LABEL = "Savings portfolio"
PORTFOLIO_CURRENCY = "GBP"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _timestamp(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _position_key(position_id: str) -> str:
    return f"manual:{position_id}"


def _position_id(asset_key: str) -> str:
    return asset_key.removeprefix("manual:")


async def _household_timezone(db, *, family_id: str):
    row = await (
        await db.execute(
            "SELECT household_timezone FROM finance_settings "
            "WHERE family_id = ? AND deleted_at IS NULL "
            "ORDER BY updated_at DESC LIMIT 1",
            (family_id,),
        )
    ).fetchone()
    try:
        return ZoneInfo(row["household_timezone"] if row else "UTC")
    except ZoneInfoNotFoundError:
        return timezone.utc


async def _portfolio_source(db, *, user: dict, space_id: str) -> dict | None:
    await require_finance_space(db, user=user, space_id=space_id)
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_asset_sources
            WHERE space_id = ? AND family_id = ?
              AND source_kind = 'MANUAL_PORTFOLIO'
              AND deleted_at IS NULL
            ORDER BY created_at, id LIMIT 1
            """,
            (space_id, user["family_id"]),
        )
    ).fetchone()
    return dict(row) if row is not None else None


async def _ensure_portfolio_source(db, *, user: dict, space_id: str) -> dict:
    source = await _portfolio_source(db, user=user, space_id=space_id)
    if source is not None:
        return source
    identifier = str(uuid.uuid4())
    now = _now()
    async with serialized_create(db):
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_asset_sources
                WHERE space_id = ? AND family_id = ?
                  AND source_kind = 'MANUAL_PORTFOLIO'
                  AND deleted_at IS NULL
                ORDER BY created_at, id LIMIT 1
                """,
                (space_id, user["family_id"]),
            )
        ).fetchone()
        if existing is not None:
            return dict(existing)
        await db.execute(
            """
            INSERT INTO finance_asset_sources
                (id, space_id, source_kind, label, public_address, status,
                 family_id, created_at, updated_at, created_by,
                 client_id, client_timestamp)
            VALUES (?, ?, 'MANUAL_PORTFOLIO', ?, NULL, 'ACTIVE',
                    ?, ?, ?, ?, ?, ?)
            """,
            (
                identifier,
                space_id,
                PORTFOLIO_LABEL,
                user["family_id"],
                now,
                now,
                user["id"],
                identifier,
                now,
            ),
        )
    return {
        "id": identifier,
        "space_id": space_id,
        "source_kind": PORTFOLIO_KIND,
        "label": PORTFOLIO_LABEL,
        "public_address": None,
        "status": "ACTIVE",
        "family_id": user["family_id"],
    }


async def _latest_position_rows(db, *, user: dict, source: dict) -> list[dict]:
    rows = await (
        await db.execute(
            """
            SELECT position.*, valuation.valuation_status,
                   valuation.value_minor, valuation.currency,
                   valuation.unit_price_minor, valuation.price_source,
                   valuation.observed_at
            FROM finance_asset_snapshots snapshot
            JOIN finance_positions position
              ON position.snapshot_id = snapshot.id
             AND position.space_id = snapshot.space_id
             AND position.family_id = snapshot.family_id
             AND position.deleted_at IS NULL
            JOIN finance_valuations valuation
              ON valuation.position_id = position.id
             AND valuation.space_id = position.space_id
             AND valuation.family_id = position.family_id
             AND valuation.deleted_at IS NULL
            WHERE snapshot.id = (
                SELECT latest.id FROM finance_asset_snapshots latest
                WHERE latest.source_id = ? AND latest.space_id = ?
                  AND latest.family_id = ? AND latest.deleted_at IS NULL
                ORDER BY latest.as_of_at DESC, latest.id DESC LIMIT 1
            )
            ORDER BY position.asset_name COLLATE NOCASE, position.asset_key
            """,
            (source["id"], source["space_id"], user["family_id"]),
        )
    ).fetchall()
    return [dict(row) for row in rows]


async def _latest_price(
    db,
    *,
    user: dict,
    source: dict,
    asset_key: str,
    quote_symbol: str,
) -> dict | None:
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_market_price_observations
            WHERE source_id = ? AND space_id = ? AND family_id = ?
              AND asset_key = ? AND quote_symbol = ? AND deleted_at IS NULL
            ORDER BY observed_at DESC, id DESC LIMIT 1
            """,
            (
                source["id"],
                source["space_id"],
                user["family_id"],
                asset_key,
                quote_symbol,
            ),
        )
    ).fetchone()
    return dict(row) if row is not None else None


async def _holding_from_saved(
    db,
    *,
    user: dict,
    source: dict,
    body: FinancePortfolioPositionSave,
    position_id: str,
) -> FinanceAssetHoldingInput:
    asset_key = _position_key(position_id)
    latest = await _latest_price(
        db,
        user=user,
        source=source,
        asset_key=asset_key,
        quote_symbol=body.quote_symbol,
    )
    value_minor = None
    unit_price_minor = None
    price_source = None
    if latest is not None and latest["currency"] == PORTFOLIO_CURRENCY:
        unit_price_minor = latest["unit_price_minor"]
        value_minor = int(
            (body.quantity * Decimal(unit_price_minor)).to_integral_value(
                rounding=ROUND_HALF_UP
            )
        )
        price_source = latest["source_label"]
    return FinanceAssetHoldingInput(
        asset_key=asset_key,
        asset_name=body.name,
        asset_class="BROKERAGE_INVESTMENT",
        position_kind="HOLDING",
        include_in_net_worth=True,
        quantity=body.quantity,
        quantity_unit="unit",
        value_minor=value_minor,
        unit_price_minor=unit_price_minor,
        price_source=price_source,
        instrument_id_kind="TICKER",
        instrument_id=body.quote_symbol,
        quote_symbol=body.quote_symbol,
        quote_currency=body.quote_currency,
        cost_basis_minor=body.cost_basis_minor,
        cost_basis_currency=(PORTFOLIO_CURRENCY if body.cost_basis_minor is not None else None),
    )


def _holding_from_row(row: dict) -> FinanceAssetHoldingInput:
    return FinanceAssetHoldingInput(
        asset_key=row["asset_key"],
        asset_name=row["asset_name"],
        asset_class=row["asset_class"],
        position_kind=row["position_kind"],
        include_in_net_worth=bool(row["include_in_net_worth"]),
        quantity=Decimal(row["quantity_decimal"]),
        quantity_unit=row["quantity_unit"],
        value_minor=row["value_minor"],
        unit_price_minor=row["unit_price_minor"],
        price_source=row["price_source"],
        instrument_id_kind=row["instrument_id_kind"],
        instrument_id=row["instrument_id"],
        quote_symbol=row["quote_symbol"],
        quote_currency=row["quote_currency"],
        cost_basis_minor=row.get("cost_basis_minor"),
        cost_basis_currency=row.get("cost_basis_currency"),
    )


async def _save_holdings(
    db,
    *,
    user: dict,
    source: dict,
    holdings: list[FinanceAssetHoldingInput],
) -> None:
    async with serialized_create(db):
        await insert_asset_snapshot(
            db,
            user=user,
            source=source,
            as_of_at=_now(),
            snapshot_kind="REVIEWED_REPORT",
            currency=PORTFOLIO_CURRENCY,
            positions=holdings,
        )


async def create_portfolio_position(
    db,
    *,
    user: dict,
    space_id: str,
    body: FinancePortfolioPositionSave,
    days: int = 365,
) -> FinancePortfolioResponse:
    source = await _ensure_portfolio_source(db, user=user, space_id=space_id)
    async with serialized_create(db):
        current_rows = await _latest_position_rows(db, user=user, source=source)
        position_id = body.id or str(uuid.uuid4())
        asset_key = _position_key(position_id)
        existing = next(
            (row for row in current_rows if row["asset_key"] == asset_key),
            None,
        )
        if existing is not None:
            matches_replay = (
                existing["asset_name"] == body.name
                and existing["quote_symbol"] == body.quote_symbol
                and existing["quote_currency"] == body.quote_currency
                and Decimal(existing["quantity_decimal"]) == body.quantity
                and existing.get("cost_basis_minor") == body.cost_basis_minor
            )
            if not matches_replay:
                raise FinanceAssetConflictError(
                    "That portfolio position ID was already used"
                )
        else:
            if any(
                row["quote_symbol"].casefold() == body.quote_symbol.casefold()
                for row in current_rows
            ):
                raise FinanceAssetConflictError(
                    "That market symbol is already in this portfolio"
                )
            holdings = [_holding_from_row(row) for row in current_rows]
            holdings.append(
                await _holding_from_saved(
                    db,
                    user=user,
                    source=source,
                    body=body,
                    position_id=position_id,
                )
            )
            await _save_holdings(db, user=user, source=source, holdings=holdings)
    return await portfolio_summary(
        db,
        user=user,
        space_id=space_id,
        currency=PORTFOLIO_CURRENCY,
        days=days,
    )


async def update_portfolio_position(
    db,
    *,
    user: dict,
    space_id: str,
    position_id: str,
    body: FinancePortfolioPositionSave,
    days: int = 365,
) -> FinancePortfolioResponse:
    source = await _portfolio_source(db, user=user, space_id=space_id)
    if source is None:
        raise FinanceAssetNotFoundError("Savings portfolio not found")
    if body.id is not None and body.id != position_id:
        raise FinanceAssetConflictError("Position ID does not match the requested holding")
    async with serialized_create(db):
        current_rows = await _latest_position_rows(db, user=user, source=source)
        asset_key = _position_key(position_id)
        if not any(row["asset_key"] == asset_key for row in current_rows):
            raise FinanceAssetNotFoundError("Portfolio position not found")
        if any(
            row["asset_key"] != asset_key
            and row["quote_symbol"].casefold() == body.quote_symbol.casefold()
            for row in current_rows
        ):
            raise FinanceAssetConflictError("That market symbol is already in this portfolio")
        replacement = await _holding_from_saved(
            db,
            user=user,
            source=source,
            body=body,
            position_id=position_id,
        )
        holdings = [
            replacement if row["asset_key"] == asset_key else _holding_from_row(row)
            for row in current_rows
        ]
        await _save_holdings(db, user=user, source=source, holdings=holdings)
    return await portfolio_summary(
        db,
        user=user,
        space_id=space_id,
        currency=PORTFOLIO_CURRENCY,
        days=days,
    )


async def remove_portfolio_position(
    db,
    *,
    user: dict,
    space_id: str,
    position_id: str,
    days: int = 365,
) -> FinancePortfolioResponse:
    source = await _portfolio_source(db, user=user, space_id=space_id)
    if source is None:
        raise FinanceAssetNotFoundError("Savings portfolio not found")
    async with serialized_create(db):
        current_rows = await _latest_position_rows(db, user=user, source=source)
        asset_key = _position_key(position_id)
        if not any(row["asset_key"] == asset_key for row in current_rows):
            raise FinanceAssetNotFoundError("Portfolio position not found")
        holdings = [
            _holding_from_row(row)
            for row in current_rows
            if row["asset_key"] != asset_key
        ]
        await _save_holdings(db, user=user, source=source, holdings=holdings)
    return await portfolio_summary(
        db,
        user=user,
        space_id=space_id,
        currency=PORTFOLIO_CURRENCY,
        days=days,
    )


def _value_for_position(
    position: dict,
    *,
    price_rows: list[dict],
    cutoff: datetime,
    currency: str,
) -> tuple[int | None, int | None, str | None, str | None]:
    matching = [
        price
        for price in price_rows
        if price["_at"] <= cutoff
        and price["quote_symbol"] == position["quote_symbol"]
        and price["currency"] == currency
    ]
    if matching:
        latest = matching[-1]
        value = int(
            (
                Decimal(position["quantity_decimal"])
                * Decimal(latest["unit_price_minor"])
            ).to_integral_value(rounding=ROUND_HALF_UP)
        )
        return (
            value,
            latest["unit_price_minor"],
            latest["observed_at"],
            latest["source_label"],
        )
    if position["valuation_status"] == "KNOWN" and position["currency"] == currency:
        return (
            position["value_minor"],
            position["unit_price_minor"],
            position["observed_at"],
            position["price_source"],
        )
    return None, None, None, None


async def portfolio_summary(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str = PORTFOLIO_CURRENCY,
    days: int = 365,
) -> FinancePortfolioResponse:
    currency = normalise_currency(currency)
    if currency != PORTFOLIO_CURRENCY:
        raise FinanceAssetError("Savings portfolio values are currently reported in GBP")
    source = await _portfolio_source(db, user=user, space_id=space_id)
    if source is None:
        return FinancePortfolioResponse(
            space_id=space_id,
            currency=currency,
            total_value_minor=0,
        )
    timezone_for_family = await _household_timezone(db, family_id=user["family_id"])
    today = datetime.now(timezone_for_family).date()
    start_date = today - timedelta(days=max(1, days) - 1)
    snapshot_rows = await (
        await db.execute(
            """
            SELECT snapshot.id AS snapshot_id, snapshot.as_of_at,
                   position.asset_key, position.asset_name,
                   position.quantity_decimal, position.quantity_unit,
                   position.quote_symbol, position.quote_currency,
                   position.cost_basis_minor, position.cost_basis_currency,
                   valuation.valuation_status, valuation.value_minor,
                   valuation.currency, valuation.unit_price_minor,
                   valuation.price_source, valuation.observed_at
            FROM finance_asset_snapshots snapshot
            LEFT JOIN finance_positions position
              ON position.snapshot_id = snapshot.id
             AND position.space_id = snapshot.space_id
             AND position.family_id = snapshot.family_id
             AND position.deleted_at IS NULL
            LEFT JOIN finance_valuations valuation
              ON valuation.position_id = position.id
             AND valuation.space_id = position.space_id
             AND valuation.family_id = position.family_id
             AND valuation.deleted_at IS NULL
            WHERE snapshot.source_id = ? AND snapshot.space_id = ?
              AND snapshot.family_id = ? AND snapshot.deleted_at IS NULL
            ORDER BY snapshot.as_of_at, snapshot.id, position.asset_key
            """,
            (source["id"], space_id, user["family_id"]),
        )
    ).fetchall()
    snapshots: dict[str, dict] = {}
    for raw in snapshot_rows:
        row = dict(raw)
        snapshot = snapshots.setdefault(
            row["snapshot_id"],
            {
                "id": row["snapshot_id"],
                "as_of_at": row["as_of_at"],
                "_at": _timestamp(row["as_of_at"]),
                "positions": [],
            },
        )
        if row["asset_key"] is not None:
            snapshot["positions"].append(row)
    ordered_snapshots = sorted(snapshots.values(), key=lambda item: (item["_at"], item["id"]))

    raw_prices = await (
        await db.execute(
            """
            SELECT * FROM finance_market_price_observations
            WHERE source_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY observed_at, id
            """,
            (source["id"], space_id, user["family_id"]),
        )
    ).fetchall()
    prices: dict[str, list[dict]] = defaultdict(list)
    for raw in raw_prices:
        row = dict(raw)
        row["_at"] = _timestamp(row["observed_at"])
        prices[row["asset_key"]].append(row)

    dates = {today}
    if any(snapshot["_at"].astimezone(timezone_for_family).date() <= start_date for snapshot in ordered_snapshots):
        dates.add(start_date)
    dates.update(
        snapshot["_at"].astimezone(timezone_for_family).date()
        for snapshot in ordered_snapshots
        if snapshot["_at"].astimezone(timezone_for_family).date() >= start_date
    )
    dates.update(
        price["_at"].astimezone(timezone_for_family).date()
        for rows in prices.values()
        for price in rows
        if price["_at"].astimezone(timezone_for_family).date() >= start_date
    )
    dates = {day for day in dates if start_date <= day <= today}

    history: list[FinancePortfolioHistoryPointResponse] = []
    for day in sorted(dates):
        cutoff = datetime.combine(day, time.max, tzinfo=timezone_for_family).astimezone(
            timezone.utc
        )
        eligible = [snapshot for snapshot in ordered_snapshots if snapshot["_at"] <= cutoff]
        positions = eligible[-1]["positions"] if eligible else []
        total = 0
        known = 0
        unknown = 0
        for position in positions:
            value, _, _, _ = _value_for_position(
                position,
                price_rows=prices[position["asset_key"]],
                cutoff=cutoff,
                currency=currency,
            )
            if value is None:
                unknown += 1
            else:
                known += 1
                total += value
        history.append(
            FinancePortfolioHistoryPointResponse(
                date=day,
                value_minor=total,
                known_position_count=known,
                unknown_position_count=unknown,
            )
        )

    latest_snapshot = ordered_snapshots[-1] if ordered_snapshots else None
    latest_positions = latest_snapshot["positions"] if latest_snapshot else []
    now_cutoff = datetime.combine(today, time.max, tzinfo=timezone_for_family).astimezone(
        timezone.utc
    )
    responses: list[FinancePortfolioPositionResponse] = []
    price_times: list[str] = []
    price_sources: set[str] = set()
    unknown_count = 0
    missing_cost_basis = 0
    total_value = 0
    total_cost = 0
    uses_saved_price = False
    for position in latest_positions:
        value, unit_price, observed_at, price_source = _value_for_position(
            position,
            price_rows=prices[position["asset_key"]],
            cutoff=now_cutoff,
            currency=currency,
        )
        if value is None:
            unknown_count += 1
        else:
            total_value += value
        cost_basis = position["cost_basis_minor"]
        if cost_basis is None:
            missing_cost_basis += 1
        else:
            total_cost += cost_basis
        gain = value - cost_basis if value is not None and cost_basis is not None else None
        is_saved = False
        if observed_at is not None:
            price_times.append(observed_at)
            if price_source:
                price_sources.add(price_source)
            is_saved = _timestamp(observed_at).astimezone(timezone_for_family).date() < today
            uses_saved_price = uses_saved_price or is_saved
        responses.append(
            FinancePortfolioPositionResponse(
                id=_position_id(position["asset_key"]),
                name=position["asset_name"],
                quote_symbol=position["quote_symbol"],
                quote_currency=position["quote_currency"],
                quantity=position["quantity_decimal"],
                cost_basis_minor=cost_basis,
                unit_price_minor=unit_price,
                value_minor=value,
                gain_minor=gain,
                currency=currency,
                price_observed_at=observed_at,
                price_source=price_source,
                using_last_known_price=is_saved,
            )
        )
    responses.sort(
        key=lambda item: (
            item.value_minor is None,
            -(item.value_minor or 0),
            item.name.casefold(),
        )
    )
    complete_cost_basis = bool(responses) and missing_cost_basis == 0 and unknown_count == 0
    return FinancePortfolioResponse(
        space_id=space_id,
        source_id=source["id"],
        label=source["label"],
        currency=currency,
        total_value_minor=total_value,
        total_cost_basis_minor=(total_cost if missing_cost_basis == 0 and responses else None),
        total_gain_minor=(total_value - total_cost if complete_cost_basis else None),
        missing_cost_basis_count=missing_cost_basis,
        unknown_position_count=unknown_count,
        price_observed_at=min(price_times, default=None),
        price_sources=sorted(price_sources),
        using_last_known_prices=uses_saved_price,
        positions=responses,
        history=history,
    )
