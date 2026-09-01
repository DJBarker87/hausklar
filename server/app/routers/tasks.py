import asyncio
import json
import uuid
from datetime import date, datetime, timezone
from typing import Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status

from app.auth import get_current_user
from app.database import get_db
from app.models.task import (
    AssigneeInput,
    TaskAssignee,
    TaskCreate,
    TaskOverviewPerson,
    TaskResponse,
    TaskUpdate,
)
from app.models.document import LinkedDocumentResponse
from app.middleware.rate_limit import RateLimiter, extract_client_ip
from app.services.create_records import create_or_replay_task
from app.services.host_integrations import require_host_integration_admin
from app.services.idempotency import CreateReplayConflictError
from app.services.managed_tasks import MANAGED_TASK_DETAIL, is_scraper_managed_task
from app.services.finance.projections import (
    FinanceProjectionNotFoundError,
    set_finance_task_completed,
    task_projections,
)
from app.services.renewal_projections import (
    RenewalProjectionNotFoundError,
    renewal_task_projections,
    set_renewal_task_completed,
)
from app.services.library_projections import (
    LibraryProjectionNotFoundError,
    library_task_projections,
    set_library_task_completed,
)
from app.services.task_recurrence import (
    create_next_task_occurrence,
    discard_generated_next_occurrence,
)

