"""Review-first service for incoming family commitments and their hand-offs."""

from __future__ import annotations

import hashlib
import json
import math
import re
import uuid
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.commitment import (
    ChildcareGapResponse,
    CommitmentActionCompleteRequest,
    CommitmentConfirmRequest,
    CommitmentCreate,
    CommitmentDeclineRequest,
    CommitmentEventDraft,
    CommitmentExternalAction,
    CommitmentFromSourceRequest,
    CommitmentFromSourceResponse,
    CommitmentKind,
    CommitmentPlan,
    CommitmentPreparationDraft,
    CommitmentResponse,
    CommitmentResultResponse,
    CommitmentSourceInput,
    CommitmentStatus,
    CommitmentTaskDraft,
    CommitmentUpdate,
    FreeWindowQuery,
    FreeWindowQueryResponse,
    FreeWindowResponse,
    ViableOutingResponse,
    _validate_kind_plan,
    commitment_review_issues,
    validate_safe_https_url,
)
from app.models.document import CaptureSuggestionCreate
from app.services.ai_consent import require_ai_consent
from app.services.capture import fallback_capture_suggestions, reference_in_timezone
from app.services.calendar_recurrence import CalendarRecurrenceError, expand_calendar_rows
from app.services.family_people import family_child_exists, family_person_type
from app.services.hermes import extract_capture_suggestions
from app.services.record_history import save_history


class CommitmentNotFoundError(ValueError):
    pass


class CommitmentConflictError(ValueError):
    pass


class CommitmentValidationError(ValueError):
    pass


_EDITABLE_STATUSES = {
    CommitmentStatus.draft.value,
    CommitmentStatus.action_required.value,
    CommitmentStatus.ready.value,
}
_PUBLIC_LINK_PATTERN = re.compile(r"https://[^\s<>\]\[\"']+", re.IGNORECASE)
_EMAIL_PATTERN = re.compile(r"(?<![\w.+-])[^\s@]+@[^\s@]+\.[^\s@]+")
_PHONE_PATTERN = re.compile(r"(?<!\d)(?:\+44|0)[0-9 ()-]{8,18}(?!\d)")
_MAX_RANGE_NONRECURRING_ROWS = 10_000
_MAX_RANGE_RECURRING_ROWS = 2_000
_MAX_OCCURRENCES_PER_SERIES = 5_000


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json(value) -> str:
    if hasattr(value, "model_dump"):
        value = value.model_dump(mode="json")
    elif isinstance(value, (list, tuple)):
        value = [
            item.model_dump(mode="json") if hasattr(item, "model_dump") else item for item in value
        ]
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _stable_uuid4(value: str) -> uuid.UUID:
    """Derive replay-stable bytes while retaining the project's UUID-v4 shape."""
    raw = bytearray(hashlib.sha256(value.encode("utf-8")).digest()[:16])
    raw[6] = (raw[6] & 0x0F) | 0x40
    raw[8] = (raw[8] & 0x3F) | 0x80
    return uuid.UUID(bytes=bytes(raw))


def _scope_sql(alias: str = "family_commitments") -> str:
    return (
        f"{alias}.family_id = ? AND {alias}.deleted_at IS NULL AND "
        f"({alias}.visibility = 'family' OR {alias}.owner_user_id = ?)"
    )


