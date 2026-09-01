"""Term date auto-scraper service.

Fetches term dates from school websites, parses them with regex, and updates
the term_dates table. Falls back to generating a Claude prompt when regex
parsing fails.
"""

import asyncio
import html
import logging
import re
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import Any
from urllib.parse import urljoin, urlsplit

import httpx

from app.database import database_lease
from app.services.record_history import save_history
from app.services.term_calendar import reconcile_term_boundary_events

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Month helpers
# ---------------------------------------------------------------------------

_MONTH_MAP: dict[str, int] = {
    "january": 1,
    "jan": 1,
    "february": 2,
    "feb": 2,
    "march": 3,
    "mar": 3,
    "april": 4,
    "apr": 4,
    "may": 5,
    "june": 6,
    "jun": 6,
    "july": 7,
    "jul": 7,
    "august": 8,
    "aug": 8,
    "september": 9,
    "sep": 9,
    "sept": 9,
    "october": 10,
    "oct": 10,
    "november": 11,
    "nov": 11,
    "december": 12,
    "dec": 12,
}

_MONTH_PATTERN = "|".join(_MONTH_MAP.keys())


def _month_num(name: str) -> int:
    """Convert month name or abbreviation to number."""
    return _MONTH_MAP[name.lower().strip(".")]


def _parse_date(day: str, month_str: str, year: str | int) -> str:
    """Build YYYY-MM-DD from components."""
    return date(int(year), _month_num(month_str), int(day)).isoformat()


def _academic_year_start(value: date) -> int:
    """Return the starting calendar year for the academic year containing value."""
    return value.year if value.month >= 8 else value.year - 1


def _target_academic_year_starts(reference_date: date | None = None) -> set[int]:
    """Return the current and following academic-year start years."""
    current_start = _academic_year_start(reference_date or date.today())
    return {current_start, current_start + 1}


def _target_academic_date_bounds(
    reference_date: date | None = None,
) -> tuple[date, date]:
    """Inclusive bounds spanning the current and following academic years."""
    first_year = min(_target_academic_year_starts(reference_date))
    return date(first_year, 8, 1), date(first_year + 2, 7, 31)


def _date_is_in_target_academic_years(
    value: date,
    reference_date: date | None = None,
) -> bool:
    """Whether value falls in the complete current-or-next academic year."""
    return _academic_year_start(value) in _target_academic_year_starts(reference_date)


def _calendar_years_for_target_academic_years(
    reference_date: date | None = None,
) -> set[int]:
    """Calendar years needed to infer yearless dates in the target window."""
    starts = _target_academic_year_starts(reference_date)
    return starts | {year + 1 for year in starts}


def _complete_academic_years(
    terms: list[dict[str, str]],
    expected_terms_per_season: int = 1,
) -> set[int]:
    """Return AY starts for which autumn, spring, and summer are all present."""
    counts_by_year: dict[int, dict[str, int]] = {}
    for term in terms:
        try:
            start = date.fromisoformat(term["start_date"])
        except (KeyError, ValueError):
            continue
        if start.month >= 8:
            season = "autumn"
        elif start.month <= 3:
            season = "spring"
        else:
            season = "summer"
        season_counts = counts_by_year.setdefault(_academic_year_start(start), {})
        season_counts[season] = season_counts.get(season, 0) + 1
    return {
        academic_year
        for academic_year, counts in counts_by_year.items()
        if all(
            counts.get(season, 0) >= expected_terms_per_season
            for season in ("autumn", "spring", "summer")
        )
    }


def _normalise_scraped_text(text: str) -> str:
    """Clean common PDF/OCR artefacts without changing line ordering."""
    normalised = html.unescape(text).replace("\u00a0", " ").replace("\u200b", "")
    # Jina's PDF OCR occasionally splits a number into chunks ("202 6", "2 3rd").
    normalised = re.sub(r"(?<=\d)[ \t]+(?=\d)", "", normalised)
    # The same OCR can split ordinals and month names ("12 th", "Septem ber").
    normalised = re.sub(r"(?<=\d)[ \t]+(?=st\b|nd\b|rd\b|th\b)", "", normalised, flags=re.I)
    for month_name in _MONTH_MAP:
        flexible_month = r"[ \t]*".join(re.escape(character) for character in month_name)
        normalised = re.sub(
            rf"\b{flexible_month}\b",
            month_name,
            normalised,
            flags=re.IGNORECASE,
        )
    for weekday in (
        "monday",
        "tuesday",
        "wednesday",
        "thursday",
        "friday",
        "saturday",
        "sunday",
    ):
        flexible_weekday = r"[ \t]*".join(re.escape(character) for character in weekday)
        normalised = re.sub(
            rf"\b{flexible_weekday}\b",
            weekday,
            normalised,
            flags=re.IGNORECASE,
        )
    return normalised


# ---------------------------------------------------------------------------
# School configuration
# ---------------------------------------------------------------------------


@dataclass
class SchoolConfig:
    """Configuration for a single school's term scraping."""

    known_url: str | None
    person_ids: list[str]
    search_query: str
    is_master: bool = False
    needs_jina: bool = False
    linked_document_hosts: tuple[str, ...] = ()
    person_term_windows: dict[str, tuple[str | None, str | None]] | None = None
    expected_terms_per_season: int = 1


