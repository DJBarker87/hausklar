"""Deterministic parsing and querying for Example School facility timetables."""

from __future__ import annotations

import hashlib
import io
import json
import re
import uuid
import zipfile
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from xml.etree import ElementTree
from zoneinfo import ZoneInfo

from app.models.facilities import (
    FacilityCalendarLayerItem,
    FacilityCalendarPreferenceResponse,
    FacilityDaySummary,
    FacilityImportChanges,
    FacilityImportCounts,
    FacilityImportPreview,
    FacilityQuickFact,
    FacilitySwimmingBookingCreate,
    FacilitySwimmingBookingResponse,
    FacilityTimeWindow,
    FacilityWeightsBookingCreate,
    FacilityWeightsBookingResponse,
    WeightsRoomAvailability,
)
from app.models.calendar import CalendarEventCreate
from app.models.fitness import PlannedSessionPayload
from app.services.create_records import create_or_replay_calendar_event
from app.services.fitness.planning import upsert_planned_session
from app.services.idempotency import (
    CreateReplayConflictError,
    serialized_create,
)


DOCX_MEDIA_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
MAX_DOCX_ENTRIES = 250
MAX_DOCX_UNCOMPRESSED_BYTES = 20 * 1024 * 1024
MAX_DOCUMENT_XML_BYTES = 5 * 1024 * 1024
MAX_IMPORTED_DAYS = 370
FACILITY_ZONE = ZoneInfo("Europe/London")
_WORD_NAMESPACE = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
_W = f"{{{_WORD_NAMESPACE}}}"
_DATE_POINT = re.compile(
    r"(?:(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+)?"
    r"(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)",
    flags=re.IGNORECASE,
)
_TIME_WINDOW = re.compile(
    r"(?P<start_hour>\d{1,2})[.:](?P<start_minute>\d{2})\s*[-–—]\s*"
    r"(?P<end_hour>\d{1,2})[.:](?P<end_minute>\d{2})"
    r"(?:\s*(?P<label>Family\s+Swimming|Lane\s+Swimming))?",
    flags=re.IGNORECASE,
)


class FacilityImportError(ValueError):
    """Raised when a timetable cannot be imported without guessing."""


@dataclass(frozen=True)
class ParsedFacilityDay:
    local_date: date
    family_swimming: tuple[tuple[str, str], ...]
    lane_swimming: tuple[tuple[str, str], ...]
    weights_room: tuple[tuple[str, str], ...]
    pool_closed: bool
    weights_room_closed: bool
    raw_athens: str
    raw_weights_room: str

    def canonical(self) -> tuple:
        return (
            self.family_swimming,
            self.lane_swimming,
            self.weights_room,
            self.pool_closed,
            self.weights_room_closed,
        )


@dataclass(frozen=True)
class ParsedFacilitySchedule:
    title: str
    filename: str
    sha256: str
    days: tuple[ParsedFacilityDay, ...]

    @property
    def valid_from(self) -> date:
        return self.days[0].local_date

    @property
    def valid_to(self) -> date:
        return self.days[-1].local_date


def _document_xml(data: bytes) -> bytes:
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except (zipfile.BadZipFile, OSError) as exc:
        raise FacilityImportError("That file is not a valid Word document") from exc
    with archive:
        entries = archive.infolist()
        if len(entries) > MAX_DOCX_ENTRIES:
            raise FacilityImportError("The Word document contains too many embedded files")
        if any(entry.flag_bits & 0x1 for entry in entries):
            raise FacilityImportError("Password-protected Word documents are not supported")
        if sum(entry.file_size for entry in entries) > MAX_DOCX_UNCOMPRESSED_BYTES:
            raise FacilityImportError("The expanded Word document is too large")
        try:
            info = archive.getinfo("word/document.xml")
        except KeyError as exc:
            raise FacilityImportError(
                "The Word document has no readable timetable content"
            ) from exc
        if info.file_size > MAX_DOCUMENT_XML_BYTES:
            raise FacilityImportError("The timetable content is too large")
        xml = archive.read(info)
    if b"<!DOCTYPE" in xml.upper() or b"<!ENTITY" in xml.upper():
        raise FacilityImportError("The Word document contains unsupported XML declarations")
    return xml


