"""Authenticated multipart endpoints for manual Finance statement repair."""

from typing import Literal

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from pydantic import ValidationError

from app.auth import get_current_user
from app.database import get_db
from app.models.finance import FinanceImportResult
from app.models.finance_import import (
    FinanceImportIssueResponse,
    FinanceImportPreviewResponse,
    FinanceImportRepairResponse,
    FinanceImportSampleRow,
    FinanceImportSettings,
)
from app.services.finance.foundation import FinanceAccessDeniedError, require_finance_access
from app.services.finance.ledger import (
    FinanceImportConflictError,
    FinanceLedgerError,
    FinanceRecordNotFoundError,
)
from app.services.finance.manual_import import MAX_IMPORT_BYTES, ManualImportInputError
from app.services.finance.manual_import_workflow import (
    ManualImportAccountNotFoundError,
    ManualImportChangedError,
    ManualImportWorkflowError,
    confirm_manual_import,
    prepare_manual_import,
)
from app.services.finance.resource_limits import (
    finance_process_slot,
    reserve_finance_resource,
)

router = APIRouter()
MAX_PREVIEW_ISSUES = 50
MAX_PREVIEW_SAMPLE_ROWS = 10


def _finance_user(current_user: dict = Depends(get_current_user)) -> dict:
    try:
        require_finance_access(current_user)
    except FinanceAccessDeniedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return current_user


def _import_settings(
    source_kind: Literal["CSV", "OFX"] = Form(...),
    space_id: str = Form(..., min_length=1, max_length=100),
    account_id: str = Form(..., min_length=1, max_length=200),
    currency: str = Form(..., min_length=3, max_length=3),
    confirmed: bool = Form(...),
    sign_convention: Literal["DEBIT_NEGATIVE", "DEBIT_POSITIVE"] | None = Form(None),
    csv_date_format: Literal["%d/%m/%Y", "%Y-%m-%d"] | None = Form(None),
    csv_delimiter: Literal[",", ";", "\t"] | None = Form(None),
    csv_encoding: Literal["utf-8", "utf-8-sig"] | None = Form(None),
    csv_booking_date_column: str | None = Form(None, max_length=120),
    csv_amount_column: str | None = Form(None, max_length=120),
    csv_description_column: str | None = Form(None, max_length=120),
    csv_currency_column: str | None = Form(None, max_length=120),
    csv_transaction_id_column: str | None = Form(None, max_length=120),
    csv_value_date_column: str | None = Form(None, max_length=120),
    csv_status_column: str | None = Form(None, max_length=120),
) -> FinanceImportSettings:
    try:
        return FinanceImportSettings(
            source_kind=source_kind,
            space_id=space_id,
            account_id=account_id,
            currency=currency,
            confirmed=confirmed,
            sign_convention=sign_convention,
            csv_date_format=csv_date_format,
            csv_delimiter=csv_delimiter,
            csv_encoding=csv_encoding,
            csv_booking_date_column=csv_booking_date_column,
            csv_amount_column=csv_amount_column,
            csv_description_column=csv_description_column,
            csv_currency_column=csv_currency_column,
            csv_transaction_id_column=csv_transaction_id_column,
            csv_value_date_column=csv_value_date_column,
            csv_status_column=csv_status_column,
        )
    except ValidationError as exc:
        raise HTTPException(status_code=422, detail="Invalid manual import settings") from exc


async def _read_upload(file: UploadFile) -> bytes:
    try:
        payload = await file.read(MAX_IMPORT_BYTES + 1)
    finally:
        await file.close()
    if len(payload) > MAX_IMPORT_BYTES:
        raise HTTPException(status_code=413, detail="Manual import file is too large")
    return payload


