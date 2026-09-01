"""Read a fixed local MBTiles 1.3 basemap without blocking the event loop."""

from __future__ import annotations

import asyncio
import hashlib
import json
import math
import re
import sqlite3
import threading
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from weakref import WeakKeyDictionary

from app.config import settings
from app.models.fitness_maps import (
    PrivateMapAvailability,
    PrivateMapStyle,
    PrivateMapTileJSON,
)


WORLD_BOUNDS = (-180.0, -85.05112878, 180.0, 85.05112878)
MAX_ZOOM = 22
INSPECTION_SAMPLE_LIMIT = 32
STYLE_URL = "/api/fitness/maps/style.json"
TILEJSON_URL = "/api/fitness/maps/tilejson.json"
SPRITE_URL = "/api/fitness/maps/sprites/sprite"
GLYPH_URL = "/api/fitness/maps/glyphs/{fontstack}/{range}.pbf"
SPRITE_FILENAMES = frozenset(
    {"sprite.json", "sprite.png", "sprite" + "@2x.json", "sprite" + "@2x.png"}
)
GLYPH_RANGE_RE = re.compile(r"^(0|[1-9][0-9]{0,6})-([1-9][0-9]{0,6})$")
FORMAT_DETAILS = {
    "png": ("png", "image/png"),
    "jpg": ("jpg", "image/jpeg"),
    "jpeg": ("jpg", "image/jpeg"),
    "webp": ("webp", "image/webp"),
    "pbf": ("pbf", "application/vnd.mapbox-vector-tile"),
}
REQUIRED_METADATA = frozenset({"name", "format"})
METADATA_KEYS = (
    "name",
    "type",
    "version",
    "description",
    "format",
    "bounds",
    "center",
    "minzoom",
    "maxzoom",
    "json",
)


class PrivateMapArchiveError(ValueError):
    """The configured archive cannot safely satisfy the private-map contract."""


@dataclass(frozen=True)
class PrivateMapConfig:
    archive_path: Path | None
    sprite_root: Path | None
    glyph_root: Path | None
    glyph_fontstacks: tuple[str, ...]
    max_tile_bytes: int
    max_uncompressed_tile_bytes: int
    max_asset_bytes: int


@dataclass(frozen=True)
class PrivateMapArchive:
    path: Path
    fingerprint: str
    name: str
    tile_format: str
    extension: str
    media_type: str
    min_zoom: int
    max_zoom: int
    bounds: tuple[float, float, float, float]
    vector_layers: tuple[dict[str, Any], ...]


@dataclass(frozen=True)
class PrivateMapTile:
    data: bytes
    media_type: str
    content_encoding: str | None
    etag: str


@dataclass(frozen=True)
class PrivateMapAsset:
    data: bytes
    media_type: str
    content_encoding: str | None
    etag: str


_cache_lock = threading.Lock()
_inspection_cache: tuple[tuple[Any, ...], PrivateMapArchive | None] | None = None
_gate_lock = threading.Lock()
_read_gates: WeakKeyDictionary = WeakKeyDictionary()


def _configured_path(value: str) -> Path | None:
    cleaned = value.strip()
    if not cleaned or "\x00" in cleaned:
        return None
    try:
        return Path(cleaned).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return None


def _config() -> PrivateMapConfig:
    fontstacks = tuple(
        dict.fromkeys(
            value.strip()
            for value in settings.fitness_map_glyph_fontstacks.split(";")
            if _valid_fontstack_name(value.strip())
        )
    )
    return PrivateMapConfig(
        archive_path=_configured_path(settings.fitness_map_mbtiles_path),
        sprite_root=_configured_path(settings.fitness_map_sprite_path),
        glyph_root=_configured_path(settings.fitness_map_glyph_path),
        glyph_fontstacks=fontstacks,
        max_tile_bytes=settings.fitness_map_max_tile_bytes,
        max_uncompressed_tile_bytes=settings.fitness_map_max_uncompressed_tile_bytes,
        max_asset_bytes=settings.fitness_map_max_asset_bytes,
    )


