"""Small, derived coordination surfaces for the calm Today experience."""

from __future__ import annotations

import json
import uuid
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import HTTPException

from app.services.managed_tasks import BIN_SCRAPER_CREATOR
from app.services.record_history import save_history
from app.utils.encryption import decrypt_value, encrypt_value

LOCAL = ZoneInfo("Europe/London")
EVENING_START = time(16, 0)


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


async def tomorrow_card(db, user: dict, *, now: datetime | None = None) -> dict:
    local_now = (now or _utc_now()).astimezone(LOCAL)
    target = local_now.date() + timedelta(days=1)
    target_text = target.isoformat()
    after_text = (target + timedelta(days=1)).isoformat()

    cursor = await db.execute(
        """SELECT id,title,start_time,all_day,location,assigned_to,event_type
           FROM calendar_events
           WHERE family_id=? AND deleted_at IS NULL AND start_time>=? AND start_time<?
           ORDER BY all_day DESC,start_time,id LIMIT 20""",
        (user["family_id"], target_text, after_text),
    )
    events = [
        {
            "id": row["id"],
            "title": row["title"],
            "start_time": row["start_time"],
            "all_day": bool(row["all_day"]),
            "location": row["location"],
            "assigned_to": row["assigned_to"],
            "event_type": row["event_type"],
        }
        for row in await cursor.fetchall()
    ]

    cursor = await db.execute(
        """SELECT t.id,t.title,t.due_date,t.priority,
                  COALESCE(json_group_array(CASE WHEN ta.id IS NULL THEN NULL ELSE
                    CASE ta.assignee_type WHEN 'user' THEN u.name ELSE c.name END END),'[]') AS names
           FROM tasks t
           LEFT JOIN task_assignments ta ON ta.task_id=t.id AND ta.deleted_at IS NULL
           LEFT JOIN users u ON ta.assignee_type='user' AND u.id=ta.assignee_id
           LEFT JOIN children c ON ta.assignee_type='child' AND c.id=ta.assignee_id
           WHERE t.family_id=? AND t.deleted_at IS NULL AND t.completed_at IS NULL
             AND t.due_date IS NOT NULL AND t.due_date<?
           GROUP BY t.id ORDER BY t.due_date,t.priority DESC,t.created_at LIMIT 12""",
        (user["family_id"], after_text),
    )
    tasks = []
    for row in await cursor.fetchall():
        names = [name for name in json.loads(row["names"] or "[]") if name]
        tasks.append(
            {
                "id": row["id"],
                "title": row["title"],
                "due_date": row["due_date"],
                "priority": row["priority"],
                "assignee_names": names,
            }
        )

    cursor = await db.execute(
        """SELECT 1 FROM coordination_actions
           WHERE user_id=? AND action_kind='tomorrow_ack' AND target_date=?
             AND deleted_at IS NULL LIMIT 1""",
        (user["id"], target_text),
    )
    acknowledged = await cursor.fetchone() is not None
    prompt = await next_load_prompt(db, user, local_today=local_now.date())
    return {
        "target_date": target_text,
        "visible": local_now.time() >= EVENING_START,
        "acknowledged": acknowledged,
        "events": events,
        "tasks": tasks,
        "load_prompt": prompt,
    }


async def next_load_prompt(db, user: dict, *, local_today: date | None = None) -> dict | None:
    today = local_today or _utc_now().astimezone(LOCAL).date()
    # Exclusive bound: due dates within the 14-day horizon inclusive.
    horizon = (today + timedelta(days=15)).isoformat()
    cursor = await db.execute(
        """SELECT t.id,t.title,t.due_date,t.priority
           FROM tasks t
           WHERE t.family_id=? AND t.deleted_at IS NULL AND t.completed_at IS NULL
             AND NOT EXISTS (
               SELECT 1 FROM task_assignments ta
               WHERE ta.task_id=t.id AND ta.deleted_at IS NULL
             )
             AND (t.due_date IS NULL OR t.due_date<?)
             AND NOT EXISTS (
               SELECT 1 FROM coordination_actions ca
               WHERE ca.user_id=? AND ca.entity_id=t.id AND ca.action_kind='load_later'
                 AND ca.target_date>=? AND ca.deleted_at IS NULL
             )
           ORDER BY CASE WHEN t.due_date IS NULL THEN 1 ELSE 0 END,
                    t.due_date,t.priority DESC,t.created_at
           LIMIT 1""",
        (user["family_id"], horizon, user["id"], today.isoformat()),
    )
    row = await cursor.fetchone()
    if not row:
        return None
    return {
        "task_id": row["id"],
        "title": row["title"],
        "due_date": row["due_date"],
        "priority": row["priority"],
    }


