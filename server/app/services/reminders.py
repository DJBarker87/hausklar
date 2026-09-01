"""Personalised reminder candidates and encrypted web/APNs delivery."""

from __future__ import annotations

import asyncio
import hashlib
import json
import uuid
from datetime import date, datetime, timedelta, timezone
from urllib.parse import quote
from zoneinfo import ZoneInfo

import httpx
from pywebpush import WebPushException, webpush

from app.config import settings
from app.database import database_lease
from app.services.apns import APNSDeliveryError, apns_configured, send_apns
from app.services.calendar_recurrence import expand_calendar_rows
from app.utils.encryption import decrypt_value
from app.services.calendar_sync import CalendarSyncError, validate_public_https_url
from app.services.finance.projections import calendar_projections, task_projections
from app.services.health_record import due_vaccination_reminders

LOCAL = ZoneInfo("Europe/London")


def in_quiet_hours(now: datetime, start: str, end: str) -> bool:
    value = now.strftime("%H:%M")
    if start == end:
        return False
    return value >= start or value < end if start > end else start <= value < end


def due_in_window(now: datetime, value: str, *, minutes: int = 15) -> bool:
    """Allow the one-minute scheduler a bounded recovery window after downtime."""
    hour, minute = (int(part) for part in value.split(":"))
    scheduled = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    return scheduled <= now < scheduled + timedelta(minutes=minutes)


def _event_start(value: str) -> datetime:
    if len(value) == 10:
        return datetime.fromisoformat(value).replace(tzinfo=LOCAL)
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.replace(tzinfo=LOCAL) if parsed.tzinfo is None else parsed


def _calendar_ids(value: str | None) -> set[str]:
    if not value:
        return set()
    try:
        decoded = json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return set()
    return {item for item in decoded if isinstance(item, str)} if isinstance(decoded, list) else set()


def _event_is_relevant_to_user(row, user_id: str) -> bool:
    participants = _calendar_ids(row["family_member_ids"])
    if row["assigned_to"]:
        participants.add(row["assigned_to"])
    if not participants:
        return True
    return user_id in participants or user_id in _calendar_ids(row["affected_member_ids"])


async def _stored_calendar_occurrences(
    db,
    *,
    family_id: str,
    range_start: datetime,
    range_end: datetime,
) -> list:
    coarse_start = (range_start - timedelta(days=1)).date().isoformat()
    coarse_end = (range_end + timedelta(days=1)).date().isoformat()
    rows = await (
        await db.execute(
            """
            SELECT ce.id, ce.title, ce.start_time, ce.end_time, ce.all_day,
                   ce.recurrence_rule, ce.assigned_to, ce.family_member_ids,
                   ce.affected_member_ids
            FROM calendar_events ce
            WHERE ce.family_id = ? AND ce.deleted_at IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM calendar_events replacement
                  WHERE replacement.overridden_event_id = ce.id
                    AND replacement.family_id = ce.family_id
                    AND replacement.deleted_at IS NULL
              )
              AND (
                  ce.recurrence_rule IS NOT NULL
                  OR (
                      substr(ce.start_time, 1, 10) < ?
                      AND substr(COALESCE(ce.end_time, ce.start_time), 1, 10) >= ?
                  )
              )
            ORDER BY ce.start_time
            LIMIT 500
            """,
            (family_id, coarse_end, coarse_start),
        )
    ).fetchall()
    return await expand_calendar_rows(
        db,
        family_id=family_id,
        rows=rows,
        range_start=range_start,
        range_end=range_end,
        max_occurrences_per_series=200,
    )


async def _renewal_reminders(
    db,
    *,
    user: dict,
    local_now: datetime,
    include_future: bool = False,
) -> list[dict]:
    """Return renewals owned by this adult whose chosen lead date has arrived."""
    cursor = await db.execute(
        """
        SELECT renewal.id, renewal.title, renewal.due_date,
               renewal.reminder_days_before, renewal.escalate_after_days,
               COALESCE(
                   renewal.responsible_user_id,
                   commitment.responsible_user_id,
                   renewal.created_by
               ) AS owner_user_id
        FROM renewals renewal
        LEFT JOIN finance_commitments commitment
          ON commitment.id = renewal.finance_commitment_id
         AND commitment.family_id = renewal.family_id
         AND commitment.deleted_at IS NULL
        WHERE renewal.family_id = ? AND renewal.deleted_at IS NULL
          AND renewal.reminders_enabled = 1
        ORDER BY renewal.due_date
        LIMIT 50
        """,
        (user["family_id"],),
    )
    reminders: list[dict] = []
    today = local_now.date()
    for row in await cursor.fetchall():
        try:
            due = datetime.fromisoformat(row["due_date"][:10]).date()
        except (TypeError, ValueError):
            continue
        owner_user_id = row["owner_user_id"]
        days_overdue = (today - due).days
        escalated = (
            row["escalate_after_days"] is not None
            and days_overdue >= int(row["escalate_after_days"])
        )
        if owner_user_id is not None and owner_user_id != user["id"] and not escalated:
            continue
        show_from = due - timedelta(days=max(0, int(row["reminder_days_before"] or 0)))
        if show_from > today and not include_future:
            continue
        reminders.append(
            {
                "id": row["id"],
                "title": row["title"],
                "due": due,
                "show_from": show_from,
            }
        )
    return reminders


