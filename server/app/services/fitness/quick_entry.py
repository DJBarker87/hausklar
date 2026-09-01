"""Owner-scoped preferences and live availability for Fitness Today actions."""

from __future__ import annotations

import asyncio
import hashlib
import json
from datetime import date, datetime, time, timedelta, timezone
from time import monotonic
from typing import Any

import httpx

from app.http_clients import provider_client
from app.models.fitness_quick_entry import (
    QuickEntryPreferencesUpdate,
    StrengthAvailabilityDay,
    StrengthAvailabilityResponse,
    StrengthAvailabilityWindow,
    StrengthBookingCreate,
    StrengthBookingResponse,
    ViBookingCreate,
    ViBookingResponse,
    ViClassClassification,
    ViClassWindow,
    ViScheduleDay,
    ViScheduleResponse,
)
from app.models.calendar import CalendarEventCreate
from app.services.create_records import create_or_replay_calendar_event
from app.services.facilities import FACILITY_ZONE, weights_room_availability
from app.services.fitness.common import owned_row, update_owned
from app.services.fitness.planning import ensure_settings
from app.services.idempotency import CreateReplayConflictError, serialized_create


VI_BOOKING_URL = (
    "https://app.vitraininggym.co.uk/a/booking/"
    "?serviceTag=1.%20All%20Group%20Classes&embedded=true&iframe=true&web_embed=true"
)
VI_SCHEDULE_URL = "https://www.vitraininggym.co.uk/class-schedule/"
VI_CALENDAR_URL = "https://app.vitraininggym.co.uk/api/v4/calendar"
_VI_RESPONSE_LIMIT_BYTES = 2_000_000
_VI_CACHE_TTL_SECONDS = 15 * 60
_VI_CACHE_MAX_STALE_SECONDS = 6 * 60 * 60
_VI_FAILURE_TTL_SECONDS = 60
_VI_CACHE_MAX_ENTRIES = 64
_VI_MAX_WINDOWS_PER_DAY = 40
_STRENGTH_RANGE_MAX_DAYS = 31
_STRENGTH_DATE_PAST_DAYS = 1
_STRENGTH_DATE_FUTURE_DAYS = 366
_vi_cache: dict[tuple[date, date], tuple[float, dict[date, list[ViClassWindow]]]] = {}
_vi_cache_lock = asyncio.Lock()
_vi_failure_at: float | None = None


def clear_vi_strength_cache() -> None:
    """Clear the short-lived public timetable cache (primarily for tests)."""
    global _vi_failure_at
    _vi_cache.clear()
    _vi_failure_at = None


def _validate_strength_range(*, start: date, end: date) -> None:
    """Bound all service callers, not just the HTTP route, before allocating days."""
    if end < start or (end - start).days >= _STRENGTH_RANGE_MAX_DAYS:
        raise ValueError("Strength range must be 31 days or fewer")
    today = datetime.now(FACILITY_ZONE).date()
    if start < today - timedelta(days=_STRENGTH_DATE_PAST_DAYS):
        raise ValueError("Strength availability cannot start more than one day ago")
    if end > today + timedelta(days=_STRENGTH_DATE_FUTURE_DAYS):
        raise ValueError("Strength availability cannot be more than 366 days ahead")


def _validate_booking_date(value: date) -> None:
    today = datetime.now(FACILITY_ZONE).date()
    if value < today - timedelta(days=_STRENGTH_DATE_PAST_DAYS):
        raise ValueError("Strength booking cannot be more than one day ago")
    if value > today + timedelta(days=_STRENGTH_DATE_FUTURE_DAYS):
        raise ValueError("Strength booking cannot be more than 366 days ahead")


def _prune_vi_cache(now: float) -> None:
    """Keep stale fallback bounded beyond the shorter freshness window."""
    expired = [
        key
        for key, (loaded_at, _) in _vi_cache.items()
        if now - loaded_at >= _VI_CACHE_MAX_STALE_SECONDS
    ]
    for key in expired:
        _vi_cache.pop(key, None)
    overflow = len(_vi_cache) - _VI_CACHE_MAX_ENTRIES
    if overflow > 0:
        oldest = sorted(_vi_cache, key=lambda key: _vi_cache[key][0])[:overflow]
        for key in oldest:
            _vi_cache.pop(key, None)


