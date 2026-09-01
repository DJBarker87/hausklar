"""Safe mutation helpers for generated calendar recurrence occurrences."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone

from dateutil.rrule import rrulestr

from app.services.calendar_attachments import (
    copy_event_attachments,
    soft_delete_event_attachments,
)
from app.services.record_history import save_history

MAX_MUTATION_OCCURRENCE_INDEX = 10_000
WEEKDAYS = ("MO", "TU", "WE", "TH", "FR", "SA", "SU")


class CalendarRecurrenceError(ValueError):
    """Raised when a requested occurrence is not an active member of a series."""


@dataclass(frozen=True)
class ResolvedOccurrence:
    start: datetime
    key: str
    start_value: str
    end_value: str | None
    occurrences_before: int


@dataclass(frozen=True)
class ExpandedCalendarOccurrence:
    """One stored or generated event occurrence inside a requested interval."""

    row: dict
    start: datetime
    end: datetime | None
    start_value: str
    end_value: str | None
    key: str
    all_day: bool
    generated: bool


def _parse_datetime(value: str, *, date_timezone) -> datetime:
    if len(value) == 10:
        parsed_date = datetime.fromisoformat(value).date()
        return datetime.combine(parsed_date, time.min, tzinfo=date_timezone)
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _format_datetime(value: datetime, template: str, *, all_day: bool) -> str:
    if all_day or len(template) == 10:
        return value.date().isoformat()
    formatted = value.isoformat()
    return formatted.replace("+00:00", "Z") if template.endswith("Z") else formatted


def _is_all_day(series: dict) -> bool:
    return bool(series.get("all_day")) or len(series["start_time"]) == 10


def _occurrence_key(value: datetime, *, all_day: bool) -> str:
    if all_day:
        return value.date().isoformat()
    return value.astimezone(timezone.utc).isoformat()


def occurrence_key(value: datetime, *, all_day: bool) -> str:
    """Return the canonical identity shared by recurrence consumers."""
    return _occurrence_key(value, all_day=all_day)


def resolve_occurrence(series: dict, requested_start: str) -> ResolvedOccurrence:
    """Resolve and verify an occurrence against the stored RRULE.

    The caller supplies the occurrence's displayed start value. The canonical
    UTC/date key returned here is the stable exception identity used by listing.
    """
    rule_text = series.get("recurrence_rule")
    if not rule_text:
        raise CalendarRecurrenceError("Event is not a repeating series")

    all_day = _is_all_day(series)
    try:
        event_start = _parse_datetime(series["start_time"], date_timezone=timezone.utc)
        requested = _parse_datetime(requested_start, date_timezone=event_start.tzinfo)
        rule = rrulestr(rule_text, dtstart=event_start)
        matched = rule.before(requested, inc=True)
    except (TypeError, ValueError, OverflowError) as exc:
        raise CalendarRecurrenceError("Repeating event could not be interpreted") from exc

    if matched is None or _occurrence_key(matched, all_day=all_day) != _occurrence_key(
        requested,
        all_day=all_day,
    ):
        raise CalendarRecurrenceError("Occurrence is not part of this repeating series")

    event_end = (
        _parse_datetime(series["end_time"], date_timezone=event_start.tzinfo)
        if series.get("end_time")
        else None
    )
    duration = event_end - event_start if event_end is not None else None
    matched_end = matched + duration if duration is not None else None
    occurrences_before = None
    try:
        for index, candidate in enumerate(
            rule.xafter(
                event_start,
                count=MAX_MUTATION_OCCURRENCE_INDEX + 1,
                inc=True,
            )
        ):
            if _occurrence_key(candidate, all_day=all_day) == _occurrence_key(
                matched,
                all_day=all_day,
            ):
                occurrences_before = index
                break
            if candidate > matched:
                break
    except (TypeError, ValueError, OverflowError) as exc:
        raise CalendarRecurrenceError("Repeating event could not be interpreted") from exc
    if occurrences_before is None:
        raise CalendarRecurrenceError("Occurrence is too far into this repeating series")

    return ResolvedOccurrence(
        start=matched,
        key=_occurrence_key(matched, all_day=all_day),
        start_value=_format_datetime(
            matched,
            series["start_time"],
            all_day=bool(series.get("all_day")),
        ),
        end_value=(
            _format_datetime(
                matched_end,
                series["end_time"],
                all_day=bool(series.get("all_day")),
            )
            if matched_end is not None and series.get("end_time")
            else None
        ),
        occurrences_before=occurrences_before,
    )


def occurrence_base(series: dict, occurrence: ResolvedOccurrence) -> dict:
    base = dict(series)
    base["start_time"] = occurrence.start_value
    base["end_time"] = occurrence.end_value
    return base


def _rule_parts(rule_text: str) -> list[tuple[str, str]]:
    parts: list[tuple[str, str]] = []
    for component in rule_text.split(";"):
        key, separator, value = component.partition("=")
        if not separator:
            raise CalendarRecurrenceError("Repeating event could not be interpreted")
        parts.append((key.upper(), value))
    return parts


def _render_rule(parts: list[tuple[str, str]]) -> str:
    return ";".join(f"{key}={value}" for key, value in parts)


def _prefix_rule(rule_text: str, occurrence_start: datetime) -> str:
    # RRULE UNTIL is inclusive, so end one second before the selected occurrence.
    until = (occurrence_start.astimezone(timezone.utc) - timedelta(seconds=1)).strftime(
        "%Y%m%dT%H%M%SZ"
    )
    # COUNT plus UNTIL is deprecated by dateutil and invalid under RFC 5545.
    # The earlier UNTIL fully defines the prefix, so COUNT must be removed.
    parts = [
        (key, value)
        for key, value in _rule_parts(rule_text)
        if key not in {"COUNT", "UNTIL"}
    ]
    parts.append(("UNTIL", until))
    return _render_rule(parts)


def _suffix_rule(rule_text: str, occurrences_before: int) -> str:
    parts = _rule_parts(rule_text)
    adjusted: list[tuple[str, str]] = []
    for key, value in parts:
        if key == "COUNT":
            try:
                remaining = int(value) - occurrences_before
            except ValueError as exc:
                raise CalendarRecurrenceError(
                    "Repeating event could not be interpreted"
                ) from exc
            if remaining < 1:
                raise CalendarRecurrenceError("Occurrence is not part of this repeating series")
            adjusted.append((key, str(remaining)))
        else:
            adjusted.append((key, value))
    return _render_rule(adjusted)


def _rule_shifted_to_new_start(
    rule_text: str,
    original_start: datetime,
    new_start: datetime,
) -> str:
    """Move simple weekday constraints with a changed series anchor.

    HausKlar creates weekly rules with a single BYDAY. Shifting that weekday is
    essential: dateutil does not automatically include DTSTART when a BYDAY
    constraint still names the old day. Multi-day BYDAY rules are shifted as a
    group; ordinal prefixes are retained for compatible legacy rules.
    """
    day_delta = (new_start.date() - original_start.date()).days
    if day_delta == 0:
        return rule_text
    shifted: list[tuple[str, str]] = []
    for key, value in _rule_parts(rule_text):
        if key != "BYDAY":
            shifted.append((key, value))
            continue
        days: list[str] = []
        for token in value.split(","):
            weekday = token[-2:]
            if weekday not in WEEKDAYS:
                raise CalendarRecurrenceError("Repeating event could not be interpreted")
            prefix = token[:-2]
            shifted_weekday = WEEKDAYS[(WEEKDAYS.index(weekday) + day_delta) % 7]
            days.append(f"{prefix}{shifted_weekday}")
        shifted.append((key, ",".join(days)))
    return _render_rule(shifted)


async def exception_keys_for_series(
    db,
    *,
    family_id: str,
    series_ids: list[str],
) -> dict[str, set[str]]:
    series_ids = list(dict.fromkeys(series_ids))
    if not series_ids:
        return {}
    placeholders = ",".join("?" for _ in series_ids)
    rows = await (
        await db.execute(
            f"""
            SELECT series_id, occurrence_start
            FROM calendar_event_exceptions
            WHERE family_id = ? AND deleted_at IS NULL
              AND series_id IN ({placeholders})
            """,
            (family_id, *series_ids),
        )
    ).fetchall()
    result: dict[str, set[str]] = {}
    for row in rows:
        result.setdefault(row["series_id"], set()).add(row["occurrence_start"])
    return result


async def expand_calendar_rows(
    db,
    *,
    family_id: str,
    rows,
    range_start: datetime,
    range_end: datetime,
    max_occurrences_per_series: int = 400,
    fail_on_truncation: bool = False,
) -> list[ExpandedCalendarOccurrence]:
    """Expand family calendar rows while consistently applying exceptions.

    Replacement occurrences and suffix series are ordinary ``calendar_events``
    rows and therefore flow through naturally. The exception lookup only
    suppresses the original generated occurrence it names.
    """
    source_rows = [dict(row) for row in rows]
    excluded = await exception_keys_for_series(
        db,
        family_id=family_id,
        series_ids=[row["id"] for row in source_rows if row.get("recurrence_rule")],
    )
    expanded: list[ExpandedCalendarOccurrence] = []
    for row in source_rows:
        try:
            event_start = _parse_datetime(
                row["start_time"],
                date_timezone=range_start.tzinfo,
            )
            event_end = (
                _parse_datetime(
                    row["end_time"],
                    date_timezone=event_start.tzinfo,
                )
                if row.get("end_time")
                else None
            )
        except (TypeError, ValueError):
            continue
        all_day = _is_all_day(row)
        stored_duration = event_end - event_start if event_end is not None else None
        overlap_duration = stored_duration
        if overlap_duration is None and all_day:
            overlap_duration = timedelta(days=1)

        generated = bool(row.get("recurrence_rule"))
        if generated:
            truncated = False
            try:
                rule = rrulestr(row["recurrence_rule"], dtstart=event_start)
                search_start = (
                    range_start - overlap_duration
                    if overlap_duration is not None
                    else range_start
                )
                starts: list[datetime] = []
                for index, candidate in enumerate(
                    rule.xafter(
                        search_start,
                        count=max_occurrences_per_series + 1,
                        inc=True,
                    )
                ):
                    if candidate >= range_end:
                        break
                    if index >= max_occurrences_per_series:
                        truncated = True
                        break
                    starts.append(candidate)
            except (OverflowError, TypeError, ValueError):
                starts = [event_start]
            if truncated and fail_on_truncation:
                raise CalendarRecurrenceError(
                    "Repeating event creates too many occurrences in this range"
                )
        else:
            starts = [event_start]

        excluded_keys = excluded.get(row["id"], set())
        for start in starts:
            end = start + stored_duration if stored_duration is not None else None
            overlap_end = start + overlap_duration if overlap_duration is not None else None
            if overlap_end is None:
                if not range_start <= start < range_end:
                    continue
            elif overlap_end <= range_start or start >= range_end:
                continue
            key = _occurrence_key(start, all_day=all_day)
            if generated and key in excluded_keys:
                continue
            expanded.append(
                ExpandedCalendarOccurrence(
                    row=row,
                    start=start,
                    end=end,
                    start_value=_format_datetime(
                        start,
                        row["start_time"],
                        all_day=bool(row.get("all_day")),
                    ),
                    end_value=(
                        _format_datetime(
                            end,
                            row["end_time"],
                            all_day=bool(row.get("all_day")),
                        )
                        if end is not None and row.get("end_time")
                        else None
                    ),
                    key=key,
                    all_day=all_day,
                    generated=generated,
                )
            )
    expanded.sort(key=lambda item: (item.start, item.row["id"]))
    return expanded


def translate_updates_to_series(
    series: dict,
    occurrence: ResolvedOccurrence,
    updates: dict,
) -> dict:
    """Translate occurrence-relative times back to the stored series anchor."""
    translated = dict(updates)
    if "start_time" not in updates and "end_time" not in updates:
        return translated

    parent_start = _parse_datetime(series["start_time"], date_timezone=timezone.utc)
    edited_occurrence_start = _parse_datetime(
        updates.get("start_time", occurrence.start_value),
        date_timezone=occurrence.start.tzinfo,
    )
    translated_parent_start = parent_start
    new_all_day = bool(updates.get("all_day", series.get("all_day")))
    if "start_time" in updates:
        displacement = occurrence.start - parent_start
        translated_parent_start = edited_occurrence_start - displacement
        translated["start_time"] = _format_datetime(
            translated_parent_start,
            updates["start_time"],
            all_day=new_all_day,
        )
        if "recurrence_rule" not in updates:
            translated["recurrence_rule"] = _rule_shifted_to_new_start(
                series["recurrence_rule"],
                occurrence.start,
                edited_occurrence_start,
            )

    if "end_time" in updates and updates["end_time"] is not None:
        edited_occurrence_end = _parse_datetime(
            updates["end_time"],
            date_timezone=edited_occurrence_start.tzinfo,
        )
        translated_parent_end = translated_parent_start + (
            edited_occurrence_end - edited_occurrence_start
        )
        translated["end_time"] = _format_datetime(
            translated_parent_end,
            updates["end_time"],
            all_day=new_all_day,
        )
    return translated


async def _soft_delete_event(db, event_id: str, *, user: dict, now: str) -> None:
    row = await (
        await db.execute(
            "SELECT id FROM calendar_events "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (event_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        return
    await save_history(
        db,
        "calendar_events",
        event_id,
        user["id"],
        family_id=user["family_id"],
    )
    await db.execute(
        "UPDATE calendar_events SET deleted_at = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, event_id, user["family_id"]),
    )
    await soft_delete_event_attachments(
        db,
        event_id=event_id,
        family_id=user["family_id"],
        user_id=user["id"],
        now=now,
    )


async def _update_local_event(
    db,
    event_id: str,
    *,
    updates: dict,
    user: dict,
    now: str,
) -> None:
    if not updates:
        return
    await save_history(
        db,
        "calendar_events",
        event_id,
        user["id"],
        family_id=user["family_id"],
    )
    values = dict(updates)
    values["recurrence_rule"] = None
    values["updated_at"] = now
    assignments = ", ".join(f"{column} = ?" for column in values)
    await db.execute(
        f"UPDATE calendar_events SET {assignments} WHERE id = ? AND family_id = ?",
        (*values.values(), event_id, user["family_id"]),
    )


async def _retire_exception(db, exception: dict, *, user: dict, now: str) -> None:
    replacement_id = exception.get("replacement_event_id")
    if replacement_id:
        await _soft_delete_event(db, replacement_id, user=user, now=now)
    await save_history(
        db,
        "calendar_event_exceptions",
        exception["id"],
        user["id"],
        family_id=user["family_id"],
    )
    await db.execute(
        "UPDATE calendar_event_exceptions SET deleted_at = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, exception["id"], user["family_id"]),
    )


async def _active_exceptions(db, series_id: str, *, family_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM calendar_event_exceptions "
            "WHERE series_id = ? AND family_id = ? AND deleted_at IS NULL",
            (series_id, family_id),
        )
    ).fetchall()
    return [dict(row) for row in rows]


async def _retire_exceptions_from(
    db,
    series: dict,
    occurrence: ResolvedOccurrence | None,
    *,
    user: dict,
    now: str,
) -> None:
    all_day = _is_all_day(series)
    for exception in await _active_exceptions(
        db,
        series["id"],
        family_id=user["family_id"],
    ):
        if occurrence is not None:
            exception_start = _parse_datetime(
                exception["occurrence_start"],
                date_timezone=occurrence.start.tzinfo,
            )
            if _occurrence_key(exception_start, all_day=all_day) < occurrence.key:
                continue
        await _retire_exception(db, exception, user=user, now=now)


async def _truncate_before(
    db,
    series: dict,
    occurrence: ResolvedOccurrence,
    *,
    user: dict,
    now: str,
) -> None:
    await save_history(
        db,
        "calendar_events",
        series["id"],
        user["id"],
        family_id=user["family_id"],
    )
    if occurrence.occurrences_before == 0:
        await db.execute(
            "UPDATE calendar_events SET deleted_at = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ?",
            (now, now, series["id"], user["family_id"]),
        )
        return
    await db.execute(
        "UPDATE calendar_events SET recurrence_rule = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (
            _prefix_rule(series["recurrence_rule"], occurrence.start),
            now,
            series["id"],
            user["family_id"],
        ),
    )


async def _insert_local_event(
    db,
    *,
    source: dict,
    start_time: str,
    end_time: str | None,
    recurrence_rule: str | None,
    updates: dict,
    user: dict,
    now: str,
) -> str:
    values = {
        "title": source["title"],
        "description": source.get("description"),
        "start_time": start_time,
        "end_time": end_time,
        "all_day": source.get("all_day", 0),
        "recurrence_rule": recurrence_rule,
        "location": source.get("location"),
        "family_member_ids": source.get("family_member_ids"),
        "affected_member_ids": source.get("affected_member_ids"),
        "assigned_to": source.get("assigned_to"),
        "event_type": source.get("event_type") or "other",
        "exertion": source.get("exertion", 0),
        "source_document_id": source.get("source_document_id"),
        "client_id": source.get("client_id"),
        "client_timestamp": source.get("client_timestamp"),
    }
    values.update(updates)
    event_id = str(uuid.uuid4())
    await db.execute(
        """
        INSERT INTO calendar_events
            (id, title, description, start_time, end_time, all_day,
             recurrence_rule, location, family_member_ids, affected_member_ids,
             assigned_to, event_type, exertion, source_document_id,
             read_only, overridden_event_id, family_id, created_at, updated_at,
             created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?, ?, ?, ?)
        """,
        (
            event_id,
            values["title"],
            values["description"],
            values["start_time"],
            values["end_time"],
            values["all_day"],
            values["recurrence_rule"],
            values["location"],
            values["family_member_ids"],
            values["affected_member_ids"],
            values["assigned_to"],
            values["event_type"],
            values["exertion"],
            values["source_document_id"],
            user["family_id"],
            now,
            now,
            user["id"],
            values["client_id"],
            values["client_timestamp"],
        ),
    )
    await copy_event_attachments(
        db,
        source_event_id=source["id"],
        target_event_id=event_id,
        family_id=user["family_id"],
        user_id=user["id"],
        legacy_source_document_id=source.get("source_document_id"),
    )
    return event_id


async def isolate_occurrence(
    db,
    *,
    series: dict,
    occurrence: ResolvedOccurrence,
    updates: dict,
    user: dict,
) -> str:
    """Suppress one generated occurrence and create its local editable copy."""
    now = datetime.now(timezone.utc).isoformat()
    existing = await (
        await db.execute(
            "SELECT * FROM calendar_event_exceptions "
            "WHERE family_id = ? AND series_id = ? AND occurrence_start = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], series["id"], occurrence.key),
        )
    ).fetchone()
    if existing is not None and existing["replacement_event_id"]:
        replacement = await (
            await db.execute(
                "SELECT id FROM calendar_events WHERE id = ? AND family_id = ? "
                "AND deleted_at IS NULL",
                (existing["replacement_event_id"], user["family_id"]),
            )
        ).fetchone()
        if replacement is not None:
            await _update_local_event(
                db,
                replacement["id"],
                updates=updates,
                user=user,
                now=now,
            )
            return replacement["id"]

    replacement_updates = dict(updates)
    replacement_updates["recurrence_rule"] = None
    replacement_id = await _insert_local_event(
        db,
        source=series,
        start_time=occurrence.start_value,
        end_time=occurrence.end_value,
        recurrence_rule=None,
        updates=replacement_updates,
        user=user,
        now=now,
    )
    if existing is None:
        await db.execute(
            """
            INSERT INTO calendar_event_exceptions
                (id, series_id, occurrence_start, action, replacement_event_id,
                 family_id, created_at, updated_at, created_by, client_id,
                 client_timestamp)
            VALUES (?, ?, ?, 'replacement', ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                series["id"],
                occurrence.key,
                replacement_id,
                user["family_id"],
                now,
                now,
                user["id"],
                updates.get("client_id"),
                updates.get("client_timestamp"),
            ),
        )
    else:
        await save_history(
            db,
            "calendar_event_exceptions",
            existing["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE calendar_event_exceptions SET action = 'replacement', "
            "replacement_event_id = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (replacement_id, now, existing["id"], user["family_id"]),
        )
    return replacement_id


async def split_series(
    db,
    *,
    series: dict,
    occurrence: ResolvedOccurrence,
    updates: dict,
    user: dict,
) -> str:
    """End the original series before an occurrence and create its new suffix."""
    now = datetime.now(timezone.utc).isoformat()
    suffix_rule = _suffix_rule(series["recurrence_rule"], occurrence.occurrences_before)
    if "start_time" in updates and "recurrence_rule" not in updates:
        edited_start = _parse_datetime(
            updates["start_time"],
            date_timezone=occurrence.start.tzinfo,
        )
        suffix_rule = _rule_shifted_to_new_start(
            suffix_rule,
            occurrence.start,
            edited_start,
        )
    suffix_id = await _insert_local_event(
        db,
        source=series,
        start_time=occurrence.start_value,
        end_time=occurrence.end_value,
        recurrence_rule=suffix_rule,
        updates=updates,
        user=user,
        now=now,
    )
    # Future one-off decisions belonged to the old future. Retire them (and any
    # replacement rows) before installing the new suffix; history keeps this
    # recoverable and avoids duplicated occurrences after a timing/rule change.
    await _retire_exceptions_from(db, series, occurrence, user=user, now=now)
    await _truncate_before(db, series, occurrence, user=user, now=now)
    return suffix_id


async def cancel_occurrence(
    db,
    *,
    series: dict,
    occurrence: ResolvedOccurrence,
    user: dict,
    client_id: str | None = None,
    client_timestamp: str | None = None,
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    existing = await (
        await db.execute(
            "SELECT * FROM calendar_event_exceptions "
            "WHERE family_id = ? AND series_id = ? AND occurrence_start = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], series["id"], occurrence.key),
        )
    ).fetchone()
    if existing is None:
        await db.execute(
            """
            INSERT INTO calendar_event_exceptions
                (id, series_id, occurrence_start, action, replacement_event_id,
                 family_id, created_at, updated_at, created_by, client_id,
                 client_timestamp)
            VALUES (?, ?, ?, 'cancelled', NULL, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                series["id"],
                occurrence.key,
                user["family_id"],
                now,
                now,
                user["id"],
                client_id,
                client_timestamp,
            ),
        )
        return
    existing_data = dict(existing)
    if existing_data.get("replacement_event_id"):
        await _soft_delete_event(
            db,
            existing_data["replacement_event_id"],
            user=user,
            now=now,
        )
    await save_history(
        db,
        "calendar_event_exceptions",
        existing_data["id"],
        user["id"],
        family_id=user["family_id"],
    )
    await db.execute(
        "UPDATE calendar_event_exceptions SET action = 'cancelled', "
        "replacement_event_id = NULL, updated_at = ?, client_id = ?, "
        "client_timestamp = ? WHERE id = ? AND family_id = ?",
        (
            now,
            client_id,
            client_timestamp,
            existing_data["id"],
            user["family_id"],
        ),
    )


async def truncate_series(
    db,
    *,
    series: dict,
    occurrence: ResolvedOccurrence,
    user: dict,
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    await _retire_exceptions_from(db, series, occurrence, user=user, now=now)
    await _truncate_before(db, series, occurrence, user=user, now=now)


async def soft_delete_series_tree(db, *, series: dict, user: dict) -> None:
    """Soft-delete a series and every replacement occurrence linked to it."""
    now = datetime.now(timezone.utc).isoformat()
    await _retire_exceptions_from(db, series, None, user=user, now=now)
    await _soft_delete_event(db, series["id"], user=user, now=now)