def _cell_text(cell: ElementTree.Element) -> str:
    paragraphs: list[str] = []
    for paragraph in cell.findall(f".//{_W}p"):
        value = "".join(node.text or "" for node in paragraph.findall(f".//{_W}t"))
        value = re.sub(r"\s+", " ", value).strip()
        if value:
            paragraphs.append(value)
    return "\n".join(paragraphs).strip()


def _table_rows(xml: bytes) -> list[list[str]]:
    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError as exc:
        raise FacilityImportError("The Word document contains invalid XML") from exc
    result: list[list[str]] = []
    for table in root.iter(f"{_W}tbl"):
        rows = list(table.findall(f"{_W}tr"))
        if not rows:
            continue
        header = [_cell_text(cell).strip().lower() for cell in rows[0].findall(f"{_W}tc")]
        if len(header) < 3 or header[:3] != ["date", "athens", "wtr"]:
            continue
        for row in rows[1:]:
            cells = [_cell_text(cell) for cell in row.findall(f"{_W}tc")]
            if any(value.strip() for value in cells):
                result.append((cells + ["", "", ""])[:3])
    if not result:
        raise FacilityImportError("No Date / Athens / WTR timetable table was found")
    return result


def _infer_year(filename: str, explicit_year: int | None) -> int:
    if explicit_year is not None:
        if not 2000 <= explicit_year <= 2100:
            raise FacilityImportError("The timetable year must be between 2000 and 2100")
        return explicit_year
    match = re.search(
        r"\b(?:spring|summer|autumn|fall|winter|term)\s*[-_ ]?(20\d{2}|\d{2})\b",
        filename,
        flags=re.IGNORECASE,
    )
    if not match:
        match = re.search(r"\b(20\d{2})\b", filename)
    if not match:
        raise FacilityImportError(
            "The year is not clear from the filename. Rename it to include the year and try again"
        )
    value = int(match.group(1))
    return 2000 + value if value < 100 else value


def _parse_date_cell(value: str, year: int) -> list[date]:
    points = list(_DATE_POINT.finditer(value.strip()))
    if len(points) not in {1, 2}:
        raise FacilityImportError(f"Could not read timetable date “{value.strip()}”")
    parsed: list[date] = []
    for point in points:
        weekday, day_value, month_value = point.groups()
        try:
            candidate = datetime.strptime(
                f"{int(day_value)} {month_value.title()} {year}", "%d %B %Y"
            ).date()
        except ValueError as exc:
            raise FacilityImportError(f"Could not read timetable date “{value.strip()}”") from exc
        if weekday and candidate.strftime("%A").lower() != weekday.lower():
            raise FacilityImportError(f"Weekday and date do not agree in “{value.strip()}”")
        parsed.append(candidate)
    if len(parsed) == 1:
        return parsed
    start, end = parsed
    if end < start:
        try:
            end = end.replace(year=end.year + 1)
        except ValueError as exc:
            raise FacilityImportError(f"Could not expand timetable date “{value.strip()}”") from exc
    count = (end - start).days + 1
    if count > 31:
        raise FacilityImportError(f"Timetable date range is unexpectedly long in “{value.strip()}”")
    return [start + timedelta(days=offset) for offset in range(count)]


def _normalised_window(match: re.Match[str], raw_value: str) -> tuple[str, str]:
    start_hour = int(match.group("start_hour"))
    start_minute = int(match.group("start_minute"))
    end_hour = int(match.group("end_hour"))
    end_minute = int(match.group("end_minute"))
    try:
        start = time(start_hour, start_minute)
        end = time(end_hour, end_minute)
    except ValueError as exc:
        raise FacilityImportError(f"Invalid time in “{raw_value.strip()}”") from exc
    if end <= start:
        raise FacilityImportError(
            f"End time must be later than start time in “{raw_value.strip()}”"
        )
    return start.strftime("%H:%M"), end.strftime("%H:%M")


def _unparsed_text(value: str, matches: list[re.Match[str]]) -> str:
    pieces: list[str] = []
    cursor = 0
    for match in matches:
        pieces.append(value[cursor : match.start()])
        cursor = match.end()
    pieces.append(value[cursor:])
    remainder = " ".join(pieces)
    remainder = re.sub(r"\bclosed\b", "", remainder, flags=re.IGNORECASE)
    return re.sub(r"[\s,;|/]+", "", remainder)