def _cached_vi_range(
    *, start: date, end: date
) -> tuple[float, dict[date, list[ViClassWindow]]] | None:
    cached = _vi_cache.get((start, end))
    if cached is not None:
        return cached
    covering = [
        (loaded_at, windows)
        for (cached_start, cached_end), (loaded_at, windows) in _vi_cache.items()
        if cached_start <= start and end <= cached_end
    ]
    if not covering:
        return None
    loaded_at, windows = max(covering, key=lambda item: item[0])
    return (
        loaded_at,
        {day: day_windows for day, day_windows in windows.items() if start <= day <= end},
    )


def _meal_times(settings: dict[str, Any]) -> dict[str, dict[str, str]]:
    return {
        "meal_times": {
            "breakfast": str(settings.get("breakfast_time") or "08:00"),
            "lunch": str(settings.get("lunch_time") or "12:30"),
            "dinner": str(settings.get("dinner_time") or "18:30"),
        }
    }


async def get_quick_entry_preferences(db, *, user: dict) -> dict[str, dict[str, str]]:
    return _meal_times(await ensure_settings(db, user=user))


async def update_quick_entry_preferences(
    db,
    *,
    user: dict,
    body: QuickEntryPreferencesUpdate,
) -> dict[str, dict[str, str]]:
    settings = await ensure_settings(db, user=user)
    await update_owned(
        db,
        table="health_user_settings",
        record_id=settings["id"],
        values={
            "breakfast_time": body.meal_times.breakfast,
            "lunch_time": body.meal_times.lunch,
            "dinner_time": body.meal_times.dinner,
        },
        user=user,
    )
    updated = await owned_row(
        db,
        table="health_user_settings",
        record_id=settings["id"],
        user=user,
    )
    return _meal_times(dict(updated))


async def _latest_example_school_owner(db, *, family_id: str) -> dict[str, Any] | None:
    row = await (
        await db.execute(
            "SELECT v.personal_owner_user_id, v.title, v.source_document_id, v.valid_to "
            "FROM facility_schedule_versions v "
            "JOIN users u ON u.id = v.personal_owner_user_id "
            "AND u.family_id = v.family_id AND u.deleted_at IS NULL "
            "WHERE v.family_id = ? AND v.provider_key = 'school_college' "
            "AND v.status = 'confirmed' AND v.deleted_at IS NULL "
            "ORDER BY v.created_at DESC, v.id DESC LIMIT 1",
            (family_id,),
        )
    ).fetchone()
    return dict(row) if row is not None else None


def _empty_days(start: date, end: date) -> list[StrengthAvailabilityDay]:
    result: list[StrengthAvailabilityDay] = []
    cursor = start
    while cursor <= end:
        result.append(StrengthAvailabilityDay(date=cursor, covered=False))
        cursor += timedelta(days=1)
    return result


async def _example_school_strength_availability(
    db,
    *,
    user: dict,
    start: date,
    end: date,
    source: dict[str, Any] | None,
) -> StrengthAvailabilityResponse:
    availability = await weights_room_availability(
        db,
        user=user,
        start=start,
        end=end,
    )
    summaries = {summary.date: summary for summary in availability.days}
    days: list[StrengthAvailabilityDay] = []
    cursor = start
    while cursor <= end:
        summary = summaries.get(cursor)
        days.append(
            StrengthAvailabilityDay(
                date=cursor,
                covered=summary is not None,
                windows=(
                    [
                        StrengthAvailabilityWindow(
                            start=window.start,
                            end=window.end,
                            label="Weights room",
                        )
                        for window in summary.weights_room
                    ]
                    if summary is not None
                    else []
                ),
            )
        )
        cursor += timedelta(days=1)
    source_title = availability.source_title or (source or {}).get("title")
    return StrengthAvailabilityResponse(
        provider="school_weights_room",
        source_title=source_title or "Example School College weights room timetable",
        unavailable_reason=(
            None
            if any(day.covered for day in days)
            else "Upload the latest Example School facilities timetable to show weights-room times."
        ),
        days=days,
    )


