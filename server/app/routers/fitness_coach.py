"""Explicit Fitness Coach requests and deterministic proposal decisions."""

from fastapi import APIRouter, Depends, HTTPException, Request

from app.auth import get_current_user
from app.config import settings
from app.database import database_lease, get_db
from app.middleware.rate_limit import RateLimiter
from app.models.fitness_coach import (
    CoachConversationCreate,
    CoachConversationDetail,
    CoachConversationResponse,
    CoachContextPreferencesResponse,
    CoachContextPreferencesUpdate,
    CoachFitnessReminderResponse,
    CoachHistoryTurn,
    CoachMessageRequest,
    CoachMessageResponse,
    CoachMemoryClearResponse,
    CoachMemoryCreate,
    CoachMemoryPatch,
    CoachMemoryResponse,
    CoachMemorySettingResponse,
    CoachMemorySettingUpdate,
    CoachProposalDecision,
    CoachProposalUndoDecision,
    CoachRecommendation,
    CoachRecommendationFeedback,
)
from app.models.fitness import CoachPreferencesUpdate
from app.services.ai_consent import require_ai_consent
from app.services.fitness import coach
from app.services.fitness import planning
from app.services.fitness.common import (
    FitnessConflictError,
    FitnessNotFoundError,
    new_id,
)
from app.services.hermes import (
    HermesBusyError,
    HermesUsageLimitError,
    ask_fitness_coach,
    fitness_coach_bridge_status,
)


router = APIRouter()
coach_rate_limiter = RateLimiter(
    max_attempts=settings.fitness_coach_rate_limit_requests,
    window_seconds=settings.fitness_coach_rate_limit_window_seconds,
)
INTENTS = [
    "discussion",
    "morning",
    "post_workout",
    "evening",
    "weekly",
    "run_plan",
    "strength_plan",
]


