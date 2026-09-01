"""Polling and owner-private saved definitions for registered Fitness analysis."""

from fastapi import APIRouter, Depends, HTTPException, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness_analysis import SavedAnalysisChartPayload
from app.services.fitness import analysis
from app.services.fitness.common import FitnessConflictError, FitnessNotFoundError

router = APIRouter()


def _raise_domain(exc: Exception) -> None:
    if isinstance(exc, FitnessNotFoundError):
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(exc, FitnessConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    raise exc


@router.get("/analysis/jobs/{job_id}")
async def get_analysis_job(
    job_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await analysis.analysis_job(db, user=current_user, job_id=job_id)
    except Exception as exc:
        _raise_domain(exc)


@router.get("/analysis/charts")
async def get_saved_analysis_charts(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await analysis.list_saved_charts(db, user=current_user)


@router.post("/analysis/charts", status_code=status.HTTP_201_CREATED)
async def create_saved_analysis_chart(
    body: SavedAnalysisChartPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await analysis.save_chart(db, user=current_user, body=body)
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)


@router.delete("/analysis/charts/{chart_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_saved_analysis_chart(
    chart_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        await analysis.delete_saved_chart(db, user=current_user, chart_id=chart_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        _raise_domain(exc)