def _classify_vi_class(item: dict[str, Any]) -> ViClassClassification:
    data = item.get("data") if isinstance(item.get("data"), dict) else {}
    title = str(data.get("service") or "").strip().casefold()
    description = str(data.get("service_description") or "").strip().casefold()
    if (
        "small group personal training" in title
        or "strength" in title
        or description.startswith("vi = strength")
    ):
        return "strength"
    if any(value in title for value in ("run", "running")):
        return "run"
    if any(value in title for value in ("mobility", "stretch", "yoga", "pilates")):
        return "mobility"
    if any(value in title for value in ("conditioning", "hiit", "circuit", "cardio", "metcon")):
        return "conditioning"
    return "other"


def _is_vi_strength_class(item: dict[str, Any]) -> bool:
    return _classify_vi_class(item) == "strength"


def _public_vi_class_label(item: dict[str, Any]) -> str:
    """Map provider text to a small public taxonomy; never surface attendee metadata."""
    data = item.get("data") if isinstance(item.get("data"), dict) else {}
    raw = str(data.get("service") or item.get("text") or "").casefold()
    if "small group personal training" in raw:
        return "Small Group Personal Training"
    classification = _classify_vi_class(item)
    return {
        "strength": "Strength class",
        "run": "Run community" if "community" in raw else "Running class",
        "conditioning": "Conditioning class",
        "mobility": "Mobility class",
        "other": "Group class",
    }[classification]


def _parse_vi_calendar(
    payload: Any,
    *,
    start: date,
    end: date,
) -> dict[date, list[ViClassWindow]]:
    _validate_strength_range(start=start, end=end)
    if not isinstance(payload, list) or len(payload) > 2_000:
        raise ValueError("Vi returned an invalid timetable")
    result: dict[date, list[ViClassWindow]] = {
        start + timedelta(days=offset): [] for offset in range((end - start).days + 1)
    }
    seen: set[tuple[date, str, str, str]] = set()
    for raw_item in payload:
        if not isinstance(raw_item, dict):
            continue
        data = raw_item.get("data") if isinstance(raw_item.get("data"), dict) else {}
        try:
            start_at = datetime.fromisoformat(
                str(raw_item["start_time"]).replace("Z", "+00:00")
            ).astimezone(FACILITY_ZONE)
            end_at = datetime.fromisoformat(
                str(raw_item["end_time"]).replace("Z", "+00:00")
            ).astimezone(FACILITY_ZONE)
        except (KeyError, TypeError, ValueError):
            continue
        local_date = start_at.date()
        if local_date not in result or end_at <= start_at or end_at.date() != local_date:
            continue
        title = _public_vi_class_label(raw_item)
        classification = _classify_vi_class(raw_item)
        visits_remaining = data.get("visits_remaining")
        if isinstance(visits_remaining, (int, float)) and visits_remaining <= 0:
            title += " · waitlist" if data.get("waitlist") else " · full"
        start_value = start_at.strftime("%H:%M")
        end_value = end_at.strftime("%H:%M")
        key = (local_date, start_value, end_value, title)
        if key in seen:
            continue
        seen.add(key)
        result[local_date].append(
            ViClassWindow(
                start=start_value,
                end=end_value,
                label=title,
                classification=classification,
                booking_url=VI_BOOKING_URL,
            )
        )
    for windows in result.values():
        windows.sort(key=lambda item: (item.start, item.end, item.label or ""))
        del windows[_VI_MAX_WINDOWS_PER_DAY:]
    return result