def _raise_domain(exc: Exception) -> None:
    if isinstance(exc, FitnessNotFoundError):
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(exc, FitnessConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    raise exc


@router.get("/coach/preferences")
async def coach_preferences(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    return await planning.get_coach_preferences(db, user=current_user)


@router.patch("/coach/preferences")
async def update_coach_preferences(
    body: CoachPreferencesUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await planning.update_coach_preferences(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get(
    "/coach/context-preferences",
    response_model=CoachContextPreferencesResponse,
)
async def coach_context_preferences(
    current_user: dict = Depends(get_current_user), db=Depends(get_db)
):
    return await coach.context_preferences(db, user=current_user)


@router.patch(
    "/coach/context-preferences",
    response_model=CoachContextPreferencesResponse,
)
async def update_coach_context_preferences(
    body: CoachContextPreferencesUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.update_context_preferences(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get(
    "/coach/reminders",
    response_model=list[CoachFitnessReminderResponse],
)
async def coach_fitness_reminders(
    current_user: dict = Depends(get_current_user), db=Depends(get_db)
):
    return await coach.list_fitness_reminders(db, user=current_user)


@router.delete("/coach/reminders/{reminder_id}", status_code=204)
async def delete_coach_fitness_reminder(
    reminder_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await coach.delete_fitness_reminder(db, user=current_user, reminder_id=reminder_id)
        await db.commit()
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/coach/memory/settings", response_model=CoachMemorySettingResponse)
async def coach_memory_setting(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    return await coach.memory_setting(db, user=current_user)


@router.put("/coach/memory/settings", response_model=CoachMemorySettingResponse)
async def update_coach_memory_setting(
    body: CoachMemorySettingUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.set_memory_enabled(db, user=current_user, enabled=body.enabled)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/coach/conversations", response_model=list[CoachConversationResponse])
async def coach_conversations(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    return await coach.list_conversations(db, user=current_user)


@router.post(
    "/coach/conversations",
    response_model=CoachConversationResponse,
    status_code=201,
)
async def create_coach_conversation(
    body: CoachConversationCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.create_conversation(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get(
    "/coach/conversations/{conversation_id}",
    response_model=CoachConversationDetail,
)
async def resume_coach_conversation(
    conversation_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await coach.conversation_detail(
            db, user=current_user, conversation_id=conversation_id
        )
    except Exception as exc:
        _raise_domain(exc)


@router.delete("/coach/conversations/{conversation_id}", status_code=204)
async def delete_coach_conversation(
    conversation_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await coach.delete_conversation(db, user=current_user, conversation_id=conversation_id)
        await db.commit()
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/coach/memories", response_model=list[CoachMemoryResponse])
async def coach_memories(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    return await coach.list_memories(db, user=current_user)


@router.post("/coach/memories", response_model=CoachMemoryResponse, status_code=201)
async def create_coach_memory(
    body: CoachMemoryCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.create_memory(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.patch("/coach/memories/{memory_id}", response_model=CoachMemoryResponse)
async def edit_coach_memory(
    memory_id: str,
    body: CoachMemoryPatch,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.patch_memory(db, user=current_user, memory_id=memory_id, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.delete("/coach/memories/{memory_id}", status_code=204)
async def forget_coach_memory(
    memory_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await coach.delete_memory(db, user=current_user, memory_id=memory_id)
        await db.commit()
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/coach/memory/clear", response_model=CoachMemoryClearResponse)
async def clear_coach_memory(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    try:
        result = await coach.clear_memory(db, user=current_user)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/coach/status")
async def coach_status(current_user: dict = Depends(get_current_user)):
    del current_user
    try:
        metadata = await fitness_coach_bridge_status()
    except (HermesBusyError, HermesUsageLimitError):
        metadata = None
    if metadata is None:
        return {
            "status": "unavailable",
            "provider": None,
            "model": None,
            "message": "Fitness coaching is temporarily unavailable; logging, plans and analysis still work.",
            "intents": INTENTS,
        }
    return {
        "status": "available",
        "provider": metadata["provider"],
        "model": metadata["model"],
        "message": None,
        "intents": INTENTS,
    }


@router.post("/coach/message", response_model=CoachMessageResponse)
async def coach_message(
    body: CoachMessageRequest,
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    del request
    require_ai_consent(current_user)
    rate_key = f"fitness-coach:{current_user['id']}"
    coach_rate_limiter.ensure_allowed(
        rate_key,
        detail_prefix="Too many Fitness Coach requests",  # gitleaks:allow
    )
    coach_rate_limiter.record_failure(rate_key)
    async with database_lease() as db:
        try:
            evidence = await coach.build_evidence(db, user=current_user, body=body)
            preferences = await planning.get_coach_preferences(db, user=current_user)
            memory_enabled = bool(preferences["coach_memory_enabled"])
            requested_conversation_id = str(body.conversation_id) if body.conversation_id else None
            if requested_conversation_id is not None:
                # Validate ownership even while memory is disabled so another user's
                # identifier is always indistinguishable from a missing record.
                await coach.owned_conversation(
                    db,
                    user=current_user,
                    conversation_id=requested_conversation_id,
                )
            retain_conversation = memory_enabled and not body.ephemeral
            if retain_conversation:
                conversation_id = requested_conversation_id or new_id()
                create_conversation = requested_conversation_id is None
                if requested_conversation_id:
                    history = [
                        CoachHistoryTurn.model_validate(turn)
                        for turn in await coach.conversation_history(
                            db,
                            user=current_user,
                            conversation_id=requested_conversation_id,
                        )
                    ]
                else:
                    history = []
                memories = await coach.relevant_memories(db, user=current_user, message=body.message)
            else:
                if requested_conversation_id is not None:
                    raise FitnessConflictError("Coach memory is not enabled")
                conversation_id = None
                create_conversation = False
                history = body.history
                memories = (
                    await coach.relevant_memories(db, user=current_user, message=body.message)
                    if memory_enabled
                    else []
                )
        except Exception as exc:
            if db.in_transaction:
                await db.rollback()
            _raise_domain(exc)

    # The pooled connection is fully released across the private bridge/model call.
    try:
        response = await ask_fitness_coach(
            message=body.message,
            intent=body.intent,
            history=history,
            memories=memories,
            timezone_name=body.timezone,
            client_now=body.client_now,
            context=coach.bridge_context(evidence, preferences=preferences),
        )
    except HermesUsageLimitError:
        response = None
        unavailable = "The Fitness coach has reached its provider usage limit for now."
    except HermesBusyError:
        response = None
        unavailable = "The Fitness coach is busy. Please try again in a moment."
    else:
        unavailable = "The Fitness coaching bridge is temporarily unavailable."
    if response is None:
        return CoachMessageResponse(
            status="unavailable",
            answer=unavailable,
            conversation_id=requested_conversation_id,
            memory_candidates=[],
            evidence=[],
            recommendation=None,
            proposal=None,
        )

    selected = [
        item
        for item in evidence
        if not response.evidence_ids or item["public"]["id"] in set(response.evidence_ids)
    ]
    proposal = None
    recommendation = None
    stored_conversation_id = None
    async with database_lease() as db:
        try:
            if retain_conversation and conversation_id is not None:
                stored_conversation_id = await coach.store_successful_exchange(
                    db,
                    user=current_user,
                    conversation_id=conversation_id,
                    create_if_missing=create_conversation,
                    user_message=body.message,
                    assistant_message=response.answer,
                    intent=body.intent,
                    provider=response.provider,
                    model=response.model,
                )
            if (
                not body.ephemeral
                and response.proposal
                and response.proposal.kind in coach.PROPOSAL_KINDS
            ):
                proposal = await coach.store_proposal(
                    db,
                    user=current_user,
                    kind=response.proposal.kind,
                    payload=response.proposal.payload,
                    evidence=selected,
                    provider=response.provider,
                    model=response.model,
                )
            if not body.ephemeral and response.recommendation:
                recommendation = await coach.store_recommendation(
                    db,
                    user=current_user,
                    recommendation_type=response.recommendation.recommendation_type,
                    text=response.recommendation.recommendation_text,
                    expected_effect=response.recommendation.expected_effect,
                    evidence=selected,
                    provider=response.provider,
                    model=response.model,
                    proposal_id=proposal["id"] if proposal else None,
                )
            await db.commit()
        except Exception:
            await db.rollback()
            raise
    return CoachMessageResponse(
        status="complete",
        answer=response.answer,
        conversation_id=stored_conversation_id,
        memory_candidates=(
            response.memory_candidates if stored_conversation_id is not None else []
        ),
        evidence=coach.public_evidence(selected),
        recommendation=recommendation,
        proposal=proposal,
    )


@router.get(
    "/coach/recommendations",
    response_model=list[CoachRecommendation],
)
async def coach_recommendations(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await coach.list_recommendations(db, user=current_user)


@router.post(
    "/coach/recommendations/{recommendation_id}/feedback",
    response_model=CoachRecommendation,
)
async def coach_recommendation_feedback(
    recommendation_id: str,
    body: CoachRecommendationFeedback,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.record_feedback(
            db,
            user=current_user,
            recommendation_id=recommendation_id,
            body=body,
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post(
    "/coach/proposals/{proposal_id}/confirm",
    response_model=CoachProposalDecision,
)
async def confirm_coach_proposal(
    proposal_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.confirm_proposal(db, user=current_user, proposal_id=proposal_id)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post(
    "/coach/proposals/{proposal_id}/undo",
    response_model=CoachProposalUndoDecision,
)
async def undo_coach_proposal(
    proposal_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.undo_proposal(db, user=current_user, proposal_id=proposal_id)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post(
    "/coach/proposals/{proposal_id}/decline",
    response_model=CoachProposalDecision,
)
async def decline_coach_proposal(
    proposal_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await coach.decline_proposal(db, user=current_user, proposal_id=proposal_id)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)