async def _renewal_preview_items(db, *, user: dict, now: datetime) -> list[dict]:
    items: list[dict] = []
    for renewal in await _renewal_reminders(
        db,
        user=user,
        local_now=now.astimezone(LOCAL),
        include_future=True,
    ):
        scheduled = datetime.combine(
            renewal["show_from"],
            datetime.min.time(),
            tzinfo=LOCAL,
        ).replace(hour=9)
        if scheduled <= now:
            scheduled = now + timedelta(minutes=1)
        days_until = (renewal["due"] - now.astimezone(LOCAL).date()).days
        if days_until < 0:
            detail = f"Overdue by {abs(days_until)} day{'s' if abs(days_until) != 1 else ''}"
        elif days_until == 0:
            detail = "Due today"
        else:
            detail = f"Due in {days_until} day{'s' if days_until != 1 else ''}"
        items.append(
            {
                "id": f"renewal:{renewal['id']}:{renewal['due'].isoformat()}",
                "kind": "renewal",
                "title": renewal["title"],
                "detail": detail,
                "scheduled_for": scheduled.astimezone(timezone.utc).isoformat(),
                "url": (
                    "/?view=lists&section=renewals&renewal="
                    f"{quote(renewal['id'], safe='')}"
                ),
            }
        )
    return items


async def _renewal_push_candidates(
    db,
    *,
    subscription: dict,
    local_now: datetime,
) -> list[tuple[str, dict]]:
    user = {
        "id": subscription["user_id"],
        "family_id": subscription["family_id"],
    }
    result: list[tuple[str, dict]] = []
    for renewal in await _renewal_reminders(db, user=user, local_now=local_now):
        days_until = (renewal["due"] - local_now.date()).days
        if days_until < 0:
            body = f"Overdue by {abs(days_until)} day{'s' if abs(days_until) != 1 else ''}"
        elif days_until == 0:
            body = "Due today"
        else:
            body = f"Due in {days_until} day{'s' if days_until != 1 else ''}"
        result.append(
            (
                f"renewal:{renewal['id']}:{renewal['due'].isoformat()}",
                _payload(
                    "renewal",
                    renewal["title"],
                    body,
                    "/?view=lists&section=renewals&renewal="
                    f"{quote(renewal['id'], safe='')}",
                    bool(subscription["privacy_mode"]),
                ),
            )
        )
    return result


async def _library_reminders(
    db,
    *,
    family_id: str,
    local_now: datetime,
    include_future: bool = False,
) -> list[dict]:
    """Return current library loans whose per-card reminder date has arrived."""
    rows = await (
        await db.execute(
            """SELECT loan.id,loan.title,loan.due_date,account.label AS account_label,
                      account.reminder_days_before
               FROM library_loans loan
               JOIN library_accounts account
                 ON account.id=loan.account_id AND account.deleted_at IS NULL
               WHERE loan.family_id=? AND loan.deleted_at IS NULL
                 AND account.sync_enabled=1
               ORDER BY loan.due_date,loan.title LIMIT 100""",
            (family_id,),
        )
    ).fetchall()
    today = local_now.date()
    reminders: list[dict] = []
    for row in rows:
        try:
            due = datetime.fromisoformat(row["due_date"][:10]).date()
        except (TypeError, ValueError):
            continue
        show_from = due - timedelta(days=max(0, int(row["reminder_days_before"] or 0)))
        if show_from > today and not include_future:
            continue
        reminders.append(
            {
                "id": row["id"],
                "title": row["title"],
                "account_label": row["account_label"],
                "due": due,
                "show_from": show_from,
            }
        )
    return reminders


def _library_due_detail(*, due: date, today: date) -> str:
    days_until = (due - today).days
    if days_until < 0:
        return f"Overdue by {abs(days_until)} day{'s' if abs(days_until) != 1 else ''}"
    if days_until == 0:
        return "Due back today"
    return f"Due back in {days_until} day{'s' if days_until != 1 else ''}"


