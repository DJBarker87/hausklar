"""Authenticated Example School timetable import and read-only facility projections."""

from __future__ import annotations

import re
import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Request, UploadFile, status

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.middleware.rate_limit import reserve_persistent_attempts
from app.models.facilities import (
    FacilityCalendarLayerItem,
    FacilityCalendarPreferenceResponse,
    FacilityCalendarPreferenceUpdate,
    FacilityDaySummary,
    FacilityImportPreview,
    FacilityImportResult,
    FacilityQuickFact,
    FacilitySwimmingBookingCreate,
    FacilitySwimmingBookingResponse,
    FacilityWeightsBookingCreate,
    FacilityWeightsBookingResponse,
)
from app.services.idempotency import CreateReplayConflictError
from app.services import facilities
from app.services.adoption import (
    CompletedAction,
    record_completed_actions_in_db,
    safe_client_metadata,
)
from app.services.documents import (
    DocumentStorageError,
    family_document_storage_bytes,
    remove_new_upload,
    safe_filename,
    store_bytes,
)


router = APIRouter()
_SHA256 = re.compile(r"^[a-f0-9]{64}$")


async def _read_docx(file: UploadFile) -> tuple[bytes, str]:
    filename = safe_filename(file.filename)
    if not filename.lower().endswith(".docx"):
        raise HTTPException(status_code=422, detail="Choose the Example School timetable as a .docx file")
    chunks: list[bytes] = []
    total = 0
    await file.seek(0)
    while chunk := await file.read(1024 * 1024):
        total += len(chunk)
        if total > settings.document_max_upload_bytes:
            raise HTTPException(
                status_code=413,
                detail=(
                    f"Timetable exceeds the "
                    f"{settings.document_max_upload_bytes // (1024 * 1024)} MB upload limit"
                ),
            )
        chunks.append(chunk)
    if not chunks:
        raise HTTPException(status_code=422, detail="The uploaded timetable is empty")
    return b"".join(chunks), filename


def _parse(data: bytes, *, filename: str, year: int | None):
    try:
        return facilities.parse_example_school_timetable(data, filename=filename, year=year)
    except facilities.FacilityImportError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post("/example_school/preview", response_model=FacilityImportPreview)
