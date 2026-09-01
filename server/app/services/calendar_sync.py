"""Secure read-only ICS ingestion and private HausKlar calendar feeds."""

from __future__ import annotations

import asyncio
import hashlib
import ipaddress
import json
import secrets
import socket
import uuid
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

import httpx
from dateutil.rrule import rrulestr
from icalendar import Calendar, Event

from app.database import database_lease
from app.services.calendar_overrides import soft_delete_overrides_for_sources
from app.services.school_rugby import (
    SCHOOL_RUGBY_SOURCE_KIND,
    SchoolRugbyError,
    apply_rugby_venue,
    current_school_season,
    discover_rugby_teams,
    parse_rugby_source_config,
    rugby_fixture_feed_url,
    rugby_source_config,
    transform_rugby_events,
)
from app.services.record_history import save_history
from app.utils.encryption import decrypt_value, encrypt_value

MAX_ICS_BYTES = 2 * 1024 * 1024
MAX_IMPORTED_OCCURRENCES = 2_000
IMPORT_PAST_DAYS = 45
IMPORT_FUTURE_DAYS = 400


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)
FETCH_TIMEOUT = httpx.Timeout(20.0, connect=8.0)
LOCAL_TIMEZONE = ZoneInfo("Europe/London")


class CalendarSyncError(ValueError):
    """A safe, user-facing calendar synchronization error."""


@dataclass(frozen=True)
class FetchedCalendar:
    body: bytes | None
    etag: str | None
    last_modified: str | None
    unchanged: bool = False


def _is_public_address(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return not (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_reserved
        or address.is_unspecified
    )


async def validate_public_https_url(value: str) -> tuple[str, str]:
    """Validate an admin-supplied feed URL before any network request."""
    candidate = value.strip()
    parsed = urlparse(candidate)
    hostname = (parsed.hostname or "").strip().lower().rstrip(".")
    if (
        parsed.scheme != "https"
        or not hostname
        or parsed.username
        or parsed.password
        or parsed.fragment
        or parsed.port not in (None, 443)
        or hostname.endswith((".local", ".localhost", ".internal"))
    ):
        raise CalendarSyncError("Calendar URL must be a public HTTPS address")
    try:
        addresses = await asyncio.get_running_loop().run_in_executor(
            None,
            lambda: socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM),
        )
    except socket.gaierror as exc:
        raise CalendarSyncError("Calendar host could not be resolved") from exc
    resolved = {item[4][0] for item in addresses}
    if not resolved or any(not _is_public_address(item) for item in resolved):
        raise CalendarSyncError("Calendar host must resolve only to public addresses")
    return candidate, hostname


async def fetch_calendar(
    url: str,
    *,
    etag: str | None = None,
    last_modified: str | None = None,
) -> FetchedCalendar:
    """Fetch one bounded calendar without redirects or credential leakage."""
    validated_url, _ = await validate_public_https_url(url)
    headers = {"Accept": "text/calendar, application/ics;q=0.9", "User-Agent": "HausKlar/1.0"}
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    try:
        async with httpx.AsyncClient(timeout=FETCH_TIMEOUT, follow_redirects=False) as client:
            async with client.stream("GET", validated_url, headers=headers) as response:
                if response.status_code == 304:
                    return FetchedCalendar(None, etag, last_modified, unchanged=True)
                if 300 <= response.status_code < 400:
                    raise CalendarSyncError("Calendar feed redirects are not accepted")
                response.raise_for_status()
                declared = response.headers.get("content-length")
                if declared and int(declared) > MAX_ICS_BYTES:
                    raise CalendarSyncError("Calendar feed is larger than 2 MB")
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body.extend(chunk)
                    if len(body) > MAX_ICS_BYTES:
                        raise CalendarSyncError("Calendar feed is larger than 2 MB")
    except CalendarSyncError:
        raise
    except (httpx.HTTPError, ValueError) as exc:
        raise CalendarSyncError("Calendar feed could not be downloaded") from exc
    if b"BEGIN:VCALENDAR" not in bytes(body[:2_048]).upper():
        raise CalendarSyncError("The address did not return an ICS calendar")
    return FetchedCalendar(
        bytes(body),
        response.headers.get("etag"),
        response.headers.get("last-modified"),
    )


def _decoded(component, name: str):
    try:
        return component.decoded(name)
    except (KeyError, ValueError, TypeError):
        return None


