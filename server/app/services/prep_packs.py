"""Deterministic calendar-to-checklist preparation packs."""

from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from dateutil.rrule import rrulestr

from app.services.calendar_recurrence import exception_keys_for_series, occurrence_key
from app.services.family_people import family_person_type

DEFAULT_PACKS = (
    {
        "key": "swimming",
        "name": "Swimming",
        "match_terms": ["swimming", "swim lesson"],
        "items": ["Pack swim kit", "Pack goggles", "Pack towels"],
        "lead_hours": 24,
    },
    {
        "key": "football",
        "name": "Football",
        "match_terms": ["football"],
        "items": ["Pack football kit", "Pack boots", "Fill water bottle"],
        "lead_hours": 24,
    },
    {
        "key": "pe",
        "name": "PE",
        "match_terms": ["pe", "p.e."],
        "items": ["Pack PE kit", "Pack trainers", "Fill water bottle"],
        "lead_hours": 24,
    },
    {
        "key": "school-trip",
        "name": "Synthetic public demo record 18",
        "match_terms": ["school trip"],
        "items": ["Pack lunch", "Fill water bottle", "Pack a weather-ready coat"],
        "lead_hours": 36,
    },
)


def _zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("Europe/London")


def _parse_start(value: str, zone: ZoneInfo) -> datetime:
    if len(value) == 10:
        return datetime.combine(datetime.fromisoformat(value).date(), time.min, tzinfo=zone)
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=zone)
    return parsed


def _canonical(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


def _display_start(value: datetime, *, all_day: bool, zone: ZoneInfo) -> str:
    local = value.astimezone(zone)
    return local.date().isoformat() if all_day else local.isoformat()


def _matches(title: str, terms: list[str]) -> bool:
    normalised = re.sub(r"[^a-z0-9]+", " ", title.casefold()).strip()
    padded = f" {normalised} "
    for term in terms:
        candidate = re.sub(r"[^a-z0-9]+", " ", term.casefold()).strip()
        if candidate and f" {candidate} " in padded:
            return True
    return False


def _occurrences(
    row: dict,
    *,
    start: datetime,
    end: datetime,
    excluded_occurrence_starts: set[str] | None = None,
) -> list[datetime]:
    event_start = _parse_start(row["start_time"], start.tzinfo)  # type: ignore[arg-type]
    if not row.get("recurrence_rule"):
        return [event_start] if start <= event_start <= end else []
    try:
        rule = rrulestr(row["recurrence_rule"], dtstart=event_start)
        occurrences = list(rule.between(start, end, inc=True))[:100]
    except (TypeError, ValueError):
        occurrences = [event_start] if start <= event_start <= end else []
    all_day = bool(row.get("all_day")) or len(row["start_time"]) == 10
    excluded = excluded_occurrence_starts or set()
    return [
        occurrence
        for occurrence in occurrences
        if occurrence_key(occurrence, all_day=all_day) not in excluded
    ]


def template_response(row) -> dict:
    item = dict(row)
    item["match_terms"] = json.loads(item.pop("match_terms"))
    item["items"] = json.loads(item.pop("items"))
    item["enabled"] = bool(item["enabled"])
    return item


async def ensure_default_templates(db, family_id: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    for pack in DEFAULT_PACKS:
        template_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"hausklar:{family_id}:prep:{pack['key']}"))
        await db.execute(
            """INSERT OR IGNORE INTO event_prep_templates
               (id, name, match_terms, items, lead_hours, enabled, family_id,
                created_at, updated_at, created_by, client_id)
               VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, 'hausklar-defaults', ?)""",
            (
                template_id,
                pack["name"],
                json.dumps(pack["match_terms"]),
                json.dumps(pack["items"]),
                pack["lead_hours"],
                family_id,
                now,
                now,
                f"default-prep:{pack['key']}",
            ),
        )
    await db.commit()


async def list_templates(db, family_id: str, *, enabled_only: bool = False) -> list[dict]:
    await ensure_default_templates(db, family_id)
    query = "SELECT * FROM event_prep_templates WHERE family_id = ? AND deleted_at IS NULL"
    if enabled_only:
        query += " AND enabled = 1"
    query += " ORDER BY name COLLATE NOCASE"
    rows = await (await db.execute(query, (family_id,))).fetchall()
    return [template_response(row) for row in rows]