async def _download_vi_calendar(
    *,
    start: date,
    end: date,
    client: httpx.AsyncClient | None = None,
) -> dict[date, list[ViClassWindow]]:
    _validate_strength_range(start=start, end=end)
    http = client or await provider_client(
        "vi-training-public-timetable",
        timeout=httpx.Timeout(8.0, connect=3.0, read=6.0, write=3.0, pool=3.0),
        follow_redirects=False,
        trust_env=False,
    )
    start_at = datetime.combine(start, time.min, tzinfo=FACILITY_ZONE)
    end_exclusive = datetime.combine(end + timedelta(days=1), time.min, tzinfo=FACILITY_ZONE)
    headers = {
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Content-Type": "application/json",
        "Referer": VI_BOOKING_URL,
        "User-Agent": "HausKlar/1.0 (+https://hausklar.example.invalid)",
    }
    params = {
        "start": int(start_at.timestamp()),
        "end": int(end_exclusive.timestamp()) - 1,
        "object_type": "appointments,schedule_services",
        "user_id": "undefined",
        "time_zone": "Europe/London",
        "q[public]": "true",
        "q[service_tag]": "1. All Group Classes",
    }
    async with http.stream("GET", VI_CALENDAR_URL, params=params, headers=headers) as response:
        response.raise_for_status()
        declared_size = response.headers.get("content-length")
        if declared_size and int(declared_size) > _VI_RESPONSE_LIMIT_BYTES:
            raise ValueError("Vi timetable response is too large")
        chunks: list[bytes] = []
        received = 0
        async for chunk in response.aiter_bytes():
            received += len(chunk)
            if received > _VI_RESPONSE_LIMIT_BYTES:
                raise ValueError("Vi timetable response is too large")
            chunks.append(chunk)
    return _parse_vi_calendar(json.loads(b"".join(chunks)), start=start, end=end)


async def _vi_windows(
    *,
    start: date,
    end: date,
    client: httpx.AsyncClient | None = None,
) -> tuple[dict[date, list[ViClassWindow]] | None, bool]:
    """Return allowlisted public slots and whether cached fallback was used."""
    global _vi_failure_at
    _validate_strength_range(start=start, end=end)
    cache_key = (start, end)
    if client is None:
        now = monotonic()
        _prune_vi_cache(now)
    cached = _cached_vi_range(start=start, end=end) if client is None else None
    if cached is not None and monotonic() - cached[0] < _VI_CACHE_TTL_SECONDS:
        return cached[1], False
    if (
        client is None
        and _vi_failure_at is not None
        and monotonic() - _vi_failure_at < _VI_FAILURE_TTL_SECONDS
    ):
        return (cached[1], True) if cached is not None else (None, False)
    try:
        if client is not None:
            return await _download_vi_calendar(start=start, end=end, client=client), False
        async with _vi_cache_lock:
            now = monotonic()
            _prune_vi_cache(now)
            cached = _cached_vi_range(start=start, end=end)
            if cached is not None and monotonic() - cached[0] < _VI_CACHE_TTL_SECONDS:
                return cached[1], False
            if _vi_failure_at is not None and now - _vi_failure_at < _VI_FAILURE_TTL_SECONDS:
                return (cached[1], True) if cached is not None else (None, False)
            windows = await _download_vi_calendar(start=start, end=end)
            _vi_failure_at = None
            _vi_cache[cache_key] = (monotonic(), windows)
            _prune_vi_cache(monotonic())
            return windows, False
    except (httpx.HTTPError, json.JSONDecodeError, TypeError, ValueError, OverflowError):
        if client is None:
            _vi_failure_at = monotonic()
        if cached is not None:
            return cached[1], True
        return None, False


async def _vi_strength_availability(
    *,
    start: date,
    end: date,
    client: httpx.AsyncClient | None = None,
) -> StrengthAvailabilityResponse:
    windows, stale = await _vi_windows(start=start, end=end, client=client)
    if windows is None:
        return StrengthAvailabilityResponse(
            provider="vi_training",
            source_title="Vi Training Example School class timetable",
            source_url=VI_SCHEDULE_URL,
            unavailable_reason=(
                "The live Vi timetable could not be read just now. Open Vi or choose a manual start time."
            ),
            days=_empty_days(start, end),
        )
    days = []
    for day, day_windows in sorted(windows.items()):
        strength_windows = [
            StrengthAvailabilityWindow(
                start=window.start,
                end=window.end,
                label=window.label,
                booking_url=window.booking_url,
            )
            for window in day_windows
            if window.classification == "strength"
        ]
        days.append(StrengthAvailabilityDay(date=day, covered=True, windows=strength_windows))
    return StrengthAvailabilityResponse(
        provider="vi_training",
        source_title="Vi Training Example School class timetable",
        source_url=VI_SCHEDULE_URL,
        unavailable_reason=(
            "Vi could not refresh, so these are the last recently loaded times." if stale else None
        ),
        days=days,
    )