def _aware(value: date | datetime) -> datetime:
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=LOCAL_TIMEZONE)
        return value
    return datetime.combine(value, time.min, tzinfo=LOCAL_TIMEZONE)


def _instance_key(value: date | datetime) -> str:
    if isinstance(value, datetime):
        return _aware(value).astimezone(timezone.utc).isoformat()
    return value.isoformat()


def _text(component, name: str, limit: int) -> str | None:
    value = component.get(name)
    if value is None:
        return None
    cleaned = str(value).replace("\x00", "").strip()
    return cleaned[:limit] or None


def _event_values(component, *, fallback_start: date | datetime | None = None) -> dict | None:
    start = _decoded(component, "dtstart") or fallback_start
    if not isinstance(start, (date, datetime)):
        return None
    all_day = isinstance(start, date) and not isinstance(start, datetime)
    end = _decoded(component, "dtend")
    duration = _decoded(component, "duration")
    if end is None and isinstance(duration, timedelta):
        end = _aware(start) + duration
        if all_day:
            end = end.date()
    if all_day:
        start_text = start.isoformat()
        end_text = end.isoformat() if isinstance(end, date) else None
    else:
        start_text = _aware(start).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        end_text = (
            _aware(end).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
            if isinstance(end, (date, datetime))
            else None
        )
    return {
        "title": _text(component, "summary", 300) or "Untitled event",
        "description": _text(component, "description", 10_000),
        "location": _text(component, "location", 500),
        "start_time": start_text,
        "end_time": end_text,
        "all_day": all_day,
    }


def _excluded_instances(component) -> set[str]:
    excluded: set[str] = set()
    values = component.get("exdate")
    if values is None:
        return excluded
    for value in values if isinstance(values, list) else [values]:
        for item in getattr(value, "dts", []):
            decoded = getattr(item, "dt", None)
            if isinstance(decoded, (date, datetime)):
                excluded.add(_instance_key(decoded))
    return excluded


def parse_calendar(
    body: bytes,
    *,
    source_id: str,
    assigned_to: str | None,
    now: datetime | None = None,
) -> list[dict]:
    """Parse and materialize a bounded set of external occurrences."""
    try:
        calendar = Calendar.from_ical(body)
    except (ValueError, TypeError) as exc:
        raise CalendarSyncError("Calendar feed is not valid ICS") from exc
    reference = (now or _utc_now()).astimezone(timezone.utc)
    window_start = reference - timedelta(days=IMPORT_PAST_DAYS)
    window_end = reference + timedelta(days=IMPORT_FUTURE_DAYS)
    masters: dict[str, object] = {}
    overrides: dict[tuple[str, str], object] = {}
    cancelled: set[tuple[str, str]] = set()
    for component in calendar.walk("VEVENT"):
        uid = (_text(component, "uid", 500) or "").strip()
        if not uid:
            continue
        recurrence_id = _decoded(component, "recurrence-id")
        if isinstance(recurrence_id, (date, datetime)):
            key = (uid, _instance_key(recurrence_id))
            if str(component.get("status", "")).upper() == "CANCELLED":
                cancelled.add(key)
            else:
                overrides[key] = component
        elif str(component.get("status", "")).upper() != "CANCELLED":
            masters[uid] = component

    results: list[dict] = []
    seen: set[str] = set()

    def append_occurrence(uid: str, instance: date | datetime, component, fallback=None) -> None:
        identity = _instance_key(instance)
        external_key = hashlib.sha256(f"{uid}\0{identity}".encode()).hexdigest()
        if external_key in seen or (uid, identity) in cancelled:
            return
        values = _event_values(component, fallback_start=fallback or instance)
        if not values:
            return
        start_dt = _aware(date.fromisoformat(values["start_time"])) if values["all_day"] else _aware(datetime.fromisoformat(values["start_time"].replace("Z", "+00:00")))
        if start_dt.astimezone(timezone.utc) < window_start or start_dt.astimezone(timezone.utc) > window_end:
            return
        seen.add(external_key)
        results.append(
            {
                **values,
                "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"hausklar:{source_id}:{external_key}")),
                "external_uid": uid,
                "external_instance_key": external_key,
                "assigned_to": assigned_to,
            }
        )

    for uid, component in masters.items():
        start = _decoded(component, "dtstart")
        if not isinstance(start, (date, datetime)):
            continue
        rule_value = component.get("rrule")
        if rule_value is None:
            identity = _instance_key(start)
            override = overrides.get((uid, identity), component)
            append_occurrence(uid, start, override, fallback=start)
            continue
        try:
            rule_text = rule_value.to_ical().decode()
            rule = rrulestr(rule_text, dtstart=_aware(start))
            occurrences = rule.between(window_start, window_end, inc=True)
        except (TypeError, ValueError, UnicodeError):
            occurrences = [_aware(start)]
        excluded = _excluded_instances(component)
        for occurrence in occurrences[:MAX_IMPORTED_OCCURRENCES]:
            identity_value: date | datetime = occurrence.date() if isinstance(start, date) and not isinstance(start, datetime) else occurrence
            identity = _instance_key(identity_value)
            if identity in excluded:
                continue
            append_occurrence(
                uid,
                identity_value,
                overrides.get((uid, identity), component),
                fallback=identity_value,
            )
            if len(results) >= MAX_IMPORTED_OCCURRENCES:
                break
        if len(results) >= MAX_IMPORTED_OCCURRENCES:
            break

    for (uid, identity), component in overrides.items():
        if len(results) >= MAX_IMPORTED_OCCURRENCES:
            break
        recurrence_id = _decoded(component, "recurrence-id")
        if isinstance(recurrence_id, (date, datetime)):
            append_occurrence(uid, recurrence_id, component, fallback=recurrence_id)
    return results


