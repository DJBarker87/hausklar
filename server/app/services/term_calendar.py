"""Keep read-only calendar boundary events in sync with term-date records."""

from __future__ import annotations

import uuid
from collections.abc import Collection
from datetime import date, datetime, timedelta, timezone

from app.services.calendar_overrides import soft_delete_overrides_for_sources
from app.services.record_history import save_history

TERM_CALENDAR_ACTOR = "term-calendar"
_TERM_EVENT_NAMESPACE = uuid.UUID("e7d1bf94-41cb-4f3c-a6aa-43ddfda72357")
_GENERATED_DESCRIPTION = "Automatically generated from term dates."


def _event_id(term_id: str, boundary: str) -> str:
    """Return a stable ID so retries cannot create duplicate boundary events."""
    return str(uuid.uuid5(_TERM_EVENT_NAMESPACE, f"{term_id}:{boundary}"))


def _title(person_name: str, label: str | None, boundary: str) -> str:
    term_name = label.strip() if label and label.strip() else "term"
    if boundary == "first":
        boundary_name = "First day"
    elif boundary == "last":
        boundary_name = "Last day"
    else:
        boundary_name = "First and last day"
    return f"{person_name} — {boundary_name} of {term_name}"


def _desired_events(term: dict) -> list[dict]:
    """Build the generated event rows for one valid, active term."""
    try:
        start_date = date.fromisoformat(term["start_date"])
        end_date = date.fromisoformat(term["end_date"])
    except (TypeError, ValueError):
        return []
    if end_date < start_date:
        return []

    if start_date == end_date:
        boundaries = [("first_last", start_date)]
    else:
        boundaries = [("first", start_date), ("last", end_date)]

    desired_events: list[dict] = []
    for boundary, boundary_date in boundaries:
        try:
            exclusive_end = boundary_date + timedelta(days=1)
        except OverflowError:
            # Malformed legacy/scraped rows must not prevent database startup.
            continue
        desired_events.append(
            {
                "id": _event_id(term["id"], boundary),
                "title": _title(term["person_name"], term.get("label"), boundary),
                "description": _GENERATED_DESCRIPTION,
                "start_time": boundary_date.isoformat(),
                # All-day event ends are exclusive, matching iCalendar DTEND.
                "end_time": exclusive_end.isoformat(),
                "all_day": 1,
                "recurrence_rule": None,
                "location": None,
                "family_member_ids": None,
                "affected_member_ids": None,
                "assigned_to": term["person_id"],
                "event_type": "school",
                "exertion": 0,
                "source_document_id": None,
                "calendar_source_id": None,
                "external_uid": None,
                "external_instance_key": None,
                "source_term_date_id": term["id"],
                "term_boundary": boundary,
                "read_only": 1,
                "family_id": term["family_id"],
                "client_id": None,
                "client_timestamp": None,
            }
        )
    return desired_events


def _in_clause(values: Collection[str]) -> tuple[str, list[str]]:
    items = sorted(set(values))
    return ", ".join("?" for _ in items), items


def _row_dicts(cursor, rows) -> list[dict]:
    """Support app Row connections and plain aiosqlite tuple connections."""
    columns = [description[0] for description in cursor.description]
    return [
        dict(row) if hasattr(row, "keys") else dict(zip(columns, row, strict=True)) for row in rows
    ]


async def suppress_overlapping_scraped_terms(
    db,
    *,
    family_id: str,
    person_id: str,
    start_date: str,
    end_date: str,
    actor_id: str,
    exclude_term_id: str | None = None,
) -> int:
    """Soft-delete auto terms shadowed by a manual term, without committing."""
    # Validate again at the service boundary because this helper may be reused
    # outside the Pydantic-backed routes.
    parsed_start = date.fromisoformat(start_date)
    parsed_end = date.fromisoformat(end_date)
    if parsed_end < parsed_start:
        raise ValueError("Term end date must be on or after its start date")

    query = """
        SELECT * FROM term_dates
        WHERE family_id = ? AND person_id = ?
          AND created_by = 'term-scraper' AND user_overridden = 0
          AND deleted_at IS NULL
          AND start_date <= ? AND end_date >= ?
    """
    params = [family_id, person_id, end_date, start_date]
    if exclude_term_id:
        query += " AND id != ?"
        params.append(exclude_term_id)
    cursor = await db.execute(query, params)
    rows = _row_dicts(cursor, await cursor.fetchall())
    if not rows:
        return 0

    now = datetime.now(timezone.utc).isoformat()
    for row in rows:
        await save_history(
            db,
            "term_dates",
            row["id"],
            actor_id,
            family_id=family_id,
        )
        await db.execute(
            "UPDATE term_dates SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (now, now, row["id"]),
        )
    return len(rows)


