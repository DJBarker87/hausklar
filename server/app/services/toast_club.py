"""Deterministic Toast Club form import and club-aware pickup windows."""

from __future__ import annotations

import hashlib
import io
import re
import uuid
import zipfile
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from xml.etree import ElementTree
from zoneinfo import ZoneInfo

from app.models.calendar import CalendarEventResponse
from app.models.managed_projection import ManagedSource
from app.models.toast_club import (
    ToastImportChanges,
    ToastImportPreview,
    ToastImportResult,
    ToastImportStatus,
)
from app.services import school_clubs


TOAST_ZONE = ZoneInfo("Europe/London")
MAX_DOCX_ENTRIES = 250
MAX_DOCX_UNCOMPRESSED_BYTES = 20 * 1024 * 1024
MAX_DOCUMENT_XML_BYTES = 5 * 1024 * 1024
MAX_FORM_DAYS = 150
_WORD_NAMESPACE = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
_W = f"{{{_WORD_NAMESPACE}}}"
_TITLE = re.compile(
    r"TOAST\s+TERMLY\s+(AUTUMN|SPRING|SUMMER|WINTER)\s+(20\d{2})",
    flags=re.IGNORECASE,
)
_DOB = re.compile(r"\b(\d{1,2})/(\d{1,2})/(20\d{2})\b")
_DATE = re.compile(
    r"^(Mon|Monday|Tue|Tues|Tuesday|Wed|Wednesday|Thu|Thur|Thurs|Thursday|Fri|Friday)"
    r"\s+(\d{1,2})\s+([A-Za-z]{3,9})$",
    flags=re.IGNORECASE,
)
_WEEKDAYS = (0, 1, 2, 3, 4)


class ToastImportError(ValueError):
    """Raised when a booking form cannot be normalised without guessing."""


@dataclass(frozen=True)
class ParsedToastDay:
    local_date: date
    session_code: str | None
    pickup_end: str | None


@dataclass(frozen=True)
class ParsedToastSchedule:
    source_title: str
    sha256: str
    date_of_birth: date
    base_start_time: str
    days: tuple[ParsedToastDay, ...]

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
        raise ToastImportError("That file is not a valid Word document") from exc
    with archive:
        entries = archive.infolist()
        if len(entries) > MAX_DOCX_ENTRIES:
            raise ToastImportError("The Word document contains too many embedded files")
        if any(entry.flag_bits & 0x1 for entry in entries):
            raise ToastImportError("Password-protected Word documents are not supported")
        if sum(entry.file_size for entry in entries) > MAX_DOCX_UNCOMPRESSED_BYTES:
            raise ToastImportError("The expanded Word document is too large")
        try:
            info = archive.getinfo("word/document.xml")
        except KeyError as exc:
            raise ToastImportError("The Word document has no readable booking form") from exc
        if info.file_size > MAX_DOCUMENT_XML_BYTES:
            raise ToastImportError("The booking form content is too large")
        xml = archive.read(info)
    if b"<!DOCTYPE" in xml.upper() or b"<!ENTITY" in xml.upper():
        raise ToastImportError("The Word document contains unsupported XML declarations")
    return xml


def _paragraphs(xml: bytes) -> list[str]:
    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError as exc:
        raise ToastImportError("The Word document contains invalid XML") from exc
    result: list[str] = []
    for paragraph in root.iter(f"{_W}p"):
        value = "".join(node.text or "" for node in paragraph.iter(f"{_W}t"))
        result.append(re.sub(r"\s+", " ", value).strip())
    return result


def _parse_form_date(value: str, year: int) -> date | None:
    match = _DATE.fullmatch(re.sub(r"\s+", " ", value.strip()))
    if not match:
        return None
    weekday, day_value, month_value = match.groups()
    try:
        parsed = datetime.strptime(
            f"{int(day_value)} {month_value.title()} {year}", "%d %B %Y"
        ).date()
    except ValueError:
        try:
            parsed = datetime.strptime(
                f"{int(day_value)} {month_value.title()} {year}", "%d %b %Y"
            ).date()
        except ValueError as exc:
            raise ToastImportError(f"Could not read Toast date “{value.strip()}”") from exc
    expected = {
        "mon": 0,
        "monday": 0,
        "tue": 1,
        "tues": 1,
        "tuesday": 1,
        "wed": 2,
        "wednesday": 2,
        "thu": 3,
        "thur": 3,
        "thurs": 3,
        "thursday": 3,
        "fri": 4,
        "friday": 4,
    }[weekday.lower()]
    if parsed.weekday() != expected:
        raise ToastImportError(f"Weekday and date do not agree in “{value.strip()}”")
    return parsed


