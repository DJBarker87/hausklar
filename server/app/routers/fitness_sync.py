"""Version-gated Fitness sync and non-blocking notice endpoints."""

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness import FitnessSyncRequest
from app.services.fitness import sync
from app.services.fitness.common import FitnessConflictError, FitnessNotFoundError

router = APIRouter()


def _compatibility_response(body: FitnessSyncRequest) -> JSONResponse | None:
    if body.sync_protocol_version < sync.CURRENT_SYNC_PROTOCOL_VERSION:
        return JSONResponse(
            status_code=426,
            content={
                "status": "sync_protocol_upgrade_required",
                "received_sync_protocol_version": body.sync_protocol_version,
                "current_sync_protocol_version": sync.CURRENT_SYNC_PROTOCOL_VERSION,
                "supported_sync_protocol_versions": sync.SUPPORTED_SYNC_PROTOCOL_VERSIONS,
                "message": "Update HausKlar before syncing Fitness data. Local entries have been kept.",
            },
        )
    if body.sync_protocol_version > sync.CURRENT_SYNC_PROTOCOL_VERSION:
        return JSONResponse(
            status_code=409,
            content={
                "status": "server_sync_protocol_upgrade_required",
                "received_sync_protocol_version": body.sync_protocol_version,
                "current_sync_protocol_version": sync.CURRENT_SYNC_PROTOCOL_VERSION,
                "supported_sync_protocol_versions": sync.SUPPORTED_SYNC_PROTOCOL_VERSIONS,
                "message": "The HausKlar server must be updated before this app can sync Fitness data.",
            },
        )
    if body.client_schema_version < sync.MINIMUM_SUPPORTED_CLIENT_SCHEMA_VERSION:
        return JSONResponse(
            status_code=426,
            content={
                "status": "upgrade_required",
                "minimum_supported_client_schema_version": sync.MINIMUM_SUPPORTED_CLIENT_SCHEMA_VERSION,
                "current_client_schema_version": sync.CURRENT_CLIENT_SCHEMA_VERSION,
                "current_sync_protocol_version": sync.CURRENT_SYNC_PROTOCOL_VERSION,
                "message": "Update HausKlar before syncing Fitness data. Local entries have been kept.",
            },
        )
    if body.client_schema_version > sync.CURRENT_CLIENT_SCHEMA_VERSION:
        return JSONResponse(
            status_code=409,
            content={
                "status": "server_upgrade_required",
                "current_client_schema_version": sync.CURRENT_CLIENT_SCHEMA_VERSION,
                "received_client_schema_version": body.client_schema_version,
                "message": "The HausKlar server must be updated before this app can sync Fitness data.",
            },
        )
    return None


@router.get("/sync/capabilities")
async def fitness_sync_capabilities(
    _current_user: dict = Depends(get_current_user),
):
    return sync.capabilities()


@router.post("/sync")
async def fitness_sync(
    body: FitnessSyncRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    compatibility = _compatibility_response(body)
    if compatibility is not None:
        return compatibility
    try:
        sync.preflight_payload_versions(body)
    except sync.PayloadUpgradeRequired as exc:
        return JSONResponse(
            status_code=426,
            content={
                "status": "payload_upgrade_required",
                "entity_type": exc.entity_type,
                "received_payload_schema_version": exc.received_version,
                "supported_payload_schema_versions": sync.SUPPORTED_PAYLOAD_SCHEMA_VERSIONS.get(
                    exc.entity_type, []
                ),
                "message": "Update HausKlar before syncing this kind of Fitness record.",
            },
        )
    try:
        return await sync.apply_sync(db, user=current_user, request=body)
    except FitnessNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except FitnessConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.get("/sync/snapshot")
async def fitness_sync_snapshot(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await sync.full_snapshot(db, user=current_user)
    except FitnessNotFoundError as exc:
        if db.in_transaction:
            await db.rollback()
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except FitnessConflictError as exc:
        if db.in_transaction:
            await db.rollback()
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.get("/sync/notices")
async def fitness_sync_notices(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await sync.list_notices(db, user=current_user)


@router.post("/sync/notices/{notice_id}/dismiss")
async def dismiss_fitness_sync_notice(
    notice_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await sync.dismiss_notice(
            db, user=current_user, notice_id=notice_id
        )
        await db.commit()
        return result
    except FitnessNotFoundError as exc:
        await db.rollback()
        raise HTTPException(status_code=404, detail=str(exc)) from exc
