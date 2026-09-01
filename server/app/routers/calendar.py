import json
import uuid
from datetime import datetime, time, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from dateutil.rrule import rrulestr

from app.auth import get_current_user
from app.database import get_db
from app.models.calendar import (
    CalendarEventCreate,
    CalendarEventResponse,
    CalendarEventUpdate,
    CalendarOccurrenceDelete,
    CalendarOccurrenceUpdate,
    CalendarRecurrenceMutationScope,
)
from app.services.calendar_recurrence import (
    CalendarRecurrenceError,
    cancel_occurrence,
    exception_keys_for_series,
    isolate_occurrence,
    occurrence_base,
    resolve_occurrence,
    soft_delete_series_tree,
    split_series,
    translate_updates_to_series,
    truncate_series,
)
from app.services.calendar_attachments import (
    attachment_specs_for_update,
    attachments_for_event_rows,
    copy_event_attachments,
    replace_event_attachments,
    soft_delete_event_attachments,
)
from app.services.create_records import create_or_replay_calendar_event
from app.services.idempotency import CreateReplayConflictError
from app.services.record_history import save_history
from app.services.family_people import validate_calendar_people
from app.services.finance.projections import calendar_projections
from app.services.renewal_projections import renewal_calendar_projections
from app.services.fitness.activities import household_logistics_calendar_projections
from app.services.fitness.cycles import calendar_cycle_projections
from app.services.school_clubs import calendar_projections as school_club_calendar_projections
from app.services.toast_club import calendar_projections as toast_club_calendar_projections

router = APIRouter()

MAX_CALENDAR_RANGE = timedelta(days=400)
MAX_RANGE_SOURCE_ROWS = 500
MAX_EXPANDED_EVENTS = 2_000
MAX_OCCURRENCES_PER_SERIES = 400

DOCUMENT_COLUMNS = (
    ", d.id AS document_id, d.title AS document_title, "
    "d.original_filename AS document_original_filename, "
    "d.media_type AS document_media_type, d.file_size AS document_file_size "
)


def _event_joins() -> str:
    return (
        " FROM calendar_events ce "
        "LEFT JOIN calendar_sources cs ON cs.id = ce.calendar_source_id "
        "LEFT JOIN documents d ON d.id = ce.source_document_id "
        "AND d.family_id = ce.family_id AND d.deleted_at IS NULL "
    )


def _row_to_response(row: dict, **overrides) -> CalendarEventResponse:
    """Convert a database row dict into a CalendarEventResponse."""
    data = dict(row)
    # all_day is stored as INTEGER (0/1) in SQLite; convert to bool
    data["all_day"] = bool(data.get("all_day", 0))
    data["read_only"] = bool(data.get("read_only", 0))
    data["rugby_venue"] = data.get("rugby_venue_override") or data.get(
        "rugby_source_venue"
    )
    data["rugby_venue_overridden"] = bool(data.get("rugby_venue_override"))
    for field in ("family_member_ids", "affected_member_ids"):
        raw = data.get(field)
        if raw and isinstance(raw, str):
            data[field] = json.loads(raw)
        elif not raw:
            data[field] = None
    document_id = data.get("document_id")
    data["source_document"] = (
        {
            "id": document_id,
            "title": data["document_title"],
            "original_filename": data["document_original_filename"],
            "media_type": data["document_media_type"],
            "file_size": data["document_file_size"],
            "download_url": f"/api/documents/{document_id}/content",
        }
        if document_id
        else None
    )
    data["attachments"] = data.get("_attachments", [])
    data.update(overrides)
    return CalendarEventResponse(**data)