def _uses_example_school_timetable(source: dict[str, Any] | None, *, user: dict) -> bool:
    return (
        source["personal_owner_user_id"] == user["id"]
        if source is not None
        else user.get("role") == "admin"
    )


async def vi_schedule(
    db,
    *,
    user: dict,
    start: date,
    end: date,
    vi_client: httpx.AsyncClient | None = None,
) -> ViScheduleResponse:
    """Return all safe public Vi classes only for the adult whose venue is Vi."""
    _validate_strength_range(start=start, end=end)
    school_source = await _latest_example_school_owner(db, family_id=user["family_id"])
    if _uses_example_school_timetable(school_source, user=user):
        return ViScheduleResponse(
            relevant=False,
            source_title="Vi Training Example School class timetable",
            source_url=VI_SCHEDULE_URL,
            days=[],
        )
    windows, stale = await _vi_windows(start=start, end=end, client=vi_client)
    if windows is None:
        return ViScheduleResponse(
            relevant=True,
            source_title="Vi Training Example School class timetable",
            source_url=VI_SCHEDULE_URL,
            unavailable_reason="The live Vi timetable could not be read just now. Open Vi to view it.",
            days=[
                ViScheduleDay(date=day.date, covered=False, classes=[])
                for day in _empty_days(start, end)
            ],
        )
    return ViScheduleResponse(
        relevant=True,
        source_title="Vi Training Example School class timetable",
        source_url=VI_SCHEDULE_URL,
        unavailable_reason=(
            "Vi could not refresh, so these are the last recently loaded times." if stale else None
        ),
        days=[
            ViScheduleDay(date=day, covered=True, classes=day_windows)
            for day, day_windows in sorted(windows.items())
        ],
    )


async def strength_availability(
    db,
    *,
    user: dict,
    start: date,
    end: date,
    vi_client: httpx.AsyncClient | None = None,
) -> StrengthAvailabilityResponse:
    """Resolve the current adult's real strength venue without sharing owner data."""
    _validate_strength_range(start=start, end=end)
    school_source = await _latest_example_school_owner(db, family_id=user["family_id"])
    if _uses_example_school_timetable(school_source, user=user):
        return await _example_school_strength_availability(
            db,
            user=user,
            start=start,
            end=end,
            source=school_source,
        )
    return await _vi_strength_availability(start=start, end=end, client=vi_client)


async def create_strength_booking(
    db,
    *,
    user: dict,
    booking: StrengthBookingCreate,
    vi_client: httpx.AsyncClient | None = None,
) -> StrengthBookingResponse:
    """Record a class only after the adult says they completed Vi's booking step."""
    result = await _create_vi_booking(
        db,
        user=user,
        booking=ViBookingCreate.model_validate(
            {**booking.model_dump(), "classification": "strength"}
        ),
        required_classification="strength",
        vi_client=vi_client,
    )
    return StrengthBookingResponse(
        event_id=result.event_id,
        title=result.title,
        start_time=result.start_time,
        end_time=result.end_time,
        location=result.location,
    )


async def create_vi_booking(
    db,
    *,
    user: dict,
    booking: ViBookingCreate,
    vi_client: httpx.AsyncClient | None = None,
) -> ViBookingResponse:
    """Acknowledge any public Vi class exactly once after the external booking step."""
    return await _create_vi_booking(
        db,
        user=user,
        booking=booking,
        required_classification=None,
        vi_client=vi_client,
    )