SCHOOL_CONFIG: dict[str, SchoolConfig] = {
    "school_college": SchoolConfig(
        known_url="https://school.example.invalid/news-and-diary/term-dates/",
        person_ids=["00000000-0000-0000-0000-000000000001"],
        is_master=True,
        needs_jina=True,
        search_query="Example School College term dates",
    ),
    "example_secondary": SchoolConfig(
        known_url="https://secondary.example.invalid/parent-information/term-dates",
        person_ids=["00000000-0000-0000-0000-000000000002"],
        needs_jina=True,
        linked_document_hosts=("secondary.example.invalid",),
        search_query="Example Secondary School term dates",
    ),
    "primary_school": SchoolConfig(
        known_url="https://primary-school.example.invalid/parent-information/term-dates",
        person_ids=[
            "00000000-0000-0000-0000-000000000011",
            "00000000-0000-0000-0000-000000000012",
        ],
        needs_jina=True,
        linked_document_hosts=("resources.finalsite.net",),
        person_term_windows={
            # Reception has a phased start: Child Two's Group 2 first morning is
            # 9 September, not the school-wide beginning of term.
            "00000000-0000-0000-0000-000000000012": ("2026-09-09", None),
        },
        expected_terms_per_season=2,
        search_query="Example Primary School school term dates",
    ),
    "school_preschool": SchoolConfig(
        known_url="https://preschool.example.invalid/term-dates",
        person_ids=[
            "00000000-0000-0000-0000-000000000012",
            "00000000-0000-0000-0000-000000000013",
        ],
        needs_jina=True,
        person_term_windows={
            "00000000-0000-0000-0000-000000000012": (None, "2026-08-31"),
            # Child Three is with Example Childminder until starting preschool in January 2027.
            "00000000-0000-0000-0000-000000000013": ("2027-01-05", None),
        },
        search_query="Example School Preschool term dates",
    ),
}


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

_HTTP_TIMEOUT = 30.0
_MAX_RESPONSE_BYTES = 5 * 1024 * 1024
_JINA_READ_PREFIX = "https://r.jina.ai/"
_JINA_SEARCH_PREFIX = "https://s.jina.ai/"


async def _fetch_bounded_text(target: str, *, operation: str) -> str:
    """Fetch UTF-8-ish text while enforcing a decompressed response-size cap."""
    try:
        async with asyncio.timeout(_HTTP_TIMEOUT):
            async with httpx.AsyncClient(
                timeout=_HTTP_TIMEOUT,
                follow_redirects=True,
                headers={"User-Agent": "HausKlar-TermScraper/1.0"},
            ) as client:
                async with client.stream("GET", target) as response:
                    response.raise_for_status()
                    content_length = response.headers.get("content-length")
                    if content_length and int(content_length) > _MAX_RESPONSE_BYTES:
                        logger.warning("%s exceeded response-size limit: %s", operation, target)
                        return ""
                    body = bytearray()
                    async for chunk in response.aiter_bytes():
                        if len(body) + len(chunk) > _MAX_RESPONSE_BYTES:
                            logger.warning(
                                "%s exceeded response-size limit: %s",
                                operation,
                                target,
                            )
                            return ""
                        body.extend(chunk)
                    encoding = response.encoding or "utf-8"
        return bytes(body).decode(encoding, errors="replace")
    except TimeoutError:
        logger.warning("%s exceeded wall-clock timeout: %s", operation, target)
        return ""
    except (TypeError, ValueError) as exc:
        logger.warning("%s returned invalid response metadata for %s: %s", operation, target, exc)
        return ""
    except httpx.HTTPError as exc:
        logger.warning("%s failed for %s: %s", operation, target, exc)
        return ""
    except Exception as exc:
        logger.error("Unexpected error during %s for %s: %s", operation, target, exc)
        return ""


async def fetch_page(url: str, use_jina: bool = False) -> str:
    """Fetch a URL directly or via Jina Reader.

    Args:
        url: The page URL to fetch.
        use_jina: If True, route through Jina Reader for JS-rendered pages.

    Returns:
        The page text content, or an empty string on failure.
    """
    target = f"{_JINA_READ_PREFIX}{url}" if use_jina else url
    return await _fetch_bounded_text(target, operation="Term page fetch")


async def search_google_via_jina(query: str) -> str:
    """Search Google via Jina Search and return the text result.

    Args:
        query: The search query string.

    Returns:
        The search result text, or an empty string on failure.
    """
    target = f"{_JINA_SEARCH_PREFIX}{query}"
    return await _fetch_bounded_text(target, operation="Jina term search")


_MARKDOWN_LINK_PATTERN = re.compile(
    r"\[([^\]]*)\]\(([^)\s]+)(?:\s+['\"][^)]*['\"])?\)",
    re.IGNORECASE,
)
_HTML_LINK_PATTERN = re.compile(
    r"<a\b[^>]*\bhref\s*=\s*['\"]([^'\"]+)['\"][^>]*>(.*?)</a>",
    re.IGNORECASE | re.DOTALL,
)
_RAW_PDF_URL_PATTERN = re.compile(r"https://[^\s)<>'\"]+\.pdf(?:\?[^\s)<>'\"]*)?", re.I)


def _extract_linked_term_documents(
    text: str,
    *,
    base_url: str,
    allowed_hosts: tuple[str, ...],
) -> list[str]:
    """Extract allowlisted official term-date PDFs linked from a school page."""
    if not allowed_hosts:
        return []

    candidates: list[tuple[str, str]] = []
    for match in _MARKDOWN_LINK_PATTERN.finditer(text):
        candidates.append((match.group(2), match.group(1)))
    for match in _HTML_LINK_PATTERN.finditer(text):
        candidates.append((match.group(1), re.sub(r"<[^>]+>", " ", match.group(2))))
    candidates.extend((match.group(0), "") for match in _RAW_PDF_URL_PATTERN.finditer(text))

    links: list[str] = []
    seen: set[str] = set()
    seen_filenames: set[str] = set()
    for raw_url, label in candidates:
        url = urljoin(base_url, html.unescape(raw_url).strip())
        parsed = urlsplit(url)
        host = (parsed.hostname or "").lower()
        allowed = any(
            host == allowed_host or host.endswith(f".{allowed_host}")
            for allowed_host in allowed_hosts
        )
        label_text = label.lower()
        path_text = parsed.path.lower()
        filename = parsed.path.rsplit("/", 1)[-1].lower()
        looks_like_term_dates = "term" in path_text or (
            "term" in label_text and "date" in label_text
        )
        if (
            parsed.scheme != "https"
            or not allowed
            or not parsed.path.lower().endswith(".pdf")
            or not looks_like_term_dates
            or url in seen
            or filename in seen_filenames
        ):
            continue
        seen.add(url)
        seen_filenames.add(filename)
        links.append(url)

    # Bound quarterly background work even if an upstream page becomes noisy.
    return links[:6]


