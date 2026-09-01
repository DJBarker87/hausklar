"""Deterministic recurring income and cost detection."""

from __future__ import annotations

import calendar
from dataclasses import dataclass
from datetime import date, timedelta
from fractions import Fraction
from typing import Literal

from app.services.finance.analytics import TransactionRecord
from app.services.finance.money import normalise_currency

Cadence = Literal["MONTHLY", "FOUR_WEEKLY", "ANNUAL", "IRREGULAR"]
WeekendAdjustment = Literal["PREVIOUS", "NEXT"]


@dataclass(frozen=True, slots=True)
class RecurringSeries:
    key: str
    cadence: Cadence
    transaction_ids: tuple[str, ...]
    evidence_ids: tuple[str, ...]
    first_date: date
    last_date: date
    expected_next_date: date
    average_amount_minor: Fraction
    minimum_amount_minor: int
    maximum_amount_minor: int
    variable_amount: bool
    weekend_adjustment: WeekendAdjustment
    confidence: Fraction


def _month_number(day: date) -> int:
    return day.year * 12 + day.month - 1


def _next_month(year: int, month: int) -> tuple[int, int]:
    if month == 12:
        return year + 1, 1
    return year, month + 1


def _adjust_working_day(
    day: date,
    adjustment: WeekendAdjustment,
    bank_holidays: frozenset[date],
) -> date:
    if day.weekday() < 5 and day not in bank_holidays:
        return day
    step = -1 if adjustment == "PREVIOUS" else 1
    candidate = day
    while candidate.weekday() >= 5 or candidate in bank_holidays:
        candidate += timedelta(days=step)
    return candidate


def _easter_sunday(year: int) -> date:
    """Gregorian Easter date, used only for deterministic UK bank holidays."""
    a = year % 19
    b, c = divmod(year, 100)
    d, e = divmod(b, 4)
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = divmod(c, 4)
    ell = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * ell) // 451
    month = (h + ell - 7 * m + 114) // 31
    day = (h + ell - 7 * m + 114) % 31 + 1
    return date(year, month, day)


def england_wales_bank_holidays(year: int) -> frozenset[date]:
    """Return the ordinary England/Wales holidays used by the UK household."""

    def monday_in_month(month: int, *, last: bool = False) -> date:
        if last:
            candidate = date(year, month, calendar.monthrange(year, month)[1])
            return candidate - timedelta(days=candidate.weekday())
        candidate = date(year, month, 1)
        return candidate + timedelta(days=(-candidate.weekday()) % 7)

    holidays: set[date] = set()
    new_year = date(year, 1, 1)
    while new_year.weekday() >= 5:
        new_year += timedelta(days=1)
    holidays.add(new_year)
    easter = _easter_sunday(year)
    holidays.update((easter - timedelta(days=2), easter + timedelta(days=1)))
    holidays.update(
        (
            monday_in_month(5),
            monday_in_month(5, last=True),
            monday_in_month(8, last=True),
        )
    )
    for calendar_day in (date(year, 12, 25), date(year, 12, 26)):
        observed = calendar_day
        while observed.weekday() >= 5 or observed in holidays:
            observed += timedelta(days=1)
        holidays.add(observed)
    return frozenset(holidays)


def _cadence(days: list[date]) -> tuple[Cadence, Fraction] | None:
    if len(days) < 2:
        return None
    intervals = [(later - earlier).days for earlier, later in zip(days, days[1:])]
    month_intervals = [
        _month_number(later) - _month_number(earlier)
        for earlier, later in zip(days, days[1:])
    ]

    if len(days) >= 4:
        matches = sum(26 <= interval <= 30 for interval in intervals)
        if matches == len(intervals):
            return "FOUR_WEEKLY", Fraction(matches, len(intervals))
    if len(days) >= 3:
        matches = sum(months == 1 for months in month_intervals)
        if matches == len(month_intervals):
            return "MONTHLY", Fraction(matches, len(month_intervals))
    matches = sum(
        months == 12 and 360 <= interval <= 371
        for months, interval in zip(month_intervals, intervals, strict=True)
    )
    if matches == len(intervals):
        return "ANNUAL", Fraction(matches, len(intervals))
    if len(days) >= 3 and all(7 <= interval <= 400 for interval in intervals):
        spread = max(intervals) - min(intervals)
        confidence = max(Fraction(1, 2), Fraction(4, 5) - Fraction(spread, 1000))
        return "IRREGULAR", confidence
    return None


