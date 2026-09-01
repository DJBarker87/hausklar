"""Route-specific deterministic safe-to-spend calculations."""

from __future__ import annotations

import calendar
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Literal

from app.services.finance.forecast import (
    ForecastEvent,
    ForecastLimit,
    ForecastResult,
    ForecastSnapshot,
    run_forecast,
)
from app.services.finance.money import Money

# ``CANNOT_MODEL`` remains accepted by the public DTO for older saved responses, but
# this calculator now always returns an amount or range.
AnswerMode = Literal["CURRENT_EXACT", "DATED_EXACT", "ESTIMATED_RANGE", "CANNOT_MODEL"]
SafeToSpendStatus = Literal[
    "OK",
    "NO_SAFE_AMOUNT",
    "CANNOT_MODEL_DIRECT_ROUTE",
    "CANNOT_MODEL_CARD_ROUTE",
    "CANNOT_MODEL_NON_MONOTONE_ROUTE",
    "CANNOT_MODEL_UNBOUNDED_ROUTE",
]

_MAX_SEARCH_MINOR = 10**15


@dataclass(frozen=True, slots=True)
class DirectAccountRoute:
    account_id: str
    spend_date: date

    def __post_init__(self) -> None:
        if not isinstance(self.account_id, str) or not self.account_id:
            raise ValueError("Direct route account_id is required")
        if isinstance(self.spend_date, datetime) or not isinstance(self.spend_date, date):
            raise TypeError("Direct route spend_date must be a date")


@dataclass(frozen=True, slots=True)
class FullRepaymentCardRoute:
    card_account_id: str
    settlement_account_id: str
    purchase_date: date
    statement_close_day: int
    repayment_day: int

    def __post_init__(self) -> None:
        if not isinstance(self.card_account_id, str) or not self.card_account_id:
            raise ValueError("Card route card_account_id is required")
        if not isinstance(self.settlement_account_id, str) or not self.settlement_account_id:
            raise ValueError("Card route settlement_account_id is required")
        if isinstance(self.purchase_date, datetime) or not isinstance(self.purchase_date, date):
            raise TypeError("Card route purchase_date must be a date")
        for value, label in (
            (self.statement_close_day, "statement_close_day"),
            (self.repayment_day, "repayment_day"),
        ):
            if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 31:
                raise ValueError(f"{label} must be an integer from 1 to 31")


SpendRoute = DirectAccountRoute | FullRepaymentCardRoute


@dataclass(frozen=True, slots=True)
class FreshnessAssumptions:
    """Explicit caller-supplied allowance for transactions not yet observed."""

    data_through: date
    unobserved_spend_low_minor: int = 0
    unobserved_spend_high_minor: int = 0

    def __post_init__(self) -> None:
        if isinstance(self.data_through, datetime) or not isinstance(self.data_through, date):
            raise TypeError("data_through must be a date")
        low = self.unobserved_spend_low_minor
        high = self.unobserved_spend_high_minor
        if any(isinstance(value, bool) or not isinstance(value, int) for value in (low, high)):
            raise TypeError("Freshness allowances must be integer minor units")
        if low < 0 or high < low:
            raise ValueError("Freshness allowances require 0 <= low <= high")


@dataclass(frozen=True, slots=True)
class SafeToSpendResult:
    status: SafeToSpendStatus
    answer_mode: AnswerMode
    currency: str
    amount_minor: int | None
    low_minor: int | None
    high_minor: int | None
    data_through: date | None
    evaluated_through: date
    limiting_event: ForecastLimit | None
    refusal_reasons: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class _Boundary:
    amount_minor: int
    failure: ForecastResult
    baseline_passed: bool


@dataclass(frozen=True, slots=True)
class _PreparedRoute:
    route: SpendRoute | None
    estimated: bool
    notes: tuple[str, ...]


def _month_after(year: int, month: int) -> tuple[int, int]:
    if month == 12:
        return year + 1, 1
    return year, month + 1


def _day_in_month(year: int, month: int, requested_day: int) -> date:
    return date(year, month, min(requested_day, calendar.monthrange(year, month)[1]))


def card_statement_and_repayment_dates(route: FullRepaymentCardRoute) -> tuple[date, date]:
    close = _day_in_month(
        route.purchase_date.year,
        route.purchase_date.month,
        route.statement_close_day,
    )
    if route.purchase_date > close:
        close_year, close_month = _month_after(close.year, close.month)
        close = _day_in_month(close_year, close_month, route.statement_close_day)
    repay_year, repay_month = _month_after(close.year, close.month)
    repayment = _day_in_month(repay_year, repay_month, route.repayment_day)
    return close, repayment


