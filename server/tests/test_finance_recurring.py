"""Focused recurring-series detection tests."""

from datetime import date, timedelta
from fractions import Fraction

from app.services.finance.analytics import TransactionRecord
from app.services.finance.money import Money
from app.services.finance.recurring import detect_recurring_series


def _transaction(
    record_id: str,
    day: date,
    amount_minor: int,
    key: str,
    *,
    transaction_type: str = "bank_transfer",
) -> TransactionRecord:
    return TransactionRecord(
        record_id,
        "dom",
        day,
        Money(amount_minor, "GBP"),
        "current",
        merchant=key,
        transaction_type=transaction_type,
        evidence_ids=(f"evidence:{record_id}",),
        recurring_key=key,
    )


def test_monthly_salary_and_four_weekly_thirteen_payday_detection():
    monthly_days = [
        date(2026, 1, 30),
        date(2026, 2, 27),
        date(2026, 3, 31),
        date(2026, 4, 30),
    ]
    four_weekly_days = [date(2026, 1, 2) + timedelta(days=28 * index) for index in range(13)]
    records = [
        *[
            _transaction(f"monthly-{index}", day, 500_000, "Example School salary")
            for index, day in enumerate(monthly_days)
        ],
        *[
            _transaction(f"four-{index}", day, 200_000, "Four weekly salary")
            for index, day in enumerate(four_weekly_days)
        ],
    ]

    series = detect_recurring_series(
        records,
        allowed_space_ids=("dom",),
        currency="GBP",
    )
    by_key = {item.key: item for item in series}

    monthly = by_key["income:bank_transfer:Example School salary"]
    assert monthly.cadence == "MONTHLY"
    assert monthly.expected_next_date == date(2026, 5, 29)
    assert monthly.variable_amount is False
    assert monthly.confidence == Fraction(1)

    four_weekly = by_key["income:bank_transfer:Four weekly salary"]
    assert four_weekly.cadence == "FOUR_WEEKLY"
    assert len(four_weekly.transaction_ids) == 13
    assert four_weekly.expected_next_date == date(2027, 1, 1)


def test_variable_direct_debit_and_annual_weekend_shift_are_detected():
    records = [
        _transaction("dd-jan", date(2026, 1, 15), -8_000, "Energy", transaction_type="direct_debit"),
        _transaction("dd-feb", date(2026, 2, 16), -11_000, "Energy", transaction_type="direct_debit"),
        _transaction("dd-mar", date(2026, 3, 16), -9_000, "Energy", transaction_type="direct_debit"),
        _transaction("annual-1", date(2025, 1, 10), -90_000, "Insurance"),
        _transaction("annual-2", date(2026, 1, 10), -92_000, "Insurance"),
    ]

    series = detect_recurring_series(
        records,
        allowed_space_ids=("dom",),
        currency="GBP",
    )
    by_key = {item.key: item for item in series}

    energy = by_key["cost:direct_debit:Energy"]
    assert energy.cadence == "MONTHLY"
    assert energy.variable_amount is True
    assert energy.minimum_amount_minor == 8_000
    assert energy.maximum_amount_minor == 11_000
    assert energy.confidence == Fraction(15, 16)

    annual = by_key["cost:bank_transfer:Insurance"]
    assert annual.cadence == "ANNUAL"
    assert annual.weekend_adjustment == "NEXT"
    assert annual.expected_next_date == date(2027, 1, 11)