async def suggestions(
    db,
    *,
    family_id: str,
    timezone_name: str,
    horizon_days: int,
    now: datetime | None = None,
) -> list[dict]:
    zone = _zone(timezone_name)
    local_now = (now or datetime.now(timezone.utc)).astimezone(zone)
    window_start = datetime.combine(local_now.date(), time.min, tzinfo=zone)
    window_end = window_start + timedelta(days=horizon_days + 1)
    templates = await list_templates(db, family_id, enabled_only=True)
    if not templates:
        return []

    dated_rows = await (
        await db.execute(
            """SELECT id, title, start_time, all_day, recurrence_rule
               FROM calendar_events
               WHERE family_id = ? AND deleted_at IS NULL
                 AND NOT EXISTS (
                     SELECT 1 FROM calendar_events replacement
                     WHERE replacement.overridden_event_id = calendar_events.id
                       AND replacement.family_id = calendar_events.family_id
                       AND replacement.deleted_at IS NULL
                 )
                 AND recurrence_rule IS NULL AND start_time >= ? AND start_time < ?
               ORDER BY start_time LIMIT 250""",
            (
                family_id,
                (window_start - timedelta(days=1)).date().isoformat(),
                (window_end + timedelta(days=1)).date().isoformat(),
            ),
        )
    ).fetchall()
    recurring_rows = await (
        await db.execute(
            """SELECT id, title, start_time, all_day, recurrence_rule
               FROM calendar_events
               WHERE family_id = ? AND deleted_at IS NULL AND recurrence_rule IS NOT NULL
                 AND NOT EXISTS (
                     SELECT 1 FROM calendar_events replacement
                     WHERE replacement.overridden_event_id = calendar_events.id
                       AND replacement.family_id = calendar_events.family_id
                       AND replacement.deleted_at IS NULL
                 )
               ORDER BY updated_at DESC LIMIT 100""",
            (family_id,),
        )
    ).fetchall()
    rows = [*dated_rows, *recurring_rows]
    excluded_occurrences = await exception_keys_for_series(
        db,
        family_id=family_id,
        series_ids=[row["id"] for row in recurring_rows],
    )
    existing_rows = await (
        await db.execute(
            """SELECT template_id, event_id, occurrence_start
               FROM event_prep_occurrences
               WHERE family_id = ? AND deleted_at IS NULL""",
            (family_id,),
        )
    ).fetchall()
    existing = {(row[0], row[1], row[2]) for row in existing_rows}

    found: list[dict] = []
    for raw in rows:
        event = dict(raw)
        matching = [template for template in templates if _matches(event["title"], template["match_terms"])]
        if not matching:
            continue
        # Most specific phrase wins when two family templates overlap.
        template = max(matching, key=lambda item: max(len(term) for term in item["match_terms"]))
        for occurrence in _occurrences(
            event,
            start=window_start,
            end=window_end,
            excluded_occurrence_starts=excluded_occurrences.get(event["id"]),
        ):
            occurrence_start = _canonical(occurrence)
            identity = (template["id"], event["id"], occurrence_start)
            if identity in existing or local_now < occurrence.astimezone(zone) - timedelta(
                hours=template["lead_hours"]
            ):
                continue
            found.append(
                {
                    "id": f"{template['id']}:{event['id']}:{occurrence_start}",
                    "template_id": template["id"],
                    "template_name": template["name"],
                    "event_id": event["id"],
                    "event_title": event["title"],
                    "event_all_day": bool(event["all_day"]),
                    "event_start": _display_start(
                        occurrence, all_day=bool(event["all_day"]), zone=zone
                    ),
                    "occurrence_start": occurrence_start,
                    "items": template["items"],
                    "lead_hours": template["lead_hours"],
                    "assigned_to": template["assigned_to"],
                }
            )
    found.sort(key=lambda item: item["occurrence_start"])
    return found[:10]


async def resolve_action(db, *, family_id: str, action) -> tuple[dict, dict, datetime, ZoneInfo]:
    template_row = await (
        await db.execute(
            "SELECT * FROM event_prep_templates WHERE id = ? AND family_id = ? "
            "AND enabled = 1 AND deleted_at IS NULL",
            (action.template_id, family_id),
        )
    ).fetchone()
    if not template_row:
        raise ValueError("Preparation pack not found")
    event_row = await (
        await db.execute(
            "SELECT id, title, start_time, all_day, recurrence_rule FROM calendar_events "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (action.event_id, family_id),
        )
    ).fetchone()
    if not event_row:
        raise ValueError("Calendar event not found")
    template = template_response(template_row)
    event = dict(event_row)
    if not _matches(event["title"], template["match_terms"]):
        raise ValueError("The event no longer matches this preparation pack")
    zone = _zone(action.timezone)
    wanted = datetime.fromisoformat(action.occurrence_start.replace("Z", "+00:00"))
    window_start = wanted.astimezone(zone) - timedelta(minutes=1)
    window_end = wanted.astimezone(zone) + timedelta(minutes=1)
    excluded_occurrences = await exception_keys_for_series(
        db,
        family_id=family_id,
        series_ids=[event["id"]] if event.get("recurrence_rule") else [],
    )
    valid = next(
        (
            occurrence
            for occurrence in _occurrences(
                event,
                start=window_start,
                end=window_end,
                excluded_occurrence_starts=excluded_occurrences.get(event["id"]),
            )
            if _canonical(occurrence) == _canonical(wanted)
        ),
        None,
    )
    if valid is None:
        raise ValueError("Calendar occurrence is no longer available")
    return template, event, valid, zone