def _valid_fontstack_name(value: str) -> bool:
    return bool(
        value
        and value not in {".", ".."}
        and len(value) <= 200
        and "/" not in value
        and "\\" not in value
        and all(ord(character) >= 32 for character in value)
    )


def _gate() -> asyncio.Semaphore:
    loop = asyncio.get_running_loop()
    limit = settings.fitness_map_max_concurrent_reads
    with _gate_lock:
        current = _read_gates.get(loop)
        if current is None or current[0] != limit:
            current = (limit, asyncio.Semaphore(limit))
            _read_gates[loop] = current
    return current[1]


async def _offload(function, *args):
    """Keep both SQLite work and its concurrency wait away from the event loop."""
    async with _gate():
        task = asyncio.create_task(asyncio.to_thread(function, *args))
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            try:
                await task
            finally:
                raise


def _file_key(config: PrivateMapConfig) -> tuple[Any, ...] | None:
    path = config.archive_path
    if path is None:
        return None
    try:
        stat = path.stat()
    except OSError:
        return None
    try:
        if not path.is_file():
            return None
    except OSError:
        return None
    return (
        str(path),
        stat.st_dev,
        stat.st_ino,
        stat.st_size,
        stat.st_mtime_ns,
        config.max_tile_bytes,
        config.max_uncompressed_tile_bytes,
    )


def _connect(path: Path, *, max_value_bytes: int) -> sqlite3.Connection:
    uri = f"{path.as_uri()}?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True, timeout=2.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    connection.execute("PRAGMA trusted_schema=OFF")
    connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, max_value_bytes)
    return connection


def _integer(value: Any, *, label: str) -> int:
    if isinstance(value, bool):
        raise PrivateMapArchiveError(f"Invalid {label}")
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise PrivateMapArchiveError(f"Invalid {label}") from exc
    if str(parsed) != str(value).strip():
        raise PrivateMapArchiveError(f"Invalid {label}")
    return parsed


def _float_list(value: str, *, count: int, label: str) -> tuple[float, ...]:
    if len(value) > 240:
        raise PrivateMapArchiveError(f"Invalid {label}")
    try:
        parts = tuple(float(item.strip()) for item in value.split(","))
    except ValueError as exc:
        raise PrivateMapArchiveError(f"Invalid {label}") from exc
    if len(parts) != count or not all(math.isfinite(item) for item in parts):
        raise PrivateMapArchiveError(f"Invalid {label}")
    return parts


def _validate_bounds(value: str | None) -> tuple[float, float, float, float]:
    if value is None:
        return WORLD_BOUNDS
    west, south, east, north = _float_list(value, count=4, label="bounds")
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        raise PrivateMapArchiveError("Invalid bounds")
    return west, south, east, north


def _validate_center(value: str | None, *, min_zoom: int, max_zoom: int) -> None:
    if value is None:
        return
    longitude, latitude, zoom = _float_list(value, count=3, label="center")
    if not (-180 <= longitude <= 180 and -90 <= latitude <= 90 and min_zoom <= zoom <= max_zoom):
        raise PrivateMapArchiveError("Invalid center")