async def preview_example_school_timetable(
    file: UploadFile = File(...),
    year: int | None = Form(None, ge=2000, le=2100),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Parse a timetable without storing the file or changing availability."""
    try:
        data, filename = await _read_docx(file)
        schedule = _parse(data, filename=filename, year=year)
        return await facilities.import_preview(
            db,
            family_id=current_user["family_id"],
            schedule=schedule,
        )
    finally:
        await file.close()


async def _personal_owner(db, *, user: dict, requested_owner: str | None) -> str:
    if requested_owner:
        row = await (
            await db.execute(
                "SELECT id FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                (requested_owner, user["family_id"]),
            )
        ).fetchone()
        if row is None:
            raise HTTPException(
                status_code=422, detail="Weights owner must be an adult in this family"
            )
        return row["id"]
    row = await (
        await db.execute(
            "SELECT v.personal_owner_user_id FROM facility_schedule_versions v "
            "JOIN users u ON u.id = v.personal_owner_user_id AND u.family_id = v.family_id "
            "WHERE v.family_id = ? AND v.provider_key = 'school_college' "
            "AND v.deleted_at IS NULL AND u.deleted_at IS NULL "
            "ORDER BY v.created_at DESC LIMIT 1",
            (user["family_id"],),
        )
    ).fetchone()
    if row:
        return row["personal_owner_user_id"]

    # Alex is the family's admin. Choosing the active admin on the first import
    # keeps his staff-only lane and weights availability private even if Morgan is
    # the person who uploads the next timetable.
    row = await (
        await db.execute(
            "SELECT id FROM users WHERE family_id = ? AND deleted_at IS NULL "
            "ORDER BY CASE WHEN role = 'admin' THEN 0 WHEN id = ? THEN 1 ELSE 2 END, "
            "priority DESC, created_at, id LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    return row["id"] if row else user["id"]


@router.post(
    "/example_school/import",
    response_model=FacilityImportResult,
    status_code=status.HTTP_201_CREATED,
)
async def import_example_school_timetable(
    file: UploadFile = File(...),
    expected_sha256: str = Form(..., min_length=64, max_length=64),
    year: int | None = Form(None, ge=2000, le=2100),
    personal_owner_user_id: str | None = Form(None, max_length=64),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Confirm a reviewed timetable and atomically file its normalised schedule."""
    if not _SHA256.fullmatch(expected_sha256):
        raise HTTPException(status_code=422, detail="expected_sha256 must be a SHA-256 digest")
    await reserve_persistent_attempts(
        db,
        [
            (
                f"facility-import:{current_user['family_id']}",
                settings.document_upload_rate_limit_requests,
                3_600,
            )
        ],
        detail_prefix="Too many timetable imports",
    )
    storage_key: str | None = None
    try:
        data, filename = await _read_docx(file)
        schedule = _parse(data, filename=filename, year=year)
        if schedule.sha256 != expected_sha256:
            raise HTTPException(
                status_code=409,
                detail="The timetable changed after review. Preview it again before importing",
            )
        preview = await facilities.import_preview(
            db,
            family_id=current_user["family_id"],
            schedule=schedule,
        )
        existing = await (
            await db.execute(
                "SELECT id, source_document_id FROM facility_schedule_versions "
                "WHERE family_id = ? AND provider_key = 'school_college' "
                "AND source_sha256 = ? AND deleted_at IS NULL",
                (current_user["family_id"], schedule.sha256),
            )
        ).fetchone()
        if existing:
            return FacilityImportResult(
                version_id=existing["id"],
                document_id=existing["source_document_id"],
                imported=False,
                preview=preview,
            )

        owner_user_id = await _personal_owner(
            db,
            user=current_user,
            requested_owner=personal_owner_user_id,
        )
        document_id = str(uuid.uuid4())
        version_id = str(uuid.uuid4())
        now = datetime.now(tz=timezone.utc).isoformat()
        await db.execute("BEGIN IMMEDIATE")
        try:
            # Re-check inside the write lock so concurrent confirmations are idempotent.
            existing = await (
                await db.execute(
                    "SELECT id, source_document_id FROM facility_schedule_versions "
                    "WHERE family_id = ? AND provider_key = 'school_college' "
                    "AND source_sha256 = ? AND deleted_at IS NULL",
                    (current_user["family_id"], schedule.sha256),
                )
            ).fetchone()
            if existing:
                await db.commit()
                return FacilityImportResult(
                    version_id=existing["id"],
                    document_id=existing["source_document_id"],
                    imported=False,
                    preview=preview,
                )
            existing_bytes = await family_document_storage_bytes(
                db,
                family_id=current_user["family_id"],
            )
            if existing_bytes + len(data) > settings.document_family_quota_bytes:
                raise HTTPException(
                    status_code=413, detail="Family document storage quota exceeded"
                )
            storage_key, stored_filename, size, digest = await store_bytes(
                data,
                filename=filename,
                media_type=facilities.DOCX_MEDIA_TYPE,
                family_id=current_user["family_id"],
                document_id=document_id,
            )
            await db.execute(
                """
                INSERT INTO documents (
                    id, title, original_filename, media_type, storage_key, file_size,
                    sha256, source, category, status, document_date, page_count,
                    extracted_text, notes, processor, family_id, created_at, updated_at,
                    created_by, client_timestamp
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'file', 'activities', 'filed', ?, 1,
                          ?, ?, 'fallback', ?, ?, ?, ?, ?)
                """,
                (
                    document_id,
                    schedule.title,
                    stored_filename,
                    facilities.DOCX_MEDIA_TYPE,
                    storage_key,
                    size,
                    digest,
                    schedule.valid_from.isoformat(),
                    facilities.extracted_schedule_text(schedule),
                    "Source timetable for Example School swimming and weights-room availability.",
                    current_user["family_id"],
                    now,
                    now,
                    current_user["id"],
                    now,
                ),
            )
            await db.execute(
                """
                INSERT INTO document_people (
                    id, document_id, person_id, person_type, family_id,
                    created_at, updated_at, created_by, client_timestamp
                ) VALUES (?, ?, ?, 'user', ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    document_id,
                    owner_user_id,
                    current_user["family_id"],
                    now,
                    now,
                    current_user["id"],
                    now,
                ),
            )
            await facilities.insert_schedule(
                db,
                schedule=schedule,
                version_id=version_id,
                document_id=document_id,
                user=current_user,
                now=now,
                personal_owner_user_id=owner_user_id,
            )
            await db.commit()
        except BaseException:
            if db.in_transaction:
                await db.rollback()
            raise
        return FacilityImportResult(
            version_id=version_id,
            document_id=document_id,
            imported=True,
            preview=preview,
        )
    except DocumentStorageError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    except BaseException:
        if storage_key:
            await remove_new_upload(storage_key)
        raise
    finally:
        await file.close()


@router.get("/quick-fact", response_model=FacilityQuickFact)
async def get_facility_quick_fact(
    reference_date: date | None = Query(None, alias="date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await facilities.quick_fact(
        db,
        family_id=current_user["family_id"],
        user_id=current_user["id"],
        reference_date=reference_date or datetime.now(facilities.FACILITY_ZONE).date(),
    )


@router.get("/timetable", response_model=list[FacilityDaySummary])
async def get_facility_timetable(
    start: date | None = Query(None),
    days: int = Query(14, ge=1, le=14),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await facilities.timetable_days(
        db,
        family_id=current_user["family_id"],
        user_id=current_user["id"],
        start=start or datetime.now(facilities.FACILITY_ZONE).date(),
        days=days,
    )


@router.post(
    "/swimming-bookings",
    response_model=FacilitySwimmingBookingResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_facility_swimming_booking(
    body: FacilitySwimmingBookingCreate,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result, replayed = await facilities.create_swimming_booking(
            db,
            user=current_user,
            booking=body,
        )
        if not replayed:
            source, version = safe_client_metadata(request.headers)
            await record_completed_actions_in_db(
                db,
                user=current_user,
                facts=[CompletedAction("facilities", "book_swimming", "created", "standard")],
                entry_source=source,
                app_version=version,
            )
        await db.commit()
        return result
    except CreateReplayConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post(
    "/weights-bookings",
    response_model=FacilityWeightsBookingResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_facility_weights_booking(
    body: FacilityWeightsBookingCreate,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result, replayed = await facilities.create_weights_booking(
            db,
            user=current_user,
            booking=body,
        )
        if not replayed:
            source, version = safe_client_metadata(request.headers)
            await record_completed_actions_in_db(
                db,
                user=current_user,
                facts=[CompletedAction("fitness", "plan_strength", "created", "standard")],
                entry_source=source,
                app_version=version,
            )
        await db.commit()
        return result
    except CreateReplayConflictError as exc:
        await db.rollback()
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        await db.rollback()
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/calendar-preferences", response_model=FacilityCalendarPreferenceResponse)
async def get_facility_calendar_preferences(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await facilities.calendar_preferences(db, user=current_user)


@router.patch("/calendar-preferences", response_model=FacilityCalendarPreferenceResponse)
async def patch_facility_calendar_preferences(
    body: FacilityCalendarPreferenceUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await facilities.update_calendar_preferences(
        db,
        user=current_user,
        show_family_swimming=body.show_family_swimming,
        show_personal_facilities=body.show_personal_facilities,
    )
    await db.commit()
    return result


@router.get("/calendar-layer", response_model=list[FacilityCalendarLayerItem])
async def get_facility_calendar_layer(
    start: date = Query(),
    end: date = Query(),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if end < start or (end - start).days > facilities.MAX_IMPORTED_DAYS:
        raise HTTPException(status_code=422, detail="Calendar range must be 370 days or fewer")
    return await facilities.calendar_layer(db, user=current_user, start=start, end=end)
