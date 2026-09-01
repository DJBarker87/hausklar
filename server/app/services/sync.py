"""Sync conflict resolution engine.

Implements the "Morgan wins" strategy:
- Within a ±5-minute conflict window the user with the higher priority wins.
- Outside that window the most-recent timestamp wins regardless of user.
"""

import base64
import json
import uuid
from datetime import datetime, timedelta, timezone

from dateutil.rrule import rrulestr
from pydantic import ValidationError

from app.models.calendar import CalendarEventCreate, CalendarEventUpdate
from app.models.cycles import (
    CycleSettingsUpdate,
    FitnessPeriodStartPayload,
    PeriodStartCreate,
)
from app.models.medicine import MedicineDoseCreate, MedicineTypeCreate, SafetyWarning
from app.models.nap import NapStartRequest
from app.models.sync import SyncPushItem, SyncPushResult
from app.models.task import AssigneeInput, TaskCreate, TaskUpdate
from app.services import record_history
from app.services.create_records import (
    create_or_replay_calendar_event,
    create_or_replay_medicine_type,
    create_or_replay_task,
)
from app.services.fitness.cycles import (
    create_period_start,
    settings_from_legacy,
    soft_delete_period_start,
    upsert_cycle_settings,
)
from app.services.family_people import (
    family_child_exists,
    family_person_type,
    validate_calendar_people,
)
from app.services.idempotency import IDEMPOTENT_CREATE_TABLES
from app.services.managed_tasks import (
    MANAGED_TASK_DETAIL,
    is_completion_only_sync,
    is_scraper_managed_task,
)
from app.services.medicine import create_or_replay_medicine_dose
from app.services.task_recurrence import create_next_task_occurrence

# ---- constants ---------------------------------------------------------------

CONFLICT_WINDOW = 300  # seconds (plus or minus 5 minutes)
MAX_FUTURE_CLOCK_SKEW = timedelta(minutes=15)

SYNCABLE_TABLES: list[str] = [
    "calendar_events",
    "tasks",
    "medicine_types",
    "medicine_doses",
    "naps",
    "dog_activities",
    "birthdays",
    "meals",
    "meal_plans",
    "meal_ratings",
    "shopping_items",
    "grocery_items",
    "purchase_batches",
    "purchases",
    "consumption_events",
    "homework_reading",
    "homework_spellings",
    "growth_records",
    "children",
    "present_ideas",
    "present_idea_scores",
]

# Pull remains broad so older clients retain their complete offline cache. Push is
# deliberately limited to operations that the iOS app actually queues today.
PUSHABLE_OPERATIONS: dict[str, frozenset[str]] = {
    "calendar_events": frozenset({"create", "update", "delete"}),
    "cycle_settings": frozenset({"create", "update"}),
    "cycle_period_starts": frozenset({"create", "delete"}),
    "tasks": frozenset({"create", "update", "delete"}),
    "medicine_types": frozenset({"create"}),
    "medicine_doses": frozenset({"create"}),
    "naps": frozenset({"create", "update", "delete"}),
}
SYNC_PAYLOAD_FIELDS: dict[tuple[str, str], frozenset[str]] = {
    (
        "calendar_events",
        "create",
    ): frozenset(
        {
            "title",
            "description",
            "start_time",
            "end_time",
            "all_day",
            "recurrence_rule",
            "location",
            "family_member_ids",
            "affected_member_ids",
            "assigned_to",
            "event_type",
            "exertion",
            "source_document_id",
        }
    ),
    (
        "calendar_events",
        "update",
    ): frozenset(
        {
            "title",
            "description",
            "start_time",
            "end_time",
            "all_day",
            "recurrence_rule",
            "location",
            "family_member_ids",
            "affected_member_ids",
            "assigned_to",
            "event_type",
            "exertion",
            "source_document_id",
        }
    ),
    ("calendar_events", "delete"): frozenset(),
    (
        "cycle_settings",
        "create",
    ): frozenset(
        {
            "cycle_length_days",
            "share_with_adults",
            "show_period_starts",
            "show_predicted_period",
            "show_estimated_ovulation",
        }
    ),
    (
        "cycle_settings",
        "update",
    ): frozenset(
        {
            "cycle_length_days",
            "share_with_adults",
            "show_period_starts",
            "show_predicted_period",
            "show_estimated_ovulation",
        }
    ),
    ("cycle_period_starts", "create"): frozenset({"started_on"}),
    ("cycle_period_starts", "delete"): frozenset(),
    (
        "tasks",
        "create",
    ): frozenset(
        {
            "title",
            "description",
            "assigned_to",
            "assignees",
            "due_date",
            "category",
            "recurrence_rule",
            "priority",
            "actionable_from",
            "source_document_id",
        }
    ),
    (
        "tasks",
        "update",
    ): frozenset(
        {
            "title",
            "description",
            "assigned_to",
            "assignees",
            "due_date",
            "category",
            "recurrence_rule",
            "priority",
            "actionable_from",
            "source_document_id",
            # iOS queues task completion as a typed offline update.
            "completed_at",
        }
    ),
    ("tasks", "delete"): frozenset(),
    (
        "medicine_types",
        "create",
    ): frozenset(
        {
            "name",
            "min_hours_between_doses",
            "max_doses_24h",
            "notes",
            "color",
            "default_dose_amount",
            "child_id",
        }
    ),
    (
        "medicine_doses",
        "create",
    ): frozenset(
        {
            "medicine_type_id",
            "child_id",
            "given_at",
            "dose_amount",
            "medicine_name",
            "notes",
            # Accepted for legacy replay only; the authenticated user replaces it.
            "given_by",
        }
    ),
    (
        "naps",
        "create",
    ): frozenset({"child_id", "started_at", "location", "notes", "sleep_type"}),
    (
        "naps",
        "update",
    ): frozenset({"started_at", "ended_at", "location", "notes", "sleep_type"}),
    ("naps", "delete"): frozenset(),
}