async def _mark_source_error(source_id: str, family_id: str, message: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        await db.execute(
            "UPDATE calendar_sources SET last_synced_at=?, last_error=?, updated_at=? "
            "WHERE id=? AND family_id=?",
            (now, message[:500], now, source_id, family_id),
        )
        await db.commit()


async def sync_calendar_source(
    source_id: str,
    *,
    family_id: str,
    fetched_calendar: FetchedCalendar | None = None,
) -> dict:
    """Fetch outside SQLite, then apply one short atomic synchronization."""
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT * FROM calendar_sources WHERE id=? AND family_id=? AND deleted_at IS NULL",
            (source_id, family_id),
        )
        row = await cursor.fetchone()
        affected_user_ids: list[str] = []
        if row and row["source_kind"] == SCHOOL_RUGBY_SOURCE_KIND:
            cursor = await db.execute(
                "SELECT id FROM users WHERE family_id=? AND id<>? "
                "AND deleted_at IS NULL ORDER BY priority DESC, created_at",
                (family_id, row["assigned_to"]),
            )
            affected_user_ids = [person["id"] for person in await cursor.fetchall()]
    if not row:
        raise CalendarSyncError("Calendar source was not found")
    source = dict(row)
    if not source["enabled"]:
        raise CalendarSyncError("Calendar source is disabled")
    try:
        if source.get("source_kind") == SCHOOL_RUGBY_SOURCE_KIND:
            saved_config = parse_rugby_source_config(source.get("config_json"))
            _, current_season = current_school_season()
            if saved_config["season"] != current_season:
                published = await discover_rugby_teams()
                replacement = next(
                    (
                        team
                        for team in published["teams"]
                        if team["name"].casefold() == saved_config["team_name"].casefold()
                    ),
                    None,
                )
                if not replacement:
                    raise SchoolRugbyError(
                        f"{saved_config['team_name']} has not been published for "
                        f"{current_season} yet"
                    )
                replacement_url = rugby_fixture_feed_url(replacement["id"])
                fetched_calendar = await fetch_calendar(replacement_url)
                # Validate the new season before replacing the working source.
                parse_calendar(
                    fetched_calendar.body or b"",
                    source_id=source_id,
                    assigned_to=source.get("assigned_to"),
                )
                replacement_config = rugby_source_config(
                    team_id=replacement["id"],
                    team_name=replacement["name"],
                    season=published["season"],
                )
                encrypted_replacement_url = encrypt_value(replacement_url)
                rollover_time = datetime.now(timezone.utc).isoformat()
                async with database_lease() as db:
                    await db.execute(
                        """UPDATE calendar_sources SET name=?,encrypted_url=?,config_json=?,
                           etag=NULL,last_modified=NULL,updated_at=?
                           WHERE id=? AND family_id=? AND deleted_at IS NULL""",
                        (
                            f"Example School {replacement['name']} rugby",
                            encrypted_replacement_url,
                            replacement_config,
                            rollover_time,
                            source_id,
                            family_id,
                        ),
                    )
                    await db.commit()
                source["name"] = f"Example School {replacement['name']} rugby"
                source["encrypted_url"] = encrypted_replacement_url
                source["config_json"] = replacement_config
                source["etag"] = None
                source["last_modified"] = None
        fetched = fetched_calendar or await fetch_calendar(
            decrypt_value(source["encrypted_url"]),
            etag=source.get("etag"),
            last_modified=source.get("last_modified"),
        )
        if fetched.unchanged:
            now_text = datetime.now(timezone.utc).isoformat()
            async with database_lease() as db:
                await db.execute(
                    "UPDATE calendar_sources SET last_synced_at=?, last_success_at=?, last_error=NULL, updated_at=? WHERE id=? AND family_id=?",
                    (now_text, now_text, now_text, source_id, family_id),
                )
                await db.commit()
            return {"source_id": source_id, "events": 0, "changed": 0, "removed": 0, "unchanged": True}
        events = parse_calendar(
            fetched.body or b"",
            source_id=source_id,
            assigned_to=source.get("assigned_to"),
        )
        if source.get("source_kind") == SCHOOL_RUGBY_SOURCE_KIND:
            if not source.get("assigned_to"):
                raise SchoolRugbyError("The rugby calendar has no owner")
            events = transform_rugby_events(
                events,
                config_json=source.get("config_json"),
                owner_user_id=source["assigned_to"],
                affected_user_ids=affected_user_ids,
            )
    except (CalendarSyncError, SchoolRugbyError) as exc:
        await _mark_source_error(source_id, family_id, str(exc))
        raise CalendarSyncError(str(exc)) from exc

    now_text = datetime.now(timezone.utc).isoformat()
    changed = 0
    removed = 0
    incoming = {event["external_instance_key"]: event for event in events}
    async with database_lease() as db:
        await db.execute("BEGIN IMMEDIATE")
        cursor = await db.execute(
            "SELECT * FROM calendar_events WHERE calendar_source_id=? AND family_id=?",
            (source_id, family_id),
        )
        existing = {row["external_instance_key"]: dict(row) for row in await cursor.fetchall()}
        for key, event in incoming.items():
            old = existing.get(key)
            event.setdefault(
                "family_member_ids",
                [event["assigned_to"]] if event.get("assigned_to") else None,
            )
            event.setdefault("affected_member_ids", None)
            event.setdefault("event_type", "imported")
            event.setdefault("exertion", 0)
            event.setdefault("color", None)
            event.setdefault("rugby_source_venue", None)
            event.setdefault("rugby_venue_override", None)
            if source.get("source_kind") == SCHOOL_RUGBY_SOURCE_KIND and old:
                override = old.get("rugby_venue_override")
                source_venue = event["rugby_source_venue"]
                if override == source_venue:
                    override = None
                event["rugby_venue_override"] = override
                event = apply_rugby_venue(event, override or source_venue)
            participants_json = (
                json.dumps(event["family_member_ids"], separators=(",", ":"))
                if event["family_member_ids"]
                else None
            )
            affected_json = (
                json.dumps(event["affected_member_ids"], separators=(",", ":"))
                if event["affected_member_ids"]
                else None
            )
            comparable = (
                event["title"], event["description"], event["start_time"], event["end_time"],
                int(event["all_day"]), event["location"], event["assigned_to"], participants_json,
                affected_json, event["event_type"], event["exertion"], event["color"],
                event["rugby_source_venue"], event["rugby_venue_override"], event["external_uid"],
            )
            if old:
                previous = (
                    old["title"], old["description"], old["start_time"], old["end_time"],
                    old["all_day"], old["location"], old["assigned_to"], old["family_member_ids"],
                    old["affected_member_ids"], old["event_type"], old["exertion"], old["color"],
                    old["rugby_source_venue"], old["rugby_venue_override"], old["external_uid"],
                )
                if comparable == previous and old["deleted_at"] is None:
                    continue
                await save_history(db, "calendar_events", old["id"], source.get("created_by") or "calendar-sync", family_id=family_id)
                await db.execute(
                    """UPDATE calendar_events SET title=?, description=?, start_time=?, end_time=?, all_day=?,
                       location=?, assigned_to=?, family_member_ids=?, affected_member_ids=?, event_type=?,
                       exertion=?, color=?, rugby_source_venue=?, rugby_venue_override=?, external_uid=?, read_only=1,
                       deleted_at=NULL, updated_at=? WHERE id=? AND family_id=?""",
                    (*comparable, now_text, old["id"], family_id),
                )
            else:
                await db.execute(
                    """INSERT INTO calendar_events
                       (id,title,description,start_time,end_time,all_day,location,family_member_ids,
                        affected_member_ids,assigned_to,event_type,exertion,color,rugby_source_venue,
                        rugby_venue_override,family_id,created_at,updated_at,created_by,calendar_source_id,
                        external_uid,external_instance_key,read_only)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)""",
                    (event["id"], event["title"], event["description"], event["start_time"], event["end_time"],
                     int(event["all_day"]), event["location"], participants_json, affected_json,
                     event["assigned_to"], event["event_type"], event["exertion"], event["color"],
                     event["rugby_source_venue"], event["rugby_venue_override"], family_id,
                     now_text, now_text, source.get("created_by"),
                     source_id, event["external_uid"], key),
                )
            changed += 1
        for key, old in existing.items():
            if key in incoming or old["deleted_at"] is not None:
                continue
            await save_history(db, "calendar_events", old["id"], source.get("created_by") or "calendar-sync", family_id=family_id)
            await soft_delete_overrides_for_sources(
                db,
                [old["id"]],
                family_id=family_id,
                actor_id=source.get("created_by") or "calendar-sync",
                now=now_text,
            )
            await db.execute(
                "UPDATE calendar_events SET deleted_at=?, updated_at=? WHERE id=? AND family_id=?",
                (now_text, now_text, old["id"], family_id),
            )
            removed += 1
        await db.execute(
            """UPDATE calendar_sources SET etag=?, last_modified=?, last_synced_at=?, last_success_at=?,
               last_error=NULL, updated_at=? WHERE id=? AND family_id=?""",
            (fetched.etag, fetched.last_modified, now_text, now_text, now_text, source_id, family_id),
        )
        await db.commit()
    return {"source_id": source_id, "events": len(events), "changed": changed, "removed": removed, "unchanged": False}