async def _library_preview_items(db, *, user: dict, now: datetime) -> list[dict]:
    items: list[dict] = []
    local_now = now.astimezone(LOCAL)
    for loan in await _library_reminders(
        db,
        family_id=user["family_id"],
        local_now=local_now,
        include_future=True,
    ):
        scheduled = datetime.combine(
            loan["show_from"], datetime.min.time(), tzinfo=LOCAL
        ).replace(hour=9)
        if scheduled <= now:
            scheduled = now + timedelta(minutes=1)
        items.append(
            {
                "id": f"library:{loan['id']}:{loan['due'].isoformat()}",
                "kind": "library",
                "title": loan["title"],
                "detail": _library_due_detail(due=loan["due"], today=local_now.date()),
                "scheduled_for": scheduled.astimezone(timezone.utc).isoformat(),
                "url": (
                    "/?view=lists&section=renewals&library="
                    f"{quote(loan['id'], safe='')}"
                ),
            }
        )
    return items


async def _library_push_candidates(
    db,
    *,
    subscription: dict,
    local_now: datetime,
) -> list[tuple[str, dict]]:
    candidates: list[tuple[str, dict]] = []
    for loan in await _library_reminders(
        db,
        family_id=subscription["family_id"],
        local_now=local_now,
    ):
        candidates.append(
            (
                f"library:{loan['id']}:{loan['due'].isoformat()}",
                _payload(
                    "library",
                    loan["title"],
                    _library_due_detail(due=loan["due"], today=local_now.date()),
                    "/?view=lists&section=renewals&library="
                    f"{quote(loan['id'], safe='')}",
                    bool(subscription["privacy_mode"]),
                ),
            )
        )
    return candidates


async def _summary_counts(
    db,
    *,
    user: dict,
    day_start: datetime,
    day_end: datetime,
    task_due_before: str,
) -> tuple[int, int]:
    """Count the same authorised stored and Finance plan shown to this adult."""
    event_count = len(
        await _stored_calendar_occurrences(
            db,
            family_id=user["family_id"],
            range_start=day_start,
            range_end=day_end,
        )
    )
    cursor = await db.execute(
        "SELECT COUNT(*) FROM tasks "
        "WHERE family_id = ? AND deleted_at IS NULL AND completed_at IS NULL "
        "AND due_date IS NOT NULL AND due_date < ?",
        (user["family_id"], task_due_before),
    )
    task_count = (await cursor.fetchone())[0]
    event_count += len(
        await calendar_projections(
            db,
            user=user,
            range_start=day_start,
            range_end=day_end,
        )
    )
    task_count += sum(
        1
        for task in await task_projections(db, user=user)
        if task.completed_at is None
        and task.due_date is not None
        and task.due_date < task_due_before
    )
    return event_count, task_count


