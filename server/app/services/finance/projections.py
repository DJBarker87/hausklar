"""Authenticated, amount-free Finance dates projected into Calendar and Tasks."""

import uuid
from datetime import date, datetime, timedelta, timezone

from app.models.calendar import CalendarEventResponse
from app.models.finance import (
    FinanceCalendarItemCreate,
    FinanceCalendarItemResponse,
    FinanceProjectionPreferenceResponse,
)
from app.models.managed_projection import ManagedSource
from app.models.task import TaskAssignee, TaskResponse
from app.services.finance.foundation import (
    get_finance_settings,
    require_finance_access,
    require_finance_space,
)
from app.services.record_history import save_history


class FinanceProjectionError(ValueError):
    pass


class FinanceProjectionNotFoundError(FinanceProjectionError):
    pass


class FinanceProjectionConflictError(FinanceProjectionError):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


async def get_projection_preference(
    db, *, user: dict
) -> FinanceProjectionPreferenceResponse:
    require_finance_access(user)
    await get_finance_settings(db, user=user)
    row = await (
        await db.execute(
            """
            SELECT show_money, show_deliveries
            FROM finance_projection_preferences
            WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (user["id"], user["family_id"]),
        )
    ).fetchone()
    # Safe by default for entitled adults: commitments still require explicit
    # per-record sharing and delivery items require reviewed typed dates.
    return FinanceProjectionPreferenceResponse(
        show_money=True if row is None else bool(row["show_money"]),
        show_deliveries=True if row is None else bool(row["show_deliveries"]),
    )


async def set_projection_preference(
    db, *, user: dict, show_money: bool, show_deliveries: bool
) -> FinanceProjectionPreferenceResponse:
    require_finance_access(user)
    await get_finance_settings(db, user=user)
    now = _now()
    row = await (
        await db.execute(
            """
            SELECT id FROM finance_projection_preferences
            WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (user["id"], user["family_id"]),
        )
    ).fetchone()
    if row is None:
        await db.execute(
            """
            INSERT INTO finance_projection_preferences
                (id, user_id, show_money, show_deliveries, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                user["id"],
                int(show_money),
                int(show_deliveries),
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    else:
        await save_history(
            db,
            "finance_projection_preferences",
            row["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_projection_preferences
            SET show_money = ?, show_deliveries = ?, updated_at = ? WHERE id = ?
            """,
            (int(show_money), int(show_deliveries), now, row["id"]),
        )
    await db.commit()
    return FinanceProjectionPreferenceResponse(
        show_money=show_money,
        show_deliveries=show_deliveries,
    )


def _source_for_commitment(row: dict) -> ManagedSource:
    if row.get("renewal_id"):
        return ManagedSource(
            kind="finance_renewal",
            source_id=row["renewal_id"],
            deep_link=f"/?view=finance&section=more&renewal={row['renewal_id']}",
            label="Finance renewal",
        )
    return ManagedSource(
        kind="finance_commitment",
        source_id=row["commitment_id"],
        deep_link=(
            f"/?view=finance&section=plan&commitment={row['commitment_id']}"
        ),
        label="Household Finance",
    )


def _commitment_calendar_title(row: dict) -> str:
    if row.get("renewal_id"):
        return f"{row['renewal_title']} renewal due"
    if row["payment_handling"] == "RENEWAL":
        return f"{row['commitment_name']} renewal due"
    if row["payment_handling"] == "AUTOMATIC":
        return f"{row['commitment_name']} payment review"
    return f"{row['commitment_name']} due"


def _commitment_task_title(row: dict) -> str:
    if row["payment_handling"] == "MANUAL":
        return f"Pay {row['commitment_name']}"
    if row["payment_handling"] == "RENEWAL":
        title = row.get("renewal_title") or row["commitment_name"]
        return f"Review or renew {title}"
    return f"Review {row['commitment_name']} payment"


