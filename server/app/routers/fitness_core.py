"""Owner-scoped Fitness settings, goals, phases and planning API."""

from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness import (
    CalendarPreferencesResponse,
    CalendarPreferencesUpdate,
    GoalPatch,
    GoalPayload,
    GoalRelationshipPayload,
    NutritionSettingsUpdate,
    PlannedSessionPayload,
    TrainingPhasePayload,
    TrainingProgrammePayload,
)
from app.models.fitness_next_action import FitnessNextAction
from app.models.fitness_quick_entry import (
    QuickEntryPreferencesResponse,
    QuickEntryPreferencesUpdate,
    StrengthAvailabilityResponse,
    StrengthBookingCreate,
    StrengthBookingResponse,
    ViBookingCreate,
    ViBookingResponse,
    ViScheduleResponse,
)
from app.models.fitness_experience import (
    FitnessOverviewResponse,
    FitnessTodayCardResponse,
)
from app.models.fitness_goal_templates import (
    GoalFromTemplateRequest,
    GoalFromTemplateResponse,
    GoalTemplateResponse,
)
from app.models.fitness_onboarding import (
    OnboardingConfirmRequest,
    OnboardingConfirmResponse,
    OnboardingDraftUpdate,
    OnboardingPreviewRequest,
    OnboardingProfileResponse,
    OnboardingWeekPreview,
)
from app.models.fitness_progress import FitnessProgressChartsResponse
from app.models.fitness_weekly_review import WeeklyReviewResponse
from app.models.fitness_workspace import (
    FitnessWorkspaceResponse,
    FitnessWorkspaceUpdate,
)
from app.models.facilities import WeightsRoomAvailability
from app.services.fitness import (
    goal_templates,
    onboarding,
    progress,
    templates,
    weekly_review,
    workspace,
)
from app.services.fitness.common import FitnessConflictError, FitnessNotFoundError
from app.services.fitness.experience import overview_for_user, today_card_for_user
from app.services.fitness.next_action import next_action_for_user
from app.services.fitness.quick_entry import (
    create_strength_booking,
    create_vi_booking,
    get_quick_entry_preferences,
    strength_availability,
    update_quick_entry_preferences,
    vi_schedule,
)
from app.services.idempotency import CreateReplayConflictError
from app.services.facilities import FACILITY_ZONE, weights_room_availability
from app.services.fitness.planning import (
    complete_goal,
    delete_goal_relationship,
    ensure_settings,
    get_calendar_preferences,
    list_goals,
    list_goal_relationships,
    list_phases,
    list_planned_sessions,
    patch_goal,
    progress_summary,
    today_summary,
    update_calendar_preferences,
    update_settings,
    upsert_goal,
    upsert_goal_relationship,
    upsert_phase,
    upsert_planned_session,
)

router = APIRouter()


