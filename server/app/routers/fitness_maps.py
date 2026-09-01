"""Authenticated same-origin delivery for the optional private Fitness basemap."""

from __future__ import annotations

import hashlib
import json

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel

from app.auth import get_current_user
from app.models.fitness_maps import (
    PrivateMapAvailability,
    PrivateMapStyle,
    PrivateMapTileJSON,
)
from app.services.fitness import private_maps


router = APIRouter()

_METADATA_CACHE_SECONDS = 60
_STYLE_CACHE_SECONDS = 300
_TILE_CACHE_SECONDS = 86_400


def _etag_matches(request: Request, etag: str) -> bool:
    supplied = request.headers.get("if-none-match")
    if supplied is None:
        return False
    target = etag.removeprefix("W/")
    return any(
        candidate == "*" or candidate.removeprefix("W/") == target
        for candidate in (value.strip() for value in supplied.split(","))
    )


def _private_headers(*, etag: str, max_age: int) -> dict[str, str]:
    return {
        "Cache-Control": f"private, max-age={max_age}",
        "ETag": etag,
        "Vary": "Authorization, Cookie",
    }


def _model_response(
    model: BaseModel,
    *,
    request: Request,
    max_age: int,
) -> Response:
    payload = json.dumps(
        model.model_dump(mode="json", exclude_none=True),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    etag = f'"{hashlib.sha256(payload).hexdigest()}"'
    headers = _private_headers(etag=etag, max_age=max_age)
    if _etag_matches(request, etag):
        return Response(status_code=status.HTTP_304_NOT_MODIFIED, headers=headers)
    return Response(
        content=payload,
        media_type="application/json",
        headers=headers,
    )


def _asset_response(
    asset: private_maps.PrivateMapTile | private_maps.PrivateMapAsset | None,
    *,
    request: Request,
) -> Response:
    if asset is None:
        raise HTTPException(status_code=404, detail="Private map asset not found")
    headers = _private_headers(etag=asset.etag, max_age=_TILE_CACHE_SECONDS)
    if asset.content_encoding is not None:
        headers["Content-Encoding"] = asset.content_encoding
    if _etag_matches(request, asset.etag):
        return Response(status_code=status.HTTP_304_NOT_MODIFIED, headers=headers)
    return Response(content=asset.data, media_type=asset.media_type, headers=headers)


@router.get("/maps", response_model=PrivateMapAvailability)
async def get_private_map_availability(
    request: Request,
    _current_user: dict = Depends(get_current_user),
) -> Response:
    """Return a compact capability contract; an absent archive is normal."""
    return _model_response(
        await private_maps.availability(),
        request=request,
        max_age=_METADATA_CACHE_SECONDS,
    )


@router.get("/maps/style.json", response_model=PrivateMapStyle)
async def get_private_map_style(
    request: Request,
    _current_user: dict = Depends(get_current_user),
) -> Response:
    """Return a local style, including a neutral source-free fallback."""
    return _model_response(
        await private_maps.style(),
        request=request,
        max_age=_STYLE_CACHE_SECONDS,
    )


@router.get("/maps/tilejson.json", response_model=PrivateMapTileJSON)
async def get_private_map_tilejson(
    request: Request,
    _current_user: dict = Depends(get_current_user),
) -> Response:
    model = await private_maps.tilejson()
    if model is None:
        raise HTTPException(status_code=404, detail="Private map asset not found")
    return _model_response(model, request=request, max_age=_STYLE_CACHE_SECONDS)


@router.get("/maps/tiles/{zoom}/{column}/{row}.{extension}")
async def get_private_map_tile(
    zoom: int,
    column: int,
    row: int,
    extension: str,
    request: Request,
    _current_user: dict = Depends(get_current_user),
) -> Response:
    return _asset_response(
        await private_maps.tile(
            zoom=zoom,
            column=column,
            row=row,
            extension=extension,
        ),
        request=request,
    )


@router.get("/maps/sprites/{filename}")
async def get_private_map_sprite(
    filename: str,
    request: Request,
    _current_user: dict = Depends(get_current_user),
) -> Response:
    return _asset_response(await private_maps.sprite(filename), request=request)


@router.get("/maps/glyphs/{fontstack}/{glyph_range}.pbf")
async def get_private_map_glyph(
    fontstack: str,
    glyph_range: str,
    request: Request,
    _current_user: dict = Depends(get_current_user),
) -> Response:
    return _asset_response(
        await private_maps.glyph(fontstack, glyph_range),
        request=request,
    )