async def sync_all_calendar_sources() -> None:
    """Refresh all enabled sources sequentially to bound network and write load."""
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT id, family_id FROM calendar_sources WHERE enabled=1 AND deleted_at IS NULL ORDER BY updated_at"
        )
        sources = await cursor.fetchall()
    for source in sources:
        try:
            await sync_calendar_source(source["id"], family_id=source["family_id"])
        except CalendarSyncError:
            continue


def build_outbound_calendar(
    rows: list[dict],
    excluded_occurrences: dict[str, set[str]] | None = None,
) -> bytes:
    calendar = Calendar()
    calendar.add("prodid", "-//HausKlar//Family Calendar//EN")
    calendar.add("version", "2.0")
    calendar.add("calscale", "GREGORIAN")
    for row in rows:
        item = Event()
        item.add("uid", f"{row['id']}@hausklar")
        item.add("summary", row["title"])
        if row.get("description"):
            item.add("description", row["description"])
        if row.get("location"):
            item.add("location", row["location"])
        if row.get("all_day"):
            item.add("dtstart", date.fromisoformat(row["start_time"][:10]))
            if row.get("end_time"):
                item.add("dtend", date.fromisoformat(row["end_time"][:10]))
        else:
            item.add("dtstart", datetime.fromisoformat(row["start_time"].replace("Z", "+00:00")))
            if row.get("end_time"):
                item.add("dtend", datetime.fromisoformat(row["end_time"].replace("Z", "+00:00")))
        if row.get("recurrence_rule"):
            rule = {}
            for part in row["recurrence_rule"].split(";"):
                key, _, value = part.partition("=")
                if key and value:
                    rule[key] = value.split(",")
            item.add("rrule", rule)
            for occurrence_start in sorted(
                (excluded_occurrences or {}).get(row["id"], set())
            ):
                if row.get("all_day") or len(row["start_time"]) == 10:
                    item.add("exdate", date.fromisoformat(occurrence_start[:10]))
                else:
                    item.add(
                        "exdate",
                        datetime.fromisoformat(
                            occurrence_start.replace("Z", "+00:00")
                        ),
                    )
        item.add("last-modified", datetime.fromisoformat(row["updated_at"].replace("Z", "+00:00")))
        calendar.add_component(item)
    return calendar.to_ical()


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def new_feed_token() -> str:
    return secrets.token_urlsafe(32)