def _parse_athens(
    value: str,
) -> tuple[tuple[tuple[str, str], ...], tuple[tuple[str, str], ...], bool]:
    matches = list(_TIME_WINDOW.finditer(value))
    closed = bool(re.search(r"\bclosed\b", value, flags=re.IGNORECASE))
    if closed and matches:
        raise FacilityImportError(f"Athens is both closed and timed in “{value.strip()}”")
    if not closed and not matches:
        raise FacilityImportError(f"No Athens opening state was found in “{value.strip()}”")
    family: list[tuple[str, str]] = []
    lane: list[tuple[str, str]] = []
    for match in matches:
        label = re.sub(r"\s+", " ", (match.group("label") or "").strip()).lower()
        if label == "family swimming":
            family.append(_normalised_window(match, value))
        elif label == "lane swimming":
            lane.append(_normalised_window(match, value))
        else:
            raise FacilityImportError(f"Swimming type is missing in “{value.strip()}”")
    if _unparsed_text(value, matches):
        raise FacilityImportError(f"Unrecognised Athens text in “{value.strip()}”")
    return tuple(sorted(family)), tuple(sorted(lane)), closed


def _parse_weights(value: str) -> tuple[tuple[tuple[str, str], ...], bool]:
    matches = list(_TIME_WINDOW.finditer(value))
    closed = bool(re.search(r"\bclosed\b", value, flags=re.IGNORECASE))
    if closed and matches:
        raise FacilityImportError(f"WTR is both closed and timed in “{value.strip()}”")
    if not closed and not matches:
        raise FacilityImportError(f"No WTR opening state was found in “{value.strip()}”")
    if any(match.group("label") for match in matches) or _unparsed_text(value, matches):
        raise FacilityImportError(f"Unrecognised WTR text in “{value.strip()}”")
    return tuple(sorted(_normalised_window(match, value) for match in matches)), closed


def parse_example_school_timetable(
    data: bytes,
    *,
    filename: str,
    year: int | None = None,
) -> ParsedFacilitySchedule:
    """Parse the known three-column timetable without running Office or model code."""
    if not filename.lower().endswith(".docx"):
        raise FacilityImportError("Choose the Example School timetable as a .docx Word document")
    if not data:
        raise FacilityImportError("The uploaded timetable is empty")
    parsed_year = _infer_year(filename, year)
    by_date: dict[date, ParsedFacilityDay] = {}
    for date_text, athens_text, weights_text in _table_rows(_document_xml(data)):
        family, lane, pool_closed = _parse_athens(athens_text)
        weights, weights_closed = _parse_weights(weights_text)
        for local_date in _parse_date_cell(date_text, parsed_year):
            item = ParsedFacilityDay(
                local_date=local_date,
                family_swimming=family,
                lane_swimming=lane,
                weights_room=weights,
                pool_closed=pool_closed,
                weights_room_closed=weights_closed,
                raw_athens=athens_text.strip(),
                raw_weights_room=weights_text.strip(),
            )
            previous = by_date.get(local_date)
            if previous and previous.canonical() != item.canonical():
                raise FacilityImportError(
                    f"The timetable contains conflicting entries for {local_date.isoformat()}"
                )
            by_date[local_date] = item
    if not by_date:
        raise FacilityImportError("The timetable contains no dated availability")
    if len(by_date) > MAX_IMPORTED_DAYS:
        raise FacilityImportError("The timetable contains too many days")
    ordered = tuple(by_date[value] for value in sorted(by_date))
    title = Path(filename).stem.strip()[:300] or "Example School facilities timetable"
    return ParsedFacilitySchedule(
        title=title,
        filename=Path(filename).name[:180],
        sha256=hashlib.sha256(data).hexdigest(),
        days=ordered,
    )


def schedule_counts(schedule: ParsedFacilitySchedule) -> FacilityImportCounts:
    return FacilityImportCounts(
        days=len(schedule.days),
        family_swimming_sessions=sum(len(item.family_swimming) for item in schedule.days),
        lane_swimming_sessions=sum(len(item.lane_swimming) for item in schedule.days),
        weights_room_open_days=sum(bool(item.weights_room) for item in schedule.days),
        pool_closed_days=sum(item.pool_closed for item in schedule.days),
        weights_room_closed_days=sum(item.weights_room_closed for item in schedule.days),
    )


