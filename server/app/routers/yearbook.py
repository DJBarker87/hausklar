"""Yearbook API — a composed, keepsake view of a child's year."""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Path, Request
from pydantic import BaseModel, Field

from app.auth import get_current_user
from app.database import get_db
from app.middleware.rate_limit import RateLimiter, extract_client_ip
from app.services.yearbook import (
    available_years,
    compose_yearbook,
    save_yearbook_arrangement,
    yearbook_candidates,
)
from app.services.ai_consent import require_ai_consent

router = APIRouter()
# Narrative generation calls the LLM bridge; keep refreshes bounded.
_refresh_limiter = RateLimiter(max_attempts=10, window_seconds=3_600)

_MIN_YEAR = 2000


class YearbookArrangement(BaseModel):
    artwork_ids: list[str] = Field(default_factory=list, max_length=60)
    photo_ids: list[str] = Field(default_factory=list, max_length=60)


def _valid_year(year: int) -> int:
    if not _MIN_YEAR <= year <= datetime.now(timezone.utc).year + 1:
        raise HTTPException(status_code=422, detail="That year is out of range")
    return year


@router.get("/{child_id}/years")
async def get_years(
    child_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return {
        "years": await available_years(db, family_id=current_user["family_id"], child_id=child_id)
    }


@router.get("/{child_id}/{year}")
async def get_yearbook(
    child_id: str,
    year: int = Path(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    yearbook = await compose_yearbook(
        db,
        family_id=current_user["family_id"],
        child_id=child_id,
        year=_valid_year(year),
        generate_narrative=False,
    )
    if not yearbook:
        raise HTTPException(status_code=404, detail="Child not found")
    return yearbook


@router.get("/{child_id}/{year}/options")
async def get_yearbook_options(
    child_id: str,
    year: int = Path(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    candidates = await yearbook_candidates(
        db,
        family_id=current_user["family_id"],
        child_id=child_id,
        year=_valid_year(year),
    )
    if candidates is None:
        raise HTTPException(status_code=404, detail="Child not found")
    return candidates


@router.put("/{child_id}/{year}/arrangement")
async def update_yearbook_arrangement(
    child_id: str,
    body: YearbookArrangement,
    year: int = Path(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        yearbook = await save_yearbook_arrangement(
            db,
            family_id=current_user["family_id"],
            child_id=child_id,
            year=_valid_year(year),
            artwork_ids=body.artwork_ids,
            photo_ids=body.photo_ids,
            changed_by=current_user["id"],
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if yearbook is None:
        raise HTTPException(status_code=404, detail="Child not found")
    return yearbook


@router.post("/{child_id}/{year}/refresh")
async def refresh_narrative(
    child_id: str,
    request: Request,
    year: int = Path(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Regenerate the Bismarck narrative for the current facts."""
    require_ai_consent(current_user)
    key = f"yearbook-refresh:{current_user['id']}:{extract_client_ip(request)}"
    _refresh_limiter.ensure_allowed(
        key,
        detail_prefix="Too many yearbook refreshes",  # gitleaks:allow
    )
    _refresh_limiter.record_failure(key)
    year = _valid_year(year)
    # Drop the cached narrative so compose regenerates it from current facts.
    await db.execute(
        "UPDATE yearbook_narratives SET deleted_at = ? "
        "WHERE family_id = ? AND child_id = ? AND year = ? AND deleted_at IS NULL",
        (datetime.now(timezone.utc).isoformat(), current_user["family_id"], child_id, year),
    )
    await db.commit()
    yearbook = await compose_yearbook(
        db,
        family_id=current_user["family_id"],
        child_id=child_id,
        year=year,
        generate_narrative=True,
    )
    if not yearbook:
        raise HTTPException(status_code=404, detail="Child not found")
    return yearbook
