"""Authenticated account-setting updates for Finance."""

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.finance import FinanceAccountResponse
from app.models.finance_account_settings import FinanceAccountSettingsUpdate
from app.services.finance.account_settings import (
    FinanceAccountSettingsError,
    FinanceAccountSettingsNotFoundError,
    update_finance_account_settings,
)
from app.services.finance.foundation import FinanceAccessDeniedError, require_finance_access

router = APIRouter()


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


@router.patch("/accounts/{account_id}", response_model=FinanceAccountResponse)
async def patch_finance_account(
    account_id: str,
    body: FinanceAccountSettingsUpdate,
    space_id: str = Query(min_length=1, max_length=100),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await update_finance_account_settings(
            db,
            user=current_user,
            space_id=space_id,
            account_id=account_id,
            body=body,
        )
    except FinanceAccessDeniedError as exc:
        raise HTTPException(
            status_code=404,
            detail="Finance account or space not found",
        ) from exc
    except FinanceAccountSettingsNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Finance account not found") from exc
    except FinanceAccountSettingsError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