def _route_date(route: SpendRoute) -> date:
    return route.spend_date if isinstance(route, DirectAccountRoute) else route.purchase_date


def _freshness_account(route: SpendRoute) -> str:
    if isinstance(route, DirectAccountRoute):
        return route.account_id
    return route.settlement_account_id


def _nearest_forecast_day(snapshot: ForecastSnapshot, day: date) -> date:
    return min(max(day, snapshot.start_date), snapshot.end_date)


def _fallback_cash_account(
    snapshot: ForecastSnapshot,
    *,
    exclude_ids: frozenset[str] = frozenset(),
) -> str | None:
    candidates = [
        account
        for account in snapshot.accounts
        if account.id not in exclude_ids
        and (account.floor_minor >= 0 or account.opening_balance.minor_units > 0)
    ]
    if not candidates:
        return None
    # Forecast snapshots deliberately contain only cash-flow accounts. Prefer an
    # included account with a non-negative floor, then the greatest known headroom.
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


def _prepare_route(snapshot: ForecastSnapshot, route: SpendRoute) -> _PreparedRoute:
    account_ids = {account.id for account in snapshot.accounts}
    route_date = _route_date(route)
    notes: list[str] = []
    estimated = False
    effective_date = _nearest_forecast_day(snapshot, route_date)
    if effective_date != route_date:
        notes.append("PURCHASE_DATE_NEAREST_SAVED_DAY_ESTIMATE")
        estimated = True

    if isinstance(route, DirectAccountRoute):
        account_id = route.account_id
        if account_id not in account_ids:
            account_id = _fallback_cash_account(snapshot)
            notes.append("PAYING_ACCOUNT_NEAREST_INCLUDED_ACCOUNT_ESTIMATE")
            estimated = True
        return _PreparedRoute(
            route=(
                DirectAccountRoute(account_id=account_id, spend_date=effective_date)
                if account_id is not None
                else None
            ),
            estimated=estimated,
            notes=tuple(notes),
        )

    card_complete = (
        route.card_account_id in account_ids
        and route.settlement_account_id in account_ids
        and route.card_account_id != route.settlement_account_id
    )
    if card_complete:
        _, repayment_date = card_statement_and_repayment_dates(
            FullRepaymentCardRoute(
                card_account_id=route.card_account_id,
                settlement_account_id=route.settlement_account_id,
                purchase_date=effective_date,
                statement_close_day=route.statement_close_day,
                repayment_day=route.repayment_day,
            )
        )
        card_complete = snapshot.end_date >= repayment_date + timedelta(days=1)
    if card_complete:
        return _PreparedRoute(
            route=FullRepaymentCardRoute(
                card_account_id=route.card_account_id,
                settlement_account_id=route.settlement_account_id,
                purchase_date=effective_date,
                statement_close_day=route.statement_close_day,
                repayment_day=route.repayment_day,
            ),
            estimated=estimated,
            notes=tuple(notes),
        )

    settlement_id = (
        route.settlement_account_id
        if route.settlement_account_id in account_ids
        and route.settlement_account_id != route.card_account_id
        else _fallback_cash_account(
            snapshot,
            exclude_ids=frozenset({route.card_account_id}),
        )
    )
    notes.append("CARD_TIMING_NOT_INCLUDED_DIRECT_ACCOUNT_ESTIMATE")
    return _PreparedRoute(
        route=(
            DirectAccountRoute(account_id=settlement_id, spend_date=effective_date)
            if settlement_id is not None
            else None
        ),
        estimated=True,
        notes=tuple(notes),
    )