async def _visible_commitment(db, user: dict, commitment_id: str):
    row = await (
        await db.execute(
            f"SELECT * FROM family_commitments WHERE id = ? AND {_scope_sql()}",
            (commitment_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise CommitmentNotFoundError("Commitment not found")
    return row


async def _source_models(db, *, commitment_id: str, family_id: str) -> list[CommitmentSourceInput]:
    rows = await (
        await db.execute(
            """SELECT id, kind, document_id, label, provider_reference, source_url, observed_at
               FROM family_commitment_sources
               WHERE commitment_id = ? AND family_id = ? AND deleted_at IS NULL
               ORDER BY created_at, id""",
            (commitment_id, family_id),
        )
    ).fetchall()
    return [CommitmentSourceInput.model_validate(dict(row)) for row in rows]


async def _result_models(
    db, *, commitment_id: str, family_id: str
) -> list[CommitmentResultResponse]:
    rows = await (
        await db.execute(
            """SELECT source_item_id, result_type, result_id
               FROM family_commitment_results
               WHERE commitment_id = ? AND family_id = ? AND deleted_at IS NULL
               ORDER BY created_at, id""",
            (commitment_id, family_id),
        )
    ).fetchall()
    return [CommitmentResultResponse.model_validate(dict(row)) for row in rows]


async def commitment_response(db, row) -> CommitmentResponse:
    item = dict(row)
    changes = json.loads(item["change_summary_json"] or "[]")
    plan = CommitmentPlan.model_validate_json(item["plan_json"])
    review_issues = commitment_review_issues(CommitmentKind(item["kind"]), plan)
    if CommitmentKind(item["kind"]) == CommitmentKind.childcare and plan.events:
        selected_people = {person_id for event in plan.events for person_id in event.person_ids}
        has_child = False
        for person_id in selected_people:
            if await family_person_type(db, item["family_id"], person_id) == "child":
                has_child = True
                break
        if not has_child:
            review_issues.append("Choose the child who needs coverage")
    if item["visibility"] == "owner" and item["status"] != "confirmed":
        review_issues.append("Share this plan with the family before adding calendar or task items")
    return CommitmentResponse(
        id=item["id"],
        kind=item["kind"],
        visibility=item["visibility"],
        owner_user_id=item["owner_user_id"],
        title=item["title"],
        summary=item["summary"],
        status=item["status"],
        revision=item["revision"],
        sources=await _source_models(db, commitment_id=item["id"], family_id=item["family_id"]),
        plan=plan,
        review_issues=review_issues,
        external_action_status=item["external_action_status"],
        external_action_outcome=item["external_action_outcome"],
        external_action_completed_at=item["external_action_completed_at"],
        group_key=item["group_key"],
        interpretation_processor=item["interpretation_processor"],
        supersedes_id=item["supersedes_id"],
        change_summary=changes if isinstance(changes, list) else [],
        confirmed_at=item["confirmed_at"],
        declined_at=item["declined_at"],
        results=await _result_models(db, commitment_id=item["id"], family_id=item["family_id"]),
        created_at=item["created_at"],
        updated_at=item["updated_at"],
        created_by=item["created_by"],
        client_id=item["client_id"],
        client_timestamp=item["client_timestamp"],
    )


async def list_commitments(
    db,
    *,
    user: dict,
    status: str | None,
    kind: str | None,
    open_only: bool,
    offset: int,
    limit: int,
) -> list[CommitmentResponse]:
    query = f"SELECT * FROM family_commitments WHERE {_scope_sql()}"
    params: list = [user["family_id"], user["id"]]
    if status:
        query += " AND status = ?"
        params.append(status)
    if open_only:
        query += " AND status IN ('draft', 'action_required', 'ready')"
    if kind:
        query += " AND kind = ?"
        params.append(kind)
    query += " ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?"
    params.extend((limit, offset))
    rows = await (await db.execute(query, params)).fetchall()
    return [await commitment_response(db, row) for row in rows]


async def get_commitment(db, *, user: dict, commitment_id: str) -> CommitmentResponse:
    return await commitment_response(db, await _visible_commitment(db, user, commitment_id))


async def _validate_document_ids(
    db,
    *,
    family_id: str,
    sources: list[CommitmentSourceInput],
    plan: CommitmentPlan,
) -> None:
    document_ids = {source.document_id for source in sources if source.document_id is not None}
    for event in plan.events:
        document_ids.update(event.document_ids)
    document_ids.update(task.document_id for task in plan.tasks if task.document_id)
    if not document_ids:
        return
    placeholders = ",".join("?" for _ in document_ids)
    rows = await (
        await db.execute(
            f"SELECT id FROM documents WHERE id IN ({placeholders}) "
            "AND family_id = ? AND deleted_at IS NULL",
            [*document_ids, family_id],
        )
    ).fetchall()
    if {row["id"] for row in rows} != document_ids:
        raise CommitmentValidationError("A source document is not available to this family")


async def _validate_people(
    db,
    *,
    family_id: str,
    kind: CommitmentKind,
    plan: CommitmentPlan,
    require_complete: bool,
) -> None:
    people: set[str] = set()
    affected_adults: set[str] = set()
    assignees: set[str] = set()
    for event in plan.events:
        people.update(event.person_ids)
        affected_adults.update(event.affected_adult_ids)
        if event.assigned_to:
            assignees.add(event.assigned_to)
    assignees.update(task.assigned_to for task in plan.tasks if task.assigned_to)
    assignees.update(prep.assigned_to for prep in plan.preparations if prep.assigned_to)
    for person_id in people | assignees:
        if await family_person_type(db, family_id, person_id) is None:
            raise CommitmentValidationError("A selected person is not in this family")
    for person_id in affected_adults:
        if await family_person_type(db, family_id, person_id) != "user":
            raise CommitmentValidationError(
                "Only a family adult can have their availability affected"
            )
    if require_complete and kind == CommitmentKind.childcare:
        child_ids = {
            person_id
            for person_id in people
            if await family_person_type(db, family_id, person_id) == "child"
        }
        if not child_ids:
            raise CommitmentValidationError("A childcare plan must name a family child")


async def _validate_plan(
    db,
    *,
    family_id: str,
    kind: CommitmentKind,
    sources: list[CommitmentSourceInput],
    plan: CommitmentPlan,
    require_complete: bool = False,
) -> None:
    if require_complete:
        try:
            _validate_kind_plan(kind, plan)
        except ValueError as exc:
            raise CommitmentValidationError(str(exc)) from exc
    await _validate_document_ids(db, family_id=family_id, sources=sources, plan=plan)
    await _validate_people(
        db,
        family_id=family_id,
        kind=kind,
        plan=plan,
        require_complete=require_complete,
    )


def _initial_state(plan: CommitmentPlan) -> tuple[str, str]:
    action = plan.external_action
    if action:
        return (
            CommitmentStatus.action_required.value
            if action.requires_completion_before_confirm
            else CommitmentStatus.draft.value,
            "pending",
        )
    return CommitmentStatus.draft.value, "not_required"


async def _insert_sources(
    db,
    *,
    commitment_id: str,
    family_id: str,
    user_id: str,
    sources: list[CommitmentSourceInput],
    now: str,
    client_id: str | None,
    client_timestamp: str | None,
) -> None:
    for source in sources:
        try:
            await db.execute(
                """INSERT INTO family_commitment_sources
                   (id, commitment_id, kind, document_id, label, provider_reference,
                    source_url, observed_at, family_id, created_at, updated_at,
                    created_by, client_id, client_timestamp)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    str(source.id),
                    commitment_id,
                    source.kind,
                    source.document_id,
                    source.label,
                    source.provider_reference,
                    source.source_url,
                    source.observed_at,
                    family_id,
                    now,
                    now,
                    user_id,
                    client_id,
                    client_timestamp,
                ),
            )
        except Exception as exc:
            if "UNIQUE constraint failed" in str(exc):
                raise CommitmentConflictError(
                    "Source ID was already used for another commitment"
                ) from exc
            raise


async def _same_create(
    db,
    row,
    *,
    user: dict,
    body: CommitmentCreate,
    dedupe_key: str | None,
    processor: str,
    supersedes_id: str | None,
    changes: list[str] | None,
) -> bool:
    if (
        row["family_id"] != user["family_id"]
        or row["created_by"] != user["id"]
        or row["deleted_at"] is not None
    ):
        return False
    stored_sources = await _source_models(db, commitment_id=row["id"], family_id=row["family_id"])
    status, external_status = _initial_state(body.plan)
    return (
        row["kind"] == body.kind.value
        and row["visibility"] == body.visibility.value
        and row["title"] == body.title
        and row["summary"] == body.summary
        and row["status"] == status
        and row["external_action_status"] == external_status
        and row["plan_json"] == _json(body.plan)
        and row["group_key"] == body.group_key
        and row["dedupe_key"] == dedupe_key
        and row["interpretation_processor"] == processor
        and row["supersedes_id"] == supersedes_id
        and row["change_summary_json"] == _json(changes or [])
        and _json(stored_sources) == _json(body.sources)
    )


def _typed_commitment_dedupe_key(*, user: dict, body: CommitmentCreate) -> str:
    """Hash semantic fields while ignoring fresh client-side relation UUIDs."""
    event_positions = {str(event.id): index for index, event in enumerate(body.plan.events)}
    events = [
        {
            "title": event.title,
            "description": event.description,
            "start_time": event.start_time,
            "end_time": event.end_time,
            "all_day": event.all_day,
            "location": event.location,
            "person_ids": sorted(event.person_ids),
            "affected_adult_ids": sorted(event.affected_adult_ids),
            "assigned_to": event.assigned_to,
            "event_type": event.event_type,
            "document_ids": sorted(event.document_ids),
        }
        for event in body.plan.events
    ]
    tasks = sorted(
        (
            {
                "title": task.title,
                "description": task.description,
                "due_date": task.due_date,
                "actionable_from": task.actionable_from,
                "assigned_to": task.assigned_to,
                "priority": task.priority,
                "document_id": task.document_id,
            }
            for task in body.plan.tasks
        ),
        key=_json,
    )
    preparations = sorted(
        (
            {
                # Invalid cross-links are rejected by _validate_plan; keeping the
                # digest total here ensures malformed input still returns the
                # intended validation response instead of raising KeyError first.
                "event_position": event_positions.get(str(preparation.event_id)),
                "name": preparation.name,
                "items": preparation.items,
                "lead_hours": preparation.lead_hours,
                "assigned_to": preparation.assigned_to,
            }
            for preparation in body.plan.preparations
        ),
        key=_json,
    )
    def semantic_provider_reference(source: CommitmentSourceInput) -> str | None:
        # Free-window candidate IDs are client-generated operation identities,
        # not stable provider facts. Exclude UUID-shaped outing references while
        # preserving genuine booking/vendor references and childcare gap sources.
        if body.kind == CommitmentKind.outing and source.provider_reference:
            try:
                uuid.UUID(source.provider_reference)
            except ValueError:
                return source.provider_reference
            return None
        return source.provider_reference

    sources = sorted(
        (
            {
                "kind": source.kind,
                "document_id": source.document_id,
                "label": source.label,
                "provider_reference": semantic_provider_reference(source),
                "source_url": source.source_url,
            }
            for source in body.sources
        ),
        key=_json,
    )
    identity = {
        "processor": "typed",
        "owner": user["id"] if body.visibility.value == "owner" else None,
        "kind": body.kind.value,
        "visibility": body.visibility.value,
        "title": body.title,
        "summary": body.summary,
        "sources": sources,
        "events": events,
        "tasks": tasks,
        "preparations": preparations,
        "external_action": (
            body.plan.external_action.model_dump(mode="json")
            if body.plan.external_action is not None
            else None
        ),
        "group_key": body.group_key,
    }
    return hashlib.sha256(_json(identity).encode()).hexdigest()


async def _validated_superseded_commitment(db, *, user: dict, body, supersedes_id: str):
    if str(body.id) == supersedes_id:
        raise CommitmentValidationError("A source update cannot supersede itself")
    prior = await _visible_commitment(db, user, supersedes_id)
    if prior["kind"] != body.kind.value:
        raise CommitmentValidationError("A source update must use the same workflow type")
    if prior["visibility"] != body.visibility.value:
        raise CommitmentValidationError(
            "A source update must keep the existing plan's visibility"
        )

    seen = {str(body.id)}
    cursor = prior
    for _ in range(100):
        if cursor["id"] in seen:
            raise CommitmentValidationError("Source update history contains a cycle")
        seen.add(cursor["id"])
        parent_id = cursor["supersedes_id"]
        if not parent_id:
            break
        cursor = await _visible_commitment(db, user, parent_id)
    else:
        raise CommitmentValidationError("Source update history is too deep")
    return prior


async def create_commitment(
    db,
    *,
    user: dict,
    body: CommitmentCreate,
    dedupe_key: str | None = None,
    processor: str = "typed",
    supersedes_id: str | None = None,
    changes: list[str] | None = None,
) -> tuple[CommitmentResponse, bool]:
    family_id = user["family_id"]
    commitment_id = str(body.id)
    if dedupe_key is None and body.kind in {
        CommitmentKind.outing,
        CommitmentKind.childcare,
    }:
        dedupe_key = _typed_commitment_dedupe_key(user=user, body=body)
    await db.execute("BEGIN IMMEDIATE")
    try:
        if supersedes_id is not None:
            await _validated_superseded_commitment(
                db,
                user=user,
                body=body,
                supersedes_id=supersedes_id,
            )
        await _validate_plan(
            db,
            family_id=family_id,
            kind=body.kind,
            sources=body.sources,
            plan=body.plan,
        )
        existing = await (
            await db.execute("SELECT * FROM family_commitments WHERE id = ?", (commitment_id,))
        ).fetchone()
        if existing is not None:
            if await _same_create(
                db,
                existing,
                user=user,
                body=body,
                dedupe_key=dedupe_key,
                processor=processor,
                supersedes_id=supersedes_id,
                changes=changes,
            ):
                await db.commit()
                return await commitment_response(db, existing), True
            raise CommitmentConflictError("Commitment ID was already used for a different request")
        if dedupe_key:
            existing = await (
                await db.execute(
                    f"SELECT * FROM family_commitments WHERE dedupe_key = ? AND {_scope_sql()}",
                    (dedupe_key, family_id, user["id"]),
                )
            ).fetchone()
            if existing is not None:
                await db.commit()
                return await commitment_response(db, existing), True

        status, external_status = _initial_state(body.plan)
        now = _now()
        await db.execute(
            """INSERT INTO family_commitments
               (id, kind, visibility, owner_user_id, title, summary, status,
                revision, plan_json, external_action_status, group_key, dedupe_key,
                interpretation_processor, supersedes_id, change_summary_json,
                family_id, created_at, updated_at, created_by, updated_by,
                client_id, client_timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                commitment_id,
                body.kind.value,
                body.visibility.value,
                user["id"],
                body.title,
                body.summary,
                status,
                _json(body.plan),
                external_status,
                body.group_key,
                dedupe_key,
                processor,
                supersedes_id,
                _json(changes or []),
                family_id,
                now,
                now,
                user["id"],
                user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )
        await _insert_sources(
            db,
            commitment_id=commitment_id,
            family_id=family_id,
            user_id=user["id"],
            sources=body.sources,
            now=now,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    row = await _visible_commitment(db, user, commitment_id)
    return await commitment_response(db, row), False


def _parse_client_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise CommitmentValidationError("Client timestamp is invalid") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    if parsed > datetime.now(timezone.utc) + timedelta(minutes=15):
        raise CommitmentValidationError("Client timestamp is too far in the future")
    return parsed


async def _revision_allows_family_conflict(
    db, *, row, user: dict, expected_revision: int, client_timestamp: str | None
) -> bool:
    if row["revision"] == expected_revision:
        return True
    incoming = _parse_client_time(client_timestamp)
    if incoming is None:
        return False
    stored = _parse_client_time(row["client_timestamp"] or row["updated_at"])
    assert stored is not None
    previous_priority_row = await (
        await db.execute(
            "SELECT priority FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (row["updated_by"], user["family_id"]),
        )
    ).fetchone()
    previous_priority = int(previous_priority_row[0]) if previous_priority_row else 0
    difference = abs((incoming - stored).total_seconds())
    if difference <= 300:
        return int(user.get("priority") or 0) > previous_priority
    return incoming > stored


async def _replace_sources(
    db,
    *,
    commitment_id: str,
    family_id: str,
    user_id: str,
    sources: list[CommitmentSourceInput],
    now: str,
    client_id: str | None,
    client_timestamp: str | None,
) -> None:
    existing_rows = await (
        await db.execute(
            "SELECT * FROM family_commitment_sources WHERE commitment_id = ? AND family_id = ?",
            (commitment_id, family_id),
        )
    ).fetchall()
    existing = {row["id"]: row for row in existing_rows}
    wanted = {str(source.id): source for source in sources}
    for source_id, row in existing.items():
        if row["deleted_at"] is not None and source_id in wanted:
            raise CommitmentConflictError("A deleted source ID cannot be reused")
        if row["deleted_at"] is not None:
            continue
        await save_history(
            db,
            "family_commitment_sources",
            source_id,
            user_id,
            family_id=family_id,
        )
        source = wanted.pop(source_id, None)
        if source is None:
            await db.execute(
                "UPDATE family_commitment_sources SET deleted_at = ?, updated_at = ?, "
                "client_id = ?, client_timestamp = ? WHERE id = ? AND family_id = ?",
                (now, now, client_id, client_timestamp, source_id, family_id),
            )
            continue
        await db.execute(
            """UPDATE family_commitment_sources
               SET kind = ?, document_id = ?, label = ?, provider_reference = ?,
                   source_url = ?, observed_at = ?, updated_at = ?, client_id = ?,
                   client_timestamp = ?
               WHERE id = ? AND family_id = ?""",
            (
                source.kind,
                source.document_id,
                source.label,
                source.provider_reference,
                source.source_url,
                source.observed_at,
                now,
                client_id,
                client_timestamp,
                source_id,
                family_id,
            ),
        )
    if wanted:
        await _insert_sources(
            db,
            commitment_id=commitment_id,
            family_id=family_id,
            user_id=user_id,
            sources=list(wanted.values()),
            now=now,
            client_id=client_id,
            client_timestamp=client_timestamp,
        )


async def update_commitment(
    db, *, user: dict, commitment_id: str, body: CommitmentUpdate
) -> CommitmentResponse:
    await db.execute("BEGIN IMMEDIATE")
    try:
        row = await _visible_commitment(db, user, commitment_id)
        if row["status"] not in _EDITABLE_STATUSES:
            raise CommitmentConflictError("Confirmed or declined commitments cannot be edited")
        if (
            body.visibility is not None
            and body.visibility.value != row["visibility"]
            and row["owner_user_id"] != user["id"]
        ):
            raise CommitmentConflictError("Only the commitment owner can change who may see it")
        if not await _revision_allows_family_conflict(
            db,
            row=row,
            user=user,
            expected_revision=body.expected_revision,
            client_timestamp=body.client_timestamp,
        ):
            raise CommitmentConflictError(
                "Commitment changed on another device; refresh before editing"
            )
        current_plan = CommitmentPlan.model_validate_json(row["plan_json"])
        current_sources = await _source_models(
            db, commitment_id=commitment_id, family_id=user["family_id"]
        )
        plan = body.plan or current_plan
        sources = body.sources or current_sources
        await _validate_plan(
            db,
            family_id=user["family_id"],
            kind=CommitmentKind(row["kind"]),
            sources=sources,
            plan=plan,
        )
        now = _now()
        await save_history(
            db,
            "family_commitments",
            commitment_id,
            user["id"],
            family_id=user["family_id"],
        )
        action_changed = _json(current_plan.external_action) != _json(plan.external_action)
        if action_changed:
            status, external_status = _initial_state(plan)
            completed_at = None
            outcome = None
        else:
            status = row["status"]
            external_status = row["external_action_status"]
            completed_at = row["external_action_completed_at"]
            outcome = row["external_action_outcome"]
        await db.execute(
            """UPDATE family_commitments
               SET visibility = ?, title = ?, summary = ?, plan_json = ?, group_key = ?, status = ?,
                   external_action_status = ?, external_action_completed_at = ?,
                   external_action_outcome = ?, revision = revision + 1,
                   updated_at = ?, updated_by = ?, client_id = ?, client_timestamp = ?
               WHERE id = ? AND family_id = ?""",
            (
                body.visibility.value if body.visibility is not None else row["visibility"],
                body.title if body.title is not None else row["title"],
                body.summary if "summary" in body.model_fields_set else row["summary"],
                _json(plan),
                body.group_key if "group_key" in body.model_fields_set else row["group_key"],
                status,
                external_status,
                completed_at,
                outcome,
                now,
                user["id"],
                body.client_id,
                body.client_timestamp,
                commitment_id,
                user["family_id"],
            ),
        )
        if body.sources is not None:
            await _replace_sources(
                db,
                commitment_id=commitment_id,
                family_id=user["family_id"],
                user_id=user["id"],
                sources=sources,
                now=now,
                client_id=body.client_id,
                client_timestamp=body.client_timestamp,
            )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return await get_commitment(db, user=user, commitment_id=commitment_id)


async def complete_external_action(
    db,
    *,
    user: dict,
    commitment_id: str,
    body: CommitmentActionCompleteRequest,
) -> CommitmentResponse:
    await db.execute("BEGIN IMMEDIATE")
    try:
        row = await _visible_commitment(db, user, commitment_id)
        plan = CommitmentPlan.model_validate_json(row["plan_json"])
        if plan.external_action is None:
            raise CommitmentConflictError("This commitment has no external action")
        if row["external_action_status"] == "completed":
            if row["external_action_outcome"] != body.outcome:
                raise CommitmentConflictError("External action was already completed differently")
            await db.commit()
            return await commitment_response(db, row)
        if row["status"] not in _EDITABLE_STATUSES:
            raise CommitmentConflictError("This commitment can no longer be changed")
        if row["revision"] != body.expected_revision:
            raise CommitmentConflictError(
                "Commitment changed on another device; refresh before confirming"
            )
        now = _now()
        await save_history(
            db,
            "family_commitments",
            commitment_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """UPDATE family_commitments
               SET status = 'ready', external_action_status = 'completed',
                   external_action_outcome = ?, external_action_completed_at = ?,
                   revision = revision + 1, updated_at = ?, updated_by = ?,
                   client_id = ?, client_timestamp = ?
               WHERE id = ? AND family_id = ?""",
            (
                body.outcome,
                now,
                now,
                user["id"],
                body.client_id,
                body.client_timestamp,
                commitment_id,
                user["family_id"],
            ),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return await get_commitment(db, user=user, commitment_id=commitment_id)


def _deterministic_id(commitment_id: str, kind: str, source_id: str) -> str:
    return str(_stable_uuid4(f"hausklar:commitment:{commitment_id}:{kind}:{source_id}"))


def _parse_calendar_time(value: str, *, zone: ZoneInfo | None = None) -> datetime:
    if len(value) == 10:
        return datetime.combine(date.fromisoformat(value), time.min, tzinfo=zone or timezone.utc)
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=zone or timezone.utc)
    return parsed


async def _insert_result(
    db,
    *,
    commitment_id: str,
    source_item_id: str,
    result_type: str,
    result_id: str,
    user: dict,
    now: str,
    client_id: str | None,
    client_timestamp: str | None,
) -> None:
    await db.execute(
        """INSERT OR IGNORE INTO family_commitment_results
           (id, commitment_id, source_item_id, result_type, result_id, family_id,
            created_at, updated_at, created_by, client_id, client_timestamp)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            _deterministic_id(
                commitment_id, "result", f"{result_type}:{source_item_id}:{result_id}"
            ),
            commitment_id,
            source_item_id,
            result_type,
            result_id,
            user["family_id"],
            now,
            now,
            user["id"],
            client_id,
            client_timestamp,
        ),
    )


async def _insert_assignment(
    db,
    *,
    task_id: str,
    assigned_to: str | None,
    user: dict,
    now: str,
) -> None:
    if not assigned_to:
        return
    person_type = await family_person_type(db, user["family_id"], assigned_to)
    if person_type is None:
        raise CommitmentValidationError("Task assignee is not in this family")
    await db.execute(
        """INSERT INTO task_assignments
           (id, task_id, assignee_id, assignee_type, family_id,
            created_at, updated_at, created_by)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            _deterministic_id(task_id, "assignment", assigned_to),
            task_id,
            assigned_to,
            person_type,
            user["family_id"],
            now,
            now,
            user["id"],
        ),
    )


async def _materialize_event(
    db,
    *,
    commitment_id: str,
    event: CommitmentEventDraft,
    source_document_ids: list[str],
    attachment_role: str,
    user: dict,
    body: CommitmentConfirmRequest,
    now: str,
) -> str:
    event_id = _deterministic_id(commitment_id, "event", str(event.id))
    existing = await (
        await db.execute("SELECT id FROM calendar_events WHERE id = ?", (event_id,))
    ).fetchone()
    if existing is not None:
        # Confirmation is atomic and confirmed retries return before materialising.
        # Therefore an existing target cannot be a legitimate partial result of
        # this draft; adopting it would silently claim an unrelated family row.
        raise CommitmentConflictError("Calendar result ID is already in use")
    documents = list(dict.fromkeys([*event.document_ids, *source_document_ids]))
    source_document_id = documents[0] if documents else None
    participant_ids = list(event.person_ids)
    if event.assigned_to and event.assigned_to not in participant_ids:
        participant_ids.append(event.assigned_to)
    await db.execute(
        """INSERT INTO calendar_events
           (id, title, description, start_time, end_time, all_day, location,
            family_member_ids, affected_member_ids, assigned_to, event_type,
            exertion, source_document_id, family_id, created_at, updated_at,
            created_by, client_id, client_timestamp)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)""",
        (
            event_id,
            event.title,
            event.description,
            event.start_time,
            event.end_time,
            int(event.all_day),
            event.location,
            json.dumps(event.person_ids) if event.person_ids else None,
            json.dumps(event.affected_adult_ids) if event.affected_adult_ids else None,
            event.assigned_to,
            event.event_type,
            source_document_id,
            user["family_id"],
            now,
            now,
            user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )
    for position, document_id in enumerate(documents):
        await db.execute(
            """INSERT INTO calendar_event_documents
               (id, event_id, document_id, role, position, family_id,
                created_at, updated_at, created_by, client_id, client_timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                _deterministic_id(event_id, "document", document_id),
                event_id,
                document_id,
                attachment_role,
                position,
                user["family_id"],
                now,
                now,
                user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )
    await _insert_result(
        db,
        commitment_id=commitment_id,
        source_item_id=str(event.id),
        result_type="calendar_event",
        result_id=event_id,
        user=user,
        now=now,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    return event_id


async def _materialize_task(
    db,
    *,
    commitment_id: str,
    source_item_id: str,
    result_type: str,
    result_suffix: str,
    title: str,
    description: str | None,
    assigned_to: str | None,
    due_date: str | None,
    actionable_from: str | None,
    priority: int,
    source_document_id: str | None,
    source_event_id: str | None,
    user: dict,
    body: CommitmentConfirmRequest,
    now: str,
) -> str:
    task_id = _deterministic_id(commitment_id, result_type, result_suffix)
    existing = await (await db.execute("SELECT id FROM tasks WHERE id = ?", (task_id,))).fetchone()
    if existing is not None:
        raise CommitmentConflictError("Task result ID is already in use")
    await db.execute(
        """INSERT INTO tasks
           (id, title, description, assigned_to, due_date, category, priority,
            actionable_from, source_document_id, source_event_id, family_id,
            created_at, updated_at, created_by, client_id, client_timestamp)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            task_id,
            title,
            description,
            assigned_to,
            due_date,
            "household" if result_type == "preparation_task" else "admin",
            priority,
            actionable_from,
            source_document_id,
            source_event_id,
            user["family_id"],
            now,
            now,
            user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )
    await _insert_assignment(db, task_id=task_id, assigned_to=assigned_to, user=user, now=now)
    await _insert_result(
        db,
        commitment_id=commitment_id,
        source_item_id=source_item_id,
        result_type=result_type,
        result_id=task_id,
        user=user,
        now=now,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    return task_id


async def confirm_commitment(
    db,
    *,
    user: dict,
    commitment_id: str,
    body: CommitmentConfirmRequest,
) -> CommitmentResponse:
    await db.execute("BEGIN IMMEDIATE")
    try:
        row = await _visible_commitment(db, user, commitment_id)
        if row["status"] == CommitmentStatus.confirmed.value:
            if body.expected_revision not in {row["revision"], row["revision"] - 1}:
                raise CommitmentConflictError("Commitment revision does not match")
            await db.commit()
            return await commitment_response(db, row)
        if row["status"] == CommitmentStatus.declined.value:
            raise CommitmentConflictError("Declined commitments cannot be confirmed")
        if row["visibility"] != "family":
            raise CommitmentConflictError(
                "Share this plan with the family before creating calendar or task items"
            )
        if row["revision"] != body.expected_revision:
            raise CommitmentConflictError(
                "Commitment changed on another device; refresh before confirming"
            )
        plan = CommitmentPlan.model_validate_json(row["plan_json"])
        sources = await _source_models(db, commitment_id=commitment_id, family_id=user["family_id"])
        await _validate_plan(
            db,
            family_id=user["family_id"],
            kind=CommitmentKind(row["kind"]),
            sources=sources,
            plan=plan,
            require_complete=True,
        )
        if (
            plan.external_action
            and plan.external_action.requires_completion_before_confirm
            and row["external_action_status"] != "completed"
        ):
            raise CommitmentConflictError(
                "Complete the external RSVP or booking step before confirming"
            )
        source_document_ids = list(
            dict.fromkeys(
                source.document_id for source in sources if source.document_id is not None
            )
        )
        role = {
            "school": "school_letter",
            "travel": "booking",
            "outing": "booking",
        }.get(row["kind"], "other")
        now = _now()
        event_results: dict[str, str] = {}
        for event in plan.events:
            event_results[str(event.id)] = await _materialize_event(
                db,
                commitment_id=commitment_id,
                event=event,
                source_document_ids=source_document_ids,
                attachment_role=role,
                user=user,
                body=body,
                now=now,
            )
        default_document = source_document_ids[0] if source_document_ids else None
        for task in plan.tasks:
            await _materialize_task(
                db,
                commitment_id=commitment_id,
                source_item_id=str(task.id),
                result_type="task",
                result_suffix=str(task.id),
                title=task.title,
                description=task.description,
                assigned_to=task.assigned_to,
                due_date=task.due_date,
                actionable_from=task.actionable_from,
                priority=task.priority,
                source_document_id=task.document_id or default_document,
                source_event_id=None,
                user=user,
                body=body,
                now=now,
            )
        events_by_id = {str(event.id): event for event in plan.events}
        for preparation in plan.preparations:
            event = events_by_id[str(preparation.event_id)]
            event_start = _parse_calendar_time(event.start_time)
            if len(event.start_time) == 10:
                due = event.start_time
                actionable = (
                    (event_start - timedelta(hours=preparation.lead_hours)).date().isoformat()
                )
            else:
                due = event.start_time
                actionable = (event_start - timedelta(hours=preparation.lead_hours)).isoformat()
            for index, item in enumerate(preparation.items):
                await _materialize_task(
                    db,
                    commitment_id=commitment_id,
                    source_item_id=str(preparation.id),
                    result_type="preparation_task",
                    result_suffix=f"{preparation.id}:{index}",
                    title=item,
                    description=f"For {event.title} · {preparation.name}",
                    assigned_to=preparation.assigned_to,
                    due_date=due,
                    actionable_from=actionable,
                    priority=2,
                    source_document_id=default_document,
                    source_event_id=event_results[str(preparation.event_id)],
                    user=user,
                    body=body,
                    now=now,
                )
        await save_history(
            db,
            "family_commitments",
            commitment_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """UPDATE family_commitments
               SET status = 'confirmed', confirmed_at = ?, revision = revision + 1,
                   updated_at = ?, updated_by = ?, client_id = ?, client_timestamp = ?
               WHERE id = ? AND family_id = ?""",
            (
                now,
                now,
                user["id"],
                body.client_id,
                body.client_timestamp,
                commitment_id,
                user["family_id"],
            ),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return await get_commitment(db, user=user, commitment_id=commitment_id)


async def decline_commitment(
    db,
    *,
    user: dict,
    commitment_id: str,
    body: CommitmentDeclineRequest,
) -> CommitmentResponse:
    await db.execute("BEGIN IMMEDIATE")
    try:
        row = await _visible_commitment(db, user, commitment_id)
        if row["status"] == "declined":
            await db.commit()
            return await commitment_response(db, row)
        if row["status"] == "confirmed":
            raise CommitmentConflictError("Confirmed commitments cannot be declined")
        if row["revision"] != body.expected_revision:
            raise CommitmentConflictError(
                "Commitment changed on another device; refresh before declining"
            )
        now = _now()
        await save_history(
            db,
            "family_commitments",
            commitment_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """UPDATE family_commitments
               SET status = 'declined', declined_at = ?, decline_reason = ?,
                   external_action_status = CASE WHEN external_action_status = 'pending'
                       THEN 'declined' ELSE external_action_status END,
                   revision = revision + 1, updated_at = ?, updated_by = ?,
                   client_id = ?, client_timestamp = ?
               WHERE id = ? AND family_id = ?""",
            (
                now,
                body.reason,
                now,
                user["id"],
                body.client_id,
                body.client_timestamp,
                commitment_id,
                user["family_id"],
            ),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
    return await get_commitment(db, user=user, commitment_id=commitment_id)


async def delete_commitment(db, *, user: dict, commitment_id: str) -> None:
    await db.execute("BEGIN IMMEDIATE")
    try:
        await _visible_commitment(db, user, commitment_id)
        now = _now()
        await save_history(
            db,
            "family_commitments",
            commitment_id,
            user["id"],
            family_id=user["family_id"],
        )
        for table in ("family_commitment_sources", "family_commitment_results"):
            rows = await (
                await db.execute(
                    f"SELECT id FROM {table} WHERE commitment_id = ? AND family_id = ? "
                    "AND deleted_at IS NULL",
                    (commitment_id, user["family_id"]),
                )
            ).fetchall()
            for row in rows:
                await save_history(
                    db,
                    table,
                    row["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
            await db.execute(
                f"UPDATE {table} SET deleted_at = ?, updated_at = ? "
                "WHERE commitment_id = ? AND family_id = ? AND deleted_at IS NULL",
                (now, now, commitment_id, user["family_id"]),
            )
        await db.execute(
            "UPDATE family_commitments SET deleted_at = ?, updated_at = ?, updated_by = ? "
            "WHERE id = ? AND family_id = ?",
            (now, now, user["id"], commitment_id, user["family_id"]),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


def _zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ValueError, ZoneInfoNotFoundError) as exc:
        raise CommitmentValidationError("Timezone is invalid") from exc


def _event_applies_to_people(row: dict, person_ids: set[str]) -> bool:
    members = set(json.loads(row.get("family_member_ids") or "[]"))
    affected = set(json.loads(row.get("affected_member_ids") or "[]"))
    assigned = row.get("assigned_to")
    if not members and not affected and not assigned:
        return True
    return bool(person_ids & (members | affected | ({assigned} if assigned else set())))


async def _calendar_source_rows(
    db,
    *,
    family_id: str,
    start: datetime,
    end: datetime,
    event_type: str | None = None,
):
    """Load range candidates without letting old point events crowd out current data."""
    columns = (
        "ce.id, ce.start_time, ce.end_time, ce.all_day, ce.recurrence_rule, "
        "ce.family_member_ids, ce.affected_member_ids, ce.assigned_to"
    )
    override_filter = """
        AND NOT EXISTS (
            SELECT 1 FROM calendar_events replacement
            WHERE replacement.overridden_event_id = ce.id
              AND replacement.family_id = ce.family_id
              AND replacement.deleted_at IS NULL
        )
    """
    type_filter = " AND ce.event_type = ?" if event_type else ""
    type_params = (event_type,) if event_type else ()
    # Storage contains date-only, Zulu and offset values. Widen the indexed text
    # prefilter by one civil day, then let recurrence expansion do exact overlap.
    coarse_start = (start - timedelta(days=1)).date().isoformat()
    coarse_end = (end + timedelta(days=1)).date().isoformat()
    nonrecurring = await (
        await db.execute(
            f"""SELECT {columns}
                FROM calendar_events ce
                WHERE ce.family_id = ? AND ce.deleted_at IS NULL
                  AND ce.recurrence_rule IS NULL
                  AND ce.start_time < ?
                  AND (
                      (ce.end_time IS NULL AND ce.start_time >= ?)
                      OR ce.end_time >= ?
                  )
                  {type_filter}
                  {override_filter}
                ORDER BY ce.start_time, ce.id
                LIMIT ?""",
            (
                family_id,
                coarse_end,
                coarse_start,
                coarse_start,
                *type_params,
                _MAX_RANGE_NONRECURRING_ROWS + 1,
            ),
        )
    ).fetchall()
    if len(nonrecurring) > _MAX_RANGE_NONRECURRING_ROWS:
        raise CommitmentValidationError("Too many calendar events overlap this range")

    recurring = await (
        await db.execute(
            f"""SELECT {columns}
                FROM calendar_events ce
                WHERE ce.family_id = ? AND ce.deleted_at IS NULL
                  AND ce.recurrence_rule IS NOT NULL
                  AND ce.start_time < ?
                  {type_filter}
                  {override_filter}
                ORDER BY ce.start_time, ce.id
                LIMIT ?""",
            (
                family_id,
                coarse_end,
                *type_params,
                _MAX_RANGE_RECURRING_ROWS + 1,
            ),
        )
    ).fetchall()
    if len(recurring) > _MAX_RANGE_RECURRING_ROWS:
        raise CommitmentValidationError("Too many repeating calendar events overlap this range")
    return [*nonrecurring, *recurring]


async def _calendar_occurrence_intervals(
    db,
    rows,
    *,
    family_id: str,
    start: datetime,
    end: datetime,
) -> list[tuple[dict, datetime, datetime]]:
    """Expand intervals with Calendar's canonical exception semantics."""
    try:
        expanded = await expand_calendar_rows(
            db,
            family_id=family_id,
            rows=rows,
            # Timed events without an explicit end occupy one hour in these
            # availability tools, including when they begin just before range_start.
            range_start=start - timedelta(hours=1),
            range_end=end,
            max_occurrences_per_series=_MAX_OCCURRENCES_PER_SERIES,
            fail_on_truncation=True,
        )
    except CalendarRecurrenceError as exc:
        raise CommitmentValidationError(str(exc)) from exc
    intervals: list[tuple[dict, datetime, datetime]] = []
    for occurrence in expanded:
        occurrence_end = occurrence.end
        if occurrence_end is None:
            occurrence_end = occurrence.start + (
                timedelta(days=1) if occurrence.all_day else timedelta(hours=1)
            )
        if occurrence.start < end and occurrence_end > start:
            intervals.append(
                (
                    occurrence.row,
                    max(start, occurrence.start),
                    min(end, occurrence_end),
                )
            )
    return intervals


def _merge_intervals(
    intervals: list[tuple[datetime, datetime]],
) -> list[tuple[datetime, datetime]]:
    merged: list[list[datetime]] = []
    for start, end in sorted(intervals):
        if not merged or start > merged[-1][1]:
            merged.append([start, end])
        elif end > merged[-1][1]:
            merged[-1][1] = end
    return [(item[0], item[1]) for item in merged]


async def query_free_windows(db, *, user: dict, body: FreeWindowQuery) -> FreeWindowQueryResponse:
    zone = _zone(body.timezone)
    start = _parse_calendar_time(body.start_time, zone=zone)
    end = _parse_calendar_time(body.end_time, zone=zone)
    if end - start > timedelta(days=31):
        raise CommitmentValidationError("Free-window searches are limited to 31 days")
    for person_id in body.person_ids:
        if await family_person_type(db, user["family_id"], person_id) is None:
            raise CommitmentValidationError("A selected person is not in this family")
    rows = await _calendar_source_rows(
        db,
        family_id=user["family_id"],
        start=start,
        end=end,
    )
    wanted = set(body.person_ids)
    busy: list[tuple[datetime, datetime]] = []
    for row, occurrence_start, occurrence_end in await _calendar_occurrence_intervals(
        db,
        rows,
        family_id=user["family_id"],
        start=start,
        end=end,
    ):
        if _event_applies_to_people(row, wanted):
            busy.append((occurrence_start, occurrence_end))
    merged = _merge_intervals(busy)
    gaps: list[tuple[datetime, datetime]] = []
    cursor = start
    minimum = timedelta(minutes=body.minimum_minutes)
    for busy_start, busy_end in merged:
        if busy_start - cursor >= minimum:
            gaps.append((cursor, busy_start))
        cursor = max(cursor, busy_end)
    if end - cursor >= minimum:
        gaps.append((cursor, end))
    windows = [
        FreeWindowResponse(
            start_time=gap_start.isoformat(),
            end_time=gap_end.isoformat(),
            duration_minutes=math.floor((gap_end - gap_start).total_seconds() / 60),
        )
        for gap_start, gap_end in gaps
    ]
    outings: list[ViableOutingResponse] = []
    for candidate in body.candidates:
        candidate_start = _parse_calendar_time(candidate.available_start, zone=zone)
        candidate_end = _parse_calendar_time(candidate.available_end, zone=zone)
        duration = timedelta(minutes=candidate.duration_minutes)
        for gap_start, gap_end in gaps:
            proposed_start = max(gap_start, candidate_start)
            proposed_end = proposed_start + duration
            if proposed_end <= min(gap_end, candidate_end):
                outings.append(
                    ViableOutingResponse(
                        candidate_id=candidate.id,
                        title=candidate.title,
                        proposed_start=proposed_start.isoformat(),
                        proposed_end=proposed_end.isoformat(),
                        location=candidate.location,
                        booking_url=candidate.booking_url,
                    )
                )
                break
    outings.sort(key=lambda item: (item.proposed_start, item.title.casefold()))
    return FreeWindowQueryResponse(windows=windows, viable_outings=outings)


async def childcare_gaps(
    db,
    *,
    user: dict,
    child_id: str,
    from_date: date,
    to_date: date,
    timezone_name: str,
) -> list[ChildcareGapResponse]:
    if to_date < from_date:
        raise CommitmentValidationError("End date must not be before start date")
    if to_date - from_date > timedelta(days=366):
        raise CommitmentValidationError("Childcare gap searches are limited to one year")
    if not await family_child_exists(db, user["family_id"], child_id):
        raise CommitmentNotFoundError("Child not found")
    zone = _zone(timezone_name)
    term_rows = await (
        await db.execute(
            """SELECT start_date, end_date FROM term_dates
               WHERE family_id = ? AND person_id = ? AND deleted_at IS NULL
                 AND end_date >= ? AND start_date <= ?""",
            (user["family_id"], child_id, from_date.isoformat(), to_date.isoformat()),
        )
    ).fetchall()
    terms = [(date.fromisoformat(row[0]), date.fromisoformat(row[1])) for row in term_rows]
    holiday_rows = await (
        await db.execute(
            """SELECT date, label FROM holiday_dates
               WHERE family_id = ? AND person_id = ? AND deleted_at IS NULL
                 AND date >= ? AND date <= ?""",
            (user["family_id"], child_id, from_date.isoformat(), to_date.isoformat()),
        )
    ).fetchall()
    explicit = {date.fromisoformat(row[0]): row[1] for row in holiday_rows}
    start_time = datetime.combine(from_date, time.min, tzinfo=zone)
    end_time = datetime.combine(to_date + timedelta(days=1), time.min, tzinfo=zone)
    event_rows = await _calendar_source_rows(
        db,
        family_id=user["family_id"],
        start=start_time,
        end=end_time,
        event_type="childcare",
    )
    coverage: list[tuple[datetime, datetime]] = []
    for row, event_start, event_end in await _calendar_occurrence_intervals(
        db,
        event_rows,
        family_id=user["family_id"],
        start=start_time,
        end=end_time,
    ):
        if not _event_applies_to_people(row, {child_id}):
            continue
        coverage.append((event_start, event_end))
    merged_coverage = _merge_intervals(coverage)

    def fully_covered(day: date) -> bool:
        day_start = datetime.combine(day, time.min, tzinfo=zone)
        day_end = datetime.combine(day + timedelta(days=1), time.min, tzinfo=zone)
        return any(start <= day_start and end >= day_end for start, end in merged_coverage)

    gaps: list[ChildcareGapResponse] = []
    current = from_date
    while current <= to_date:
        if current.weekday() < 5 and not fully_covered(current):
            if current in explicit:
                gaps.append(
                    ChildcareGapResponse(
                        date=current.isoformat(),
                        label=explicit[current] or "School holiday",
                        source="explicit_holiday",
                    )
                )
            elif terms and not any(start <= current <= end for start, end in terms):
                gaps.append(
                    ChildcareGapResponse(
                        date=current.isoformat(),
                        label="School holiday",
                        source="outside_term",
                    )
                )
        current += timedelta(days=1)
    return gaps


async def _family_people(db, family_id: str) -> list[dict[str, str]]:
    rows = await (
        await db.execute(
            """SELECT id, name, 'user' AS person_type FROM users
               WHERE family_id = ? AND deleted_at IS NULL
               UNION ALL
               SELECT id, name, 'child' AS person_type FROM children
               WHERE family_id = ? AND deleted_at IS NULL
               ORDER BY name""",
            (family_id, family_id),
        )
    ).fetchall()
    return [dict(row) for row in rows]


def _first_safe_link(text: str) -> str | None:
    for match in _PUBLIC_LINK_PATTERN.findall(text):
        candidate = match.rstrip(".,);:")
        try:
            return validate_safe_https_url(candidate)
        except ValueError:
            continue
    return None


def _external_action(kind: CommitmentKind, text: str) -> CommitmentExternalAction | None:
    action_kind = {
        CommitmentKind.invitation: "rsvp",
        CommitmentKind.appointment: "book",
        CommitmentKind.outing: "book",
        CommitmentKind.travel: "register",
    }.get(kind)
    if action_kind is None and "pay" not in text.casefold():
        return None
    if action_kind is None:
        action_kind = "pay"
    link = _first_safe_link(text)
    if link:
        target_type, target = "https", link
    else:
        email = _EMAIL_PATTERN.search(text)
        phone = _PHONE_PATTERN.search(text)
        if email:
            target_type, target = "email", email.group(0)
        elif phone:
            target_type, target = "phone", phone.group(0)
        else:
            target_type, target = "manual", "Follow the instructions in the source"
    label = {
        "rsvp": "Reply to the invitation",
        "book": "Complete the booking",
        "register": "Complete check-in or registration",
        "pay": "Complete the payment",
    }[action_kind]
    return CommitmentExternalAction(
        kind=action_kind,
        label=label,
        target_type=target_type,
        target=target,
        requires_completion_before_confirm=kind
        in {CommitmentKind.invitation, CommitmentKind.appointment, CommitmentKind.outing},
    )


def _preparation_items(kind: CommitmentKind, text: str) -> list[str]:
    lower = text.casefold()
    items: list[str] = []
    keyword_items = (
        ("costume", "Prepare the costume"),
        ("gift", "Choose a gift"),
        ("present", "Choose a present"),
        ("card", "Write the card"),
        ("passport", "Pack passports"),
        ("ticket", "Save tickets for offline access"),
        ("form", "Complete the required form"),
        ("bring", "Check what needs to be brought"),
        ("pack", "Pack the required items"),
    )
    for keyword, label in keyword_items:
        if keyword in lower and label not in items:
            items.append(label)
    if kind == CommitmentKind.invitation and not items:
        items = ["Choose a gift", "Write the card"]
    return items[:8]


def _suggested_task_date(value: str | None) -> str | None:
    if value is None:
        return None
    try:
        if len(value) == 10:
            return date.fromisoformat(value).isoformat()
        return datetime.fromisoformat(value.replace("Z", "+00:00")).date().isoformat()
    except (TypeError, ValueError):
        return None


def _plan_from_suggestions(
    *,
    commitment_id: str,
    kind: CommitmentKind,
    suggestions: list[CaptureSuggestionCreate],
    text: str,
) -> CommitmentPlan:
    events: list[CommitmentEventDraft] = []
    tasks: list[CommitmentTaskDraft] = []
    for index, suggestion in enumerate(suggestions):
        item_id = _stable_uuid4(
            f"hausklar:commitment-source:{commitment_id}:{suggestion.kind}:{index}",
        )
        if suggestion.kind == "event" and suggestion.start_time:
            events.append(
                CommitmentEventDraft(
                    id=item_id,
                    title=suggestion.title,
                    description=suggestion.details,
                    start_time=suggestion.start_time,
                    end_time=suggestion.end_time,
                    all_day=suggestion.all_day,
                    person_ids=[suggestion.assigned_to] if suggestion.assigned_to else [],
                    assigned_to=suggestion.assigned_to,
                    event_type=kind.value,
                )
            )
        elif suggestion.kind == "task":
            tasks.append(
                CommitmentTaskDraft(
                    id=item_id,
                    title=suggestion.title,
                    description=suggestion.details,
                    due_date=_suggested_task_date(suggestion.due_date),
                    assigned_to=suggestion.assigned_to,
                )
            )
    if kind in {
        CommitmentKind.invitation,
        CommitmentKind.outing,
        CommitmentKind.childcare,
        CommitmentKind.appointment,
    }:
        events = events[:1]
    preparations: list[CommitmentPreparationDraft] = []
    items = _preparation_items(kind, text)
    if events and items:
        preparations.append(
            CommitmentPreparationDraft(
                id=_stable_uuid4(
                    f"hausklar:commitment-source:{commitment_id}:preparation",
                ),
                event_id=events[0].id,
                name={
                    CommitmentKind.school: "School preparation",
                    CommitmentKind.invitation: "Synthetic public demo record 11",
                    CommitmentKind.appointment: "Appointment preparation",
                    CommitmentKind.travel: "Synthetic public demo record 9",
                }.get(kind, "Preparation"),
                items=items,
            )
        )
    return CommitmentPlan(
        events=events,
        tasks=tasks,
        preparations=preparations,
        external_action=_external_action(kind, text),
    )


def _material_changes(old: CommitmentPlan, new: CommitmentPlan) -> list[str]:
    def event_values(plan: CommitmentPlan) -> list[dict]:
        return sorted(
            (
                {
                    "title": item.title,
                    "description": item.description,
                    "start_time": item.start_time,
                    "end_time": item.end_time,
                    "all_day": item.all_day,
                    "location": item.location,
                    "person_ids": sorted(item.person_ids),
                    "affected_adult_ids": sorted(item.affected_adult_ids),
                    "assigned_to": item.assigned_to,
                    "event_type": item.event_type,
                    "document_ids": sorted(item.document_ids),
                }
                for item in plan.events
            ),
            key=_json,
        )

    def task_values(plan: CommitmentPlan) -> list[dict]:
        return sorted(
            (
                item.model_dump(mode="json", exclude={"id"})
                for item in plan.tasks
            ),
            key=_json,
        )

    def preparation_values(plan: CommitmentPlan) -> list[dict]:
        event_positions = {str(item.id): index for index, item in enumerate(plan.events)}
        return sorted(
            (
                {
                    "event_position": event_positions.get(str(item.event_id)),
                    "name": item.name,
                    "items": sorted(item.items),
                    "lead_hours": item.lead_hours,
                    "assigned_to": item.assigned_to,
                }
                for item in plan.preparations
            ),
            key=_json,
        )

    changes: list[str] = []
    if event_values(old) != event_values(new):
        changes.append("Event details or times changed")
    if task_values(old) != task_values(new):
        changes.append("Actions or deadlines changed")
    if preparation_values(old) != preparation_values(new):
        changes.append("Preparation changed")
    if _json(old.external_action) != _json(new.external_action):
        changes.append("External booking or reply instructions changed")
    return changes


async def commitment_from_source(
    db, *, user: dict, body: CommitmentFromSourceRequest
) -> CommitmentFromSourceResponse:
    document = None
    if body.source_document_id:
        document = await (
            await db.execute(
                """SELECT id, title, extracted_text, sha256 FROM documents
                   WHERE id = ? AND family_id = ? AND deleted_at IS NULL""",
                (body.source_document_id, user["family_id"]),
            )
        ).fetchone()
        if document is None:
            raise CommitmentNotFoundError("Source document not found")
    text = body.text or (document["extracted_text"] if document else None)
    if not text or not text.strip():
        raise CommitmentValidationError("The source has no reviewed text to interpret")
    text = text.strip()[:100_000]
    people = await _family_people(db, user["family_id"])
    reference = reference_in_timezone(body.client_now, body.timezone)
    suggestions: list[CaptureSuggestionCreate] | None = None
    processor = "fallback"
    warning = None
    if body.use_hermes:
        require_ai_consent(user)
        suggestions = await extract_capture_suggestions(
            title=body.title or (document["title"] if document else body.kind.value),
            text=text,
            people=people,
            reference_date=reference.date().isoformat(),
        )
        if suggestions:
            processor = "hermes"
        else:
            warning = "Smart interpretation was unavailable, so HausKlar used basic parsing."
    if not suggestions:
        suggestions = fallback_capture_suggestions(text, people=people, reference=reference)
    commitment_id = str(body.id)
    plan = _plan_from_suggestions(
        commitment_id=commitment_id,
        kind=body.kind,
        suggestions=suggestions,
        text=text,
    )
    observed_at = reference.isoformat()
    sources: list[CommitmentSourceInput] = []
    if document:
        sources.append(
            CommitmentSourceInput(
                id=_stable_uuid4(
                    f"hausklar:commitment-source:{commitment_id}:document:{document['id']}",
                ),
                kind="document",
                document_id=document["id"],
                label=document["title"],
                observed_at=observed_at,
            )
        )
    if body.text:
        sources.append(
            CommitmentSourceInput(
                id=_stable_uuid4(
                    f"hausklar:commitment-source:{commitment_id}:reviewed-text",
                ),
                kind="share" if body.provider_reference else "manual",
                label=body.source_label or "Reviewed source text",
                provider_reference=body.provider_reference,
                observed_at=observed_at,
            )
        )
    supersedes_id = str(body.supersedes_id) if body.supersedes_id is not None else None
    digest_payload = {
        "owner": user["id"] if body.visibility.value == "owner" else None,
        "kind": body.kind.value,
        "document": document["sha256"] if document else None,
        "text": text,
        "provider_reference": body.provider_reference,
        "supersedes_id": supersedes_id,
    }
    dedupe_key = hashlib.sha256(_json(digest_payload).encode()).hexdigest()
    changes: list[str] = []
    if supersedes_id:
        prior_row = await _validated_superseded_commitment(
            db,
            user=user,
            body=body,
            supersedes_id=supersedes_id,
        )
        changes = _material_changes(
            CommitmentPlan.model_validate_json(prior_row["plan_json"]), plan
        )
        if not changes:
            changes = ["No material plan changes detected"]
    title = (
        body.title
        or (document["title"] if document else None)
        or (plan.events[0].title if plan.events else None)
        or (plan.tasks[0].title if plan.tasks else None)
        or f"{body.kind.value.title()} commitment"
    )
    create = CommitmentCreate(
        id=body.id,
        kind=body.kind,
        visibility=body.visibility,
        title=title,
        summary=text[:10_000],
        sources=sources,
        plan=plan,
        group_key=(
            body.provider_reference
            if body.kind == CommitmentKind.travel and body.provider_reference
            else None
        ),
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    commitment, replayed = await create_commitment(
        db,
        user=user,
        body=create,
        dedupe_key=dedupe_key,
        processor=processor,
        supersedes_id=supersedes_id,
        changes=changes,
    )
    return CommitmentFromSourceResponse(
        commitment=commitment,
        processor=processor,
        warning=warning,
        deduplicated=replayed,
        material_changes=commitment.change_summary,
    )
