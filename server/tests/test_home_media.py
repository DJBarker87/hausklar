import io
from unittest.mock import AsyncMock

import httpx
import pytest
from PIL import Image

from app.config import settings
from app.models.audiobooks import AudiobookPlayRequest
from app.services import audiobooks, home_assistant, media_thumbnails


async def _mock_client(monkeypatch, module, handler):
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler),
        follow_redirects=False,
    )

    async def provide(*_args, **_kwargs):
        return client

    monkeypatch.setattr(module, "provider_client", provide)
    return client


@pytest.mark.asyncio
async def test_camera_snapshot_requires_authentication(client):
    response = await client.get("/api/home/cameras/camera.front_door/snapshot")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_camera_snapshot_returns_bounded_private_image(client, adult_a_headers, monkeypatch):
    mocked = AsyncMock(return_value=(b"jpeg-bytes", "image/jpeg"))
    monkeypatch.setattr("app.routers.home.get_camera_snapshot_for_family", mocked)

    response = await client.get(
        "/api/home/cameras/camera.front_door/snapshot",
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.content == b"jpeg-bytes"
    assert response.headers["cache-control"] == "private, no-store"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert mocked.await_args.args == (
        "00000000-0000-0000-0000-000000000100",
        "camera.front_door",
    )


def test_camera_entity_validation_rejects_non_camera_and_path_syntax():
    assert (
        home_assistant.validate_camera_snapshot_entity_id("camera.front_door")
        == "camera.front_door"
    )
    for value in ["sensor.front_door", "camera../secrets", "camera.front-door", "camera."]:
        with pytest.raises(ValueError):
            home_assistant.validate_camera_snapshot_entity_id(value)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("status", "headers", "body", "message"),
    [
        (302, {"location": "https://evil.example/image"}, b"", "redirected"),
        (200, {"content-type": "text/html"}, b"not an image", "invalid camera image"),
        (200, {"content-type": "image/jpeg"}, b"not-a-jpeg", "invalid camera image"),
        (
            200,
            {"content-type": "image/jpeg", "content-length": "-1"},
            b"\xff\xd8\xffx",
            "invalid image length",
        ),
        (
            200,
            {"content-type": "image/jpeg", "content-length": str(6 * 1024 * 1024)},
            b"x",
            "too large",
        ),
        (200, {"content-type": "image/jpeg"}, b"x" * (5 * 1024 * 1024 + 1), "too large"),
    ],
)
async def test_camera_snapshot_rejects_redirect_mime_and_size_bounds(
    initialized_db,
    monkeypatch,
    status,
    headers,
    body,
    message,
):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(status, headers=headers, content=body)

    client = await _mock_client(monkeypatch, home_assistant, handler)
    monkeypatch.setattr(
        home_assistant,
        "_settings",
        AsyncMock(return_value=("https://ha.internal", "private-token")),
    )
    try:
        with pytest.raises(RuntimeError, match=message):
            await home_assistant.get_camera_snapshot_for_family(
                "00000000-0000-0000-0000-000000000100",
                "camera.front_door",
            )
    finally:
        await client.aclose()

    assert len(requests) == 1
    assert requests[0].url == "https://ha.internal/api/camera_proxy/camera.front_door"
    assert requests[0].headers["authorization"] == "Bearer private-token"


def _thumbnail_jpeg(width: int = 32, height: int = 24) -> bytes:
    output = io.BytesIO()
    Image.new("RGB", (width, height), color="navy").save(output, format="JPEG")
    return output.getvalue()


