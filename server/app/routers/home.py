import httpx
from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response

from app.auth import get_current_user
from app.models.audiobooks import (
    AudiobookItemDetail,
    AudiobookLibrariesResponse,
    AudiobookLibraryItemsResponse,
    AudiobookPlayRequest,
    AudiobookPlayResponse,
    AudiobookProgressRequest,
    AudiobookProgressResponse,
)
from app.models.home import (
    HomeActionRequest,
    HomeActionResponse,
    HomeBroadActionRequest,
    HomeBroadActionResponse,
    HomeFavouritesRequest,
    HomeFavouritesResponse,
    HomeLayoutResponse,
    HomeServiceRequest,
    HomeSnapshotResponse,
    HomeTemperatureHistoryResponse,
)
from app.services.home_assistant import (
    get_home_snapshot_for_family,
    get_home_temperature_history_for_family,
    get_camera_snapshot_for_family,
    get_media_thumbnail_for_family,
    home_is_configured_for_family,
    perform_home_action_for_family,
    perform_home_broad_action_for_family,
    perform_home_service_for_family,
    save_home_favourites_for_family,
)
from app.services.media_thumbnails import (
    ThumbnailNotFound,
    ThumbnailUnavailable,
    UnsafeThumbnailSource,
)
from app.services.audiobooks import (
    AudiobookUnavailable,
    cover_for_family,
    item_for_family,
    libraries_for_family,
    library_items_for_family,
    play_for_family,
    update_progress_for_family,
)
from app.services.home_layout import HOME_LAYOUT

router = APIRouter()


@router.get(
    "/status",
    response_model=HomeSnapshotResponse,
    response_model_exclude_none=True,
)
async def home_status(current_user: dict = Depends(get_current_user)):
    return await get_home_snapshot_for_family(current_user["family_id"])


@router.get("/layout", response_model=HomeLayoutResponse)
async def home_layout(current_user: dict = Depends(get_current_user)):
    """Return the private household layout only to an authenticated family user."""
    if not await home_is_configured_for_family(current_user["family_id"]):
        raise HTTPException(status_code=404, detail="A house map is not configured for this family")
    return HOME_LAYOUT


@router.get(
    "/temperature-history/{entity_id}",
    response_model=HomeTemperatureHistoryResponse,
    response_model_exclude_none=True,
)
async def home_temperature_history(
    entity_id: str = Path(pattern=r"^[a-z0-9_]+\.[a-z0-9_]+$"),
    current_user: dict = Depends(get_current_user),
):
    """Return one bounded, sanitised room-temperature series."""
    try:
        return await get_home_temperature_history_for_family(
            current_user["family_id"],
            entity_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=502,
            detail="Home Assistant could not provide room-temperature history",
        ) from exc


