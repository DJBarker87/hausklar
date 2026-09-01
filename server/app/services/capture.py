"""Deterministic parsing fallback for universal family capture."""

import re
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.document import CaptureSuggestionCreate

_MONTHS = {
    "jan": 1,
    "january": 1,
    "feb": 2,
    "february": 2,
    "mar": 3,
    "march": 3,
    "apr": 4,
    "april": 4,
    "may": 5,
    "jun": 6,
    "june": 6,
    "jul": 7,
    "july": 7,
    "aug": 8,
    "august": 8,
    "sep": 9,
    "sept": 9,
    "september": 9,
    "oct": 10,
    "october": 10,
    "nov": 11,
    "november": 11,
    "dec": 12,
    "december": 12,
}
_WEEKDAYS = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}
_TASK_WORDS = (
    "buy",
    "call",
    "collect",
    "complete",
    "email",
    "order",
    "pack",
    "pay",
    "pick up",
    "remember",
    "remind",
    "return",
    "send",
    "submit",
)
_OBVIOUS_TYPO_CORRECTIONS = {
    "appointement": "appointment",
    "appoitment": "appointment",
    "becuase": "because",
    "calender": "calendar",
    "colect": "collect",
    "medecine": "medicine",
    "nursary": "nursery",
    "nursey": "nursery",
    "payement": "payment",
    "presciption": "prescription",
    "recieve": "receive",
    "remeber": "remember",
    "rember": "remember",
    "spoecialist": "specialist",
    "tommorow": "tomorrow",
    "tomorow": "tomorrow",
    "tuesay": "Tuesday",
    "wedensday": "Wednesday",
}
_OBVIOUS_TYPO_PATTERN = re.compile(
    rf"\b(?:{'|'.join(re.escape(word) for word in _OBVIOUS_TYPO_CORRECTIONS)})\b",
    flags=re.IGNORECASE,
)


def parse_reference_datetime(value: str | None) -> datetime:
    if value:
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return datetime.now(timezone.utc)


def reference_in_timezone(value: str | None, timezone_name: str | None) -> datetime:
    reference = parse_reference_datetime(value)
    if not timezone_name:
        return reference
    try:
        return reference.astimezone(ZoneInfo(timezone_name))
    except (ValueError, ZoneInfoNotFoundError):
        return reference


def _capture_lines(text: str) -> list[str]:
    return [
        part.strip(" \t-\u2022")
        for part in re.split(r"[\n;]+|(?<=[.!?])\s+", text)
        if part.strip(" \t-\u2022")
    ][:20]


def _correct_obvious_typos(value: str) -> str:
    """Fix a deliberately small set of unambiguous typos without touching names."""

    def replacement(match: re.Match[str]) -> str:
        original = match.group(0)
        corrected = _OBVIOUS_TYPO_CORRECTIONS[original.lower()]
        if original.isupper():
            return corrected.upper()
        if original[0].isupper():
            return corrected[0].upper() + corrected[1:]
        return corrected.lower()

    return _OBVIOUS_TYPO_PATTERN.sub(replacement, value)