def _derived_snapshot(
    snapshot: ForecastSnapshot,
    *,
    route: SpendRoute,
    candidate_minor: int,
    unobserved_spend_minor: int,
    unobserved_spend_day: date,
) -> ForecastSnapshot:
    events = list(snapshot.events)

    if unobserved_spend_minor:
        events.append(
            ForecastEvent(
                id="__safe_to_spend_unobserved__",
                day=unobserved_spend_day,
                account_id=_freshness_account(route),
                amount=Money(-unobserved_spend_minor, snapshot.currency),
                kind="expense",
                sequence=-20,
            )
        )

    if isinstance(route, DirectAccountRoute):
        if candidate_minor:
            events.append(
                ForecastEvent(
                    id="__safe_to_spend_candidate__",
                    day=route.spend_date,
                    account_id=route.account_id,
                    amount=Money(-candidate_minor, snapshot.currency),
                    kind="planned",
                    sequence=-10,
                )
            )
    else:
        _, repayment_date = card_statement_and_repayment_dates(route)
        if candidate_minor:
            events.extend(
                (
                    ForecastEvent(
                        id="__safe_to_spend_card_purchase__",
                        day=route.purchase_date,
                        account_id=route.card_account_id,
                        amount=Money(-candidate_minor, snapshot.currency),
                        kind="card_purchase",
                        sequence=-10,
                    ),
                    ForecastEvent(
                        id="__safe_to_spend_card_repayment__",
                        day=repayment_date,
                        account_id=route.settlement_account_id,
                        destination_account_id=route.card_account_id,
                        amount=Money(-candidate_minor, snapshot.currency),
                        kind="transfer",
                        sequence=10,
                    ),
                )
            )

    return ForecastSnapshot(
        start_date=snapshot.start_date,
        end_date=snapshot.end_date,
        timezone=snapshot.timezone,
        currency=snapshot.currency,
        accounts=snapshot.accounts,
        events=tuple(events),
        household_buffer_minor=snapshot.household_buffer_minor,
        engine_version=snapshot.engine_version,
        non_monotone_rule_ids=snapshot.non_monotone_rule_ids,
    )


def _find_boundary(
    snapshot: ForecastSnapshot,
    *,
    route: SpendRoute,
    unobserved_spend_minor: int,
    unobserved_spend_day: date,
) -> _Boundary | None:
    def evaluate(amount_minor: int) -> ForecastResult:
        return run_forecast(
            _derived_snapshot(
                snapshot,
                route=route,
                candidate_minor=amount_minor,
                unobserved_spend_minor=unobserved_spend_minor,
                unobserved_spend_day=unobserved_spend_day,
            )
        )

    baseline = evaluate(0)
    if not baseline.passed:
        return _Boundary(amount_minor=0, failure=baseline, baseline_passed=False)

    lower = 0
    upper = 1
    upper_result = evaluate(upper)
    while upper_result.passed and upper < _MAX_SEARCH_MINOR:
        lower = upper
        upper = min(upper * 2, _MAX_SEARCH_MINOR)
        upper_result = evaluate(upper)
    if upper_result.passed:
        return None

    while lower + 1 < upper:
        middle = (lower + upper) // 2
        middle_result = evaluate(middle)
        if middle_result.passed:
            lower = middle
        else:
            upper = middle
            upper_result = middle_result

    if upper != lower + 1:
        raise AssertionError("Safe-to-spend boundary search did not converge")
    return _Boundary(amount_minor=lower, failure=upper_result, baseline_passed=True)


def _mode(
    *,
    freshness: FreshnessAssumptions | None,
    route_date: date,
) -> AnswerMode:
    if freshness is None:
        return "CURRENT_EXACT"
    if freshness.unobserved_spend_high_minor > 0:
        return "ESTIMATED_RANGE"
    return "DATED_EXACT" if freshness.data_through < route_date else "CURRENT_EXACT"


def _unobserved_spend_day(
    snapshot: ForecastSnapshot,
    route: SpendRoute,
    freshness: FreshnessAssumptions | None,
) -> date:
    if freshness is None:
        return _route_date(route)
    earliest_unobserved = max(
        snapshot.start_date,
        freshness.data_through + timedelta(days=1),
    )
    return min(earliest_unobserved, _route_date(route))


