"""Self-service controls for an adult's short, content-free usage history."""

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.adoption import (
    UsageHistoryClearResponse,
    UsageHistoryEventExport,
    UsageHistoryExport,
    UsageHistoryPreferenceResponse,
    UsageHistoryPreferenceUpdate,
    UsageHistorySummary,
    UsageInteractionBatch,
    UsageControlSummary,
    UsageModuleSummary,
    UsageScreenSummary,
    UsageWorkflowSummary,
)
from app.services.adoption import (
    RETENTION_DAYS,
    SHARED_MODULES,
    cleanup_expired_adoption_events,
    record_client_interactions,
    safe_client_metadata,
    set_usage_history_enabled,
    usage_history_enabled,
)


router = APIRouter()


@router.post("/events", status_code=status.HTTP_204_NO_CONTENT)
async def append_usage_interactions(
    body: UsageInteractionBatch,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Accept only reviewed semantic IDs; arbitrary labels and content are rejected."""
    source, version = safe_client_metadata(request.headers)
    try:
        await record_client_interactions(
            db,
            user=current_user,
            events=body.events,
            entry_source=source,
            app_version=version,
        )
    except ValueError as exc:
        await db.rollback()
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/preferences", response_model=UsageHistoryPreferenceResponse)
async def get_usage_history_preferences(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    enabled = await usage_history_enabled(
        db, user_id=current_user["id"], family_id=current_user["family_id"]
    )
    return UsageHistoryPreferenceResponse(enabled=enabled)


@router.patch("/preferences", response_model=UsageHistoryPreferenceResponse)
async def update_usage_history_preferences(
    body: UsageHistoryPreferenceUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await set_usage_history_enabled(db, user=current_user, enabled=body.enabled)
    await db.commit()
    return UsageHistoryPreferenceResponse(enabled=body.enabled)


@router.get("/summary", response_model=UsageHistorySummary)
async def get_usage_history_summary(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    now = datetime.now(timezone.utc)
    if await cleanup_expired_adoption_events(db, now=now):
        await db.commit()
    cutoff = (now - timedelta(days=RETENTION_DAYS)).isoformat()
    owner = await (
        await db.execute(
            """
            SELECT COUNT(*) AS actions,
                   SUM(CASE WHEN outcome = 'failed' THEN 1 ELSE 0 END) AS failed_actions,
                   SUM(CASE WHEN outcome != 'failed' THEN 1 ELSE 0 END) AS useful_actions,
                   COUNT(DISTINCT CASE WHEN outcome != 'failed' THEN date(created_at) END) AS active_days,
                   MAX(created_at) AS last_action_at
            FROM adoption_events
            WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL
              AND datetime(created_at) >= datetime(?)
              AND event_kind = 'server_action'
            """,
            (current_user["id"], current_user["family_id"], cutoff),
        )
    ).fetchone()
    modules = await (
        await db.execute(
            """
            SELECT module, COUNT(*) AS actions,
                   COUNT(DISTINCT date(created_at)) AS active_days
            FROM adoption_events
            WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL
              AND datetime(created_at) >= datetime(?)
              AND event_kind = 'server_action'
              AND outcome != 'failed'
            GROUP BY module
            HAVING COUNT(DISTINCT date(created_at)) >= 2
            ORDER BY actions DESC, module ASC
            """,
            (current_user["id"], current_user["family_id"], cutoff),
        )
    ).fetchall()
    placeholders = ",".join("?" for _ in SHARED_MODULES)
    shared = await (
        await db.execute(
            f"""
            SELECT COUNT(*) AS actions, COUNT(DISTINCT e.user_id) AS adults
            FROM adoption_events e
            JOIN users u ON u.id = e.user_id AND u.family_id = e.family_id
            WHERE e.family_id = ? AND e.deleted_at IS NULL
              AND u.deleted_at IS NULL
              AND datetime(e.created_at) >= datetime(?)
              AND e.outcome != 'failed'
              AND e.event_kind = 'server_action'
              AND e.module IN ({placeholders})
            """,
            (current_user["family_id"], cutoff, *sorted(SHARED_MODULES)),
        )
    ).fetchone()
    screens = await (
        await db.execute(
            """
            SELECT module, surface, COUNT(*) AS views,
                   COUNT(DISTINCT date(COALESCE(client_timestamp, created_at))) AS active_days
            FROM adoption_events
            WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL
              AND datetime(created_at) >= datetime(?)
              AND event_kind = 'screen_view' AND outcome = 'viewed'
            GROUP BY module, surface
            ORDER BY views DESC, module, surface
            LIMIT 20
            """,
            (current_user["id"], current_user["family_id"], cutoff),
        )
    ).fetchall()
    controls = await (
        await db.execute(
            """
            SELECT module, action, surface, COUNT(*) AS presses,
                   COUNT(DISTINCT date(COALESCE(client_timestamp, created_at))) AS active_days
            FROM adoption_events
            WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL
              AND datetime(created_at) >= datetime(?)
              AND event_kind = 'control' AND outcome = 'tapped'
            GROUP BY module, action, surface
            ORDER BY presses DESC, module, action, surface
            LIMIT 30
            """,
            (current_user["id"], current_user["family_id"], cutoff),
        )
    ).fetchall()
    workflows = await (
        await db.execute(
            """
            SELECT module, workflow, action,
                   COUNT(DISTINCT CASE WHEN outcome = 'started' THEN workflow_run_id END) AS starts,
                   COUNT(DISTINCT CASE WHEN outcome = 'completed' THEN workflow_run_id END) AS completions,
                   COUNT(DISTINCT CASE WHEN outcome = 'failed' THEN workflow_run_id END) AS failures,
                   COUNT(DISTINCT CASE WHEN outcome IN ('abandoned', 'cancelled') THEN workflow_run_id END) AS abandonments,
                   COUNT(DISTINCT CASE WHEN outcome = 'completed' AND connectivity = 'queued' THEN workflow_run_id END) AS queued_completions,
                   AVG(CASE WHEN outcome = 'completed' THEN interaction_count END) AS average_interactions
            FROM adoption_events
            WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL
              AND datetime(created_at) >= datetime(?)
              AND event_kind = 'workflow' AND workflow IS NOT NULL
            GROUP BY module, workflow, action
            ORDER BY completions DESC, starts DESC, module, workflow, action
            LIMIT 30
            """,
            (current_user["id"], current_user["family_id"], cutoff),
        )
    ).fetchall()
    enabled = await usage_history_enabled(
        db, user_id=current_user["id"], family_id=current_user["family_id"]
    )
    meaningful_actions = int(owner["useful_actions"] or 0)
    active_days = int(owner["active_days"] or 0)
    use_signal = (
        "returning"
        if meaningful_actions >= 2 and active_days >= 2
        else "started"
        if meaningful_actions > 0
        else "not_started"
    )
    return UsageHistorySummary(
        enabled=enabled,
        meaningful_actions=meaningful_actions,
        failed_actions=int(owner["failed_actions"] or 0),
        active_days=active_days,
        use_signal=use_signal,
        repeat_modules=[
            UsageModuleSummary(
                module=row["module"],
                actions=int(row["actions"]),
                active_days=int(row["active_days"]),
            )
            for row in modules
        ],
        both_adults_contributed=int(shared["adults"] or 0) >= 2,
        shared_family_actions=int(shared["actions"] or 0),
        screen_views=[
            UsageScreenSummary(
                module=row["module"],
                surface=row["surface"],
                views=int(row["views"]),
                active_days=int(row["active_days"]),
            )
            for row in screens
        ],
        control_uses=[
            UsageControlSummary(
                module=row["module"],
                action=row["action"],
                surface=row["surface"],
                presses=int(row["presses"]),
                active_days=int(row["active_days"]),
            )
            for row in controls
        ],
        workflows=[
            UsageWorkflowSummary(
                module=row["module"],
                workflow=row["workflow"],
                action=row["action"],
                starts=int(row["starts"]),
                completions=int(row["completions"]),
                failures=int(row["failures"]),
                abandonments=int(row["abandonments"]),
                queued_completions=int(row["queued_completions"]),
                average_interactions=(
                    round(float(row["average_interactions"]), 1)
                    if row["average_interactions"] is not None
                    else None
                ),
            )
            for row in workflows
        ],
        last_action_at=owner["last_action_at"],
    )


@router.get("/export", response_model=UsageHistoryExport)
async def export_usage_history(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    now = datetime.now(timezone.utc)
    if await cleanup_expired_adoption_events(db, now=now):
        await db.commit()
    cutoff = (now - timedelta(days=RETENTION_DAYS)).isoformat()
    rows = await (
        await db.execute(
            """
            SELECT module, action, outcome, entry_source, effort, app_version,
                   event_kind, surface, workflow, workflow_run_id, duration_bucket,
                   interaction_count, connectivity, failure_class,
                   COALESCE(client_timestamp, created_at) AS recorded_at
            FROM adoption_events
            WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL
              AND datetime(created_at) >= datetime(?)
            ORDER BY created_at ASC
            """,
            (current_user["id"], current_user["family_id"], cutoff),
        )
    ).fetchall()
    return UsageHistoryExport(
        generated_at=now.isoformat(),
        events=[
            UsageHistoryEventExport(
                module=row["module"],
                action=row["action"],
                outcome=row["outcome"],
                entry_source=row["entry_source"],
                effort=row["effort"],
                app_version=row["app_version"],
                event_kind=row["event_kind"],
                surface=row["surface"],
                workflow=row["workflow"],
                workflow_run_id=row["workflow_run_id"],
                duration_bucket=row["duration_bucket"],
                interaction_count=row["interaction_count"],
                connectivity=row["connectivity"],
                failure_class=row["failure_class"],
                recorded_at=row["recorded_at"],
            )
            for row in rows
        ],
    )


@router.delete("/", response_model=UsageHistoryClearResponse)
async def clear_usage_history(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    now = datetime.now(timezone.utc).isoformat()
    cursor = await db.execute(
        "UPDATE adoption_events SET deleted_at = ?, updated_at = ? "
        "WHERE user_id = ? AND family_id = ? AND deleted_at IS NULL",
        (now, now, current_user["id"], current_user["family_id"]),
    )
    await db.commit()
    return UsageHistoryClearResponse(cleared=max(cursor.rowcount, 0))
