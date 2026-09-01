"""Focused route-specific safe-to-spend tests."""

from datetime import date

from app.services.finance.forecast import (
    ForecastAccount,
    ForecastEvent,
    ForecastSnapshot,
    run_forecast,
)
from app.services.finance.money import Money
from app.services.finance.safe_to_spend import (
    DirectAccountRoute,
    FreshnessAssumptions,
    FullRepaymentCardRoute,
    calculate_safe_to_spend,
)


def test_direct_route_returns_maximum_that_passes_and_next_penny_fails():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 1, 31),
        timezone="Europe/London",
        currency="GBP",
        accounts=(ForecastAccount("current", Money(10_000, "GBP"), floor_minor=2_000),),
        events=(
            ForecastEvent(
                "future-bill",
                date(2026, 1, 20),
                "current",
                Money(-3_000, "GBP"),
                "commitment",
            ),
        ),
        household_buffer_minor=1_000,
    )
    route = DirectAccountRoute("current", date(2026, 1, 5))

    result = calculate_safe_to_spend(snapshot, route)

    assert result.status == "OK"
    assert result.answer_mode == "CURRENT_EXACT"
    assert result.amount_minor == 4_000
    assert result.limiting_event is not None
    assert result.limiting_event.event_id == "future-bill"
    assert result.limiting_event.shortfall_minor == 1

    next_penny = ForecastSnapshot(
        start_date=snapshot.start_date,
        end_date=snapshot.end_date,
        timezone=snapshot.timezone,
        currency=snapshot.currency,
        accounts=snapshot.accounts,
        events=snapshot.events
        + (
            ForecastEvent(
                "candidate-next-penny",
                route.spend_date,
                route.account_id,
                Money(-(result.amount_minor + 1), "GBP"),
                "planned",
            ),
        ),
        household_buffer_minor=snapshot.household_buffer_minor,
    )
    assert run_forecast(next_penny).passed is False


def test_full_repayment_card_requires_and_uses_complete_repayment_horizon():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 2, 6),
        timezone="Europe/London",
        currency="GBP",
        accounts=(
            ForecastAccount("current", Money(10_000, "GBP"), floor_minor=1_000),
            ForecastAccount("card", Money(0, "GBP"), floor_minor=-10_000),
        ),
        events=(
            ForecastEvent(
                "post-original-horizon-bill",
                date(2026, 2, 1),
                "current",
                Money(-1_000, "GBP"),
                "commitment",
            ),
        ),
        household_buffer_minor=1_000,
    )
    route = FullRepaymentCardRoute(
        card_account_id="card",
        settlement_account_id="current",
        purchase_date=date(2026, 1, 10),
        statement_close_day=15,
        repayment_day=5,
    )

    result = calculate_safe_to_spend(snapshot, route)

    assert result.status == "OK"
    assert result.amount_minor == 8_000
    assert result.evaluated_through == date(2026, 2, 6)
    assert result.limiting_event is not None
    assert result.limiting_event.event_id == "__safe_to_spend_card_repayment__"
    assert result.limiting_event.shortfall_minor == 1

    short_horizon = ForecastSnapshot(
        start_date=snapshot.start_date,
        end_date=date(2026, 1, 20),
        timezone=snapshot.timezone,
        currency=snapshot.currency,
        accounts=snapshot.accounts,
        household_buffer_minor=snapshot.household_buffer_minor,
    )
    estimated = calculate_safe_to_spend(short_horizon, route)
    assert estimated.status == "OK"
    assert estimated.answer_mode == "ESTIMATED_RANGE"
    assert (estimated.low_minor, estimated.high_minor) == (8_100, 9_000)
    assert estimated.refusal_reasons == ("CARD_TIMING_NOT_INCLUDED_DIRECT_ACCOUNT_ESTIMATE",)


def test_stale_result_uses_only_explicit_unobserved_spend_range():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 1, 10),
        timezone="Europe/London",
        currency="GBP",
        accounts=(ForecastAccount("current", Money(10_000, "GBP")),),
        household_buffer_minor=1_000,
    )

    result = calculate_safe_to_spend(
        snapshot,
        DirectAccountRoute("current", date(2026, 1, 5)),
        freshness=FreshnessAssumptions(
            data_through=date(2026, 1, 2),
            unobserved_spend_low_minor=100,
            unobserved_spend_high_minor=500,
        ),
    )

    assert result.status == "OK"
    assert result.answer_mode == "ESTIMATED_RANGE"
    assert result.amount_minor is None
    assert result.low_minor == 8_500
    assert result.high_minor == 8_900
    assert result.data_through == date(2026, 1, 2)