# ---------------------------------------------------------------------------
# Parsing — Example School College specific
# ---------------------------------------------------------------------------

# Example School uses "halves" not terms: Michaelmas, Lent, Summer.
# Training Days mark the start because Alex works those days.

_SCHOOL_HALF_HEADER = re.compile(
    r"(Michaelmas|Lent|Summer)(?:\s+(?:Half|Term))?\s+(\d{4})",
    re.IGNORECASE,
)

_WEEKDAY_PATTERN = (
    r"(?:Mon(?:day)?|Tue(?:s(?:day)?)?|Wed(?:s|nesday)?|"
    r"Thu(?:r(?:s(?:day)?)?)?|"
    r"Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?)"
)
_DATE_DASH_PATTERN = r"(?:-|\u2010|\u2011|\u2012|\u2013|\u2014|to)"
_ORDINAL_PATTERN = r"(?:st|nd|rd|th)?"

_SCHOOL_TRAINING_PATTERNS = (
    re.compile(
        rf"Training\s+Days?(?:\s+for\s+Masters)?\s*:?\s*"
        rf"(?:{_WEEKDAY_PATTERN}\s+)?"
        rf"(?P<day>\d{{1,2}}){_ORDINAL_PATTERN}\s+"
        rf"(?P<month>{_MONTH_PATTERN})(?:\s+(?P<year>\d{{4}}))?",
        re.IGNORECASE,
    ),
    re.compile(
        rf"{_WEEKDAY_PATTERN}\s+(?P<day>\d{{1,2}}){_ORDINAL_PATTERN}\s*"
        rf"(?:{_DATE_DASH_PATTERN}\s*{_WEEKDAY_PATTERN}\s+"
        rf"\d{{1,2}}{_ORDINAL_PATTERN}\s+)?"
        rf"(?P<month>{_MONTH_PATTERN})(?:\s+(?P<year>\d{{4}}))?\s+"
        rf"Training\s+Days?(?:\s+for\s+Masters)?",
        re.IGNORECASE,
    ),
)

_SCHOOL_END_PATTERNS = (
    re.compile(
        rf"End\s+of\s+Half\s*:?\s*(?:{_WEEKDAY_PATTERN}\s+)?"
        rf"(?P<day>\d{{1,2}}){_ORDINAL_PATTERN}\s+"
        rf"(?P<month>{_MONTH_PATTERN})(?:\s+(?P<year>\d{{4}}))?",
        re.IGNORECASE,
    ),
    re.compile(
        rf"(?:{_WEEKDAY_PATTERN}\s+)?(?P<day>\d{{1,2}}){_ORDINAL_PATTERN}\s+"
        rf"(?P<month>{_MONTH_PATTERN})(?:\s+(?P<year>\d{{4}}))?\s+"
        rf"End\s+of\s+Half",
        re.IGNORECASE,
    ),
)


def _first_named_match(
    patterns: tuple[re.Pattern[str], ...],
    text: str,
) -> re.Match[str] | None:
    """Return the earliest match from a set of source-format patterns."""
    matches = [match for pattern in patterns if (match := pattern.search(text))]
    return min(matches, key=lambda match: match.start()) if matches else None


def _parse_example_school_college(
    text: str,
    reference_date: date | None = None,
) -> list[dict[str, str]]:
    """Parse Example School College term dates from page text.

    Looks for half names (Michaelmas/Lent/Summer), training day starts, and
    end-of-half dates. Training day = Alex's first working day of term.

    Returns:
        List of dicts with keys: label, start_date, end_date.
    """
    terms: list[dict[str, str]] = []

    try:
        text = _normalise_scraped_text(text)
        target_years = _calendar_years_for_target_academic_years(reference_date)

        # Split text into sections by half headers
        sections: list[tuple[str, int, int]] = []
        for m in _SCHOOL_HALF_HEADER.finditer(text):
            year = int(m.group(2))
            half_name = m.group(1).title()
            sections.append((half_name, year, m.start()))

        if not sections:
            # Try without explicit year headers — parse all dates linearly
            return _parse_example_school_linear(text, target_years, reference_date)

        # For each section, find training day and end-of-half
        for i, (half_name, section_year, start_pos) in enumerate(sections):
            end_pos = sections[i + 1][2] if i + 1 < len(sections) else len(text)
            section_text = text[start_pos:end_pos]

            training = _first_named_match(_SCHOOL_TRAINING_PATTERNS, section_text)
            end_half = _first_named_match(_SCHOOL_END_PATTERNS, section_text)

            if training and end_half:
                t_year = int(training.group("year") or section_year)
                e_year = int(end_half.group("year") or section_year)
                try:
                    start_date = _parse_date(training.group("day"), training.group("month"), t_year)
                    end_date = _parse_date(end_half.group("day"), end_half.group("month"), e_year)
                    parsed_start = date.fromisoformat(start_date)
                    if not _date_is_in_target_academic_years(
                        parsed_start,
                        reference_date,
                    ):
                        continue
                    terms.append(
                        {
                            "label": f"{half_name} Half {section_year}",
                            "start_date": start_date,
                            "end_date": end_date,
                        }
                    )
                except (ValueError, KeyError) as exc:
                    logger.warning(
                        "Failed to parse Example School dates in '%s Half %d': %s",
                        half_name,
                        section_year,
                        exc,
                    )

    except Exception as exc:
        logger.error("Example School College parser error: %s", exc)

    return terms


