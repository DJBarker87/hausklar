"""Authenticated routes for saved deterministic Finance coaching loops."""

from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.finance_coaching import (
    FinanceCoachingReportResponse,
    FinanceHabitCreate,
    FinanceHabitResponse,
    FinanceHabitReview,
    FinancePaydayActionCreate,
    FinancePaydayActionResolve,
    FinancePaydayActionResponse,
    FinancePlanGenerate,
    FinancePlanResponse,
    FinancePlanSetResponse,
    FinancePurchaseApprove,
    FinancePurchaseEvaluationRequest,
    FinancePurchaseEvaluationResponse,
    FinancePurchaseProposalCreate,
    FinancePurchaseProposalResponse,
    FinanceReportPreferenceResponse,
    FinanceReportPreferenceUpdate,
)
from app.services.finance.coaching import (
    FinanceCoachingConflictError,
    FinanceCoachingError,
    FinanceCoachingNotFoundError,
    activate_plan,
    approve_purchase_proposal,
    create_habit,
    create_payday_action,
    create_purchase_proposal,
    evaluate_purchase_proposal,
    generate_plan_strategies,
    get_report_preference,
    list_coaching_reports,
    list_habits,
    list_payday_actions,
    list_plans,
    list_purchase_proposals,
    match_payday_actions,
    measure_habit,
    refresh_coaching_report,
    refresh_drift_monitor,
    resolve_payday_action,
    review_habit,
    set_report_preference,
)
from app.services.finance.foundation import FinanceAccessDeniedError, require_finance_access

router = APIRouter()
ReportKind = Literal["DAILY", "DRIFT", "WEEKLY", "MONTHLY"]


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


def _coaching_error(exc: Exception) -> HTTPException:
    if isinstance(exc, (FinanceCoachingNotFoundError, FinanceAccessDeniedError)):
        return HTTPException(status_code=404, detail="Finance record is not available")
    if isinstance(exc, FinanceCoachingConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


@router.post("/plans/generate", response_model=FinancePlanSetResponse)
async def post_plan_generation(
    body: FinancePlanGenerate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await generate_plan_strategies(
            db, user=current_user, space_id=space_id, body=body
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.get("/plans", response_model=list[FinancePlanResponse])
async def get_plans(
    space_id: str = Query(min_length=1, max_length=100),
    include_inactive: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_plans(
            db,
            user=current_user,
            space_id=space_id,
            include_inactive=include_inactive,
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/plans/{plan_id}/activate", response_model=FinancePlanResponse)
async def post_plan_activation(
    plan_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await activate_plan(db, user=current_user, plan_id=plan_id)
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/payday-actions", response_model=FinancePaydayActionResponse)
async def post_payday_action(
    body: FinancePaydayActionCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_payday_action(db, user=current_user, body=body)
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.get("/payday-actions", response_model=list[FinancePaydayActionResponse])
async def get_payday_actions(
    space_id: str = Query(min_length=1, max_length=100),
    include_resolved: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_payday_actions(
            db,
            user=current_user,
            space_id=space_id,
            include_resolved=include_resolved,
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/payday-actions/match", response_model=list[FinancePaydayActionResponse])
async def post_payday_action_match(
    space_id: str = Query(min_length=1, max_length=100),
    as_of: date | None = None,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await match_payday_actions(
            db, user=current_user, space_id=space_id, as_of=as_of
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post(
    "/payday-actions/{action_id}/resolve",
    response_model=FinancePaydayActionResponse,
)
async def post_payday_action_resolution(
    action_id: str,
    body: FinancePaydayActionResolve,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await resolve_payday_action(
            db, user=current_user, action_id=action_id, body=body
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/habits", response_model=FinanceHabitResponse)
async def post_habit(
    body: FinanceHabitCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_habit(db, user=current_user, space_id=space_id, body=body)
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.get("/habits", response_model=list[FinanceHabitResponse])
async def get_habits(
    space_id: str = Query(min_length=1, max_length=100),
    include_inactive: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_habits(
            db,
            user=current_user,
            space_id=space_id,
            include_inactive=include_inactive,
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/habits/{habit_id}/measure", response_model=FinanceHabitResponse)
async def post_habit_measurement(
    habit_id: str,
    as_of: date | None = None,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await measure_habit(
            db, user=current_user, habit_id=habit_id, as_of=as_of
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/habits/{habit_id}/review", response_model=FinanceHabitResponse)
async def post_habit_review(
    habit_id: str,
    body: FinanceHabitReview,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await review_habit(db, user=current_user, habit_id=habit_id, body=body)
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/proposals", response_model=FinancePurchaseProposalResponse)
async def post_purchase_proposal(
    body: FinancePurchaseProposalCreate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_purchase_proposal(
            db, user=current_user, space_id=space_id, body=body
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.get("/proposals", response_model=list[FinancePurchaseProposalResponse])
async def get_purchase_proposals(
    space_id: str = Query(min_length=1, max_length=100),
    include_resolved: bool = False,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_purchase_proposals(
            db,
            user=current_user,
            space_id=space_id,
            include_resolved=include_resolved,
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post(
    "/proposals/{proposal_id}/evaluate",
    response_model=FinancePurchaseEvaluationResponse,
)
async def post_purchase_evaluation(
    proposal_id: str,
    body: FinancePurchaseEvaluationRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await evaluate_purchase_proposal(
            db, user=current_user, proposal_id=proposal_id, body=body
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/proposals/{proposal_id}/approve", response_model=FinancePurchaseProposalResponse)
async def post_purchase_approval(
    proposal_id: str,
    body: FinancePurchaseApprove,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await approve_purchase_proposal(
            db, user=current_user, proposal_id=proposal_id, body=body
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.put("/report-preferences", response_model=FinanceReportPreferenceResponse)
async def put_report_preference(
    body: FinanceReportPreferenceUpdate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await set_report_preference(
            db, user=current_user, space_id=space_id, body=body
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.get("/report-preferences", response_model=FinanceReportPreferenceResponse)
async def get_saved_report_preference(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await get_report_preference(
            db, user=current_user, space_id=space_id
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.get("/reports", response_model=list[FinanceCoachingReportResponse])
async def get_coaching_reports(
    space_id: str = Query(min_length=1, max_length=100),
    report_kind: ReportKind | None = None,
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_coaching_reports(
            db,
            user=current_user,
            space_id=space_id,
            report_kind=report_kind,
            limit=limit,
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post("/reports/{report_kind}/refresh", response_model=FinanceCoachingReportResponse)
async def post_coaching_report_refresh(
    report_kind: ReportKind,
    space_id: str = Query(min_length=1, max_length=100),
    as_of: date | None = None,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await refresh_coaching_report(
            db,
            user=current_user,
            space_id=space_id,
            report_kind=report_kind,
            as_of=as_of,
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc


@router.post(
    "/monitoring/recalculate",
    response_model=FinanceCoachingReportResponse | None,
)
async def post_drift_recalculation(
    space_id: str = Query(min_length=1, max_length=100),
    as_of: date | None = None,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await refresh_drift_monitor(
            db, user=current_user, space_id=space_id, as_of=as_of
        )
    except (FinanceCoachingError, FinanceAccessDeniedError) as exc:
        raise _coaching_error(exc) from exc