router = APIRouter()
bin_refresh_limiter = RateLimiter(max_attempts=2, window_seconds=3_600)
bin_refresh_lock = asyncio.Lock()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _save_history(
    db,
    record_id: str,
    previous: dict,
    changed_by: str | None,
    *,
    family_id: str,
    table_name: str = "tasks",
) -> None:
    """Insert a snapshot of the previous values into record_history."""
    await db.execute(
        """
        INSERT INTO record_history (
            id, table_name, record_id, previous_values, changed_by, changed_at, family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            table_name,
            record_id,
            json.dumps(previous),
            changed_by,
            datetime.now(timezone.utc).isoformat(),
            family_id,
        ),
    )


async def _get_task_assignments_by_task(
    db,
    task_ids: list[str],
    family_id: str,
) -> dict[str, list[TaskAssignee]]:
    """Fetch active assignments and names for a page of tasks in one query."""
    assignments = {task_id: [] for task_id in task_ids}
    if not task_ids:
        return assignments

    placeholders = ", ".join("?" for _ in task_ids)
    cursor = await db.execute(
        f"""
        SELECT ta.task_id, ta.id, ta.assignee_id, ta.assignee_type,
               CASE ta.assignee_type
                   WHEN 'user' THEN u.name
                   ELSE c.name
               END AS assignee_name,
               ta.completed_at, ta.completed_by
        FROM task_assignments ta
        LEFT JOIN users u ON ta.assignee_type = 'user' AND u.id = ta.assignee_id
            AND u.family_id = ta.family_id AND u.deleted_at IS NULL
        LEFT JOIN children c ON ta.assignee_type = 'child' AND c.id = ta.assignee_id
            AND c.family_id = ta.family_id AND c.deleted_at IS NULL
        WHERE ta.task_id IN ({placeholders}) AND ta.deleted_at IS NULL
          AND ta.family_id = ?
        ORDER BY ta.created_at ASC
        """,
        [*task_ids, family_id],
    )
    for row in await cursor.fetchall():
        assignments[row[0]].append(
            TaskAssignee(
                id=row[1],
                assignee_id=row[2],
                assignee_type=row[3],
                assignee_name=row[4],
                completed_at=row[5],
                completed_by=row[6],
            )
        )
    return assignments


async def _get_task_assignments(db, task_id: str, family_id: str) -> list[TaskAssignee]:
    assignments = await _get_task_assignments_by_task(db, [task_id], family_id)
    return assignments[task_id]


async def _get_source_documents(
    db,
    tasks: list[dict],
    family_id: str,
) -> dict[str, LinkedDocumentResponse | None]:
    """Fetch family-scoped document summaries for a page of tasks in one query."""
    result: dict[str, LinkedDocumentResponse | None] = {task["id"]: None for task in tasks}
    document_ids = list(
        {task["source_document_id"] for task in tasks if task.get("source_document_id")}
    )
    if not document_ids:
        return result

    placeholders = ", ".join("?" for _ in document_ids)
    rows = await (
        await db.execute(
            f"""
            SELECT id, title, original_filename, media_type, file_size
            FROM documents
            WHERE id IN ({placeholders}) AND family_id = ? AND deleted_at IS NULL
            """,
            [*document_ids, family_id],
        )
    ).fetchall()
    documents = {
        row["id"]: LinkedDocumentResponse(
            id=row["id"],
            title=row["title"],
            original_filename=row["original_filename"],
            media_type=row["media_type"],
            file_size=row["file_size"],
            download_url=f"/api/documents/{row['id']}/content",
        )
        for row in rows
    }
    for task in tasks:
        result[task["id"]] = documents.get(task.get("source_document_id"))
    return result


async def _get_prep_occurrence_starts(
    db,
    tasks: list[dict],
    family_id: str,
) -> dict[str, str | None]:
    """Resolve the exact calendar occurrence for generated preparation tasks."""
    result = {task["id"]: None for task in tasks}
    occurrence_ids = list(
        {task["prep_occurrence_id"] for task in tasks if task.get("prep_occurrence_id")}
    )
    if not occurrence_ids:
        return result
    placeholders = ", ".join("?" for _ in occurrence_ids)
    rows = await (
        await db.execute(
            f"""SELECT id, occurrence_start
                FROM event_prep_occurrences
                WHERE id IN ({placeholders}) AND family_id = ? AND deleted_at IS NULL""",
            [*occurrence_ids, family_id],
        )
    ).fetchall()
    starts = {row["id"]: row["occurrence_start"] for row in rows}
    for task in tasks:
        result[task["id"]] = starts.get(task.get("prep_occurrence_id"))
    return result


async def _build_task_response(db, row) -> TaskResponse:
    """Build a TaskResponse from a task row, including assignees."""
    task_dict = dict(row)
    assignees = await _get_task_assignments(db, task_dict["id"], task_dict["family_id"])
    documents = await _get_source_documents(db, [task_dict], task_dict["family_id"])
    occurrence_starts = await _get_prep_occurrence_starts(
        db, [task_dict], task_dict["family_id"]
    )
    return TaskResponse(
        **task_dict,
        assignees=assignees,
        source_document=documents[task_dict["id"]],
        prep_occurrence_start=occurrence_starts[task_dict["id"]],
    )


async def _build_task_responses(db, rows) -> list[TaskResponse]:
    """Build a page of task responses without per-task database reads."""
    task_dicts = [dict(row) for row in rows]
    family_id = task_dicts[0]["family_id"] if task_dicts else ""
    assignments = await _get_task_assignments_by_task(
        db,
        [task["id"] for task in task_dicts],
        family_id,
    )
    documents = await _get_source_documents(db, task_dicts, family_id)
    occurrence_starts = await _get_prep_occurrence_starts(db, task_dicts, family_id)
    return [
        TaskResponse(
            **task,
            assignees=assignments[task["id"]],
            source_document=documents[task["id"]],
            prep_occurrence_start=occurrence_starts[task["id"]],
        )
        for task in task_dicts
    ]


async def _sync_assignments(
    db,
    task_id: str,
    assignees: list[AssigneeInput],
    created_by: str | None,
    family_id: str | None = None,
) -> None:
    """Replace all assignments for a task: soft-delete old ones, insert new."""
    now = datetime.now(timezone.utc).isoformat()
    # Soft-delete existing
    await db.execute(
        "UPDATE task_assignments SET deleted_at = ?, updated_at = ? "
        "WHERE task_id = ? AND deleted_at IS NULL",
        (now, now, task_id),
    )
    # Insert new
    if assignees:
        await db.executemany(
            "INSERT INTO task_assignments (id, task_id, assignee_id, assignee_type, created_by, created_at, updated_at, family_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    str(uuid.uuid4()),
                    task_id,
                    assignee.assignee_id,
                    assignee.assignee_type,
                    created_by,
                    now,
                    now,
                    family_id,
                )
                for assignee in assignees
            ],
        )


async def _validate_assignees(
    db,
    assignees: list[AssigneeInput],
    family_id: str,
) -> None:
    if len({(item.assignee_type, item.assignee_id) for item in assignees}) != len(assignees):
        raise HTTPException(status_code=400, detail="Duplicate task assignee")
    for assignee in assignees:
        table = "users" if assignee.assignee_type == "user" else "children"
        cursor = await db.execute(
            f"SELECT id FROM {table} WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (assignee.assignee_id, family_id),
        )
        if not await cursor.fetchone():
            raise HTTPException(status_code=400, detail="Task assignee is not in this family")


async def _legacy_assignee(
    db,
    assignee_id: str,
    family_id: str,
) -> AssigneeInput:
    cursor = await db.execute(
        """
        SELECT id, 'user' AS assignee_type FROM users
        WHERE id = ? AND family_id = ? AND deleted_at IS NULL
        UNION ALL
        SELECT id, 'child' AS assignee_type FROM children
        WHERE id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (assignee_id, family_id, assignee_id, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=400, detail="Task assignee is not in this family")
    return AssigneeInput(assignee_id=row["id"], assignee_type=row["assignee_type"])


# ---------------------------------------------------------------------------
# Overview — MUST be declared before /{task_id} routes
# ---------------------------------------------------------------------------


@router.get("/overview", response_model=list[TaskOverviewPerson])
async def task_overview(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Per-person task summary: pending, completed today, overdue counts."""
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0).isoformat()

    # Get all active assignments joined with their tasks
    cursor = await db.execute(
        """
        SELECT ta.assignee_id, ta.assignee_type, ta.completed_at,
               t.due_date, t.completed_at AS task_completed_at,
               t.actionable_from,
               CASE ta.assignee_type
                   WHEN 'user' THEN u.name
                   ELSE c.name
               END AS assignee_name
        FROM task_assignments ta
        JOIN tasks t ON t.id = ta.task_id
        LEFT JOIN users u ON ta.assignee_type = 'user' AND u.id = ta.assignee_id
        LEFT JOIN children c ON ta.assignee_type = 'child' AND c.id = ta.assignee_id
        WHERE ta.deleted_at IS NULL AND t.deleted_at IS NULL
          AND t.family_id = ?
        """,
        (current_user["family_id"],),
    )
    rows = await cursor.fetchall()

    now_iso = now.isoformat()

    # Aggregate per person
    people: dict[str, dict] = {}
    for row in rows:
        assignee_id = row[0]
        assignee_type = row[1]
        assignment_completed = row[2]
        due_date = row[3]
        task_completed = row[4]
        actionable_from = row[5]
        assignee_name = row[6]

        if assignee_id not in people:
            people[assignee_id] = {
                "person_type": assignee_type,
                "total_pending": 0,
                "total_completed_today": 0,
                "overdue": 0,
                "name": assignee_name,
            }

        p = people[assignee_id]
        if assignment_completed is None and task_completed is None:
            # Only count as pending if currently actionable
            is_actionable = actionable_from is None or actionable_from <= now_iso
            if is_actionable:
                p["total_pending"] += 1
                if due_date and due_date < now_iso:
                    p["overdue"] += 1
        elif assignment_completed and assignment_completed >= today_start:
            p["total_completed_today"] += 1
        elif task_completed and task_completed >= today_start and assignment_completed is None:
            # Task was bulk-completed today — count as completed today
            p["total_completed_today"] += 1

    # Library tasks are computed from the live family loan list rather than
    # stored in tasks/task_assignments. Include their shared adult assignees in
    # the same overview so the per-person view matches the task list.
    for task in await library_task_projections(db, user=current_user):
        for assignee in task.assignees:
            if assignee.assignee_id not in people:
                people[assignee.assignee_id] = {
                    "person_type": assignee.assignee_type,
                    "total_pending": 0,
                    "total_completed_today": 0,
                    "overdue": 0,
                    "name": assignee.assignee_name,
                }
            person = people[assignee.assignee_id]
            if assignee.completed_at is None and task.completed_at is None:
                is_actionable = (
                    task.actionable_from is None or task.actionable_from <= now_iso
                )
                if is_actionable:
                    person["total_pending"] += 1
                    if task.due_date and task.due_date < now_iso:
                        person["overdue"] += 1
            elif assignee.completed_at and assignee.completed_at >= today_start:
                person["total_completed_today"] += 1

    result = []
    for person_id, data in people.items():
        result.append(
            TaskOverviewPerson(
                person_id=person_id,
                person_name=data["name"] or "Unknown",
                person_type=data["person_type"],
                total_pending=data["total_pending"],
                total_completed_today=data["total_completed_today"],
                overdue=data["overdue"],
            )
        )

    # Sort: users first, then children, then alphabetical
    result.sort(key=lambda p: (0 if p.person_type == "user" else 1, p.person_name))
    return result


# ---------------------------------------------------------------------------
# CRUD endpoints
# ---------------------------------------------------------------------------


@router.get("/", response_model=list[TaskResponse])
async def list_tasks(
    status_filter: str | None = Query(None, alias="status"),
    category: str | None = None,
    assigned_to: str | None = None,
    actionable: str | None = Query(None),
    order: Literal["created", "attention"] = Query("created"),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List tasks with optional filters. Excludes soft-deleted records."""
    if assigned_to is not None:
        # Search in junction table for assignee matches
        query = """
            SELECT DISTINCT t.* FROM tasks t
            JOIN task_assignments ta ON ta.task_id = t.id
            WHERE t.deleted_at IS NULL
              AND ta.deleted_at IS NULL
              AND t.family_id = ?
              AND ta.assignee_id = ?
        """
        params: list = [current_user["family_id"], assigned_to]
    else:
        query = "SELECT * FROM tasks WHERE deleted_at IS NULL AND family_id = ?"
        params = [current_user["family_id"]]

    t_prefix = "t." if assigned_to else ""

    if status_filter == "pending":
        query += f" AND {t_prefix}completed_at IS NULL"
    elif status_filter == "completed":
        query += f" AND {t_prefix}completed_at IS NOT NULL"

    if category is not None:
        query += f" AND {t_prefix}category = ?"
        params.append(category)

    if actionable == "now":
        query += f" AND ({t_prefix}actionable_from IS NULL OR datetime({t_prefix}actionable_from) <= datetime('now'))"
    elif actionable == "upcoming":
        query += f" AND {t_prefix}actionable_from IS NOT NULL AND datetime({t_prefix}actionable_from) > datetime('now') AND {t_prefix}completed_at IS NULL"

    if order == "attention":
        query += (
            f" ORDER BY {t_prefix}priority DESC, "
            f"CASE WHEN {t_prefix}due_date IS NULL THEN 1 ELSE 0 END, "
            f"{t_prefix}due_date ASC, {t_prefix}created_at DESC"
        )
    else:
        query += f" ORDER BY {t_prefix}created_at DESC"
    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    ordinary = await _build_task_responses(db, rows)
    projected = await task_projections(db, user=current_user)
    projected.extend(await renewal_task_projections(db, user=current_user))
    projected.extend(await library_task_projections(db, user=current_user))
    now = datetime.now(timezone.utc)
    local_today = datetime.now(ZoneInfo("Europe/London")).date()
    if status_filter == "pending":
        projected = [task for task in projected if task.completed_at is None]
    elif status_filter == "completed":
        projected = [task for task in projected if task.completed_at is not None]
    if category is not None:
        projected = [task for task in projected if task.category == category]
    if assigned_to is not None:
        projected = [
            task
            for task in projected
            if task.assigned_to == assigned_to
            or any(assignee.assignee_id == assigned_to for assignee in task.assignees)
        ]
    if actionable == "now":
        projected = [
            task
            for task in projected
            if task.actionable_from is None
            or (
                date.fromisoformat(task.actionable_from) <= local_today
                if len(task.actionable_from) == 10
                else datetime.fromisoformat(task.actionable_from.replace("Z", "+00:00")) <= now
            )
        ]
    elif actionable == "upcoming":
        projected = [
            task
            for task in projected
            if task.completed_at is None
            and task.actionable_from is not None
            and (
                date.fromisoformat(task.actionable_from) > local_today
                if len(task.actionable_from) == 10
                else datetime.fromisoformat(task.actionable_from.replace("Z", "+00:00")) > now
            )
        ]
    combined = [*ordinary, *projected]
    if order == "attention":
        combined.sort(
            key=lambda task: (
                -task.priority,
                task.due_date is None,
                task.due_date or "",
                task.created_at,
            )
        )
    else:
        combined.sort(key=lambda task: task.created_at, reverse=True)
    return combined[offset : offset + limit]


@router.post("/", response_model=TaskResponse, status_code=status.HTTP_201_CREATED)
async def create_task(
    body: TaskCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a new task."""
    try:
        row, _replayed = await create_or_replay_task(
            db,
            body,
            record_id=str(body.id),
            user=current_user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    except CreateReplayConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return await _build_task_response(db, row)


# ---------------------------------------------------------------------------
# Bin collection refresh (must be before /{task_id} routes)
# ---------------------------------------------------------------------------


@router.post("/bins/refresh")
async def refresh_bins(
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """Re-scrape Local authority bin collection dates and update tasks."""
    require_host_integration_admin(current_user)
    key = f"bin-refresh:{current_user['id']}:{extract_client_ip(request)}"
    bin_refresh_limiter.ensure_allowed(
        key,  # gitleaks:allow
        detail_prefix="Too many bin refresh requests",
    )
    bin_refresh_limiter.record_failure(key)
    if bin_refresh_lock.locked():
        raise HTTPException(status_code=409, detail="A bin refresh is already running")
    from app.services.bin_scraper import refresh_bin_tasks_for_family

    async with bin_refresh_lock:
        result = await refresh_bin_tasks_for_family(family_id=current_user["family_id"])
    return result


@router.put("/{task_id}", response_model=TaskResponse)
async def update_task(
    task_id: str,
    body: TaskUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update an existing task. Saves previous values to record_history."""
    # Serialize validation and mutation with document deletion so a validated
    # attachment cannot become dangling before this request writes it.
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT * FROM tasks WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
            (task_id, current_user["family_id"]),
        )
        existing = await cursor.fetchone()
        if not existing:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")
        if is_scraper_managed_task(existing):
            raise HTTPException(status_code=409, detail=MANAGED_TASK_DETAIL)

        # Save history before modifying
        await _save_history(
            db,
            task_id,
            dict(existing),
            current_user["id"],
            family_id=current_user["family_id"],
        )

        updates = body.model_dump(exclude_unset=True)
        # Remove assignees from the dict — handled separately
        assignees_input = updates.pop("assignees", None)  # gitleaks:allow
        if "assigned_to" in updates and updates["assigned_to"] is not None:
            await _legacy_assignee(db, updates["assigned_to"], current_user["family_id"])
        if "source_document_id" in updates and updates["source_document_id"] is not None:
            document = await (
                await db.execute(
                    "SELECT 1 FROM documents "
                    "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                    (updates["source_document_id"], current_user["family_id"]),
                )
            ).fetchone()
            if document is None:
                raise HTTPException(
                    status_code=400,
                    detail="Attached document is not available to this family",
                )
        parsed_assignees = None
        if assignees_input is not None:
            parsed_assignees = [
                AssigneeInput(**item) if isinstance(item, dict) else item
                for item in assignees_input
            ]
            await _validate_assignees(db, parsed_assignees, current_user["family_id"])

        if updates:
            now = datetime.now(timezone.utc).isoformat()
            updates["updated_at"] = now

            set_clause = ", ".join(f"{key} = ?" for key in updates)
            values = list(updates.values()) + [task_id, current_user["family_id"]]

            await db.execute(
                f"UPDATE tasks SET {set_clause} WHERE id = ? AND family_id = ?",
                values,
            )

        # Sync assignments if provided
        if parsed_assignees is not None:
            await _sync_assignments(
                db,
                task_id,
                parsed_assignees,
                current_user["id"],
                current_user["family_id"],
            )

        cursor = await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
        row = await cursor.fetchone()
        response = await _build_task_response(db, row)
        await db.commit()
        return response
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


@router.patch("/{task_id}/complete", response_model=TaskResponse)
async def complete_task(
    task_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Mark a task as completed by setting completed_at to now. Also marks all assignments complete."""
    if task_id.startswith("finance-task-"):
        try:
            return await set_finance_task_completed(
                db,
                user=current_user,
                projection_id=task_id,
                completed=True,
            )
        except FinanceProjectionNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
    if task_id.startswith("renewal-task-"):
        try:
            return await set_renewal_task_completed(
                db,
                user=current_user,
                projection_id=task_id,
                completed=True,
            )
        except RenewalProjectionNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
    if task_id.startswith("library-task-"):
        try:
            return await set_library_task_completed(
                db,
                user=current_user,
                projection_id=task_id,
                completed=True,
            )
        except LibraryProjectionNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
    cursor = await db.execute(
        "SELECT * FROM tasks WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (task_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")
    if existing["completed_at"] is not None:
        return await _build_task_response(db, existing)

    # Save history before modifying
    await _save_history(
        db,
        task_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    cursor = await db.execute(
        """
        SELECT * FROM task_assignments
        WHERE task_id = ? AND family_id = ?
          AND deleted_at IS NULL AND completed_at IS NULL
        """,
        (task_id, current_user["family_id"]),
    )
    for assignment in await cursor.fetchall():
        await _save_history(
            db,
            assignment["id"],
            dict(assignment),
            current_user["id"],
            family_id=current_user["family_id"],
            table_name="task_assignments",
        )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE tasks SET completed_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, task_id, current_user["family_id"]),
    )

    # Also mark all active assignments as complete
    await db.execute(
        "UPDATE task_assignments SET completed_at = ?, completed_by = ?, updated_at = ? "
        "WHERE task_id = ? AND family_id = ? "
        "AND deleted_at IS NULL AND completed_at IS NULL",
        (now, current_user["id"], now, task_id, current_user["family_id"]),
    )

    if not is_scraper_managed_task(existing):
        await create_next_task_occurrence(
            db,
            existing,
            completed_at=now,
            created_by=current_user["id"],
        )

    await db.commit()

    cursor = await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
    row = await cursor.fetchone()
    return await _build_task_response(db, row)


@router.patch("/{task_id}/reopen", response_model=TaskResponse)
async def reopen_task(
    task_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Reopen a completed task without changing any linked payment state."""
    if task_id.startswith("finance-task-"):
        try:
            return await set_finance_task_completed(
                db,
                user=current_user,
                projection_id=task_id,
                completed=False,
            )
        except FinanceProjectionNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
    if task_id.startswith("renewal-task-"):
        try:
            return await set_renewal_task_completed(
                db,
                user=current_user,
                projection_id=task_id,
                completed=False,
            )
        except RenewalProjectionNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
    if task_id.startswith("library-task-"):
        try:
            return await set_library_task_completed(
                db,
                user=current_user,
                projection_id=task_id,
                completed=False,
            )
        except LibraryProjectionNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    existing = await (
        await db.execute(
            "SELECT * FROM tasks WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
            (task_id, current_user["family_id"]),
        )
    ).fetchone()
    if existing is None:
        raise HTTPException(status_code=404, detail="Task not found")
    if existing["completed_at"] is None:
        return await _build_task_response(db, existing)
    if is_scraper_managed_task(existing):
        raise HTTPException(status_code=409, detail=MANAGED_TASK_DETAIL)
    await _save_history(
        db,
        task_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE tasks SET completed_at = NULL, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, task_id, current_user["family_id"]),
    )
    await db.execute(
        """
        UPDATE task_assignments
        SET completed_at = NULL, completed_by = NULL, updated_at = ?
        WHERE task_id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (now, task_id, current_user["family_id"]),
    )
    await discard_generated_next_occurrence(
        db,
        source_task_id=task_id,
        family_id=current_user["family_id"],
        changed_by=current_user["id"],
        now=now,
    )
    await db.commit()
    row = await (await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))).fetchone()
    return await _build_task_response(db, row)


@router.patch("/{task_id}/complete/{assignee_id}", response_model=TaskResponse)
async def complete_task_for_person(
    task_id: str,
    assignee_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Mark one person's assignment as complete. Does NOT complete the overall task."""
    # Verify task exists
    cursor = await db.execute(
        "SELECT * FROM tasks WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (task_id, current_user["family_id"]),
    )
    task = await cursor.fetchone()
    if not task:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")

    # Find the assignment
    cursor = await db.execute(
        "SELECT * FROM task_assignments "
        "WHERE task_id = ? AND family_id = ? AND assignee_id = ? AND deleted_at IS NULL",
        (task_id, current_user["family_id"], assignee_id),
    )
    assignment = await cursor.fetchone()
    if not assignment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Assignment not found")
    if assignment["completed_at"] is not None:
        return await _build_task_response(db, task)

    await _save_history(
        db,
        assignment["id"],
        dict(assignment),
        current_user["id"],
        family_id=current_user["family_id"],
        table_name="task_assignments",
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE task_assignments SET completed_at = ?, completed_by = ?, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (
            now,
            current_user["id"],
            now,
            assignment["id"],
            current_user["family_id"],
        ),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
    row = await cursor.fetchone()
    return await _build_task_response(db, row)


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_task(
    task_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete a task by setting deleted_at."""
    cursor = await db.execute(
        "SELECT * FROM tasks WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (task_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")
    if is_scraper_managed_task(existing):
        raise HTTPException(status_code=409, detail=MANAGED_TASK_DETAIL)

    # Save history before modifying
    await _save_history(
        db,
        task_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE tasks SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, task_id, current_user["family_id"]),
    )
    # Also soft-delete assignments
    await db.execute(
        "UPDATE task_assignments SET deleted_at = ?, updated_at = ? "
        "WHERE task_id = ? AND deleted_at IS NULL",
        (now, now, task_id),
    )
    await db.commit()