@pytest.mark.asyncio
async def test_media_thumbnail_requires_authentication(client):
    response = await client.get(
        "/api/home/media/thumbnails/0123456789abcdef0123456789abcdef"
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_media_thumbnail_route_is_private_and_owner_scoped(
    client, adult_a_headers, monkeypatch
):
    body = _thumbnail_jpeg()
    mocked = AsyncMock(return_value=(body, "image/jpeg"))
    monkeypatch.setattr("app.routers.home.get_media_thumbnail_for_family", mocked)

    response = await client.get(
        "/api/home/media/thumbnails/0123456789abcdef0123456789abcdef",
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.content == body
    assert response.headers["cache-control"] == "private, max-age=300"
    assert response.headers["vary"] == "Authorization"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert mocked.await_args.args == (
        "00000000-0000-0000-0000-000000000100",
        "0123456789abcdef0123456789abcdef",
    )


def test_home_media_response_replaces_upstream_artwork_with_opaque_paths():
    media_thumbnails.clear_thumbnail_registry()
    family_id = "00000000-0000-0000-0000-000000000100"
    ha_url = "http://192.0.2.108:8123"
    spotify_url = "https://i.scdn.co/image/album-secret"
    ha_path = "/api/media_player_proxy/media_player.kitchen?token=ha-secret"
    payload = {
        "children": [{"title": "Kitchen", "thumbnail": ha_path}],
        "items": [
            {
                "name": "Album",
                "images": [{"url": spotify_url, "height": 300, "width": 300}],
            }
        ],
        "image_url": "https://evil.example/collect",
    }

    cleaned = home_assistant._sanitise_service_response(
        payload,
        family_id=family_id,
        ha_url=ha_url,
    )

    ha_proxy = cleaned["children"][0]["thumbnail"]
    spotify_proxy = cleaned["items"][0]["images"][0]["url"]
    assert ha_proxy.startswith("/home/media/thumbnails/")
    assert spotify_proxy.startswith("/home/media/thumbnails/")
    assert "image_url" not in cleaned
    assert "192.168" not in str(cleaned)
    assert "scdn.co" not in str(cleaned)
    assert "ha-secret" not in str(cleaned)
    assert media_thumbnails.resolve_thumbnail(family_id, ha_proxy.rsplit("/", 1)[1]) == ha_path
    assert (
        media_thumbnails.resolve_thumbnail(family_id, spotify_proxy.rsplit("/", 1)[1])
        == spotify_url
    )
    with pytest.raises(media_thumbnails.ThumbnailNotFound):
        media_thumbnails.resolve_thumbnail(
            "00000000-0000-0000-0000-000000000200",
            spotify_proxy.rsplit("/", 1)[1],
        )


def test_home_snapshot_replaces_now_playing_artwork_with_opaque_proxy_path():
    media_thumbnails.clear_thumbnail_registry()
    family_id = "00000000-0000-0000-0000-000000000100"
    source = "/api/media_player_proxy/media_player.kitchen?token=upstream-only"

    entities = home_assistant.sanitise_entities(
        [
            {
                "entity_id": "media_player.kitchen",
                "state": "playing",
                "attributes": {
                    "friendly_name": "Kitchen",
                    "entity_picture": source,
                },
            }
        ],
        family_id=family_id,
        ha_url="http://192.0.2.108:8123",
    )

    proxy_path = entities[0]["entity_picture"]
    assert proxy_path.startswith("/home/media/thumbnails/")
    assert "upstream-only" not in str(entities)
    assert (
        media_thumbnails.resolve_thumbnail(family_id, proxy_path.rsplit("/", 1)[1])
        == source
    )


@pytest.mark.parametrize(
    "source",
    [
        "http://i.scdn.co/image/album",
        "https://i.scdn.co:444/image/album",
        "https://user:demo-person-34@example.invalid/image/album",
        "https://evil.example/image/album",
        "//i.scdn.co/image/album",
        "/api/states",
        "/api/media_player_proxy/%252e%252e/secrets",
        "/local/../secrets",
    ],
)
def test_media_thumbnail_source_allowlist_rejects_ambiguous_and_unapproved_urls(source):
    with pytest.raises(media_thumbnails.UnsafeThumbnailSource):
        media_thumbnails.approve_source(
            source,
            ha_url="http://192.0.2.108:8123",
        )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "addresses",
    [
        ("127.0.0.1",),
        ("192.0.2.141",),
        ("169.254.169.254",),
        ("::1",),
        ("2606:4700:4700::1111", "192.0.2.123"),
    ],
)
async def test_spotify_dns_resolution_rejects_private_or_mixed_answers(
    monkeypatch, addresses
):
    monkeypatch.setattr(
        media_thumbnails,
        "_resolve_host",
        AsyncMock(return_value=addresses),
    )
    approved = media_thumbnails.approve_source(
        "https://i.scdn.co/image/album",
        ha_url="http://192.0.2.108:8123",
    )

    with pytest.raises(media_thumbnails.UnsafeThumbnailSource, match="non-public"):
        await media_thumbnails._pinned_spotify_request(approved)


@pytest.mark.asyncio
async def test_spotify_thumbnail_pins_validated_dns_and_preserves_tls_authority(monkeypatch):
    media_thumbnails.clear_thumbnail_registry()
    family_id = "00000000-0000-0000-0000-000000000100"
    path = media_thumbnails.register_thumbnail(
        family_id,
        "https://i.scdn.co/image/album",
        ha_url="http://192.0.2.108:8123",
    )
    token = path.rsplit("/", 1)[1]
    body = _thumbnail_jpeg()
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, headers={"content-type": "image/jpeg"}, content=body)

    outbound = await _mock_client(monkeypatch, media_thumbnails, handler)
    monkeypatch.setattr(
        media_thumbnails,
        "_resolve_host",
        AsyncMock(return_value=("203.0.113.10",)),
    )
    monkeypatch.setattr(media_thumbnails, "_is_public_address", lambda _value: True)
    try:
        result = await media_thumbnails.fetch_registered_thumbnail(
            family_id,
            token,
            ha_url="http://192.0.2.108:8123",
            ha_token="private-ha-token",
        )
    finally:
        await outbound.aclose()

    assert result == (body, "image/jpeg")
    assert len(requests) == 1
    assert requests[0].url.host == "203.0.113.10"
    assert requests[0].headers["host"] == "i.scdn.co"
    assert requests[0].extensions["sni_hostname"] == "i.scdn.co"
    assert "authorization" not in requests[0].headers


