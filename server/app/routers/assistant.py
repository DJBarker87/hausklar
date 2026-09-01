import json
import hashlib
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import ValidationError

from app.auth import get_current_user
from app.database import database_lease, get_db
from app.models.assistant import (
    AssistantActionResponse,
    AssistantActionResult,
    AssistantActionUpdate,
    AssistantMessageRequest,
    AssistantMessageResponse,
)
from app.config import settings
from app.middleware.rate_limit import RateLimiter, extract_client_ip, reserve_persistent_attempts
from app.services.assistant import (
    assistant_action_preview,
    build_assistant_context,
    call_all_lights,
    create_calendar_event_from_action,
    create_shopping_item_from_action,
    create_task_from_action,
    complete_task_from_action,
    edited_action_summary,
    load_family_people,
    normalise_edited_action_payload,
    redact_assistant_context,
    request_reference,
    store_pending_actions,
)
from app.services.ai_consent import require_ai_consent
from app.services.hermes import (
    HermesBusyError,
    HermesUsageLimitError,
    ask_family_assistant,
)
from app.services.home_assistant import get_home_snapshot_for_family
from app.services.record_history import save_history

router = APIRouter()
assistant_rate_limiter = RateLimiter(
    max_attempts=settings.assistant_rate_limit_requests,
    window_seconds=settings.assistant_rate_limit_window_seconds,
)