async def _event_row_with_document(db, event_id: str, family_id: str) -> dict:
    row = await (
        await db.execute(
            "SELECT ce.*, cs.name AS source_name, COALESCE(ce.color, cs.color) AS source_color "
            + DOCUMENT_COLUMNS
            + _event_joins()
            + "WHERE ce.id = ? AND ce.family_id = ?",
            (event_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Event not found")
    return dict(row)


async def _event_response(db, event_id: str, family_id: str) -> CalendarEventResponse:
    row = await _event_row_with_document(db, event_id, family_id)
    attachments = await attachments_for_event_rows(
        db,
        rows=[row],
        family_id=family_id,
    )
    row["_attachments"] = attachments.get(event_id, [])
    return _row_to_response(row)


def _parse_datetime(value: str, *, end_of_day: bool = False) -> datetime:
    """Parse API ISO timestamps and date-only values into timezone-aware datetimes."""
    if len(value) == 10:
        parsed_date = datetime.fromisoformat(value).date()
        parsed = datetime.combine(parsed_date, time.min, tzinfo=timezone.utc)
        # Date-only range parameters are inclusive calendar dates. Convert the
        # final date to the exclusive start of the following day so event
        # intervals can consistently use [start, end) semantics.
        return parsed + timedelta(days=1) if end_of_day else parsed

    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _format_occurrence(value: datetime, template: str, *, all_day: bool) -> str:
    if all_day or len(template) == 10:
        return value.date().isoformat()
    formatted = value.isoformat()
    if template.endswith("Z"):
        formatted = formatted.replace("+00:00", "Z")
    return formatted


def _parse_event_datetime(value: str, *, date_timezone) -> datetime:
    """Parse stored event values, keeping date-only values as civil dates."""
    if len(value) == 10:
        parsed_date = datetime.fromisoformat(value).date()
        return datetime.combine(parsed_date, time.min, tzinfo=date_timezone)
    return _parse_datetime(value)


def _expand_recurring_event(
    row: dict,
    *,
    range_start: datetime,
    range_end: datetime,
    excluded_occurrence_starts: set[str] | None = None,
) -> list[CalendarEventResponse]:
    """Materialize a recurring series inside a requested range without changing storage."""
    start_value = row["start_time"]
    event_start = _parse_event_datetime(
        start_value,
        date_timezone=range_start.tzinfo,
    )
    event_end = (
        _parse_event_datetime(
            row["end_time"],
            date_timezone=range_start.tzinfo,
        )
        if row.get("end_time")
        else None
    )
    stored_duration = event_end - event_start if event_end is not None else None
    is_all_day = bool(row.get("all_day")) or len(start_value) == 10
    overlap_duration = stored_duration
    if overlap_duration is None and is_all_day:
        overlap_duration = timedelta(days=1)

    try:
        rule = rrulestr(row["recurrence_rule"], dtstart=event_start)
        search_start = (
            range_start - overlap_duration if overlap_duration is not None else range_start
        )
        starts = []
        for occurrence in rule.xafter(
            search_start,
            count=MAX_OCCURRENCES_PER_SERIES,
            inc=True,
        ):
            if occurrence >= range_end:
                break
            starts.append(occurrence)
    except (TypeError, ValueError):
        # Preserve visibility of malformed legacy series at their original date.
        starts = [event_start]

    occurrences: list[CalendarEventResponse] = []
    for occurrence_start in starts:
        occurrence_end = occurrence_start + stored_duration if stored_duration is not None else None
        overlap_end = occurrence_start + overlap_duration if overlap_duration is not None else None
        if overlap_end is None:
            if not range_start <= occurrence_start < range_end:
                continue
        elif overlap_end <= range_start or occurrence_start >= range_end:
            continue

        occurrence_key = (
            occurrence_start.date().isoformat()
            if is_all_day
            else occurrence_start.astimezone(timezone.utc).isoformat()
        )
        if occurrence_key in (excluded_occurrence_starts or set()):
            continue
        occurrences.append(
            _row_to_response(
                row,
                id=f"{row['id']}::{occurrence_key}",
                series_id=row["id"],
                is_generated_occurrence=True,
                start_time=_format_occurrence(
                    occurrence_start,
                    start_value,
                    all_day=bool(row.get("all_day")),
                ),
                end_time=(
                    _format_occurrence(
                        occurrence_end,
                        row["end_time"],
                        all_day=bool(row.get("all_day")),
                    )
                    if occurrence_end and row.get("end_time")
                    else None
                ),
            )
        )
    return occurrences


def _event_overlaps_range(
    row: dict,
    *,
    range_start: datetime,
    range_end: datetime,
) -> bool:
    """Return whether a non-recurring event intersects a half-open range.

    Event end times are exclusive, matching iCalendar ``DTEND``. All-day and
    date-only events without an explicit end occupy one civil day; timed
    events without an end are points at their start.
    """
    try:
        event_start = _parse_event_datetime(
            row["start_time"],
            date_timezone=range_start.tzinfo,
        )
        event_end = (
            _parse_event_datetime(
                row["end_time"],
                date_timezone=range_start.tzinfo,
            )
            if row.get("end_time")
            else None
        )
    except (TypeError, ValueError):
        # Keep malformed legacy rows visible rather than failing the calendar.
        return True
    if event_end is None and (bool(row.get("all_day")) or len(row["start_time"]) == 10):
        event_end = event_start + timedelta(days=1)
    if event_end is None:
        return range_start <= event_start < range_end
    return event_start < range_end and event_end > range_start


@router.get("/", response_model=list[CalendarEventResponse])
async def list_events(
    start: str | None = Query(None),
    end: str | None = Query(None),
    assigned_to: str | None = Query(None),
    offset: int = Query(0, ge=0, le=MAX_EXPANDED_EVENTS),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List calendar events, optionally filtered by a date/time range."""
    if bool(start) != bool(end):
        raise HTTPException(status_code=400, detail="Calendar start and end are required together")
    range_start = None
    range_end = None
    if start and end:
        try:
            range_start = _parse_datetime(start)
            range_end = _parse_datetime(end, end_of_day=len(end) == 10)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="Calendar range is invalid") from exc
        if range_end <= range_start:
            raise HTTPException(status_code=400, detail="Calendar end must be after start")
        if range_end - range_start > MAX_CALENDAR_RANGE:
            raise HTTPException(status_code=400, detail="Calendar range cannot exceed 400 days")

    query = (
        "SELECT ce.*, cs.name AS source_name, COALESCE(ce.color, cs.color) AS source_color "
        + DOCUMENT_COLUMNS
        + _event_joins()
        + "WHERE ce.deleted_at IS NULL AND ce.family_id = ? "
        "AND NOT EXISTS ("
        "SELECT 1 FROM calendar_events replacement "
        "WHERE replacement.overridden_event_id = ce.id "
        "AND replacement.family_id = ce.family_id "
        "AND replacement.deleted_at IS NULL)"
    )
    params: list = [current_user["family_id"]]

    if start and end:
        assert range_start is not None and range_end is not None
        # ISO strings in storage can be date-only, Zulu, or offset timestamps,
        # which are not safely comparable as exact SQLite text values. Use a
        # deliberately widened date prefilter, then perform the precise
        # timezone-aware overlap check in Python below.
        coarse_start = (range_start - timedelta(days=1)).date().isoformat()
        coarse_end = (range_end + timedelta(days=1)).date().isoformat()
        query += """ AND (
            ce.recurrence_rule IS NOT NULL
            OR (
                ce.start_time < ?
                AND (
                    (ce.end_time IS NULL AND ce.start_time >= ?)
                    OR ce.end_time >= ?
                )
            )
        )"""
        params.extend([coarse_end, coarse_start, coarse_start])
    if assigned_to:
        query += """ AND (
            ce.assigned_to = ?
            OR EXISTS (SELECT 1 FROM json_each(ce.family_member_ids) WHERE value = ?)
            OR EXISTS (SELECT 1 FROM json_each(ce.affected_member_ids) WHERE value = ?)
            OR (ce.assigned_to IS NULL AND ce.family_member_ids IS NULL)
        )"""
        params.extend([assigned_to, assigned_to, assigned_to])

    query += " ORDER BY ce.start_time ASC"
    if not (start and end):
        query += " LIMIT ? OFFSET ?"
        params.extend([limit, offset])
    else:
        query += f" LIMIT {MAX_RANGE_SOURCE_ROWS}"

    cursor = await db.execute(query, params)
    rows = [dict(row) for row in await cursor.fetchall()]
    attachment_map = await attachments_for_event_rows(
        db,
        rows=rows,
        family_id=current_user["family_id"],
    )
    for row in rows:
        row["_attachments"] = attachment_map.get(row["id"], [])
    if not (start and end):
        return [_row_to_response(row) for row in rows]

    assert range_start is not None and range_end is not None
    events: list[CalendarEventResponse] = []
    recurring_series_ids = [row["id"] for row in rows if row["recurrence_rule"]]
    excluded_occurrences = await exception_keys_for_series(
        db,
        family_id=current_user["family_id"],
        series_ids=recurring_series_ids,
    )
    for row in rows:
        row_data = row
        if row_data.get("recurrence_rule"):
            events.extend(
                _expand_recurring_event(
                    row_data,
                    range_start=range_start,
                    range_end=range_end,
                    excluded_occurrence_starts=excluded_occurrences.get(row_data["id"]),
                )
            )
        elif _event_overlaps_range(
            row_data,
            range_start=range_start,
            range_end=range_end,
        ):
            events.append(_row_to_response(row_data))
        if len(events) >= MAX_EXPANDED_EVENTS:
            break

    cycle_events = await calendar_cycle_projections(
        db,
        family_id=current_user["family_id"],
        current_user_id=current_user["id"],
        range_start=range_start,
        range_end=range_end,
    )
    if assigned_to:
        cycle_events = [
            event
            for event in cycle_events
            if event.assigned_to == assigned_to
            or assigned_to in (event.family_member_ids or [])
        ]
    events.extend(cycle_events)
    fitness_logistics = await household_logistics_calendar_projections(
        db,
        user=current_user,
        range_start=range_start,
        range_end=range_end,
    )
    if assigned_to:
        fitness_logistics = [
            event
            for event in fitness_logistics
            if event.assigned_to is None or event.assigned_to == assigned_to
        ]
    events.extend(fitness_logistics)
    finance_events = await calendar_projections(
        db,
        user=current_user,
        range_start=range_start,
        range_end=range_end,
    )
    if assigned_to:
        finance_events = [
            event
            for event in finance_events
            if event.assigned_to is None or event.assigned_to == assigned_to
        ]
    events.extend(finance_events)
    renewal_events = await renewal_calendar_projections(
        db,
        user=current_user,
        range_start=range_start,
        range_end=range_end,
    )
    if assigned_to:
        renewal_events = [
            event
            for event in renewal_events
            if event.assigned_to is None or event.assigned_to == assigned_to
        ]
    events.extend(renewal_events)
    club_events = await school_club_calendar_projections(
        db,
        family_id=current_user["family_id"],
        range_start=range_start,
        range_end=range_end,
    )
    if assigned_to:
        club_events = [
            event
            for event in club_events
            if assigned_to in (event.family_member_ids or [])
        ]
    events.extend(club_events)
    toast_events = await toast_club_calendar_projections(
        db,
        family_id=current_user["family_id"],
        range_start=range_start,
        range_end=range_end,
    )
    if assigned_to:
        toast_events = [
            event
            for event in toast_events
            if assigned_to in (event.family_member_ids or [])
        ]
    events.extend(toast_events)
    events.sort(key=lambda event: event.start_time)
    return events[offset : offset + limit]


@router.post("/", response_model=CalendarEventResponse, status_code=status.HTTP_201_CREATED)
async def create_event(
    body: CalendarEventCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a new calendar event."""
    try:
        row, _replayed = await create_or_replay_calendar_event(
            db,
            body,
            record_id=str(body.id),
            user=current_user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    except CreateReplayConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return await _event_response(db, row["id"], current_user["family_id"])


async def _normalised_event_updates(
    db,
    *,
    existing: dict,
    body: CalendarEventUpdate,
    family_id: str,
) -> dict:
    """Validate a partial event edit and convert values for SQLite storage."""
    update_data = body.model_dump(exclude_unset=True)
    # Attachment relations are persisted separately from calendar_events.
    update_data.pop("attachments", None)
    if "title" in update_data and update_data["title"] is None:
        raise HTTPException(status_code=400, detail="Calendar title cannot be empty")
    if "start_time" in update_data and update_data["start_time"] is None:
        raise HTTPException(status_code=400, detail="Calendar start time is required")
    if "all_day" in update_data and update_data["all_day"] is None:
        raise HTTPException(status_code=400, detail="Calendar all-day flag is required")

    start_value = update_data.get("start_time", existing["start_time"])
    end_value = update_data.get("end_time", existing["end_time"])
    try:
        start = _parse_datetime(start_value)
        if end_value is not None:
            end = _parse_datetime(end_value)
            if end <= start:
                raise HTTPException(
                    status_code=400,
                    detail="Calendar end time must be after start time",
                )
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="Calendar time is invalid") from exc

    people_fields = {"family_member_ids", "affected_member_ids", "assigned_to"}
    if people_fields & update_data.keys():
        raw_members = update_data.get("family_member_ids", existing["family_member_ids"])
        if isinstance(raw_members, str):
            raw_members = json.loads(raw_members)
        participants = list(raw_members or [])
        assigned = update_data.get("assigned_to", existing["assigned_to"])
        if assigned and assigned not in participants:
            participants.append(assigned)
        raw_affected = update_data.get(
            "affected_member_ids",
            existing["affected_member_ids"],
        )
        if isinstance(raw_affected, str):
            raw_affected = json.loads(raw_affected)
        try:
            await validate_calendar_people(
                db,
                family_id,
                participants,
                list(raw_affected or []),
                whole_family=not raw_members and not assigned,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    if (
        "source_document_id" in update_data
        and update_data["source_document_id"] is not None
    ):
        document = await (
            await db.execute(
                "SELECT 1 FROM documents WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                (update_data["source_document_id"], family_id),
            )
        ).fetchone()
        if document is None:
            raise HTTPException(
                status_code=400,
                detail="Attached document is not available to this family",
            )

    updates: dict = {}
    for field, value in update_data.items():
        if field == "all_day" and value is not None:
            updates[field] = int(value)
        elif field in {"family_member_ids", "affected_member_ids"}:
            updates[field] = json.dumps(value) if value else None
        else:
            updates[field] = value
    return updates


async def _save_event_updates(
    db,
    *,
    existing: dict,
    updates: dict,
    current_user: dict,
    save_existing_history: bool = True,
) -> dict:
    """Apply validated event updates without committing the caller's transaction."""
    if not updates:
        return existing
    if save_existing_history:
        await save_history(
            db,
            "calendar_events",
            existing["id"],
            current_user["id"],
            family_id=current_user["family_id"],
        )
    updates["updated_at"] = datetime.now(timezone.utc).isoformat()
    set_clause = ", ".join(f"{column} = ?" for column in updates)
    await db.execute(
        f"UPDATE calendar_events SET {set_clause} WHERE id = ? AND family_id = ?",
        [*updates.values(), existing["id"], current_user["family_id"]],
    )
    row = await (
        await db.execute(
            "SELECT * FROM calendar_events WHERE id = ? AND family_id = ?",
            (existing["id"], current_user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Event not found")
    return dict(row)


async def _override_read_only_event(
    db,
    *,
    source_event: dict,
    body: CalendarEventUpdate,
    current_user: dict,
) -> dict:
    """Create or update an editable row that supersedes a read-only source event."""
    family_id = current_user["family_id"]
    owns_transaction = not db.in_transaction
    if owns_transaction:
        await db.execute("BEGIN IMMEDIATE")
    try:
        # Serialize against sync and another stale client editing the same source.
        source_row = await (
            await db.execute(
                "SELECT * FROM calendar_events "
                "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                (source_event["id"], family_id),
            )
        ).fetchone()
        if source_row is None:
            raise HTTPException(status_code=404, detail="Event not found")
        source = dict(source_row)

        override_row = await (
            await db.execute(
                "SELECT * FROM calendar_events "
                "WHERE overridden_event_id = ? AND family_id = ? AND deleted_at IS NULL",
                (source["id"], family_id),
            )
        ).fetchone()
        created_override = override_row is None
        if created_override:
            now = datetime.now(timezone.utc).isoformat()
            override_id = str(uuid.uuid4())
            await db.execute(
                """
                INSERT INTO calendar_events
                    (id, title, description, start_time, end_time, all_day,
                     recurrence_rule, location, family_member_ids, affected_member_ids,
                     assigned_to, event_type, exertion, source_document_id,
                     read_only, overridden_event_id,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                """,
                (
                    override_id,
                    source["title"],
                    source["description"],
                    source["start_time"],
                    source["end_time"],
                    source["all_day"],
                    source["recurrence_rule"],
                    source["location"],
                    source["family_member_ids"],
                    source["affected_member_ids"],
                    source["assigned_to"],
                    source["event_type"],
                    source["exertion"],
                    source["source_document_id"],
                    source["id"],
                    family_id,
                    now,
                    now,
                    current_user["id"],
                ),
            )
            override = dict(
                await (
                    await db.execute(
                        "SELECT * FROM calendar_events WHERE id = ?",
                        (override_id,),
                    )
                ).fetchone()
            )
            await copy_event_attachments(
                db,
                source_event_id=source["id"],
                target_event_id=override_id,
                family_id=family_id,
                user_id=current_user["id"],
                legacy_source_document_id=source.get("source_document_id"),
            )
        else:
            override = dict(override_row)

        attachment_specs = await attachment_specs_for_update(
            db,
            event=override,
            body=body,
            family_id=family_id,
        )
        updates = await _normalised_event_updates(
            db,
            existing=override,
            body=body,
            family_id=family_id,
        )
        if attachment_specs is not None:
            updates["source_document_id"] = (
                attachment_specs[0][0] if attachment_specs else None
            )
        updated = await _save_event_updates(
            db,
            existing=override,
            updates=updates,
            current_user=current_user,
            save_existing_history=not created_override,
        )
        if attachment_specs is not None:
            await replace_event_attachments(
                db,
                event_id=override["id"],
                family_id=family_id,
                user_id=current_user["id"],
                specs=attachment_specs,
                client_id=body.client_id,
                client_timestamp=body.client_timestamp,
            )
        if owns_transaction:
            await db.commit()
        return updated
    except BaseException:
        if owns_transaction and db.in_transaction:
            await db.rollback()
        raise


@router.put("/{event_id}", response_model=CalendarEventResponse)
async def update_event(
    event_id: str,
    body: CalendarEventUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update an existing calendar event."""
    # Hold the write reservation across document validation and the update. Without
    # this, a concurrent document deletion could detach existing references, commit,
    # and then have this request recreate a dangling source_document_id.
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT * FROM calendar_events "
            "WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
            (event_id, current_user["family_id"]),
        )
        existing_row = await cursor.fetchone()
        if not existing_row:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Event not found",
            )
        existing = dict(existing_row)
        if existing["read_only"]:
            row = await _override_read_only_event(
                db,
                source_event=existing,
                body=body,
                current_user=current_user,
            )
        else:
            attachment_specs = await attachment_specs_for_update(
                db,
                event=existing,
                body=body,
                family_id=current_user["family_id"],
            )
            updates = await _normalised_event_updates(
                db,
                existing=existing,
                body=body,
                family_id=current_user["family_id"],
            )
            if attachment_specs is not None:
                updates["source_document_id"] = (
                    attachment_specs[0][0] if attachment_specs else None
                )
            row = await _save_event_updates(
                db,
                existing=existing,
                updates=updates,
                current_user=current_user,
            )
            if attachment_specs is not None:
                await replace_event_attachments(
                    db,
                    event_id=existing["id"],
                    family_id=current_user["family_id"],
                    user_id=current_user["id"],
                    specs=attachment_specs,
                    client_id=body.client_id,
                    client_timestamp=body.client_timestamp,
                )
        response = await _event_response(db, row["id"], current_user["family_id"])
        await db.commit()
        return response
    except ValueError as exc:
        if db.in_transaction:
            await db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


async def _active_recurring_series(db, series_id: str, *, family_id: str) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM calendar_events "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (series_id, family_id),
        )
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Event not found")
    series = dict(row)
    if not series.get("recurrence_rule"):
        raise HTTPException(status_code=409, detail="Event is not a repeating series")
    if series.get("read_only"):
        raise HTTPException(
            status_code=409,
            detail="Imported calendar events are read-only; edit the imported occurrence to create a HausKlar copy",
        )
    return series


@router.patch("/{series_id}/occurrences", response_model=CalendarEventResponse)
@router.post("/{series_id}/occurrences/edit", response_model=CalendarEventResponse)
async def update_recurring_occurrence(
    series_id: str,
    body: CalendarOccurrenceUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Edit one occurrence, a new suffix, or the complete stored series."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        series = await _active_recurring_series(
            db,
            series_id,
            family_id=current_user["family_id"],
        )
        try:
            occurrence = resolve_occurrence(series, body.occurrence_start)
        except CalendarRecurrenceError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

        updates = await _normalised_event_updates(
            db,
            existing=occurrence_base(series, occurrence),
            body=body.updates,
            family_id=current_user["family_id"],
        )
        attachment_specs = await attachment_specs_for_update(
            db,
            event=series,
            body=body.updates,
            family_id=current_user["family_id"],
        )
        if attachment_specs is not None:
            updates["source_document_id"] = (
                attachment_specs[0][0] if attachment_specs else None
            )
        if body.scope == CalendarRecurrenceMutationScope.only_this:
            result_id = await isolate_occurrence(
                db,
                series=series,
                occurrence=occurrence,
                updates=updates,
                user=current_user,
            )
        elif body.scope == CalendarRecurrenceMutationScope.this_and_later:
            result_id = await split_series(
                db,
                series=series,
                occurrence=occurrence,
                updates=updates,
                user=current_user,
            )
        else:
            translated = translate_updates_to_series(series, occurrence, updates)
            updated = await _save_event_updates(
                db,
                existing=series,
                updates=translated,
                current_user=current_user,
            )
            result_id = updated["id"]

        if attachment_specs is not None:
            await replace_event_attachments(
                db,
                event_id=result_id,
                family_id=current_user["family_id"],
                user_id=current_user["id"],
                specs=attachment_specs,
                client_id=body.updates.client_id,
                client_timestamp=body.updates.client_timestamp,
            )

        response = await _event_response(db, result_id, current_user["family_id"])
        await db.commit()
        return response
    except ValueError as exc:
        if db.in_transaction:
            await db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


@router.post("/{series_id}/occurrences/delete", status_code=status.HTTP_204_NO_CONTENT)
async def delete_recurring_occurrence(
    series_id: str,
    body: CalendarOccurrenceDelete,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Delete one occurrence, the selected suffix, or the complete series."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        series = await _active_recurring_series(
            db,
            series_id,
            family_id=current_user["family_id"],
        )
        try:
            occurrence = resolve_occurrence(series, body.occurrence_start)
        except CalendarRecurrenceError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

        if body.scope == CalendarRecurrenceMutationScope.only_this:
            await cancel_occurrence(
                db,
                series=series,
                occurrence=occurrence,
                user=current_user,
                client_id=body.client_id,
                client_timestamp=body.client_timestamp,
            )
        elif body.scope == CalendarRecurrenceMutationScope.this_and_later:
            await truncate_series(
                db,
                series=series,
                occurrence=occurrence,
                user=current_user,
            )
        else:
            await soft_delete_series_tree(db, series=series, user=current_user)
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


@router.delete("/{event_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_event(
    event_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a calendar event by setting deleted_at."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT * FROM calendar_events "
            "WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
            (event_id, current_user["family_id"]),
        )
        existing_row = await cursor.fetchone()
        if not existing_row:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Event not found",
            )
        existing = dict(existing_row)
        if existing["read_only"]:
            raise HTTPException(status_code=409, detail="Imported calendar events are read-only")

        if existing.get("recurrence_rule"):
            await soft_delete_series_tree(db, series=existing, user=current_user)
        else:
            await save_history(
                db,
                "calendar_events",
                event_id,
                current_user["id"],
                family_id=current_user["family_id"],
            )
            now = datetime.now(timezone.utc).isoformat()
            await db.execute(
                "UPDATE calendar_events SET deleted_at = ?, updated_at = ? "
                "WHERE id = ? AND family_id = ?",
                (now, now, event_id, current_user["family_id"]),
            )
            await soft_delete_event_attachments(
                db,
                event_id=event_id,
                family_id=current_user["family_id"],
                user_id=current_user["id"],
                now=now,
            )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
