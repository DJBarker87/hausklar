"""Private Fitness activity/import/gear/analysis routes."""

from datetime import date, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    Header,
    HTTPException,
    Query,
    UploadFile,
    status,
)

from app.auth import get_current_user
from app.database import get_db
from app.fitness_registry import activity_registry
from app.models.fitness_analysis import AnalysisQueryPayload
from app.models.fitness_activity import (
    ActivityContextPatch,
    ActivityGoalLinksReplacePayload,
    GearDefaultPayload,
    GearPatch,
    GearPayload,
    HealthKitWorkoutImport,
    HealthKitWorkoutImportResponse,
    HealthKitWorkoutSourceMetadata,
    ManualActivityDefaults,
    ManualActivityPayload,
    WorkerCompletePayload,
    WorkerFailPayload,
    WorkerLeasePayload,
)
from app.services.fitness import activities, analysis, healthkit_workouts
from app.services.fitness.activity_import import (
    claim_job,
    complete_job,
    ensure_worker_token,
    fail_job,
    heartbeat_job,
    import_response,
    reconcile_assets,
    regenerate_activity_analysis,
    retry_fit_import,
    stage_fit_import,
)
from app.services.fitness.common import (
    FitnessConflictError,
    FitnessNotFoundError,
    append_change,
    decoded_row,
    owned_row,
)
from app.services.fitness.resource_limits import (
    fitness_upload_slot,
    reserve_fitness_upload,
)

router = APIRouter()
internal_router = APIRouter()


@router.get("/activity-registry")
async def get_activity_registry(current_user: dict = Depends(get_current_user)):
    return activity_registry()