async def apply_pack(db, *, family_id: str, user: dict, action) -> dict:
    template, event, occurrence, zone = await resolve_action(
        db, family_id=family_id, action=action
    )
    assigned_to = action.assigned_to or template["assigned_to"]
    assignee_type = None
    if assigned_to:
        assignee_type = await family_person_type(db, family_id, assigned_to)
        if assignee_type is None:
            raise ValueError("Task assignee is not in this family")

    canonical = _canonical(occurrence)
    await db.execute("BEGIN IMMEDIATE")
    try:
        existing = await (
            await db.execute(
                "SELECT id, status, task_ids FROM event_prep_occurrences "
                "WHERE family_id = ? AND template_id = ? AND event_id = ? "
                "AND occurrence_start = ? AND deleted_at IS NULL",
                (family_id, template["id"], event["id"], canonical),
            )
        ).fetchone()
        if existing:
            if existing["status"] == "dismissed":
                raise ValueError("This preparation pack was dismissed")
            await db.commit()
            return {
                "status": "added",
                "occurrence_id": existing["id"],
                "task_ids": json.loads(existing["task_ids"]),
                "task_count": len(json.loads(existing["task_ids"])),
            }

        now = datetime.now(timezone.utc).isoformat()
        occurrence_id = str(uuid.uuid4())
        task_ids: list[str] = []
        due_date = occurrence.astimezone(zone).date().isoformat()
        for index, title in enumerate(template["items"]):
            task_id = str(uuid.uuid4())
            task_ids.append(task_id)
            await db.execute(
                """INSERT INTO tasks
                   (id, title, description, assigned_to, due_date, category, priority,
                    source_event_id, prep_occurrence_id, family_id, created_at, updated_at,
                    created_by, client_id)
                   VALUES (?, ?, ?, ?, ?, 'household', 2, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    task_id,
                    title,
                    f"For {event['title']}",
                    assigned_to,
                    due_date,
                    event["id"],
                    occurrence_id,
                    family_id,
                    now,
                    now,
                    user["id"],
                    f"prep:{occurrence_id}:{index}",
                ),
            )
            if assigned_to and assignee_type:
                await db.execute(
                    """INSERT INTO task_assignments
                       (id, task_id, assignee_id, assignee_type, family_id,
                        created_at, updated_at, created_by)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        str(uuid.uuid4()),
                        task_id,
                        assigned_to,
                        assignee_type,
                        family_id,
                        now,
                        now,
                        user["id"],
                    ),
                )
        await db.execute(
            """INSERT INTO event_prep_occurrences
               (id, template_id, event_id, occurrence_start, status, task_ids,
                family_id, created_at, updated_at, created_by, client_id)
               VALUES (?, ?, ?, ?, 'added', ?, ?, ?, ?, ?, ?)""",
            (
                occurrence_id,
                template["id"],
                event["id"],
                canonical,
                json.dumps(task_ids),
                family_id,
                now,
                now,
                user["id"],
                f"prep-occurrence:{template['id']}:{event['id']}:{canonical}",
            ),
        )
        await db.commit()
        return {
            "status": "added",
            "occurrence_id": occurrence_id,
            "task_ids": task_ids,
            "task_count": len(task_ids),
        }
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


async def dismiss_pack(db, *, family_id: str, user: dict, action) -> dict:
    template, event, occurrence, _zone_value = await resolve_action(
        db, family_id=family_id, action=action
    )
    canonical = _canonical(occurrence)
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        existing = await (
            await db.execute(
                "SELECT status FROM event_prep_occurrences WHERE family_id = ? "
                "AND template_id = ? AND event_id = ? AND occurrence_start = ? "
                "AND deleted_at IS NULL",
                (family_id, template["id"], event["id"], canonical),
            )
        ).fetchone()
        if existing:
            await db.commit()
            return {"status": existing["status"]}
        await db.execute(
            """INSERT INTO event_prep_occurrences
           (id, template_id, event_id, occurrence_start, status, task_ids,
            family_id, created_at, updated_at, created_by, client_id)
           VALUES (?, ?, ?, ?, 'dismissed', '[]', ?, ?, ?, ?, ?)""",
            (
                str(uuid.uuid4()), template["id"], event["id"], canonical, family_id,
                now, now, user["id"],
                f"prep-dismiss:{template['id']}:{event['id']}:{canonical}",
            ),
        )
        await db.commit()
        return {"status": "dismissed"}
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