def _parse_example_school_linear(
    text: str,
    target_years: set[int],
    reference_date: date | None = None,
) -> list[dict[str, str]]:
    """Fallback Example School parser: pair consecutive training-day/end-of-half dates."""
    terms: list[dict[str, str]] = []

    try:
        training_days = sorted(
            (match for pattern in _SCHOOL_TRAINING_PATTERNS for match in pattern.finditer(text)),
            key=lambda match: match.start(),
        )
        end_halves = sorted(
            (match for pattern in _SCHOOL_END_PATTERNS for match in pattern.finditer(text)),
            key=lambda match: match.start(),
        )

        # Pair them up in order
        for td, eh in zip(training_days, end_halves):
            # Guess year from context — use the first 4-digit number nearby
            t_year_str = td.group("year")
            e_year_str = eh.group("year")

            if not t_year_str or not e_year_str:
                # Try to find year from surrounding text
                for y in sorted(target_years):
                    t_year_str = t_year_str or str(y)
                    e_year_str = e_year_str or str(y)
                    break

            if not t_year_str or not e_year_str:
                continue

            t_year = int(t_year_str)
            e_year = int(e_year_str)

            try:
                start_date = _parse_date(td.group("day"), td.group("month"), t_year)
                end_date = _parse_date(eh.group("day"), eh.group("month"), e_year)

                # Determine a label from position
                sd = date.fromisoformat(start_date)
                if not _date_is_in_target_academic_years(sd, reference_date):
                    continue
                if sd.month in (8, 9, 10, 11):
                    label = f"Michaelmas Half {sd.year}"
                elif sd.month in (1, 2, 3):
                    label = f"Lent Half {sd.year}"
                else:
                    label = f"Summer Half {sd.year}"

                terms.append(
                    {
                        "label": label,
                        "start_date": start_date,
                        "end_date": end_date,
                    }
                )
            except (ValueError, KeyError) as exc:
                logger.warning("Example School linear parse failed: %s", exc)

    except Exception as exc:
        logger.error("Example School linear parser error: %s", exc)

    return terms


# ---------------------------------------------------------------------------
# Parsing — Generic UK school terms
# ---------------------------------------------------------------------------

# Pattern: "Spring Term: 6 January - 28 March 2026"
_TERM_RANGE_PATTERN = re.compile(
    r"(Autumn|Spring|Summer|Michaelmas|Lent|Trinity)\s*"
    r"(?:Term|Half)?\s*"
    r"[:\-\u2013\u2014]?\s*"
    r"(\d{1,2})(?:st|nd|rd|th)?\s+(" + _MONTH_PATTERN + r")\s*"
    r"(?:\-|\u2010|\u2011|\u2012|\u2013|\u2014|to)\s*"
    r"(\d{1,2})(?:st|nd|rd|th)?\s+(" + _MONTH_PATTERN + r")\s+(\d{4})",
    re.IGNORECASE,
)

# Patterns include source variants such as "Term commences Thursday ..." and
# OCR output such as "Term starts on: Thursday 3rd September 2026".
_TERM_STARTS_PATTERN = re.compile(
    rf"(?:Term|Half\s+Term)\s+"
    rf"(?:starts?(?:\s+on)?|commences?|begins?)\s*:?\s*"
    rf"(?:{_WEEKDAY_PATTERN}\s+)?"
    rf"(\d{{1,2}}){_ORDINAL_PATTERN}\s+({_MONTH_PATTERN})"
    rf"(?:\s+(\d{{4}}))?",
    re.IGNORECASE,
)

_TERM_ENDS_PATTERN = re.compile(
    rf"(?:Term|Half\s+Term)\s+ends?(?:\s+on)?\s*:?\s*"
    rf"(?:{_WEEKDAY_PATTERN}\s+)?"
    rf"(\d{{1,2}}){_ORDINAL_PATTERN}\s+({_MONTH_PATTERN})"
    rf"(?:\s+(\d{{4}}))?",
    re.IGNORECASE,
)

_TERM_NAME_PATTERN = re.compile(
    r"(Autumn|Spring|Summer|Michaelmas|Lent|Trinity)\s*(?:Term|Half)?"
    r"(?:\s+(\d{4}))?",
    re.IGNORECASE,
)
_ACADEMIC_YEAR_PATTERN = re.compile(
    r"(?:Academic\s+Year|Term\s+Dates)\D{0,16}(\d{4})\s*[/\-]\s*(\d{2,4})",
    re.IGNORECASE,
)
_TERM_SEGMENT_PATTERN = re.compile(r"\bTerm\s+([1-6])\b", re.IGNORECASE)


def _last_match_before(
    matches: list[re.Match[str]],
    position: int,
    *,
    max_distance: int = 1500,
) -> re.Match[str] | None:
    """Return the closest preceding contextual match within a bounded section."""
    candidates = [
        match
        for match in matches
        if match.start() <= position and position - match.start() <= max_distance
    ]
    return max(candidates, key=lambda match: match.start()) if candidates else None


