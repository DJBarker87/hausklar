"""Exactly-once create services shared by direct API and offline sync."""

import json
import uuid
from datetime import datetime, timezone

from dateutil.rrule import rrulestr

from app.models.calendar import CalendarEventCreate, CalendarEventUpdate
from app.models.meal import ShoppingItemCreate
from app.models.medicine import MedicineTypeCreate
from app.models.task import AssigneeInput, TaskCreate
from app.services.calendar_attachments import (
    creation_attachment_specs,
    replace_event_attachments,
    stored_attachment_specs,
    validate_attachment_specs,
)
from app.services.family_people import (
    family_child_exists,
    family_person_type,
    validate_calendar_people,
)
from app.services.idempotency import (
    existing_create_row,
    reject_create_mismatch,
    serialized_create,
)


def _parse_timestamp(value: str, field_name: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} is invalid") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _validated_recurrence(value: str | None, *, starts_at: datetime) -> str | None:
    if value is None:
        return None
    try:
        normalised = CalendarEventUpdate(recurrence_rule=value).recurrence_rule
        if normalised:
            rrulestr(normalised, dtstart=starts_at)
    except (TypeError, ValueError) as exc:
        raise ValueError("Recurrence rule is invalid") from exc
    return normalised


def _calendar_members(value: str | None) -> list[str] | None:
    if not value:
        return None
    try:
        decoded = json.loads(value)
    except (TypeError, ValueError) as exc:
        raise ValueError("Stored calendar members are invalid") from exc
    return decoded


async def create_or_replay_calendar_event(
    db,
    body: CalendarEventCreate,
    *,
    record_id: str,
    user: dict,
    client_id: str | None,
    client_timestamp: str | None,
) -> tuple[dict, bool]:
    family_id = user["family_id"]
    user_id = user["id"]
    start = _parse_timestamp(body.start_time, "Calendar start time")
    if body.end_time is not None:
        end = _parse_timestamp(body.end_time, "Calendar end time")
        if end <= start:
            raise ValueError("Calendar end time must be after start time")
    recurrence = _validated_recurrence(body.recurrence_rule, starts_at=start)
    attachment_specs = creation_attachment_specs(body)
    legacy_source_document_id = attachment_specs[0][0] if attachment_specs else None
    member_ids = list(body.family_member_ids or [])
    if body.assigned_to and body.assigned_to not in member_ids:
        member_ids.append(body.assigned_to)

    async with serialized_create(db):
        existing = await existing_create_row(
            db,
            table_name="calendar_events",
            record_id=record_id,
            family_id=family_id,
            user_id=user_id,
        )
        if existing is not None:
            existing_attachment_specs = await stored_attachment_specs(
                db,
                event_id=record_id,
                family_id=family_id,
                legacy_source_document_id=existing["source_document_id"],
            )
            reject_create_mismatch(
                existing["title"] == body.title
                and existing["description"] == body.description
                and existing["start_time"] == body.start_time
                and existing["end_time"] == body.end_time
                and bool(existing["all_day"]) == body.all_day
                and existing["recurrence_rule"] == recurrence
                and existing["location"] == body.location
                and _calendar_members(existing["family_member_ids"])
                == (body.family_member_ids or None)
                and _calendar_members(existing["affected_member_ids"])
                == (body.affected_member_ids or None)
                and existing["assigned_to"] == body.assigned_to
                and existing["event_type"] == body.event_type
                and existing["exertion"] == body.exertion
                and existing["source_document_id"] == legacy_source_document_id
                and existing_attachment_specs == attachment_specs
            )
            return dict(existing), True

        await validate_attachment_specs(
            db,
            specs=attachment_specs,
            family_id=family_id,
        )

        await validate_calendar_people(
            db,
            family_id,
            member_ids,
            list(body.affected_member_ids or []),
            whole_family=body.family_member_ids is None and body.assigned_to is None,
        )
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """
            INSERT INTO calendar_events
                (id, title, description, start_time, end_time, all_day,
                 recurrence_rule, location, family_member_ids, affected_member_ids, assigned_to,
                 event_type, exertion, source_document_id, family_id, created_at, updated_at,
                 created_by, client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                record_id,
                body.title,
                body.description,
                body.start_time,
                body.end_time,
                int(body.all_day),
                recurrence,
                body.location,
                json.dumps(body.family_member_ids) if body.family_member_ids else None,
                json.dumps(body.affected_member_ids) if body.affected_member_ids else None,
                body.assigned_to,
                body.event_type,
                body.exertion,
                legacy_source_document_id,
                family_id,
                now,
                now,
                user_id,
                client_id,
                client_timestamp,
            ),
        )
        row = await (
            await db.execute(
                "SELECT * FROM calendar_events WHERE id = ?",
                (record_id,),
            )
        ).fetchone()
        if row is None:
            raise RuntimeError("Calendar event insert did not return a row")
        await replace_event_attachments(
            db,
            event_id=record_id,
            family_id=family_id,
            user_id=user_id,
            specs=attachment_specs,
            client_id=client_id,
            client_timestamp=client_timestamp,
            validate=False,
        )
        return dict(row), False


async def _task_assignees(
    db,
    body: TaskCreate,
    *,
    family_id: str,
) -> list[AssigneeInput]:
    if body.assignees is not None:
        assignees = body.assignees
    elif body.assigned_to:
        person_type = await family_person_type(db, family_id, body.assigned_to)
        if person_type is None:
            raise ValueError("Task assignee is not in this family")
        assignees = [
            AssigneeInput(
                assignee_id=body.assigned_to,
                assignee_type=person_type,
            )
        ]
    else:
        assignees = []

    identities = [(item.assignee_type, item.assignee_id) for item in assignees]
    if len(set(identities)) != len(identities):
        raise ValueError("Duplicate task assignee")
    for assignee in assignees:
        person_type = await family_person_type(db, family_id, assignee.assignee_id)
        if person_type != assignee.assignee_type:
            raise ValueError("Task assignee is not in this family")
    return assignees


async def _stored_task_assignees(db, task_id: str, family_id: str) -> set[tuple[str, str]]:
    cursor = await db.execute(
        """
        SELECT assignee_type, assignee_id FROM task_assignments
        WHERE task_id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (task_id, family_id),
    )
    return {(row["assignee_type"], row["assignee_id"]) for row in await cursor.fetchall()}