def _raise_domain(exc: Exception) -> None:
    if isinstance(exc, FitnessNotFoundError):
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(exc, FitnessConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    raise exc


@router.post("/imports/fit", status_code=status.HTTP_202_ACCEPTED)
async def upload_fit(
    file: Annotated[UploadFile, File()],
    client_import_id: Annotated[str | None, Form(max_length=100)] = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await reserve_fitness_upload(db, user=current_user)
        with fitness_upload_slot(user=current_user):
            return await stage_fit_import(
                db,
                user=current_user,
                file=file,
                client_import_id=client_import_id,
            )
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@router.post(
    "/imports/healthkit-workout",
    response_model=HealthKitWorkoutImportResponse,
)
async def import_healthkit_workout(
    body: HealthKitWorkoutImport,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await healthkit_workouts.import_healthkit_workout(
            db, user=current_user, body=body
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get(
    "/imports/healthkit-workout/{workout_uuid}/sources",
    response_model=list[HealthKitWorkoutSourceMetadata],
)
async def healthkit_workout_sources(
    workout_uuid: UUID,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await healthkit_workouts.active_workout_sources(
        db, user=current_user, workout_uuid=workout_uuid
    )


@router.get("/imports/{import_id}")
async def get_import(
    import_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await import_response(db, user=current_user, import_id=import_id)
    except Exception as exc:
        _raise_domain(exc)


@router.post("/imports/{import_id}/retry", status_code=status.HTTP_202_ACCEPTED)
async def retry_import(
    import_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await retry_fit_import(db, user=current_user, import_id=import_id)
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@router.get("/activities")
async def get_activities(
    sport_key: str | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    from_date: date | None = None,
    to_date: date | None = None,
    phase_id: str | None = None,
    workout_classification: str | None = None,
    gear_id: str | None = None,
    status_filter: Annotated[str | None, Query(alias="status")] = None,
    offset: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await activities.list_activities(
        db,
        user=current_user,
        sport_key=sport_key,
        date_from=date_from or from_date,
        date_to=date_to or to_date,
        phase_id=phase_id,
        workout_classification=workout_classification,
        gear_id=gear_id,
        status=status_filter,
        offset=offset,
        limit=limit,
    )


@router.get("/activities/manual-defaults", response_model=ManualActivityDefaults)
async def get_manual_activity_defaults(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await activities.manual_activity_defaults(db, user=current_user)


@router.post("/activities/manual", status_code=status.HTTP_201_CREATED)
async def create_manual_activity(
    body: ManualActivityPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await activities.upsert_manual_activity(
            db, user=current_user, body=body
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/activities/{activity_id}")
async def get_activity(
    activity_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await activities.activity_detail(db, user=current_user, activity_id=activity_id)
    except Exception as exc:
        _raise_domain(exc)


@router.get("/activities/{activity_id}/streams")
async def get_activity_stream(
    activity_id: str,
    metrics: str = "pace_s_per_km,heart_rate_bpm",
    clock: Annotated[str, Query(pattern="^(elapsed|timer)$")] = "elapsed",
    from_offset_ms: Annotated[int | None, Query(ge=0)] = None,
    to_offset_ms: Annotated[int | None, Query(ge=0)] = None,
    max_points: Annotated[int | None, Query(ge=10, le=20_000)] = None,
    points: Annotated[int | None, Query(ge=10, le=20_000)] = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if from_offset_ms is not None and to_offset_ms is not None and to_offset_ms < from_offset_ms:
        raise HTTPException(status_code=422, detail="to_offset_ms must not precede from_offset_ms")
    try:
        return await activities.activity_stream(
            db,
            user=current_user,
            activity_id=activity_id,
            metrics=[item.strip() for item in metrics.split(",") if item.strip()],
            clock=clock,
            from_offset_ms=from_offset_ms,
            to_offset_ms=to_offset_ms,
            max_points=max_points or points or 2_000,
        )
    except Exception as exc:
        _raise_domain(exc)


@router.get("/activities/{activity_id}/analysis")
async def get_activity_analysis(
    activity_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await activities.activity_analysis(db, user=current_user, activity_id=activity_id)
    except Exception as exc:
        _raise_domain(exc)


@router.get("/activities/{activity_id}/comparisons")
async def get_activity_comparisons(
    activity_id: str,
    gear_id: str | None = None,
    phase_id: str | None = None,
    sensor_key: str | None = None,
    readiness_min: Annotated[float | None, Query(ge=1, le=5)] = None,
    readiness_max: Annotated[float | None, Query(ge=1, le=5)] = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if (
        readiness_min is not None
        and readiness_max is not None
        and readiness_min > readiness_max
    ):
        raise HTTPException(status_code=422, detail="readiness_min cannot exceed readiness_max")
    try:
        return await activities.comparable_runs(
            db,
            user=current_user,
            activity_id=activity_id,
            gear_id=gear_id,
            phase_id=phase_id,
            sensor_key=sensor_key,
            readiness_min=readiness_min,
            readiness_max=readiness_max,
        )
    except Exception as exc:
        _raise_domain(exc)


@router.get("/activities/{activity_id}/comparison-overlay")
async def get_activity_comparison_overlay(
    activity_id: str,
    comparison_ids: str = "",
    metrics: str = "pace_s_per_km,heart_rate_bpm",
    points: Annotated[int, Query(ge=20, le=500)] = 160,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await activities.distance_aligned_comparison_overlay(
            db,
            user=current_user,
            activity_id=activity_id,
            comparison_ids=[
                value.strip()
                for value in comparison_ids.split(",")
                if value.strip()
            ],
            metrics=[value.strip() for value in metrics.split(",") if value.strip()],
            points=points,
        )
    except Exception as exc:
        _raise_domain(exc)


@router.get("/activities/{activity_id}/adherence")
async def get_activity_adherence(
    activity_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await activities.activity_adherence(db, user=current_user, activity_id=activity_id)
    except Exception as exc:
        _raise_domain(exc)


@router.post(
    "/activities/{activity_id}/reanalyse",
    status_code=status.HTTP_202_ACCEPTED,
)
async def reanalyse_activity(
    activity_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await regenerate_activity_analysis(
            db,
            user=current_user,
            activity_id=activity_id,
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.patch("/activities/{activity_id}/context")
async def patch_activity(
    activity_id: str,
    body: ActivityContextPatch,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await activities.patch_activity_context(
            db, user=current_user, activity_id=activity_id, body=body
        )
        row = await owned_row(
            db,
            table="health_activities",
            record_id=activity_id,
            user=current_user,
        )
        await append_change(
            db,
            entity_type="activity_context",
            entity_id=activity_id,
            revision=int(row["revision"]),
            operation="upsert",
            user=current_user,
            data={
                "id": activity_id,
                "title": row["title"],
                "notes": result.get("notes"),
                "session_rpe": result.get("session_rpe"),
                "workout_classification": row["workout_classification"],
                "planned_session_id": row["planned_session_id"],
                "gear_ids": [item["id"] for item in result.get("gear", [])],
                "goal_links": result.get("goal_links", []),
                "revision": int(row["revision"]),
            },
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/activities/{activity_id}/goal-links")
async def get_activity_goal_links(
    activity_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await activities.list_activity_goal_links(
            db, user=current_user, activity_id=activity_id
        )
    except Exception as exc:
        _raise_domain(exc)


@router.put("/activities/{activity_id}/goal-links")
async def replace_activity_goal_links(
    activity_id: str,
    body: ActivityGoalLinksReplacePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await activities.replace_activity_goal_links(
            db,
            user=current_user,
            activity_id=activity_id,
            body=body,
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/gear")
async def get_gear(
    include_inactive: bool = False,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await activities.list_gear(
        db, user=current_user, include_inactive=include_inactive
    )


@router.post("/gear", status_code=status.HTTP_201_CREATED)
async def create_gear_item(
    body: GearPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await activities.create_gear(db, user=current_user, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/gear/{gear_id}")
async def get_gear_item(
    gear_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        row = await owned_row(
            db, table="health_gear_items", record_id=gear_id, user=current_user
        )
        return decoded_row(row)
    except Exception as exc:
        _raise_domain(exc)


@router.patch("/gear/{gear_id}")
async def update_gear_item(
    gear_id: str,
    body: GearPatch,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await activities.patch_gear(db, user=current_user, gear_id=gear_id, body=body)
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.delete("/gear/{gear_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_gear_item(
    gear_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await activities.delete_gear(db, user=current_user, gear_id=gear_id)
        await db.commit()
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/gear/{gear_id}/retire")
async def retire_gear_item(
    gear_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await activities.retire_gear(
            db, user=current_user, gear_id=gear_id
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/gear/{gear_id}/default")
async def make_gear_default(
    gear_id: str,
    body: GearDefaultPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await activities.set_gear_default(
            db, user=current_user, gear_id=gear_id, sport_key=body.sport_key
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/calendar-layer")
async def get_calendar_layer(
    start: date | None = None,
    end: date | None = None,
    include_completed: bool = False,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    range_start = start or date.today() - timedelta(days=30)
    range_end = end or date.today() + timedelta(days=90)
    if range_end < range_start or (range_end - range_start).days > 730:
        raise HTTPException(status_code=422, detail="Calendar range is invalid")
    return await activities.calendar_layer(
        db,
        user=current_user,
        start=range_start,
        end=range_end,
        include_completed=include_completed,
    )


@router.get("/running/load")
async def get_running_training_load(
    as_of: date | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await activities.running_training_load(
        db,
        user=current_user,
        as_of=as_of,
    )


@router.get("/analysis/registry")
async def get_analysis_registry(current_user: dict = Depends(get_current_user)):
    return analysis.registry()


@router.post("/analysis/query")
async def run_analysis_query(
    body: AnalysisQueryPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await analysis.submit_query(db, user=current_user, body=body)
    except Exception as exc:
        _raise_domain(exc)


@router.post("/files/reconcile")
async def reconcile_fitness_files(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await reconcile_assets(db, user=current_user)


@internal_router.post("/jobs/claim")
async def worker_claim(
    worker_token: Annotated[str | None, Header(alias="X-Fitness-Worker-Token")] = None,
    db=Depends(get_db),
):
    ensure_worker_token(worker_token)
    try:
        return {"job": await claim_job(db)}
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@internal_router.post("/jobs/{job_id}/heartbeat")
async def worker_heartbeat(
    job_id: str,
    body: WorkerLeasePayload,
    worker_token: Annotated[str | None, Header(alias="X-Fitness-Worker-Token")] = None,
    db=Depends(get_db),
):
    ensure_worker_token(worker_token)
    try:
        return await heartbeat_job(db, job_id=job_id, lease_token=body.lease_token)
    except Exception as exc:
        _raise_domain(exc)


@internal_router.post("/jobs/{job_id}/complete")
async def worker_complete(
    job_id: str,
    body: WorkerCompletePayload,
    worker_token: Annotated[str | None, Header(alias="X-Fitness-Worker-Token")] = None,
    db=Depends(get_db),
):
    ensure_worker_token(worker_token)
    try:
        return await complete_job(
            db,
            job_id=job_id,
            lease_token=body.lease_token,
        )
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@internal_router.post("/jobs/{job_id}/fail")
async def worker_fail(
    job_id: str,
    body: WorkerFailPayload,
    worker_token: Annotated[str | None, Header(alias="X-Fitness-Worker-Token")] = None,
    db=Depends(get_db),
):
    ensure_worker_token(worker_token)
    try:
        return await fail_job(
            db,
            job_id=job_id,
            lease_token=body.lease_token,
            error_code=body.error_code,
            error=body.error,
            retryable=body.retryable,
        )
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)