def _decode_windows(value: str | None) -> list[FacilityTimeWindow]:
    try:
        raw = json.loads(value or "[]")
    except (json.JSONDecodeError, TypeError):
        return []
    return [
        FacilityTimeWindow(start=item[0], end=item[1])
        for item in raw
        if isinstance(item, list) and len(item) == 2 and all(isinstance(part, str) for part in item)
    ]


def _summary_from_parsed(item: ParsedFacilityDay) -> FacilityDaySummary:
    return FacilityDaySummary(
        date=item.local_date,
        covered=True,
        family_swimming=[
            FacilityTimeWindow(start=start, end=end) for start, end in item.family_swimming
        ],
        lane_swimming=[
            FacilityTimeWindow(start=start, end=end) for start, end in item.lane_swimming
        ],
        weights_room=[FacilityTimeWindow(start=start, end=end) for start, end in item.weights_room],
        pool_closed=item.pool_closed,
        weights_room_status="open" if item.weights_room else "closed",
        weights_relevant=True,
    )


async def current_day_rows(db, *, family_id: str, start: date, end: date) -> dict[str, dict]:
    if end < start or (end - start).days > MAX_IMPORTED_DAYS:
        raise ValueError("Facility availability range must be 370 days or fewer")
    cursor = await db.execute(
        """
        SELECT d.*, v.title AS source_title, v.source_document_id,
               v.personal_owner_user_id, v.valid_from, v.valid_to,
               v.created_at AS version_created_at
        FROM facility_schedule_days d
        JOIN facility_schedule_versions v ON v.id = d.version_id
        WHERE d.family_id = ? AND v.family_id = ?
          AND d.deleted_at IS NULL AND v.deleted_at IS NULL
          AND v.status = 'confirmed' AND d.local_date BETWEEN ? AND ?
        ORDER BY v.created_at DESC, v.id DESC, d.local_date
        """,
        (family_id, family_id, start.isoformat(), end.isoformat()),
    )
    result: dict[str, dict] = {}
    for row in await cursor.fetchall():
        item = dict(row)
        result.setdefault(item["local_date"], item)
    return result


def day_summary(day: date, row: dict | None, *, user_id: str) -> FacilityDaySummary:
    if row is None:
        return FacilityDaySummary(date=day, covered=False, weights_room_status="unknown")
    personal = row["personal_owner_user_id"] == user_id
    weights = _decode_windows(row["weights_room_json"]) if personal else []
    if not personal:
        weights_status = "not_relevant"
    elif weights:
        weights_status = "open"
    elif bool(row["weights_room_closed"]):
        weights_status = "closed"
    else:
        weights_status = "unknown"
    return FacilityDaySummary(
        date=day,
        covered=True,
        family_swimming=_decode_windows(row["family_swimming_json"]),
        lane_swimming=_decode_windows(row["lane_swimming_json"]) if personal else [],
        weights_room=weights,
        pool_closed=bool(row["pool_closed"]),
        weights_room_status=weights_status,
        weights_relevant=personal,
    )


async def quick_fact(
    db,
    *,
    family_id: str,
    user_id: str,
    reference_date: date,
) -> FacilityQuickFact:
    tomorrow = reference_date + timedelta(days=1)
    rows = await current_day_rows(db, family_id=family_id, start=reference_date, end=tomorrow)
    source_row = rows.get(reference_date.isoformat()) or rows.get(tomorrow.isoformat())
    if source_row is None:
        source_cursor = await db.execute(
            """
            SELECT title AS source_title, source_document_id, valid_from, valid_to
            FROM facility_schedule_versions
            WHERE family_id = ? AND provider_key = 'school_college'
              AND status = 'confirmed' AND deleted_at IS NULL
            ORDER BY CASE WHEN valid_to >= ? THEN 0 ELSE 1 END,
                     CASE WHEN valid_to >= ? THEN valid_from END,
                     created_at DESC
            LIMIT 1
            """,
            (family_id, reference_date.isoformat(), reference_date.isoformat()),
        )
        fetched = await source_cursor.fetchone()
        source_row = dict(fetched) if fetched else None
    current_to = date.fromisoformat(source_row["valid_to"]) if source_row else None
    return FacilityQuickFact(
        source_title=source_row["source_title"] if source_row else None,
        source_document_id=source_row["source_document_id"] if source_row else None,
        current_from=date.fromisoformat(source_row["valid_from"]) if source_row else None,
        current_to=current_to,
        update_due=current_to is None or current_to <= reference_date + timedelta(days=14),
        today=day_summary(reference_date, rows.get(reference_date.isoformat()), user_id=user_id),
        tomorrow=day_summary(tomorrow, rows.get(tomorrow.isoformat()), user_id=user_id),
    )