def _raise_domain(exc: Exception) -> None:
    if isinstance(exc, FitnessNotFoundError):
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(exc, FitnessConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    raise exc


@router.get("/workspace", response_model=FitnessWorkspaceResponse)
async def get_fitness_workspace(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await workspace.get_workspace(db, user=current_user)
    await db.commit()
    return result


@router.patch("/workspace", response_model=FitnessWorkspaceResponse)
async def patch_fitness_workspace(
    body: FitnessWorkspaceUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await workspace.update_workspace(db, user=current_user, body=body)
    await db.commit()
    return result


@router.get("/today")
async def get_fitness_today(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await today_summary(db, user=current_user)
    await db.commit()
    return result


@router.get("/overview", response_model=FitnessOverviewResponse)
async def get_fitness_overview(
    day: date | None = Query(default=None, alias="date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await overview_for_user(db, user=current_user, day=day)
    await db.commit()
    return result


@router.get("/today-card", response_model=FitnessTodayCardResponse)
async def get_fitness_today_card(
    day: date | None = Query(default=None, alias="date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await today_card_for_user(db, user=current_user, day=day)
    await db.commit()
    return result


@router.get("/next-action", response_model=FitnessNextAction)
async def get_fitness_next_action(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await next_action_for_user(db, user=current_user)


@router.get("/weights-room-availability", response_model=WeightsRoomAvailability)
async def get_weights_room_availability(
    start: date | None = Query(default=None),
    end: date | None = Query(default=None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    range_start = start or datetime.now(FACILITY_ZONE).date()
    range_end = end or (range_start + timedelta(days=13))
    if range_end < range_start or (range_end - range_start).days > 119:
        raise HTTPException(status_code=422, detail="Weights-room range must be 120 days or fewer")
    return await weights_room_availability(
        db,
        user=current_user,
        start=range_start,
        end=range_end,
    )


@router.get(
    "/strength-availability",
    response_model=StrengthAvailabilityResponse,
)
async def get_strength_availability(
    start: date | None = Query(default=None),
    end: date | None = Query(default=None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    range_start = start or datetime.now(FACILITY_ZONE).date()
    range_end = end or (range_start + timedelta(days=13))
    try:
        return await strength_availability(
            db,
            user=current_user,
            start=range_start,
            end=range_end,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post(
    "/strength-bookings",
    response_model=StrengthBookingResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_fitness_strength_booking(
    body: StrengthBookingCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await create_strength_booking(
            db,
            user=current_user,
            booking=body,
        )
        await db.commit()
        return result
    except CreateReplayConflictError as exc:
        await db.rollback()
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        await db.rollback()
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get(
    "/vi-schedule",
    response_model=ViScheduleResponse,
)
async def get_vi_schedule(
    start: date | None = Query(default=None),
    end: date | None = Query(default=None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    range_start = start or datetime.now(FACILITY_ZONE).date()
    range_end = end or (range_start + timedelta(days=13))
    try:
        return await vi_schedule(
            db,
            user=current_user,
            start=range_start,
            end=range_end,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post(
    "/vi-bookings",
    response_model=ViBookingResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_fitness_vi_booking(
    body: ViBookingCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await create_vi_booking(
            db,
            user=current_user,
            booking=body,
        )
        await db.commit()
        return result
    except CreateReplayConflictError as exc:
        await db.rollback()
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        await db.rollback()
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get(
    "/quick-entry-preferences",
    response_model=QuickEntryPreferencesResponse,
)
async def get_fitness_quick_entry_preferences(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await get_quick_entry_preferences(db, user=current_user)
    await db.commit()
    return result


@router.patch(
    "/quick-entry-preferences",
    response_model=QuickEntryPreferencesResponse,
)
async def patch_fitness_quick_entry_preferences(
    body: QuickEntryPreferencesUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await update_quick_entry_preferences(
        db,
        user=current_user,
        body=body,
    )
    await db.commit()
    return result


@router.get("/progress")
async def get_fitness_progress(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await progress_summary(db, user=current_user)


@router.get("/progress/charts", response_model=FitnessProgressChartsResponse)
async def get_fitness_progress_charts(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await progress.progress_charts(db, user=current_user)


@router.get("/weekly-review", response_model=WeeklyReviewResponse)
async def get_fitness_weekly_review(
    week_start: date = Query(),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await weekly_review.weekly_review(
        db,
        user=current_user,
        week_start=week_start,
    )


@router.get("/calendar-preferences", response_model=CalendarPreferencesResponse)
async def get_fitness_calendar_preferences(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await get_calendar_preferences(db, user=current_user)


@router.patch("/calendar-preferences", response_model=CalendarPreferencesResponse)
async def patch_fitness_calendar_preferences(
    body: CalendarPreferencesUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await update_calendar_preferences(db, user=current_user, body=body)
    await db.commit()
    return result


@router.get("/onboarding", response_model=OnboardingProfileResponse)
async def get_fitness_onboarding(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await onboarding.get_profile(db, user=current_user)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.put("/onboarding", response_model=OnboardingProfileResponse)
async def save_fitness_onboarding(
    body: OnboardingDraftUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await onboarding.save_draft(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/onboarding/skip", response_model=OnboardingProfileResponse)
async def skip_fitness_onboarding(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await onboarding.skip_setup(db, user=current_user)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/onboarding/preview-week", response_model=OnboardingWeekPreview)
async def preview_fitness_onboarding_week(
    body: OnboardingPreviewRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await onboarding.preview_week(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/onboarding/confirm", response_model=OnboardingConfirmResponse)
async def confirm_fitness_onboarding_week(
    body: OnboardingConfirmRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await onboarding.confirm_week(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/nutrition/settings")
async def get_nutrition_settings(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await ensure_settings(db, user=current_user)


@router.patch("/nutrition/settings")
async def patch_nutrition_settings(
    body: NutritionSettingsUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await update_settings(db, user=current_user, body=body)
    await db.commit()
    return result


@router.get("/goals")
async def get_goals(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await list_goals(db, user=current_user)


@router.get("/goal-templates", response_model=list[GoalTemplateResponse])
async def get_goal_templates(
    _current_user: dict = Depends(get_current_user),
):
    return goal_templates.list_goal_templates()


@router.post(
    "/goals/from-template",
    response_model=GoalFromTemplateResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_goal_from_template(
    body: GoalFromTemplateRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await goal_templates.create_goal_from_template(
            db,
            user=current_user,
            body=body,
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/goals", status_code=status.HTTP_201_CREATED)
async def create_goal(
    body: GoalPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await upsert_goal(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.patch("/goals/{goal_id}")
async def update_goal(
    goal_id: str,
    body: GoalPatch,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await patch_goal(db, user=current_user, goal_id=goal_id, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/goals/{goal_id}/complete")
async def mark_goal_complete(
    goal_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await complete_goal(db, user=current_user, goal_id=goal_id)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/goal-relationships")
async def get_goal_relationships(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await list_goal_relationships(db, user=current_user)


@router.post("/goal-relationships", status_code=status.HTTP_201_CREATED)
async def create_goal_relationship(
    body: GoalRelationshipPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await upsert_goal_relationship(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.put("/goal-relationships/{relationship_id}")
async def replace_goal_relationship(
    relationship_id: str,
    body: GoalRelationshipPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await upsert_goal_relationship(
            db,
            user=current_user,
            body=body,
            record_id=relationship_id,
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.delete(
    "/goal-relationships/{relationship_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def remove_goal_relationship(
    relationship_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await delete_goal_relationship(db, user=current_user, relationship_id=relationship_id)
        await db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/phases")
async def get_phases(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await list_phases(db, user=current_user)


@router.post("/phases", status_code=status.HTTP_201_CREATED)
async def create_phase(
    body: TrainingPhasePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await upsert_phase(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.patch("/phases/{phase_id}")
async def update_phase(
    phase_id: str,
    body: TrainingPhasePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await upsert_phase(
            db,
            user=current_user,
            body=body,
            record_id=phase_id,
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/planned-sessions")
async def get_planned_sessions(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await list_planned_sessions(db, user=current_user)


@router.post("/planned-sessions", status_code=status.HTTP_201_CREATED)
async def create_planned_session(
    body: PlannedSessionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await upsert_planned_session(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.patch("/planned-sessions/{session_id}")
async def update_planned_session(
    session_id: str,
    body: PlannedSessionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await upsert_planned_session(
            db,
            user=current_user,
            body=body,
            record_id=session_id,
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/training-programmes")
async def get_training_programmes(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await templates.list_programmes(db, user=current_user)


@router.post("/training-programmes", status_code=status.HTTP_201_CREATED)
async def create_training_programme(
    body: TrainingProgrammePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await templates.upsert_programme(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.patch("/training-programmes/{programme_id}")
async def update_training_programme(
    programme_id: str,
    body: TrainingProgrammePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await templates.upsert_programme(
            db, user=current_user, body=body, record_id=programme_id
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)
