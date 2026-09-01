"""Owner-private Intervals.icu connection, workout, and activity routes."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import RedirectResponse

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness_intervals import (
    IntervalsActivityImportSettingsRequest,
    IntervalsActivityImportSyncResponse,
    IntervalsApiKeyConnectRequest,
    IntervalsConnectionStatusResponse,
    IntervalsDeliveryResponse,
    IntervalsDisconnectResponse,
    IntervalsOAuthStartRequest,
    IntervalsOAuthStartResponse,
)
from app.services.fitness import intervals_icu
from app.services.fitness.common import FitnessConflictError, FitnessNotFoundError


router = APIRouter()


def _domain_error(exc: Exception) -> HTTPException:
    if isinstance(exc, intervals_icu.IntervalsNotConfiguredError):
        return HTTPException(status_code=503, detail=str(exc))
    if isinstance(exc, FitnessNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, intervals_icu.IntervalsConnectionNotFoundError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, intervals_icu.IntervalsAuthorizationError):
        return HTTPException(status_code=401, detail="Intervals.icu rejected the credentials")
    if isinstance(exc, intervals_icu.IntervalsProviderError):
        return HTTPException(
            status_code=502, detail="Intervals.icu could not complete the request"
        )
    if isinstance(exc, FitnessConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, intervals_icu.IntervalsError):
        return HTTPException(status_code=422, detail=str(exc))
    return HTTPException(status_code=500, detail="Intervals.icu request failed")


async def _rollback(db) -> None:
    if db.in_transaction:
        await db.rollback()


@router.get(
    "/integrations/intervals/status",
    response_model=IntervalsConnectionStatusResponse,
)
async def intervals_status(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await intervals_icu.connection_status(db, user=current_user)


@router.post(
    "/integrations/intervals/connect",
    response_model=IntervalsConnectionStatusResponse,
)
async def connect_intervals_api_key(
    body: IntervalsApiKeyConnectRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await intervals_icu.connect_api_key(
            db,
            user=current_user,
            api_key=body.api_key.get_secret_value(),
        )
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.post(
    "/integrations/intervals/test",
    response_model=IntervalsConnectionStatusResponse,
)
async def test_intervals_connection(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await intervals_icu.test_connection(db, user=current_user)
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.post(
    "/integrations/intervals/oauth/start",
    response_model=IntervalsOAuthStartResponse,
)
async def start_intervals_oauth(
    body: IntervalsOAuthStartRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        authorization_url, expires_at = await intervals_icu.start_authorization(
            db, user=current_user, return_surface=body.return_surface
        )
        return IntervalsOAuthStartResponse(
            authorization_url=authorization_url,
            expires_at=expires_at,
        )
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.get(
    "/integrations/intervals/oauth/callback",
    response_class=RedirectResponse,
)
async def finish_intervals_oauth(
    state: str = Query(min_length=20, max_length=500),
    code: str | None = Query(default=None, min_length=1, max_length=2_000),
    error: str | None = Query(default=None, max_length=300),
    db=Depends(get_db),
):
    if error or not code:
        try:
            surface = await intervals_icu.consume_cancelled_authorization(
                db, state=state
            )
        except Exception:
            surface = "web"
        return RedirectResponse(
            intervals_icu.callback_return_url(surface, "cancelled"), status_code=303
        )
    try:
        surface = await intervals_icu.complete_authorization(
            db, state=state, code=code
        )
    except intervals_icu.IntervalsOAuthCompletionError as exc:
        await _rollback(db)
        return RedirectResponse(
            intervals_icu.callback_return_url(exc.surface, "failed"), status_code=303
        )
    except Exception:
        await _rollback(db)
        return RedirectResponse(
            intervals_icu.callback_return_url("web", "failed"), status_code=303
        )
    return RedirectResponse(
        intervals_icu.callback_return_url(surface, "connected"), status_code=303
    )


@router.delete(
    "/integrations/intervals",
    response_model=IntervalsDisconnectResponse,
)
async def disconnect_intervals(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        retained = await intervals_icu.disconnect(db, user=current_user)
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc
    return IntervalsDisconnectResponse(
        status="disconnected", retained_publication_count=retained
    )


@router.put(
    "/integrations/intervals/activity-import",
    response_model=IntervalsConnectionStatusResponse,
)
async def update_intervals_activity_import(
    body: IntervalsActivityImportSettingsRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await intervals_icu.set_activity_import(
            db,
            user=current_user,
            enabled=body.enabled,
            lookback_days=body.lookback_days,
        )
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.post(
    "/integrations/intervals/activity-import/sync",
    response_model=IntervalsActivityImportSyncResponse,
)
async def sync_intervals_activities(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await intervals_icu.sync_activity_imports(db, user=current_user)
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.get(
    "/integrations/intervals/workouts/{planned_session_id}",
    response_model=IntervalsDeliveryResponse,
)
async def get_intervals_delivery(
    planned_session_id: str,
    refresh: bool = Query(default=False),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await intervals_icu.delivery_status(
            db,
            user=current_user,
            planned_session_id=planned_session_id,
            refresh=refresh,
        )
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.post(
    "/integrations/intervals/workouts/{planned_session_id}",
    response_model=IntervalsDeliveryResponse,
)
async def send_intervals_workout(
    planned_session_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await intervals_icu.publish_workout(
            db, user=current_user, planned_session_id=planned_session_id
        )
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.delete(
    "/integrations/intervals/workouts/{planned_session_id}",
    response_model=IntervalsDeliveryResponse,
)
async def cancel_intervals_workout(
    planned_session_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await intervals_icu.cancel_workout(
            db, user=current_user, planned_session_id=planned_session_id
        )
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc
