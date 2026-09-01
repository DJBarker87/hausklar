"""Canonical Fitness cycle-tracking API."""

from fastapi import APIRouter, Depends, HTTPException, status

from app.auth import get_current_user
from app.database import get_db
from app.models.cycles import (
    FitnessCycleProfileResponse,
    FitnessCycleSettingsPayload,
    FitnessPeriodStartPayload,
    FitnessPeriodStartResponse,
)
from app.services.fitness import cycles
from app.services.idempotency import serialized_create

router = APIRouter()


async def _own_profile(db, user: dict) -> FitnessCycleProfileResponse:
    profiles = await cycles.visible_cycle_profiles(
        db,
        family_id=user["family_id"],
        current_user_id=user["id"],
    )
    profile = next((item for item in profiles if item.is_owner), None)
    if profile is None:
        raise HTTPException(status_code=404, detail="Cycle tracking is not set up")
    return profile


@router.get("/cycles", response_model=list[FitnessCycleProfileResponse])
async def list_cycles(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await cycles.visible_cycle_profiles(
        db,
        family_id=current_user["family_id"],
        current_user_id=current_user["id"],
    )


@router.put("/cycles/settings", response_model=FitnessCycleProfileResponse)
async def update_cycle_settings(
    body: FitnessCycleSettingsPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        async with serialized_create(db):
            await cycles.upsert_cycle_settings(db, body=body, user=current_user)
    except cycles.CycleWriteConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return await _own_profile(db, current_user)


@router.delete("/cycles/settings", status_code=status.HTTP_204_NO_CONTENT)
async def delete_cycle_settings(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    profile = await _own_profile(db, current_user)
    await cycles.soft_delete_cycle_settings(
        db,
        settings_id=profile.id,
        user=current_user,
    )
    await db.commit()


@router.post(
    "/cycles/periods",
    response_model=FitnessPeriodStartResponse,
    status_code=status.HTTP_201_CREATED,
)
async def add_period_start(
    body: FitnessPeriodStartPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        async with serialized_create(db):
            return await cycles.create_period_start(
                db,
                body=body,
                user=current_user,
            )
    except cycles.CycleRecordNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except cycles.CycleWriteConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.delete(
    "/cycles/periods/{period_id}", status_code=status.HTTP_204_NO_CONTENT
)
async def delete_period_start(
    period_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await cycles.soft_delete_period_start(
            db,
            period_id=period_id,
            user=current_user,
        )
    except cycles.CycleRecordNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    await db.commit()
