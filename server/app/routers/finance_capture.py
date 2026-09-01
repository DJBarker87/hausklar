"""Creator-bound Finance text capture and confirmation routes."""

from fastapi import APIRouter, Depends, HTTPException, status

from app.auth import get_current_user
from app.database import get_db
from app.models.finance_capture import (
    FinanceCaptureConfirmRequest,
    FinanceCaptureConfirmResponse,
    FinanceCaptureInterpretRequest,
    FinanceCaptureInterpretResponse,
)
from app.services.finance.capture import (
    FinanceCaptureConflictError,
    FinanceCaptureError,
    FinanceCaptureNotFoundError,
    confirm_finance_capture,
    interpret_finance_capture,
)
from app.services.finance.foundation import FinanceAccessDeniedError, require_finance_access
from app.services.finance.resource_limits import (
    finance_process_slot,
    reserve_finance_resource,
)

router = APIRouter()


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


def _capture_error(exc: FinanceCaptureError) -> HTTPException:
    if isinstance(exc, FinanceCaptureNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinanceCaptureConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


@router.post("/capture/interpret", response_model=FinanceCaptureInterpretResponse)
async def post_finance_capture_interpretation(
    body: FinanceCaptureInterpretRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        with finance_process_slot(user=current_user, kind="capture"):
            await reserve_finance_resource(db, user=current_user, kind="capture")
            return await interpret_finance_capture(db, user=current_user, body=body)
    except (FinanceCaptureError, FinanceAccessDeniedError) as exc:
        if isinstance(exc, FinanceAccessDeniedError):
            raise HTTPException(status_code=404, detail="Finance space is not available") from exc
        raise _capture_error(exc) from exc

@router.post(
    "/capture/{draft_id}/confirm",
    response_model=FinanceCaptureConfirmResponse,
)
async def post_finance_capture_confirmation(
    draft_id: str,
    body: FinanceCaptureConfirmRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await confirm_finance_capture(
            db, user=current_user, draft_id=draft_id, body=body
        )
    except (FinanceCaptureError, FinanceAccessDeniedError) as exc:
        if isinstance(exc, FinanceAccessDeniedError):
            raise HTTPException(status_code=404, detail="Finance review card not found") from exc
        raise _capture_error(exc) from exc
