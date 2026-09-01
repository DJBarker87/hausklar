"""Family task projections for current library loans."""

import hashlib
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app.models.managed_projection import ManagedSource
from app.models.task import TaskAssignee, TaskResponse
from app.services.record_history import save_history


class LibraryProjectionNotFoundError(ValueError):
    pass


_TASK_PREFIX = "library-task-"


def _projection_id(rows: list[dict]) -> str:
    """Keep single-loan IDs stable and give changing groups a new identity."""
    if len(rows) == 1:
        return f"{_TASK_PREFIX}{rows[0]['id']}"
    due_date = rows[0]["due_date"][:10]
    membership = "\x1f".join(sorted(row["id"] for row in rows))
    digest = hashlib.sha256(membership.encode()).hexdigest()[:12]
    return f"{_TASK_PREFIX}group-{due_date}-{digest}"


def _source(rows: list[dict]) -> ManagedSource:
    first_loan_id = rows[0]["id"]
    count = len(rows)
    return ManagedSource(
        kind="library_loan",
        source_id=first_loan_id,
        deep_link=f"/?view=lists&section=renewals&library={first_loan_id}",
        label="Library book" if count == 1 else f"{count} library books",
    )


def _groups(rows: list[dict]) -> list[list[dict]]:
    by_due_date: dict[str, list[dict]] = {}
    for row in rows:
        by_due_date.setdefault(row["due_date"][:10], []).append(row)
    return list(by_due_date.values())


def _description(rows: list[dict]) -> str:
    if len(rows) == 1:
        return (
            f"{rows[0]['account_label']} library card. Open Library books for "
            "current status and the official renewal link."
        )
    shown = "; ".join(row["title"] for row in rows[:8])
    if len(rows) > 8:
        shown += f"; and {len(rows) - 8} more"
    account_labels = sorted({row["account_label"] for row in rows})
    cards = ", ".join(account_labels)
    return (
        f"Books due together: {shown}. Library cards: {cards}. "
        "Open Library books for current status and the official renewal links."
    )


def _title(rows: list[dict], *, overdue: bool) -> str:
    if len(rows) == 1:
        return (
            f"Return overdue library book: {rows[0]['title']}"
            if overdue
            else f"Renew or return {rows[0]['title']}"
        )
    return (
        f"Return {len(rows)} overdue library books"
        if overdue
        else f"Renew or return {len(rows)} library books"
    )


async def _rows(db, *, family_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            """
            SELECT loan.*, account.label AS account_label
            FROM library_loans loan
            JOIN library_accounts account
              ON account.id = loan.account_id
             AND account.family_id = loan.family_id
             AND account.deleted_at IS NULL
            WHERE loan.family_id = ? AND loan.deleted_at IS NULL
            ORDER BY loan.due_date, loan.title, loan.id
            """,
            (family_id,),
        )
    ).fetchall()
    return [dict(row) for row in rows]


async def _adults(db, *, family_id: str) -> list[dict]:
    rows = await (
        await db.execute(
            """
            SELECT id, name
            FROM users
            WHERE family_id = ? AND deleted_at IS NULL
            ORDER BY priority DESC, name, id
            """,
            (family_id,),
        )
    ).fetchall()
    return [dict(row) for row in rows]


def _adult_assignees(
    projection_id: str,
    adults: list[dict],
    *,
    completed_at: str | None,
    completed_by: str | None,
) -> list[TaskAssignee]:
    return [
        TaskAssignee(
            id=f"{projection_id}-assignee-{adult['id']}",
            assignee_id=adult["id"],
            assignee_type="user",
            assignee_name=adult["name"],
            completed_at=completed_at,
            completed_by=completed_by,
        )
        for adult in adults
    ]


async def library_task_projections(db, *, user: dict) -> list[TaskResponse]:
    result: list[TaskResponse] = []
    today = datetime.now(ZoneInfo("Europe/London")).date()
    rows = await _rows(db, family_id=user["family_id"])
    adults = await _adults(db, family_id=user["family_id"])
    for group in _groups(rows):
        due = date.fromisoformat(group[0]["due_date"][:10])
        completed_values = [row["task_completed_at"] for row in group]
        completed_at = (
            max(value for value in completed_values if value is not None)
            if all(value is not None for value in completed_values)
            else None
        )
        projection_id = _projection_id(group)
        completed_by = (
            next(
                (
                    row["task_completed_by"]
                    for row in group
                    if row["task_completed_at"] == completed_at
                ),
                None,
            )
            if completed_at is not None
            else None
        )
        result.append(
            TaskResponse(
                id=projection_id,
                title=_title(group, overdue=due < today),
                description=_description(group),
                assigned_to=None,
                due_date=due.isoformat(),
                completed_at=completed_at,
                category="admin",
                priority=3 if due < today else 2,
                actionable_from=(due - timedelta(days=7)).isoformat(),
                created_at=min(row["created_at"] for row in group),
                updated_at=max(row["updated_at"] for row in group),
                created_by=group[0]["created_by"],
                assignees=_adult_assignees(
                    projection_id,
                    adults,
                    completed_at=completed_at,
                    completed_by=completed_by,
                ),
                read_only=True,
                managed_source=_source(group),
            )
        )
    return result


async def set_library_task_completed(
    db,
    *,
    user: dict,
    projection_id: str,
    completed: bool,
) -> TaskResponse:
    if not projection_id.startswith(_TASK_PREFIX):
        raise LibraryProjectionNotFoundError("Library task not found")
    rows = await _rows(db, family_id=user["family_id"])
    group = next(
        (candidate for candidate in _groups(rows) if _projection_id(candidate) == projection_id),
        None,
    )
    if group is None:
        raise LibraryProjectionNotFoundError("Library task not found")
    if any((row["task_completed_at"] is not None) != completed for row in group):
        now = datetime.now(timezone.utc).isoformat()
        for row in group:
            await save_history(
                db,
                "library_loans",
                row["id"],
                user["id"],
                family_id=user["family_id"],
            )
            await db.execute(
                """
                UPDATE library_loans
                SET task_completed_at = ?, task_completed_by = ?, updated_at = ?
                WHERE id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (
                    now if completed else None,
                    user["id"] if completed else None,
                    now,
                    row["id"],
                    user["family_id"],
                ),
            )
        await db.commit()
    tasks = await library_task_projections(db, user=user)
    try:
        return next(task for task in tasks if task.id == projection_id)
    except StopIteration as exc:
        raise LibraryProjectionNotFoundError("Library task not found") from exc