def _year_from_academic_header(match: re.Match[str], month: int) -> int:
    """Infer a calendar year from a 2026/27-style academic-year heading."""
    start_year = int(match.group(1))
    end_token = match.group(2)
    end_year = int(end_token)
    if len(end_token) == 2:
        end_year += (start_year // 100) * 100
    return start_year if month >= 8 else end_year


def _contextual_year(
    *,
    explicit_year: str | None,
    month: int,
    term_header: re.Match[str] | None,
    academic_header: re.Match[str] | None,
) -> int | None:
    """Resolve a possibly omitted year using the nearest source heading."""
    if explicit_year:
        return int(explicit_year)
    if term_header and term_header.group(2):
        return int(term_header.group(2))
    if academic_header:
        return _year_from_academic_header(academic_header, month)
    return None


def _parse_generic_uk_terms(
    text: str,
    reference_date: date | None = None,
) -> list[dict[str, str]]:
    """Parse generic UK school term dates from page text.

    Handles common patterns like:
      - "Spring Term: 6 January - 28 March 2026"
      - "Term starts: Monday 6 January" / "Term ends: Friday 28 March"
      - Standalone date ranges near term name headers

    Tries to extract the current/next academic year.

    Returns:
        List of dicts with keys: label, start_date, end_date.
    """
    terms: list[dict[str, str]] = []

    try:
        text = _normalise_scraped_text(text)

        # Strategy 1: Full range patterns like "Spring Term: 6 Jan - 28 Mar 2026"
        for m in _TERM_RANGE_PATTERN.finditer(text):
            year = int(m.group(6))
            try:
                # Start month might be in previous year for Autumn
                start_month = _month_num(m.group(3))
                end_month = _month_num(m.group(5))
                start_year = year if start_month <= end_month else year - 1
                start_date = _parse_date(m.group(2), m.group(3), start_year)
                end_date = _parse_date(m.group(4), m.group(5), year)
                parsed_start = date.fromisoformat(start_date)
                if not _date_is_in_target_academic_years(
                    parsed_start,
                    reference_date,
                ):
                    continue
                terms.append(
                    {
                        "label": f"{m.group(1).title()} Term {start_year}",
                        "start_date": start_date,
                        "end_date": end_date,
                    }
                )
            except (ValueError, KeyError) as exc:
                logger.warning("Generic range parse failed: %s", exc)

        # Strategy 2: Pair "Term starts" with "Term ends"
        starts = list(_TERM_STARTS_PATTERN.finditer(text))
        ends = list(_TERM_ENDS_PATTERN.finditer(text))
        term_headers = list(_TERM_NAME_PATTERN.finditer(text))
        academic_headers = list(_ACADEMIC_YEAR_PATTERN.finditer(text))
        segment_headers = list(_TERM_SEGMENT_PATTERN.finditer(text))

        if starts and ends:
            for index, s_match in enumerate(starts):
                next_start = starts[index + 1].start() if index + 1 < len(starts) else len(text)
                term_header = _last_match_before(term_headers, s_match.start())
                academic_header = _last_match_before(
                    academic_headers,
                    s_match.start(),
                    max_distance=5000,
                )
                start_month = _month_num(s_match.group(2))
                s_year = _contextual_year(
                    explicit_year=s_match.group(3),
                    month=start_month,
                    term_header=term_header,
                    academic_header=academic_header,
                )
                if s_year is None:
                    continue
                try:
                    start_date = _parse_date(s_match.group(1), s_match.group(2), s_year)
                except (ValueError, KeyError):
                    continue

                end_match = next(
                    (
                        candidate
                        for candidate in ends
                        if s_match.end() <= candidate.start() < next_start
                    ),
                    None,
                )
                if end_match is None:
                    continue

                end_month = _month_num(end_match.group(2))
                e_year = _contextual_year(
                    explicit_year=end_match.group(3),
                    month=end_month,
                    term_header=term_header,
                    academic_header=academic_header,
                )
                if e_year is None:
                    e_year = s_year + (1 if end_month < start_month else 0)
                try:
                    end_date = _parse_date(
                        end_match.group(1),
                        end_match.group(2),
                        e_year,
                    )
                except (ValueError, KeyError) as exc:
                    logger.warning("Generic term-end parse failed: %s", exc)
                    continue

                parsed_start = date.fromisoformat(start_date)
                parsed_end = date.fromisoformat(end_date)
                duration = (parsed_end - parsed_start).days
                if (
                    not _date_is_in_target_academic_years(
                        parsed_start,
                        reference_date,
                    )
                    or duration < 0
                    or duration > 200
                ):
                    continue

                season = (
                    term_header.group(1).title() if term_header else _guess_term_name(parsed_start)
                )
                segment = _last_match_before(
                    segment_headers,
                    s_match.start(),
                    max_distance=500,
                )
                segment_suffix = f" {segment.group(1)}" if segment else ""
                terms.append(
                    {
                        "label": f"{season} Term{segment_suffix} {s_year}",
                        "start_date": start_date,
                        "end_date": end_date,
                    }
                )

    except Exception as exc:
        logger.error("Generic UK term parser error: %s", exc)

    return _deduplicate_terms(terms)


def _guess_term_name(start: date) -> str:
    """Guess the UK term season from a start date."""
    if start.month >= 8:
        return "Autumn"
    if start.month <= 3:
        return "Spring"
    return "Summer"


def _deduplicate_terms(terms: list[dict[str, str]]) -> list[dict[str, str]]:
    """Validate, order, and remove duplicate date intervals."""
    seen: set[tuple[str, str]] = set()
    result: list[dict[str, str]] = []
    for term in sorted(
        terms,
        key=lambda item: (item["start_date"], item["end_date"], item["label"]),
    ):
        try:
            start = date.fromisoformat(term["start_date"])
            end = date.fromisoformat(term["end_date"])
        except (KeyError, ValueError):
            continue
        if end < start:
            continue
        key = (term["start_date"], term["end_date"])
        if key not in seen:
            seen.add(key)
            result.append(term)
    return result


# ---------------------------------------------------------------------------
# Claude prompt fallback
# ---------------------------------------------------------------------------


def generate_claude_prompt(school_name: str, raw_text: str) -> str:
    """Generate a prompt for Claude to extract term dates from raw text.

    Used as a fallback when regex parsing fails. The prompt instructs Claude
    to return structured JSON that can be directly inserted into the database.

    Args:
        school_name: Human-readable school name for context.
        raw_text: The raw page text (possibly messy HTML/markdown).

    Returns:
        A complete prompt string ready to send to Claude.
    """
    # Truncate very long text to avoid token limits
    truncated = raw_text[:15000] if len(raw_text) > 15000 else raw_text

    return f"""Extract school term dates from the following text for {school_name}.

I need the term start and end dates for the current and/or next academic year.
For each term, provide a label (e.g. "Autumn Term 2025", "Spring Term 2026"),
the start date, and the end date.

IMPORTANT:
- Use YYYY-MM-DD format for all dates.
- The start date should be the first day pupils/staff are expected in school
  (including training days if mentioned).
- The end date should be the last day of term.
- Only include main terms, not half-term holidays.
- If the text covers multiple academic years, prefer the current/upcoming one.

Return ONLY a JSON array in this exact format, with no other text:
[
  {{"label": "Autumn Term 2025", "start_date": "2025-09-03", "end_date": "2025-12-12"}},
  {{"label": "Spring Term 2026", "start_date": "2026-01-06", "end_date": "2026-03-27"}},
  {{"label": "Summer Term 2026", "start_date": "2026-04-21", "end_date": "2026-07-10"}}
]

Here is the text to extract from:

---
{truncated}
---"""


# ---------------------------------------------------------------------------
# Database update
# ---------------------------------------------------------------------------

_SCRAPER_CREATED_BY = "term-scraper"


async def _configured_people_for_family(
    db: Any,
    person_ids: list[str],
    family_id: str | None,
) -> list[str]:
    if family_id is None:
        return person_ids
    if not person_ids:
        return []
    placeholders = ",".join("?" for _ in person_ids)
    cursor = await db.execute(
        f"""
        SELECT id FROM users
        WHERE family_id = ? AND deleted_at IS NULL AND id IN ({placeholders})
        UNION ALL
        SELECT id FROM children
        WHERE family_id = ? AND deleted_at IS NULL AND id IN ({placeholders})
        """,
        (family_id, *person_ids, family_id, *person_ids),
    )
    valid = {row[0] for row in await cursor.fetchall()}
    return [person_id for person_id in person_ids if person_id in valid]


def _terms_for_person(
    config: SchoolConfig,
    person_id: str,
    terms: list[dict[str, str]],
) -> list[dict[str, str]]:
    """Apply an effective-dated school assignment to parsed term intervals."""
    window = (config.person_term_windows or {}).get(person_id)
    if not window:
        return _deduplicate_terms(terms)

    effective_from = date.fromisoformat(window[0]) if window[0] else None
    effective_until = date.fromisoformat(window[1]) if window[1] else None
    assigned: list[dict[str, str]] = []
    for term in terms:
        try:
            term_start = date.fromisoformat(term["start_date"])
            term_end = date.fromisoformat(term["end_date"])
        except (KeyError, ValueError):
            continue
        clipped_start = max(term_start, effective_from) if effective_from else term_start
        clipped_end = min(term_end, effective_until) if effective_until else term_end
        if clipped_end < clipped_start:
            continue
        assigned.append(
            {
                **term,
                "start_date": clipped_start.isoformat(),
                "end_date": clipped_end.isoformat(),
            }
        )
    return _deduplicate_terms(assigned)


def _assignment_overlaps_target_years(
    config: SchoolConfig,
    person_id: str,
    reference_date: date | None,
) -> bool:
    """Whether a school assignment is relevant to this two-AY refresh window."""
    window = (config.person_term_windows or {}).get(person_id)
    if not window:
        return True
    target_start, target_end = _target_academic_date_bounds(reference_date)
    relevance_start = max(target_start, reference_date or date.today())
    effective_from = date.fromisoformat(window[0]) if window[0] else date.min
    effective_until = date.fromisoformat(window[1]) if window[1] else date.max
    return effective_from <= target_end and effective_until >= relevance_start


async def _replace_person_term_dates(
    db: Any,
    *,
    person_id: str,
    terms: list[dict[str, str]],
    family_id: str | None,
    now: str,
    replace_academic_years: set[int],
) -> int:
    """Reconcile one person's scraper-owned dates without committing."""
    manual_query = """
        SELECT start_date, end_date FROM term_dates
        WHERE person_id = ?
          AND (created_by IS NULL OR created_by != ? OR user_overridden = 1)
          AND deleted_at IS NULL
    """
    manual_params: list[str] = [person_id, _SCRAPER_CREATED_BY]
    if family_id is not None:
        manual_query += " AND family_id = ?"
        manual_params.append(family_id)
    manual_cursor = await db.execute(manual_query, manual_params)
    manual_ranges: list[tuple[date, date]] = []
    for row in await manual_cursor.fetchall():
        try:
            manual_ranges.append((date.fromisoformat(row[0]), date.fromisoformat(row[1])))
        except (TypeError, ValueError):
            continue

    non_overlapping_terms: list[dict[str, str]] = []
    for term in _deduplicate_terms(terms):
        term_start = date.fromisoformat(term["start_date"])
        term_end = date.fromisoformat(term["end_date"])
        if any(
            term_start <= manual_end and term_end >= manual_start
            for manual_start, manual_end in manual_ranges
        ):
            continue
        non_overlapping_terms.append(term)

    existing_query = """
        SELECT * FROM term_dates
        WHERE person_id = ? AND created_by = ? AND user_overridden = 0
    """
    existing_params: list[str] = [person_id, _SCRAPER_CREATED_BY]
    if family_id is not None:
        existing_query += " AND family_id = ?"
        existing_params.append(family_id)
    existing_cursor = await db.execute(existing_query, existing_params)
    columns = [description[0] for description in existing_cursor.description]
    existing_rows = [
        dict(row) if hasattr(row, "keys") else dict(zip(columns, row, strict=True))
        for row in await existing_cursor.fetchall()
    ]

    async def save_term_history(row: dict[str, Any]) -> None:
        history_family_id = row.get("family_id") or family_id
        if history_family_id:
            await save_history(
                db,
                "term_dates",
                row["id"],
                _SCRAPER_CREATED_BY,
                family_id=history_family_id,
            )

    claimed_ids: set[str] = set()
    initially_active_years: set[int] = set()
    for row in existing_rows:
        if row.get("deleted_at") is not None:
            continue
        try:
            initially_active_years.add(_academic_year_start(date.fromisoformat(row["start_date"])))
        except (TypeError, ValueError):
            continue
    reconciled = 0
    for term in non_overlapping_terms:
        term_academic_year = _academic_year_start(date.fromisoformat(term["start_date"]))
        candidates = [
            row
            for row in existing_rows
            if row["id"] not in claimed_ids
            and row.get("start_date") == term["start_date"]
            and row.get("end_date") == term["end_date"]
        ]
        candidates.sort(
            key=lambda row: (
                row.get("deleted_at") is not None,
                row.get("created_at") or "",
                row["id"],
            )
        )
        existing = candidates[0] if candidates else None
        if existing is not None:
            if (
                existing.get("deleted_at") is not None
                and term_academic_year not in replace_academic_years
                and term_academic_year in initially_active_years
            ):
                continue
            claimed_ids.add(existing["id"])
            reconciled += 1
            if existing.get("deleted_at") is None and existing.get("label") == term["label"]:
                continue
            await save_term_history(existing)
            await db.execute(
                """
                UPDATE term_dates
                SET label = ?, deleted_at = NULL, updated_at = ?
                WHERE id = ?
                """,
                (term["label"], now, existing["id"]),
            )
            continue

        if (
            term_academic_year not in replace_academic_years
            and term_academic_year in initially_active_years
        ):
            # A changed partial result is not authoritative enough to coexist
            # with or replace an already-active snapshot of that academic year.
            continue

        term_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO term_dates
                (id, person_id, label, start_date, end_date,
                 family_id, created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                term_id,
                person_id,
                term["label"],
                term["start_date"],
                term["end_date"],
                family_id,
                now,
                now,
                _SCRAPER_CREATED_BY,
            ),
        )
        claimed_ids.add(term_id)
        reconciled += 1

    for existing in existing_rows:
        if existing["id"] in claimed_ids or existing.get("deleted_at") is not None:
            continue
        try:
            academic_year = _academic_year_start(date.fromisoformat(existing["start_date"]))
        except (TypeError, ValueError):
            continue
        # An incomplete upstream parse must never erase a previously complete AY.
        if academic_year not in replace_academic_years:
            continue
        await save_term_history(existing)
        await db.execute(
            "UPDATE term_dates SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (now, now, existing["id"]),
        )

    return reconciled


