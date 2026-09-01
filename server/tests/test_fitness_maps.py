"""Private MBTiles delivery stays local, authenticated and quietly optional."""

from __future__ import annotations

import asyncio
import gzip
import json
import sqlite3
import threading
import time
from pathlib import Path

import pytest

from app.config import settings
from app.services.fitness import private_maps


pytestmark = pytest.mark.asyncio

PNG = b"\x89PNG\r\n\x1a\nhausklar"
JPEG = b"\xff\xd8\xff\xe0hausklar"
WEBP = b"RIFF\x08\x00\x00\x00WEBPhausklar"
VECTOR_TILE = b"\x1a\x08hausklar"


@pytest.fixture
def private_map_paths(tmp_path, monkeypatch):
    root = tmp_path / "maps"
    archive = root / "basemap.mbtiles"
    sprites = root / "sprites"
    glyphs = root / "glyphs"
    root.mkdir()
    monkeypatch.setattr(settings, "fitness_map_mbtiles_path", str(archive))
    monkeypatch.setattr(settings, "fitness_map_sprite_path", str(sprites))
    monkeypatch.setattr(settings, "fitness_map_glyph_path", str(glyphs))
    monkeypatch.setattr(settings, "fitness_map_glyph_fontstacks", "")
    monkeypatch.setattr(settings, "fitness_map_max_tile_bytes", 64 * 1024)
    monkeypatch.setattr(settings, "fitness_map_max_uncompressed_tile_bytes", 128 * 1024)
    monkeypatch.setattr(settings, "fitness_map_max_asset_bytes", 64 * 1024)
    monkeypatch.setattr(settings, "fitness_map_max_concurrent_reads", 4)
    private_maps._inspection_cache = None
    yield archive, sprites, glyphs
    private_maps._inspection_cache = None


def _make_mbtiles(
    path: Path,
    *,
    tile_format: str = "png",
    tiles: list[tuple[int, int, int, bytes]] | None = None,
    metadata: dict[str, str] | None = None,
    unique_index: bool = False,
    interfaces_as_views: bool = False,
) -> None:
    values = {"name": "HausKlar regional map", "format": tile_format}
    if metadata:
        values.update(metadata)
    tile_rows = tiles or [(0, 0, 0, PNG)]
    metadata_table = "metadata_source" if interfaces_as_views else "metadata"
    tiles_table = "tiles_source" if interfaces_as_views else "tiles"
    with sqlite3.connect(path) as connection:
        connection.execute(f"CREATE TABLE {metadata_table} (name TEXT, value TEXT)")
        connection.execute(
            f"CREATE TABLE {tiles_table} ("
            "zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)"
        )
        connection.executemany(
            f"INSERT INTO {metadata_table} (name, value) VALUES (?, ?)",
            values.items(),
        )
        connection.executemany(
            f"INSERT INTO {tiles_table} "
            "(zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)",
            tile_rows,
        )
        if interfaces_as_views:
            connection.execute("CREATE VIEW metadata AS SELECT name, value FROM metadata_source")
            connection.execute(
                "CREATE VIEW tiles AS SELECT zoom_level, tile_column, tile_row, "
                "tile_data FROM tiles_source"
            )
        elif unique_index:
            connection.execute(
                "CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)"
            )
        connection.commit()


def _vector_metadata(
    *,
    fields: dict[str, str] | None = None,
    minzoom: int | None = None,
    maxzoom: int | None = None,
    layer_id: str = "place",
) -> str:
    layer: dict[str, object] = {
        "id": layer_id,
        "fields": fields or {"name": "String", "rank": "Number", "capital": "Boolean"},
    }
    if minzoom is not None:
        layer["minzoom"] = minzoom
    if maxzoom is not None:
        layer["maxzoom"] = maxzoom
    return json.dumps({"vector_layers": [layer]})