# ---- helpers -----------------------------------------------------------------


def _parse_iso(ts: str) -> datetime:
    """Parse an ISO-8601 timestamp string into a timezone-aware datetime."""
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _validated_client_timestamp(value: str) -> datetime:
    try:
        parsed = _parse_iso(value)
    except (AttributeError, TypeError, ValueError) as exc:
        raise ValueError("Sync client timestamp is invalid") from exc
    if parsed > datetime.now(timezone.utc) + MAX_FUTURE_CLOCK_SKEW:
        raise ValueError("Sync client timestamp is too far in the future")
    return parsed


def _validated_payload(push_item: SyncPushItem) -> dict:
    payload = push_item.payload or {}
    allowed_fields = SYNC_PAYLOAD_FIELDS.get((push_item.table_name, push_item.operation))
    if allowed_fields is None:
        raise ValueError("Sync operation does not accept a payload")
    invalid_columns = set(payload) - allowed_fields
    if invalid_columns:
        raise ValueError("Sync payload contains unsupported fields")
    if push_item.operation in {"create", "update"} and not payload:
        raise ValueError("Sync payload is required for this operation")
    if push_item.operation == "delete" and payload:
        raise ValueError("Sync delete payload must be empty")
    return payload


def _validated_domain_timestamp(value: str, field_name: str) -> datetime:
    try:
        return _parse_iso(value)
    except (AttributeError, TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} is invalid") from exc


def _validated_recurrence(value: str | None, *, starts_at: datetime) -> str | None:
    if value is None:
        return None
    try:
        normalised = CalendarEventUpdate(recurrence_rule=value).recurrence_rule
        if normalised:
            rrulestr(normalised, dtstart=starts_at)
    except (TypeError, ValueError, ValidationError) as exc:
        raise ValueError("Recurrence rule is invalid") from exc
    return normalised


def _validated_calendar_model(payload: dict) -> CalendarEventCreate:
    try:
        return CalendarEventCreate.model_validate(payload)
    except ValidationError as exc:
        raise ValueError("Calendar sync payload failed validation") from exc


def _validated_task_model(
    payload: dict,
    *,
    operation: str,
) -> TaskCreate | TaskUpdate:
    candidate = {key: value for key, value in payload.items() if key != "completed_at"}
    try:
        if operation == "create":
            return TaskCreate.model_validate(candidate)
        return TaskUpdate.model_validate(candidate)
    except ValidationError as exc:
        raise ValueError("Task sync payload failed validation") from exc


def _validated_medicine_model(model_type, payload: dict, *, legacy_fields: set[str] | None = None):
    """Validate a medicine sync payload without trusting ignored extra fields."""
    model_fields = set(model_type.model_fields) - {"client_id", "client_timestamp"}
    allowed_fields = model_fields | (legacy_fields or set())
    if set(payload) - allowed_fields:
        raise ValueError("Medicine sync payload contains unsupported fields")
    candidate = {key: value for key, value in payload.items() if key in model_fields}
    try:
        return model_type.model_validate(candidate)
    except ValidationError as exc:
        raise ValueError("Medicine sync payload failed validation") from exc


def _validated_cycle_model(model_type, payload: dict):
    try:
        return model_type.model_validate(payload)
    except ValidationError as exc:
        raise ValueError("Cycle sync payload failed validation") from exc