async def update_term_dates(
    db: Any,
    school_key: str,
    terms: list[dict[str, str]],
    family_id: str | None = None,
) -> int:
    """Reconcile scraper-created term dates for one school assignment.

    Only touches rows where created_by = 'term-scraper'. Manually created
    entries are never modified.

    Args:
        db: An aiosqlite database connection.
        school_key: The school config key (for logging).
        terms: List of dicts with keys: label, start_date, end_date.
        family_id: The family_id to assign to created term dates.

    Returns:
        Number of desired rows reconciled as active.
    """
    config = SCHOOL_CONFIG.get(school_key)
    if not config:
        logger.error("Unknown school key: %s", school_key)
        return 0

    now = datetime.now(timezone.utc).isoformat()
    reconciled = 0
    person_ids = await _configured_people_for_family(
        db,
        config.person_ids,
        family_id,
    )

    for person_id in person_ids:
        person_terms = _terms_for_person(config, person_id, terms)
        reconciled += await _replace_person_term_dates(
            db,
            person_id=person_id,
            terms=person_terms,
            family_id=family_id,
            now=now,
            replace_academic_years=_complete_academic_years(
                person_terms,
                config.expected_terms_per_season,
            ),
        )

    if person_ids:
        await reconcile_term_boundary_events(
            db,
            family_id=family_id,
            person_ids=None if family_id is not None else person_ids,
            actor_id=_SCRAPER_CREATED_BY,
        )
    await db.commit()
    logger.info(
        "Reconciled %d active term dates for %s",
        reconciled,
        school_key,
    )
    return reconciled