def _week_at(paragraphs: list[str], index: int, year: int) -> tuple[date, ...] | None:
    if index + 5 > len(paragraphs):
        return None
    parsed = tuple(_parse_form_date(paragraphs[index + offset], year) for offset in range(5))
    if any(item is None for item in parsed):
        return None
    dates = tuple(item for item in parsed if item is not None)
    if tuple(item.weekday() for item in dates) != _WEEKDAYS:
        return None
    if any((dates[offset + 1] - dates[offset]).days != 1 for offset in range(4)):
        raise ToastImportError("Toast form weekdays are not consecutive")
    return dates


def _normal_status(value: str) -> str:
    normal = re.sub(r"\s+", " ", value.strip()).upper()
    if normal in {"", "1", "2", "NO TOAST", "HALF TERM"}:
        return normal
    raise ToastImportError(f"Unrecognised Toast booking value “{value.strip()}”")


def _instruction_times(text: str) -> tuple[str, dict[str, str]]:
    normal = re.sub(r"\s+", " ", text)
    if not re.search(r"\b1\b.{0,100}?4[.:]30\s*(?:pm)?", normal, re.IGNORECASE):
        raise ToastImportError("The form does not define Toast session 1")
    if not re.search(r"\b2\b.{0,100}?5[.:]30\s*(?:pm)?", normal, re.IGNORECASE):
        raise ToastImportError("The form does not define Toast session 2")
    ends = {"1": "16:30", "2": "17:30"}
    starts = []
    for code, end_value in ends.items():
        end = datetime.combine(date.min, time.fromisoformat(end_value))
        starts.append((end - timedelta(hours=int(code))).time().strftime("%H:%M"))
    if len(set(starts)) != 1:
        raise ToastImportError("Toast session times do not share one start time")
    return starts[0], ends


def parse_booking_form(data: bytes, *, filename: str) -> ParsedToastSchedule:
    if not filename.lower().endswith(".docx"):
        raise ToastImportError("Choose the Toast booking form as a .docx file")
    if not data:
        raise ToastImportError("The uploaded booking form is empty")
    paragraphs = _paragraphs(_document_xml(data))
    full_text = " ".join(value for value in paragraphs if value)
    title_match = _TITLE.search(full_text)
    if not title_match:
        raise ToastImportError("No Toast term title and year were found")
    term_name, year_value = title_match.groups()
    year = int(year_value)
    dob_match = _DOB.search(full_text)
    if not dob_match:
        raise ToastImportError("No child date of birth was found on the Toast form")
    try:
        date_of_birth = date(
            int(dob_match.group(3)), int(dob_match.group(2)), int(dob_match.group(1))
        )
    except ValueError as exc:
        raise ToastImportError("The child date of birth on the Toast form is invalid") from exc
    base_start, ends = _instruction_times(full_text)

    weeks: list[tuple[int, tuple[date, ...]]] = []
    index = 0
    while index < len(paragraphs):
        week = _week_at(paragraphs, index, year)
        if week is None:
            index += 1
            continue
        weeks.append((index, week))
        index += 5
    if not weeks:
        raise ToastImportError("No Monday-to-Friday Toast booking rows were found")

    parsed_days: dict[date, ParsedToastDay] = {}
    footer_index = next(
        (i for i, value in enumerate(paragraphs) if value.lower().startswith("total number of hours")),
        len(paragraphs),
    )
    for week_index, (start_index, dates) in enumerate(weeks):
        status_start = start_index + 5
        status_end = weeks[week_index + 1][0] if week_index + 1 < len(weeks) else footer_index
        raw_statuses = paragraphs[status_start:status_end]
        statuses = [_normal_status(value) for value in raw_statuses]
        if any(value in {"1", "2"} for value in statuses):
            if len(statuses) < 5:
                raise ToastImportError("A Toast booking week has missing weekday cells")
            weekday_statuses = statuses[:5]
            if any(value not in {""} for value in statuses[5:]):
                raise ToastImportError("A Toast booking week has extra values")
        else:
            # Half-term rows in the supplied form use two lines per weekday.
            # With no numeric session there is no booking to infer.
            weekday_statuses = ["", "", "", "", ""]
        for local_date, status in zip(dates, weekday_statuses, strict=True):
            code = status if status in {"1", "2"} else None
            day = ParsedToastDay(
                local_date=local_date,
                session_code=code,
                pickup_end=ends.get(code) if code else None,
            )
            previous = parsed_days.get(local_date)
            if previous is not None and previous != day:
                raise ToastImportError(f"Conflicting Toast entries for {local_date.isoformat()}")
            parsed_days[local_date] = day
    if not 1 <= len(parsed_days) <= MAX_FORM_DAYS:
        raise ToastImportError("The Toast booking form contains an unexpected number of days")
    if not any(item.session_code for item in parsed_days.values()):
        raise ToastImportError("The Toast booking form contains no booked sessions")
    source_title = f"Toast {term_name.title()} {year}"
    return ParsedToastSchedule(
        source_title=source_title,
        sha256=hashlib.sha256(data).hexdigest(),
        date_of_birth=date_of_birth,
        base_start_time=base_start,
        days=tuple(sorted(parsed_days.values(), key=lambda item: item.local_date)),
    )


