from datetime import date, datetime, timezone
from decimal import Decimal
from fractions import Fraction

import pytest

from app.services.finance.dates import financial_date, payday_for_month
from app.services.finance.money import (
    AllocationError,
    CurrencyMismatchError,
    Money,
    allocate_minor_units,
    convert_money,
)


def test_money_uses_exact_minor_units_and_requires_explicit_fx():
    assert Money.from_major("12.34", "gbp") == Money(1234, "GBP")
    assert Money(1200, "GBP") + Money(34, "GBP") == Money(1234, "GBP")
    with pytest.raises(CurrencyMismatchError):
        Money(100, "GBP") + Money(100, "EUR")
    with pytest.raises(TypeError):
        Money.from_major(12.34, "GBP")
    with pytest.raises(ValueError):
        Money(100, "pounds")


def test_explicit_conversion_preserves_source_and_uses_exact_rounding():
    result = convert_money(
        Money(101, "GBP"),
        "EUR",
        target_minor_per_source_minor=Fraction(6, 5),
    )

    assert result.source == Money(101, "GBP")
    assert result.converted == Money(121, "EUR")
    assert result.target_minor_per_source_minor == Fraction(6, 5)


def test_stable_hamilton_allocation_handles_ties_and_negative_totals():
    assert allocate_minor_units(5, {"b": 1, "a": 1, "c": 1}) == {
        "a": 2,
        "b": 2,
        "c": 1,
    }
    assert allocate_minor_units(-5, {"b": Decimal("1"), "a": Decimal("1")}) == {
        "a": -3,
        "b": -2,
    }


def test_bounded_allocation_sums_exactly_and_rejects_impossible_requests():
    result = allocate_minor_units(
        10,
        {"a": 1, "b": 3},
        lower_bounds={"a": 4},
        upper_bounds={"a": 4, "b": 6},
    )
    assert result == {"a": 4, "b": 6}
    assert sum(result.values()) == 10

    with pytest.raises(AllocationError):
        allocate_minor_units(10, {"a": 1, "b": 1}, lower_bounds={"a": 6, "b": 5})
    with pytest.raises(AllocationError):
        allocate_minor_units(10, {"a": 1, "b": 1}, upper_bounds={"a": 4, "b": 5})
    with pytest.raises(AllocationError):
        allocate_minor_units(1, {"a": 0})


def test_financial_date_uses_household_timezone_and_rejects_naive_instants():
    instant = datetime(2026, 1, 1, 0, 30, tzinfo=timezone.utc)
    assert financial_date(instant, "America/New_York") == date(2025, 12, 31)
    assert financial_date(instant, "Europe/London") == date(2026, 1, 1)
    with pytest.raises(ValueError):
        financial_date(datetime(2026, 1, 1, 0, 30), "Europe/London")


def test_payday_uses_confirmed_day_weekends_and_holidays():
    assert payday_for_month(2026, 8, calendar_day="last") == date(2026, 8, 31)
    assert payday_for_month(2026, 5, calendar_day=31) == date(2026, 5, 29)
    assert payday_for_month(
        2026,
        12,
        calendar_day=25,
        holidays={date(2026, 12, 25)},
    ) == date(2026, 12, 24)