# ---------------------------------------------------------------------------
# Main orchestrator
# ---------------------------------------------------------------------------


async def _fetch_school_text(config: SchoolConfig) -> str:
    """Fetch an authoritative page, never applying untrusted search snippets."""
    if config.known_url:
        return await fetch_page(config.known_url, use_jina=config.needs_jina)

    logger.warning("No official term-date URL configured for %s", config.search_query)
    return ""


def _parse_school_text(
    config: SchoolConfig,
    text: str,
    reference_date: date | None,
) -> list[dict[str, str]]:
    """Apply the configured parser and its safe generic fallback."""
    terms = (
        _parse_example_school_college(text, reference_date)
        if config.is_master
        else _parse_generic_uk_terms(text, reference_date)
    )
    if not terms and config.is_master:
        terms = _parse_generic_uk_terms(text, reference_date)
    return terms


def _covers_next_academic_year(
    terms: list[dict[str, str]],
    reference_date: date | None,
    expected_terms_per_season: int = 1,
) -> bool:
    """Whether parsed output has the expected blocks in every next-AY season."""
    next_start = max(_target_academic_year_starts(reference_date))
    return next_start in _complete_academic_years(terms, expected_terms_per_season)


async def _fetch_linked_term_documents(
    config: SchoolConfig,
    page_text: str,
) -> list[str]:
    """Fetch allowlisted linked term-date PDFs through Jina's PDF reader."""
    if not config.known_url:
        return []
    links = _extract_linked_term_documents(
        page_text,
        base_url=config.known_url,
        allowed_hosts=config.linked_document_hosts,
    )
    if not links:
        return []
    return list(await asyncio.gather(*(fetch_page(link, use_jina=True) for link in links)))


