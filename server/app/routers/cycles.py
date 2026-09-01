from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status

from app.auth import get_current_user
from app.database import get_db
from app.models.cycles import (
    CycleProfileResponse,
    CycleSettingsResponse,
    CycleSettingsUpdate,
    FitnessCycleProfileResponse,
    FitnessPeriodStartPayload,
    PeriodStartCreate,
    PeriodStartResponse,
)
from app.services.fitness.cycles import (
    CycleRecordNotFoundError,
    CycleWriteConflictError,
    create_period_start,
    settings_from_legacy,
    soft_delete_period_start,
    upsert_cycle_settings,
    visible_cycle_profiles,
)
from app.services.idempotency import serialized_create

router = APIRouter()


async def _own_profile(db, current_user: dict) -> FitnessCycleProfileResponse:
    profiles = await visible_cycle_profiles(
        db,
        family_id=current_user["family_id"],
        current_user_id=current_user["id"],
    )
    profile = next((item for item in profiles if item.is_owner), None)
    if profile is None:
        raise HTTPException(status_code=404, detail="Cycle tracking is not set up")
    return profile


def _legacy_profile(profile: FitnessCycleProfileResponse) -> CycleProfileResponse:
    return CycleProfileResponse(
        id=profile.id,
        owner_user_id=profile.owner_user_id,
        owner_name=profile.owner_name,
        is_owner=profile.is_owner,
        cycle_length_days=profile.cycle_length_days,
        share_with_adults=any(
            (
                profile.share_period_starts_with_adults,
                profile.share_predicted_period_with_adults,
                profile.share_estimated_ovulation_with_adults,
            )
        ),
        show_period_starts=profile.show_period_starts,
        show_predicted_period=profile.show_predicted_period,
        show_estimated_ovulation=profile.show_estimated_ovulation,
        latest_period_start=profile.latest_period_start,
        predicted_next_period=profile.predicted_next_period,
        estimated_ovulation=profile.estimated_ovulation,
        period_starts=[
            PeriodStartResponse(
                id=item.id,
                started_on=item.started_on,
                created_at=item.created_at,
                updated_at=item.updated_at,
            )
            for item in profile.period_starts
        ],
        created_at=profile.created_at,
        updated_at=profile.updated_at,
    )


@router.get("/", response_model=list[CycleProfileResponse])
async def list_cycles(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return own and explicitly adult-shared cycle profiles."""
    profiles = await visible_cycle_profiles(
        db,
        family_id=current_user["family_id"],
        current_user_id=current_user["id"],
    )
    return [_legacy_profile(profile) for profile in profiles]


@router.put("/settings", response_model=CycleSettingsResponse)
async def update_cycle_settings(
    body: CycleSettingsUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create or update only the authenticated account's cycle settings."""
    now = datetime.now(timezone.utc).isoformat()
    try:
        async with serialized_create(db):
            await upsert_cycle_settings(
                db,
                body=settings_from_legacy(body),
                user=current_user,
                now=now,
                adopt_existing_identity=True,
            )
    except CycleWriteConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _legacy_profile(await _own_profile(db, current_user))


@router.post(
    "/periods",
    response_model=PeriodStartResponse,
    status_code=status.HTTP_201_CREATED,
)
async def add_period_start(
    body: PeriodStartCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Record an actual period start for the authenticated account."""
    await _own_profile(db, current_user)
    now = datetime.now(timezone.utc).isoformat()
    try:
        async with serialized_create(db):
            response = await create_period_start(
                db,
                body=FitnessPeriodStartPayload(
                    id=body.id,
                    started_on=body.started_on,
                ),
                user=current_user,
                now=now,
            )
    except CycleWriteConflictError as exc:
        if db.in_transaction:
            await db.rollback()
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return response


@router.delete("/periods/{period_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_period_start(
    period_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Soft-delete only the authenticated account's period start."""
    now = datetime.now(timezone.utc).isoformat()
    try:
        await soft_delete_period_start(
            db,
            period_id=period_id,
            user=current_user,
            now=now,
        )
    except CycleRecordNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    await db.commit()
