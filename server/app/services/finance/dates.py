"""Household-timezone and confirmed-payday date helpers."""

import calendar
from collections.abc import Iterable
from datetime import date, datetime, time
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DEFAULT_HOUSEHOLD_TIMEZONE = "Europe/London"
WeekendAdjustment = Literal["previous", "next", "none"]


def household_zone(timezone_name: str) -> ZoneInfo:
    if not isinstance(timezone_name, str) or not timezone_name.strip():
        raise ValueError("Household timezone must be an IANA timezone name")
    try:
        return ZoneInfo(timezone_name.strip())
    except ZoneInfoNotFoundError as exc:
        raise ValueError("Household timezone must be an IANA timezone name") from exc


def financial_date(value: date | datetime, timezone_name: str) -> date:
    """Map an aware instant to the household civil date."""
    if isinstance(value, datetime):
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("Financial instants must include a timezone")
        return value.astimezone(household_zone(timezone_name)).date()
    if isinstance(value, date):
        return value
    raise TypeError("Financial date must be a date or timezone-aware datetime")


def start_of_financial_day(day: date, timezone_name: str) -> datetime:
    if isinstance(day, datetime) or not isinstance(day, date):
        raise TypeError("day must be a civil date")
    return datetime.combine(day, time.min, tzinfo=household_zone(timezone_name))


def is_working_day(day: date, *, holidays: Iterable[date] = ()) -> bool:
    return day.weekday() < 5 and day not in frozenset(holidays)


def adjust_to_working_day(
    day: date,
    *,
    adjustment: WeekendAdjustment,
    holidays: Iterable[date] = (),
) -> date:
    if adjustment not in {"previous", "next", "none"}:
        raise ValueError("Unknown working-day adjustment")
    holiday_dates = frozenset(holidays)
    if adjustment == "none" or is_working_day(day, holidays=holiday_dates):
        return day
    step = -1 if adjustment == "previous" else 1
    candidate = day
    while not is_working_day(candidate, holidays=holiday_dates):
        candidate = date.fromordinal(candidate.toordinal() + step)
    return candidate


def payday_for_month(
    year: int,
    month: int,
    *,
    calendar_day: int | Literal["last"],
    adjustment: WeekendAdjustment = "previous",
    holidays: Iterable[date] = (),
) -> date:
    """Resolve a confirmed monthly payday without assuming generic month end."""
    last_day = calendar.monthrange(year, month)[1]
    if calendar_day == "last":
        day_number = last_day
    else:
        if isinstance(calendar_day, bool) or not isinstance(calendar_day, int):
            raise TypeError("calendar_day must be 1..31 or 'last'")
        if not 1 <= calendar_day <= 31:
            raise ValueError("calendar_day must be 1..31 or 'last'")
        day_number = min(calendar_day, last_day)
    return adjust_to_working_day(
        date(year, month, day_number),
        adjustment=adjustment,
        holidays=holidays,
    )