def _validate_vector_layers(
    raw: str | None,
    *,
    tileset_min_zoom: int,
    tileset_max_zoom: int,
) -> tuple[dict[str, Any], ...]:
    if raw is None:
        raise PrivateMapArchiveError("Vector metadata is missing")
    if len(raw.encode()) > 256_000:
        raise PrivateMapArchiveError("Vector metadata is invalid")
    try:
        value = json.loads(raw)
    except (TypeError, ValueError) as exc:
        raise PrivateMapArchiveError("Vector metadata is invalid") from exc
    layers = value.get("vector_layers") if isinstance(value, dict) else None
    if not isinstance(layers, list) or not 1 <= len(layers) <= 64:
        raise PrivateMapArchiveError("Vector layer metadata is invalid")
    clean: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in layers:
        if not isinstance(item, dict):
            raise PrivateMapArchiveError("Vector layer metadata is invalid")
        identifier = item.get("id")
        if (
            not isinstance(identifier, str)
            or not identifier.strip()
            or len(identifier) > 200
            or identifier in seen
            or any(ord(character) < 32 for character in identifier)
        ):
            raise PrivateMapArchiveError("Vector layer metadata is invalid")
        seen.add(identifier)
        fields = item.get("fields", {})
        if not isinstance(fields, dict) or len(fields) > 256:
            raise PrivateMapArchiveError("Vector fields are invalid")
        clean_fields: dict[str, str] = {}
        for key, field_type in fields.items():
            if (
                not isinstance(key, str)
                or not key
                or len(key) > 200
                or any(ord(character) < 32 for character in key)
                or field_type not in {"Number", "Boolean", "String"}
            ):
                raise PrivateMapArchiveError("Vector fields are invalid")
            clean_fields[key] = field_type
        layer: dict[str, Any] = {"id": identifier, "fields": clean_fields}
        for key in ("description", "minzoom", "maxzoom"):
            if key in item:
                candidate = item[key]
                if key == "description":
                    if (
                        not isinstance(candidate, str)
                        or len(candidate) > 1_000
                        or any(ord(character) < 32 for character in candidate)
                    ):
                        raise PrivateMapArchiveError("Vector layer description is invalid")
                else:
                    candidate = _integer(candidate, label=key)
                    if not tileset_min_zoom <= candidate <= tileset_max_zoom:
                        raise PrivateMapArchiveError("Vector layer zoom is invalid")
                layer[key] = candidate
        if layer.get("minzoom", tileset_min_zoom) > layer.get("maxzoom", tileset_max_zoom):
            raise PrivateMapArchiveError("Vector layer zoom is invalid")
        clean.append(layer)
    return tuple(clean)


def _valid_tile_signature(data: bytes, tile_format: str) -> bool:
    if tile_format == "png":
        return data.startswith(b"\x89PNG\r\n\x1a\n")
    if tile_format == "jpg":
        return data.startswith(b"\xff\xd8\xff")
    if tile_format == "webp":
        return len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    return tile_format == "pbf" and data.startswith(b"\x1f\x8b")


