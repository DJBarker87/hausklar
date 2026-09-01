"""Run-plan acceptance, plan matching/adherence and Garmin FIT export routes."""

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import FileResponse

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness_activity import ActivityLinkPayload
from app.services.fitness import activities, run_plans
from app.services.fitness.common import (
    FitnessConflictError,
    FitnessNotFoundError,
    owned_row,
)

router = APIRouter()


def _raise_domain(exc: Exception) -> None:
    if isinstance(exc, FitnessNotFoundError):
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(exc, FitnessConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if isinstance(exc, ValueError):
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    raise exc


@router.post(
    "/workout-definitions/{definition_id}/versions/{version_id}/accept"
)
async def accept_workout_version(
    definition_id: str,
    version_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await run_plans.accept_workout_version(
            db,
            user=current_user,
            definition_id=definition_id,
            version_id=version_id,
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.post("/planned-sessions/{planned_session_id}/link-activity")
async def link_planned_activity(
    planned_session_id: str,
    body: ActivityLinkPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await activities.link_activity_to_plan(
            db,
            user=current_user,
            activity_id=str(body.activity_id),
            planned_session_id=planned_session_id,
            match_method="user",
            user_confirmed=True,
            explanation=body.explanation,
        )
        result = await activities.activity_detail(
            db, user=current_user, activity_id=str(body.activity_id)
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.delete("/planned-sessions/{planned_session_id}/link-activity")
async def unlink_planned_activity(
    planned_session_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        plan = await owned_row(
            db,
            table="health_planned_sessions",
            record_id=planned_session_id,
            user=current_user,
        )
        if plan["completion_activity_id"]:
            await activities.unlink_activity_from_plan(
                db,
                user=current_user,
                activity_id=plan["completion_activity_id"],
            )
        await db.commit()
        return {"id": planned_session_id, "linked": False}
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/planned-sessions/{planned_session_id}/adherence")
async def planned_session_adherence(
    planned_session_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await activities.planned_session_adherence(
            db, user=current_user, planned_session_id=planned_session_id
        )
    except Exception as exc:
        _raise_domain(exc)


@router.post(
    "/workout-versions/{version_id}/garmin-exports",
    status_code=status.HTTP_202_ACCEPTED,
)
async def create_garmin_export(
    version_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await run_plans.create_garmin_export(
            db, user=current_user, version_id=version_id
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/garmin-exports/{export_id}")
async def get_garmin_export(
    export_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await run_plans.garmin_export_response(
            db, user=current_user, export_id=export_id
        )
    except Exception as exc:
        _raise_domain(exc)


@router.post(
    "/garmin-exports/{export_id}/retry",
    status_code=status.HTTP_202_ACCEPTED,
)
async def retry_garmin_export(
    export_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        result = await run_plans.retry_garmin_export(
            db, user=current_user, export_id=export_id
        )
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/garmin-exports/{export_id}/download")
async def download_garmin_export(
    export_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        path, filename = await run_plans.garmin_download_path(
            db, user=current_user, export_id=export_id
        )
        return FileResponse(
            path,
            media_type="application/vnd.ant.fit",
            filename=filename,
        )
    except Exception as exc:
        _raise_domain(exc)