def _calendar_date(line: str, reference: datetime) -> date | None:
    lower = line.lower()
    if "tomorrow" in lower:
        return reference.date() + timedelta(days=1)
    if re.search(r"\btoday\b", lower):
        return reference.date()

    iso_match = re.search(r"\b(20\d{2})-(\d{1,2})-(\d{1,2})\b", lower)
    if iso_match:
        try:
            return date(*(int(value) for value in iso_match.groups()))
        except ValueError:
            return None

    numeric_match = re.search(r"\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b", lower)
    if numeric_match:
        day, month = int(numeric_match.group(1)), int(numeric_match.group(2))
        raw_year = numeric_match.group(3)
        year = int(raw_year) if raw_year else reference.year
        if year < 100:
            year += 2000
        try:
            candidate = date(year, month, day)
            if not raw_year and candidate < reference.date() - timedelta(days=1):
                candidate = date(year + 1, month, day)
            return candidate
        except ValueError:
            return None

    month_match = re.search(
        r"\b(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]{3,9})(?:\s+(20\d{2}))?\b",
        lower,
    )
    if month_match and month_match.group(2) in _MONTHS:
        year = int(month_match.group(3) or reference.year)
        try:
            candidate = date(year, _MONTHS[month_match.group(2)], int(month_match.group(1)))
            if not month_match.group(3) and candidate < reference.date() - timedelta(days=1):
                candidate = date(year + 1, candidate.month, candidate.day)
            return candidate
        except ValueError:
            return None

    weekday_match = re.search(
        r"\b(next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b",
        lower,
    )
    if weekday_match:
        target = _WEEKDAYS[weekday_match.group(2)]
        days = (target - reference.weekday()) % 7
        if days == 0:
            days = 7
        if weekday_match.group(1) and days < 7:
            days += 7
        return reference.date() + timedelta(days=days)
    return None


def _clock_time(line: str) -> time | None:
    lower = line.lower()
    match = re.search(r"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", lower)
    if not match:
        match = re.search(r"\b(?:at\s+)?([01]?\d|2[0-3]):([0-5]\d)\b", lower)
    if not match:
        return None
    hour = int(match.group(1))
    minute = int(match.group(2) or 0)
    marker = match.group(3) if match.lastindex and match.lastindex >= 3 else None
    if marker:
        hour %= 12
        if marker == "pm":
            hour += 12
    try:
        return time(hour, minute)
    except ValueError:
        return None


def _assignee(line: str, people: list[dict[str, str]]) -> str | None:
    lower = line.lower()
    for person in sorted(people, key=lambda item: len(item.get("name", "")), reverse=True):
        name = person.get("name", "").strip().lower()
        if name and re.search(rf"(?<!\w){re.escape(name)}(?!\w)", lower):
            return person.get("id")
    return None


def _title(line: str) -> str:
    value = re.sub(
        r"^(?:please\s+|remember(?:\s+to)?\s+|remind\s+me\s+to\s+|add\s+)",
        "",
        line.strip(),
        flags=re.IGNORECASE,
    ).strip(" .")
    if value:
        value = value[0].upper() + value[1:]
    return value[:300] or "Captured item"


def fallback_capture_suggestions(
    text: str,
    *,
    people: list[dict[str, str]],
    reference: datetime,
) -> list[CaptureSuggestionCreate]:
    """Return conservative proposals when private AI parsing is unavailable."""
    suggestions: list[CaptureSuggestionCreate] = []
    for source_line in _capture_lines(text):
        line = _correct_obvious_typos(source_line)
        captured_date = _calendar_date(line, reference)
        captured_time = _clock_time(line)
        lower = line.lower()
        is_task = any(word in lower for word in _TASK_WORDS)
        assigned_to = _assignee(line, people)
        title = _title(line)

        if captured_date and not is_task:
            if captured_time:
                start = datetime.combine(captured_date, captured_time, tzinfo=reference.tzinfo)
                start_value = start.isoformat()
                all_day = False
            else:
                start_value = captured_date.isoformat()
                all_day = True
            suggestions.append(
                CaptureSuggestionCreate(
                    kind="event",
                    title=title,
                    start_time=start_value,
                    all_day=all_day,
                    assigned_to=assigned_to,
                    confidence=0.62,
                    source_text=source_line[:2_000],
                )
            )
        else:
            due_date = None
            if captured_date:
                if captured_time:
                    due_date = datetime.combine(
                        captured_date,
                        captured_time,
                        tzinfo=reference.tzinfo,
                    ).isoformat()
                else:
                    due_date = captured_date.isoformat()
            suggestions.append(
                CaptureSuggestionCreate(
                    kind="task",
                    title=title,
                    due_date=due_date,
                    assigned_to=assigned_to,
                    confidence=0.48 if not is_task else 0.6,
                    source_text=source_line[:2_000],
                )
            )
    return suggestions[:20]