@router.get("/cameras/{entity_id}/snapshot", response_class=Response)
async def home_camera_snapshot(
    entity_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Return one bounded image from a concrete camera through family HA credentials."""
    try:
        body, media_type = await get_camera_snapshot_for_family(
            current_user["family_id"], entity_id
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="Home Assistant could not provide the camera image") from exc
    return Response(
        content=body,
        media_type=media_type,
        headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"},
    )


@router.get("/media/thumbnails/{thumbnail_id}", response_class=Response)
async def home_media_thumbnail(
    thumbnail_id: str = Path(pattern=r"^[0-9a-f]{32}$"),
    current_user: dict = Depends(get_current_user),
):
    """Return one approved artwork image without exposing its upstream URL."""
    try:
        body, media_type = await get_media_thumbnail_for_family(
            current_user["family_id"], thumbnail_id
        )
    except (ThumbnailNotFound, UnsafeThumbnailSource) as exc:
        raise HTTPException(status_code=404, detail="That media thumbnail is unavailable") from exc
    except ThumbnailUnavailable as exc:
        raise HTTPException(status_code=502, detail="The media thumbnail is unavailable") from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="The media thumbnail is unavailable") from exc
    return Response(
        content=body,
        media_type=media_type,
        headers={
            "Cache-Control": "private, max-age=300",
            "Vary": "Authorization",
            "X-Content-Type-Options": "nosniff",
        },
    )


def _audiobook_error(exc: Exception) -> HTTPException:
    if isinstance(exc, PermissionError):
        return HTTPException(status_code=403, detail=str(exc))
    if isinstance(exc, ValueError):
        return HTTPException(status_code=404, detail=str(exc))
    if isinstance(exc, AudiobookUnavailable):
        return HTTPException(status_code=503, detail=str(exc))
    if isinstance(exc, httpx.HTTPError):
        return HTTPException(status_code=502, detail="The audiobook service is unavailable")
    return HTTPException(status_code=503, detail="The audiobook service is unavailable")


@router.get("/audiobooks/libraries", response_model=AudiobookLibrariesResponse)
async def audiobook_libraries(current_user: dict = Depends(get_current_user)):
    try:
        return await libraries_for_family(current_user["family_id"])
    except (PermissionError, ValueError, AudiobookUnavailable, httpx.HTTPError) as exc:
        raise _audiobook_error(exc) from exc


@router.get(
    "/audiobooks/libraries/{library_id}/items",
    response_model=AudiobookLibraryItemsResponse,
)
async def audiobook_library_items(
    library_id: str,
    limit: int = Query(default=100, ge=1, le=100),
    current_user: dict = Depends(get_current_user),
):
    try:
        return await library_items_for_family(
            current_user["family_id"], library_id, limit
        )
    except (PermissionError, ValueError, AudiobookUnavailable, httpx.HTTPError) as exc:
        raise _audiobook_error(exc) from exc


@router.get("/audiobooks/items/{item_id}", response_model=AudiobookItemDetail)
async def audiobook_item(
    item_id: str,
    current_user: dict = Depends(get_current_user),
):
    try:
        return await item_for_family(current_user["family_id"], item_id)
    except (PermissionError, ValueError, AudiobookUnavailable, httpx.HTTPError) as exc:
        raise _audiobook_error(exc) from exc


@router.get("/audiobooks/items/{item_id}/cover", response_class=Response)
async def audiobook_cover(
    item_id: str,
    current_user: dict = Depends(get_current_user),
):
    try:
        body, media_type = await cover_for_family(current_user["family_id"], item_id)
    except (PermissionError, ValueError, AudiobookUnavailable, httpx.HTTPError) as exc:
        raise _audiobook_error(exc) from exc
    return Response(
        content=body,
        media_type=media_type,
        headers={"Cache-Control": "private, max-age=3600", "X-Content-Type-Options": "nosniff"},
    )


@router.patch(
    "/audiobooks/items/{item_id}/progress",
    response_model=AudiobookProgressResponse,
)
async def audiobook_progress(
    item_id: str,
    body: AudiobookProgressRequest,
    current_user: dict = Depends(get_current_user),
):
    try:
        await update_progress_for_family(current_user["family_id"], item_id, body)
    except (PermissionError, ValueError, AudiobookUnavailable, httpx.HTTPError) as exc:
        raise _audiobook_error(exc) from exc
    return AudiobookProgressResponse(success=True)


@router.post(
    "/audiobooks/items/{item_id}/play",
    response_model=AudiobookPlayResponse,
)
async def audiobook_play(
    item_id: str,
    body: AudiobookPlayRequest,
    current_user: dict = Depends(get_current_user),
):
    try:
        return await play_for_family(current_user["family_id"], item_id, body)
    except (PermissionError, ValueError, AudiobookUnavailable, httpx.HTTPError) as exc:
        raise _audiobook_error(exc) from exc


@router.post("/actions", response_model=HomeActionResponse)
async def home_action(
    body: HomeActionRequest,
    current_user: dict = Depends(get_current_user),
):
    try:
        await perform_home_action_for_family(current_user["family_id"], body)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="Home Assistant did not accept the action") from exc
    return HomeActionResponse(success=True, entity_id=body.entity_id, action=body.action)


@router.put("/favourites", response_model=HomeFavouritesResponse)
async def home_favourites(
    body: HomeFavouritesRequest,
    current_user: dict = Depends(get_current_user),
):
    try:
        entity_ids = await save_home_favourites_for_family(
            current_user["family_id"],
            current_user["id"],
            body.entity_ids,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="Home Assistant could not verify favourites") from exc
    return HomeFavouritesResponse(entity_ids=entity_ids)


@router.post("/broad-actions", response_model=HomeBroadActionResponse)
async def home_broad_action(
    body: HomeBroadActionRequest,
    current_user: dict = Depends(get_current_user),
):
    try:
        entity_ids = await perform_home_broad_action_for_family(
            current_user["family_id"],
            body,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="Home Assistant did not accept the action") from exc
    return HomeBroadActionResponse(
        success=True,
        action=body.action,
        scope=body.scope,
        entity_ids=entity_ids,
    )


@router.post("/services")
async def home_service(
    body: HomeServiceRequest,
    current_user: dict = Depends(get_current_user),
):
    """Run one explicitly allowlisted Home Assistant service without exposing its token."""
    try:
        return await perform_home_service_for_family(current_user["family_id"], body)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="Home Assistant did not accept the action") from exc