def _expected_next(
    days: list[date],
    cadence: Cadence,
    adjustment: WeekendAdjustment,
    bank_holidays: frozenset[date],
) -> date:
    last = days[-1]
    if cadence == "FOUR_WEEKLY":
        return _adjust_working_day(
            last + timedelta(days=28), adjustment, bank_holidays
        )
    if cadence == "ANNUAL":
        try:
            candidate = last.replace(year=last.year + 1)
        except ValueError:
            candidate = last.replace(year=last.year + 1, day=28)
        return _adjust_working_day(candidate, adjustment, bank_holidays)

    if cadence == "IRREGULAR":
        intervals = sorted(
            (later - earlier).days for earlier, later in zip(days, days[1:])
        )
        typical_interval = intervals[len(intervals) // 2]
        return _adjust_working_day(
            last + timedelta(days=typical_interval),
            adjustment,
            bank_holidays,
        )

    next_year, next_month = _next_month(last.year, last.month)
    last_working_day_pattern = all(
        day.day >= calendar.monthrange(day.year, day.month)[1] - 3 for day in days
    )
    if last_working_day_pattern:
        candidate = date(
            next_year,
            next_month,
            calendar.monthrange(next_year, next_month)[1],
        )
    else:
        typical_day = sorted(day.day for day in days)[len(days) // 2]
        candidate = date(
            next_year,
            next_month,
            min(typical_day, calendar.monthrange(next_year, next_month)[1]),
        )
    return _adjust_working_day(candidate, adjustment, bank_holidays)


def detect_recurring_series(
    transactions: tuple[TransactionRecord, ...] | list[TransactionRecord],
    *,
    allowed_space_ids: tuple[str, ...] | list[str],
    currency: str,
    bank_holidays: tuple[date, ...] | list[date] = (),
) -> tuple[RecurringSeries, ...]:
    """Detect bounded common cadences from normalized transaction records."""

    allowed_spaces = set(allowed_space_ids)
    if not allowed_spaces:
        raise ValueError("Recurring detection requires an authorized Finance space")
    currency = normalise_currency(currency)
    holiday_dates = frozenset(bank_holidays)
    grouped: dict[str, list[TransactionRecord]] = {}
    for transaction in transactions:
        if transaction.space_id not in allowed_spaces or transaction.amount.currency != currency:
            continue
        direction = "income" if transaction.amount.minor_units > 0 else "cost"
        base_key = transaction.recurring_key or transaction.merchant or transaction.category
        if not base_key or transaction.amount.minor_units == 0:
            continue
        key = f"{direction}:{transaction.transaction_type}:{base_key}"
        grouped.setdefault(key, []).append(transaction)

    detected: list[RecurringSeries] = []
    for key in sorted(grouped):
        records = sorted(grouped[key], key=lambda item: (item.day, item.id))
        days = [record.day for record in records]
        cadence_result = _cadence(days)
        if cadence_result is None:
            continue
        cadence, interval_confidence = cadence_result
        amounts = [abs(record.amount.minor_units) for record in records]
        average = Fraction(sum(amounts), len(amounts))
        variable_threshold = max(Fraction(100), average / 20)
        variable = max(amounts) - min(amounts) > variable_threshold
        amount_confidence = Fraction(3, 4) if variable else Fraction(1)
        confidence = interval_confidence * Fraction(3, 4) + amount_confidence / 4
        adjustment: WeekendAdjustment = (
            "PREVIOUS" if records[-1].amount.minor_units > 0 else "NEXT"
        )
        detected.append(
            RecurringSeries(
                key=key,
                cadence=cadence,
                transaction_ids=tuple(record.id for record in records),
                evidence_ids=tuple(
                    sorted(
                        {
                            evidence_id
                            for record in records
                            for evidence_id in record.evidence_ids
                        }
                    )
                ),
                first_date=days[0],
                last_date=days[-1],
                expected_next_date=_expected_next(
                    days,
                    cadence,
                    adjustment,
                    holiday_dates,
                ),
                average_amount_minor=average,
                minimum_amount_minor=min(amounts),
                maximum_amount_minor=max(amounts),
                variable_amount=variable,
                weekend_adjustment=adjustment,
                confidence=confidence,
            )
        )
    return tuple(detected)