def _inspect_archive_sync(config: PrivateMapConfig, key: tuple[Any, ...]) -> PrivateMapArchive:
    path = config.archive_path
    if path is None:
        raise PrivateMapArchiveError("Archive is unavailable")
    try:
        with path.open("rb") as source:
            if source.read(16) != b"SQLite format 3\x00":
                raise PrivateMapArchiveError("Archive is not SQLite")
        with _connect(
            path,
            max_value_bytes=max(config.max_tile_bytes, 512_000),
        ) as connection:
            objects = {
                row["name"]: row["type"]
                for row in connection.execute(
                    "SELECT name, type FROM sqlite_schema WHERE name IN ('metadata','tiles')"
                ).fetchall()
            }
            if set(objects) != {"metadata", "tiles"} or not all(
                object_type in {"table", "view"} for object_type in objects.values()
            ):
                raise PrivateMapArchiveError("MBTiles tables are missing")
            metadata_columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info('metadata')").fetchall()
            }
            tile_columns = {
                row["name"] for row in connection.execute("PRAGMA table_info('tiles')").fetchall()
            }
            if (
                not {"name", "value"} <= metadata_columns
                or not {
                    "zoom_level",
                    "tile_column",
                    "tile_row",
                    "tile_data",
                }
                <= tile_columns
            ):
                raise PrivateMapArchiveError("MBTiles schema is invalid")
            placeholders = ",".join("?" for _ in METADATA_KEYS)
            rows = connection.execute(
                f"SELECT name, value FROM metadata WHERE name IN ({placeholders})",
                METADATA_KEYS,
            ).fetchall()
            metadata: dict[str, str] = {}
            for row in rows:
                name, value = row["name"], row["value"]
                if (
                    name in metadata
                    or not isinstance(name, str)
                    or not isinstance(value, str)
                    or len(value.encode()) > 256_000
                ):
                    raise PrivateMapArchiveError("MBTiles metadata is invalid")
                metadata[name] = value
            if not REQUIRED_METADATA <= set(metadata):
                raise PrivateMapArchiveError("Required MBTiles metadata is missing")
            name = metadata["name"].strip()
            if not name or len(name) > 200 or any(ord(character) < 32 for character in name):
                raise PrivateMapArchiveError("MBTiles name is invalid")
            description = metadata.get("description")
            if description is not None and len(description) > 2_000:
                raise PrivateMapArchiveError("MBTiles description is invalid")
            version = metadata.get("version")
            if version is not None and (
                not version.strip()
                or len(version) > 100
                or any(ord(character) < 32 for character in version)
            ):
                raise PrivateMapArchiveError("MBTiles version is invalid")
            tileset_type = metadata.get("type")
            if tileset_type is not None and tileset_type.strip() not in {
                "baselayer",
                "overlay",
            }:
                raise PrivateMapArchiveError("MBTiles type is invalid")
            format_key = metadata["format"].strip().lower()
            if format_key not in FORMAT_DETAILS:
                raise PrivateMapArchiveError("MBTiles format is invalid")
            extension, media_type = FORMAT_DETAILS[format_key]
            tile_format = "jpg" if format_key == "jpeg" else format_key

            zoom_row = connection.execute(
                "SELECT MIN(zoom_level) AS min_zoom, MAX(zoom_level) AS max_zoom FROM tiles"
            ).fetchone()
            if zoom_row["min_zoom"] is None or zoom_row["max_zoom"] is None:
                raise PrivateMapArchiveError("MBTiles archive has no tiles")
            actual_min = _integer(zoom_row["min_zoom"], label="minimum tile zoom")
            actual_max = _integer(zoom_row["max_zoom"], label="maximum tile zoom")
            min_zoom = _integer(metadata.get("minzoom", actual_min), label="minimum zoom")
            max_zoom = _integer(metadata.get("maxzoom", actual_max), label="maximum zoom")
            if not (0 <= min_zoom <= actual_min <= actual_max <= max_zoom <= MAX_ZOOM):
                raise PrivateMapArchiveError("MBTiles zoom range is invalid")
            bounds = _validate_bounds(metadata.get("bounds"))
            _validate_center(metadata.get("center"), min_zoom=min_zoom, max_zoom=max_zoom)
            vector_layers = (
                _validate_vector_layers(
                    metadata.get("json"),
                    tileset_min_zoom=min_zoom,
                    tileset_max_zoom=max_zoom,
                )
                if tile_format == "pbf"
                else ()
            )
            # Never scan every tile BLOB during first-open inspection. SQLite's
            # stable scan of this immutable archive gives us a bounded sample;
            # every requested coordinate and payload is validated again below.
            samples = connection.execute(
                "SELECT zoom_level, tile_column, tile_row, "
                "typeof(tile_data) AS data_type, length(tile_data) AS size, "
                "substr(tile_data, 1, 12) AS prefix FROM tiles LIMIT ?",
                (INSPECTION_SAMPLE_LIMIT,),
            ).fetchall()
            for sample in samples:
                zoom = _integer(sample["zoom_level"], label="tile zoom")
                column = _integer(sample["tile_column"], label="tile column")
                tile_row = _integer(sample["tile_row"], label="tile row")
                size = _integer(sample["size"], label="tile size")
                prefix = sample["prefix"]
                dimension = 1 << zoom if 0 <= zoom <= MAX_ZOOM else 0
                if not (
                    min_zoom <= zoom <= max_zoom
                    and 0 <= column < dimension
                    and 0 <= tile_row < dimension
                    and sample["data_type"] == "blob"
                    and 0 < size <= config.max_tile_bytes
                    and isinstance(prefix, bytes)
                    and _valid_tile_signature(prefix, tile_format)
                ):
                    raise PrivateMapArchiveError("MBTiles tile is invalid")
    except (OSError, sqlite3.DatabaseError) as exc:
        raise PrivateMapArchiveError("MBTiles archive cannot be read") from exc

    fingerprint_data = json.dumps(
        {
            "file": key,
            "name": name,
            "format": tile_format,
            "minzoom": min_zoom,
            "maxzoom": max_zoom,
            "bounds": bounds,
            "layers": vector_layers,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return PrivateMapArchive(
        path=path,
        fingerprint=hashlib.sha256(fingerprint_data).hexdigest()[:20],
        name=name,
        tile_format=tile_format,
        extension=extension,
        media_type=media_type,
        min_zoom=min_zoom,
        max_zoom=max_zoom,
        bounds=bounds,
        vector_layers=vector_layers,
    )


def _load_archive_sync(config: PrivateMapConfig) -> PrivateMapArchive | None:
    global _inspection_cache
    key = _file_key(config)
    if key is None:
        return None
    with _cache_lock:
        if _inspection_cache is not None and _inspection_cache[0] == key:
            return _inspection_cache[1]
        try:
            archive = _inspect_archive_sync(config, key)
        except (PrivateMapArchiveError, ValueError):
            archive = None
        _inspection_cache = (key, archive)
        return archive


def _validate_gzip(data: bytes, *, max_uncompressed_bytes: int) -> None:
    try:
        decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        decoded = decompressor.decompress(data, max_uncompressed_bytes + 1)
        if len(decoded) > max_uncompressed_bytes or decompressor.unconsumed_tail:
            raise PrivateMapArchiveError("Compressed tile is too large")
        decoded += decompressor.flush(max_uncompressed_bytes + 1 - len(decoded))
        if (
            len(decoded) > max_uncompressed_bytes
            or not decompressor.eof
            or decompressor.unused_data
        ):
            raise PrivateMapArchiveError("Compressed tile is invalid")
    except zlib.error as exc:
        raise PrivateMapArchiveError("Compressed tile is invalid") from exc


def _validate_tile_bytes(
    data: bytes, archive: PrivateMapArchive, config: PrivateMapConfig
) -> str | None:
    if not data or len(data) > config.max_tile_bytes:
        raise PrivateMapArchiveError("Tile payload is invalid")
    if not _valid_tile_signature(data, archive.tile_format):
        raise PrivateMapArchiveError("Tile signature is invalid")
    if archive.tile_format != "pbf":
        return None
    if not data.startswith(b"\x1f\x8b"):
        raise PrivateMapArchiveError("Vector tile is not gzip-compressed")
    _validate_gzip(data, max_uncompressed_bytes=config.max_uncompressed_tile_bytes)
    return "gzip"


def _read_tile_sync(
    config: PrivateMapConfig,
    zoom: int,
    column: int,
    xyz_row: int,
    extension: str,
) -> PrivateMapTile | None:
    archive = _load_archive_sync(config)
    if archive is None or extension != archive.extension:
        return None
    dimension = 1 << zoom
    if not (
        archive.min_zoom <= zoom <= archive.max_zoom
        and 0 <= column < dimension
        and 0 <= xyz_row < dimension
    ):
        return None
    tms_row = dimension - 1 - xyz_row
    try:
        with _connect(
            archive.path,
            max_value_bytes=max(config.max_tile_bytes, 512_000),
        ) as connection:
            data_rows = connection.execute(
                "SELECT tile_data FROM tiles WHERE zoom_level = ? "
                "AND tile_column = ? AND tile_row = ? LIMIT 2",
                (zoom, column, tms_row),
            ).fetchall()
            if len(data_rows) != 1 or not isinstance(data_rows[0]["tile_data"], bytes):
                return None
            data = data_rows[0]["tile_data"]
    except (OSError, sqlite3.DatabaseError, PrivateMapArchiveError):
        return None
    try:
        content_encoding = _validate_tile_bytes(data, archive, config)
    except PrivateMapArchiveError:
        return None
    digest = hashlib.sha256(
        archive.fingerprint.encode() + f":{zoom}:{column}:{xyz_row}:".encode() + data
    ).hexdigest()
    return PrivateMapTile(
        data=data,
        media_type=archive.media_type,
        content_encoding=content_encoding,
        etag=f'"{digest}"',
    )


def _strict_asset(root: Path | None, *parts: str) -> Path | None:
    if root is None:
        return None
    try:
        candidate = root.joinpath(*parts).resolve()
        candidate.relative_to(root)
    except (OSError, RuntimeError, ValueError):
        return None
    return candidate


def _asset_capabilities_sync(config: PrivateMapConfig) -> tuple[bool, str | None]:
    try:
        sprite_ready = all(_read_sprite_sync(config, name) is not None for name in SPRITE_FILENAMES)
        glyph_fontstack = next(
            (
                fontstack
                for fontstack in config.glyph_fontstacks
                if _read_glyph_sync(config, fontstack, "0-255") is not None
            ),
            None,
        )
    except OSError:
        return False, None
    return sprite_ready, glyph_fontstack


def _read_asset_file(
    path: Path | None,
    *,
    max_bytes: int,
    media_type: str,
    allow_gzip: bool,
) -> PrivateMapAsset | None:
    if path is None:
        return None
    try:
        stat = path.stat()
        if not path.is_file() or not 0 < stat.st_size <= max_bytes:
            return None
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) != stat.st_size:
        return None
    if media_type == "image/png" and not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return None
    if media_type == "application/json":
        try:
            if not isinstance(json.loads(data), dict):
                return None
        except (UnicodeDecodeError, ValueError):
            return None
    content_encoding = "gzip" if allow_gzip and data.startswith(b"\x1f\x8b") else None
    if content_encoding is not None:
        try:
            _validate_gzip(data, max_uncompressed_bytes=max_bytes)
        except PrivateMapArchiveError:
            return None
    return PrivateMapAsset(
        data=data,
        media_type=media_type,
        content_encoding=content_encoding,
        etag=f'"{hashlib.sha256(data).hexdigest()}"',
    )


def _read_sprite_sync(config: PrivateMapConfig, filename: str) -> PrivateMapAsset | None:
    if filename not in SPRITE_FILENAMES:
        return None
    media_type = "application/json" if filename.endswith(".json") else "image/png"
    return _read_asset_file(
        _strict_asset(config.sprite_root, filename),
        max_bytes=config.max_asset_bytes,
        media_type=media_type,
        allow_gzip=False,
    )


def _valid_glyph_range(value: str) -> bool:
    match = GLYPH_RANGE_RE.fullmatch(value)
    if match is None:
        return False
    start, end = int(match.group(1)), int(match.group(2))
    return start % 256 == 0 and end == start + 255 and end <= 1_114_111


def _read_glyph_sync(
    config: PrivateMapConfig, fontstack: str, glyph_range: str
) -> PrivateMapAsset | None:
    if fontstack not in config.glyph_fontstacks or not _valid_glyph_range(glyph_range):
        return None
    return _read_asset_file(
        _strict_asset(config.glyph_root, fontstack, f"{glyph_range}.pbf"),
        max_bytes=config.max_asset_bytes,
        media_type="application/x-protobuf",
        allow_gzip=True,
    )


def _vector_style_layers(archive: PrivateMapArchive, *, glyph_fontstack: str | None) -> list[dict]:
    layers: list[dict] = []
    for index, layer in enumerate(archive.vector_layers):
        identifier = layer["id"]
        lowered = identifier.casefold()
        if any(term in lowered for term in ("water", "ocean", "river")):
            fill, line, point = "#dbeafe", "#93c5fd", "#60a5fa"
        elif any(term in lowered for term in ("park", "land", "wood", "green")):
            fill, line, point = "#e7efe5", "#b8c9b3", "#86a780"
        elif "building" in lowered:
            fill, line, point = "#e5e7eb", "#c5c9d0", "#9ca3af"
        elif any(term in lowered for term in ("road", "transport", "street")):
            fill, line, point = "#f3f4f6", "#ffffff", "#9ca3af"
        else:
            fill, line, point = "#eef0f2", "#b8bdc5", "#8b929d"
        prefix = f"local-{index}"
        layers.extend(
            [
                {
                    "id": f"{prefix}-fill",
                    "type": "fill",
                    "source": "hausklar-private-map",
                    "source-layer": identifier,
                    "filter": ["==", ["geometry-type"], "Polygon"],
                    "paint": {"fill-color": fill, "fill-opacity": 0.72},
                },
                {
                    "id": f"{prefix}-line",
                    "type": "line",
                    "source": "hausklar-private-map",
                    "source-layer": identifier,
                    "filter": ["==", ["geometry-type"], "LineString"],
                    "paint": {"line-color": line, "line-width": 1.1},
                },
                {
                    "id": f"{prefix}-point",
                    "type": "circle",
                    "source": "hausklar-private-map",
                    "source-layer": identifier,
                    "filter": ["==", ["geometry-type"], "Point"],
                    "paint": {"circle-color": point, "circle-radius": 2.25},
                },
            ]
        )
        if glyph_fontstack is not None and any(
            term in lowered for term in ("place", "poi", "road", "transport")
        ):
            layers.append(
                {
                    "id": f"{prefix}-label",
                    "type": "symbol",
                    "source": "hausklar-private-map",
                    "source-layer": identifier,
                    "layout": {
                        "text-field": [
                            "coalesce",
                            ["get", "name:en"],
                            ["get", "name"],
                        ],
                        "text-size": 11,
                        "text-font": [glyph_fontstack],
                    },
                    "paint": {
                        "text-color": "#374151",
                        "text-halo-color": "#ffffff",
                        "text-halo-width": 1,
                    },
                }
            )
    return layers[:255]


async def availability() -> PrivateMapAvailability:
    config = _config()
    archive = await _offload(_load_archive_sync, config)
    if archive is None:
        return PrivateMapAvailability(available=False)
    sprites, glyph_fontstack = await _offload(_asset_capabilities_sync, config)
    return PrivateMapAvailability(
        available=True,
        format=archive.tile_format,
        min_zoom=archive.min_zoom,
        max_zoom=archive.max_zoom,
        bounds=archive.bounds,
        style_url=STYLE_URL,
        tilejson_url=TILEJSON_URL,
        has_sprites=sprites,
        has_glyphs=glyph_fontstack is not None,
    )


async def tilejson() -> PrivateMapTileJSON | None:
    archive = await _offload(_load_archive_sync, _config())
    if archive is None:
        return None
    tile_url = (
        f"/api/fitness/maps/tiles/{{z}}/{{x}}/{{y}}.{archive.extension}?v={archive.fingerprint}"
    )
    return PrivateMapTileJSON(
        name=archive.name,
        tiles=[tile_url],
        minzoom=archive.min_zoom,
        maxzoom=archive.max_zoom,
        bounds=archive.bounds,
        vector_layers=list(archive.vector_layers) or None,
    )


async def style() -> PrivateMapStyle:
    config = _config()
    archive = await _offload(_load_archive_sync, config)
    background = {
        "id": "hausklar-neutral-background",
        "type": "background",
        "paint": {"background-color": "#f4f3ef"},
    }
    if archive is None:
        return PrivateMapStyle(
            name="HausKlar neutral route background",
            sources={},
            layers=[background],
        )
    sprites, glyph_fontstack = await _offload(_asset_capabilities_sync, config)
    source: dict[str, Any] = {
        "type": "vector" if archive.tile_format == "pbf" else "raster",
        "url": f"{TILEJSON_URL}?v={archive.fingerprint}",
    }
    if archive.tile_format != "pbf":
        source["tileSize"] = 256
        layers = [
            background,
            {
                "id": "hausklar-private-raster",
                "type": "raster",
                "source": "hausklar-private-map",
            },
        ]
    else:
        layers = [
            background,
            *_vector_style_layers(archive, glyph_fontstack=glyph_fontstack),
        ]
    return PrivateMapStyle(
        name="HausKlar private basemap",
        sources={"hausklar-private-map": source},
        layers=layers,
        sprite=SPRITE_URL if sprites else None,
        glyphs=GLYPH_URL if glyph_fontstack is not None else None,
    )


async def tile(*, zoom: int, column: int, row: int, extension: str) -> PrivateMapTile | None:
    if not 0 <= zoom <= MAX_ZOOM:
        return None
    return await _offload(
        _read_tile_sync,
        _config(),
        zoom,
        column,
        row,
        extension.casefold(),
    )


async def sprite(filename: str) -> PrivateMapAsset | None:
    return await _offload(_read_sprite_sync, _config(), filename)


async def glyph(fontstack: str, glyph_range: str) -> PrivateMapAsset | None:
    return await _offload(_read_glyph_sync, _config(), fontstack, glyph_range)
