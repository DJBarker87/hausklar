"""Bounded, SSRF-resistant artwork proxy for Home media browse results."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import io
import ipaddress
import secrets
import socket
import time
import warnings
from collections import OrderedDict
from dataclasses import dataclass
from urllib.parse import unquote, urljoin, urlsplit, urlunsplit

import httpx
from PIL import Image, UnidentifiedImageError

from app.http_clients import provider_client
from app.models.family_settings import normalised_origin

MAX_THUMBNAIL_BYTES = 3 * 1_024 * 1_024
MAX_THUMBNAIL_DIMENSION = 8_192
MAX_THUMBNAIL_PIXELS = 24_000_000
MAX_REDIRECTS = 2
TOTAL_FETCH_SECONDS = 12.0
REGISTRY_TTL_SECONDS = 15 * 60
MAX_REGISTRY_ENTRIES = 2_048

_ALLOWED_MEDIA_TYPES = {"image/jpeg", "image/png", "image/webp"}
_FORMAT_MEDIA_TYPES = {
    "JPEG": "image/jpeg",
    "PNG": "image/png",
    "WEBP": "image/webp",
}
_SPOTIFY_HOST_SUFFIXES = (".scdn.co", ".spotifycdn.com")
_SPOTIFY_EXACT_HOSTS = {"scdn.co", "spotifycdn.com"}
_HA_PATH_PREFIXES = (
    "/api/image/serve/",
    "/api/image_proxy/",
    "/api/media_player_proxy/",
    "/api/media_source_proxy/",
    "/local/",
    "/media/",
)
_registry_secret = secrets.token_bytes(32)


class ThumbnailNotFound(ValueError):
    """The opaque thumbnail reference is absent, expired, or belongs to another family."""


class UnsafeThumbnailSource(ValueError):
    """The source is outside the deliberately narrow artwork trust boundary."""


class ThumbnailUnavailable(RuntimeError):
    """The approved upstream did not return one safe bounded image."""


@dataclass(frozen=True)
class _RegistryEntry:
    family_id: str
    source: str
    expires_at: float


@dataclass(frozen=True)
class _ApprovedSource:
    logical_url: str
    kind: str
    host: str


_registry: OrderedDict[str, _RegistryEntry] = OrderedDict()


def _canonical_host(host: str | None) -> str:
    if not host:
        raise UnsafeThumbnailSource("The artwork host is invalid")
    try:
        result = host.rstrip(".").encode("idna").decode("ascii").lower()
    except UnicodeError as exc:
        raise UnsafeThumbnailSource("The artwork host is invalid") from exc
    if not result or "%" in result or len(result) > 253:
        raise UnsafeThumbnailSource("The artwork host is invalid")
    return result


def _decoded_path_is_safe(path: str) -> bool:
    decoded = path
    for _ in range(3):
        next_value = unquote(decoded)
        if next_value == decoded:
            break
        decoded = next_value
    if "\\" in decoded or "\x00" in decoded:
        return False
    return all(segment not in {".", ".."} for segment in decoded.split("/"))


def _is_allowed_ha_path(path: str) -> bool:
    return (
        len(path.encode("utf-8")) <= 1_024
        and _decoded_path_is_safe(path)
        and any(path.startswith(prefix) for prefix in _HA_PATH_PREFIXES)
    )


def _is_spotify_host(host: str) -> bool:
    return host in _SPOTIFY_EXACT_HOSTS or any(
        host.endswith(suffix) for suffix in _SPOTIFY_HOST_SUFFIXES
    )


def approve_source(source: str, *, ha_url: str) -> _ApprovedSource:
    """Validate an artwork source without performing network I/O."""
    if (
        not isinstance(source, str)
        or not source
        or len(source.encode("utf-8")) > 2_048
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in source)
        or "\\" in source
    ):
        raise UnsafeThumbnailSource("The artwork source is invalid")
    try:
        parsed = urlsplit(source)
    except ValueError as exc:
        raise UnsafeThumbnailSource("The artwork source is invalid") from exc
    if parsed.fragment or len(parsed.query.encode("utf-8")) > 1_024:
        raise UnsafeThumbnailSource("The artwork source is invalid")

    if not parsed.scheme and not parsed.netloc:
        if not source.startswith("/") or source.startswith("//"):
            raise UnsafeThumbnailSource("The Home Assistant artwork path is invalid")
        if not _is_allowed_ha_path(parsed.path):
            raise UnsafeThumbnailSource("The Home Assistant artwork path is not allowed")
        ha_origin = urlsplit(ha_url)
        host = _canonical_host(ha_origin.hostname)
        return _ApprovedSource(
            logical_url=f"{ha_url.rstrip('/')}{source}",
            kind="home_assistant",
            host=host,
        )

    if parsed.username or parsed.password or not parsed.scheme or not parsed.netloc:
        raise UnsafeThumbnailSource("The artwork URL is invalid")
    try:
        port = parsed.port
    except ValueError as exc:
        raise UnsafeThumbnailSource("The artwork port is invalid") from exc
    host = _canonical_host(parsed.hostname)

    if normalised_origin(source) == normalised_origin(ha_url):
        if not _is_allowed_ha_path(parsed.path):
            raise UnsafeThumbnailSource("The Home Assistant artwork path is not allowed")
        return _ApprovedSource(logical_url=source, kind="home_assistant", host=host)

    if (
        parsed.scheme.lower() != "https"
        or (port or 443) != 443
        or not _is_spotify_host(host)
        or not parsed.path.startswith("/")
        or not _decoded_path_is_safe(parsed.path)
    ):
        raise UnsafeThumbnailSource("The external artwork origin is not allowed")
    return _ApprovedSource(logical_url=source, kind="spotify", host=host)


def _purge_registry(now: float) -> None:
    expired = [token for token, entry in _registry.items() if entry.expires_at <= now]
    for token in expired:
        _registry.pop(token, None)
    while len(_registry) > MAX_REGISTRY_ENTRIES:
        _registry.popitem(last=False)


def register_thumbnail(family_id: str, source: str, *, ha_url: str) -> str | None:
    """Retain an approved source server-side and return only an opaque API path."""
    try:
        approved = approve_source(source, ha_url=ha_url)
    except UnsafeThumbnailSource:
        return None
    digest = hmac.new(
        _registry_secret,
        f"{family_id}\x00{approved.logical_url}".encode(),
        hashlib.sha256,
    ).hexdigest()[:32]
    now = time.monotonic()
    _registry[digest] = _RegistryEntry(
        family_id=family_id,
        source=source,
        expires_at=now + REGISTRY_TTL_SECONDS,
    )
    _registry.move_to_end(digest)
    _purge_registry(now)
    return f"/home/media/thumbnails/{digest}"


def resolve_thumbnail(family_id: str, token: str) -> str:
    if len(token) != 32 or any(character not in "0123456789abcdef" for character in token):
        raise ThumbnailNotFound("That media thumbnail is unavailable")
    now = time.monotonic()
    _purge_registry(now)
    entry = _registry.get(token)
    if entry is None or entry.family_id != family_id or entry.expires_at <= now:
        raise ThumbnailNotFound("That media thumbnail is unavailable")
    _registry.move_to_end(token)
    return entry.source


async def _resolve_host(host: str, port: int) -> tuple[str, ...]:
    def lookup() -> tuple[str, ...]:
        records = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        return tuple(dict.fromkeys(record[4][0] for record in records))

    try:
        return await asyncio.wait_for(asyncio.to_thread(lookup), timeout=2.0)
    except (OSError, TimeoutError) as exc:
        raise ThumbnailUnavailable("The artwork host could not be resolved") from exc


def _is_public_address(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value.split("%", 1)[0])
    except ValueError:
        return False
    return (
        address.is_global
        and not address.is_private
        and not address.is_loopback
        and not address.is_link_local
        and not address.is_multicast
        and not address.is_reserved
        and not address.is_unspecified
    )


async def _pinned_spotify_request(approved: _ApprovedSource) -> tuple[str, dict[str, str], dict]:
    addresses = await _resolve_host(approved.host, 443)
    if not addresses or any(not _is_public_address(address) for address in addresses):
        raise UnsafeThumbnailSource("The artwork host resolved to a non-public address")
    address = sorted(addresses, key=lambda value: (":" in value, value))[0]
    parsed = urlsplit(approved.logical_url)
    netloc = f"[{address}]" if ":" in address else address
    pinned_url = urlunsplit(("https", netloc, parsed.path, parsed.query, ""))
    return pinned_url, {"Host": approved.host}, {"sni_hostname": approved.host}


def _content_length(headers: httpx.Headers) -> int | None:
    raw = headers.get("content-length")
    if raw is None:
        return None
    try:
        value = int(raw)
    except ValueError as exc:
        raise ThumbnailUnavailable("The artwork length is invalid") from exc
    if value <= 0 or value > MAX_THUMBNAIL_BYTES:
        raise ThumbnailUnavailable("The artwork exceeds the size limit")
    return value


def _validated_image(content: bytes, declared_media_type: str) -> tuple[bytes, str]:
    if not content or len(content) > MAX_THUMBNAIL_BYTES:
        raise ThumbnailUnavailable("The artwork exceeds the size limit")
    signatures = {
        "image/jpeg": content.startswith(b"\xff\xd8\xff"),
        "image/png": content.startswith(b"\x89PNG\r\n\x1a\n"),
        "image/webp": len(content) >= 12
        and content[:4] == b"RIFF"
        and content[8:12] == b"WEBP",
    }
    if not signatures.get(declared_media_type, False):
        raise ThumbnailUnavailable("The artwork signature is invalid")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(content)) as image:
                media_type = _FORMAT_MEDIA_TYPES.get(image.format or "")
                width, height = image.size
                if (
                    media_type != declared_media_type
                    or getattr(image, "n_frames", 1) != 1
                    or width <= 0
                    or height <= 0
                    or width > MAX_THUMBNAIL_DIMENSION
                    or height > MAX_THUMBNAIL_DIMENSION
                    or width * height > MAX_THUMBNAIL_PIXELS
                ):
                    raise ThumbnailUnavailable("The artwork dimensions or format are invalid")
                image.verify()
    except ThumbnailUnavailable:
        raise
    except (
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
        OSError,
        UnidentifiedImageError,
        ValueError,
    ) as exc:
        raise ThumbnailUnavailable("The artwork is invalid") from exc
    return content, declared_media_type


async def fetch_registered_thumbnail(
    family_id: str,
    token: str,
    *,
    ha_url: str,
    ha_token: str,
) -> tuple[bytes, str]:
    """Fetch one registered image with bounded redirects, time, bytes, and pixels."""
    source = resolve_thumbnail(family_id, token)
    approved = approve_source(source, ha_url=ha_url)
    initial_kind = approved.kind
    timeout = httpx.Timeout(connect=3.0, read=5.0, write=3.0, pool=3.0)
    client = await provider_client(
        "home_media_thumbnail",
        timeout=timeout,
        follow_redirects=False,
        trust_env=False,
    )

    try:
        async with asyncio.timeout(TOTAL_FETCH_SECONDS):
            for redirect_count in range(MAX_REDIRECTS + 1):
                approved = approve_source(approved.logical_url, ha_url=ha_url)
                if approved.kind != initial_kind:
                    raise UnsafeThumbnailSource("The artwork redirect changed trust boundary")
                headers = {
                    "Accept": "image/jpeg, image/png, image/webp",
                    "Accept-Encoding": "identity",
                }
                extensions: dict = {}
                request_url = approved.logical_url
                if approved.kind == "home_assistant":
                    headers["Authorization"] = f"Bearer {ha_token}"
                else:
                    request_url, pinned_headers, extensions = await _pinned_spotify_request(
                        approved
                    )
                    headers.update(pinned_headers)

                request = client.build_request(
                    "GET",
                    request_url,
                    headers=headers,
                    extensions=extensions,
                )
                response = await client.send(request, stream=True, follow_redirects=False)
                try:
                    if response.is_redirect:
                        if approved.kind == "home_assistant":
                            raise UnsafeThumbnailSource(
                                "Home Assistant artwork redirects are not allowed"
                            )
                        if redirect_count >= MAX_REDIRECTS:
                            raise ThumbnailUnavailable("The artwork redirected too many times")
                        location = response.headers.get("location")
                        if not location or len(location.encode("utf-8")) > 2_048:
                            raise ThumbnailUnavailable("The artwork redirect is invalid")
                        logical_url = urljoin(approved.logical_url, location)
                        approved = approve_source(logical_url, ha_url=ha_url)
                        if approved.kind != "spotify":
                            raise UnsafeThumbnailSource(
                                "The artwork redirect left the approved origin set"
                            )
                        continue

                    if response.status_code == 404:
                        raise ThumbnailNotFound("That media thumbnail is unavailable")
                    response.raise_for_status()
                    media_type = response.headers.get("content-type", "").split(";", 1)[0]
                    media_type = media_type.strip().lower()
                    if media_type not in _ALLOWED_MEDIA_TYPES:
                        raise ThumbnailUnavailable("The artwork media type is invalid")
                    _content_length(response.headers)
                    payload = bytearray()
                    async for chunk in response.aiter_bytes():
                        if len(payload) + len(chunk) > MAX_THUMBNAIL_BYTES:
                            raise ThumbnailUnavailable("The artwork exceeds the size limit")
                        payload.extend(chunk)
                    return _validated_image(bytes(payload), media_type)
                finally:
                    await response.aclose()
    except (ThumbnailNotFound, ThumbnailUnavailable, UnsafeThumbnailSource):
        raise
    except TimeoutError as exc:
        raise ThumbnailUnavailable("The artwork request timed out") from exc
    except httpx.HTTPError as exc:
        raise ThumbnailUnavailable("The artwork provider is unavailable") from exc
    raise ThumbnailUnavailable("The artwork provider did not return an image")


def clear_thumbnail_registry() -> None:
    """Test/process-lifecycle hook; registry entries contain private upstream URLs."""
    _registry.clear()