async def _resolve_child(
    db,
    *,
    family_id: str,
    schedule: ParsedToastSchedule,
    requested_child_id: str | None,
):
    if requested_child_id:
        row = await (
            await db.execute(
                "SELECT id, name, date_of_birth FROM children WHERE id = ? AND family_id = ? "
                "AND deleted_at IS NULL",
                (requested_child_id, family_id),
            )
        ).fetchone()
        if row is None:
            raise ToastImportError("Toast child is not in this family")
        if row["date_of_birth"] != schedule.date_of_birth.isoformat():
            raise ToastImportError("The selected child does not match the booking form")
        return row
    rows = await (
        await db.execute(
            "SELECT id, name, date_of_birth FROM children WHERE family_id = ? "
            "AND date_of_birth = ? AND deleted_at IS NULL",
            (family_id, schedule.date_of_birth.isoformat()),
        )
    ).fetchall()
    if len(rows) != 1:
        raise ToastImportError("No child in this family uniquely matches the booking form")
    return rows[0]


async def _effective_days(
    db,
    *,
    family_id: str,
    child_id: str | None,
    start: date,
    end: date,
) -> dict[tuple[str, date], dict]:
    query = (
        "SELECT d.*, i.source_title, i.base_start_time, i.created_at AS imported_at, "
        "i.updated_at AS import_updated_at, i.created_by AS import_created_by "
        "FROM toast_club_import_days d JOIN toast_club_imports i ON i.id = d.import_id "
        "AND i.family_id = d.family_id AND i.deleted_at IS NULL "
        "WHERE d.family_id = ? AND d.booking_date >= ? AND d.booking_date <= ? "
        "AND d.deleted_at IS NULL"
    )
    params: list[str] = [family_id, start.isoformat(), end.isoformat()]
    if child_id:
        query += " AND d.child_id = ?"
        params.append(child_id)
    query += " ORDER BY i.created_at, i.id"
    rows = await (await db.execute(query, params)).fetchall()
    result: dict[tuple[str, date], dict] = {}
    for row in rows:
        result[(row["child_id"], date.fromisoformat(row["booking_date"]))] = dict(row)
    return result


