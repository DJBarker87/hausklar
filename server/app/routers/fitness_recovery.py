"""Fitness sleep, recovery, provenance preference and private-photo routes."""

from datetime import date
from typing import Annotated

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Query,
    Response,
    UploadFile,
    status,
)
from fastapi.responses import FileResponse

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness_recovery import (
    BodyMeasurementCanonicalOverrideResponse,
    ProgressPhotoPayload,
    SourcePriorityPayload,
)
from app.services.fitness import progress_photos, recovery
from app.services.fitness.resource_limits import (
    fitness_upload_slot,
    reserve_fitness_upload,
)
from app.services.fitness.activity_import import enqueue_photo_thumbnail_job
from app.services.fitness.common import FitnessConflictError, FitnessNotFoundError

router = APIRouter()


def _raise_domain(exc: Exception) -> None:
    if isinstance(exc, HTTPException):
        raise exc
    if isinstance(exc, FitnessNotFoundError):
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(exc, FitnessConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    raise exc


@router.get("/sleep/sessions")
async def get_sleep_sessions(
    from_date: date | None = None,
    to_date: date | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if from_date and to_date and to_date < from_date:
        raise HTTPException(status_code=422, detail="Sleep date range is invalid")
    return await recovery.list_sleep_sessions(
        db,
        user=current_user,
        from_date=from_date,
        to_date=to_date,
        limit=limit,
        offset=offset,
    )


@router.get("/recovery/observations")
async def get_recovery_observations(
    from_date: date | None = None,
    to_date: date | None = None,
    metric_key: Annotated[str | None, Query(max_length=120)] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if from_date and to_date and to_date < from_date:
        raise HTTPException(status_code=422, detail="Recovery date range is invalid")
    return await recovery.list_recovery_observations(
        db,
        user=current_user,
        from_date=from_date,
        to_date=to_date,
        metric_key=metric_key,
        limit=limit,
        offset=offset,
    )


@router.get("/recovery/summary")
async def get_recovery_summary(
    from_date: date,
    to_date: date,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if to_date < from_date or (to_date - from_date).days > 730:
        raise HTTPException(status_code=422, detail="Recovery date range is invalid")
    return await recovery.recovery_summary(
        db,
        user=current_user,
        from_date=from_date,
        to_date=to_date,
    )


@router.get("/source-priorities")
async def get_source_priorities(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await recovery.list_source_priorities(db, user=current_user)


@router.post("/source-priorities", status_code=status.HTTP_201_CREATED)
async def set_source_priority(
    body: SourcePriorityPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await recovery.upsert_source_priority(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@router.post(
    "/body/measurements/{measurement_id}/canonical-override",
    response_model=BodyMeasurementCanonicalOverrideResponse,
)
async def select_canonical_body_measurement(
    measurement_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await recovery.set_weight_canonical_override(
            db, user=current_user, measurement_id=measurement_id
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.delete(
    "/body/measurements/{measurement_id}/canonical-override",
    response_model=BodyMeasurementCanonicalOverrideResponse,
)
async def clear_canonical_body_measurement(
    measurement_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await recovery.clear_weight_canonical_override(
            db, user=current_user, measurement_id=measurement_id
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/files/private", status_code=status.HTTP_201_CREATED)
async def upload_private_file(
    file: Annotated[UploadFile, File()],
    asset_id: Annotated[str, Form(max_length=100)],
    asset_kind: Annotated[str, Form(max_length=80)] = "progress_photo",
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await reserve_fitness_upload(db, user=current_user)
        with fitness_upload_slot(user=current_user):
            return await progress_photos.stage_private_photo(
                db,
                user=current_user,
                upload=file,
                asset_id=asset_id,
                asset_kind=asset_kind,
            )
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@router.get("/files/private/{asset_id}")
async def get_private_nutrition_label(
    asset_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        asset, path = await progress_photos.nutrition_label_asset(
            db, user=current_user, asset_id=asset_id
        )
        filename = (asset["original_filename"] or path.name).replace('"', "")
        filename = filename.replace("\r", "").replace("\n", "")
        return FileResponse(
            path,
            media_type=asset["media_type"],
            headers={
                "Cache-Control": "private, no-store",
                "Content-Disposition": f'inline; filename="{filename}"',
            },
        )
    except Exception as exc:
        _raise_domain(exc)


@router.delete("/files/private/{asset_id}", status_code=status.HTTP_204_NO_CONTENT)
async def cancel_private_file(
    asset_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await progress_photos.delete_staged_private_asset(
            db, user=current_user, asset_id=asset_id
        )
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@router.post("/progress-photos", status_code=status.HTTP_201_CREATED)
async def save_progress_photo(
    body: ProgressPhotoPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await progress_photos.create_progress_photo(
            db, user=current_user, body=body
        )
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@router.get("/progress-photos")
async def get_progress_photos(
    pose: Annotated[str | None, Query(max_length=50)] = None,
    from_date: date | None = None,
    to_date: date | None = None,
    phase_id: Annotated[str | None, Query(max_length=100)] = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if to_date and from_date and to_date < from_date:
        raise HTTPException(status_code=422, detail="Progress-photo date range is invalid")
    return await progress_photos.list_progress_photos(
        db,
        user=current_user,
        pose=pose,
        from_date=from_date,
        to_date=to_date,
        phase_id=phase_id,
    )


@router.get("/progress-photos/{photo_id}")
async def get_progress_photo(
    photo_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await progress_photos.progress_photo_response(
            db, user=current_user, photo_id=photo_id
        )
    except Exception as exc:
        _raise_domain(exc)


@router.get("/progress-photos/{photo_id}/original")
async def get_progress_photo_original(
    photo_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        asset, path = await progress_photos.photo_asset(
            db, user=current_user, photo_id=photo_id, thumbnail=False
        )
        return FileResponse(
            path,
            media_type=asset["media_type"],
            filename=asset["original_filename"] or path.name,
            headers={"Cache-Control": "private, no-store"},
        )
    except Exception as exc:
        _raise_domain(exc)


@router.get("/progress-photos/{photo_id}/thumbnail")
async def get_progress_photo_thumbnail(
    photo_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        asset, path = await progress_photos.photo_asset(
            db, user=current_user, photo_id=photo_id, thumbnail=True
        )
        return FileResponse(
            path,
            media_type=asset["media_type"],
            headers={"Cache-Control": "private, max-age=86400"},
        )
    except Exception as exc:
        _raise_domain(exc)


@router.post("/progress-photos/{photo_id}/thumbnail/regenerate")
async def regenerate_progress_photo_thumbnail(
    photo_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        photo = await progress_photos.progress_photo_response(
            db, user=current_user, photo_id=photo_id
        )
        if photo["thumbnail_state"] == "ready":
            try:
                await progress_photos.photo_asset(
                    db, user=current_user, photo_id=photo_id, thumbnail=True
                )
                photo["status"] = "ready"
                return photo
            except FitnessNotFoundError:
                pass
        await enqueue_photo_thumbnail_job(db, user=current_user, photo_id=photo_id)
        await db.commit()
        photo["status"] = "queued"
        return photo
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@router.delete("/progress-photos/{photo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_progress_photo(
    photo_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await progress_photos.delete_progress_photo(
            db, user=current_user, photo_id=photo_id
        )
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)