async def _commitment_projection_rows(db, *, user: dict) -> list[dict]:
    return [
        dict(row)
        for row in await (
            await db.execute(
                """
                SELECT occurrence.*, commitment.id AS commitment_id,
                       commitment.name AS commitment_name,
                       commitment.payment_handling, commitment.priority,
                       commitment.responsible_user_id,
                       commitment.show_in_calendar, commitment.show_in_tasks,
                       commitment.status AS commitment_status,
                       renewal.id AS renewal_id,
                       renewal.title AS renewal_title,
                       renewal.category AS renewal_category,
                       renewal.reminder_days_before,
                       responsible.name AS responsible_name
                FROM finance_commitment_occurrences occurrence
                JOIN finance_commitments commitment
                  ON commitment.id = occurrence.commitment_id
                 AND commitment.family_id = occurrence.family_id
                 AND commitment.deleted_at IS NULL
                JOIN finance_spaces space
                  ON space.id = commitment.space_id
                 AND space.family_id = commitment.family_id
                 AND space.kind = 'household'
                 AND space.owner_user_id IS NULL
                 AND space.deleted_at IS NULL
                LEFT JOIN renewals renewal
                  ON renewal.finance_commitment_id = commitment.id
                 AND renewal.family_id = commitment.family_id
                 AND renewal.deleted_at IS NULL
                LEFT JOIN users responsible
                  ON responsible.id = commitment.responsible_user_id
                 AND responsible.family_id = commitment.family_id
                 AND responsible.deleted_at IS NULL
                WHERE occurrence.family_id = ? AND occurrence.deleted_at IS NULL
                  AND occurrence.status = 'ACTIVE'
                  AND commitment.status = 'ACTIVE'
                ORDER BY occurrence.due_date, occurrence.id
                """,
                (user["family_id"],),
            )
        ).fetchall()
    ]


def _in_calendar_range(value: str, *, range_start: datetime, range_end: datetime) -> bool:
    if len(value) == 10:
        point = datetime.combine(
            date.fromisoformat(value),
            datetime.min.time(),
            range_start.tzinfo,
        )
    else:
        point = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return range_start <= point < range_end


