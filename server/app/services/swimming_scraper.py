"""Import configured Sunday swimming lessons from the configured swimming provider calendar."""

import json
import logging
import re
import uuid
from datetime import datetime, timezone
from typing import Any

import httpx

from app.config import settings
from app.database import database_lease

logger = logging.getLogger(__name__)

SWIMMING_SCHEDULE_URL = (
    "https://swimming.example.invalid/available-classes/schedule/"
)
_CREATED_BY = "swimming-scraper"
_LESSON_START_HOUR = 8
_LESSON_START_MINUTE = 30
_LESSON_DURATION_MINUTES = 30
_HTTP_TIMEOUT = 20.0
_MAX_PAGE_BYTES = 2_000_000
_UUID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
_DATES_PATTERN = re.compile(
    r"\bvar\s+w_dates\s*=\s*(\[[^;]{1,1900000}\])\s*;",
    flags=re.DOTALL,
)


def _configured_child_ids() -> list[str]:
    """Return unique, syntactically valid child IDs from private configuration."""
    result: list[str] = []
    for raw_value in settings.swimming_child_ids.split(","):
        value = raw_value.strip().lower()
        if value and _UUID_PATTERN.fullmatch(value) and value not in result:
            result.append(value)
    return result


def _extract_lesson_dates(page_html: str) -> list[str]:
    """Extract unique Sunday dates from the bounded embedded ``w_dates`` JSON."""
    match = _DATES_PATTERN.search(page_html)
    if not match:
        return []
    try:
        raw_dates = json.loads(match.group(1))
    except json.JSONDecodeError:
        return []
    if not isinstance(raw_dates, list):
        return []

    dates: set[str] = set()
    for value in raw_dates:
        if not isinstance(value, str) or len(value) > 100:
            continue
        try:
            parsed = datetime.strptime(value.strip(), "%a %b %d %Y")
        except ValueError:
            continue
        if parsed.weekday() == 6:
            dates.add(parsed.date().isoformat())
    return sorted(dates)


async def _fetch_lesson_dates() -> list[str]:
    """Fetch at most two megabytes and parse dates without launching a browser."""
    try:
        async with httpx.AsyncClient(
            timeout=_HTTP_TIMEOUT,
            follow_redirects=True,
            headers={"User-Agent": "HausKlar-SwimmingImporter/1.0"},
        ) as client:
            async with client.stream("GET", SWIMMING_SCHEDULE_URL) as response:
                response.raise_for_status()
                content_length = response.headers.get("content-length")
                if content_length and int(content_length) > _MAX_PAGE_BYTES:
                    logger.warning("configured swimming provider page exceeded the response limit")
                    return []
                chunks: list[bytes] = []
                received = 0
                async for chunk in response.aiter_bytes():
                    received += len(chunk)
                    if received > _MAX_PAGE_BYTES:
                        logger.warning("configured swimming provider page exceeded the response limit")
                        return []
                    chunks.append(chunk)
        dates = _extract_lesson_dates(b"".join(chunks).decode("utf-8", errors="replace"))
        if not dates:
            logger.warning("No Sunday lesson dates found on the configured swimming provider page")
        return dates
    except (httpx.HTTPError, ValueError):
        logger.warning("Failed to fetch the configured swimming provider lesson calendar")
        return []


async def _family_attendee_ids(db: Any, family_id: str, configured: list[str]) -> list[str]:
    if not configured:
        return []
    placeholders = ",".join("?" for _ in configured)
    cursor = await db.execute(
        f"SELECT id FROM children WHERE family_id = ? AND deleted_at IS NULL "
        f"AND id IN ({placeholders})",
        (family_id, *configured),
    )
    valid = {row["id"] for row in await cursor.fetchall()}
    return [child_id for child_id in configured if child_id in valid]


async def _replace_swimming_lessons(
    db: Any,
    *,
    family_id: str,
    attendee_ids: list[str],
    lesson_dates: list[str],
) -> dict:
    """Atomically replace only this family's importer-created future events."""
    now = datetime.now(timezone.utc).isoformat()
    today = datetime.now(timezone.utc).date().isoformat()
    future_dates = [value for value in lesson_dates if value >= today]
    await db.execute("BEGIN IMMEDIATE")
    try:
        valid_attendees = await _family_attendee_ids(db, family_id, attendee_ids)
        if not valid_attendees:
            await db.rollback()
            return {"status": "not_configured", "events_created": 0}
        await db.execute(
            "UPDATE calendar_events SET deleted_at = ?, updated_at = ? "
            "WHERE created_by = ? AND deleted_at IS NULL AND family_id = ?",
            (now, now, _CREATED_BY, family_id),
        )

        member_ids_json = json.dumps(valid_attendees, separators=(",", ":"))
        end_total_minutes = (
            _LESSON_START_HOUR * 60
            + _LESSON_START_MINUTE
            + _LESSON_DURATION_MINUTES
        )
        end_hour, end_minute = divmod(end_total_minutes, 60)
        for date_str in future_dates:
            await db.execute(
                """
                INSERT INTO calendar_events
                    (id, title, start_time, end_time, all_day, location,
                     family_member_ids, event_type, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    "Swimming",
                    f"{date_str}T{_LESSON_START_HOUR:02d}:{_LESSON_START_MINUTE:02d}:00",
                    f"{date_str}T{end_hour:02d}:{end_minute:02d}:00",
                    "St John's Beaumont, Old Example Town",
                    member_ids_json,
                    "activity",
                    family_id,
                    now,
                    now,
                    _CREATED_BY,
                ),
            )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise

    logger.info("Swimming importer inserted %d events", len(future_dates))
    return {
        "status": "ok",
        "total_sunday_dates": len(lesson_dates),
        "events_created": len(future_dates),
    }


async def refresh_swimming_lessons(*, family_id: str) -> dict:
    """Validate private attendees, fetch externally, then hold SQLite only to write."""
    configured = _configured_child_ids()
    if not configured:
        return {"status": "not_configured", "events_created": 0}
    async with database_lease() as db:
        attendee_ids = await _family_attendee_ids(db, family_id, configured)
    if not attendee_ids:
        return {"status": "not_configured", "events_created": 0}

    lesson_dates = await _fetch_lesson_dates()
    if not lesson_dates:
        return {"status": "no_dates", "events_created": 0}
    async with database_lease() as db:
        return await _replace_swimming_lessons(
            db,
            family_id=family_id,
            attendee_ids=attendee_ids,
            lesson_dates=lesson_dates,
        )