async def reminder_preview(db, user: dict, preferences: dict) -> list[dict]:
    now = datetime.now(timezone.utc)
    horizon = now + timedelta(hours=48)
    stored_occurrences = await _stored_calendar_occurrences(
        db,
        family_id=user["family_id"],
        range_start=now,
        range_end=horizon,
    )
    items = []
    if preferences["event_reminders_enabled"]:
        for occurrence in stored_occurrences:
            row = occurrence.row
            if not _event_is_relevant_to_user(row, user["id"]):
                continue
            event_date = occurrence.start
            if not occurrence.all_day and event_date < now:
                continue
            event_id = (
                f"{row['id']}::{occurrence.key}" if occurrence.generated else row["id"]
            )
            scheduled = (
                event_date.astimezone(LOCAL).replace(hour=8, minute=0, second=0, microsecond=0)
                if occurrence.all_day
                else event_date - timedelta(minutes=preferences["event_minutes_before"])
            )
            items.append({
                "id": f"event:{event_id}",
                "kind": "event", "title": row["title"],
                "detail": "All day" if occurrence.all_day else event_date.astimezone(LOCAL).strftime("%a %-d %b at %-I:%M %p"),
                "scheduled_for": scheduled.astimezone(timezone.utc).isoformat(),
                "url": f"/?view=calendar&event={quote(event_id, safe='')}",
            })
        for event in await calendar_projections(
            db,
            user=user,
            range_start=now,
            range_end=horizon,
        ):
            event_date = _event_start(event.start_time)
            scheduled = (
                event_date.astimezone(LOCAL).replace(
                    hour=8, minute=0, second=0, microsecond=0
                )
                if event.all_day
                else event_date - timedelta(minutes=preferences["event_minutes_before"])
            )
            items.append(
                {
                    "id": f"event:{event.id}",
                    "kind": "event",
                    "title": event.title,
                    "detail": (
                        "All day"
                        if event.all_day
                        else event_date.astimezone(LOCAL).strftime(
                            "%a %-d %b at %-I:%M %p"
                        )
                    ),
                    "scheduled_for": scheduled.astimezone(timezone.utc).isoformat(),
                    "url": event.managed_source.deep_link,
                }
            )
    if preferences["task_reminders_enabled"]:
        cursor = await db.execute(
            """SELECT id,title,due_date,assigned_to FROM tasks WHERE family_id=? AND deleted_at IS NULL
               AND completed_at IS NULL AND due_date IS NOT NULL ORDER BY due_date LIMIT 8""",
            (user["family_id"],),
        )
        for row in await cursor.fetchall():
            if row["assigned_to"] not in (None, user["id"]):
                continue
            due = _event_start(row["due_date"]).astimezone(LOCAL).replace(hour=9, minute=0, second=0, microsecond=0)
            items.append({"id": f"task:{row['id']}", "kind": "task", "title": row["title"], "detail": f"Due {due.astimezone(LOCAL).strftime('%a %-d %b')}", "scheduled_for": due.astimezone(timezone.utc).isoformat(), "url": f"/?view=lists&section=tasks&task={quote(row['id'], safe='')}"})
        for task in await task_projections(db, user=user):
            if task.completed_at or task.assigned_to != user["id"] or not task.due_date:
                continue
            due = _event_start(task.due_date).astimezone(LOCAL).replace(
                hour=9, minute=0, second=0, microsecond=0
            )
            items.append(
                {
                    "id": f"task:{task.id}",
                    "kind": "task",
                    "title": task.title,
                    "detail": f"Due {due.astimezone(LOCAL).strftime('%a %-d %b')}",
                    "scheduled_for": due.astimezone(timezone.utc).isoformat(),
                    "url": task.managed_source.deep_link,
                }
            )
    items.extend(await _renewal_preview_items(db, user=user, now=now))
    items.extend(await _library_preview_items(db, user=user, now=now))
    return sorted(items, key=lambda item: item["scheduled_for"])[:12]


def _private_notification_content(kind: str, title: str, body: str) -> tuple[str, str]:
    """Describe the reminder without exposing names or sensitive record details."""
    if kind == "event":
        return "Upcoming event", body
    if kind == "task":
        return "Task due", body
    if kind == "renewal":
        return "Renewal due", body
    if kind == "library":
        return "Library book due", body
    if kind == "document":
        return "Document ready to review", "A document has suggestions ready to check."
    if kind == "insight":
        return "Family update", "HausKlar noticed something worth checking."
    if kind == "vaccination":
        return "Vaccination reminder", "A vaccination is due soon."
    if kind in {"morning", "evening"}:
        return title, body
    return "HausKlar reminder", "Something needs checking in HausKlar."


def _payload(kind: str, title: str, body: str, url: str, privacy: bool) -> dict:
    if privacy:
        title, body = _private_notification_content(kind, title, body)
    return {"title": title, "body": body, "url": url, "tag": f"hausklar-{kind}"}


async def _send(subscription: dict, payload: dict) -> None:
    await asyncio.to_thread(
        webpush,
        subscription_info=subscription,
        data=json.dumps(payload),
        vapid_private_key=settings.web_push_vapid_private_key,
        vapid_claims={"sub": settings.web_push_vapid_subject},
        ttl=3600,
    )


