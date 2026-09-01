"""Toast Club booking-form review and pickup-window projections."""

from __future__ import annotations

import re

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.middleware.rate_limit import reserve_persistent_attempts
from app.models.toast_club import ToastImportPreview, ToastImportResult, ToastImportStatus
from app.services import toast_club
from app.services.documents import safe_filename


router = APIRouter()
_SHA256 = re.compile(r"^[a-f0-9]{64}$")


async def _read_form(file: UploadFile) -> tuple[bytes, str]:
    filename = safe_filename(file.filename)
    if not filename.lower().endswith(".docx"):
        raise HTTPException(status_code=422, detail="Choose the Toast booking form as a .docx file")
    chunks: list[bytes] = []
    total = 0
    await file.seek(0)
    while chunk := await file.read(1024 * 1024):
        total += len(chunk)
        if total > settings.document_max_upload_bytes:
            raise HTTPException(
                status_code=413,
                detail=(
                    "Booking form exceeds the "
                    f"{settings.document_max_upload_bytes // (1024 * 1024)} MB upload limit"
                ),
            )
        chunks.append(chunk)
    if not chunks:
        raise HTTPException(status_code=422, detail="The uploaded booking form is empty")
    return b"".join(chunks), filename


def _parse(data: bytes, filename: str):
    try:
        return toast_club.parse_booking_form(data, filename=filename)
    except toast_club.ToastImportError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/status", response_model=list[ToastImportStatus])
async def get_toast_status(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await toast_club.import_status(db, family_id=current_user["family_id"])


@router.post("/preview", response_model=ToastImportPreview)
async def preview_toast_booking_form(
    file: UploadFile = File(...),
    child_id: str | None = Form(None, max_length=100),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        data, filename = await _read_form(file)
        schedule = _parse(data, filename)
        try:
            return await toast_club.import_preview(
                db,
                family_id=current_user["family_id"],
                schedule=schedule,
                requested_child_id=child_id,
            )
        except toast_club.ToastImportError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
    finally:
        await file.close()


@router.post(
    "/import",
    response_model=ToastImportResult,
    status_code=status.HTTP_201_CREATED,
)
async def import_toast_booking_form(
    file: UploadFile = File(...),
    expected_sha256: str = Form(..., min_length=64, max_length=64),
    child_id: str | None = Form(None, max_length=100),
    client_id: str | None = Form(None, max_length=200),
    client_timestamp: str | None = Form(None, max_length=64),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if not _SHA256.fullmatch(expected_sha256):
        raise HTTPException(status_code=422, detail="expected_sha256 must be a SHA-256 digest")
    await reserve_persistent_attempts(
        db,
        [
            (
                f"toast-import:{current_user['family_id']}",
                settings.document_upload_rate_limit_requests,
                3_600,
            )
        ],
        detail_prefix="Too many Toast form imports",
    )
    try:
        data, filename = await _read_form(file)
        schedule = _parse(data, filename)
        if schedule.sha256 != expected_sha256:
            raise HTTPException(
                status_code=409,
                detail="The booking form changed after review. Preview it again",
            )
        try:
            return await toast_club.confirm_import(
                db,
                current_user=current_user,
                schedule=schedule,
                expected_sha256=expected_sha256,
                requested_child_id=child_id,
                client_id=client_id,
                client_timestamp=client_timestamp,
            )
        except toast_club.ToastImportError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
    finally:
        await file.close()
