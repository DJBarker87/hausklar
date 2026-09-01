"""Authenticated Finance export and user-visible history."""

from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse

from app.auth import get_current_user
from app.database import get_db
from app.models.finance_data_control import FinanceHistoryPageResponse
from app.services.finance.data_control import (
    FinanceExportTooLargeError,
    build_finance_export,
    list_finance_history,
)
from app.services.finance.foundation import (
    FinanceAccessDeniedError,
    FinanceScopeError,
    require_finance_access,
)
from app.services.finance.resource_limits import (
    finance_process_slot,
    reserve_finance_resource,
)

router = APIRouter()


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    return current_user


@router.get("/history", response_model=FinanceHistoryPageResponse)
async def read_finance_history(
    scope: Literal["mine", "household"] = "mine",
    offset: int = Query(0, ge=0, le=1_000_000),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        return await list_finance_history(
            db,
            user=current_user,
            scope=scope,
            offset=offset,
            limit=limit,
        )
    except FinanceScopeError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/export")
async def export_finance_data(
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    try:
        with finance_process_slot(user=current_user, kind="export"):
            await reserve_finance_resource(db, user=current_user, kind="export")
            archive = await build_finance_export(db, user=current_user)
    except FinanceExportTooLargeError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc

    def chunks():
        try:
            while chunk := archive.read(256 * 1024):
                yield chunk
        finally:
            archive.close()

    filename = f"hausklar-finance-export-{datetime.now(timezone.utc).date().isoformat()}.zip"
    return StreamingResponse(
        chunks(),
        media_type="application/zip",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Cache-Control": "private, no-store",
        },
    )