async def deliver_finance_report_notification(
    *,
    user_id: str,
    family_id: str,
    reminder_key: str,
    locale: str = "en",
    notification_mode: str = "ACTION_ONLY",
    action_id: str | None = None,
    action_scope: str = "mine",
) -> int:
    """Deliver one deliberately detail-free Finance notification per subscription.

    This is the existing encrypted browser-push path, with the existing durable
    ``reminder_deliveries`` table used as an at-most-once claim.  A missing or
    broken subscription never prevents the in-app report from being retained.
    """
    if notification_mode == "NEVER" or (
        notification_mode == "ACTION_ONLY" and action_id is None
    ):
        return 0
    if not settings.web_push_vapid_private_key or not settings.web_push_vapid_public_key:
        return 0
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT * FROM web_push_subscriptions WHERE user_id = ? "
            "AND family_id = ? AND deleted_at IS NULL ORDER BY created_at, id",
            (user_id, family_id),
        )
        subscriptions = [dict(row) for row in await cursor.fetchall()]
    if not subscriptions:
        return 0

    needs_action = notification_mode == "ACTION_ONLY" and action_id is not None
    if locale == "de":
        title = "Geld braucht deine Aufmerksamkeit" if needs_action else "HausKlar Finanzen"
        body = (
            "Öffne HausKlar und erledige eine private Geldsache."
            if needs_action
            else "Dein privater Geld-Check ist bereit."
        )
    else:
        title = "Money needs your attention" if needs_action else "HausKlar Finance"
        body = (
            "Open HausKlar to finish one private money action."
            if needs_action
            else "Your private money check is ready."
        )
    url = "/?view=finance&section=coach"
    if action_id:
        url += f"&action={quote(action_id, safe='')}"
        if action_scope == "household":
            url += "&scope=household"
    payload = {
        "title": title,
        "body": body,
        "url": url,
        "tag": "hausklar-finance",
    }
    sent = 0
    for subscription_row in subscriptions:
        try:
            decoded = json.loads(decrypt_value(subscription_row["encrypted_subscription"]))
            await validate_public_https_url(decoded["endpoint"])
        except (ValueError, KeyError, json.JSONDecodeError, CalendarSyncError, OSError):
            continue

        # Claim before network I/O.  Two scheduler instances therefore cannot
        # both send the same report.  A failed send releases the claim for a
        # later scheduler pass; a process crash favours no duplicate over a
        # second push because the report remains available in-app.
        delivery_id = str(uuid.uuid4())
        claimed_at = datetime.now(timezone.utc).isoformat()
        async with database_lease() as db:
            cursor = await db.execute(
                """INSERT OR IGNORE INTO reminder_deliveries
                   (id,user_id,family_id,subscription_id,reminder_key,delivered_at,
                    created_at,updated_at,created_by)
                   VALUES (?,?,?,?,?,?,?,?,?)""",
                (
                    delivery_id,
                    user_id,
                    family_id,
                    subscription_row["id"],
                    reminder_key,
                    claimed_at,
                    claimed_at,
                    claimed_at,
                    user_id,
                ),
            )
            await db.commit()
            claimed = cursor.rowcount == 1
        if not claimed:
            continue

        try:
            await _send(decoded, payload)
        except WebPushException as exc:
            failed_at = datetime.now(timezone.utc).isoformat()
            status = getattr(getattr(exc, "response", None), "status_code", None)
            async with database_lease() as db:
                await db.execute(
                    "UPDATE reminder_deliveries SET deleted_at = ?, updated_at = ? "
                    "WHERE id = ?",
                    (failed_at, failed_at, delivery_id),
                )
                if status in (404, 410):
                    await db.execute(
                        "UPDATE web_push_subscriptions SET deleted_at = ?, updated_at = ? "
                        "WHERE id = ?",
                        (failed_at, failed_at, subscription_row["id"]),
                    )
                await db.commit()
            continue
        except Exception:
            failed_at = datetime.now(timezone.utc).isoformat()
            async with database_lease() as db:
                await db.execute(
                    "UPDATE reminder_deliveries SET deleted_at = ?, updated_at = ? "
                    "WHERE id = ?",
                    (failed_at, failed_at, delivery_id),
                )
                await db.commit()
            continue
        sent += 1
    return sent