async def timetable_days(
    db,
    *,
    family_id: str,
    user_id: str,
    start: date,
    days: int = 14,
) -> list[FacilityDaySummary]:
    """Return an on-demand run of facility times without changing calendar layers."""
    if days < 1 or days > 14:
        raise ValueError("Facility timetable must cover between 1 and 14 days")
    end = start + timedelta(days=days - 1)
    rows = await current_day_rows(db, family_id=family_id, start=start, end=end)
    return [
        day_summary(
            start + timedelta(days=offset),
            rows.get((start + timedelta(days=offset)).isoformat()),
            user_id=user_id,
        )
        for offset in range(days)
    ]


async def create_swimming_booking(
    db,
    *,
    user: dict,
    booking: FacilitySwimmingBookingCreate,
) -> tuple[FacilitySwimmingBookingResponse, bool]:
    """Add a confirmed family-swimming booking to the normal family calendar."""
    rows = await current_day_rows(
        db,
        family_id=user["family_id"],
        start=booking.date,
        end=booking.date,
    )
    row = rows.get(booking.date.isoformat())
    if row is None:
        raise ValueError("No confirmed Example School timetable covers that date")

    booked_start = time.fromisoformat(booking.start)
    booked_end = time.fromisoformat(booking.end)
    windows = _decode_windows(row["family_swimming_json"])
    if not any(
        time.fromisoformat(window.start) <= booked_start
        and booked_end <= time.fromisoformat(window.end)
        for window in windows
    ):
        raise ValueError("Booked times must fit within one family-swimming window")

    start_time = datetime.combine(booking.date, booked_start, tzinfo=FACILITY_ZONE).isoformat()
    end_time = datetime.combine(booking.date, booked_end, tzinfo=FACILITY_ZONE).isoformat()
    event, _replayed = await create_or_replay_calendar_event(
        db,
        CalendarEventCreate(
            id=booking.id,
            title="Swimming",
            start_time=start_time,
            end_time=end_time,
            all_day=False,
            location="Example School College",
            family_member_ids=None,
            event_type="activity",
            source_document_id=row["source_document_id"],
            client_id=booking.client_id,
            client_timestamp=booking.client_timestamp,
        ),
        record_id=str(booking.id),
        user=user,
        client_id=booking.client_id,
        client_timestamp=booking.client_timestamp,
    )
    return (
        FacilitySwimmingBookingResponse(
            event_id=event["id"],
            start_time=event["start_time"],
            end_time=event["end_time"],
        ),
        _replayed,
    )


def _weights_booking_response(row) -> FacilityWeightsBookingResponse:
    start_utc = datetime.fromisoformat(str(row["scheduled_start_utc"]).replace("Z", "+00:00"))
    if start_utc.tzinfo is None:
        start_utc = start_utc.replace(tzinfo=timezone.utc)
    local_start = start_utc.astimezone(FACILITY_ZONE)
    local_end = local_start + timedelta(seconds=int(row["expected_duration_s"]))
    return FacilityWeightsBookingResponse(
        planned_session_id=row["id"],
        start_time=local_start.isoformat(),
        end_time=local_end.isoformat(),
    )


def _weights_booking_matches(
    row,
    *,
    user: dict,
    booking: FacilityWeightsBookingCreate,
) -> bool:
    booked_start = datetime.combine(
        booking.date,
        time.fromisoformat(booking.start),
        tzinfo=FACILITY_ZONE,
    ).astimezone(timezone.utc)
    stored_start = datetime.fromisoformat(str(row["scheduled_start_utc"]).replace("Z", "+00:00"))
    if stored_start.tzinfo is None:
        stored_start = stored_start.replace(tzinfo=timezone.utc)
    duration_s = int(
        (
            datetime.combine(
                booking.date,
                time.fromisoformat(booking.end),
                tzinfo=FACILITY_ZONE,
            )
            - datetime.combine(
                booking.date,
                time.fromisoformat(booking.start),
                tzinfo=FACILITY_ZONE,
            )
        ).total_seconds()
    )
    return (
        row["deleted_at"] is None
        and row["family_id"] == user["family_id"]
        and row["owner_user_id"] == user["id"]
        and row["created_by"] == user["id"]
        and row["sport_key"] == "strength"
        and row["title"] == "Strength"
        and row["session_source"] == "user"
        and row["local_timezone"] == "Europe/London"
        and stored_start.astimezone(timezone.utc) == booked_start
        and row["scheduled_date"] == booking.date.isoformat()
        and int(row["expected_duration_s"] or 0) == duration_s
        and not bool(row["movable"])
        and row["visibility"] == "private"
    )