async def create_or_replay_task(
    db,
    body: TaskCreate,
    *,
    record_id: str,
    user: dict,
    client_id: str | None,
    client_timestamp: str | None,
) -> tuple[dict, bool]:
    family_id = user["family_id"]
    user_id = user["id"]
    due = _parse_timestamp(body.due_date, "Task due date") if body.due_date else None
    actionable = (
        _parse_timestamp(body.actionable_from, "Task actionable time")
        if body.actionable_from
        else None
    )
    if due is not None and actionable is not None and actionable > due:
        raise ValueError("Task actionable time must not be after its due date")
    recurrence = _validated_recurrence(
        body.recurrence_rule,
        starts_at=due or actionable or datetime.now(timezone.utc),
    )

    async with serialized_create(db):
        existing = await existing_create_row(
            db,
            table_name="tasks",
            record_id=record_id,
            family_id=family_id,
            user_id=user_id,
        )
        assignees = await _task_assignees(db, body, family_id=family_id)
        expected_assignees = {
            (assignee.assignee_type, assignee.assignee_id) for assignee in assignees
        }
        if existing is not None:
            reject_create_mismatch(
                existing["title"] == body.title
                and existing["description"] == body.description
                and existing["assigned_to"] == body.assigned_to
                and existing["due_date"] == body.due_date
                and existing["category"] == body.category
                and existing["recurrence_rule"] == recurrence
                and existing["priority"] == body.priority
                and existing["actionable_from"] == body.actionable_from
                and existing["source_document_id"] == body.source_document_id
                and await _stored_task_assignees(db, record_id, family_id) == expected_assignees
            )
            return dict(existing), True

        if body.source_document_id is not None:
            source_document = await (
                await db.execute(
                    "SELECT 1 FROM documents WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                    (body.source_document_id, family_id),
                )
            ).fetchone()
            if source_document is None:
                raise ValueError("Attached document is not available to this family")

        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """
            INSERT INTO tasks
                (id, title, description, assigned_to, due_date, category,
                 recurrence_rule, priority, actionable_from, family_id,
                 source_document_id, created_at, updated_at, created_by,
                 client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                record_id,
                body.title,
                body.description,
                body.assigned_to,
                body.due_date,
                body.category,
                recurrence,
                body.priority,
                body.actionable_from,
                family_id,
                body.source_document_id,
                now,
                now,
                user_id,
                client_id,
                client_timestamp,
            ),
        )
        if assignees:
            await db.executemany(
                """
                INSERT INTO task_assignments
                    (id, task_id, assignee_id, assignee_type, family_id,
                     created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        str(uuid.uuid4()),
                        record_id,
                        assignee.assignee_id,
                        assignee.assignee_type,
                        family_id,
                        now,
                        now,
                        user_id,
                    )
                    for assignee in assignees
                ],
            )
        row = await (
            await db.execute(
                "SELECT * FROM tasks WHERE id = ?",
                (record_id,),
            )
        ).fetchone()
        if row is None:
            raise RuntimeError("Task insert did not return a row")
        return dict(row), False


