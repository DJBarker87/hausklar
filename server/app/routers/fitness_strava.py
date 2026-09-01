"""Owner-private Strava connection and one-tap import routes."""

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import RedirectResponse

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness_strava import (
    StravaConnectionStatusResponse,
    StravaDisconnectResponse,
    StravaOAuthStartRequest,
    StravaOAuthStartResponse,
    StravaSyncResponse,
)
from app.services.fitness import strava
from app.services.fitness.common import FitnessConflictError


router = APIRouter()


def _domain_error(exc: Exception) -> HTTPException:
    if isinstance(exc, strava.StravaNotConfiguredError):
        return HTTPException(status_code=503, detail=str(exc))
    if isinstance(exc, strava.StravaConnectionNotFoundError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, strava.StravaAuthorizationError):
        return HTTPException(status_code=401, detail="Strava needs to be reconnected")
    if isinstance(exc, strava.StravaProviderError):
        return HTTPException(status_code=502, detail="Strava could not complete the request")
    if isinstance(exc, (strava.StravaError, FitnessConflictError)):
        return HTTPException(status_code=422, detail=str(exc))
    return HTTPException(status_code=500, detail="Strava request failed")


async def _rollback(db) -> None:
    if db.in_transaction:
        await db.rollback()


@router.get("/integrations/strava/status", response_model=StravaConnectionStatusResponse)
async def strava_status(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await strava.connection_status(db, user=current_user)


@router.post("/integrations/strava/start", response_model=StravaOAuthStartResponse)
async def start_strava(
    body: StravaOAuthStartRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        url, expires_at = await strava.start_authorization(
            db, user=current_user, return_surface=body.return_surface
        )
        return StravaOAuthStartResponse(authorization_url=url, expires_at=expires_at)
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.get("/integrations/strava/callback", response_class=RedirectResponse)
async def finish_strava(
    state: str = Query(min_length=20, max_length=500),
    code: str | None = Query(default=None, min_length=1, max_length=2_000),
    scope: str | None = Query(default=None, max_length=500),
    error: str | None = Query(default=None, max_length=300),
    db=Depends(get_db),
):
    if error or not code:
        try:
            surface = await strava.consume_cancelled_authorization(db, state=state)
        except Exception:
            surface = "web"
        return RedirectResponse(strava.callback_return_url(surface, "cancelled"), status_code=303)
    try:
        surface = await strava.complete_authorization(
            db,
            state=state,
            code=code,
            granted_scope=scope,
        )
    except strava.StravaOAuthCompletionError as exc:
        await _rollback(db)
        return RedirectResponse(strava.callback_return_url(exc.surface, "failed"), status_code=303)
    except Exception:
        await _rollback(db)
        return RedirectResponse(strava.callback_return_url("web", "failed"), status_code=303)
    return RedirectResponse(strava.callback_return_url(surface, "connected"), status_code=303)


@router.post("/integrations/strava/sync", response_model=StravaSyncResponse)
async def sync_strava(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await strava.sync_activities(db, user=current_user)
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc


@router.delete("/integrations/strava", response_model=StravaDisconnectResponse)
async def disconnect_strava(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        retained = await strava.disconnect(db, user=current_user)
        return StravaDisconnectResponse(status="disconnected", retained_activity_count=retained)
    except Exception as exc:
        await _rollback(db)
        raise _domain_error(exc) from exc