def _estimated_interval(
    *,
    conservative_minor: int,
    optimistic_minor: int,
    add_small_allowance: bool,
) -> tuple[int, int]:
    low = max(0, min(conservative_minor, optimistic_minor))
    high = max(low, max(conservative_minor, optimistic_minor))
    if add_small_allowance and low == high and high > 0:
        # A ten-percent interval is deliberately small: it acknowledges a route or
        # coverage assumption without turning ordinary family-bank uncertainty into
        # a warning or an unusably wide answer.
        low = max(0, high - max(1, high // 10))
    return low, high


def _known_headroom(
    snapshot: ForecastSnapshot, route: SpendRoute
) -> tuple[int, ForecastLimit | None]:
    result = run_forecast(snapshot)
    account_id = _freshness_account(route)
    account_headroom = min(
        (
            account.headroom_minor
            for day in result.days
            for account in day.accounts
            if account.account_id == account_id
        ),
        default=0,
    )
    amount = max(0, min(account_headroom, result.minimum_household_free_minor))
    return amount, result.limiting_event


def calculate_safe_to_spend(
    snapshot: ForecastSnapshot,
    route: SpendRoute,
    *,
    freshness: FreshnessAssumptions | None = None,
    prefer_estimate: bool = False,
) -> SafeToSpendResult:
    """Return the best supported amount or range for the requested payment route."""

    prepared = _prepare_route(snapshot, route)
    if prepared.route is None:
        return SafeToSpendResult(
            status="NO_SAFE_AMOUNT",
            answer_mode="ESTIMATED_RANGE",
            currency=snapshot.currency,
            amount_minor=None,
            low_minor=0,
            high_minor=0,
            data_through=freshness.data_through if freshness else None,
            evaluated_through=snapshot.end_date,
            limiting_event=None,
            refusal_reasons=(*prepared.notes, "NO_INCLUDED_CASH_ACCOUNT_ZERO_ESTIMATE"),
        )
    effective_route = prepared.route
    notes = list(prepared.notes)
    route_needs_estimate = prepared.estimated or prefer_estimate
    if snapshot.non_monotone_rule_ids:
        route_needs_estimate = True
        notes.append("SAVED_THRESHOLD_RULE_SMALL_RANGE_ESTIMATE")

    low_assumption = freshness.unobserved_spend_low_minor if freshness else 0
    high_assumption = freshness.unobserved_spend_high_minor if freshness else 0
    unobserved_spend_day = _unobserved_spend_day(snapshot, effective_route, freshness)
    conservative = _find_boundary(
        snapshot,
        route=effective_route,
        unobserved_spend_minor=high_assumption,
        unobserved_spend_day=unobserved_spend_day,
    )
    optimistic = (
        conservative
        if low_assumption == high_assumption
        else _find_boundary(
            snapshot,
            route=effective_route,
            unobserved_spend_minor=low_assumption,
            unobserved_spend_day=unobserved_spend_day,
        )
    )
    if conservative is None or optimistic is None:
        fallback_amount, limiting_event = _known_headroom(snapshot, effective_route)
        low_minor, high_minor = _estimated_interval(
            conservative_minor=fallback_amount,
            optimistic_minor=fallback_amount,
            add_small_allowance=True,
        )
        return SafeToSpendResult(
            status="OK" if high_minor > 0 else "NO_SAFE_AMOUNT",
            answer_mode="ESTIMATED_RANGE",
            currency=snapshot.currency,
            amount_minor=None,
            low_minor=low_minor,
            high_minor=high_minor,
            data_through=freshness.data_through if freshness else None,
            evaluated_through=snapshot.end_date,
            limiting_event=limiting_event,
            refusal_reasons=(*notes, "KNOWN_HEADROOM_RANGE_ESTIMATE"),
        )

    evaluated_through = conservative.failure.end_date
    answer_mode = _mode(freshness=freshness, route_date=_route_date(effective_route))
    if route_needs_estimate:
        answer_mode = "ESTIMATED_RANGE"
    if not conservative.baseline_passed:
        high_minor = optimistic.amount_minor
        if answer_mode == "ESTIMATED_RANGE" and low_assumption == high_assumption:
            _, high_minor = _estimated_interval(
                conservative_minor=0,
                optimistic_minor=high_minor,
                add_small_allowance=route_needs_estimate,
            )
        return SafeToSpendResult(
            status="NO_SAFE_AMOUNT",
            answer_mode=answer_mode,
            currency=snapshot.currency,
            amount_minor=0 if answer_mode != "ESTIMATED_RANGE" else None,
            low_minor=0 if answer_mode == "ESTIMATED_RANGE" else None,
            high_minor=(high_minor if answer_mode == "ESTIMATED_RANGE" else None),
            data_through=freshness.data_through if freshness else None,
            evaluated_through=evaluated_through,
            limiting_event=conservative.failure.limiting_event,
            refusal_reasons=tuple(notes),
        )

    if answer_mode == "ESTIMATED_RANGE":
        low_minor, high_minor = _estimated_interval(
            conservative_minor=conservative.amount_minor,
            optimistic_minor=optimistic.amount_minor,
            add_small_allowance=(route_needs_estimate and low_assumption == high_assumption),
        )
        return SafeToSpendResult(
            status="OK",
            answer_mode=answer_mode,
            currency=snapshot.currency,
            amount_minor=None,
            low_minor=low_minor,
            high_minor=high_minor,
            data_through=freshness.data_through if freshness else None,
            evaluated_through=evaluated_through,
            limiting_event=conservative.failure.limiting_event,
            refusal_reasons=tuple(notes),
        )

    return SafeToSpendResult(
        status="OK",
        answer_mode=answer_mode,
        currency=snapshot.currency,
        amount_minor=conservative.amount_minor,
        low_minor=None,
        high_minor=None,
        data_through=freshness.data_through if freshness else None,
        evaluated_through=evaluated_through,
        limiting_event=conservative.failure.limiting_event,
        refusal_reasons=tuple(notes),
    )