@pytest.mark.asyncio
async def test_home_assistant_thumbnail_uses_only_configured_origin_and_rejects_redirects(
    monkeypatch,
):
    media_thumbnails.clear_thumbnail_registry()
    family_id = "00000000-0000-0000-0000-000000000100"
    path = media_thumbnails.register_thumbnail(
        family_id,
        "/api/media_player_proxy/media_player.kitchen?token=upstream-only",
        ha_url="http://192.0.2.108:8123",
    )
    token = path.rsplit("/", 1)[1]
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(302, headers={"location": "https://i.scdn.co/image/pivot"})

    outbound = await _mock_client(monkeypatch, media_thumbnails, handler)
    try:
        with pytest.raises(media_thumbnails.UnsafeThumbnailSource, match="redirects"):
            await media_thumbnails.fetch_registered_thumbnail(
                family_id,
                token,
                ha_url="http://192.0.2.108:8123",
                ha_token="private-ha-token",
            )
    finally:
        await outbound.aclose()

    assert len(requests) == 1
    assert requests[0].url.host == "192.0.2.108"
    assert requests[0].headers["authorization"] == "Bearer " + "private-ha-token"


@pytest.mark.asyncio
async def test_spotify_redirect_cannot_pivot_outside_allowlist(monkeypatch):
    media_thumbnails.clear_thumbnail_registry()
    family_id = "00000000-0000-0000-0000-000000000100"
    path = media_thumbnails.register_thumbnail(
        family_id,
        "https://i.scdn.co/image/album",
        ha_url="http://192.0.2.108:8123",
    )
    token = path.rsplit("/", 1)[1]

    def handler(_request):
        return httpx.Response(302, headers={"location": "http://127.0.0.1/secrets"})

    outbound = await _mock_client(monkeypatch, media_thumbnails, handler)
    monkeypatch.setattr(
        media_thumbnails,
        "_resolve_host",
        AsyncMock(return_value=("203.0.113.10",)),
    )
    monkeypatch.setattr(media_thumbnails, "_is_public_address", lambda _value: True)
    try:
        with pytest.raises(media_thumbnails.UnsafeThumbnailSource):
            await media_thumbnails.fetch_registered_thumbnail(
                family_id,
                token,
                ha_url="http://192.0.2.108:8123",
                ha_token="private-ha-token",
            )
    finally:
        await outbound.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("headers", "body", "message"),
    [
        ({"content-type": "text/html"}, b"<html>", "media type"),
        ({"content-type": "image/jpeg"}, b"not-jpeg", "signature"),
        (
            {
                "content-type": "image/jpeg",
                "content-length": str(media_thumbnails.MAX_THUMBNAIL_BYTES + 1),
            },
            b"x",
            "size limit",
        ),
        (
            {"content-type": "image/jpeg"},
            _thumbnail_jpeg(media_thumbnails.MAX_THUMBNAIL_DIMENSION + 1, 1),
            "dimensions",
        ),
    ],
)
async def test_media_thumbnail_rejects_mime_signature_size_and_dimensions(
    monkeypatch, headers, body, message
):
    media_thumbnails.clear_thumbnail_registry()
    family_id = "00000000-0000-0000-0000-000000000100"
    path = media_thumbnails.register_thumbnail(
        family_id,
        "/local/album.jpg",
        ha_url="http://192.0.2.108:8123",
    )

    def handler(_request):
        return httpx.Response(200, headers=headers, content=body)

    outbound = await _mock_client(monkeypatch, media_thumbnails, handler)
    try:
        with pytest.raises(media_thumbnails.ThumbnailUnavailable, match=message):
            await media_thumbnails.fetch_registered_thumbnail(
                family_id,
                path.rsplit("/", 1)[1],
                ha_url="http://192.0.2.108:8123",
                ha_token="private-ha-token",
            )
    finally:
        await outbound.aclose()