async def test_every_private_map_route_requires_authentication(client):
    for path in (
        "/api/fitness/maps",
        "/api/fitness/maps/style.json",
        "/api/fitness/maps/tilejson.json",
        "/api/fitness/maps/tiles/0/0/0.png",
        "/api/fitness/maps/sprites/sprite.png",
        "/api/fitness/maps/glyphs/Noto%20Sans/0-255.pbf",
    ):
        response = await client.get(path)
        assert response.status_code == 401, path


async def test_missing_archive_is_a_quiet_supported_state(
    client,
    adult_a_headers,
    private_map_paths,
):
    availability = await client.get("/api/fitness/maps", headers=adult_a_headers)
    assert availability.status_code == 200
    assert availability.json() == {"available": False}

    style = await client.get("/api/fitness/maps/style.json", headers=adult_a_headers)
    assert style.status_code == 200
    assert style.json()["sources"] == {}
    assert style.json()["layers"] == [
        {
            "id": "hausklar-neutral-background",
            "paint": {"background-color": "#f4f3ef"},
            "type": "background",
        }
    ]
    assert "http://" not in style.text
    assert "https://" not in style.text
    assert (
        await client.get("/api/fitness/maps/tilejson.json", headers=adult_a_headers)
    ).status_code == 404
    assert (
        await client.get("/api/fitness/maps/tiles/0/0/0.png", headers=adult_a_headers)
    ).status_code == 404


@pytest.mark.parametrize("corruption", ["bytes", "schema"])
async def test_corrupt_archive_quietly_uses_neutral_style(
    client,
    adult_a_headers,
    private_map_paths,
    corruption,
):
    archive, _sprites, _glyphs = private_map_paths
    if corruption == "bytes":
        archive.write_bytes(b"not sqlite")
    else:
        with sqlite3.connect(archive) as connection:
            connection.execute("CREATE TABLE unrelated (value TEXT)")

    response = await client.get("/api/fitness/maps", headers=adult_a_headers)
    assert response.status_code == 200
    assert response.json() == {"available": False}
    style = await client.get("/api/fitness/maps/style.json", headers=adult_a_headers)
    assert style.status_code == 200
    assert style.json()["sources"] == {}