def _vi_booking_logical_key(*, user: dict, booking: ViBookingCreate) -> str:
    identity = {
        "owner_user_id": user["id"],
        "provider": booking.provider,
        "date": booking.date.isoformat(),
        "start": booking.start,
        "end": booking.end,
        "label": booking.label,
        "classification": booking.classification,
    }
    return hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def _vi_receipt_response(row) -> ViBookingResponse:
    booking_date = date.fromisoformat(row["booking_date"])
    return ViBookingResponse(
        event_id=row["event_id"],
        title=row["label"],
        start_time=datetime.combine(
            booking_date,
            time.fromisoformat(row["start_time"]),
            tzinfo=FACILITY_ZONE,
        ).isoformat(),
        end_time=datetime.combine(
            booking_date,
            time.fromisoformat(row["end_time"]),
            tzinfo=FACILITY_ZONE,
        ).isoformat(),
        location=row["location"],
        classification=row["classification"],
    )


def _vi_receipt_matches(row, *, user: dict, booking: ViBookingCreate, logical_key: str) -> bool:
    return (
        row["deleted_at"] is None
        and row["owner_user_id"] == user["id"]
        and row["family_id"] == user["family_id"]
        and row["provider"] == booking.provider
        and row["logical_key"] == logical_key
        and row["booking_date"] == booking.date.isoformat()
        and row["start_time"] == booking.start
        and row["end_time"] == booking.end
        and row["label"] == booking.label
        and row["classification"] == booking.classification
    )


async def _insert_vi_receipt(
    db,
    *,
    request_id: str,
    canonical_receipt_id: str,
    is_canonical: bool,
    logical_key: str,
    event_id: str,
    booking: ViBookingCreate,
    user: dict,
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """INSERT INTO fitness_vi_booking_receipts
           (id, canonical_receipt_id, is_canonical, owner_user_id, provider,
            logical_key, event_id, booking_date, start_time, end_time, label,
            classification, location, family_id, created_at, updated_at,
            created_by, client_id, client_timestamp)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'Vi Training, Example School',
                   ?, ?, ?, ?, ?, ?)""",
        (
            request_id,
            canonical_receipt_id,
            int(is_canonical),
            user["id"],
            booking.provider,
            logical_key,
            event_id,
            booking.date.isoformat(),
            booking.start,
            booking.end,
            booking.label,
            booking.classification,
            user["family_id"],
            now,
            now,
            user["id"],
            booking.client_id,
            booking.client_timestamp,
        ),
    )


async def _replay_vi_receipt(
    db,
    *,
    user: dict,
    booking: ViBookingCreate,
    logical_key: str,
) -> ViBookingResponse | None:
    request_id = str(booking.id)
    by_request = await (
        await db.execute(
            "SELECT * FROM fitness_vi_booking_receipts WHERE id = ?",
            (request_id,),
        )
    ).fetchone()
    if by_request is not None:
        if not _vi_receipt_matches(
            by_request,
            user=user,
            booking=booking,
            logical_key=logical_key,
        ):
            raise CreateReplayConflictError(
                "Create operation ID was already used for a different request"
            )
        return _vi_receipt_response(by_request)

    canonical = await (
        await db.execute(
            "SELECT * FROM fitness_vi_booking_receipts "
            "WHERE owner_user_id = ? AND logical_key = ? AND is_canonical = 1 "
            "AND deleted_at IS NULL",
            (user["id"], logical_key),
        )
    ).fetchone()
    if canonical is None:
        return None
    await _insert_vi_receipt(
        db,
        request_id=request_id,
        canonical_receipt_id=canonical["id"],
        is_canonical=False,
        logical_key=logical_key,
        event_id=canonical["event_id"],
        booking=booking,
        user=user,
    )
    return _vi_receipt_response(canonical)