async def reconcile_term_boundary_events(
    db,
    *,
    family_id: str | None = None,
    term_ids: Collection[str] | None = None,
    person_ids: Collection[str] | None = None,
    actor_id: str = TERM_CALENDAR_ACTOR,
) -> int:
    """Reconcile generated first/last-day events without committing.

    Callers can scope a retry to term IDs, a family, or selected people. With
    no scope the function reconciles every family-backed term. The helper is
    deliberately transaction-neutral so term writes and their calendar events
    can be committed atomically by both CRUD routes and bulk scrapers.
    """
    term_conditions: list[str] = []
    term_params: list[str] = []
    event_conditions = ["ce.source_term_date_id IS NOT NULL"]
    event_params: list[str] = []

    if family_id is not None:
        term_conditions.append("td.family_id = ?")
        term_params.append(family_id)
        event_conditions.append("ce.family_id = ?")
        event_params.append(family_id)
    if term_ids:
        placeholders, values = _in_clause(term_ids)
        term_conditions.append(f"td.id IN ({placeholders})")
        term_params.extend(values)
        event_conditions.append(f"ce.source_term_date_id IN ({placeholders})")
        event_params.extend(values)
    if person_ids:
        placeholders, values = _in_clause(person_ids)
        term_conditions.append(f"td.person_id IN ({placeholders})")
        term_params.extend(values)
        event_conditions.append(
            "EXISTS (SELECT 1 FROM term_dates scoped_td "
            "WHERE scoped_td.id = ce.source_term_date_id "
            f"AND scoped_td.person_id IN ({placeholders}))"
        )
        event_params.extend(values)

    where_terms = f"WHERE {' AND '.join(term_conditions)}" if term_conditions else ""
    cursor = await db.execute(
        f"""
        SELECT td.*,
               COALESCE(u.name, c.name) AS person_name
        FROM term_dates td
        LEFT JOIN users u
          ON u.id = td.person_id
         AND u.family_id = td.family_id
         AND u.deleted_at IS NULL
        LEFT JOIN children c
          ON c.id = td.person_id
         AND c.family_id = td.family_id
         AND c.deleted_at IS NULL
        {where_terms}
        """,
        term_params,
    )
    term_rows = _row_dicts(cursor, await cursor.fetchall())

    cursor = await db.execute(
        f"SELECT ce.* FROM calendar_events ce WHERE {' AND '.join(event_conditions)}",
        event_params,
    )
    event_rows = _row_dicts(cursor, await cursor.fetchall())

    desired_by_key: dict[tuple[str, str], dict] = {}
    for term in term_rows:
        if (
            term.get("deleted_at") is not None
            or not term.get("family_id")
            or not term.get("person_name")
        ):
            continue
        for desired in _desired_events(term):
            desired_by_key[(desired["source_term_date_id"], desired["term_boundary"])] = desired

    existing_by_key: dict[tuple[str, str], list[dict]] = {}
    for event in event_rows:
        boundary = event.get("term_boundary")
        source_term_id = event.get("source_term_date_id")
        if not boundary or not source_term_id:
            continue
        existing_by_key.setdefault((source_term_id, boundary), []).append(event)

    now = datetime.now(timezone.utc).isoformat()
    changed = 0
    claimed_ids: set[str] = set()

    for key, desired in desired_by_key.items():
        candidates = existing_by_key.get(key, [])
        candidates.sort(
            key=lambda row: (
                row.get("deleted_at") is not None,
                row["id"] != desired["id"],
                row.get("created_at") or "",
            )
        )
        existing = candidates[0] if candidates else None
        if existing is None:
            await db.execute(
                """
                INSERT INTO calendar_events
                    (id, title, description, start_time, end_time, all_day,
                     recurrence_rule, location, family_member_ids, affected_member_ids,
                     assigned_to, event_type, exertion, source_document_id,
                     calendar_source_id, external_uid, external_instance_key,
                     source_term_date_id, term_boundary, read_only, family_id,
                     created_at, updated_at, created_by, client_id, client_timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?)
                """,
                (
                    desired["id"],
                    desired["title"],
                    desired["description"],
                    desired["start_time"],
                    desired["end_time"],
                    desired["all_day"],
                    desired["recurrence_rule"],
                    desired["location"],
                    desired["family_member_ids"],
                    desired["affected_member_ids"],
                    desired["assigned_to"],
                    desired["event_type"],
                    desired["exertion"],
                    desired["source_document_id"],
                    desired["calendar_source_id"],
                    desired["external_uid"],
                    desired["external_instance_key"],
                    desired["source_term_date_id"],
                    desired["term_boundary"],
                    desired["read_only"],
                    desired["family_id"],
                    now,
                    now,
                    actor_id,
                    desired["client_id"],
                    desired["client_timestamp"],
                ),
            )
            claimed_ids.add(desired["id"])
            changed += 1
            continue

        claimed_ids.add(existing["id"])
        comparable_fields = tuple(desired)
        needs_update = existing.get("deleted_at") is not None or any(
            existing.get(field) != desired[field] for field in comparable_fields if field != "id"
        )
        if not needs_update:
            continue
        await save_history(
            db,
            "calendar_events",
            existing["id"],
            actor_id,
            family_id=desired["family_id"],
        )
        assignments = ", ".join(f"{field} = ?" for field in comparable_fields if field != "id")
        values = [desired[field] for field in comparable_fields if field != "id"]
        await db.execute(
            f"UPDATE calendar_events SET {assignments}, deleted_at = NULL, updated_at = ? WHERE id = ?",
            [*values, now, existing["id"]],
        )
        changed += 1

    # Any active generated event in scope that is no longer desired belongs to
    # a deleted/changed term boundary. Manual events have no source term and are
    # never considered here.
    for event in event_rows:
        if event["id"] in claimed_ids or event.get("deleted_at") is not None:
            continue
        key = (event.get("source_term_date_id"), event.get("term_boundary"))
        if key in desired_by_key:
            # A duplicate inactive candidate can coexist, but the active unique
            # index guarantees only the claimed event is active.
            continue
        event_family_id = event.get("family_id")
        if not event_family_id:
            continue
        await save_history(
            db,
            "calendar_events",
            event["id"],
            actor_id,
            family_id=event_family_id,
        )
        await soft_delete_overrides_for_sources(
            db,
            [event["id"]],
            family_id=event_family_id,
            actor_id=actor_id,
            now=now,
        )
        await db.execute(
            "UPDATE calendar_events SET deleted_at = ?, updated_at = ? WHERE id = ?",
            (now, now, event["id"]),
        )
        changed += 1

    return changed
