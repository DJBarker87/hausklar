"""Sync API endpoints.

POST /push   — push local changes to the server (conflict-resolved).
GET  /pull   — pull all changes since a given timestamp.
GET  /status — lightweight health-check for the sync sub-system.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Query

from app.auth import get_current_user
from app.database import get_db
from app.models.sync import (
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
    SyncPushResult,
    SyncStatusResponse,
)
from app.services.sync import apply_push, get_changes_page, resolve_conflict

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/push", response_model=SyncPushResponse)
async def push(
    body: SyncPushRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Accept a batch of client-side changes.

    Each item is individually conflict-checked.  Accepted items are applied
    immediately; conflicting items are returned with the current server
    version so the client can reconcile.
    """
    results: list[SyncPushResult] = []

    # Sync item savepoints must live inside an IMMEDIATE transaction. This is
    # especially important for medicine doses: the safety read and subsequent
    # insert must serialize with direct API writes as one operation.
    await db.execute("BEGIN IMMEDIATE")

    for item in body.items:
        try:
            result = await resolve_conflict(db, item, current_user)
        except (TypeError, ValueError):
            results.append(
                SyncPushResult(
                    operation_id=item.operation_id,
                    record_id=item.record_id,
                    status="error",
                    detail="Sync item metadata is invalid",
                )
            )
            continue

        if result.status == "accepted":
            try:
                await db.execute("SAVEPOINT sync_item")
                warnings = await apply_push(db, item, current_user)
                await db.execute("RELEASE SAVEPOINT sync_item")
                result = result.model_copy(update={"warnings": warnings})
            except ValueError as exc:
                await db.execute("ROLLBACK TO SAVEPOINT sync_item")
                await db.execute("RELEASE SAVEPOINT sync_item")
                result = SyncPushResult(
                    record_id=item.record_id,
                    status="error",
                    detail=str(exc),
                )
            except Exception:
                await db.execute("ROLLBACK TO SAVEPOINT sync_item")
                await db.execute("RELEASE SAVEPOINT sync_item")
                logger.exception(
                    "Unable to apply sync change for table=%s operation=%s",
                    item.table_name,
                    item.operation,
                )
                result = SyncPushResult(
                    record_id=item.record_id,
                    status="error",
                    detail="Unable to apply sync change",
                )

        results.append(result.model_copy(update={"operation_id": item.operation_id}))

    await db.commit()
    return SyncPushResponse(results=results)


@router.get("/pull", response_model=SyncPullResponse)
async def pull(
    since: str = Query(..., description="ISO-8601 timestamp — return records updated after this point"),
    cursor: str | None = Query(default=None, max_length=1_024),
    limit: int | None = Query(default=None, ge=1, le=2_000),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return records changed since a timestamp, optionally in bounded pages."""
    try:
        page = await get_changes_page(
            db,
            since,
            family_id=current_user.get("family_id"),
            cursor=cursor,
            limit=limit,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return SyncPullResponse(**page)


@router.get("/status", response_model=SyncStatusResponse)
async def status(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return the current state of the sync queue."""
    family_id = current_user.get("family_id")
    if family_id:
        cursor = await db.execute(
            "SELECT COUNT(*) AS cnt FROM sync_queue WHERE status = 'pending' AND family_id = ?",
            (family_id,),
        )
    else:
        cursor = await db.execute(
            "SELECT COUNT(*) AS cnt FROM sync_queue WHERE status = 'pending'",
        )
    row = await cursor.fetchone()
    pending_count = row["cnt"] if row else 0

    if family_id:
        cursor = await db.execute(
            "SELECT MAX(updated_at) AS last_sync FROM sync_queue WHERE status = 'completed' AND family_id = ?",
            (family_id,),
        )
    else:
        cursor = await db.execute(
            "SELECT MAX(updated_at) AS last_sync FROM sync_queue WHERE status = 'completed'",
        )
    row = await cursor.fetchone()
    last_sync = row["last_sync"] if row else None

    return SyncStatusResponse(
        status="ok",
        last_sync=last_sync,
        pending_count=pending_count,
    )