async def test_spec_compatible_optional_metadata_no_index_and_xyz_tms_inversion(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    top_tms_tile = PNG + b"-north"
    bottom_tms_tile = PNG + b"-south"
    _make_mbtiles(
        archive,
        tiles=[
            (2, 1, 0, top_tms_tile),
            (2, 1, 3, bottom_tms_tile),
        ],
        metadata={"version": "2"},
    )

    availability = await client.get("/api/fitness/maps", headers=adult_a_headers)
    assert availability.status_code == 200
    assert availability.json() == {
        "available": True,
        "bounds": [-180.0, -85.05112878, 180.0, 85.05112878],
        "format": "png",
        "has_glyphs": False,
        "has_sprites": False,
        "max_zoom": 2,
        "min_zoom": 2,
        "style_url": "/api/fitness/maps/style.json",
        "tilejson_url": "/api/fitness/maps/tilejson.json",
    }
    north = await client.get("/api/fitness/maps/tiles/2/1/3.png", headers=adult_a_headers)
    south = await client.get("/api/fitness/maps/tiles/2/1/0.png", headers=adult_a_headers)
    assert north.status_code == south.status_code == 200
    assert north.content == top_tms_tile
    assert south.content == bottom_tms_tile
    assert north.headers["content-type"].startswith("image/png")


async def test_metadata_and_tiles_interfaces_may_be_views(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(archive, interfaces_as_views=True)

    assert (await client.get("/api/fitness/maps", headers=adult_a_headers)).json()["available"]
    tile = await client.get("/api/fitness/maps/tiles/0/0/0.png", headers=adult_a_headers)
    assert tile.status_code == 200
    assert tile.content == PNG


@pytest.mark.parametrize(
    ("tile_format", "extension", "payload", "media_type"),
    [
        ("png", "png", PNG, "image/png"),
        ("jpg", "jpg", JPEG, "image/jpeg"),
        ("jpeg", "jpg", JPEG, "image/jpeg"),
        ("webp", "webp", WEBP, "image/webp"),
    ],
)
async def test_raster_format_mime_contract(
    client,
    adult_a_headers,
    private_map_paths,
    tile_format,
    extension,
    payload,
    media_type,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(archive, tile_format=tile_format, tiles=[(0, 0, 0, payload)])

    tile = await client.get(f"/api/fitness/maps/tiles/0/0/0.{extension}", headers=adult_a_headers)
    assert tile.status_code == 200
    assert tile.headers["content-type"].startswith(media_type)
    assert tile.content == payload


async def test_gzipped_vector_tiles_and_vector_metadata_contract(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    compressed = gzip.compress(VECTOR_TILE, mtime=0)
    _make_mbtiles(
        archive,
        tile_format="pbf",
        tiles=[(2, 1, 0, compressed)],
        metadata={
            "version": "2",
            "minzoom": "2",
            "maxzoom": "4",
            "json": _vector_metadata(minzoom=2, maxzoom=4),
        },
    )

    availability = await client.get("/api/fitness/maps", headers=adult_a_headers)
    assert availability.json()["available"] is True
    tilejson = await client.get("/api/fitness/maps/tilejson.json", headers=adult_a_headers)
    assert tilejson.status_code == 200
    assert tilejson.json()["scheme"] == "xyz"
    assert tilejson.json()["vector_layers"][0]["fields"] == {
        "capital": "Boolean",
        "name": "String",
        "rank": "Number",
    }
    assert len(tilejson.json()["tiles"]) == 1
    assert tilejson.json()["tiles"][0].startswith("/api/fitness/maps/tiles/{z}/{x}/{y}.pbf?v=")
    tile = await client.get("/api/fitness/maps/tiles/2/1/3.pbf", headers=adult_a_headers)
    assert tile.status_code == 200
    assert tile.headers["content-type"].startswith("application/vnd.mapbox-vector-tile")
    assert tile.headers["content-encoding"] == "gzip"
    assert tile.content == VECTOR_TILE


async def test_raw_vector_tile_is_not_treated_as_valid_pbf(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(
        archive,
        tile_format="pbf",
        tiles=[(0, 0, 0, VECTOR_TILE)],
    )

    assert (await client.get("/api/fitness/maps", headers=adult_a_headers)).json() == {
        "available": False
    }
    assert (
        await client.get("/api/fitness/maps/tiles/0/0/0.pbf", headers=adult_a_headers)
    ).status_code == 404


async def test_vector_archive_requires_json_metadata(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(
        archive,
        tile_format="pbf",
        tiles=[(0, 0, 0, gzip.compress(VECTOR_TILE, mtime=0))],
    )

    assert (await client.get("/api/fitness/maps", headers=adult_a_headers)).json() == {
        "available": False
    }


@pytest.mark.parametrize(
    "vector_json",
    [
        _vector_metadata(fields={"name": "string"}),
        _vector_metadata(minzoom=1, maxzoom=4),
        _vector_metadata(minzoom=2, maxzoom=5),
        _vector_metadata(minzoom=4, maxzoom=3),
    ],
)
async def test_invalid_vector_fields_and_layer_zoom_bounds_are_rejected(
    client,
    adult_a_headers,
    private_map_paths,
    vector_json,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(
        archive,
        tile_format="pbf",
        tiles=[(2, 1, 0, gzip.compress(VECTOR_TILE, mtime=0))],
        metadata={"minzoom": "2", "maxzoom": "4", "json": vector_json},
    )

    assert (await client.get("/api/fitness/maps", headers=adult_a_headers)).json() == {
        "available": False
    }


async def test_style_tilejson_and_binary_responses_are_private_and_revalidatable(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(archive)

    metadata = await client.get("/api/fitness/maps", headers=adult_a_headers)
    assert metadata.headers["cache-control"] == "private, max-age=60"
    assert metadata.headers["vary"] == "Authorization, Cookie"
    metadata_304 = await client.get(
        "/api/fitness/maps",
        headers={**adult_a_headers, "If-None-Match": f"W/{metadata.headers['etag']}"},
    )
    assert metadata_304.status_code == 304
    assert metadata_304.content == b""

    tile = await client.get("/api/fitness/maps/tiles/0/0/0.png", headers=adult_a_headers)
    assert tile.headers["cache-control"] == "private, max-age=86400"
    assert tile.headers["vary"] == "Authorization, Cookie"
    tile_304 = await client.get(
        "/api/fitness/maps/tiles/0/0/0.png",
        headers={**adult_a_headers, "If-None-Match": tile.headers["etag"]},
    )
    assert tile_304.status_code == 304
    assert tile_304.content == b""


async def test_generated_style_and_tilejson_never_reference_an_external_host(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(archive)

    for path in (
        "/api/fitness/maps/style.json",
        "/api/fitness/maps/tilejson.json",
    ):
        response = await client.get(path, headers=adult_a_headers)
        assert response.status_code == 200
        assert "http://" not in response.text
        assert "https://" not in response.text
        assert "//" not in response.text


async def test_fixed_allowlisted_sprite_and_glyph_assets(
    client,
    adult_a_headers,
    private_map_paths,
    monkeypatch,
):
    archive, sprites, glyphs = private_map_paths
    _make_mbtiles(
        archive,
        tile_format="pbf",
        tiles=[(0, 0, 0, gzip.compress(VECTOR_TILE, mtime=0))],
        metadata={"json": _vector_metadata()},
    )
    sprites.mkdir()
    for filename in ("sprite.json", "sprite" + "@2x.json"):
        (sprites / filename).write_text("{}")
    for filename in ("sprite.png", "sprite" + "@2x.png"):
        (sprites / filename).write_bytes(PNG)
    font_root = glyphs / "Noto Sans Regular"
    font_root.mkdir(parents=True)
    (font_root / "0-255.pbf").write_bytes(VECTOR_TILE)
    monkeypatch.setattr(
        settings,
        "fitness_map_glyph_fontstacks",
        "Noto Sans Regular;Uninstalled Font",
    )

    availability = await client.get("/api/fitness/maps", headers=adult_a_headers)
    assert availability.json()["has_sprites"] is True
    assert availability.json()["has_glyphs"] is True
    style = await client.get("/api/fitness/maps/style.json", headers=adult_a_headers)
    assert style.json()["sprite"] == "/api/fitness/maps/sprites/sprite"
    assert style.json()["glyphs"] == ("/api/fitness/maps/glyphs/{fontstack}/{range}.pbf")
    sprite = await client.get("/api/fitness/maps/sprites/sprite.png", headers=adult_a_headers)
    glyph = await client.get(
        "/api/fitness/maps/glyphs/Noto%20Sans%20Regular/0-255.pbf",
        headers=adult_a_headers,
    )
    assert sprite.status_code == glyph.status_code == 200
    assert sprite.headers["content-type"].startswith("image/png")
    assert glyph.headers["content-type"].startswith("application/x-protobuf")
    assert glyph.content == VECTOR_TILE

    for path in (
        "/api/fitness/maps/sprites/other.png",
        "/api/fitness/maps/sprites/%2e%2e%2fbasemap.mbtiles",
        "/api/fitness/maps/glyphs/Uninstalled%20Font/0-255.pbf",
        "/api/fitness/maps/glyphs/Noto%20Sans%20Regular/1-256.pbf",
        "/api/fitness/maps/glyphs/%2e%2e/0-255.pbf",
    ):
        response = await client.get(path, headers=adult_a_headers)
        assert response.status_code == 404, path


async def test_invalid_request_coordinates_extension_and_archive_limits(
    client,
    adult_a_headers,
    private_map_paths,
    monkeypatch,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(archive, tiles=[(2, 1, 0, PNG)])

    for path in (
        "/api/fitness/maps/tiles/-1/0/0.png",
        "/api/fitness/maps/tiles/23/0/0.png",
        "/api/fitness/maps/tiles/2/-1/0.png",
        "/api/fitness/maps/tiles/2/4/0.png",
        "/api/fitness/maps/tiles/2/1/4.png",
        "/api/fitness/maps/tiles/2/1/3.mbtiles",
    ):
        response = await client.get(path, headers=adult_a_headers)
        assert response.status_code == 404, path

    oversized = archive.with_name("oversized.mbtiles")
    monkeypatch.setattr(settings, "fitness_map_mbtiles_path", str(oversized))
    monkeypatch.setattr(settings, "fitness_map_max_tile_bytes", 16 * 1024)
    _make_mbtiles(oversized, tiles=[(0, 0, 0, PNG + b"x" * (16 * 1024))])
    assert (await client.get("/api/fitness/maps", headers=adult_a_headers)).json() == {
        "available": False
    }

    bad_coordinates = archive.with_name("bad-coordinates.mbtiles")
    monkeypatch.setattr(settings, "fitness_map_mbtiles_path", str(bad_coordinates))
    monkeypatch.setattr(settings, "fitness_map_max_tile_bytes", 64 * 1024)
    _make_mbtiles(bad_coordinates, tiles=[(2, 4, 0, PNG)])
    assert (await client.get("/api/fitness/maps", headers=adult_a_headers)).json() == {
        "available": False
    }


async def test_duplicate_tile_coordinates_are_quietly_rejected_without_requiring_index(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(
        archive,
        tiles=[(0, 0, 0, PNG + b"a"), (0, 0, 0, PNG + b"b")],
    )
    assert (await client.get("/api/fitness/maps", headers=adult_a_headers)).json()["available"]
    ambiguous = await client.get("/api/fitness/maps/tiles/0/0/0.png", headers=adult_a_headers)
    assert ambiguous.status_code == 404


async def test_archive_inspection_samples_payloads_and_validates_requested_tile(
    client,
    adult_a_headers,
    private_map_paths,
):
    archive, _sprites, _glyphs = private_map_paths
    valid = gzip.compress(VECTOR_TILE, mtime=0)
    tiles = [(6, column, 0, valid) for column in range(private_maps.INSPECTION_SAMPLE_LIMIT)]
    tiles.append((6, 63, 0, b"\x1f\x8bcorrupt-gzip-outside-sample"))
    _make_mbtiles(
        archive,
        tile_format="pbf",
        tiles=tiles,
        metadata={"json": _vector_metadata()},
    )

    # First-open inspection remains available because it does not scan every
    # BLOB. The corrupt coordinate is still rejected quietly when requested.
    availability = await client.get("/api/fitness/maps", headers=adult_a_headers)
    assert availability.status_code == 200
    assert availability.json()["available"] is True
    corrupt = await client.get("/api/fitness/maps/tiles/6/63/63.pbf", headers=adult_a_headers)
    assert corrupt.status_code == 404


async def test_tile_reads_are_bounded_and_do_not_block_the_event_loop(
    private_map_paths,
    monkeypatch,
):
    archive, _sprites, _glyphs = private_map_paths
    _make_mbtiles(archive)
    assert (await private_maps.availability()).available

    original = private_maps._read_tile_sync
    lock = threading.Lock()
    active = 0
    maximum_active = 0

    def slow_read(*args):
        nonlocal active, maximum_active
        with lock:
            active += 1
            maximum_active = max(maximum_active, active)
        try:
            time.sleep(0.06)
            return original(*args)
        finally:
            with lock:
                active -= 1

    monkeypatch.setattr(settings, "fitness_map_max_concurrent_reads", 2)
    monkeypatch.setattr(private_maps, "_read_tile_sync", slow_read)
    started = time.perf_counter()

    async def event_loop_tick() -> float:
        await asyncio.sleep(0.01)
        return time.perf_counter() - started

    responses, tick_delay = await asyncio.gather(
        asyncio.gather(
            *(
                private_maps.tile(
                    zoom=0,
                    column=0,
                    row=0,
                    extension="png",
                )
                for _ in range(6)
            )
        ),
        event_loop_tick(),
    )
    assert all(response is not None for response in responses)
    assert tick_delay < 0.05
    assert maximum_active == 2
