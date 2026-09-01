"""Calendar-safe birthday calculations shared by API and briefings."""

from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

FAMILY_TIMEZONE = ZoneInfo("Europe/London")


def family_today(reference: datetime | None = None) -> date:
    instant = reference or datetime.now(timezone.utc)
    if instant.tzinfo is None:
        instant = instant.replace(tzinfo=timezone.utc)
    return instant.astimezone(FAMILY_TIMEZONE).date()


def birthday_in_year(date_of_birth: date, year: int) -> date:
    """Return the observed birthday, using 28 February in non-leap years."""
    return birthday_in_year_parts(date_of_birth.month, date_of_birth.day, year)


def birthday_in_year_parts(month: int, day: int, year: int) -> date:
    """Return a birthday occurrence when the birth year is not known."""
    try:
        return date(year, month, day)
    except ValueError:
        if month == 2 and day == 29:
            return date(year, 2, 28)
        raise


def current_age(date_of_birth: date, on_date: date) -> int:
    age = on_date.year - date_of_birth.year
    if on_date < birthday_in_year(date_of_birth, on_date.year):
        age -= 1
    return age


def next_birthday(date_of_birth: date, on_date: date) -> date:
    return next_birthday_parts(date_of_birth.month, date_of_birth.day, on_date)


def next_birthday_parts(month: int, day: int, on_date: date) -> date:
    occurrence = birthday_in_year_parts(month, day, on_date.year)
    if occurrence >= on_date:
        return occurrence
    return birthday_in_year_parts(month, day, on_date.year + 1)


def turning_age(date_of_birth: date, on_date: date) -> int:
    return next_birthday(date_of_birth, on_date).year - date_of_birth.year
