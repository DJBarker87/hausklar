"""Compact contracts for the authenticated same-origin Fitness basemap."""

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


PrivateMapFormat = Literal["png", "jpg", "webp", "pbf"]


class PrivateMapModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PrivateMapAvailability(PrivateMapModel):
    available: bool
    format: PrivateMapFormat | None = None
    min_zoom: int | None = Field(default=None, ge=0, le=22)
    max_zoom: int | None = Field(default=None, ge=0, le=22)
    bounds: tuple[float, float, float, float] | None = None
    style_url: str | None = None
    tilejson_url: str | None = None
    has_sprites: bool | None = None
    has_glyphs: bool | None = None


class PrivateMapTileJSON(PrivateMapModel):
    tilejson: Literal["3.0.0"] = "3.0.0"
    name: str = Field(min_length=1, max_length=200)
    scheme: Literal["xyz"] = "xyz"
    tiles: list[str] = Field(min_length=1, max_length=1)
    minzoom: int = Field(ge=0, le=22)
    maxzoom: int = Field(ge=0, le=22)
    bounds: tuple[float, float, float, float]
    vector_layers: list[dict[str, Any]] | None = Field(default=None, max_length=64)


class PrivateMapStyle(PrivateMapModel):
    version: Literal[8] = 8
    name: str = Field(min_length=1, max_length=200)
    sources: dict[str, dict[str, Any]]
    layers: list[dict[str, Any]] = Field(min_length=1, max_length=256)
    sprite: str | None = None
    glyphs: str | None = None