async def create_or_replay_shopping_item(
    db,
    body: ShoppingItemCreate,
    *,
    record_id: str,
    user: dict,
) -> tuple[dict, bool]:
    family_id = user["family_id"]
    user_id = user["id"]
    async with serialized_create(db):
        existing = await existing_create_row(
            db,
            table_name="shopping_items",
            record_id=record_id,
            family_id=family_id,
            user_id=user_id,
        )
        if existing is not None:
            reject_create_mismatch(
                existing["name"] == body.name
                and existing["quantity"] == body.quantity
                and existing["category"] == body.category
                and existing["meal_plan_id"] == body.meal_plan_id
            )
            return dict(existing), True

        if body.meal_plan_id:
            cursor = await db.execute(
                "SELECT 1 FROM meal_plans WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                (body.meal_plan_id, family_id),
            )
            if await cursor.fetchone() is None:
                raise ValueError("Meal plan is not available to this family")
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """INSERT INTO shopping_items (
                   id, name, quantity, category, meal_plan_id, checked,
                   created_at, updated_at, created_by, client_id,
                   client_timestamp, family_id
               ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)""",
            (
                record_id,
                body.name,
                body.quantity,
                body.category,
                body.meal_plan_id,
                now,
                now,
                user_id,
                body.client_id,
                body.client_timestamp,
                family_id,
            ),
        )
        row = await (
            await db.execute("SELECT * FROM shopping_items WHERE id = ?", (record_id,))
        ).fetchone()
        if row is None:
            raise RuntimeError("Shopping item insert did not return a row")
        return dict(row), False


async def create_or_replay_medicine_type(
    db,
    body: MedicineTypeCreate,
    *,
    record_id: str,
    user: dict,
    client_id: str | None,
    client_timestamp: str | None,
) -> tuple[dict, bool]:
    family_id = user["family_id"]
    user_id = user["id"]
    async with serialized_create(db):
        existing = await existing_create_row(
            db,
            table_name="medicine_types",
            record_id=record_id,
            family_id=family_id,
            user_id=user_id,
        )
        if existing is not None:
            reject_create_mismatch(
                existing["name"] == body.name
                and existing["min_hours_between_doses"] == body.min_hours_between_doses
                and existing["max_doses_24h"] == body.max_doses_24h
                and existing["notes"] == body.notes
                and existing["color"] == body.color
                and existing["default_dose_amount"] == body.default_dose_amount
                and existing["child_id"] == body.child_id
            )
            return dict(existing), True

        if not await family_child_exists(db, family_id, body.child_id):
            raise ValueError("Child is not in this family")
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """
            INSERT INTO medicine_types
                (id, name, min_hours_between_doses, max_doses_24h, notes,
                 color, default_dose_amount, child_id, family_id, created_at,
                 updated_at, created_by, client_id, client_timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                record_id,
                body.name,
                body.min_hours_between_doses,
                body.max_doses_24h,
                body.notes,
                body.color,
                body.default_dose_amount,
                body.child_id,
                family_id,
                now,
                now,
                user_id,
                client_id,
                client_timestamp,
            ),
        )
        row = await (
            await db.execute(
                "SELECT * FROM medicine_types WHERE id = ?",
                (record_id,),
            )
        ).fetchone()
        if row is None:
            raise RuntimeError("Medicine type insert did not return a row")
        return dict(row), False