@pytest.mark.asyncio
async def test_media_thumbnail_stops_chunked_body_at_finite_limit(monkeypatch):
    media_thumbnails.clear_thumbnail_registry()
    monkeypatch.setattr(media_thumbnails, "MAX_THUMBNAIL_BYTES", 8)
    family_id = "00000000-0000-0000-0000-000000000100"
    path = media_thumbnails.register_thumbnail(
        family_id,
        "/local/album.jpg",
        ha_url="http://192.0.2.108:8123",
    )

    class ChunkedBody(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b"12345"
            yield b"6789"
            raise AssertionError("the proxy must stop when its byte limit is crossed")

    def handler(_request):
        return httpx.Response(
            200,
            headers={"content-type": "image/jpeg"},
            stream=ChunkedBody(),
        )

    outbound = await _mock_client(monkeypatch, media_thumbnails, handler)
    try:
        with pytest.raises(media_thumbnails.ThumbnailUnavailable, match="size limit"):
            await media_thumbnails.fetch_registered_thumbnail(
                family_id,
                path.rsplit("/", 1)[1],
                ha_url="http://192.0.2.108:8123",
                ha_token="private-ha-token",
            )
    finally:
        await outbound.aclose()


@pytest.mark.asyncio
async def test_audiobook_routes_require_authentication(client):
    for method, path in [
        ("GET", "/api/home/audiobooks/libraries"),
        ("GET", "/api/home/audiobooks/libraries/library-1/items"),
        ("GET", "/api/home/audiobooks/items/item-1"),
        ("GET", "/api/home/audiobooks/items/item-1/cover"),
        ("PATCH", "/api/home/audiobooks/items/item-1/progress"),
        ("POST", "/api/home/audiobooks/items/item-1/play"),
    ]:
        response = await client.request(method, path, json={})
        assert response.status_code == 401, path


@pytest.mark.asyncio
async def test_audiobook_library_proxy_sanitizes_upstream_and_never_exposes_config(
    initialized_db,
    monkeypatch,
):
    monkeypatch.setattr(settings, "audiobookshelf_url", "https://abs.internal")
    monkeypatch.setattr(settings, "audiobookshelf_token", "private-upstream-token")
    monkeypatch.setattr(
        settings,
        "audiobookshelf_family_id",
        "00000000-0000-0000-0000-000000000100",
    )
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(
            200,
            headers={"content-type": "application/json"},
            json={
                "libraries": [
                    {
                        "id": "library-1",
                        "name": "Family books",
                        "mediaType": "book",
                        "token": "must-not-leak",
                        "baseUrl": "https://abs.internal",
                    }
                ],
                "token": "must-not-leak",
            },
        )

    outbound = await _mock_client(monkeypatch, audiobooks, handler)
    try:
        result = await audiobooks.libraries_for_family(
            "00000000-0000-0000-0000-000000000100"
        )
    finally:
        await outbound.aclose()

    assert result.model_dump() == {
        "libraries": [
            {"id": "library-1", "name": "Family books", "media_type": "book"}
        ]
    }
    assert len(requests) == 1
    assert requests[0].url == "https://abs.internal/api/libraries"
    assert requests[0].headers["authorization"] == "Bearer " + "private-upstream-token"
    assert "token" not in str(result.model_dump()).lower()
    assert "internal" not in str(result.model_dump()).lower()


@pytest.mark.asyncio
async def test_audiobook_upstream_redirect_is_not_followed(initialized_db, monkeypatch):
    monkeypatch.setattr(settings, "audiobookshelf_url", "https://abs.internal")
    monkeypatch.setattr(settings, "audiobookshelf_token", "private-upstream-token")
    monkeypatch.setattr(
        settings,
        "audiobookshelf_family_id",
        "00000000-0000-0000-0000-000000000100",
    )
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(307, headers={"location": "https://evil.example/collect"})

    outbound = await _mock_client(monkeypatch, audiobooks, handler)
    try:
        with pytest.raises(audiobooks.AudiobookUnavailable, match="unsafe redirect"):
            await audiobooks.libraries_for_family(
                "00000000-0000-0000-0000-000000000100"
            )
    finally:
        await outbound.aclose()
    assert len(requests) == 1


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("headers", "body"),
    [
        (
            {"content-type": "application/json", "content-length": str(3 * 1024 * 1024)},
            b"{}",
        ),
        ({"content-type": "application/json"}, b"x" * (2 * 1024 * 1024 + 1)),
    ],
)
async def test_audiobook_json_proxy_enforces_length_before_decode(
    initialized_db,
    monkeypatch,
    headers,
    body,
):
    family_id = "00000000-0000-0000-0000-000000000100"
    monkeypatch.setattr(settings, "audiobookshelf_url", "https://abs.internal")
    monkeypatch.setattr(settings, "audiobookshelf_token", "private-upstream-token")
    monkeypatch.setattr(settings, "audiobookshelf_family_id", family_id)

    def handler(_request):
        return httpx.Response(200, headers=headers, content=body)

    outbound = await _mock_client(monkeypatch, audiobooks, handler)
    try:
        with pytest.raises(audiobooks.AudiobookUnavailable, match="too much data"):
            await audiobooks.libraries_for_family(family_id)
    finally:
        await outbound.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("headers", "body", "message"),
    [
        ({"content-type": "image/jpeg"}, b"not-jpeg", "invalid cover"),
        (
            {"content-type": "image/png", "content-length": str(9 * 1024 * 1024)},
            b"\x89PNG\r\n\x1a\n",
            "too large",
        ),
        (
            {"content-type": "image/webp", "content-length": "-1"},
            b"RIFFxxxxWEBPdata",
            "too large",
        ),
    ],
)
async def test_audiobook_cover_rejects_magic_and_length_bounds(
    initialized_db,
    monkeypatch,
    headers,
    body,
    message,
):
    family_id = "00000000-0000-0000-0000-000000000100"
    monkeypatch.setattr(settings, "audiobookshelf_url", "https://abs.internal")
    monkeypatch.setattr(settings, "audiobookshelf_token", "private-upstream-token")
    monkeypatch.setattr(settings, "audiobookshelf_family_id", family_id)

    def handler(_request):
        return httpx.Response(200, headers=headers, content=body)

    outbound = await _mock_client(monkeypatch, audiobooks, handler)
    try:
        with pytest.raises(audiobooks.AudiobookUnavailable, match=message):
            await audiobooks.cover_for_family(family_id, "item-1")
    finally:
        await outbound.aclose()