async def import_preview(
    db,
    *,
    family_id: str,
    schedule: ParsedToastSchedule,
    requested_child_id: str | None = None,
) -> ToastImportPreview:
    child = await _resolve_child(
        db,
        family_id=family_id,
        schedule=schedule,
        requested_child_id=requested_child_id,
    )
    current = await _effective_days(
        db,
        family_id=family_id,
        child_id=child["id"],
        start=schedule.valid_from,
        end=schedule.valid_to,
    )
    counts = {"added": 0, "changed": 0, "removed": 0, "unchanged": 0}
    for day in schedule.days:
        prior = current.get((child["id"], day.local_date))
        prior_code = prior["session_code"] if prior else None
        if prior_code == day.session_code:
            counts["unchanged"] += 1
        elif prior_code is None and day.session_code is not None:
            counts["added"] += 1
        elif prior_code is not None and day.session_code is None:
            counts["removed"] += 1
        else:
            counts["changed"] += 1
    duplicate = await (
        await db.execute(
            "SELECT id FROM toast_club_imports WHERE family_id = ? AND source_sha256 = ? "
            "AND deleted_at IS NULL",
            (family_id, schedule.sha256),
        )
    ).fetchone()
    codes = [day.session_code for day in schedule.days]
    return ToastImportPreview(
        sha256=schedule.sha256,
        source_title=schedule.source_title,
        child_id=child["id"],
        child_name=child["name"],
        valid_from=schedule.valid_from.isoformat(),
        valid_to=schedule.valid_to.isoformat(),
        base_start_time=schedule.base_start_time,
        booked_days=sum(code is not None for code in codes),
        until_1630=codes.count("1"),
        until_1730=codes.count("2"),
        changes=ToastImportChanges(**counts),
        already_imported=duplicate is not None,
        can_confirm=duplicate is None,
    )


async def confirm_import(
    db,
    *,
    current_user: dict,
    schedule: ParsedToastSchedule,
    expected_sha256: str,
    requested_child_id: str | None = None,
    client_id: str | None = None,
    client_timestamp: str | None = None,
) -> ToastImportResult:
    if schedule.sha256 != expected_sha256:
        raise ToastImportError("The booking form changed after review. Preview it again")
    family_id = current_user["family_id"]
    preview = await import_preview(
        db,
        family_id=family_id,
        schedule=schedule,
        requested_child_id=requested_child_id,
    )
    existing = await (
        await db.execute(
            "SELECT id FROM toast_club_imports WHERE family_id = ? AND source_sha256 = ? "
            "AND deleted_at IS NULL",
            (family_id, schedule.sha256),
        )
    ).fetchone()
    if existing:
        return ToastImportResult(import_id=existing["id"], imported=False, preview=preview)
    import_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    timestamp = client_timestamp or now
    await db.execute("BEGIN IMMEDIATE")
    try:
        existing = await (
            await db.execute(
                "SELECT id FROM toast_club_imports WHERE family_id = ? AND source_sha256 = ? "
                "AND deleted_at IS NULL",
                (family_id, schedule.sha256),
            )
        ).fetchone()
        if existing:
            await db.commit()
            return ToastImportResult(import_id=existing["id"], imported=False, preview=preview)
        await db.execute(
            """
            INSERT INTO toast_club_imports (
                id, child_id, source_sha256, source_title, valid_from, valid_to,
                base_start_time, family_id, created_at, updated_at, created_by,
                client_id, client_timestamp
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                import_id,
                preview.child_id,
                schedule.sha256,
                schedule.source_title,
                schedule.valid_from.isoformat(),
                schedule.valid_to.isoformat(),
                schedule.base_start_time,
                family_id,
                now,
                now,
                current_user["id"],
                client_id,
                timestamp,
            ),
        )
        await db.executemany(
            """
            INSERT INTO toast_club_import_days (
                id, import_id, child_id, booking_date, session_code, pickup_end,
                family_id, created_at, updated_at, created_by, client_id,
                client_timestamp
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    str(uuid.uuid4()),
                    import_id,
                    preview.child_id,
                    day.local_date.isoformat(),
                    day.session_code,
                    day.pickup_end,
                    family_id,
                    now,
                    now,
                    current_user["id"],
                    client_id,
                    timestamp,
                )
                for day in schedule.days
            ],
        )
        await db.commit()
    except BaseException:
        await db.rollback()
        raise
    return ToastImportResult(import_id=import_id, imported=True, preview=preview)