async def _create_vi_booking(
    db,
    *,
    user: dict,
    booking: ViBookingCreate,
    required_classification: ViClassClassification | None,
    vi_client: httpx.AsyncClient | None,
) -> ViBookingResponse:
    start_time = datetime.combine(
        booking.date,
        time.fromisoformat(booking.start),
        tzinfo=FACILITY_ZONE,
    ).isoformat()
    end_time = datetime.combine(
        booking.date,
        time.fromisoformat(booking.end),
        tzinfo=FACILITY_ZONE,
    ).isoformat()
    logical_key = _vi_booking_logical_key(user=user, booking=booking)

    def event_body(title: str) -> CalendarEventCreate:
        return CalendarEventCreate(
            id=booking.id,
            title=title,
            description=(
                f"Vi class: {booking.classification}. "
                f"Booked through the Vi Training timetable. {VI_SCHEDULE_URL}"
            ),
            start_time=start_time,
            end_time=end_time,
            all_day=False,
            location="Vi Training, Example School",
            family_member_ids=[user["id"]],
            event_type="activity",
            exertion=2 if booking.classification in {"strength", "conditioning"} else 1,
            client_id=booking.client_id,
            client_timestamp=booking.client_timestamp,
        )

    # Receipts are authoritative after the external booking acknowledgement.
    # Check them before date/provider relevance so even an old booking remains
    # retryable after a relaunch or a later account-setting change.
    async with serialized_create(db):
        replay = await _replay_vi_receipt(
            db,
            user=user,
            booking=booking,
            logical_key=logical_key,
        )
        if replay is not None:
            return replay

    _validate_booking_date(booking.date)
    school_source = await _latest_example_school_owner(db, family_id=user["family_id"])
    if _uses_example_school_timetable(school_source, user=user):
        raise ValueError("This account does not use the Vi timetable")

    # Backfill a durable receipt for acknowledgements created by releases before
    # this ledger existed, while retaining caller-UUID mismatch detection.
    async with serialized_create(db):
        replay = await _replay_vi_receipt(
            db,
            user=user,
            booking=booking,
            logical_key=logical_key,
        )
        if replay is not None:
            return replay
        existing = await (
            await db.execute("SELECT id FROM calendar_events WHERE id = ?", (str(booking.id),))
        ).fetchone()
        if existing is not None:
            event, _replayed = await create_or_replay_calendar_event(
                db,
                event_body(booking.label),
                record_id=str(booking.id),
                user=user,
                client_id=booking.client_id,
                client_timestamp=booking.client_timestamp,
            )
            await _insert_vi_receipt(
                db,
                request_id=str(booking.id),
                canonical_receipt_id=str(booking.id),
                is_canonical=True,
                logical_key=logical_key,
                event_id=event["id"],
                booking=booking,
                user=user,
            )
            return _vi_receipt_response(
                await (
                    await db.execute(
                        "SELECT * FROM fitness_vi_booking_receipts WHERE id = ?",
                        (str(booking.id),),
                    )
                ).fetchone()
            )

    windows, _stale = await _vi_windows(start=booking.date, end=booking.date, client=vi_client)
    matched = next(
        (
            window
            for window in ((windows or {}).get(booking.date) or [])
            if window.start == booking.start
            and window.end == booking.end
            and window.label == booking.label
            and window.classification == booking.classification
            and (
                required_classification is None or window.classification == required_classification
            )
        ),
        None,
    )
    if matched is None:
        raise ValueError("That Vi class is no longer in the live timetable")

    async with serialized_create(db):
        replay = await _replay_vi_receipt(
            db,
            user=user,
            booking=booking,
            logical_key=logical_key,
        )
        if replay is not None:
            return replay
        # Another entity may have claimed the caller UUID while the public
        # timetable request was in flight. The shared create service validates it.
        event, _replayed = await create_or_replay_calendar_event(
            db,
            event_body(matched.label),
            record_id=str(booking.id),
            user=user,
            client_id=booking.client_id,
            client_timestamp=booking.client_timestamp,
        )
        await _insert_vi_receipt(
            db,
            request_id=str(booking.id),
            canonical_receipt_id=str(booking.id),
            is_canonical=True,
            logical_key=logical_key,
            event_id=event["id"],
            booking=booking,
            user=user,
        )
        return ViBookingResponse(
            event_id=event["id"],
            title=event["title"],
            start_time=event["start_time"],
            end_time=event["end_time"],
            location=event["location"],
            classification=matched.classification,
        )