@router.post("/message", response_model=AssistantMessageResponse)
async def assistant_message(
    body: AssistantMessageRequest,
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """Return a grounded answer plus actions that still require confirmation."""
    require_ai_consent(current_user)
    rate_key = f"assistant:{current_user['id']}"
    assistant_rate_limiter.ensure_allowed(
        rate_key,
        detail_prefix="Too many Bismarck requests",
    )
    assistant_rate_limiter.record_failure(rate_key)
    ip_hash = hashlib.sha256(extract_client_ip(request).encode()).hexdigest()
    family_key = f"assistant:family:{current_user['family_id']}"
    durable_rules = [
        (
            "assistant:global",
            settings.assistant_global_rate_limit_requests,
            settings.assistant_rate_limit_window_seconds,
        ),
        (
            family_key,
            settings.assistant_family_rate_limit_requests,
            settings.assistant_rate_limit_window_seconds,
        ),
        (
            f"assistant:user:{current_user['id']}",
            settings.assistant_rate_limit_requests,
            settings.assistant_rate_limit_window_seconds,
        ),
        (
            f"assistant:ip:{ip_hash}",
            settings.assistant_ip_rate_limit_requests,
            settings.assistant_rate_limit_window_seconds,
        ),
    ]
    if current_user["email"].strip().lower() == "reviewer@example.invalid":
        durable_rules.append(
            (
                f"assistant:review:{current_user['id']}",
                settings.assistant_review_rate_limit_requests,
                settings.assistant_rate_limit_window_seconds,
            )
        )
    async with database_lease() as db:
        await reserve_persistent_attempts(
            db,
            durable_rules,
            detail_prefix="Too many Bismarck requests",
        )
    reference = request_reference(body.client_now, body.timezone)
    history_text = "\n".join(item.content for item in body.history[-12:])
    async with database_lease() as db:
        context, people = await build_assistant_context(
            db,
            family_id=current_user["family_id"],
            message=body.message,
            history_text=history_text,
            reference=reference,
            timezone_name=body.timezone,
            user_id=current_user["id"],
        )
    if context["home_assistant"].get("requested"):
        context["home_assistant"] = await get_home_snapshot_for_family(
            current_user["family_id"], timeout=3.0
        )
        context["home_assistant"]["requested"] = True
        context = redact_assistant_context(context)
    try:
        hermes_response = await ask_family_assistant(
            message=body.message,
            history=body.history,
            context=context,
        )
    except HermesUsageLimitError:
        raise HTTPException(
            status_code=503,
            detail=(
                "Bismarck has reached its AI usage limit for now. "
                "It resets on its own — please try again in an hour or two."
            ),
        )
    except HermesBusyError:
        raise HTTPException(
            status_code=503,
            detail=("Bismarck is helping someone else right now. Please try again in a moment."),
        )
    if not hermes_response:
        raise HTTPException(
            status_code=503,
            detail="Bismarck is unavailable just now. Please try again shortly.",
        )

    async with database_lease() as db:
        actions = await store_pending_actions(
            db,
            actions=hermes_response.actions,
            people=people,
            reference=reference,
            timezone_name=body.timezone,
            current_user=current_user,
            persist=not body.dry_run,
            request_text=f"{history_text}\n{body.message}",
            request_message=body.message,
            response_language=hermes_response.language,
        )
    answer = hermes_response.answer
    if hermes_response.actions and not actions:
        if all(action.kind == "complete_task" for action in hermes_response.actions):
            answer = (
                "Ich habe mehrere passende offene Aufgaben gefunden. Welches "
                "Fälligkeitsdatum soll ich als erledigt markieren?"
                if hermes_response.language == "de"
                else (
                    "I found more than one matching open task. Which due date should I mark done?"
                )
            )
        elif all(action.kind == "create_task" for action in hermes_response.actions):
            answer = (
                "I need a little more detail before I can prepare that task safely. "
                "Please include what needs doing, who owns it, and the first due date "
                "or repeat day."
            )
        else:
            answer = (
                "I need a little more detail before I can prepare that safely. "
                "Please give the relevant person, date or day, and time."
            )
    elif len(actions) < len(hermes_response.actions):
        answer += (
            "\n\nOne part needs a clearer date, time, or family member before I can prepare it."
        )
    return AssistantMessageResponse(answer=answer, actions=actions)


async def _owned_action(db, action_id: str, current_user: dict):
    cursor = await db.execute(
        """
        SELECT * FROM assistant_actions
        WHERE id = ? AND family_id = ? AND created_by = ? AND deleted_at IS NULL
        """,
        (action_id, current_user["family_id"], current_user["id"]),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Assistant action not found")
    return row


def _expired(row) -> bool:
    expires_at = datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    return expires_at <= datetime.now(timezone.utc)


def _action_language(row) -> str:
    try:
        payload = json.loads(row["payload"])
    except (json.JSONDecodeError, TypeError):
        return "en"
    return "de" if payload.get("_language") == "de" else "en"


def _result(row, *, status: str, message: str, result_id: str | None = None):
    return AssistantActionResult(
        id=row["id"],
        kind=row["action_type"],
        summary=row["summary"],
        status=status,
        message=message,
        result_id=result_id,
    )


def _action_response(row) -> AssistantActionResponse:
    payload = json.loads(row["payload"])
    preview = assistant_action_preview(row["action_type"], payload)
    return AssistantActionResponse(
        id=row["id"],
        kind=row["action_type"],
        summary=row["summary"],
        status=row["status"],
        expires_at=row["expires_at"],
        editable=preview is not None,
        preview=preview,
    )


def _expired_message(row) -> str:
    return (
        "Diese Aktion ist abgelaufen. Frag Bismarck einfach noch einmal."
        if _action_language(row) == "de"
        else "This action expired. Just ask Bismarck again."
    )


def _failed_message(row) -> str:
    if _action_language(row) == "de":
        return "Dieser Befehl konnte nicht ausgeführt werden."
    return (
        "Home Assistant could not complete that command."
        if row["action_type"] == "home_lights"
        else "HausKlar could not complete that action."
    )


def _success_message(row) -> str:
    language = _action_language(row)
    if row["action_type"] == "calendar_event":
        return (
            "Zum Familienkalender hinzugefügt."
            if language == "de"
            else "Added to the family calendar."
        )
    if row["action_type"] == "create_task":
        return "Aufgabe erstellt." if language == "de" else "Task created."
    if row["action_type"] == "complete_task":
        return "Aufgabe als erledigt markiert." if language == "de" else "Task marked complete."
    if row["action_type"] == "shopping_item":
        return (
            "Zur Einkaufsliste hinzugefügt." if language == "de" else "Added to the shopping list."
        )
    payload = json.loads(row["payload"])
    state = payload["state"]
    if language == "de":
        return (
            "Alle Lichter wurden eingeschaltet."
            if state == "on"
            else "Alle Lichter wurden ausgeschaltet."
        )
    return f"All lights were turned {state}."


@router.patch("/actions/{action_id}", response_model=AssistantActionResponse)
async def update_assistant_action(
    action_id: str,
    body: AssistantActionUpdate,
    current_user: dict = Depends(get_current_user),
):
    """Edit a short-lived typed proposal before it is explicitly confirmed."""
    async with database_lease() as db:
        row = await _owned_action(db, action_id, current_user)
        if row["status"] != "pending":
            raise HTTPException(
                status_code=409,
                detail="This assistant action has already been handled",
            )
        if _expired(row):
            now = datetime.now(timezone.utc).isoformat()
            await db.execute(
                "UPDATE assistant_actions SET status = 'expired', updated_at = ? "
                "WHERE id = ? AND family_id = ? AND created_by = ? "
                "AND status = 'pending'",
                (now, action_id, current_user["family_id"], current_user["id"]),
            )
            await db.commit()
            raise HTTPException(status_code=409, detail="This assistant action has expired")
        if row["action_type"] not in {"calendar_event", "create_task", "shopping_item"}:
            raise HTTPException(
                status_code=409,
                detail="This type of assistant action cannot be edited",
            )
        if body.kind != row["action_type"]:
            raise HTTPException(
                status_code=422,
                detail="Action kind does not match the stored proposal",
            )

        changes = body.model_dump(exclude_unset=True)
        changes.pop("kind", None)
        if not changes:
            raise HTTPException(status_code=422, detail="Provide at least one field to update")

        payload = json.loads(row["payload"])
        merged = {**payload, **changes}
        required_field = {
            "calendar_event": "title",
            "create_task": "title",
            "shopping_item": "name",
        }[row["action_type"]]
        if not isinstance(merged.get(required_field), str) or not merged[required_field].strip():
            raise HTTPException(
                status_code=422,
                detail=f"{required_field.replace('_', ' ').title()} cannot be blank",
            )
        if row["action_type"] == "calendar_event" and not isinstance(merged.get("start_time"), str):
            raise HTTPException(status_code=422, detail="Start time is required")

        people = await load_family_people(db, current_user["family_id"])
        assignee = merged.get("assigned_to")
        if assignee and assignee not in {person["id"] for person in people}:
            raise HTTPException(
                status_code=422,
                detail="The selected assignee is not an active family member",
            )
        try:
            normalised = normalise_edited_action_payload(
                row["action_type"],
                merged,
                people=people,
            )
        except (TypeError, ValueError, ValidationError) as exc:
            raise HTTPException(
                status_code=422,
                detail="The proposed changes are invalid",
            ) from exc
        if not normalised:
            raise HTTPException(
                status_code=422,
                detail="The proposed changes contain an invalid date, recurrence, or value",
            )
        summary = edited_action_summary(row["action_type"], normalised, people)
        now = datetime.now(timezone.utc).isoformat()
        await db.execute("BEGIN IMMEDIATE")
        try:
            await save_history(
                db,
                "assistant_actions",
                action_id,
                current_user["id"],
                family_id=current_user["family_id"],
            )
            update = await db.execute(
                """
                UPDATE assistant_actions
                SET payload = ?, summary = ?, updated_at = ?
                WHERE id = ? AND family_id = ? AND created_by = ?
                  AND status = 'pending' AND updated_at = ?
                  AND payload = ? AND summary = ?
                """,
                (
                    json.dumps(normalised, separators=(",", ":")),
                    summary,
                    now,
                    action_id,
                    current_user["family_id"],
                    current_user["id"],
                    row["updated_at"],
                    row["payload"],
                    row["summary"],
                ),
            )
            if update.rowcount != 1:
                await db.rollback()
                raise HTTPException(
                    status_code=409,
                    detail="This assistant action changed while you were editing it",
                )
            await db.commit()
        except BaseException:
            if db.in_transaction:
                await db.rollback()
            raise
        updated = await _owned_action(db, action_id, current_user)
        return _action_response(updated)


@router.post("/actions/{action_id}/execute", response_model=AssistantActionResult)
async def execute_assistant_action(
    action_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Execute one server-stored action once, after an explicit user confirmation."""
    async with database_lease() as db:
        row = await _owned_action(db, action_id, current_user)
        if row["status"] == "executed":
            return _result(
                row,
                status="executed",
                message=_success_message(row),
                result_id=row["result_id"],
            )
        if row["status"] == "failed":
            return _result(row, status="failed", message=_failed_message(row))
        if row["status"] == "expired":
            return _result(row, status="expired", message=_expired_message(row))
        if row["status"] != "pending":
            raise HTTPException(
                status_code=409,
                detail="This assistant action has already been handled",
            )
        if _expired(row):
            now = datetime.now(timezone.utc).isoformat()
            expiry = await db.execute(
                "UPDATE assistant_actions SET status = 'expired', updated_at = ? "
                "WHERE id = ? AND family_id = ? AND created_by = ? "
                "AND status = 'pending'",
                (now, action_id, current_user["family_id"], current_user["id"]),
            )
            if expiry.rowcount != 1:
                await db.rollback()
                raise HTTPException(
                    status_code=409,
                    detail="This assistant action has already been handled",
                )
            await db.commit()
            return _result(row, status="expired", message=_expired_message(row))

        now = datetime.now(timezone.utc).isoformat()
        claim = await db.execute(
            """
            UPDATE assistant_actions
            SET status = 'executing', updated_at = ?
            WHERE id = ? AND family_id = ? AND created_by = ? AND status = 'pending'
            """,
            (now, action_id, current_user["family_id"], current_user["id"]),
        )
        if claim.rowcount != 1:
            await db.rollback()
            raise HTTPException(
                status_code=409,
                detail="This assistant action has already been handled",
            )
        await db.commit()
        # A PATCH may have committed after our initial read but before this claim.
        # Re-read the claimed row so execution always uses the latest accepted payload.
        cursor = await db.execute(
            "SELECT * FROM assistant_actions WHERE id = ? AND status = 'executing'",
            (action_id,),
        )
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(
                status_code=409,
                detail="This assistant action has already been handled",
            )

    result_id = None
    try:
        payload = json.loads(row["payload"])
        if row["action_type"] == "home_lights":
            await call_all_lights(
                family_id=current_user["family_id"],
                state=payload["state"],
            )
        else:
            async with database_lease() as db:
                if row["action_type"] == "calendar_event":
                    result_id = await create_calendar_event_from_action(
                        db,
                        payload=payload,
                        current_user=current_user,
                    )
                elif row["action_type"] == "create_task":
                    result_id = await create_task_from_action(
                        db,
                        payload=payload,
                        current_user=current_user,
                    )
                elif row["action_type"] == "complete_task":
                    result_id = await complete_task_from_action(
                        db,
                        payload=payload,
                        current_user=current_user,
                    )
                elif row["action_type"] == "shopping_item":
                    result_id = await create_shopping_item_from_action(
                        db,
                        payload=payload,
                        current_user=current_user,
                    )
                else:
                    raise ValueError("Unsupported assistant action")
                finished = datetime.now(timezone.utc).isoformat()
                await db.execute(
                    """
                    UPDATE assistant_actions
                    SET status = 'executed', executed_at = ?, result_id = ?, updated_at = ?
                    WHERE id = ? AND status = 'executing'
                    """,
                    (finished, result_id, finished, action_id),
                )
                await db.commit()
                return _result(
                    row,
                    status="executed",
                    message=_success_message(row),
                    result_id=result_id,
                )

        finished = datetime.now(timezone.utc).isoformat()
        async with database_lease() as db:
            await db.execute(
                """
                UPDATE assistant_actions
                SET status = 'executed', executed_at = ?, result_id = ?, updated_at = ?
                WHERE id = ? AND status = 'executing'
                """,
                (finished, result_id, finished, action_id),
            )
            await db.commit()
        return _result(
            row,
            status="executed",
            message=_success_message(row),
            result_id=result_id,
        )
    except Exception:
        failed_at = datetime.now(timezone.utc).isoformat()
        async with database_lease() as db:
            await db.execute(
                """
                UPDATE assistant_actions
                SET status = 'failed', error = ?, updated_at = ?
                WHERE id = ? AND status = 'executing'
                """,
                ("Execution failed", failed_at, action_id),
            )
            await db.commit()
        return _result(row, status="failed", message=_failed_message(row))


@router.post("/actions/{action_id}/decline", response_model=AssistantActionResult)
async def decline_assistant_action(
    action_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _owned_action(db, action_id, current_user)
    if row["status"] == "declined":
        message = "Aktion verworfen." if _action_language(row) == "de" else "Action dismissed."
        return _result(row, status="declined", message=message)
    if row["status"] != "pending":
        raise HTTPException(
            status_code=409, detail="This assistant action has already been handled"
        )
    now = datetime.now(timezone.utc).isoformat()
    decline = await db.execute(
        """
        UPDATE assistant_actions
        SET status = 'declined', updated_at = ?
        WHERE id = ? AND family_id = ? AND created_by = ? AND status = 'pending'
        """,
        (now, action_id, current_user["family_id"], current_user["id"]),
    )
    if decline.rowcount != 1:
        await db.rollback()
        raise HTTPException(
            status_code=409, detail="This assistant action has already been handled"
        )
    await db.commit()
    message = "Aktion verworfen." if _action_language(row) == "de" else "Action dismissed."
    return _result(row, status="declined", message=message)
