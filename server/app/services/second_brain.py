"""Second Brain — deterministic logistics detection (clashes, tight turnarounds).

Unlike School Brain (an LLM cross-check for fuzzy gaps), logistics is arithmetic:
who needs to be where, when, and whether that's physically possible. Doing it
deterministically makes it reliable and free, and it feeds the same insights.
"""

import json
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app.database import database_lease
from app.services.insights_store import store_insights

logger = logging.getLogger(__name__)

LOCAL = ZoneInfo("Europe/London")
_CREATED_BY = "second-brain"
_HORIZON_DAYS = 10
_DEFAULT_DURATION = timedelta(minutes=60)
_TURNAROUND_GAP = timedelta(minutes=25)
_MAX_FINDINGS = 5


def _parse_instant(value: str) -> datetime | None:
    try:
        if len(value) == 10:
            return None  # all-day events don't create time clashes
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=LOCAL)
        return parsed
    except ValueError:
        return None


def _people_of(row: dict) -> set[str]:
    people = set()
    if row["assigned_to"]:
        people.add(row["assigned_to"])
    try:
        people.update(json.loads(row["family_member_ids"] or "[]"))
    except (json.JSONDecodeError, TypeError):
        pass
    return {p for p in people if p}


def _time_label(instant: datetime) -> str:
    local = instant.astimezone(LOCAL)
    minute = f":{local.minute:02d}" if local.minute else ""
    marker = "am" if local.hour < 12 else "pm"
    hour = local.hour % 12 or 12
    return f"{hour}{minute}{marker}"


def _detect(rows: list[dict], names: dict[str, str]) -> list[dict]:
    events = []
    for row in rows:
        start = _parse_instant(row["start_time"])
        if start is None:
            continue
        end = _parse_instant(row["end_time"]) if row["end_time"] else None
        if end is None or end <= start:
            end = start + _DEFAULT_DURATION
        events.append(
            {
                "title": (row["title"] or "Event")[:120],
                "start": start,
                "end": end,
                "location": (row["location"] or "").strip() or None,
                "people": _people_of(row),
            }
        )
    events.sort(key=lambda item: item["start"])

    findings: list[dict] = []
    seen: set[tuple] = set()

    def add(kind: str, message: str, detail: str, target: datetime) -> None:
        key = (message.lower(), target.astimezone(LOCAL).date().isoformat())
        if key in seen or len(findings) >= _MAX_FINDINGS:
            return
        seen.add(key)
        findings.append(
            {
                "kind": kind,
                "message": message[:200],
                "detail": detail[:500] if detail else None,
                "target_date": target.astimezone(LOCAL).date().isoformat(),
                "source_document_id": None,
            }
        )

    for i, a in enumerate(events):
        for b in events[i + 1 :]:
            if b["start"] >= a["end"]:
                break  # sorted by start; nothing later can overlap a
            # Overlapping in time.
            different_places = (
                a["location"] and b["location"] and a["location"] != b["location"]
            )
            different_people = bool(a["people"] and b["people"] and not (a["people"] & b["people"]))
            if not (different_places or different_people):
                continue
            who_a = ", ".join(sorted(names.get(p, "someone") for p in a["people"])) or "Someone"
            who_b = ", ".join(sorted(names.get(p, "someone") for p in b["people"])) or "someone"
            where = ""
            if a["location"] and b["location"]:
                where = f" — {a['location']} and {b['location']}"
            message = (
                f"Clash: {who_a} at {a['title']} ({_time_label(a['start'])}) "
                f"and {who_b} at {b['title']} ({_time_label(b['start'])}) overlap"
            )
            detail = (
                f"These two overlap{where}. You'll likely need two of you, or to move one."
            )
            add("conflict", message, detail, a["start"])

    # Tight turnarounds: same person, back-to-back at different places.
    by_person: dict[str, list[dict]] = {}
    for event in events:
        for person in event["people"]:
            by_person.setdefault(person, []).append(event)
    for person, person_events in by_person.items():
        person_events.sort(key=lambda item: item["start"])
        for earlier, later in zip(person_events, person_events[1:]):
            gap = later["start"] - earlier["end"]
            if timedelta(0) <= gap < _TURNAROUND_GAP and earlier["location"] and later["location"] \
                    and earlier["location"] != later["location"]:
                minutes = int(gap.total_seconds() // 60)
                name = names.get(person, "Someone")
                message = (
                    f"Tight turnaround: {name} has {earlier['title']} then {later['title']} "
                    f"{minutes} min apart"
                )
                detail = (
                    f"{earlier['location']} to {later['location']} with only {minutes} minutes "
                    f"between them — check that's enough travel time."
                )
                add("conflict", message, detail, later["start"])

    return findings


async def detect_logistics(family_id: str) -> list[dict]:
    """Scan the next 10 days for clashes and tight turnarounds; store new ones."""
    today = datetime.now(LOCAL).date()
    now = datetime.now(timezone.utc).isoformat()
    horizon = (today + timedelta(days=_HORIZON_DAYS)).isoformat()

    async with database_lease() as db:
        # Retire clashes for days that have passed.
        await db.execute(
            """UPDATE family_insights SET status = 'dismissed', updated_at = ?
               WHERE family_id = ? AND status = 'active' AND deleted_at IS NULL
                 AND created_by = ? AND target_date IS NOT NULL AND target_date < ?""",
            (now, family_id, _CREATED_BY, today.isoformat()),
        )
        await db.commit()

        cursor = await db.execute(
            """
            SELECT id, name FROM users WHERE family_id = ? AND deleted_at IS NULL
            UNION ALL
            SELECT id, name FROM children WHERE family_id = ? AND deleted_at IS NULL
            """,
            (family_id, family_id),
        )
        names = {row["id"]: row["name"] for row in await cursor.fetchall()}

        cursor = await db.execute(
            """
            SELECT title, start_time, end_time, all_day, location, assigned_to, family_member_ids
            FROM calendar_events
            WHERE family_id = ? AND deleted_at IS NULL AND all_day = 0
              AND recurrence_rule IS NULL
              AND start_time >= ? AND start_time < ?
            ORDER BY start_time
            LIMIT 200
            """,
            (family_id, today.isoformat(), horizon),
        )
        rows = [dict(row) for row in await cursor.fetchall()]

    findings = _detect(rows, names)
    if not findings:
        return []
    async with database_lease() as db:
        return await store_insights(db, family_id=family_id, findings=findings, created_by=_CREATED_BY)


async def run_second_brain() -> None:
    """Run logistics detection for every family with an active user."""
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT DISTINCT family_id FROM users "
            "WHERE deleted_at IS NULL AND family_id IS NOT NULL"
        )
        family_ids = [row["family_id"] for row in await cursor.fetchall()]
    for family_id in family_ids:
        try:
            found = await detect_logistics(family_id)
            logger.info("Second brain stored %d logistics insights for family %s", len(found), family_id)
        except Exception:
            logger.exception("Second brain failed for family %s", family_id)