def _workflow_error(exc: Exception) -> HTTPException:
    if isinstance(exc, (FinanceAccessDeniedError, ManualImportAccountNotFoundError)):
        return HTTPException(status_code=404, detail="Finance account or space not found")
    if isinstance(exc, ManualImportChangedError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, FinanceImportConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, FinanceRecordNotFoundError):
        return HTTPException(status_code=404, detail="Finance account or space not found")
    return HTTPException(status_code=422, detail=str(exc))


def _preview_response(settings: FinanceImportSettings, prepared) -> FinanceImportPreviewResponse:
    preview = prepared.preview
    dates = [record.transaction.booking_date for record in preview.records]
    issues = preview.issues[:MAX_PREVIEW_ISSUES]
    samples = preview.records[:MAX_PREVIEW_SAMPLE_ROWS]
    return FinanceImportPreviewResponse(
        batch_id=preview.batch_id,
        source_kind=preview.source_kind,
        space_id=settings.space_id,
        account_id=preview.account_id,
        currency=preview.currency,
        total_rows=preview.total_rows,
        importable_rows=len(preview.records),
        invalid_rows=preview.invalid_rows,
        duplicate_rows=preview.duplicate_rows,
        can_confirm=preview.can_commit,
        date_from=min(dates) if dates else None,
        date_to=max(dates) if dates else None,
        issue_count=len(preview.issues),
        issues_truncated=len(preview.issues) > MAX_PREVIEW_ISSUES,
        issues=[
            FinanceImportIssueResponse(
                row_number=issue.row_number,
                code=issue.code,
                message=issue.message,
                severity=issue.severity,
            )
            for issue in issues
        ],
        sample_rows=[
            FinanceImportSampleRow(
                row_number=record.row_number,
                booking_date=record.transaction.booking_date,
                value_date=record.transaction.value_date,
                amount_minor=record.transaction.amount_minor,
                currency=record.transaction.currency,
                description=record.transaction.description,
                source_transaction_id=record.transaction.source_transaction_id,
            )
            for record in samples
        ],
        repair=FinanceImportRepairResponse(
            relationship=prepared.repair.relationship,
            imported_start=prepared.repair.imported_start,
            imported_end=prepared.repair.imported_end,
            existing_start=prepared.repair.existing_start,
            existing_end=prepared.repair.existing_end,
            gap_start=prepared.repair.gap_start,
            gap_end=prepared.repair.gap_end,
            overlap_start=prepared.repair.overlap_start,
            overlap_end=prepared.repair.overlap_end,
        ),
    )


@router.post("/imports/preview", response_model=FinanceImportPreviewResponse)
async def preview_finance_import(
    file: UploadFile = File(...),
    settings: FinanceImportSettings = Depends(_import_settings),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    with finance_process_slot(user=current_user, kind="upload"):
        await reserve_finance_resource(db, user=current_user, kind="upload")
        payload = await _read_upload(file)
        try:
            prepared = await prepare_manual_import(
                db,
                user=current_user,
                settings=settings,
                payload=payload,
            )
        except (
            FinanceAccessDeniedError,
            ManualImportInputError,
            ManualImportWorkflowError,
        ) as exc:
            raise _workflow_error(exc) from exc
    return _preview_response(settings, prepared)


@router.post("/imports/confirm", response_model=FinanceImportResult)
async def confirm_finance_import(
    file: UploadFile = File(...),
    preview_batch_id: str = Form(..., min_length=1, max_length=200),
    settings: FinanceImportSettings = Depends(_import_settings),
    current_user: dict = Depends(_finance_user),
    db=Depends(get_db),
):
    with finance_process_slot(user=current_user, kind="upload"):
        await reserve_finance_resource(db, user=current_user, kind="upload")
        payload = await _read_upload(file)
        try:
            return await confirm_manual_import(
                db,
                user=current_user,
                settings=settings,
                payload=payload,
                expected_batch_id=preview_batch_id,
            )
        except (
            FinanceAccessDeniedError,
            FinanceLedgerError,
            ManualImportInputError,
            ManualImportWorkflowError,
        ) as exc:
            raise _workflow_error(exc) from exc