async def dispatch_due_reminders() -> None:
    """Send due web and iPhone reminders with durable per-device deduplication."""
    web_configured = bool(
        settings.web_push_vapid_private_key and settings.web_push_vapid_public_key
    )
    iphone_configured = apns_configured()
    if not web_configured and not iphone_configured:
        return
    now = datetime.now(timezone.utc)
    local_now = now.astimezone(LOCAL)
    subscriptions: list[dict] = []
    async with database_lease() as db:
        preference_columns = """p.event_reminders_enabled,p.event_minutes_before,
            p.task_reminders_enabled,p.morning_summary_enabled,p.morning_summary_time,
            p.evening_summary_enabled,p.evening_summary_time,
            p.quiet_start,p.quiet_end,p.privacy_mode"""
        if web_configured:
            cursor = await db.execute(
                f"""SELECT s.*,{preference_columns},'web' AS delivery_channel
                    FROM web_push_subscriptions s
                    JOIN reminder_preferences p
                      ON p.user_id=s.user_id AND p.deleted_at IS NULL
                    WHERE s.deleted_at IS NULL"""
            )
            subscriptions.extend(dict(row) for row in await cursor.fetchall())
        if iphone_configured:
            cursor = await db.execute(
                f"""SELECT s.*,{preference_columns},'apns' AS delivery_channel
                    FROM apns_device_registrations s
                    JOIN reminder_preferences p
                      ON p.user_id=s.user_id AND p.deleted_at IS NULL
                    WHERE s.deleted_at IS NULL AND s.bundle_id=?""",
                (settings.apns_bundle_id.strip(),),
            )
            subscriptions.extend(dict(row) for row in await cursor.fetchall())
    if not subscriptions:
        return
    for subscription_row in subscriptions:
        if in_quiet_hours(local_now, subscription_row["quiet_start"], subscription_row["quiet_end"]):
            continue
        candidates: list[tuple[str, dict]] = []
        async with database_lease() as db:
            lead = timedelta(minutes=subscription_row["event_minutes_before"])
            start, end = now + lead - timedelta(seconds=45), now + lead + timedelta(seconds=75)
            if subscription_row["event_reminders_enabled"]:
                all_day_window = due_in_window(local_now, "08:00")
                local_day_start = local_now.replace(
                    hour=0, minute=0, second=0, microsecond=0
                ).astimezone(timezone.utc)
                stored_occurrences = await _stored_calendar_occurrences(
                    db,
                    family_id=subscription_row["family_id"],
                    range_start=min(start, local_day_start) if all_day_window else start,
                    range_end=(
                        max(end, local_day_start + timedelta(days=1))
                        if all_day_window
                        else end
                    ),
                )
                for occurrence in stored_occurrences:
                    if occurrence.all_day:
                        due = (
                            all_day_window
                            and occurrence.start.astimezone(LOCAL).date()
                            == local_now.date()
                        )
                        body = "Today"
                    else:
                        due = start <= occurrence.start <= end
                        body = (
                            f"Starts in {subscription_row['event_minutes_before']} minutes"
                        )
                    if not due:
                        continue
                    event = occurrence.row
                    if not _event_is_relevant_to_user(event, subscription_row["user_id"]):
                        continue
                    event_id = (
                        f"{event['id']}::{occurrence.key}"
                        if occurrence.generated
                        else event["id"]
                    )
                    candidates.append(
                        (
                            f"event:{event_id}:{occurrence.start_value}",
                            _payload(
                                "event",
                                event["title"],
                                body,
                                f"/?view=calendar&event={quote(event_id, safe='')}",
                                bool(subscription_row["privacy_mode"]),
                            ),
                        )
                    )
                finance_user = await (
                    await db.execute(
                        "SELECT id, family_id FROM users "
                        "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                        (
                            subscription_row["user_id"],
                            subscription_row["family_id"],
                        ),
                    )
                ).fetchone()
                if finance_user is not None:
                    finance_events = await calendar_projections(
                        db,
                        user=dict(finance_user),
                        range_start=min(start, local_day_start),
                        range_end=max(
                            end,
                            local_day_start + timedelta(days=1),
                        ),
                    )
                    for event in finance_events:
                        event_date = _event_start(event.start_time)
                        if event.all_day:
                            due = (
                                all_day_window
                                and event_date.astimezone(LOCAL).date() == local_now.date()
                            )
                            body = "Today"
                        else:
                            due = start <= event_date <= end
                            body = (
                                f"Starts in {subscription_row['event_minutes_before']} minutes"
                            )
                        if not due:
                            continue
                        candidates.append(
                            (
                                f"event:{event.id}:{event.start_time}",
                                _payload(
                                    "event",
                                    event.title,
                                    body,
                                    event.managed_source.deep_link,
                                    bool(subscription_row["privacy_mode"]),
                                ),
                            )
                        )
            # New documents with pending suggestions (e.g. a forwarded school
            # letter) notify once per document, soon after processing.
            cursor = await db.execute(
                """SELECT d.id, d.title,
                          (SELECT COUNT(*) FROM capture_suggestions s
                           WHERE s.document_id = d.id AND s.status = 'pending'
                             AND s.deleted_at IS NULL) AS pending
                   FROM documents d
                   WHERE d.family_id = ? AND d.deleted_at IS NULL AND d.created_at >= ?
                   ORDER BY d.created_at DESC LIMIT 10""",
                (subscription_row["family_id"], (now - timedelta(hours=24)).isoformat()),
            )
            for document in await cursor.fetchall():
                if not document["pending"]:
                    continue
                plural = "suggestion" if document["pending"] == 1 else "suggestions"
                candidates.append((
                    f"document:{document['id']}",
                    _payload(
                        "document",
                        "New in the document inbox",
                        f"{document['pending']} {plural} from “{document['title'][:80]}” — review and add",
                        f"/?view=documents&document={document['id']}",
                        bool(subscription_row["privacy_mode"]),
                    ),
                ))
            # Fresh School Brain findings (e.g. a letter date with no calendar
            # event) notify once per insight, the evening they are created.
            cursor = await db.execute(
                """SELECT id, message FROM family_insights
                   WHERE family_id = ? AND status = 'active' AND deleted_at IS NULL
                     AND created_at >= ?
                   ORDER BY created_at DESC LIMIT 3""",
                (subscription_row["family_id"], (now - timedelta(hours=24)).isoformat()),
            )
            for insight in await cursor.fetchall():
                candidates.append((
                    f"insight:{insight['id']}",
                    _payload(
                        "insight",
                        "HausKlar noticed something",
                        insight["message"],
                        "/?view=today",
                        bool(subscription_row["privacy_mode"]),
                    ),
                ))
            # A child with a routine vaccination due within the next fortnight
            # and not yet recorded — a once-only nudge to book it.
            for due in await due_vaccination_reminders(
                db, subscription_row["family_id"], local_now.date()
            ):
                candidates.append((
                    f"vaccination:{due['child_id']}:{due['vaccine_key']}",
                    _payload(
                        "vaccination",
                        "Vaccination due soon",
                        f"{due['child_name']} is due {due['vaccine_name']} "
                        f"on {due['due_date'].strftime('%-d %b')}",
                        "/?view=family&section=medicine",
                        bool(subscription_row["privacy_mode"]),
                    ),
                ))
            if subscription_row["task_reminders_enabled"] and due_in_window(local_now, "09:00"):
                cursor = await db.execute(
                    """SELECT id,title,due_date,assigned_to FROM tasks WHERE family_id=? AND deleted_at IS NULL
                       AND completed_at IS NULL AND due_date IS NOT NULL AND due_date<=?""",
                    (subscription_row["family_id"], local_now.date().isoformat()),
                )
                for task in await cursor.fetchall():
                    if task["assigned_to"] not in (None, subscription_row["user_id"]):
                        continue
                    candidates.append((f"task:{task['id']}:{local_now.date().isoformat()}", _payload("task", task["title"], "This task is due", f"/?view=lists&section=tasks&task={quote(task['id'], safe='')}", bool(subscription_row["privacy_mode"]))))
                finance_user = await (
                    await db.execute(
                        "SELECT id, family_id FROM users "
                        "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                        (subscription_row["user_id"], subscription_row["family_id"]),
                    )
                ).fetchone()
                if finance_user is not None:
                    for task in await task_projections(db, user=dict(finance_user)):
                        if (
                            task.completed_at
                            or task.assigned_to != subscription_row["user_id"]
                            or not task.due_date
                            or task.due_date > local_now.date().isoformat()
                        ):
                            continue
                        candidates.append(
                            (
                                f"task:{task.id}:{local_now.date().isoformat()}",
                                _payload(
                                    "task",
                                    task.title,
                                    "This task is due",
                                    task.managed_source.deep_link,
                                    bool(subscription_row["privacy_mode"]),
                                ),
                            )
                        )
            if due_in_window(local_now, "09:00"):
                candidates.extend(
                    await _renewal_push_candidates(
                        db,
                        subscription=dict(subscription_row),
                        local_now=local_now,
                    )
                )
                candidates.extend(
                    await _library_push_candidates(
                        db,
                        subscription=dict(subscription_row),
                        local_now=local_now,
                    )
                )
            if subscription_row["morning_summary_enabled"] and due_in_window(
                local_now, subscription_row["morning_summary_time"]
            ):
                summary_user = await (
                    await db.execute(
                        "SELECT id, family_id FROM users "
                        "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                        (subscription_row["user_id"], subscription_row["family_id"]),
                    )
                ).fetchone()
                summary_user = (
                    dict(summary_user)
                    if summary_user is not None
                    else {
                        "id": subscription_row["user_id"],
                        "family_id": subscription_row["family_id"],
                    }
                )
                today_start = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
                tomorrow_start = today_start + timedelta(days=1)
                event_count, task_count = await _summary_counts(
                    db,
                    user=summary_user,
                    day_start=today_start,
                    day_end=tomorrow_start,
                    task_due_before=tomorrow_start.date().isoformat(),
                )
                candidates.append((f"morning:{local_now.date().isoformat()}", _payload("morning", "Today in HausKlar", f"{event_count} events and {task_count} tasks need attention", "/?view=today", bool(subscription_row["privacy_mode"]))))
            if subscription_row["evening_summary_enabled"] and due_in_window(
                local_now, subscription_row["evening_summary_time"]
            ):
                summary_user = await (
                    await db.execute(
                        "SELECT id, family_id FROM users "
                        "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                        (subscription_row["user_id"], subscription_row["family_id"]),
                    )
                ).fetchone()
                summary_user = (
                    dict(summary_user)
                    if summary_user is not None
                    else {
                        "id": subscription_row["user_id"],
                        "family_id": subscription_row["family_id"],
                    }
                )
                tomorrow_start = local_now.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
                day_after_start = tomorrow_start + timedelta(days=1)
                tomorrow = tomorrow_start.date().isoformat()
                event_count, task_count = await _summary_counts(
                    db,
                    user=summary_user,
                    day_start=tomorrow_start,
                    day_end=day_after_start,
                    task_due_before=day_after_start.date().isoformat(),
                )
                candidates.append((f"evening:{tomorrow}", _payload("evening", "Tomorrow, sorted", f"{event_count} events and {task_count} tasks to check", "/?view=today&tomorrow=1", bool(subscription_row["privacy_mode"]))))
            pending = []
            for key, payload in candidates:
                cursor = await db.execute("SELECT 1 FROM reminder_deliveries WHERE subscription_id=? AND reminder_key=? AND deleted_at IS NULL", (subscription_row["id"], key))
                if not await cursor.fetchone():
                    pending.append((key, payload))
        decoded = None
        device_token = None
        if subscription_row["delivery_channel"] == "web":
            try:
                decoded = json.loads(
                    decrypt_value(subscription_row["encrypted_subscription"])
                )
                await validate_public_https_url(decoded["endpoint"])
            except (ValueError, KeyError, json.JSONDecodeError, CalendarSyncError):
                continue
        else:
            try:
                device_token = decrypt_value(subscription_row["encrypted_device_token"])
            except (TypeError, ValueError):
                continue
        for key, payload in pending:
            delivery_id = str(uuid.uuid4())
            async with database_lease() as db:
                cursor = await db.execute(
                    """INSERT OR IGNORE INTO reminder_deliveries
                       (id,user_id,family_id,subscription_id,reminder_key,delivered_at,
                        created_at,updated_at,created_by)
                       VALUES (?,?,?,?,?,?,?,?,?)""",
                    (
                        delivery_id,
                        subscription_row["user_id"],
                        subscription_row["family_id"],
                        subscription_row["id"],
                        key,
                        now.isoformat(),
                        now.isoformat(),
                        now.isoformat(),
                        subscription_row["user_id"],
                    ),
                )
                await db.commit()
                claimed = cursor.rowcount == 1
            if not claimed:
                continue
            try:
                if subscription_row["delivery_channel"] == "web":
                    await _send(decoded, payload)
                else:
                    await send_apns(
                        device_token=device_token,
                        environment=subscription_row["environment"],
                        payload=payload,
                        collapse_key=key,
                    )
            except WebPushException as exc:
                status = getattr(getattr(exc, "response", None), "status_code", None)
                async with database_lease() as db:
                    await db.execute(
                        "UPDATE reminder_deliveries SET deleted_at=?,updated_at=? WHERE id=?",
                        (now.isoformat(), now.isoformat(), delivery_id),
                    )
                    if status in (404, 410):
                        await db.execute("UPDATE web_push_subscriptions SET deleted_at=?,updated_at=? WHERE id=?", (now.isoformat(), now.isoformat(), subscription_row["id"]))
                    await db.commit()
                break
            except APNSDeliveryError as exc:
                failed_at = datetime.now(timezone.utc).isoformat()
                async with database_lease() as db:
                    await db.execute(
                        "UPDATE reminder_deliveries SET deleted_at=?,updated_at=? WHERE id=?",
                        (failed_at, failed_at, delivery_id),
                    )
                    await db.execute(
                        "UPDATE apns_device_registrations "
                        "SET last_error_code=?,last_error_at=?,updated_at=?,"
                        "deleted_at=CASE WHEN ? THEN ? ELSE deleted_at END WHERE id=?",
                        (
                            exc.reason,
                            failed_at,
                            failed_at,
                            int(exc.invalidates_device),
                            failed_at,
                            subscription_row["id"],
                        ),
                    )
                    await db.commit()
                break
            except (httpx.HTTPError, OSError, RuntimeError):
                failed_at = datetime.now(timezone.utc).isoformat()
                async with database_lease() as db:
                    await db.execute(
                        "UPDATE reminder_deliveries SET deleted_at=?,updated_at=? WHERE id=?",
                        (failed_at, failed_at, delivery_id),
                    )
                    await db.commit()
                break


def endpoint_hash(endpoint: str) -> str:
    return hashlib.sha256(endpoint.encode()).hexdigest()
