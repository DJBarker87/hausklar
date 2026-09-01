"""Adult-only purchase understanding and bounded saved-record analysis routes."""

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.finance_understanding import (
    FinanceAnalysisRequest,
    FinanceAnalysisResponse,
    FinanceEvidenceHandleResponse,
    FinancePurchaseLineAssessmentResponse,
    FinancePurchaseLineAssessmentConfirm,
    FinancePurchaseLineAssessmentUpdate,
    FinancePurchaseReviewItemResponse,
    FinanceSavedAnalysisViewResponse,
)
from app.services.finance.foundation import FinanceAccessDeniedError, require_finance_access
from app.services.finance.understanding import (
    FinanceUnderstandingError,
    FinanceUnderstandingNotFoundError,
    list_high_impact_purchase_review,
    list_saved_analysis_views,
    read_analysis_evidence,
    read_purchase_line_assessment,
    run_saved_finance_analysis,
    update_purchase_line_assessment,
    confirm_purchase_line_assessment,
)

router = APIRouter()


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        # Finance entitlement is deliberately adult-only; children have no
        # family account and cannot enter these service boundaries.
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


def _understanding_error(exc: FinanceUnderstandingError) -> HTTPException:
    if isinstance(exc, FinanceUnderstandingNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


@router.get(
    "/purchase-lines/{line_id}/assessment",
    response_model=FinancePurchaseLineAssessmentResponse,
)
async def get_purchase_line_assessment(
    line_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await read_purchase_line_assessment(db, user=current_user, line_id=line_id)
    except FinanceUnderstandingError as exc:
        raise _understanding_error(exc) from exc


@router.put(
    "/purchase-lines/{line_id}/assessment",
    response_model=FinancePurchaseLineAssessmentResponse,
)
async def put_purchase_line_assessment(
    line_id: str,
    body: FinancePurchaseLineAssessmentUpdate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await update_purchase_line_assessment(
            db, user=current_user, line_id=line_id, body=body
        )
    except FinanceUnderstandingError as exc:
        raise _understanding_error(exc) from exc


@router.post(
    "/purchase-lines/{line_id}/assessment/confirm",
    response_model=FinancePurchaseLineAssessmentResponse,
)
async def confirm_purchase_line_review(
    line_id: str,
    body: FinancePurchaseLineAssessmentConfirm,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await confirm_purchase_line_assessment(
            db, user=current_user, line_id=line_id, body=body
        )
    except FinanceUnderstandingError as exc:
        raise _understanding_error(exc) from exc


@router.get(
    "/purchases/review/high-impact",
    response_model=list[FinancePurchaseReviewItemResponse],
)
async def get_high_impact_purchase_review(
    space_id: str = Query(min_length=1, max_length=100),
    minimum_impact_minor: int = Query(10_000, ge=1, le=1_000_000_000_000),
    limit: int = Query(50, ge=1, le=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_high_impact_purchase_review(
            db,
            user=current_user,
            space_id=space_id,
            minimum_impact_minor=minimum_impact_minor,
            limit=limit,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.post("/analysis", response_model=FinanceAnalysisResponse)
async def post_finance_analysis(
    body: FinanceAnalysisRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await run_saved_finance_analysis(db, user=current_user, body=body)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc
    except FinanceUnderstandingError as exc:
        raise _understanding_error(exc) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get(
    "/analysis/views",
    response_model=list[FinanceSavedAnalysisViewResponse],
)
async def get_saved_finance_analysis_views(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_saved_analysis_views(db, user=current_user, space_id=space_id)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=404, detail="Finance space is not available") from exc


@router.get(
    "/analysis/evidence/{kind}/{record_id}",
    response_model=FinanceEvidenceHandleResponse,
)
async def get_finance_analysis_evidence(
    kind: str,
    record_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await read_analysis_evidence(
            db, user=current_user, kind=kind, record_id=record_id
        )
    except FinanceUnderstandingError as exc:
        raise HTTPException(status_code=404, detail="Finance analysis evidence not found") from exc
