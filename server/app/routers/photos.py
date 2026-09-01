"""Photo memories, chapters, and thumbnail proxy for the family archive."""

import re
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response

from app.auth import get_current_user
from app.database import get_db
from app.services.photos import (
    fetch_thumbnail,
    photo_chapters,
    photo_memories,
    search_photos,
)

router = APIRouter()

_ASSET_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")


@router.get("/memories")
async def get_memories(
    timezone_name: str = Query("Europe/London", alias="timezone", max_length=50),
    current_user: dict = Depends(get_current_user),
):
    """Photos taken this week in previous years."""
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "memories": await photo_memories(timezone_name=timezone_name),
    }


@router.get("/chapters")
async def get_chapters(
    timezone_name: str = Query("Europe/London", alias="timezone", max_length=50),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Life-event photo chapters assembled from family data."""
    return {
        "chapters": await photo_chapters(
            db,
            family_id=current_user["family_id"],
            timezone_name=timezone_name,
        )
    }


@router.get("/search")
async def search(
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(30, ge=1, le=60),
    current_user: dict = Depends(get_current_user),
):
    """Semantic search of the family photo archive."""
    return {"query": q, "results": await search_photos(query=q, limit=limit)}


@router.get("/{asset_id}/thumbnail")
async def get_thumbnail(
    asset_id: str,
    size: str = Query("preview", max_length=20),
    current_user: dict = Depends(get_current_user),
):
    if not _ASSET_ID.fullmatch(asset_id):
        raise HTTPException(status_code=422, detail="Invalid photo id")
    result = await fetch_thumbnail(asset_id, size)
    if not result:
        raise HTTPException(status_code=404, detail="Photo not found")
    content, media_type = result
    return Response(
        content=content,
        media_type=media_type,
        headers={"Cache-Control": "private, max-age=86400"},
    )