async def _create_synced_medicine_type(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    body: MedicineTypeCreate = _validated_medicine_model(MedicineTypeCreate, payload)
    await create_or_replay_medicine_type(
        db,
        body,
        record_id=push_item.record_id,
        user=user,
        client_id=push_item.client_id,
        client_timestamp=push_item.client_timestamp,
    )
    return []


async def _create_synced_medicine_dose(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    # Older app versions queued `given_by="offline"`. Accept the field for
    # replay compatibility, but always replace it with the authenticated user.
    body: MedicineDoseCreate = _validated_medicine_model(
        MedicineDoseCreate,
        payload,
        legacy_fields={"given_by"},
    )
    _row, warnings, _replayed = await create_or_replay_medicine_dose(
        db,
        body,
        dose_id=push_item.record_id,
        user=user,
        client_id=push_item.client_id,
        client_timestamp=push_item.client_timestamp,
    )
    return warnings


async def _create_synced_nap(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    try:
        body = NapStartRequest.model_validate({"id": push_item.record_id, **payload})
    except ValidationError as exc:
        raise ValueError("Nap sync payload failed validation") from exc
    if body.started_at is None:
        raise ValueError("Nap start time is required for sync")
    _validated_domain_timestamp(body.started_at, "Nap start time")
    family_id = user["family_id"]
    if not await family_child_exists(db, family_id, body.child_id):
        raise ValueError("Child is not in this family")

    existing = await (
        await db.execute("SELECT * FROM naps WHERE id = ?", (push_item.record_id,))
    ).fetchone()
    if existing is not None:
        row = dict(existing)
        if not (
            row["family_id"] == family_id
            and row["created_by"] == user["id"]
            and row["deleted_at"] is None
            and row["child_id"] == body.child_id
            and row["started_at"] == body.started_at
            and row["location"] == body.location
            and row["notes"] == body.notes
            and row["sleep_type"] == body.sleep_type
        ):
            raise ValueError("Nap operation ID was already used for a different request")
        return []

    await db.execute(
        """
        INSERT INTO naps (
            id, child_id, started_at, ended_at, location, notes, sleep_type,
            family_id, created_at, updated_at, created_by, client_id,
            client_timestamp, deleted_at
        ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        """,
        (
            push_item.record_id,
            body.child_id,
            body.started_at,
            body.location,
            body.notes,
            body.sleep_type,
            family_id,
            now,
            now,
            user["id"],
            push_item.client_id,
            push_item.client_timestamp,
        ),
    )
    return []


async def _update_synced_nap(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    family_id = user["family_id"]
    existing_row = await (
        await db.execute(
            "SELECT * FROM naps WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (push_item.record_id, family_id),
        )
    ).fetchone()
    if existing_row is None:
        raise ValueError("Nap is no longer available")
    existing = dict(existing_row)
    updates = dict(payload)
    if "sleep_type" in updates and updates["sleep_type"] not in {"nap", "bedtime"}:
        raise ValueError("Nap sleep type is invalid")
    started_at = updates.get("started_at", existing["started_at"])
    ended_at = updates.get("ended_at", existing["ended_at"])
    start = _validated_domain_timestamp(started_at, "Nap start time")
    if ended_at is not None:
        end = _validated_domain_timestamp(ended_at, "Nap end time")
        if end < start:
            raise ValueError("Nap end time cannot precede its start time")

    await record_history.save_history(
        db,
        "naps",
        push_item.record_id,
        user["id"],
        family_id=family_id,
    )
    updates.update(
        {
            "updated_at": now,
            "client_id": push_item.client_id,
            "client_timestamp": push_item.client_timestamp,
        }
    )
    set_clause = ", ".join(f"{field} = ?" for field in updates)
    await db.execute(
        f"UPDATE naps SET {set_clause} WHERE id = ? AND family_id = ?",
        (*updates.values(), push_item.record_id, family_id),
    )
    return []


async def _create_synced_calendar_event(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    body = _validated_calendar_model(payload)
    await create_or_replay_calendar_event(
        db,
        body,
        record_id=push_item.record_id,
        user=user,
        client_id=push_item.client_id,
        client_timestamp=push_item.client_timestamp,
    )
    return []


async def _upsert_synced_cycle_settings(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    body: CycleSettingsUpdate = _validated_cycle_model(CycleSettingsUpdate, payload)
    await upsert_cycle_settings(
        db,
        body=settings_from_legacy(body),
        user=user,
        settings_id=push_item.record_id,
        client_id=push_item.client_id,
        client_timestamp=push_item.client_timestamp,
        now=now,
        adopt_existing_identity=True,
    )
    return []


async def _create_synced_period_start(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    body: PeriodStartCreate = _validated_cycle_model(PeriodStartCreate, payload)
    await create_period_start(
        db,
        body=FitnessPeriodStartPayload(id=body.id, started_on=body.started_on),
        user=user,
        period_id=push_item.record_id,
        client_id=push_item.client_id,
        client_timestamp=push_item.client_timestamp,
        now=now,
    )
    return []


async def _update_synced_calendar_event(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    """Apply a sparse, validated offline edit to an editable calendar row."""
    try:
        body = CalendarEventUpdate.model_validate(payload)
    except ValidationError as exc:
        raise ValueError("Calendar sync payload failed validation") from exc

    family_id = user["family_id"]
    existing_row = await (
        await db.execute(
            """
            SELECT * FROM calendar_events
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (push_item.record_id, family_id),
        )
    ).fetchone()
    if existing_row is None:
        raise ValueError("Sync record is no longer available")
    existing = dict(existing_row)
    if existing["read_only"]:
        raise ValueError("Calendar event is read-only")

    updates = body.model_dump(
        exclude_unset=True,
        exclude={"client_id", "client_timestamp"},
    )
    if "title" in updates and updates["title"] is None:
        raise ValueError("Calendar title cannot be empty")
    if "start_time" in updates and updates["start_time"] is None:
        raise ValueError("Calendar start time is required")
    if "all_day" in updates and updates["all_day"] is None:
        raise ValueError("Calendar all-day flag is required")

    start_value = updates.get("start_time", existing["start_time"])
    end_value = updates.get("end_time", existing["end_time"])
    start = _validated_domain_timestamp(start_value, "Calendar start time")
    if end_value is not None:
        end = _validated_domain_timestamp(end_value, "Calendar end time")
        if end <= start:
            raise ValueError("Calendar end time must be after start time")

    people_fields = {"family_member_ids", "affected_member_ids", "assigned_to"}
    if people_fields & updates.keys():
        raw_members = updates.get("family_member_ids", existing["family_member_ids"])
        if isinstance(raw_members, str):
            raw_members = json.loads(raw_members)
        participants = list(raw_members or [])
        assigned_to = updates.get("assigned_to", existing["assigned_to"])
        if assigned_to and assigned_to not in participants:
            participants.append(assigned_to)
        raw_affected = updates.get(
            "affected_member_ids",
            existing["affected_member_ids"],
        )
        if isinstance(raw_affected, str):
            raw_affected = json.loads(raw_affected)
        try:
            await validate_calendar_people(
                db,
                family_id,
                participants,
                list(raw_affected or []),
                whole_family=not raw_members and not assigned_to,
            )
        except ValueError as exc:
            raise ValueError(str(exc)) from exc

    if "source_document_id" in updates and updates["source_document_id"] is not None:
        source_document = await (
            await db.execute(
                "SELECT 1 FROM documents WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                (updates["source_document_id"], family_id),
            )
        ).fetchone()
        if source_document is None:
            raise ValueError("Attached document is not available to this family")

    await record_history.save_history(
        db,
        "calendar_events",
        push_item.record_id,
        user["id"],
        family_id=family_id,
    )
    stored_updates: dict = {}
    for field, value in updates.items():
        if field == "all_day" and value is not None:
            stored_updates[field] = int(value)
        elif field in {"family_member_ids", "affected_member_ids"}:
            stored_updates[field] = json.dumps(value) if value else None
        else:
            stored_updates[field] = value
    stored_updates.update(
        {
            "updated_at": now,
            "client_id": push_item.client_id,
            "client_timestamp": push_item.client_timestamp,
        }
    )
    set_clause = ", ".join(f"{column} = ?" for column in stored_updates)
    cursor = await db.execute(
        f"UPDATE calendar_events SET {set_clause} WHERE id = ? AND family_id = ?",
        (*stored_updates.values(), push_item.record_id, family_id),
    )
    if cursor.rowcount != 1:
        raise ValueError("Sync record is no longer available")
    return []


async def _validate_task_assignees(
    db,
    family_id: str,
    assignees: list[AssigneeInput],
) -> None:
    identities = [(item.assignee_type, item.assignee_id) for item in assignees]
    if len(set(identities)) != len(identities):
        raise ValueError("Duplicate task assignee")
    for assignee in assignees:
        person_type = await family_person_type(db, family_id, assignee.assignee_id)
        if person_type != assignee.assignee_type:
            raise ValueError("Task assignee is not in this family")


async def _legacy_task_assignee(
    db,
    family_id: str,
    assignee_id: str,
) -> AssigneeInput:
    person_type = await family_person_type(db, family_id, assignee_id)
    if person_type is None:
        raise ValueError("Task assignee is not in this family")
    return AssigneeInput(assignee_id=assignee_id, assignee_type=person_type)


async def _replace_task_assignments(
    db,
    *,
    task_id: str,
    assignees: list[AssigneeInput],
    user_id: str,
    family_id: str,
    now: str,
) -> None:
    await db.execute(
        """
        UPDATE task_assignments
        SET deleted_at = ?, updated_at = ?
        WHERE task_id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (now, now, task_id, family_id),
    )
    if not assignees:
        return
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
                task_id,
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


def _validated_task_timing(
    *,
    due_date: str | None,
    actionable_from: str | None,
    recurrence_rule: str | None,
) -> str | None:
    due = _validated_domain_timestamp(due_date, "Task due date") if due_date is not None else None
    actionable = (
        _validated_domain_timestamp(actionable_from, "Task actionable time")
        if actionable_from is not None
        else None
    )
    if due is not None and actionable is not None and actionable > due:
        raise ValueError("Task actionable time must not be after its due date")
    recurrence_start = due or actionable or datetime.now(timezone.utc)
    return _validated_recurrence(recurrence_rule, starts_at=recurrence_start)


async def _create_synced_task(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    body = _validated_task_model(payload, operation="create")
    assert isinstance(body, TaskCreate)
    await create_or_replay_task(
        db,
        body,
        record_id=push_item.record_id,
        user=user,
        client_id=push_item.client_id,
        client_timestamp=push_item.client_timestamp,
    )
    return []


async def _update_synced_task(
    db,
    push_item: SyncPushItem,
    user: dict,
    payload: dict,
    now: str,
) -> list[SafetyWarning]:
    body = _validated_task_model(payload, operation="update")
    assert isinstance(body, TaskUpdate)
    family_id = user["family_id"]
    cursor = await db.execute(
        """
        SELECT * FROM tasks
        WHERE id = ? AND family_id = ? AND deleted_at IS NULL
        """,
        (push_item.record_id, family_id),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise ValueError("Sync record is no longer available")
    if is_scraper_managed_task(existing) and not is_completion_only_sync(payload):
        raise ValueError(MANAGED_TASK_DETAIL)

    updates = body.model_dump(
        exclude_unset=True,
        exclude={"assignees", "client_id", "client_timestamp"},
    )
    due_date = updates.get("due_date", existing["due_date"])
    actionable_from = updates.get("actionable_from", existing["actionable_from"])
    recurrence_rule = updates.get("recurrence_rule", existing["recurrence_rule"])
    normalised_recurrence = _validated_task_timing(
        due_date=due_date,
        actionable_from=actionable_from,
        recurrence_rule=recurrence_rule,
    )
    if "recurrence_rule" in updates:
        updates["recurrence_rule"] = normalised_recurrence

    if "assigned_to" in updates and updates["assigned_to"] is not None:
        await _legacy_task_assignee(db, family_id, updates["assigned_to"])

    if "source_document_id" in updates and updates["source_document_id"] is not None:
        source_document = await (
            await db.execute(
                "SELECT 1 FROM documents WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                (updates["source_document_id"], family_id),
            )
        ).fetchone()
        if source_document is None:
            raise ValueError("Attached document is not available to this family")

    assignees = body.assignees if "assignees" in payload else None
    if assignees is not None:
        await _validate_task_assignees(db, family_id, assignees)

    completed_at = None
    if "completed_at" in payload:
        value = payload["completed_at"]
        if not isinstance(value, str):
            raise ValueError("Task completion time is invalid")
        completed = _validated_domain_timestamp(value, "Task completion time")
        if completed > datetime.now(timezone.utc) + MAX_FUTURE_CLOCK_SKEW:
            raise ValueError("Task completion time is too far in the future")
        completed_at = value
        updates["completed_at"] = value

    if completed_at is not None and existing["completed_at"] is not None:
        if set(payload) == {"completed_at"}:
            return []

    await record_history.save_history(
        db,
        "tasks",
        push_item.record_id,
        user["id"],
        family_id=family_id,
    )
    updates.update(
        {
            "updated_at": now,
            "client_id": push_item.client_id,
            "client_timestamp": push_item.client_timestamp,
        }
    )
    set_clause = ", ".join(f"{column} = ?" for column in updates)
    values = [*updates.values(), push_item.record_id, family_id]
    cursor = await db.execute(
        f"UPDATE tasks SET {set_clause} WHERE id = ? AND family_id = ?",
        values,
    )
    if cursor.rowcount != 1:
        raise ValueError("Sync record is no longer available")

    if assignees is not None:
        await _replace_task_assignments(
            db,
            task_id=push_item.record_id,
            assignees=assignees,
            user_id=user["id"],
            family_id=family_id,
            now=now,
        )
    if completed_at is not None:
        cursor = await db.execute(
            """
            SELECT id FROM task_assignments
            WHERE task_id = ? AND family_id = ?
              AND deleted_at IS NULL AND completed_at IS NULL
            """,
            (push_item.record_id, family_id),
        )
        for assignment in await cursor.fetchall():
            await record_history.save_history(
                db,
                "task_assignments",
                assignment["id"],
                user["id"],
                family_id=family_id,
            )
        await db.execute(
            """
            UPDATE task_assignments
            SET completed_at = ?, completed_by = ?, updated_at = ?
            WHERE task_id = ? AND family_id = ?
              AND deleted_at IS NULL AND completed_at IS NULL
            """,
            (completed_at, user["id"], now, push_item.record_id, family_id),
        )
        if existing["completed_at"] is None and not is_scraper_managed_task(existing):
            completed_task = await (
                await db.execute(
                    "SELECT * FROM tasks WHERE id = ? AND family_id = ?",
                    (push_item.record_id, family_id),
                )
            ).fetchone()
            await create_next_task_occurrence(
                db,
                completed_task,
                completed_at=completed_at,
                created_by=user["id"],
            )
    return []


async def _delete_synced_record(
    db,
    push_item: SyncPushItem,
    user: dict,
    now: str,
) -> list[SafetyWarning]:
    family_id = user["family_id"]
    if push_item.table_name == "cycle_period_starts":
        await soft_delete_period_start(
            db,
            period_id=push_item.record_id,
            user=user,
            now=now,
            client_id=push_item.client_id,
            client_timestamp=push_item.client_timestamp,
        )
        return []
    if push_item.table_name == "calendar_events":
        cursor = await db.execute(
            "SELECT read_only FROM calendar_events WHERE id = ? AND family_id = ?",
            (push_item.record_id, family_id),
        )
        calendar_event = await cursor.fetchone()
        if calendar_event is not None and calendar_event["read_only"]:
            raise ValueError("Calendar event is read-only")
    elif push_item.table_name == "tasks":
        cursor = await db.execute(
            "SELECT * FROM tasks WHERE id = ? AND family_id = ?",
            (push_item.record_id, family_id),
        )
        task = await cursor.fetchone()
        if task is not None and is_scraper_managed_task(task):
            raise ValueError(MANAGED_TASK_DETAIL)
    await record_history.save_history(
        db,
        push_item.table_name,
        push_item.record_id,
        user["id"],
        family_id=family_id,
    )
    cursor = await db.execute(
        f"""
        UPDATE {push_item.table_name}
        SET deleted_at = ?, updated_at = ?
        WHERE id = ? AND family_id = ?
        """,
        (now, now, push_item.record_id, family_id),
    )
    if cursor.rowcount != 1:
        raise ValueError("Sync record is no longer available")
    if push_item.table_name == "tasks":
        await db.execute(
            """
            UPDATE task_assignments
            SET deleted_at = ?, updated_at = ?
            WHERE task_id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (now, now, push_item.record_id, family_id),
        )
    return []


# ---- conflict resolution ----------------------------------------------------


async def resolve_conflict(
    db,
    push_item: SyncPushItem,
    user: dict,
) -> SyncPushResult:
    """Decide whether to accept or reject an incoming push item.

    Returns a SyncPushResult with status "accepted" or "conflict".
    """
    allowed_operations = PUSHABLE_OPERATIONS.get(push_item.table_name)
    if allowed_operations is None:
        return SyncPushResult(
            record_id=push_item.record_id,
            status="error",
            detail=f"Table '{push_item.table_name}' is not syncable",
        )
    if push_item.operation not in allowed_operations:
        return SyncPushResult(
            record_id=push_item.record_id,
            status="error",
            detail=f"Operation '{push_item.operation}' is not syncable for table '{push_item.table_name}'",
        )

    family_id = user.get("family_id")
    if not family_id:
        return SyncPushResult(
            record_id=push_item.record_id,
            status="error",
            detail="A family is required for sync",
        )
    client_timestamp = _validated_client_timestamp(push_item.client_timestamp)

    # Already-queued legacy cycle writes resolve against the canonical Fitness
    # tables. No new code writes the deprecated cycle_* storage.
    storage_table = {
        "cycle_settings": "health_cycle_settings",
        "cycle_period_starts": "health_cycle_period_starts",
    }.get(push_item.table_name, push_item.table_name)

    # Fetch only records owned by this family. Never disclose another tenant's row.
    cursor = await db.execute(
        f"SELECT * FROM {storage_table} WHERE id = ? AND family_id = ?",
        (push_item.record_id, family_id),
    )
    existing = await cursor.fetchone()
    if existing is None and push_item.table_name == "cycle_settings":
        existing = await (
            await db.execute(
                """
                SELECT * FROM health_cycle_settings
                WHERE owner_user_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (user["id"], family_id),
            )
        ).fetchone()

    if (
        existing is not None
        and push_item.table_name in {"cycle_settings", "cycle_period_starts"}
        and existing["owner_user_id"] != user["id"]
    ):
        return SyncPushResult(
            record_id=push_item.record_id,
            status="error",
            detail="Cycle record is not available",
        )

    # ------------------------------------------------------------------
    # No existing record — no conflict possible.
    # ------------------------------------------------------------------
    if existing is None:
        if push_item.operation != "create":
            return SyncPushResult(
                record_id=push_item.record_id,
                status="error",
                detail="Record not found",
            )
        return SyncPushResult(
            record_id=push_item.record_id,
            status="accepted",
        )

    if push_item.operation == "create" and push_item.table_name in IDEMPOTENT_CREATE_TABLES:
        # The service performs an exact payload check. A matching existing dose
        # is an acknowledged replay, not a conflict that the offline client
        # should retry forever.
        return SyncPushResult(
            record_id=push_item.record_id,
            status="accepted",
        )
    if push_item.operation == "create":
        return SyncPushResult(
            record_id=push_item.record_id,
            status="conflict",
            detail="Record already exists",
            server_version=dict(existing),
        )
    if push_item.operation == "delete" and existing["deleted_at"] is not None:
        return SyncPushResult(
            record_id=push_item.record_id,
            status="accepted",
        )
    if existing["deleted_at"] is not None and push_item.operation == "update":
        return SyncPushResult(
            record_id=push_item.record_id,
            status="error",
            detail="Record not found",
        )
    if push_item.table_name == "tasks" and is_scraper_managed_task(existing):
        if push_item.operation == "delete" or not is_completion_only_sync(push_item.payload or {}):
            return SyncPushResult(
                record_id=push_item.record_id,
                status="error",
                detail=MANAGED_TASK_DETAIL,
            )
        return SyncPushResult(
            record_id=push_item.record_id,
            status="accepted",
        )

    # ------------------------------------------------------------------
    # Record exists — compare timestamps.
    # ------------------------------------------------------------------
    server_updated_at = _parse_iso(existing["updated_at"])

    diff_seconds = abs((client_timestamp - server_updated_at).total_seconds())

    if diff_seconds <= CONFLICT_WINDOW:
        # Within the conflict window — priority decides.
        pushing_priority: int = user.get("priority", 0)

        # Look up the priority of the user who last touched the server record.
        existing_created_by = existing["created_by"]
        existing_priority: int = 0
        if existing_created_by:
            cur = await db.execute(
                "SELECT priority FROM users WHERE id = ? AND family_id = ?",
                (existing_created_by, family_id),
            )
            creator_row = await cur.fetchone()
            if creator_row:
                existing_priority = creator_row["priority"]

        if pushing_priority >= existing_priority:
            return SyncPushResult(
                record_id=push_item.record_id,
                status="accepted",
            )
        else:
            return SyncPushResult(
                record_id=push_item.record_id,
                status="conflict",
                detail="Server record has higher priority",
                server_version=dict(existing),
            )
    else:
        # Outside the conflict window — most-recent timestamp wins.
        if client_timestamp > server_updated_at:
            return SyncPushResult(
                record_id=push_item.record_id,
                status="accepted",
            )
        else:
            return SyncPushResult(
                record_id=push_item.record_id,
                status="conflict",
                detail="Server record is more recent",
                server_version=dict(existing),
            )


# ---- apply push --------------------------------------------------------------


async def apply_push(db, push_item: SyncPushItem, user: dict) -> list[SafetyWarning]:
    """Execute the actual create / update / delete against the database."""
    now = _now_iso()
    family_id = user.get("family_id")
    if not family_id:
        raise ValueError("A family is required for sync")
    allowed_operations = PUSHABLE_OPERATIONS.get(push_item.table_name)
    if allowed_operations is None or push_item.operation not in allowed_operations:
        raise ValueError("Sync operation is not supported")
    _validated_client_timestamp(push_item.client_timestamp)
    payload = _validated_payload(push_item)

    if push_item.operation == "delete":
        return await _delete_synced_record(db, push_item, user, now)

    if push_item.table_name == "cycle_settings":
        return await _upsert_synced_cycle_settings(
            db,
            push_item,
            user,
            payload,
            now,
        )

    if push_item.table_name == "cycle_period_starts":
        return await _create_synced_period_start(
            db,
            push_item,
            user,
            payload,
            now,
        )

    if push_item.table_name == "medicine_types":
        return await _create_synced_medicine_type(db, push_item, user, payload, now)

    if push_item.table_name == "medicine_doses":
        return await _create_synced_medicine_dose(db, push_item, user, payload, now)

    if push_item.table_name == "naps":
        if push_item.operation == "create":
            return await _create_synced_nap(db, push_item, user, payload, now)
        return await _update_synced_nap(db, push_item, user, payload, now)

    if push_item.table_name == "calendar_events":
        if push_item.operation == "update":
            return await _update_synced_calendar_event(
                db,
                push_item,
                user,
                payload,
                now,
            )
        return await _create_synced_calendar_event(
            db,
            push_item,
            user,
            payload,
            now,
        )

    if push_item.table_name == "tasks":
        if push_item.operation == "create":
            return await _create_synced_task(db, push_item, user, payload, now)
        return await _update_synced_task(db, push_item, user, payload, now)

    raise ValueError("Sync operation is not supported")


# ---- pull changes ------------------------------------------------------------


def _sync_snapshot_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


def _encode_pull_cursor(
    *,
    since: str,
    snapshot: str,
    updated_at: str,
    table_name: str,
    record_id: str,
) -> str:
    raw = json.dumps(
        {
            "v": 1,
            "since": since,
            "snapshot": snapshot,
            "updated_at": updated_at,
            "table_name": table_name,
            "record_id": record_id,
        },
        separators=(",", ":"),
    ).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _decode_pull_cursor(value: str, *, since: str) -> dict[str, str]:
    try:
        padding = "=" * (-len(value) % 4)
        payload = json.loads(base64.urlsafe_b64decode(value + padding))
        required = {"snapshot", "updated_at", "table_name", "record_id"}
        if payload.get("v") != 1 or payload.get("since") != since:
            raise ValueError
        if not required.issubset(payload) or not all(
            isinstance(payload[key], str) for key in required
        ):
            raise ValueError
        if payload["table_name"] not in SYNCABLE_TABLES:
            raise ValueError
        return payload
    except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValueError("Sync cursor is invalid or no longer matches this pull") from exc


async def _hydrate_sync_rows(
    db,
    *,
    keys: list[tuple[str, str, str]],
    family_id: str | None,
) -> list[dict]:
    grouped: dict[str, list[str]] = {}
    for table_name, record_id, _updated_at in keys:
        grouped.setdefault(table_name, []).append(record_id)

    rows_by_key: dict[tuple[str, str], dict] = {}
    # Stay below SQLite's conservative host-parameter limit even for a legacy,
    # unpaginated first pull.
    for table_name, record_ids in grouped.items():
        for start in range(0, len(record_ids), 400):
            chunk = record_ids[start : start + 400]
            placeholders = ",".join("?" for _ in chunk)
            family_clause = " AND family_id = ?" if family_id else ""
            params: tuple = (*chunk, family_id) if family_id else tuple(chunk)
            rows = await (
                await db.execute(
                    f"SELECT * FROM {table_name} WHERE id IN ({placeholders})"
                    f"{family_clause}",
                    params,
                )
            ).fetchall()
            for row in rows:
                rows_by_key[(table_name, str(row["id"]))] = dict(row)

    changes: list[dict] = []
    for table_name, record_id, updated_at in keys:
        row = rows_by_key.get((table_name, record_id))
        # HausKlar uses soft deletion, but fail closed if a legacy row vanished.
        if row is None:
            continue
        changes.append(
            {
                "table_name": table_name,
                "record_id": record_id,
                "operation": "delete" if row.get("deleted_at") is not None else "update",
                "data": row,
                "updated_at": updated_at,
            }
        )
    return changes


async def get_changes_page(
    db,
    since: str,
    *,
    family_id: str | None = None,
    cursor: str | None = None,
    limit: int | None = None,
) -> dict:
    """Return one stable, ordered page across every syncable table.

    Legacy callers may omit ``limit`` and retain the original unbounded contract.
    New clients use an opaque cursor so initial syncs are bounded and writes that
    land during a pull remain for the following snapshot.
    """
    position: dict[str, str] | None = None
    if cursor:
        position = _decode_pull_cursor(cursor, since=since)
        snapshot = position["snapshot"]
    else:
        snapshot = _sync_snapshot_timestamp()

    branches: list[str] = []
    params: list[str] = []
    for table_name in SYNCABLE_TABLES:
        family_clause = " AND family_id = ?" if family_id else ""
        branches.append(
            f"SELECT '{table_name}' AS table_name, id AS record_id, updated_at "
            f"FROM {table_name} WHERE updated_at > ? AND updated_at <= ?"
            f"{family_clause}"
        )
        params.extend((since, snapshot))
        if family_id:
            params.append(family_id)

    sql = "SELECT table_name, record_id, updated_at FROM (" + " UNION ALL ".join(branches) + ")"
    if position:
        sql += (
            " WHERE (updated_at > ? OR (updated_at = ? AND table_name > ?) "
            "OR (updated_at = ? AND table_name = ? AND record_id > ?))"
        )
        params.extend(
            (
                position["updated_at"],
                position["updated_at"],
                position["table_name"],
                position["updated_at"],
                position["table_name"],
                position["record_id"],
            )
        )
    sql += " ORDER BY updated_at, table_name, record_id"
    if limit is not None:
        sql += " LIMIT ?"
        params.append(str(limit + 1))

    started_transaction = not db.in_transaction
    if started_transaction:
        await db.execute("BEGIN")
    try:
        rows = await (await db.execute(sql, tuple(params))).fetchall()
        has_more = limit is not None and len(rows) > limit
        page_rows = rows[:limit] if limit is not None else rows
        keys = [
            (str(row["table_name"]), str(row["record_id"]), str(row["updated_at"]))
            for row in page_rows
        ]
        records = await _hydrate_sync_rows(
            db, keys=keys, family_id=family_id
        )
    finally:
        if started_transaction:
            await db.rollback()

    next_cursor = None
    if has_more and keys:
        table_name, record_id, updated_at = keys[-1]
        next_cursor = _encode_pull_cursor(
            since=since,
            snapshot=snapshot,
            updated_at=updated_at,
            table_name=table_name,
            record_id=record_id,
        )
    return {
        "records": records,
        "server_timestamp": snapshot,
        "next_cursor": next_cursor,
        "has_more": bool(next_cursor),
    }


async def get_changes_since(db, since: str, family_id: str | None = None) -> list[dict]:
    """Compatibility wrapper for the original unpaginated pull service."""
    page = await get_changes_page(db, since, family_id=family_id)
    return page["records"]