async def calendar_projections(
    db,
    *,
    user: dict,
    range_start: datetime,
    range_end: datetime,
) -> list[CalendarEventResponse]:
    preference = await get_projection_preference(db, user=user)
    result: list[CalendarEventResponse] = []
    if preference.show_money:
        for row in await _commitment_projection_rows(db, user=user):
            if not bool(row["show_in_calendar"]):
                continue
            if not _in_calendar_range(row["due_date"], range_start=range_start, range_end=range_end):
                continue
            result.append(
                CalendarEventResponse(
                    id=row["calendar_projection_id"],
                    title=_commitment_calendar_title(row),
                    description="Managed in Finance. No amount or account details are shown here.",
                    start_time=row["due_date"],
                    all_day=True,
                    event_type="finance_commitment",
                    assigned_to=row["responsible_user_id"],
                    read_only=True,
                    created_at=row["created_at"],
                    updated_at=row["updated_at"],
                    created_by=row["created_by"],
                    managed_source=_source_for_commitment(row),
                )
            )

    delivery_rows = [] if not preference.show_deliveries else await (
        await db.execute(
            """
            SELECT item.*, source.source_kind,
                   space.kind AS space_kind,
                   space.owner_user_id AS space_owner_user_id
            FROM finance_calendar_items item
            JOIN finance_spaces space
              ON space.id = item.space_id AND space.family_id = item.family_id
             AND space.deleted_at IS NULL
            JOIN finance_purchase_sources source
              ON source.id = item.source_id AND source.space_id = item.space_id
             AND source.family_id = item.family_id AND source.deleted_at IS NULL
            WHERE item.family_id = ? AND item.status = 'ACTIVE'
              AND item.reviewed = 1 AND item.deleted_at IS NULL
              AND (
                  (space.kind = 'personal' AND space.owner_user_id = ?)
                  OR (space.kind = 'household' AND space.owner_user_id IS NULL)
              )
            ORDER BY item.starts_at, item.id
            """,
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    for raw in delivery_rows:
        row = dict(raw)
        if not _in_calendar_range(row["starts_at"], range_start=range_start, range_end=range_end):
            continue
        title = "Tesco delivery" if row["item_kind"] == "GROCERY_DELIVERY" else "Parcel delivery"
        result.append(
            CalendarEventResponse(
                id=row["calendar_projection_id"],
                title=title,
                description="Reviewed delivery time from Finance.",
                start_time=row["starts_at"],
                end_time=row["ends_at"],
                all_day=bool(row["all_day"]),
                event_type="finance_delivery",
                assigned_to=(
                    row["space_owner_user_id"]
                    if row["space_kind"] == "personal"
                    else None
                ),
                read_only=True,
                created_at=row["created_at"],
                updated_at=row["updated_at"],
                created_by=row["created_by"],
                managed_source=ManagedSource(
                    kind="finance_order",
                    source_id=row["source_id"],
                    deep_link=(
                        f"/?view=finance&section=activity&evidence={row['source_id']}"
                    ),
                    label="Finance delivery",
                ),
            )
        )
    return sorted(result, key=lambda item: item.start_time)


async def task_projections(db, *, user: dict) -> list[TaskResponse]:
    result: list[TaskResponse] = []
    for row in await _commitment_projection_rows(db, user=user):
        if not bool(row["show_in_tasks"]) or not row["responsible_user_id"]:
            continue
        lead_days = row.get("reminder_days_before") or 21
        due = date.fromisoformat(row["due_date"])
        completed_at = row["task_completed_at"]
        assignee = TaskAssignee(
            id=f"{row['task_projection_id']}-assignee",
            assignee_id=row["responsible_user_id"],
            assignee_type="user",
            assignee_name=row.get("responsible_name"),
            completed_at=completed_at,
            completed_by=row["task_completed_by"],
        )
        result.append(
            TaskResponse(
                id=row["task_projection_id"],
                title=_commitment_task_title(row),
                description="Managed in Finance. Completing this task does not confirm that money cleared.",
                assigned_to=row["responsible_user_id"],
                due_date=row["due_date"],
                completed_at=completed_at,
                category="admin",
                priority={"PROTECTED": 3, "IMPORTANT": 2, "OPTIONAL": 1}.get(
                    row["priority"], 2
                ),
                actionable_from=(due - timedelta(days=lead_days)).isoformat(),
                created_at=row["created_at"],
                updated_at=row["updated_at"],
                created_by=row["created_by"],
                assignees=[assignee],
                read_only=True,
                managed_source=_source_for_commitment(row),
            )
        )
    return result


async def _authorised_task_occurrence(db, *, user: dict, projection_id: str) -> dict:
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT occurrence.*
            FROM finance_commitment_occurrences occurrence
            JOIN finance_commitments commitment
              ON commitment.id = occurrence.commitment_id
             AND commitment.family_id = occurrence.family_id
             AND commitment.deleted_at IS NULL
            JOIN finance_spaces space
              ON space.id = commitment.space_id
             AND space.family_id = commitment.family_id
             AND space.kind = 'household' AND space.owner_user_id IS NULL
             AND space.deleted_at IS NULL
            WHERE occurrence.task_projection_id = ?
              AND occurrence.family_id = ? AND occurrence.deleted_at IS NULL
              AND occurrence.status = 'ACTIVE' AND commitment.status = 'ACTIVE'
              AND commitment.show_in_tasks = 1
            """,
            (projection_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceProjectionNotFoundError("Finance task not found")
    return dict(row)


async def set_finance_task_completed(
    db, *, user: dict, projection_id: str, completed: bool
) -> TaskResponse:
    occurrence = await _authorised_task_occurrence(
        db, user=user, projection_id=projection_id
    )
    already_in_requested_state = (
        occurrence["task_completed_at"] is not None
        if completed
        else occurrence["task_completed_at"] is None
    )
    if already_in_requested_state:
        tasks = await task_projections(db, user=user)
        return next(task for task in tasks if task.id == projection_id)
    await save_history(
        db,
        "finance_commitment_occurrences",
        occurrence["id"],
        user["id"],
        family_id=user["family_id"],
    )
    now = _now()
    await db.execute(
        """
        UPDATE finance_commitment_occurrences
        SET task_completed_at = ?, task_completed_by = ?, updated_at = ?
        WHERE id = ? AND family_id = ?
        """,
        (
            now if completed else None,
            user["id"] if completed else None,
            now,
            occurrence["id"],
            user["family_id"],
        ),
    )
    await db.commit()
    tasks = await task_projections(db, user=user)
    return next(task for task in tasks if task.id == projection_id)


async def create_calendar_item(
    db, *, user: dict, body: FinanceCalendarItemCreate
) -> FinanceCalendarItemResponse:
    await require_finance_space(db, user=user, space_id=body.space_id)
    source = await (
        await db.execute(
            """
            SELECT id, source_kind FROM finance_purchase_sources
            WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (body.source_id, body.space_id, user["family_id"]),
        )
    ).fetchone()
    if source is None:
        raise FinanceProjectionNotFoundError("Finance purchase source not found")
    if body.item_kind == "GROCERY_DELIVERY" and source["source_kind"] != "tesco_batch":
        raise FinanceProjectionError("Grocery delivery dates require Tesco evidence")
    existing = await (
        await db.execute(
            """
            SELECT * FROM finance_calendar_items
            WHERE space_id = ? AND source_id = ? AND item_kind = ?
              AND deleted_at IS NULL
            """,
            (body.space_id, body.source_id, body.item_kind),
        )
    ).fetchone()
    now = _now()
    if existing is not None:
        await save_history(
            db,
            "finance_calendar_items",
            existing["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_calendar_items
            SET starts_at = ?, ends_at = ?, all_day = ?, status = 'ACTIVE',
                updated_at = ?
            WHERE id = ? AND space_id = ?
            """,
            (
                body.starts_at,
                body.ends_at,
                int(body.all_day),
                now,
                existing["id"],
                body.space_id,
            ),
        )
        identifier = existing["id"]
    else:
        identifier = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO finance_calendar_items
                (id, space_id, item_kind, source_id, starts_at, ends_at, all_day,
                 reviewed, calendar_projection_id, status, family_id, created_at,
                 updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, 'ACTIVE', ?, ?, ?, ?)
            """,
            (
                identifier,
                body.space_id,
                body.item_kind,
                body.source_id,
                body.starts_at,
                body.ends_at,
                int(body.all_day),
                f"finance-calendar-item-{identifier}",
                user["family_id"],
                now,
                now,
                user["id"],
            ),
        )
    await db.commit()
    row = await (
        await db.execute("SELECT * FROM finance_calendar_items WHERE id = ?", (identifier,))
    ).fetchone()
    return FinanceCalendarItemResponse(
        id=row["id"],
        space_id=row["space_id"],
        item_kind=row["item_kind"],
        source_id=row["source_id"],
        starts_at=row["starts_at"],
        ends_at=row["ends_at"],
        all_day=bool(row["all_day"]),
        status=row["status"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


async def cancel_calendar_item(db, *, user: dict, item_id: str) -> None:
    require_finance_access(user)
    row = await (
        await db.execute(
            """
            SELECT item.* FROM finance_calendar_items item
            JOIN finance_spaces space ON space.id = item.space_id
              AND space.family_id = item.family_id AND space.deleted_at IS NULL
            WHERE item.id = ? AND item.family_id = ? AND item.deleted_at IS NULL
              AND ((space.kind = 'personal' AND space.owner_user_id = ?)
                   OR (space.kind = 'household' AND space.owner_user_id IS NULL))
            """,
            (item_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceProjectionNotFoundError("Finance calendar item not found")
    await save_history(
        db,
        "finance_calendar_items",
        item_id,
        user["id"],
        family_id=user["family_id"],
    )
    await db.execute(
        "UPDATE finance_calendar_items SET status = 'CANCELLED', updated_at = ? WHERE id = ?",
        (_now(), item_id),
    )
    await db.commit()