async def _replay_weights_booking(
    db,
    *,
    user: dict,
    booking: FacilityWeightsBookingCreate,
) -> FacilityWeightsBookingResponse | None:
    row = await (
        await db.execute(
            "SELECT * FROM health_planned_sessions WHERE id = ?",
            (str(booking.id),),
        )
    ).fetchone()
    if row is None:
        return None
    if not _weights_booking_matches(row, user=user, booking=booking):
        raise CreateReplayConflictError(
            "Create operation ID was already used for a different request"
        )
    return _weights_booking_response(row)


async def create_weights_booking(
    db,
    *,
    user: dict,
    booking: FacilityWeightsBookingCreate,
) -> tuple[FacilityWeightsBookingResponse, bool]:
    """Turn one private weights-room window into one startable strength plan."""
    replay = await _replay_weights_booking(db, user=user, booking=booking)
    if replay is not None:
        return replay, True

    rows = await current_day_rows(
        db,
        family_id=user["family_id"],
        start=booking.date,
        end=booking.date,
    )
    row = rows.get(booking.date.isoformat())
    if row is None:
        raise ValueError("No confirmed Example School timetable covers that date")
    if row["personal_owner_user_id"] != user["id"]:
        raise ValueError("Weights-room times are private to their timetable owner")

    booked_start = time.fromisoformat(booking.start)
    booked_end = time.fromisoformat(booking.end)
    windows = _decode_windows(row["weights_room_json"])
    if not any(
        time.fromisoformat(window.start) <= booked_start
        and booked_end <= time.fromisoformat(window.end)
        for window in windows
    ):
        raise ValueError("Strength times must fit within one weights-room window")

    local_start = datetime.combine(
        booking.date,
        booked_start,
        tzinfo=FACILITY_ZONE,
    )
    local_end = datetime.combine(
        booking.date,
        booked_end,
        tzinfo=FACILITY_ZONE,
    )
    async with serialized_create(db):
        replay = await _replay_weights_booking(db, user=user, booking=booking)
        if replay is not None:
            return replay, True
        await upsert_planned_session(
            db,
            user=user,
            body=PlannedSessionPayload(
                id=booking.id,
                sport_key="strength",
                title="Strength",
                local_timezone="Europe/London",
                status="scheduled",
                session_source="user",
                scheduled_start_utc=local_start.astimezone(timezone.utc),
                scheduled_date=booking.date,
                expected_duration_s=int((local_end - local_start).total_seconds()),
                movable=False,
                visibility="private",
                reason_for_placement="Example School weights room",
                client_id=booking.client_id,
                client_timestamp=booking.client_timestamp,
            ),
        )
        created = await (
            await db.execute(
                "SELECT * FROM health_planned_sessions WHERE id = ?",
                (str(booking.id),),
            )
        ).fetchone()
        if created is None:
            raise RuntimeError("Strength plan insert did not return a row")
        return _weights_booking_response(created), False