async def assign_load(
    db,
    user: dict,
    *,
    task_id: str,
    assignee_id: str,
) -> None:
    """Assign a load prompt, treating bins as one household responsibility."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            """SELECT id FROM users
               WHERE id=? AND family_id=? AND deleted_at IS NULL""",
            (assignee_id, user["family_id"]),
        )
        if not await cursor.fetchone():
            raise HTTPException(
                status_code=400,
                detail="Assignee is not an active user in this family",
            )

        cursor = await db.execute(
            """SELECT id,created_by FROM tasks
               WHERE id=? AND family_id=? AND deleted_at IS NULL
                 AND completed_at IS NULL""",
            (task_id, user["family_id"]),
        )
        task = await cursor.fetchone()
        if not task:
            raise HTTPException(status_code=404, detail="Task not found")

        if task["created_by"] == BIN_SCRAPER_CREATOR:
            cursor = await db.execute(
                """SELECT id FROM tasks
                   WHERE family_id=? AND created_by=? AND deleted_at IS NULL
                     AND completed_at IS NULL
                   ORDER BY due_date,id""",
                (user["family_id"], BIN_SCRAPER_CREATOR),
            )
            task_ids = [row["id"] for row in await cursor.fetchall()]
        else:
            task_ids = [task_id]

        now = _utc_now().isoformat()
        placeholders = ",".join("?" for _ in task_ids)
        cursor = await db.execute(
            f"""SELECT id FROM task_assignments
                WHERE family_id=? AND task_id IN ({placeholders})
                  AND deleted_at IS NULL""",
            (user["family_id"], *task_ids),
        )
        assignment_ids = [row["id"] for row in await cursor.fetchall()]

        for identifier in task_ids:
            await save_history(
                db,
                "tasks",
                identifier,
                user["id"],
                family_id=user["family_id"],
            )
        for identifier in assignment_ids:
            await save_history(
                db,
                "task_assignments",
                identifier,
                user["id"],
                family_id=user["family_id"],
            )

        await db.execute(
            f"""UPDATE task_assignments
                SET deleted_at=?,updated_at=?
                WHERE family_id=? AND task_id IN ({placeholders})
                  AND deleted_at IS NULL""",
            (now, now, user["family_id"], *task_ids),
        )
        await db.execute(
            f"""UPDATE tasks SET assigned_to=?,updated_at=?
                WHERE family_id=? AND id IN ({placeholders})
                  AND deleted_at IS NULL AND completed_at IS NULL""",
            (assignee_id, now, user["family_id"], *task_ids),
        )
        await db.executemany(
            """INSERT INTO task_assignments
               (id,task_id,assignee_id,assignee_type,family_id,
                created_at,updated_at,created_by)
               VALUES (?,?,?,'user',?,?,?,?)""",
            [
                (
                    str(uuid.uuid4()),
                    identifier,
                    assignee_id,
                    user["family_id"],
                    now,
                    now,
                    user["id"],
                )
                for identifier in task_ids
            ],
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


async def record_action(
    db, user: dict, *, action_kind: str, target_date: str, entity_id: str | None = None
) -> None:
    now = _utc_now().isoformat()
    cursor = await db.execute(
        """SELECT id FROM coordination_actions
           WHERE user_id=? AND action_kind=? AND target_date=?
             AND COALESCE(entity_id,'')=COALESCE(?,'') AND deleted_at IS NULL""",
        (user["id"], action_kind, target_date, entity_id),
    )
    existing = await cursor.fetchone()
    if existing:
        return
    else:
        await db.execute(
            """INSERT INTO coordination_actions
               (id,user_id,family_id,action_kind,entity_id,target_date,created_at,updated_at,created_by)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (
                str(uuid.uuid4()),
                user["id"],
                user["family_id"],
                action_kind,
                entity_id,
                target_date,
                now,
                now,
                user["id"],
            ),
        )
    await db.commit()


def share_text(*, text: str, title: str | None = None, url: str | None = None) -> str:
    parts = [value.strip() for value in (title, text, url) if value and value.strip()]
    combined = "\n".join(dict.fromkeys(parts))
    return combined[:10_000]


async def create_share_draft(
    db, user: dict, *, text: str, title: str | None = None, url: str | None = None
) -> str:
    combined = share_text(text=text, title=title, url=url)
    if not combined:
        raise HTTPException(status_code=400, detail="There was no text to share")
    identifier = str(uuid.uuid4())
    now = _utc_now()
    await db.execute(
        """INSERT INTO share_capture_drafts
           (id,user_id,family_id,encrypted_text,expires_at,created_at,updated_at,created_by)
           VALUES (?,?,?,?,?,?,?,?)""",
        (
            identifier,
            user["id"],
            user["family_id"],
            encrypt_value(combined),
            (now + timedelta(hours=24)).isoformat(),
            now.isoformat(),
            now.isoformat(),
            user["id"],
        ),
    )
    await db.commit()
    return identifier


async def claim_share_draft(db, user: dict, identifier: str) -> str:
    cursor = await db.execute(
        """SELECT * FROM share_capture_drafts
           WHERE id=? AND user_id=? AND family_id=? AND deleted_at IS NULL""",
        (identifier, user["id"], user["family_id"]),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="That shared item is no longer available")
    now = _utc_now()
    if datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00")) <= now:
        await save_history(
            db, "share_capture_drafts", identifier, user["id"], family_id=user["family_id"]
        )
        await db.execute(
            "UPDATE share_capture_drafts SET deleted_at=?,updated_at=? WHERE id=?",
            (now.isoformat(), now.isoformat(), identifier),
        )
        await db.commit()
        raise HTTPException(status_code=410, detail="That shared item has expired")
    value = decrypt_value(row["encrypted_text"])
    await save_history(
        db, "share_capture_drafts", identifier, user["id"], family_id=user["family_id"]
    )
    await db.execute(
        "UPDATE share_capture_drafts SET deleted_at=?,updated_at=? WHERE id=?",
        (now.isoformat(), now.isoformat(), identifier),
    )
    await db.commit()
    return value