async def _collect_school_terms(
    school_key: str,
    config: SchoolConfig,
    reference_date: date | None = None,
) -> tuple[str, dict[str, Any], list[dict[str, str]]]:
    """Fetch and parse one school without touching SQLite."""
    logger.info("Processing school: %s", school_key)
    try:
        text = await _fetch_school_text(config)
        if not text:
            logger.warning("No text retrieved for %s", school_key)
            return (
                school_key,
                {
                    "status": "fetch_failed",
                    "error": "Could not retrieve any text from URL or search",
                },
                [],
            )

        terms = _parse_school_text(config, text, reference_date)
        linked_documents: list[str] = []
        if not _covers_next_academic_year(
            terms,
            reference_date,
            config.expected_terms_per_season,
        ):
            linked_documents = await _fetch_linked_term_documents(config, text)
            for document in linked_documents:
                if document:
                    terms.extend(_parse_school_text(config, document, reference_date))
            terms = _deduplicate_terms(terms)

        if terms:
            academic_years = sorted(
                {_academic_year_start(date.fromisoformat(term["start_date"])) for term in terms}
            )
            next_year_complete = _covers_next_academic_year(
                terms,
                reference_date,
                config.expected_terms_per_season,
            )
            return (
                school_key,
                {
                    "status": "ok" if next_year_complete else "partial",
                    "labels": [term["label"] for term in terms],
                    "academic_years": academic_years,
                    "next_academic_year_complete": next_year_complete,
                    "linked_documents": sum(bool(document) for document in linked_documents),
                },
                terms,
            )

        logger.warning("Regex parsing failed for %s", school_key)
        return (
            school_key,
            {
                "status": "parse_failed",
                "prompt": generate_claude_prompt(
                    school_key.replace("_", " ").title(),
                    text,
                ),
            },
            [],
        )
    except Exception as exc:
        logger.error("Error processing %s: %s", school_key, exc, exc_info=True)
        return school_key, {"status": "error", "error": str(exc)}, []


async def _collect_all_term_updates(
    reference_date: date | None = None,
) -> list[tuple[str, dict[str, Any], list[dict[str, str]]]]:
    """Fetch independent school pages concurrently; each has its own timeout."""
    return list(
        await asyncio.gather(
            *(
                _collect_school_terms(school_key, config, reference_date)
                for school_key, config in SCHOOL_CONFIG.items()
            )
        )
    )


async def _apply_term_updates(
    db: Any,
    collected: list[tuple[str, dict[str, Any], list[dict[str, str]]]],
    *,
    family_id: str | None,
    reference_date: date | None = None,
) -> dict[str, dict[str, Any]]:
    """Atomically merge every relevant school before replacing each person."""
    collected_by_school = {school_key: (result, terms) for school_key, result, terms in collected}
    summary = {school_key: dict(result) for school_key, result, _terms in collected}
    required_sources: dict[str, set[str]] = {}
    terms_by_person: dict[str, list[dict[str, str]]] = {}
    contribution_counts: dict[tuple[str, str], int] = {}
    expected_terms_by_person_year: dict[tuple[str, int], int] = {}

    for school_key, config in SCHOOL_CONFIG.items():
        valid_people = await _configured_people_for_family(
            db,
            config.person_ids,
            family_id,
        )
        _result, school_terms = collected_by_school.get(
            school_key,
            ({"status": "error"}, []),
        )
        for person_id in valid_people:
            if not _assignment_overlaps_target_years(
                config,
                person_id,
                reference_date,
            ):
                continue
            required_sources.setdefault(person_id, set()).add(school_key)
            assigned_terms = _terms_for_person(config, person_id, school_terms)
            if assigned_terms:
                terms_by_person.setdefault(person_id, []).extend(assigned_terms)
                contribution_counts[(person_id, school_key)] = len(assigned_terms)
                for term in assigned_terms:
                    academic_year = _academic_year_start(date.fromisoformat(term["start_date"]))
                    expectation_key = (person_id, academic_year)
                    expected_terms_by_person_year[expectation_key] = max(
                        expected_terms_by_person_year.get(expectation_key, 1),
                        config.expected_terms_per_season,
                    )

    now = datetime.now(timezone.utc).isoformat()
    written_people: set[str] = set()
    skipped_people_by_school: dict[str, list[str]] = {}
    for person_id, school_keys in required_sources.items():
        missing_sources = {
            school_key
            for school_key in school_keys
            if not collected_by_school.get(school_key, ({}, []))[1]
        }
        if missing_sources:
            for school_key in school_keys:
                skipped_people_by_school.setdefault(school_key, []).append(person_id)
            logger.warning(
                "Preserving existing terms for %s because sources failed: %s",
                person_id,
                ", ".join(sorted(missing_sources)),
            )
            continue

        person_terms = _deduplicate_terms(terms_by_person.get(person_id, []))
        replace_academic_years = {
            academic_year
            for (expected_person_id, academic_year), expectation in (
                expected_terms_by_person_year.items()
            )
            if expected_person_id == person_id
            and academic_year in _complete_academic_years(person_terms, expectation)
        }
        await _replace_person_term_dates(
            db,
            person_id=person_id,
            terms=person_terms,
            family_id=family_id,
            now=now,
            replace_academic_years=replace_academic_years,
        )
        written_people.add(person_id)

    if family_id is not None or written_people:
        await reconcile_term_boundary_events(
            db,
            family_id=family_id,
            person_ids=None if family_id is not None else written_people,
            actor_id=_SCRAPER_CREATED_BY,
        )
    await db.commit()

    for school_key, result in summary.items():
        if collected_by_school.get(school_key, ({}, []))[1]:
            result["terms"] = sum(
                count
                for (person_id, source_key), count in contribution_counts.items()
                if source_key == school_key and person_id in written_people
            )
            logger.info(
                "Parsed %d source terms for %s",
                len(collected_by_school[school_key][1]),
                school_key,
            )
        if skipped := skipped_people_by_school.get(school_key):
            result["write_skipped_people"] = sorted(skipped)
    return summary


async def refresh_all_terms(
    db: Any,
    family_id: str | None = None,
    reference_date: date | None = None,
) -> dict[str, dict[str, Any]]:
    """Compatibility entry point for callers that already own a connection."""
    collected = await _collect_all_term_updates(reference_date)
    return await _apply_term_updates(
        db,
        collected,
        family_id=family_id,
        reference_date=reference_date,
    )


async def refresh_all_terms_for_family(
    *,
    family_id: str,
    reference_date: date | None = None,
) -> dict[str, dict[str, Any]]:
    """Fetch all schools first, then lease SQLite only for validated writes."""
    collected = await _collect_all_term_updates(reference_date)
    async with database_lease() as db:
        return await _apply_term_updates(
            db,
            collected,
            family_id=family_id,
            reference_date=reference_date,
        )
