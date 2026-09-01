import io
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import httpx
import pytest
from PIL import Image

from app.config import settings
from app.services import photos


@pytest.fixture(autouse=True)
def immich_config(monkeypatch):
    monkeypatch.setattr(settings, "immich_url", "http://192.0.2.108:2283")
    monkeypatch.setattr(settings, "immich_api_key", "test-key")
    photos._memories_cache.clear()


async def test_photos_require_authentication(client):
    assert (await client.get("/api/photos/memories")).status_code == 401


async def test_memories_pick_one_per_year_preferring_favourites(
    client, adult_a_headers, monkeypatch
):
    last_year = (datetime.now(timezone.utc) - timedelta(days=365)).isoformat()

    async def fake_search(client_, *, taken_after, taken_before, size):
        if taken_after.year == datetime.now(timezone.utc).year - 1:
            return [
                {"id": "plain-photo", "type": "IMAGE", "isFavorite": False, "fileCreatedAt": last_year},
                {"id": "starred-photo", "type": "IMAGE", "isFavorite": True, "fileCreatedAt": last_year},
            ]
        return []

    monkeypatch.setattr(photos, "_search_assets", fake_search)
    response = await client.get("/api/photos/memories", headers=adult_a_headers)
    assert response.status_code == 200
    memories = response.json()["memories"]
    assert len(memories) == 1
    assert memories[0]["asset_id"] == "starred-photo"
    assert memories[0]["years_ago"] == 1
    assert memories[0]["thumbnail_url"] == "/photos/starred-photo/thumbnail?size=preview"


async def test_memories_empty_when_unconfigured(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(settings, "immich_url", "")
    monkeypatch.setattr(settings, "immich_api_key", "")
    response = await client.get("/api/photos/memories", headers=adult_a_headers)
    assert response.status_code == 200
    assert response.json()["memories"] == []


async def test_thumbnail_proxy_validates_asset_id(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(
        photos, "fetch_thumbnail", AsyncMock(return_value=(b"jpegbytes", "image/jpeg"))
    )
    monkeypatch.setattr(
        "app.routers.photos.fetch_thumbnail",
        AsyncMock(return_value=(b"jpegbytes", "image/jpeg")),
    )
    good = await client.get("/api/photos/asset-123/thumbnail", headers=adult_a_headers)
    assert good.status_code == 200
    assert good.content == b"jpegbytes"

    bad = await client.get("/api/photos/..%2Fsecrets/thumbnail", headers=adult_a_headers)
    assert bad.status_code in (404, 422)


async def test_thumbnail_fetch_streams_and_validates_image(monkeypatch):
    encoded = io.BytesIO()
    Image.new("RGB", (32, 24), color="navy").save(encoded, format="JPEG")
    body = encoded.getvalue()

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={"Content-Type": "image/jpeg", "Content-Length": str(len(body))},
            content=body,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as provider:
        monkeypatch.setattr(photos, "provider_client", AsyncMock(return_value=provider))
        result = await photos.fetch_thumbnail("asset-123", "preview")

    assert result == (body, "image/jpeg")


async def test_thumbnail_fetch_rejects_mime_mismatch(monkeypatch):
    encoded = io.BytesIO()
    Image.new("RGB", (16, 16), color="navy").save(encoded, format="PNG")
    body = encoded.getvalue()

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={"Content-Type": "image/jpeg"},
            content=body,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as provider:
        monkeypatch.setattr(photos, "provider_client", AsyncMock(return_value=provider))
        result = await photos.fetch_thumbnail("asset-123", "preview")

    assert result is None


async def test_thumbnail_fetch_rejects_oversized_declared_body_without_reading(
    monkeypatch,
):
    class UnreadBody(httpx.AsyncByteStream):
        async def __aiter__(self):
            raise AssertionError("oversized provider body must not be read")
            yield b""  # pragma: no cover

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={
                "Content-Type": "image/jpeg",
                "Content-Length": str(photos._MAX_THUMBNAIL_BYTES + 1),
            },
            stream=UnreadBody(),
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as provider:
        monkeypatch.setattr(photos, "provider_client", AsyncMock(return_value=provider))
        result = await photos.fetch_thumbnail("asset-123", "preview")

    assert result is None


async def test_thumbnail_fetch_stops_chunked_body_at_stream_limit(monkeypatch):
    monkeypatch.setattr(photos, "_MAX_THUMBNAIL_BYTES", 8)

    class ChunkedBody(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b"12345"
            yield b"6789"
            raise AssertionError("stream must stop as soon as the cap is crossed")

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={"Content-Type": "image/jpeg"},
            stream=ChunkedBody(),
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as provider:
        monkeypatch.setattr(photos, "provider_client", AsyncMock(return_value=provider))
        result = await photos.fetch_thumbnail("asset-123", "preview")

    assert result is None


def test_thumbnail_validation_rejects_excessive_dimensions():
    encoded = io.BytesIO()
    Image.new("RGB", (photos._MAX_THUMBNAIL_WIDTH + 1, 1), color="navy").save(
        encoded, format="JPEG"
    )

    assert (
        photos._validated_thumbnail(
            encoded.getvalue(), declared_media_type="image/jpeg"
        )
        is None
    )


async def test_photo_search_returns_results(client, adult_a_headers, monkeypatch):
    async def fake_search(*, query, limit):
        assert query == "beach"
        return [
            {
                "asset_id": "beach-1",
                "taken_at": "2025-08-01T12:00:00Z",
                "thumbnail_url": "/photos/beach-1/thumbnail?size=preview",
            }
        ]

    monkeypatch.setattr("app.routers.photos.search_photos", fake_search)
    response = await client.get("/api/photos/search", params={"q": "beach"}, headers=adult_a_headers)
    assert response.status_code == 200
    body = response.json()
    assert body["query"] == "beach"
    assert body["results"][0]["asset_id"] == "beach-1"


async def test_photo_search_requires_query(client, adult_a_headers):
    assert (await client.get("/api/photos/search", headers=adult_a_headers)).status_code == 422


async def test_glance_includes_memory_field(client, adult_a_headers, monkeypatch):
    async def fake_memories(*, timezone_name):
        return [
            {
                "asset_id": "memory-1",
                "taken_at": "2025-07-12T10:00:00+01:00",
                "years_ago": 1,
                "thumbnail_url": "/photos/memory-1/thumbnail?size=preview",
            }
        ]

    monkeypatch.setattr("app.services.glance.photo_memories", fake_memories)
    response = await client.get("/api/briefing/glance", headers=adult_a_headers)
    assert response.status_code == 200
    memory = response.json()["memory"]
    assert memory == {
        "asset_id": "memory-1",
        "taken_at": "2025-07-12T10:00:00+01:00",
        "years_ago": 1,
    }