@pytest.mark.asyncio
async def test_audiobook_invalid_identifier_and_wrong_family_never_call_upstream(monkeypatch):
    provider = AsyncMock()
    monkeypatch.setattr(audiobooks, "provider_client", provider)
    monkeypatch.setattr(
        settings,
        "audiobookshelf_family_id",
        "00000000-0000-0000-0000-000000000100",
    )

    with pytest.raises(PermissionError):
        await audiobooks.item_for_family(
            "00000000-0000-0000-0000-000000000200", "item-1"
        )
    with pytest.raises(ValueError):
        await audiobooks.item_for_family(
            "00000000-0000-0000-0000-000000000100", "../secret"
        )
    provider.assert_not_awaited()


@pytest.mark.asyncio
async def test_audiobook_playback_is_server_side_and_returns_only_opaque_handoff(monkeypatch):
    family_id = "00000000-0000-0000-0000-000000000100"
    monkeypatch.setattr(settings, "audiobookshelf_family_id", family_id)
    monkeypatch.setattr(
        settings,
        "audiobookshelf_handoff_base_url",
        "http://hausklar-stream.internal/api/audiobooks",
    )
    monkeypatch.setattr(
        audiobooks,
        "_json_request",
        AsyncMock(
            return_value={
                "media": {
                    "audioFiles": [
                        {"ino": "987654", "metadata": {"ext": "m4b"}}
                    ]
                }
            }
        ),
    )
    home_service = AsyncMock(return_value={"success": True})
    monkeypatch.setattr(audiobooks, "perform_home_service_for_family", home_service)
    progress = AsyncMock(return_value=None)
    monkeypatch.setattr(audiobooks, "update_progress_for_family", progress)

    result = await audiobooks.play_for_family(
        family_id,
        "item-1",
        AudiobookPlayRequest(entity_id="media_player.example_2da32186", start_time=120),
    )

    assert result.available is True
    assert result.handoff_id
    assert "url" not in result.model_dump()
    service_request = home_service.await_args.args[1]
    assert service_request.data["media_content_id"] == (
        "http://hausklar-stream.internal/api/audiobooks/stream/item-1/987654/audio.m4a"
    )
    assert "media_content_id" not in result.model_dump()
    progress.assert_awaited_once()


@pytest.mark.asyncio
async def test_audiobook_playback_fails_closed_without_fixed_handoff(monkeypatch):
    family_id = "00000000-0000-0000-0000-000000000100"
    monkeypatch.setattr(settings, "audiobookshelf_family_id", family_id)
    monkeypatch.setattr(settings, "audiobookshelf_handoff_base_url", "")
    upstream = AsyncMock()
    monkeypatch.setattr(audiobooks, "_json_request", upstream)

    result = await audiobooks.play_for_family(
        family_id,
        "item-1",
        AudiobookPlayRequest(entity_id="media_player.example_2da32186"),
    )

    assert result.available is False
    assert result.handoff_id is None
    assert result.reason
    upstream.assert_not_awaited()
