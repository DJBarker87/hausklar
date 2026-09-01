"""Owner-private Withings connection, notification, sync, and chart routes."""

from __future__ import annotations

import secrets
from datetime import date, datetime, timedelta, timezone
from urllib.parse import parse_qs

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    HTTPException,
    Query,
    Request,
    Response,
    status,
)
from fastapi.responses import RedirectResponse

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.models.fitness_withings import (
    MeasurementHistoryResponse,
    WithingsConnectionStartRequest,
    WithingsConnectionStartResponse,
    WithingsConnectionStatusResponse,
    WithingsDisconnectResponse,
    WithingsSyncResponse,
)
from app.services.fitness import withings
from app.services.fitness.common import FitnessConflictError


router = APIRouter()


def _domain_error(exc: Exception) -> HTTPException:
    if isinstance(exc, withings.WithingsNotConfiguredError):
        return HTTPException(status_code=503, detail=str(exc))
    if isinstance(exc, withings.WithingsConnectionNotFoundError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, withings.WithingsSyncBusyError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, FitnessConflictError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, withings.WithingsProviderError):
        return HTTPException(status_code=502, detail="Withings could not complete the request")
    if isinstance(exc, withings.WithingsError):
        return HTTPException(status_code=422, detail=str(exc))
    return HTTPException(status_code=500, detail="Withings request failed")


@router.get(
    "/integrations/withings/status",
    response_model=WithingsConnectionStatusResponse,
)
async def get_withings_status(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await withings.connection_status(db, user=current_user)


@router.post(
    "/integrations/withings/start",
    response_model=WithingsConnectionStartResponse,
)
async def start_withings_connection(
    body: WithingsConnectionStartRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        authorization_url, expires_at = await withings.start_authorization(
            db,
            user=current_user,
            return_surface=body.return_surface,
        )
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        raise _domain_error(exc) from exc
    return WithingsConnectionStartResponse(
        authorization_url=authorization_url,
        expires_at=expires_at,
    )


@router.get(
    "/integrations/withings/callback",
    response_class=RedirectResponse,
)
async def finish_withings_connection(
    background_tasks: BackgroundTasks,
    state: str | None = Query(default=None, min_length=20, max_length=500),
    code: str | None = Query(default=None, min_length=1, max_length=2_000),
    error: str | None = Query(default=None, max_length=300),
    db=Depends(get_db),
):
    # Withings validates registered callback URLs with a parameterless GET.
    # Real OAuth callbacks always include state, so this branch is only a
    # reachability probe and does not consume or create authorization state.
    if state is None and code is None and error is None:
        return Response(
            content="HausKlar Withings OAuth callback is ready",
            media_type="text/plain",
            status_code=status.HTTP_200_OK,
        )
    if state is None:
        raise HTTPException(status_code=400, detail="Missing Withings OAuth state")
    if error or not code:
        try:
            surface = await withings.consume_cancelled_authorization(db, state=state)
        except Exception:
            surface = "web"
        return RedirectResponse(
            withings.callback_return_url(surface, "cancelled"), status_code=303
        )
    try:
        connection_id, surface = await withings.complete_authorization(
            db, state=state, code=code
        )
    except Exception:
        if db.in_transaction:
            await db.rollback()
        return RedirectResponse(
            withings.callback_return_url("web", "failed"), status_code=303
        )
    background_tasks.add_task(withings.finish_connection_setup, connection_id)
    return RedirectResponse(
        withings.callback_return_url(surface, "connected"), status_code=303
    )


@router.head(
    "/integrations/withings/callback",
    status_code=status.HTTP_200_OK,
    include_in_schema=False,
)
async def verify_withings_callback():
    """Answer Withings' registered-URL reachability probe."""
    return Response(status_code=status.HTTP_200_OK)


def _assert_webhook_token(provided: str) -> None:
    expected = settings.withings_webhook_secret.strip()
    if not withings.configured() or not expected:
        raise HTTPException(status_code=503, detail="Withings notifications are unavailable")
    if not secrets.compare_digest(provided.strip(), expected):
        raise HTTPException(status_code=401, detail="Invalid Withings notification token")


@router.head("/integrations/withings/webhook", status_code=status.HTTP_204_NO_CONTENT)
async def verify_withings_webhook(
    request: Request,
    token: str = Query(min_length=1, max_length=500),
):
    if not await withings.notification_source_allowed(
        request.headers.get("CF-Connecting-IP", "")
    ):
        raise HTTPException(status_code=403, detail="Withings notification source rejected")
    _assert_webhook_token(token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/integrations/withings/webhook", status_code=status.HTTP_202_ACCEPTED)
async def receive_withings_webhook(
    request: Request,
    token: str = Query(min_length=1, max_length=500),
    db=Depends(get_db),
):
    if not await withings.notification_source_allowed(
        request.headers.get("CF-Connecting-IP", "")
    ):
        raise HTTPException(status_code=403, detail="Withings notification source rejected")
    _assert_webhook_token(token)
    content_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if content_type != "application/x-www-form-urlencoded":
        raise HTTPException(status_code=415, detail="Withings notification must be form encoded")
    raw = await request.body()
    if len(raw) > 4_096:
        raise HTTPException(status_code=413, detail="Withings notification is too large")
    try:
        values = parse_qs(raw.decode("ascii"), keep_blank_values=False, strict_parsing=True)
        if any(
            len(values.get(key, [])) != 1
            for key in ("userid", "appli", "startdate", "enddate")
        ):
            raise ValueError("duplicate or missing field")
        provider_user_id = values["userid"][0]
        category = int(values["appli"][0])
        start_at = int(values["startdate"][0])
        end_at = int(values["enddate"][0])
    except (KeyError, UnicodeDecodeError, TypeError, ValueError, IndexError) as exc:
        raise HTTPException(status_code=422, detail="Withings notification is malformed") from exc
    if (
        not provider_user_id.isascii()
        or not provider_user_id.isdecimal()
        or len(provider_user_id) > 20
        or category not in withings.WITHINGS_NOTIFICATION_CATEGORIES
        or start_at < 0
        or end_at < start_at
        or end_at > int((datetime.now(timezone.utc) + timedelta(days=1)).timestamp())
        or end_at - start_at > int(timedelta(days=366).total_seconds())
    ):
        raise HTTPException(status_code=422, detail="Withings notification range is invalid")
    await withings.enqueue_notification(
        db,
        provider_user_id=provider_user_id,
        category=category,
        start_at=start_at,
        end_at=end_at,
    )
    return {"status": "accepted"}


@router.post(
    "/integrations/withings/sync",
    response_model=WithingsSyncResponse,
)
async def sync_withings_now(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await withings.sync_connection(db, user=current_user)
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        raise _domain_error(exc) from exc
    return WithingsSyncResponse(status="synced", **result)


@router.delete(
    "/integrations/withings",
    response_model=WithingsDisconnectResponse,
)
async def disconnect_withings(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        retained = await withings.disconnect(db, user=current_user)
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        raise _domain_error(exc) from exc
    return WithingsDisconnectResponse(
        status="disconnected", retained_measurement_count=retained
    )


@router.get(
    "/measurements/history",
    response_model=MeasurementHistoryResponse,
)
async def get_measurement_history(
    metric: str = Query(pattern="^(weight|body_fat|blood_pressure)$"),
    start_on: date | None = None,
    end_on: date | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if start_on and end_on and end_on < start_on:
        raise HTTPException(status_code=422, detail="Measurement date range is invalid")
    return await withings.measurement_history(
        db,
        user=current_user,
        metric=metric,
        start_on=start_on,
        end_on=end_on,
    )