async def import_status(db, *, family_id: str) -> list[ToastImportStatus]:
    rows = await (
        await db.execute(
            """
            SELECT i.*, c.name AS child_name,
                   SUM(CASE WHEN d.session_code IS NOT NULL THEN 1 ELSE 0 END) AS booked_days
            FROM toast_club_imports i
            JOIN children c ON c.id = i.child_id AND c.family_id = i.family_id
                           AND c.deleted_at IS NULL
            JOIN toast_club_import_days d ON d.import_id = i.id AND d.family_id = i.family_id
                                         AND d.deleted_at IS NULL
            WHERE i.family_id = ? AND i.deleted_at IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM toast_club_imports newer
                  WHERE newer.family_id = i.family_id AND newer.child_id = i.child_id
                    AND newer.deleted_at IS NULL
                    AND (newer.created_at > i.created_at
                         OR (newer.created_at = i.created_at AND newer.id > i.id))
              )
            GROUP BY i.id
            ORDER BY c.name COLLATE NOCASE
            """,
            (family_id,),
        )
    ).fetchall()
    return [
        ToastImportStatus(
            import_id=row["id"],
            child_id=row["child_id"],
            child_name=row["child_name"],
            source_title=row["source_title"],
            valid_from=row["valid_from"],
            valid_to=row["valid_to"],
            booked_days=int(row["booked_days"] or 0),
            imported_at=row["created_at"],
        )
        for row in rows
    ]


def _bounds(range_start: datetime, range_end: datetime) -> tuple[date, date]:
    return (
        range_start.astimezone(TOAST_ZONE).date(),
        (range_end - timedelta(microseconds=1)).astimezone(TOAST_ZONE).date(),
    )


def _local_datetime(day: date, value: str) -> datetime:
    return datetime.combine(day, time.fromisoformat(value), tzinfo=TOAST_ZONE)


async def calendar_projections(
    db,
    *,
    family_id: str,
    range_start: datetime,
    range_end: datetime,
) -> list[CalendarEventResponse]:
    start, end = _bounds(range_start, range_end)
    source_days = await _effective_days(
        db,
        family_id=family_id,
        child_id=None,
        start=start,
        end=end,
    )
    booked = {key: row for key, row in source_days.items() if row["session_code"]}
    if not booked:
        return []
    child_ids = sorted({child_id for child_id, _ in booked})
    placeholders = ",".join("?" for _ in child_ids)
    child_rows = await (
        await db.execute(
            "SELECT id, name FROM children WHERE family_id = ? AND id IN ("
            + placeholders
            + ") AND deleted_at IS NULL",
            (family_id, *child_ids),
        )
    ).fetchall()
    child_names = {row["id"]: row["name"] for row in child_rows}
    club_items = await school_clubs.occurrence_records(
        db, family_id=family_id, start=start, end=end
    )
    clubs_by_day: dict[tuple[str, date], list[school_clubs.ClubOccurrence]] = {}
    for club in club_items:
        if not club.cancelled:
            clubs_by_day.setdefault((club.child_id, club.local_date), []).append(club)

    result: list[CalendarEventResponse] = []
    for (child_id, local_date), row in sorted(booked.items(), key=lambda item: item[0][1]):
        child_name = child_names.get(child_id)
        if child_name is None:
            continue
        base_start = row["base_start_time"]
        pickup_end = row["pickup_end"]
        candidates = [
            club
            for club in clubs_by_day.get((child_id, local_date), [])
            if club.end_time > base_start and club.start_time < pickup_end
        ]
        latest_club = max(candidates, key=lambda club: club.end_time) if candidates else None
        available_from = max(base_start, latest_club.end_time if latest_club else base_start)
        event_type = "toast_club"
        title = f"Toast · {child_name}"
        description = f"After {latest_club.title}" if latest_club and available_from < pickup_end else None
        end_value = pickup_end
        if available_from >= pickup_end:
            event_type = "toast_club_conflict"
            title = f"Toast clash · {child_name}"
            description = f"{latest_club.title} ends after Toast" if latest_club else "No pickup window"
            end_value = latest_club.end_time if latest_club else pickup_end
        result.append(
            CalendarEventResponse(
                id=f"toast-club:{child_id}:{local_date.isoformat()}",
                title=title,
                description=description,
                start_time=_local_datetime(local_date, available_from).isoformat(),
                end_time=_local_datetime(local_date, end_value).isoformat(),
                all_day=False,
                location="Toast Club",
                family_member_ids=[child_id],
                event_type=event_type,
                is_generated_occurrence=True,
                source_name="Toast Club",
                source_color="#DC2626",
                read_only=True,
                created_at=row["imported_at"],
                updated_at=row["import_updated_at"],
                created_by=row["import_created_by"],
                managed_source=ManagedSource(
                    kind="toast_club",
                    source_id=row["import_id"],
                    deep_link="/calendar?toast=1",
                    label="Toast Club",
                ),
            )
        )
    return result
