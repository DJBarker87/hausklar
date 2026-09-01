"""Authorised safe-to-spend answers from a stored Finance forecast."""

import json
from dataclasses import asdict
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app.models.finance import (
    FinanceSafeToSpendRequest,
    FinanceSafeToSpendResponse,
)
from app.services.finance.forecast import (
    ForecastAccount,
    ForecastEvent,
    ForecastSnapshot,
)
from app.services.finance.foundation import require_finance_space
from app.services.finance.money import Money
from app.services.finance.safe_to_spend import (
    DirectAccountRoute,
    FreshnessAssumptions,
    FullRepaymentCardRoute,
    calculate_safe_to_spend,
)


class FinanceSafeToSpendError(RuntimeError):
    """The stored forecast cannot support this answer."""


async def _stored_snapshot(db, *, user: dict, forecast_id: str):
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_forecast_snapshots
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (forecast_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceSafeToSpendError("Finance forecast not found")
    await require_finance_space(db, user=user, space_id=row["space_id"])
    try:
        persisted = json.loads(row["canonical_input_json"])
        payload = persisted["engine_input"]
        currency = payload["currency"]
        snapshot = ForecastSnapshot(
            start_date=date.fromisoformat(payload["start_date"]),
            end_date=date.fromisoformat(payload["end_date"]),
            timezone=payload["timezone"],
            currency=currency,
            accounts=tuple(
                ForecastAccount(
                    id=account["id"],
                    opening_balance=Money(account["opening_balance_minor"], currency),
                    floor_minor=account["floor_minor"],
                    include_in_household=account["include_in_household"],
                )
                for account in payload["accounts"]
            ),
            events=tuple(
                ForecastEvent(
                    id=event["id"],
                    day=date.fromisoformat(event["day"]),
                    account_id=event["account_id"],
                    amount=Money(event["amount_minor"], currency),
                    kind=event["kind"],
                    destination_account_id=event["destination_account_id"],
                    sequence=event["sequence"],
                )
                for event in payload["events"]
            ),
            household_buffer_minor=payload["household_buffer_minor"],
            engine_version=payload["engine_version"],
            non_monotone_rule_ids=tuple(payload["non_monotone_rule_ids"]),
        )
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise FinanceSafeToSpendError("Stored Finance forecast is not usable") from exc
    source = "SAVED" if persisted.get("source") == "SAVED" else "LEGACY_EXPLICIT"
    data_status = persisted.get(
        "data_status",
        "CURRENT" if row["data_through_at"] else "PARTIAL",
    )
    notes = persisted.get("input_notes", [])
    if not isinstance(notes, list) or any(not isinstance(item, str) for item in notes):
        notes = ["The stored forecast input warnings are not readable."]
        data_status = "PARTIAL"
    unsafe_routes = persisted.get("unsafe_safe_to_spend_routes", [])
    if data_status == "PARTIAL" and "unsafe_safe_to_spend_routes" not in persisted:
        unsafe_routes = ["direct", "full_repayment_card"]
    if not isinstance(unsafe_routes, list) or any(
        item not in {"direct", "full_repayment_card"} for item in unsafe_routes
    ):
        unsafe_routes = ["direct", "full_repayment_card"]
        notes.append("The stored route-safety warnings are not readable.")
        data_status = "PARTIAL"
    card_routes: dict[str, tuple[str, int, int]] = {}
    raw_card_routes = persisted.get("card_routes", [])
    if isinstance(raw_card_routes, list):
        for route in raw_card_routes:
            if not isinstance(route, dict):
                continue
            try:
                card_id = route["card_account_id"]
                settlement_id = route["settlement_account_id"]
                close_day = route["statement_close_day"]
                repayment_day = route["repayment_day"]
            except KeyError:
                continue
            if (
                isinstance(card_id, str)
                and isinstance(settlement_id, str)
                and isinstance(close_day, int)
                and not isinstance(close_day, bool)
                and 1 <= close_day <= 31
                and isinstance(repayment_day, int)
                and not isinstance(repayment_day, bool)
                and 1 <= repayment_day <= 31
            ):
                card_routes[card_id] = (settlement_id, close_day, repayment_day)
    return (
        row,
        snapshot,
        source,
        data_status,
        tuple(notes),
        frozenset(unsafe_routes),
        card_routes,
    )


def _data_through_date(row, *, timezone_name: str) -> date | None:
    data_through_at = row["data_through_at"]
    if data_through_at is None:
        return None
    try:
        observed_at = datetime.fromisoformat(str(data_through_at).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if observed_at.tzinfo is None or observed_at.utcoffset() is None:
        observed_at = observed_at.replace(tzinfo=timezone.utc)
    return observed_at.astimezone(ZoneInfo(timezone_name)).date()


async def _freshness(
    db,
    *,
    row,
    body: FinanceSafeToSpendRequest,
    snapshot: ForecastSnapshot,
) -> tuple[FreshnessAssumptions | None, tuple[str, ...]]:
    through = _data_through_date(row, timezone_name=snapshot.timezone)
    explicit_low = body.unobserved_spend_low_minor
    explicit_high = body.unobserved_spend_high_minor
    if explicit_low or explicit_high:
        if through is None:
            # The amount is still useful even when the imported-through timestamp is
            # absent. Anchor it to the first saved day and make the range clear.
            through = snapshot.start_date
        return (
            FreshnessAssumptions(
                data_through=through,
                unobserved_spend_low_minor=explicit_low,
                unobserved_spend_high_minor=explicit_high,
            ),
            (),
        )
    if through is None:
        return None, ("DATA_DATE_NOT_SAVED_SMALL_RANGE_ESTIMATE",)

    local_today = datetime.now(timezone.utc).astimezone(ZoneInfo(snapshot.timezone)).date()
    last_unobserved_day = min(body.spend_date, local_today)
    missing_days = max(0, (last_unobserved_day - through).days)
    if missing_days == 0:
        return FreshnessAssumptions(data_through=through), ()

    history_start = through - timedelta(days=27)
    spend_row = await (
        await db.execute(
            """
            SELECT COALESCE(SUM(-tx.amount_minor), 0)
            FROM finance_transactions tx
            LEFT JOIN finance_categories category
              ON category.id = tx.primary_category_id
             AND category.space_id = tx.space_id
             AND category.family_id = tx.family_id
             AND category.deleted_at IS NULL
            WHERE tx.space_id = ? AND tx.family_id = ? AND tx.currency = ?
              AND tx.state = 'POSTED' AND tx.amount_minor < 0
              AND tx.canonical_date BETWEEN ? AND ? AND tx.deleted_at IS NULL
              AND COALESCE(category.spending_type, 'FLEXIBLE') <> 'FIXED'
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
            """,
            (
                row["space_id"],
                row["family_id"],
                snapshot.currency,
                history_start.isoformat(),
                through.isoformat(),
            ),
        )
    ).fetchone()
    daily_minor = (max(0, int(spend_row[0])) + 27) // 28
    expected_minor = daily_minor * missing_days
    low_minor = expected_minor * 85 // 100
    high_minor = (expected_minor * 115 + 99) // 100
    return (
        FreshnessAssumptions(
            data_through=through,
            unobserved_spend_low_minor=low_minor,
            unobserved_spend_high_minor=high_minor,
        ),
        (("RECENT_SPENDING_AUTOMATIC_ALLOWANCE",) if high_minor else ()),
    )


async def _fallback_cash_account_id(
    db,
    *,
    row,
    snapshot: ForecastSnapshot,
    card_account_id: str,
) -> str | None:
    snapshot_ids = {account.id for account in snapshot.accounts}
    configured = await (
        await db.execute(
            """
            SELECT id FROM finance_accounts
            WHERE space_id = ? AND family_id = ? AND currency = ?
              AND account_type IN ('CURRENT', 'CASH', 'SAVINGS')
              AND include_in_cashflow = 1 AND deleted_at IS NULL
            ORDER BY primary_spending_account DESC,
                     CASE WHEN purpose = 'OPERATING_CURRENT' THEN 0 ELSE 1 END,
                     CASE WHEN account_type = 'CURRENT' THEN 0 ELSE 1 END,
                     id
            """,
            (row["space_id"], row["family_id"], snapshot.currency),
        )
    ).fetchall()
    for account in configured:
        if account["id"] in snapshot_ids and account["id"] != card_account_id:
            return account["id"]

    candidates = [
        account
        for account in snapshot.accounts
        if account.id != card_account_id
        and (account.floor_minor >= 0 or account.opening_balance.minor_units > 0)
    ]
    if not candidates:
        return None
    candidates.sort(
        key=lambda account: (
            account.include_in_household,
            account.floor_minor >= 0,
            account.opening_balance.minor_units - account.floor_minor,
            account.id,
        ),
        reverse=True,
    )
    return candidates[0].id


async def safe_to_spend_from_forecast(
    db, *, user: dict, body: FinanceSafeToSpendRequest
) -> FinanceSafeToSpendResponse:
    (
        row,
        snapshot,
        source,
        data_status,
        _input_notes,
        unsafe_routes,
        card_routes,
    ) = await _stored_snapshot(db, user=user, forecast_id=body.forecast_id)
    freshness, estimate_notes = await _freshness(
        db,
        row=row,
        body=body,
        snapshot=snapshot,
    )
    response_notes = list(estimate_notes)
    prefer_estimate = (
        source != "SAVED"
        or data_status != "CURRENT"
        or body.route in unsafe_routes
        or bool(estimate_notes)
    )
    if source != "SAVED" or data_status == "PARTIAL" or body.route in unsafe_routes:
        response_notes.append("SAVED_OUTLOOK_GAPS_SMALL_RANGE_ESTIMATE")
    if body.route == "direct":
        assert body.account_id is not None
        route = DirectAccountRoute(
            account_id=body.account_id,
            spend_date=body.spend_date,
        )
    else:
        assert body.card_account_id is not None
        card_route = card_routes.get(body.card_account_id)
        if card_route is None:
            fallback_account_id = await _fallback_cash_account_id(
                db,
                row=row,
                snapshot=snapshot,
                card_account_id=body.card_account_id,
            )
            if fallback_account_id is None:
                return FinanceSafeToSpendResponse(
                    forecast_id=row["id"],
                    input_snapshot_digest=row["input_snapshot_digest"],
                    status="NO_SAFE_AMOUNT",
                    answer_mode="ESTIMATED_RANGE",
                    currency=snapshot.currency,
                    low_minor=0,
                    high_minor=0,
                    data_through=freshness.data_through if freshness else None,
                    evaluated_through=snapshot.end_date,
                    refusal_reasons=[
                        "CARD_TIMING_NOT_INCLUDED_DIRECT_ACCOUNT_ESTIMATE",
                        "NO_INCLUDED_CASH_ACCOUNT_ZERO_ESTIMATE",
                    ],
                )
            route = DirectAccountRoute(
                account_id=fallback_account_id,
                spend_date=body.spend_date,
            )
            prefer_estimate = True
            response_notes.insert(0, "CARD_TIMING_NOT_INCLUDED_DIRECT_ACCOUNT_ESTIMATE")
        else:
            settlement_account_id, statement_close_day, repayment_day = card_route
            route = FullRepaymentCardRoute(
                card_account_id=body.card_account_id,
                settlement_account_id=settlement_account_id,
                purchase_date=body.spend_date,
                statement_close_day=statement_close_day,
                repayment_day=repayment_day,
            )
    result = calculate_safe_to_spend(
        snapshot,
        route,
        freshness=freshness,
        prefer_estimate=prefer_estimate,
    )
    limiting = asdict(result.limiting_event) if result.limiting_event else None
    return FinanceSafeToSpendResponse(
        forecast_id=row["id"],
        input_snapshot_digest=row["input_snapshot_digest"],
        status=result.status,
        answer_mode=result.answer_mode,
        currency=result.currency,
        amount_minor=result.amount_minor,
        low_minor=result.low_minor,
        high_minor=result.high_minor,
        data_through=result.data_through,
        evaluated_through=result.evaluated_through,
        limiting_event=limiting,
        refusal_reasons=list(dict.fromkeys([*result.refusal_reasons, *response_notes])),
    )