def test_stale_spend_is_applied_before_later_salary_can_hide_a_floor_breach():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 1, 10),
        timezone="Europe/London",
        currency="GBP",
        accounts=(ForecastAccount("current", Money(500, "GBP"), floor_minor=400),),
        events=(
            ForecastEvent(
                "salary",
                date(2026, 1, 4),
                "current",
                Money(1_000, "GBP"),
                "income",
            ),
        ),
    )

    result = calculate_safe_to_spend(
        snapshot,
        DirectAccountRoute("current", date(2026, 1, 5)),
        freshness=FreshnessAssumptions(
            data_through=date(2025, 12, 31),
            unobserved_spend_low_minor=0,
            unobserved_spend_high_minor=200,
        ),
    )

    assert result.status == "NO_SAFE_AMOUNT"
    assert result.answer_mode == "ESTIMATED_RANGE"
    assert result.low_minor == 0
    assert result.high_minor == 1_100
    assert result.limiting_event is not None
    assert result.limiting_event.event_id == "__safe_to_spend_unobserved__"
    assert result.limiting_event.day == date(2026, 1, 1)
    assert result.limiting_event.shortfall_minor == 100


def test_missing_card_timing_and_non_monotone_rules_still_return_useful_ranges():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 1, 31),
        timezone="Europe/London",
        currency="GBP",
        accounts=(ForecastAccount("current", Money(10_000, "GBP")),),
    )
    missing_card = calculate_safe_to_spend(
        snapshot,
        FullRepaymentCardRoute(
            card_account_id="missing-card",
            settlement_account_id="current",
            purchase_date=date(2026, 1, 10),
            statement_close_day=15,
            repayment_day=5,
        ),
    )

    assert missing_card.status == "OK"
    assert missing_card.answer_mode == "ESTIMATED_RANGE"
    assert (missing_card.low_minor, missing_card.high_minor) == (9_000, 10_000)
    assert missing_card.refusal_reasons == ("CARD_TIMING_NOT_INCLUDED_DIRECT_ACCOUNT_ESTIMATE",)

    non_monotone = ForecastSnapshot(
        start_date=snapshot.start_date,
        end_date=snapshot.end_date,
        timezone=snapshot.timezone,
        currency=snapshot.currency,
        accounts=snapshot.accounts,
        non_monotone_rule_ids=("threshold-cashback",),
    )
    estimated = calculate_safe_to_spend(
        non_monotone,
        DirectAccountRoute("current", date(2026, 1, 10)),
    )
    assert estimated.status == "OK"
    assert estimated.answer_mode == "ESTIMATED_RANGE"
    assert (estimated.low_minor, estimated.high_minor) == (9_000, 10_000)
    assert estimated.refusal_reasons == ("SAVED_THRESHOLD_RULE_SMALL_RANGE_ESTIMATE",)


def test_dates_beyond_the_saved_outlook_use_the_nearest_day_and_still_answer():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 1, 31),
        timezone="Europe/London",
        currency="GBP",
        accounts=(ForecastAccount("current", Money(10_000, "GBP")),),
        household_buffer_minor=1_000,
    )

    result = calculate_safe_to_spend(
        snapshot,
        DirectAccountRoute("current", date(2026, 3, 1)),
    )

    assert result.status == "OK"
    assert result.answer_mode == "ESTIMATED_RANGE"
    assert (result.low_minor, result.high_minor) == (8_100, 9_000)
    assert result.refusal_reasons == ("PURCHASE_DATE_NEAREST_SAVED_DAY_ESTIMATE",)


def test_card_only_snapshot_returns_zero_range_instead_of_a_route_refusal():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 1, 31),
        timezone="Europe/London",
        currency="GBP",
        accounts=(ForecastAccount("card", Money(0, "GBP"), floor_minor=-50_000),),
    )

    result = calculate_safe_to_spend(
        snapshot,
        FullRepaymentCardRoute(
            card_account_id="card",
            settlement_account_id="missing-current",
            purchase_date=date(2026, 1, 10),
            statement_close_day=15,
            repayment_day=5,
        ),
    )

    assert result.status == "NO_SAFE_AMOUNT"
    assert result.answer_mode == "ESTIMATED_RANGE"
    assert (result.low_minor, result.high_minor) == (0, 0)
    assert result.refusal_reasons == (
        "CARD_TIMING_NOT_INCLUDED_DIRECT_ACCOUNT_ESTIMATE",
        "NO_INCLUDED_CASH_ACCOUNT_ZERO_ESTIMATE",
    )
