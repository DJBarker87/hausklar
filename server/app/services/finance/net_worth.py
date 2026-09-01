"""Dated household net worth with investment cash flows kept separate."""

from collections import defaultdict
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.finance_products_assets import (
    FinanceNetWorthHistoryResponse,
    FinanceNetWorthHoldingResponse,
    FinanceNetWorthPointLayerResponse,
    FinanceNetWorthPointResponse,
)
from app.services.finance.foundation import require_finance_space
from app.services.finance.money import normalise_currency

NET_WORTH_LAYERS = (
    "OPERATING_CASH",
    "PROTECTED_RESERVE",
    "GOAL_CASH",
    "ACCESSIBLE_SAVINGS",
    "BROKERAGE_INVESTMENT",
    "PENSION_LOCKED",
    "STABLE_CRYPTO",
    "VOLATILE_CRYPTO",
    "PROPERTY",
    "OTHER_ASSET",
    "LIABILITY",
)
INVESTMENT_LAYERS = {"BROKERAGE_INVESTMENT", "PENSION_LOCKED"}


def _timestamp(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _dated_marker(value: str, household_tz) -> datetime:
    """Keep report and market-close dates on the calendar day they name."""
    named_day = date.fromisoformat(value[:10])
    return datetime.combine(named_day, time.max, tzinfo=household_tz).astimezone(timezone.utc)


def _account_layer(row: dict) -> str:
    if row["account_type"] == "CREDIT_CARD":
        return "LIABILITY"
    if row["account_type"] == "INVESTMENT" or row["purpose"] == "INVESTMENT_LIKE":
        return "BROKERAGE_INVESTMENT"
    if row["account_type"] == "CRYPTO":
        return "VOLATILE_CRYPTO"
    if row["purpose"] == "GOAL":
        return "GOAL_CASH"
    if row["account_type"] == "SAVINGS" or row["purpose"] == "SAVINGS":
        return "ACCESSIBLE_SAVINGS"
    return "OPERATING_CASH"


def _advance_latest(rows: list[dict], cutoff: datetime, index: int) -> tuple[dict | None, int]:
    """Advance through an ascending dated series exactly once."""
    while index + 1 < len(rows) and rows[index + 1]["_at"] <= cutoff:
        index += 1
    return (rows[index] if index >= 0 else None), index


def _signed_value(layer: str, value: int) -> int:
    return -abs(value) if layer == "LIABILITY" else value


async def net_worth_history(
    db,
    *,
    user: dict,
    space_id: str,
    currency: str,
    days: int = 365,
) -> FinanceNetWorthHistoryResponse:
    """Build a dated series from saved balances, holdings, prices and debts."""
    currency = normalise_currency(currency)
    await require_finance_space(db, user=user, space_id=space_id)
    settings = await (
        await db.execute(
            """
            SELECT household_timezone FROM finance_settings
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY updated_at DESC LIMIT 1
            """,
            (user["family_id"],),
        )
    ).fetchone()
    try:
        household_tz = ZoneInfo(settings["household_timezone"] if settings else "UTC")
    except ZoneInfoNotFoundError:
        household_tz = timezone.utc
    end_date = datetime.now(household_tz).date()
    start_date = end_date - timedelta(days=max(1, days) - 1)
    end_cutoff = datetime.combine(end_date, time.max, tzinfo=household_tz).astimezone(timezone.utc)
    start_cutoff = datetime.combine(
        start_date,
        time.max,
        tzinfo=household_tz,
    ).astimezone(timezone.utc)

    account_rows = await (
        await db.execute(
            """
            WITH selected_accounts AS MATERIALIZED (
                SELECT * FROM finance_accounts
                WHERE space_id = ? AND family_id = ?
                  AND include_in_net_worth = 1 AND deleted_at IS NULL
            ),
            selected_balances AS (
                SELECT balance.*
                FROM finance_balance_snapshots balance
                JOIN selected_accounts account
                  ON account.id = balance.account_id
                 AND account.space_id = balance.space_id
                 AND account.family_id = balance.family_id
                WHERE balance.observed_at > ? AND balance.observed_at <= ?
                  AND balance.deleted_at IS NULL
                UNION ALL
                SELECT baseline.*
                FROM selected_accounts account
                JOIN finance_balance_snapshots baseline ON baseline.id = (
                    SELECT latest.id FROM finance_balance_snapshots latest
                    WHERE latest.account_id = account.id
                      AND latest.space_id = account.space_id
                      AND latest.family_id = account.family_id
                      AND latest.observed_at <= ? AND latest.deleted_at IS NULL
                    ORDER BY latest.observed_at DESC, latest.id DESC LIMIT 1
                )
            )
            SELECT account.id AS account_id, account.label, account.institution,
                   account.account_type, account.purpose, balance.booked_minor,
                   balance.currency, balance.observed_at
            FROM selected_accounts account
            JOIN selected_balances balance
              ON balance.account_id = account.id AND balance.space_id = account.space_id
             AND balance.family_id = account.family_id
            ORDER BY balance.observed_at, balance.id
            """,
            (
                space_id,
                user["family_id"],
                start_cutoff.isoformat(),
                end_cutoff.isoformat(),
                start_cutoff.isoformat(),
            ),
        )
    ).fetchall()
    accounts: dict[str, list[dict]] = defaultdict(list)
    for raw in account_rows:
        row = dict(raw)
        row["_at"] = _timestamp(row["observed_at"])
        if row["_at"] <= end_cutoff:
            row["layer"] = _account_layer(row)
            accounts[row["account_id"]].append(row)

    reserve_rows = await (
        await db.execute(
            """
            SELECT id, name, allocated_minor, currency, updated_at
            FROM finance_reserves
            WHERE space_id = ? AND family_id = ? AND status = 'ACTIVE'
              AND deleted_at IS NULL ORDER BY updated_at, id
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    reserves = []
    for raw in reserve_rows:
        row = dict(raw)
        row["_at"] = _timestamp(row["updated_at"])
        if row["_at"] <= end_cutoff:
            reserves.append(row)

    position_rows = await (
        await db.execute(
            """
            WITH selected_sources AS MATERIALIZED (
                SELECT * FROM finance_asset_sources
                WHERE space_id = ? AND family_id = ? AND deleted_at IS NULL
            ),
            selected_snapshots AS (
                SELECT snapshot.*
                FROM finance_asset_snapshots snapshot
                JOIN selected_sources source
                  ON source.id = snapshot.source_id
                 AND source.space_id = snapshot.space_id
                 AND source.family_id = snapshot.family_id
                WHERE snapshot.as_of_at > ? AND snapshot.as_of_at <= ?
                  AND snapshot.deleted_at IS NULL
                UNION ALL
                SELECT baseline.*
                FROM selected_sources source
                JOIN finance_asset_snapshots baseline ON baseline.id = (
                    SELECT latest.id FROM finance_asset_snapshots latest
                    WHERE latest.source_id = source.id
                      AND latest.space_id = source.space_id
                      AND latest.family_id = source.family_id
                      AND latest.as_of_at <= ? AND latest.deleted_at IS NULL
                    ORDER BY latest.as_of_at DESC, latest.id DESC LIMIT 1
                )
            )
            SELECT source.id AS source_id, source.label AS source_label,
                   source.source_kind,
                   source.status AS source_status, snapshot.id AS snapshot_id,
                   snapshot.as_of_at, position.asset_key, position.asset_name,
                   position.asset_class, position.quantity_decimal,
                   position.quantity_unit, position.instrument_id_kind,
                   position.instrument_id, position.quote_symbol,
                   valuation.valuation_status, valuation.value_minor,
                   valuation.currency, valuation.unit_price_minor,
                   valuation.price_source, valuation.observed_at
            FROM selected_sources source
            JOIN selected_snapshots snapshot
              ON snapshot.source_id = source.id AND snapshot.space_id = source.space_id
             AND snapshot.family_id = source.family_id
            LEFT JOIN finance_positions position
              ON position.snapshot_id = snapshot.id AND position.space_id = snapshot.space_id
             AND position.family_id = snapshot.family_id AND position.deleted_at IS NULL
             AND position.include_in_net_worth = 1
            LEFT JOIN finance_valuations valuation
              ON valuation.position_id = position.id AND valuation.space_id = position.space_id
             AND valuation.family_id = position.family_id AND valuation.deleted_at IS NULL
            ORDER BY snapshot.as_of_at, snapshot.id, position.asset_key
            """,
            (
                space_id,
                user["family_id"],
                start_cutoff.isoformat(),
                end_cutoff.isoformat(),
                start_cutoff.isoformat(),
            ),
        )
    ).fetchall()
    snapshots: dict[str, dict[str, dict]] = defaultdict(dict)
    for raw in position_rows:
        row = dict(raw)
        at = (
            _timestamp(row["as_of_at"])
            if row["source_kind"] == "MANUAL_PORTFOLIO"
            else _dated_marker(row["as_of_at"], household_tz)
        )
        if at > end_cutoff:
            continue
        source_snapshots = snapshots[row["source_id"]]
        snapshot = source_snapshots.setdefault(
            row["snapshot_id"],
            {
                "snapshot_id": row["snapshot_id"],
                "source_id": row["source_id"],
                "source_label": row["source_label"],
                "source_kind": row["source_kind"],
                "source_status": row["source_status"],
                "as_of_at": row["as_of_at"],
                "_at": at,
                "positions": [],
            },
        )
        if row["asset_key"] is not None:
            position = dict(row)
            position["_valuation_at"] = _timestamp(position["observed_at"])
            snapshot["positions"].append(position)
    source_snapshots: dict[str, list[dict]] = {
        source_id: sorted(items.values(), key=lambda item: (item["_at"], item["snapshot_id"]))
        for source_id, items in snapshots.items()
    }

    price_keys = sorted(
        {
            (source_id, position["asset_key"])
            for source_id, rows in source_snapshots.items()
            for snapshot in rows
            for position in snapshot["positions"]
        }
    )
    price_rows = []
    for offset in range(0, len(price_keys), 400):
        key_batch = price_keys[offset : offset + 400]
        values_sql = ",".join("(?, ?)" for _ in key_batch)
        params: list[object] = [value for key in key_batch for value in key]
        params.extend(
            (
                space_id,
                user["family_id"],
                start_cutoff.isoformat(),
                end_cutoff.isoformat(),
                space_id,
                user["family_id"],
                start_cutoff.isoformat(),
            )
        )
        rows = await (
            await db.execute(
                f"""
                WITH requested(source_id, asset_key) AS (VALUES {values_sql}),
                selected_prices AS (
                    SELECT price.*
                    FROM requested
                    JOIN finance_market_price_observations price
                      ON price.source_id = requested.source_id
                     AND price.asset_key = requested.asset_key
                    WHERE price.space_id = ? AND price.family_id = ?
                      AND price.observed_at > ? AND price.observed_at <= ?
                      AND price.deleted_at IS NULL
                    UNION ALL
                    SELECT baseline.*
                    FROM requested
                    JOIN finance_market_price_observations baseline ON baseline.id = (
                        SELECT latest.id
                        FROM finance_market_price_observations latest
                        WHERE latest.source_id = requested.source_id
                          AND latest.asset_key = requested.asset_key
                          AND latest.space_id = ? AND latest.family_id = ?
                          AND latest.observed_at <= ? AND latest.deleted_at IS NULL
                        ORDER BY latest.observed_at DESC, latest.id DESC LIMIT 1
                    )
                )
                SELECT id AS price_id, source_id, asset_key, quote_symbol, currency,
                       unit_price_minor, observed_at, source_label
                FROM selected_prices
                """,
                tuple(params),
            )
        ).fetchall()
        price_rows.extend(rows)
    price_rows.sort(key=lambda row: (row["observed_at"], row["price_id"]))
    prices: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for raw in price_rows:
        row = dict(raw)
        row["_at"] = _dated_marker(row["observed_at"], household_tz)
        if row["_at"] <= end_cutoff:
            prices[(row["source_id"], row["asset_key"])].append(row)

    activity_rows = await (
        await db.execute(
            """
            SELECT snapshot.source_id, activity.snapshot_id, activity.activity_type,
                   activity.occurred_on, activity.amount_minor, activity.currency,
                   activity.description
            FROM finance_asset_report_activities activity
            JOIN finance_asset_snapshots snapshot
              ON snapshot.id = activity.snapshot_id
             AND snapshot.space_id = activity.space_id
             AND snapshot.family_id = activity.family_id
            WHERE activity.space_id = ? AND activity.family_id = ?
              AND activity.occurred_on BETWEEN ? AND ?
              AND snapshot.as_of_at <= ?
              AND activity.deleted_at IS NULL AND snapshot.deleted_at IS NULL
            ORDER BY snapshot.as_of_at, activity.occurred_on, activity.id
            """,
            (
                space_id,
                user["family_id"],
                start_date.isoformat(),
                end_date.isoformat(),
                end_cutoff.isoformat(),
            ),
        )
    ).fetchall()
    activities: dict[str, list[dict]] = defaultdict(list)
    for raw in activity_rows:
        activities[raw["snapshot_id"]].append(dict(raw))

    manual_rows = await (
        await db.execute(
            """
            WITH selected_items AS MATERIALIZED (
                SELECT * FROM finance_manual_assets
                WHERE space_id = ? AND family_id = ?
                  AND status = 'ACTIVE' AND deleted_at IS NULL
            ),
            selected_values AS (
                SELECT value.*
                FROM finance_manual_asset_values value
                JOIN selected_items item
                  ON item.id = value.item_id AND item.space_id = value.space_id
                 AND item.family_id = value.family_id
                WHERE value.as_of_at > ? AND value.as_of_at <= ?
                  AND value.deleted_at IS NULL
                UNION ALL
                SELECT baseline.*
                FROM selected_items item
                JOIN finance_manual_asset_values baseline ON baseline.id = (
                    SELECT latest.id FROM finance_manual_asset_values latest
                    WHERE latest.item_id = item.id AND latest.space_id = item.space_id
                      AND latest.family_id = item.family_id
                      AND latest.as_of_at <= ? AND latest.deleted_at IS NULL
                    ORDER BY latest.as_of_at DESC, latest.id DESC LIMIT 1
                )
            )
            SELECT item.id AS item_id, item.name, item.asset_class,
                   value.id AS value_id, value.as_of_at, value.value_minor,
                   value.currency, value.source_label
            FROM selected_items item
            JOIN selected_values value
              ON value.item_id = item.id AND value.space_id = item.space_id
             AND value.family_id = item.family_id
            ORDER BY value.as_of_at, value.id
            """,
            (
                space_id,
                user["family_id"],
                start_cutoff.isoformat(),
                end_cutoff.isoformat(),
                start_cutoff.isoformat(),
            ),
        )
    ).fetchall()
    manual: dict[str, list[dict]] = defaultdict(list)
    for raw in manual_rows:
        row = dict(raw)
        row["_at"] = _dated_marker(row["as_of_at"], household_tz)
        if row["_at"] <= end_cutoff:
            manual[row["item_id"]].append(row)

    dates = {end_date}
    has_value_at_start = (
        any(row["_at"] <= start_cutoff for rows in accounts.values() for row in rows)
        or any(reserve["_at"] <= start_cutoff for reserve in reserves)
        or any(row["_at"] <= start_cutoff for rows in source_snapshots.values() for row in rows)
        or any(row["_at"] <= start_cutoff for rows in manual.values() for row in rows)
    )
    if has_value_at_start:
        dates.add(start_date)
    for rows in accounts.values():
        dates.update(
            row["_at"].astimezone(household_tz).date()
            for row in rows
            if row["_at"].astimezone(household_tz).date() >= start_date
        )
    for rows in source_snapshots.values():
        dates.update(
            row["_at"].astimezone(household_tz).date()
            for row in rows
            if row["_at"].astimezone(household_tz).date() >= start_date
        )
    for rows in prices.values():
        dates.update(
            row["_at"].astimezone(household_tz).date()
            for row in rows
            if row["_at"].astimezone(household_tz).date() >= start_date
        )
    for rows in manual.values():
        dates.update(
            row["_at"].astimezone(household_tz).date()
            for row in rows
            if row["_at"].astimezone(household_tz).date() >= start_date
        )
    dates = {day for day in dates if start_date <= day <= end_date}

    points: list[FinanceNetWorthPointResponse] = []
    previous_investment: int | None = None
    previous_snapshot_ids: dict[str, str] = {}
    seen_activities: set[tuple] = set()
    latest_holdings: list[FinanceNetWorthHoldingResponse] = []
    latest_price_times: list[str] = []
    latest_price_sources: set[str] = set()
    latest_uses_saved_price = False
    account_cursors = {key: -1 for key in accounts}
    source_cursors = {key: -1 for key in source_snapshots}
    price_cursors = {key: -1 for key in prices}
    manual_cursors = {key: -1 for key in manual}
    last_day = max(dates)

    for day in sorted(dates):
        cutoff = datetime.combine(day, time.max, tzinfo=household_tz).astimezone(timezone.utc)
        layer_values = {layer: 0 for layer in NET_WORTH_LAYERS}
        unknown = 0
        collect_holdings = day == last_day
        holdings: list[FinanceNetWorthHoldingResponse] = []
        price_times: list[str] = []
        price_sources: set[str] = set()
        uses_saved_price = False

        for account_id, rows in accounts.items():
            row, account_cursors[account_id] = _advance_latest(
                rows, cutoff, account_cursors[account_id]
            )
            if row is None:
                continue
            if row["currency"] != currency:
                unknown += 1
                continue
            value = _signed_value(row["layer"], row["booked_minor"])
            layer_values[row["layer"]] += value
            if collect_holdings:
                holdings.append(
                    FinanceNetWorthHoldingResponse(
                        key=f"account:{account_id}",
                        source_label=row["institution"] or "Bank balance",
                        name=row["label"],
                        layer=row["layer"],
                        value_minor=value,
                        currency=currency,
                        as_of_at=row["observed_at"],
                        price_source="Bank balance",
                    )
                )

        for reserve in reserves:
            if reserve["_at"] > cutoff:
                continue
            if reserve["currency"] != currency:
                unknown += 1
                continue
            layer_values["PROTECTED_RESERVE"] += reserve["allocated_minor"]
            if collect_holdings:
                holdings.append(
                    FinanceNetWorthHoldingResponse(
                        key=f"reserve:{reserve['id']}",
                        source_label="Protected cash allocation",
                        name=reserve["name"],
                        layer="PROTECTED_RESERVE",
                        value_minor=reserve["allocated_minor"],
                        currency=currency,
                        as_of_at=reserve["updated_at"],
                        price_source="Saved allocation",
                    )
                )

        contributions = 0
        withdrawals = 0
        portfolio_value = 0
        for source_id, rows in source_snapshots.items():
            snapshot, source_cursors[source_id] = _advance_latest(
                rows, cutoff, source_cursors[source_id]
            )
            if snapshot is None:
                continue
            if previous_snapshot_ids.get(source_id) != snapshot["snapshot_id"]:
                for activity in activities.get(snapshot["snapshot_id"], []):
                    occurred_on = date.fromisoformat(activity["occurred_on"])
                    if not start_date <= occurred_on <= day:
                        continue
                    fingerprint = (
                        source_id,
                        activity["activity_type"],
                        activity["occurred_on"],
                        activity["amount_minor"],
                        activity["currency"],
                    )
                    if fingerprint in seen_activities:
                        continue
                    seen_activities.add(fingerprint)
                    if activity["currency"] != currency:
                        continue
                    if activity["activity_type"] == "CONTRIBUTION":
                        contributions += abs(activity["amount_minor"])
                    elif activity["activity_type"] == "WITHDRAWAL":
                        withdrawals += abs(activity["amount_minor"])
            previous_snapshot_ids[source_id] = snapshot["snapshot_id"]

            for position in snapshot["positions"]:
                price_key = (source_id, position["asset_key"])
                price_rows_for_key = prices.get(price_key, [])
                latest_price, price_cursors[price_key] = _advance_latest(
                    price_rows_for_key,
                    cutoff,
                    price_cursors.get(price_key, -1),
                )
                if latest_price is not None and (
                    latest_price["quote_symbol"] != position["quote_symbol"]
                    or (
                        latest_price["_at"] < snapshot["_at"]
                        and snapshot["source_kind"] != "MANUAL_PORTFOLIO"
                    )
                ):
                    latest_price = None
                if latest_price is not None and latest_price["currency"] == currency:
                    value = int(
                        (
                            Decimal(position["quantity_decimal"])
                            * Decimal(latest_price["unit_price_minor"])
                        ).to_integral_value(rounding=ROUND_HALF_UP)
                    )
                    observed_at = latest_price["observed_at"]
                    unit_price_minor = latest_price["unit_price_minor"]
                    price_source = latest_price["source_label"]
                    quote_symbol = latest_price["quote_symbol"]
                elif position["valuation_status"] == "KNOWN" and position["currency"] == currency:
                    value = position["value_minor"]
                    observed_at = position["observed_at"]
                    unit_price_minor = position["unit_price_minor"]
                    price_source = position["price_source"] or "Reviewed report"
                    quote_symbol = position["quote_symbol"]
                else:
                    unknown += 1
                    continue
                value = _signed_value(position["asset_class"], value)
                layer_values[position["asset_class"]] += value
                if collect_holdings:
                    holdings.append(
                        FinanceNetWorthHoldingResponse(
                            key=f"holding:{source_id}:{position['asset_key']}",
                            source_id=source_id,
                            source_label=snapshot["source_label"],
                            name=position["asset_name"],
                            layer=position["asset_class"],
                            value_minor=value,
                            currency=currency,
                            as_of_at=observed_at,
                            quantity=position["quantity_decimal"],
                            quantity_unit=position["quantity_unit"],
                            instrument_id_kind=position["instrument_id_kind"],
                            instrument_id=position["instrument_id"],
                            quote_symbol=quote_symbol,
                            unit_price_minor=unit_price_minor,
                            price_source=price_source,
                            using_last_known_price=(date.fromisoformat(observed_at[:10]) < day),
                        )
                    )
                if position["asset_class"] in INVESTMENT_LAYERS:
                    portfolio_value += value
                    if collect_holdings and position["asset_key"] != "hl:cash":
                        price_times.append(observed_at)
                        price_sources.add(price_source)
                if collect_holdings:
                    uses_saved_price = (
                        uses_saved_price or date.fromisoformat(observed_at[:10]) < day
                    )

        for item_id, rows in manual.items():
            row, manual_cursors[item_id] = _advance_latest(rows, cutoff, manual_cursors[item_id])
            if row is None:
                continue
            if row["currency"] != currency:
                unknown += 1
                continue
            value = _signed_value(row["asset_class"], row["value_minor"])
            layer_values[row["asset_class"]] += value
            if collect_holdings:
                holdings.append(
                    FinanceNetWorthHoldingResponse(
                        key=f"manual:{item_id}",
                        source_label=row["source_label"],
                        name=row["name"],
                        layer=row["asset_class"],
                        value_minor=value,
                        currency=currency,
                        as_of_at=row["as_of_at"],
                        price_source=row["source_label"],
                        using_last_known_price=(date.fromisoformat(row["as_of_at"][:10]) < day),
                    )
                )
            if collect_holdings and row["asset_class"] in INVESTMENT_LAYERS:
                price_times.append(row["as_of_at"])
                price_sources.add(row["source_label"])
                uses_saved_price = (
                    uses_saved_price or date.fromisoformat(row["as_of_at"][:10]) < day
                )

        total = sum(value for layer, value in layer_values.items() if layer != "PROTECTED_RESERVE")
        market_movement = (
            None
            if previous_investment is None
            else portfolio_value - previous_investment - contributions + withdrawals
        )
        previous_investment = portfolio_value
        points.append(
            FinanceNetWorthPointResponse(
                as_of_date=day,
                total_minor=total,
                unknown_component_count=unknown,
                layers=[
                    FinanceNetWorthPointLayerResponse(layer=layer, amount_minor=value)
                    for layer, value in layer_values.items()
                ],
                contributions_minor=contributions,
                withdrawals_minor=withdrawals,
                market_movement_minor=market_movement,
            )
        )
        if collect_holdings:
            latest_holdings = holdings
            latest_price_times = price_times
            latest_price_sources = price_sources
            latest_uses_saved_price = uses_saved_price

    current_total = points[-1].total_minor if points else 0
    first_total = points[0].total_minor if points else 0
    return FinanceNetWorthHistoryResponse(
        space_id=space_id,
        currency=currency,
        points=points,
        current_total_minor=current_total,
        change_minor=current_total - first_total,
        period_contributions_minor=sum(point.contributions_minor for point in points),
        period_withdrawals_minor=sum(point.withdrawals_minor for point in points),
        period_market_movement_minor=sum(point.market_movement_minor or 0 for point in points),
        holdings=sorted(
            latest_holdings,
            key=lambda item: (
                NET_WORTH_LAYERS.index(item.layer),
                -abs(item.value_minor),
                item.name.casefold(),
            ),
        ),
        price_observed_at=min(latest_price_times, default=None),
        price_sources=sorted(latest_price_sources),
        using_last_known_prices=latest_uses_saved_price,
    )
