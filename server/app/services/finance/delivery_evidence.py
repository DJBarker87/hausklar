"""Strict delivery dates that are safe to offer for adult review."""

from datetime import date, datetime, time, timezone
import re

from app.services.finance.dates import household_zone


LABELLED_EMAIL_DELIVERY_ORIGIN = "labelled_email_v1"

_LABEL = re.compile(r"^([A-Za-z _-]+):\s*(.+?)\s*$", re.MULTILINE)
_DATE_LABELS = frozenset(
    {
        "delivery date",
        "arrival date",
        "expected delivery date",
        "estimated delivery date",
        "expected arrival date",
        "estimated arrival date",
    }
)
_TIME_LABELS = frozenset(
    {
        "delivery time",
        "arrival time",
        "delivery window",
        "arrival window",
        "expected delivery time",
        "estimated delivery time",
        "expected arrival time",
        "estimated arrival time",
        "expected delivery window",
        "estimated delivery window",
        "expected arrival window",
        "estimated arrival window",
    }
)
_DATE_FORMATS = (
    "%Y-%m-%d",
    "%d/%m/%Y",
    "%d-%m-%Y",
    "%d %B %Y",
    "%d %b %Y",
    "%B %d, %Y",
    "%b %d, %Y",
)
_TIME_TOKEN = r"(?:[0-9]{1,2}(?::[0-9]{2})?\s*(?:a\.?m\.?|p\.?m\.?)?)"
_TIME_WINDOW = re.compile(
    rf"^(?P<start>{_TIME_TOKEN})(?:\s*(?:-|–|—|to)\s*(?P<end>{_TIME_TOKEN}))?$",
    re.IGNORECASE,
)


def _normalise_label(value: str) -> str:
    return " ".join(value.replace("_", " ").replace("-", " ").casefold().split())


def _labelled_values(body_text: str, accepted_labels: frozenset[str]) -> list[str]:
    matches = [
        " ".join(value.split())
        for label, value in _LABEL.findall(body_text)
        if _normalise_label(label) in accepted_labels
    ]
    unique = {value.casefold(): value for value in matches}
    return list(unique.values())


def _parse_date(value: str) -> date | None:
    for date_format in _DATE_FORMATS:
        try:
            return datetime.strptime(value, date_format).date()
        except ValueError:
            continue
    return None


def _parse_time(value: str) -> time | None:
    compact = value.casefold().replace(".", "").replace(" ", "")
    match = re.fullmatch(
        r"(?P<hour>[0-9]{1,2})(?::(?P<minute>[0-9]{2}))?(?P<period>am|pm)?",
        compact,
    )
    if match is None:
        return None
    hour = int(match.group("hour"))
    minute_text = match.group("minute")
    period = match.group("period")
    if minute_text is None and period is None:
        return None
    minute = int(minute_text or 0)
    if minute > 59:
        return None
    if period:
        if not 1 <= hour <= 12:
            return None
        hour = hour % 12 + (12 if period == "pm" else 0)
    elif hour > 23:
        return None
    return time(hour, minute)


def _unambiguous_local_datetime(
    day: date,
    clock_time: time,
    timezone_name: str,
) -> datetime | None:
    try:
        zone = household_zone(timezone_name)
    except ValueError:
        return None
    naive = datetime.combine(day, clock_time)
    candidates: dict[datetime, datetime] = {}
    for fold in (0, 1):
        candidate = naive.replace(tzinfo=zone, fold=fold)
        round_trip = candidate.astimezone(timezone.utc).astimezone(zone)
        if round_trip.replace(tzinfo=None) == naive:
            candidates[candidate.astimezone(timezone.utc)] = candidate
    if len(candidates) != 1:
        return None
    return next(iter(candidates.values()))


def labelled_email_delivery_window(
    body_text: str,
    *,
    timezone_name: str,
) -> dict[str, object] | None:
    """Read only exact labelled fields; never infer a date from ordinary prose."""
    date_values = _labelled_values(body_text, _DATE_LABELS)
    if len(date_values) != 1:
        return None
    delivery_day = _parse_date(date_values[0])
    if delivery_day is None:
        return None

    time_values = _labelled_values(body_text, _TIME_LABELS)
    if len(time_values) > 1:
        return None
    if not time_values:
        return {
            "starts_at": delivery_day.isoformat(),
            "ends_at": None,
            "all_day": True,
        }
    time_value = time_values[0]
    if time_value.casefold() == "all day":
        return {
            "starts_at": delivery_day.isoformat(),
            "ends_at": None,
            "all_day": True,
        }

    match = _TIME_WINDOW.fullmatch(time_value)
    if match is None:
        return None
    start_time = _parse_time(match.group("start"))
    end_text = match.group("end")
    end_time = _parse_time(end_text) if end_text else None
    if start_time is None or (end_text is not None and end_time is None):
        return None
    starts_at = _unambiguous_local_datetime(delivery_day, start_time, timezone_name)
    ends_at = (
        _unambiguous_local_datetime(delivery_day, end_time, timezone_name)
        if end_time is not None
        else None
    )
    if starts_at is None or (end_text is not None and ends_at is None):
        return None
    if ends_at is not None and ends_at <= starts_at:
        return None
    return {
        "starts_at": starts_at.isoformat(),
        "ends_at": ends_at.isoformat() if ends_at is not None else None,
        "all_day": False,
    }
