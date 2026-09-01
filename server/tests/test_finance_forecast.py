"""Focused deterministic forecast tests."""

from datetime import date

from app.services.finance.forecast import (
    ForecastAccount,
    ForecastEvent,
    ForecastSnapshot,
    run_forecast,
    snapshot_digest,
)
from app.services.finance.money import Money


def _day(result, target: date):
    return next(day for day in result.days if day.day == target)


def test_snapshot_digest_and_forecast_are_reproducible_across_input_order():
    accounts = (
        ForecastAccount("current", Money(10_000, "GBP"), floor_minor=1_000),
        ForecastAccount("savings", Money(5_000, "GBP")),
    )
    events = (
        ForecastEvent(
            "salary",
            date(2026, 1, 2),
            "current",
            Money(2_000, "GBP"),
            "income",
        ),
        ForecastEvent(
            "planned",
            date(2026, 1, 3),
            "current",
            Money(-500, "GBP"),
            "planned",
        ),
    )
    first = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 1, 5),
        timezone="Europe/London",
        currency="GBP",
        accounts=accounts,
        events=events,
        household_buffer_minor=1_000,
    )
    reordered = ForecastSnapshot(
        start_date=first.start_date,
        end_date=first.end_date,
        timezone=first.timezone,
        currency=first.currency,
        accounts=tuple(reversed(accounts)),
        events=tuple(reversed(events)),
        household_buffer_minor=first.household_buffer_minor,
    )

    first_result = run_forecast(first)
    reordered_result = run_forecast(reordered)

    assert snapshot_digest(first) == snapshot_digest(reordered)
    assert first_result == reordered_result
    assert first_result.snapshot_digest == snapshot_digest(first)


def test_termly_commitments_and_internal_transfer_follow_exact_account_paths():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 9, 2),
        timezone="Europe/London",
        currency="GBP",
        accounts=(
            ForecastAccount("current", Money(10_000, "GBP")),
            ForecastAccount("savings", Money(5_000, "GBP")),
        ),
        events=(
            ForecastEvent(
                "move-to-savings",
                date(2026, 1, 2),
                "current",
                Money(-2_000, "GBP"),
                "transfer",
                destination_account_id="savings",
            ),
            ForecastEvent(
                "nursery-jan",
                date(2026, 1, 3),
                "current",
                Money(-2_000, "GBP"),
                "commitment",
            ),
            ForecastEvent(
                "nursery-apr",
                date(2026, 4, 3),
                "current",
                Money(-2_000, "GBP"),
                "commitment",
            ),
            ForecastEvent(
                "nursery-sep",
                date(2026, 9, 1),
                "current",
                Money(-2_000, "GBP"),
                "commitment",
            ),
        ),
        household_buffer_minor=1_000,
    )

    result = run_forecast(snapshot)

    transfer_day = _day(result, date(2026, 1, 2))
    transfer_balances = {
        account.account_id: account.balance_minor for account in transfer_day.accounts
    }
    assert transfer_balances == {"current": 8_000, "savings": 7_000}
    assert transfer_day.household_liquid_minor == 15_000
    final_balances = {
        account.account_id: account.balance_minor for account in result.days[-1].accounts
    }
    assert final_balances == {"current": 2_000, "savings": 7_000}
    assert result.passed is True


def test_forecast_returns_the_exact_event_that_first_breaks_a_floor():
    snapshot = ForecastSnapshot(
        start_date=date(2026, 1, 1),
        end_date=date(2026, 1, 4),
        timezone="Europe/London",
        currency="GBP",
        accounts=(ForecastAccount("current", Money(1_000, "GBP"), floor_minor=200),),
        events=(
            ForecastEvent(
                "insurance-reserve",
                date(2026, 1, 2),
                "current",
                Money(-500, "GBP"),
                "reserve",
            ),
            ForecastEvent(
                "goal-contribution",
                date(2026, 1, 3),
                "current",
                Money(-400, "GBP"),
                "goal",
            ),
        ),
    )

    result = run_forecast(snapshot)

    assert result.passed is False
    assert result.limiting_event is not None
    assert result.limiting_event.kind == "ACCOUNT_FLOOR"
    assert result.limiting_event.event_id == "goal-contribution"
    assert result.limiting_event.day == date(2026, 1, 3)
    assert result.limiting_event.actual_minor == 100
    assert result.limiting_event.shortfall_minor == 100