async def calendar_preferences(db, *, user: dict) -> FacilityCalendarPreferenceResponse:
    row = await (
        await db.execute(
            "SELECT show_family_swimming, show_personal_facilities "
            "FROM facility_calendar_preferences WHERE family_id = ? AND user_id = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    return FacilityCalendarPreferenceResponse(
        show_family_swimming=bool(row["show_family_swimming"]) if row else False,
        show_personal_facilities=bool(row["show_personal_facilities"]) if row else False,
    )


async def update_calendar_preferences(
    db,
    *,
    user: dict,
    show_family_swimming: bool | None,
    show_personal_facilities: bool | None,
) -> FacilityCalendarPreferenceResponse:
    current = await calendar_preferences(db, user=user)
    family_value = (
        current.show_family_swimming if show_family_swimming is None else show_family_swimming
    )
    personal_value = (
        current.show_personal_facilities
        if show_personal_facilities is None
        else show_personal_facilities
    )
    now = datetime.now(tz=ZoneInfo("UTC")).isoformat()
    row = await (
        await db.execute(
            "SELECT id FROM facility_calendar_preferences WHERE user_id = ? "
            "AND family_id = ? AND deleted_at IS NULL",
            (user["id"], user["family_id"]),
        )
    ).fetchone()
    if row:
        await db.execute(
            "UPDATE facility_calendar_preferences SET show_family_swimming = ?, "
            "show_personal_facilities = ?, updated_at = ?, client_timestamp = ? "
            "WHERE id = ?",
            (int(family_value), int(personal_value), now, now, row["id"]),
        )
    else:
        await db.execute(
            """
            INSERT INTO facility_calendar_preferences (
                id, user_id, show_family_swimming, show_personal_facilities,
                family_id, created_at, updated_at, created_by, client_timestamp
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                user["id"],
                int(family_value),
                int(personal_value),
                user["family_id"],
                now,
                now,
                user["id"],
                now,
            ),
        )
    return FacilityCalendarPreferenceResponse(
        show_family_swimming=family_value,
        show_personal_facilities=personal_value,
    )


def _local_datetime(day_value: str, clock: str) -> str:
    return datetime.combine(
        date.fromisoformat(day_value), time.fromisoformat(clock), tzinfo=FACILITY_ZONE
    ).isoformat()


async def calendar_layer(
    db,
    *,
    user: dict,
    start: date,
    end: date,
) -> list[FacilityCalendarLayerItem]:
    preference = await calendar_preferences(db, user=user)
    if not preference.show_family_swimming and not preference.show_personal_facilities:
        return []
    rows = await current_day_rows(db, family_id=user["family_id"], start=start, end=end)
    result: list[FacilityCalendarLayerItem] = []
    for day_value, row in sorted(rows.items()):
        groups: list[tuple[str, str, list[FacilityTimeWindow], str | None]] = []
        if preference.show_family_swimming:
            groups.append(
                (
                    "family_swimming",
                    "Family swimming",
                    _decode_windows(row["family_swimming_json"]),
                    None,
                )
            )
        if preference.show_personal_facilities and row["personal_owner_user_id"] == user["id"]:
            groups.extend(
                (
                    (
                        "lane_swimming",
                        "Lane swimming",
                        _decode_windows(row["lane_swimming_json"]),
                        user["id"],
                    ),
                    (
                        "weights_room",
                        "Weights room",
                        _decode_windows(row["weights_room_json"]),
                        user["id"],
                    ),
                )
            )
        for kind, title, windows, owner_user_id in groups:
            for index, window in enumerate(windows):
                result.append(
                    FacilityCalendarLayerItem(
                        id=f"{row['id']}:{kind}:{index}",
                        layer_kind=kind,
                        display_title=title,
                        start_time=_local_datetime(day_value, window.start),
                        end_time=_local_datetime(day_value, window.end),
                        owner_user_id=owner_user_id,
                        source_document_id=row["source_document_id"],
                        source_title=row["source_title"],
                    )
                )
    return result


async def weights_room_availability(
    db,
    *,
    user: dict,
    start: date,
    end: date,
) -> WeightsRoomAvailability:
    rows = await current_day_rows(db, family_id=user["family_id"], start=start, end=end)
    relevant_rows = {
        day_value: row
        for day_value, row in rows.items()
        if row["personal_owner_user_id"] == user["id"]
    }
    source = next(iter(relevant_rows.values()), None)
    days: list[FacilityDaySummary] = []
    cursor = start
    while cursor <= end:
        summary = day_summary(cursor, relevant_rows.get(cursor.isoformat()), user_id=user["id"])
        if summary.covered:
            days.append(summary)
        cursor += timedelta(days=1)
    return WeightsRoomAvailability(
        relevant=bool(relevant_rows),
        source_title=source["source_title"] if source else None,
        source_document_id=source["source_document_id"] if source else None,
        current_to=date.fromisoformat(source["valid_to"]) if source else None,
        days=days,
    )


async def _preview_changes(
    db,
    *,
    family_id: str,
    schedule: ParsedFacilitySchedule,
) -> FacilityImportChanges:
    previous = await current_day_rows(
        db,
        family_id=family_id,
        start=schedule.valid_from,
        end=schedule.valid_to,
    )
    current_by_date = {item.local_date.isoformat(): item for item in schedule.days}
    added = sum(day_value not in previous for day_value in current_by_date)
    changed = 0
    for day_value, item in current_by_date.items():
        row = previous.get(day_value)
        if row is None:
            continue
        previous_value = (
            tuple(
                (window.start, window.end)
                for window in _decode_windows(row["family_swimming_json"])
            ),
            tuple(
                (window.start, window.end) for window in _decode_windows(row["lane_swimming_json"])
            ),
            tuple(
                (window.start, window.end) for window in _decode_windows(row["weights_room_json"])
            ),
            bool(row["pool_closed"]),
            bool(row["weights_room_closed"]),
        )
        changed += previous_value != item.canonical()
    removed = sum(day_value not in current_by_date for day_value in previous)
    return FacilityImportChanges(added_days=added, changed_days=changed, removed_days=removed)


async def import_preview(
    db,
    *,
    family_id: str,
    schedule: ParsedFacilitySchedule,
) -> FacilityImportPreview:
    row = await (
        await db.execute(
            "SELECT id FROM facility_schedule_versions WHERE family_id = ? "
            "AND provider_key = 'school_college' AND source_sha256 = ? AND deleted_at IS NULL",
            (family_id, schedule.sha256),
        )
    ).fetchone()
    indices = list(range(min(3, len(schedule.days))))
    indices.extend(range(max(3, len(schedule.days) - 3), len(schedule.days)))
    sample = [_summary_from_parsed(schedule.days[index]) for index in dict.fromkeys(indices)]
    return FacilityImportPreview(
        filename=schedule.filename,
        title=schedule.title,
        sha256=schedule.sha256,
        valid_from=schedule.valid_from,
        valid_to=schedule.valid_to,
        counts=schedule_counts(schedule),
        changes=await _preview_changes(db, family_id=family_id, schedule=schedule),
        sample_days=sample,
        issues=[],
        already_imported=row is not None,
        can_confirm=row is None,
    )


def extracted_schedule_text(schedule: ParsedFacilitySchedule) -> str:
    lines = [schedule.title]
    for item in schedule.days:
        lines.append(
            f"{item.local_date.isoformat()} | Athens: {item.raw_athens} | "
            f"WTR: {item.raw_weights_room}"
        )
    return "\n".join(lines)[:150_000]


async def insert_schedule(
    db,
    *,
    schedule: ParsedFacilitySchedule,
    version_id: str,
    document_id: str,
    user: dict,
    now: str,
    personal_owner_user_id: str,
) -> None:
    await db.execute(
        """
        INSERT INTO facility_schedule_versions (
            id, provider_key, title, source_document_id, personal_owner_user_id,
            valid_from, valid_to, source_sha256, day_count, status, family_id,
            created_at, updated_at, created_by, client_timestamp
        ) VALUES (?, 'school_college', ?, ?, ?, ?, ?, ?, ?, 'confirmed', ?, ?, ?, ?, ?)
        """,
        (
            version_id,
            schedule.title,
            document_id,
            personal_owner_user_id,
            schedule.valid_from.isoformat(),
            schedule.valid_to.isoformat(),
            schedule.sha256,
            len(schedule.days),
            user["family_id"],
            now,
            now,
            user["id"],
            now,
        ),
    )
    await db.executemany(
        """
        INSERT INTO facility_schedule_days (
            id, version_id, local_date, family_swimming_json, lane_swimming_json,
            weights_room_json, pool_closed, weights_room_closed, raw_athens,
            raw_weights_room, family_id, created_at, updated_at, created_by,
            client_timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (
                str(uuid.uuid4()),
                version_id,
                item.local_date.isoformat(),
                json.dumps(item.family_swimming, separators=(",", ":")),
                json.dumps(item.lane_swimming, separators=(",", ":")),
                json.dumps(item.weights_room, separators=(",", ":")),
                int(item.pool_closed),
                int(item.weights_room_closed),
                item.raw_athens,
                item.raw_weights_room,
                user["family_id"],
                now,
                now,
                user["id"],
                now,
            )
            for item in schedule.days
        ],
    )
