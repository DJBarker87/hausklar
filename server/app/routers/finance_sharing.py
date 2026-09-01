from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.finance_sharing import (
    FinanceContributionCreate,
    FinanceContributionResponse,
    FinancePurchaseShareCreate,
    FinanceSharePreviewRequest,
    FinanceSharePreviewResponse,
    FinanceShareResponse,
    FinanceShareRuleCreate,
)
from app.services.finance.foundation import FinanceAccessDeniedError, require_finance_access
from app.services.finance.sharing import (
    FinanceSharingConflictError,
    FinanceSharingError,
    FinanceSharingNotFoundError,
    create_share_rule,
    declare_contribution,
    list_contributions,
    list_share_actions,
    preview_share,
    replace_shared_version,
    share_account,
    share_planning_record,
    share_purchase,
    share_transaction,
    stop_share_action,
)


router = APIRouter()


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


def _sharing_error(exc: FinanceSharingError) -> HTTPException:
    if isinstance(exc, FinanceSharingNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, FinanceSharingConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=422, detail=str(exc))


@router.get("/shares", response_model=list[FinanceShareResponse])
async def read_share_history(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    """List only the caller's share actions; private source IDs are omitted."""
    return await list_share_actions(db, user=current_user)


@router.post("/shares/preview", response_model=FinanceSharePreviewResponse)
async def preview_finance_share(
    body: FinanceSharePreviewRequest,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await preview_share(db, user=current_user, body=body)
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/shares/accounts/{account_id}", response_model=FinanceShareResponse)
async def create_account_share(
    account_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await share_account(db, user=current_user, account_id=account_id)
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/shares/transactions/{transaction_id}", response_model=FinanceShareResponse)
async def create_transaction_share(
    transaction_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await share_transaction(db, user=current_user, transaction_id=transaction_id)
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/shares/purchases/{purchase_id}", response_model=FinanceShareResponse)
async def create_purchase_share(
    purchase_id: str,
    body: FinancePurchaseShareCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await share_purchase(
            db, user=current_user, purchase_id=purchase_id, body=body
        )
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/shares/commitments/{commitment_id}", response_model=FinanceShareResponse)
async def create_commitment_share(
    commitment_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await share_planning_record(
            db, user=current_user, record_type="commitment", record_id=commitment_id
        )
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/shares/goals/{goal_id}", response_model=FinanceShareResponse)
async def create_goal_share(
    goal_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await share_planning_record(
            db, user=current_user, record_type="goal", record_id=goal_id
        )
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/shares/contributions", response_model=FinanceShareResponse)
async def create_contribution_share(
    body: FinanceContributionCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await declare_contribution(db, user=current_user, body=body)
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.get("/contributions", response_model=list[FinanceContributionResponse])
async def read_contributions(
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_contributions(db, user=current_user, space_id=space_id)
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/share-rules", response_model=FinanceShareResponse)
async def create_future_share_rule(
    body: FinanceShareRuleCreate,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await create_share_rule(db, user=current_user, body=body)
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/shares/{share_id}/stop", response_model=FinanceShareResponse)
async def stop_future_share(
    share_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await stop_share_action(db, user=current_user, share_id=share_id)
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc


@router.post("/shares/{share_id}/replace", response_model=FinanceShareResponse)
async def replace_one_off_shared_version(
    share_id: str,
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await replace_shared_version(db, user=current_user, share_id=share_id)
    except FinanceSharingError as exc:
        raise _sharing_error(exc) from exc
