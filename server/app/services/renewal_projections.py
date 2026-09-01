"""Optional, amount-free Renewal dates in Calendar and Tasks."""

from datetime import date, datetime, timedelta, timezone

from app.models.calendar import CalendarEventResponse
from app.models.managed_projection import ManagedSource
from app.models.task import TaskAssignee, TaskResponse
from app.services.record_history import save_history


class RenewalProjectionNotFoundError(ValueError):
    pass


def _deep_link(renewal_id: str) -> str:
    return f"/?view=lists&section=renewals&renewal={renewal_id}"


def _source(renewal_id: str) -> ManagedSource:
    return ManagedSource(
        kind="finance_renewal",
        source_id=renewal_id,
        deep_link=_deep_link(renewal_id),
        label="Renewal",
    )


async def _rows(db, *, family_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            """
            SELECT renewal.*, responsible.name AS responsible_name
            FROM renewals renewal
            LEFT JOIN users responsible
              ON responsible.id = renewal.responsible_user_id
             AND responsible.family_id = renewal.family_id
             AND responsible.deleted_at IS NULL
            WHERE renewal.family_id = ? AND renewal.deleted_at IS NULL
              AND renewal.finance_commitment_id IS NULL
            ORDER BY renewal.due_date, renewal.id
            """,
            (family_id,),
        )
    ).fetchall()
    return [dict(row) for row in rows]


async def renewal_calendar_projections(
    db,
    *,
    user: dict,
    range_start: datetime,
    range_end: datetime,
) -> list[CalendarEventResponse]:
    result: list[CalendarEventResponse] = []
    for row in await _rows(db, family_id=user["family_id"]):
        if not bool(row["show_in_calendar"]):
            continue
        due = date.fromisoformat(row["due_date"][:10])
        point = datetime.combine(due, datetime.min.time(), range_start.tzinfo)
        if not range_start <= point < range_end:
            continue
        result.append(
            CalendarEventResponse(
                id=f"renewal-calendar-{row['id']}",
                title=f"{row['title']} renewal due",
                description="Open the renewal for the document, checklist and next action.",
                start_time=due.isoformat(),
                all_day=True,
                event_type="renewal",
                assigned_to=row["responsible_user_id"],
                read_only=True,
                created_at=row["created_at"],
                updated_at=row["updated_at"],
                created_by=row["created_by"],
                managed_source=_source(row["id"]),
            )
        )
    return result


async def renewal_task_projections(db, *, user: dict) -> list[TaskResponse]:
    result: list[TaskResponse] = []
    for row in await _rows(db, family_id=user["family_id"]):
        if not bool(row["show_in_tasks"]) or not row["responsible_user_id"]:
            continue
        lead_days = max(0, int(row["reminder_days_before"] or 0))
        due = date.fromisoformat(row["due_date"][:10])
        projection_id = f"renewal-task-{row['id']}"
        assignee = TaskAssignee(
            id=f"{projection_id}-assignee",
            assignee_id=row["responsible_user_id"],
            assignee_type="user",
            assignee_name=row.get("responsible_name"),
            completed_at=row["task_completed_at"],
            completed_by=row["task_completed_by"],
        )
        result.append(
            TaskResponse(
                id=projection_id,
                title=f"Review or renew {row['title']}",
                description="Open the renewal for its document, checklist and useful links.",
                assigned_to=row["responsible_user_id"],
                due_date=due.isoformat(),
                completed_at=row["task_completed_at"],
                category="admin",
                priority=2,
                actionable_from=(due - timedelta(days=lead_days)).isoformat(),
                source_document_id=row["source_document_id"],
                created_at=row["created_at"],
                updated_at=row["updated_at"],
                created_by=row["created_by"],
                assignees=[assignee],
                read_only=True,
                managed_source=_source(row["id"]),
            )
        )
    return result


async def set_renewal_task_completed(
    db,
    *,
    user: dict,
    projection_id: str,
    completed: bool,
) -> TaskResponse:
    prefix = "renewal-task-"
    renewal_id = projection_id.removeprefix(prefix)
    if not projection_id.startswith(prefix) or not renewal_id:
        raise RenewalProjectionNotFoundError("Renewal task not found")
    row = await (
        await db.execute(
            """
            SELECT * FROM renewals
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
              AND finance_commitment_id IS NULL AND show_in_tasks = 1
              AND responsible_user_id IS NOT NULL
            """,
            (renewal_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise RenewalProjectionNotFoundError("Renewal task not found")
    already = row["task_completed_at"] is not None
    if already != completed:
        await save_history(
            db,
            "renewals",
            renewal_id,
            user["id"],
            family_id=user["family_id"],
        )
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """
            UPDATE renewals
            SET task_completed_at = ?, task_completed_by = ?, updated_at = ?
            WHERE id = ? AND family_id = ?
            """,
            (
                now if completed else None,
                user["id"] if completed else None,
                now,
                renewal_id,
                user["family_id"],
            ),
        )
        await db.commit()
    tasks = await renewal_task_projections(db, user=user)
    try:
        return next(task for task in tasks if task.id == projection_id)
    except StopIteration as exc:
        raise RenewalProjectionNotFoundError("Renewal task not found") from exc
