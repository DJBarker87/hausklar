"""Materialise the next occurrence of a repeating task after completion."""

from __future__ import annotations

import uuid
from datetime import date, datetime, time, timezone

from dateutil.rrule import rrulestr

from app.services import record_history


_GENERATED_CLIENT_PREFIX = "hausklar:task-recurrence:"


def _parse_timestamp(value: str) -> tuple[datetime, bool]:
    date_only = len(value) == 10
    if date_only:
        parsed = datetime.combine(date.fromisoformat(value), time.min, tzinfo=timezone.utc)
    else:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed, date_only


def _format_timestamp(value: datetime, *, date_only: bool, source: str) -> str:
    if date_only:
        return value.date().isoformat()
    rendered = value.isoformat()
    if source.endswith("Z") and rendered.endswith("+00:00"):
        return f"{rendered[:-6]}Z"
    return rendered


def _rule_with_remaining_count(
    rule_text: str,
    *,
    rule,
    due: datetime,
    next_due: datetime,
) -> str | None:
    segments = rule_text.split(";")
    count_index = next(
        (
            index
            for index, segment in enumerate(segments)
            if segment.upper().startswith("COUNT=")
        ),
        None,
    )
    if count_index is None:
        return rule_text

    original_count = int(segments[count_index].split("=", 1)[1])
    successors_through_next = 0
    for occurrence in rule:
        if occurrence <= due:
            continue
        successors_through_next += 1
        if occurrence >= next_due:
            break
    remaining = original_count - successors_through_next
    if remaining < 1:
        return None
    segments[count_index] = f"COUNT={remaining}"
    return ";".join(segments)


def next_task_occurrence(
    *,
    due_date: str,
    recurrence_rule: str,
    completed_at: str,
    actionable_from: str | None,
) -> tuple[str, str, str | None] | None:
    """Return the next due date, remaining rule, and shifted visibility time."""
    try:
        due, due_is_date_only = _parse_timestamp(due_date)
        completed, _ = _parse_timestamp(completed_at)
        rule = rrulestr(recurrence_rule, dtstart=due)
        next_due = rule.after(max(due, completed), inc=False)
        if next_due is None:
            return None
        next_rule = _rule_with_remaining_count(
            recurrence_rule,
            rule=rule,
            due=due,
            next_due=next_due,
        )
        if next_rule is None:
            return None
        next_actionable: str | None = None
        if actionable_from:
            actionable, actionable_is_date_only = _parse_timestamp(actionable_from)
            next_actionable = _format_timestamp(
                actionable + (next_due - due),
                date_only=actionable_is_date_only,
                source=actionable_from,
            )
        return (
            _format_timestamp(next_due, date_only=due_is_date_only, source=due_date),
            next_rule,
            next_actionable,
        )
    except (OverflowError, TypeError, ValueError):
        return None


async def create_next_task_occurrence(
    db,
    task,
    *,
    completed_at: str,
    created_by: str,
) -> str | None:
    """Create exactly one pending successor for a completed repeating task."""
    source = dict(task)
    if not source.get("due_date") or not source.get("recurrence_rule"):
        return None

    generated_client_id = f"{_GENERATED_CLIENT_PREFIX}{source['id']}"
    existing = await (
        await db.execute(
            "SELECT id FROM tasks WHERE family_id = ? AND client_id = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (source["family_id"], generated_client_id),
        )
    ).fetchone()
    if existing is not None:
        return existing["id"]

    occurrence = next_task_occurrence(
        due_date=source["due_date"],
        recurrence_rule=source["recurrence_rule"],
        completed_at=completed_at,
        actionable_from=source.get("actionable_from"),
    )
    if occurrence is None:
        return None
    next_due, next_rule, next_actionable = occurrence

    next_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        """
        INSERT INTO tasks (
            id, title, description, assigned_to, due_date, completed_at,
            category, recurrence_rule, priority, actionable_from,
            source_document_id, family_id, created_at, updated_at, created_by,
            client_id, client_timestamp, deleted_at
        ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        """,
        (
            next_id,
            source["title"],
            source.get("description"),
            source.get("assigned_to"),
            next_due,
            source.get("category") or "other",
            next_rule,
            source.get("priority") or 2,
            next_actionable,
            source.get("source_document_id"),
            source["family_id"],
            now,
            now,
            source.get("created_by") or created_by,
            generated_client_id,
            completed_at,
        ),
    )

    assignments = await (
        await db.execute(
            """
            SELECT assignee_id, assignee_type, created_by
            FROM task_assignments
            WHERE task_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY created_at
            """,
            (source["id"], source["family_id"]),
        )
    ).fetchall()
    if assignments:
        await db.executemany(
            """
            INSERT INTO task_assignments (
                id, task_id, assignee_id, assignee_type, family_id,
                created_at, updated_at, created_by
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    str(uuid.uuid4()),
                    next_id,
                    assignment["assignee_id"],
                    assignment["assignee_type"],
                    source["family_id"],
                    now,
                    now,
                    assignment["created_by"] or created_by,
                )
                for assignment in assignments
            ],
        )
    return next_id


async def discard_generated_next_occurrence(
    db,
    *,
    source_task_id: str,
    family_id: str,
    changed_by: str,
    now: str,
) -> str | None:
    """Remove an untouched pending successor when its source completion is undone."""
    generated_client_id = f"{_GENERATED_CLIENT_PREFIX}{source_task_id}"
    generated = await (
        await db.execute(
            """
            SELECT id FROM tasks
            WHERE family_id = ? AND client_id = ?
              AND completed_at IS NULL AND deleted_at IS NULL
              AND updated_at = created_at
              AND NOT EXISTS (
                  SELECT 1 FROM task_assignments assignment
                  WHERE assignment.task_id = tasks.id
                    AND assignment.family_id = tasks.family_id
                    AND assignment.deleted_at IS NULL
                    AND assignment.completed_at IS NOT NULL
              )
            LIMIT 1
            """,
            (family_id, generated_client_id),
        )
    ).fetchone()
    if generated is None:
        return None

    task_id = generated["id"]
    await record_history.save_history(
        db,
        "tasks",
        task_id,
        changed_by,
        family_id=family_id,
    )
    await db.execute(
        "UPDATE tasks SET deleted_at = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, now, task_id, family_id),
    )
    assignments = await (
        await db.execute(
            "SELECT id FROM task_assignments "
            "WHERE task_id = ? AND family_id = ? AND deleted_at IS NULL",
            (task_id, family_id),
        )
    ).fetchall()
    for assignment in assignments:
        await record_history.save_history(
            db,
            "task_assignments",
            assignment["id"],
            changed_by,
            family_id=family_id,
        )
    await db.execute(
        "UPDATE task_assignments SET deleted_at = ?, updated_at = ? "
        "WHERE task_id = ? AND family_id = ? AND deleted_at IS NULL",
        (now, now, task_id, family_id),
    )
    return task_id
