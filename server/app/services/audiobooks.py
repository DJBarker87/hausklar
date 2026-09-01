from __future__ import annotations

import math
import json
import re
import uuid
from urllib.parse import urlsplit

import httpx

from app.config import settings
from app.http_clients import provider_client
from app.models.audiobooks import (
    AudiobookChapter,
    AudiobookItemDetail,
    AudiobookLibrariesResponse,
    AudiobookLibrary,
    AudiobookLibraryItem,
    AudiobookLibraryItemsResponse,
    AudiobookMediaInfo,
    AudiobookMetadata,
    AudiobookPlayRequest,
    AudiobookPlayResponse,
    AudiobookProgress,
    AudiobookProgressRequest,
)
from app.models.home import HomeServiceRequest
from app.services.home_assistant import (
    perform_home_service_for_family,
    valid_image_signature,
    validate_bounded_content_length,
)


IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_COVER_BYTES = 8 * 1024 * 1024


class AudiobookUnavailable(RuntimeError):
    pass


def _family_authorized(family_id: str) -> bool:
    allowed_family = (
        settings.audiobookshelf_family_id.strip() or settings.production_family_id.strip()
    )
    return bool(allowed_family) and family_id == allowed_family


def _require_family(family_id: str) -> None:
    if not _family_authorized(family_id):
        raise PermissionError("Audiobooks are not configured for this family")


def _identifier(value: str, label: str) -> str:
    if not IDENTIFIER_RE.fullmatch(value):
        raise ValueError(f"A valid {label} is required")
    return value


def _fixed_origin(value: str, label: str) -> str:
    value = value.strip().rstrip("/")
    parsed = urlsplit(value)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise AudiobookUnavailable(f"The {label} is not configured safely")
    return value


def _upstream() -> tuple[str, str]:
    base = _fixed_origin(settings.audiobookshelf_url, "audiobook service")
    token = settings.audiobookshelf_token.strip()
    if not token:
        raise AudiobookUnavailable("The audiobook service is unavailable")
    return base, token


async def _json_request(
    method: str,
    path: str,
    *,
    payload: dict | None = None,
    params: dict | None = None,
) -> dict:
    base, token = _upstream()
    client = await provider_client(
        "audiobookshelf",
        timeout=httpx.Timeout(connect=3.0, read=10.0, write=5.0, pool=3.0),
        follow_redirects=False,
    )
    async with client.stream(
        method,
        f"{base}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        json=payload,
        params=params,
    ) as response:
        if response.is_redirect:
            raise AudiobookUnavailable("The audiobook service returned an unsafe redirect")
        if response.status_code == 404:
            raise ValueError("That audiobook item is not available")
        response.raise_for_status()
        media_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
        if media_type not in {"application/json", "application/problem+json"}:
            raise AudiobookUnavailable("The audiobook service returned invalid data")
        try:
            validate_bounded_content_length(
                response.headers.get("content-length"), MAX_JSON_BYTES
            )
        except RuntimeError as exc:
            raise AudiobookUnavailable("The audiobook service returned too much data") from exc
        data = bytearray()
        async for chunk in response.aiter_bytes():
            data.extend(chunk)
            if len(data) > MAX_JSON_BYTES:
                raise AudiobookUnavailable("The audiobook service returned too much data")
    try:
        body = json.loads(data)
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        raise AudiobookUnavailable("The audiobook service returned invalid data") from exc
    if not isinstance(body, dict):
        raise AudiobookUnavailable("The audiobook service returned invalid data")
    return body


def _text(value: object, maximum: int = 500) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value[:maximum] if value else None


def _number(value: object, *, minimum: float = 0, maximum: float = 10_000_000) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    if not math.isfinite(result) or result < minimum or result > maximum:
        return None
    return result


def _media(raw: object) -> AudiobookMediaInfo | None:
    if not isinstance(raw, dict):
        return None
    metadata_raw = raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {}
    metadata = AudiobookMetadata(
        title=_text(metadata_raw.get("title")),
        author_name=_text(metadata_raw.get("authorName")),
        narrator_name=_text(metadata_raw.get("narratorName")),
        description=_text(metadata_raw.get("description"), 5_000),
    )
    chapters = []
    for index, chapter in enumerate(raw.get("chapters", [])[:1_000]):
        if not isinstance(chapter, dict):
            continue
        start = _number(chapter.get("start"))
        end = _number(chapter.get("end"))
        if start is None or end is None or end < start:
            continue
        chapter_id = chapter.get("id")
        if not isinstance(chapter_id, int) or isinstance(chapter_id, bool):
            chapter_id = index
        chapters.append(
            AudiobookChapter(
                id=chapter_id,
                title=_text(chapter.get("title"), 300) or f"Chapter {index + 1}",
                start=start,
                end=end,
            )
        )
    return AudiobookMediaInfo(
        metadata=metadata,
        duration=_number(raw.get("duration")),
        chapters=chapters,
    )


def _item(raw: object) -> AudiobookLibraryItem | None:
    if not isinstance(raw, dict) or not isinstance(raw.get("id"), str):
        return None
    try:
        identifier = _identifier(raw["id"], "audiobook item")
    except ValueError:
        return None
    return AudiobookLibraryItem(id=identifier, media=_media(raw.get("media")))


async def libraries_for_family(family_id: str) -> AudiobookLibrariesResponse:
    _require_family(family_id)
    body = await _json_request("GET", "/api/libraries")
    libraries = []
    for value in body.get("libraries", [])[:100]:
        if not isinstance(value, dict) or not isinstance(value.get("id"), str):
            continue
        try:
            identifier = _identifier(value["id"], "audiobook library")
        except ValueError:
            continue
        libraries.append(
            AudiobookLibrary(
                id=identifier,
                name=_text(value.get("name"), 300) or "Audiobooks",
                media_type=_text(value.get("mediaType"), 50) or "book",
            )
        )
    return AudiobookLibrariesResponse(libraries=libraries)


async def library_items_for_family(
    family_id: str,
    library_id: str,
    limit: int,
) -> AudiobookLibraryItemsResponse:
    _require_family(family_id)
    library_id = _identifier(library_id, "audiobook library")
    body = await _json_request(
        "GET",
        f"/api/libraries/{library_id}/items",
        params={"sort": "media.metadata.title", "limit": max(1, min(limit, 100))},
    )
    results = []
    for value in body.get("results", [])[:100]:
        item = _item(value)
        if item is not None:
            results.append(item)
    return AudiobookLibraryItemsResponse(results=results)


async def item_for_family(family_id: str, item_id: str) -> AudiobookItemDetail:
    _require_family(family_id)
    item_id = _identifier(item_id, "audiobook item")
    body = await _json_request("GET", f"/api/items/{item_id}", params={"expanded": "1"})
    item = _item(body)
    if item is None:
        raise AudiobookUnavailable("The audiobook service returned an invalid item")
    progress_raw = body.get("userMediaProgress")
    progress = None
    if isinstance(progress_raw, dict):
        progress = AudiobookProgress(
            current_time=_number(progress_raw.get("currentTime")),
            is_finished=(
                progress_raw.get("isFinished")
                if isinstance(progress_raw.get("isFinished"), bool)
                else None
            ),
            progress=_number(progress_raw.get("progress"), maximum=1),
        )
    return AudiobookItemDetail(
        id=item.id,
        media=item.media,
        user_media_progress=progress,
    )


async def cover_for_family(family_id: str, item_id: str) -> tuple[bytes, str]:
    _require_family(family_id)
    item_id = _identifier(item_id, "audiobook item")
    base, token = _upstream()
    client = await provider_client(
        "audiobookshelf",
        timeout=httpx.Timeout(connect=3.0, read=10.0, write=3.0, pool=3.0),
        follow_redirects=False,
    )
    async with client.stream(
        "GET",
        f"{base}/api/items/{item_id}/cover",
        headers={"Authorization": f"Bearer {token}", "Accept": "image/jpeg, image/png, image/webp"},
    ) as response:
        if response.is_redirect:
            raise AudiobookUnavailable("The audiobook service returned an unsafe redirect")
        if response.status_code == 404:
            raise ValueError("That audiobook cover is not available")
        response.raise_for_status()
        media_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
        if media_type not in {"image/jpeg", "image/png", "image/webp"}:
            raise AudiobookUnavailable("The audiobook service returned an invalid cover")
        try:
            validate_bounded_content_length(
                response.headers.get("content-length"), MAX_COVER_BYTES
            )
        except RuntimeError as exc:
            raise AudiobookUnavailable("The audiobook cover is too large") from exc
        body = bytearray()
        async for chunk in response.aiter_bytes():
            body.extend(chunk)
            if len(body) > MAX_COVER_BYTES:
                raise AudiobookUnavailable("The audiobook cover is too large")
    if not body:
        raise AudiobookUnavailable("The audiobook service returned an empty cover")
    if not valid_image_signature(body, media_type):
        raise AudiobookUnavailable("The audiobook service returned an invalid cover")
    return bytes(body), media_type


async def update_progress_for_family(
    family_id: str,
    item_id: str,
    progress: AudiobookProgressRequest,
) -> None:
    _require_family(family_id)
    item_id = _identifier(item_id, "audiobook item")
    await _json_request(
        "PATCH",
        f"/api/me/progress/{item_id}",
        payload={
            "currentTime": progress.current_time,
            "isFinished": progress.is_finished,
        },
    )


def _audio_file(body: dict) -> tuple[str, str]:
    media = body.get("media")
    files = media.get("audioFiles") if isinstance(media, dict) else None
    if not isinstance(files, list):
        raise AudiobookUnavailable("Secure audiobook playback is unavailable")
    for value in files[:100]:
        if not isinstance(value, dict):
            continue
        ino = str(value.get("ino", ""))
        if not IDENTIFIER_RE.fullmatch(ino):
            continue
        metadata = value.get("metadata") if isinstance(value.get("metadata"), dict) else {}
        extension = str(metadata.get("ext", "")).lower().lstrip(".")
        if extension == "m4b":
            extension = "m4a"
        if extension in {"aac", "flac", "m4a", "mp3", "ogg", "opus", "wav"}:
            return ino, extension
    raise AudiobookUnavailable("Secure audiobook playback is unavailable")


async def play_for_family(
    family_id: str,
    item_id: str,
    request: AudiobookPlayRequest,
) -> AudiobookPlayResponse:
    _require_family(family_id)
    item_id = _identifier(item_id, "audiobook item")
    try:
        handoff_base = _fixed_origin(
            settings.audiobookshelf_handoff_base_url,
            "audiobook playback handoff",
        )
    except AudiobookUnavailable as exc:
        return AudiobookPlayResponse(available=False, reason=str(exc))
    body = await _json_request("GET", f"/api/items/{item_id}", params={"expanded": "1"})
    try:
        ino, extension = _audio_file(body)
    except AudiobookUnavailable as exc:
        return AudiobookPlayResponse(available=False, reason=str(exc))
    # This fixed URL is consumed server-to-server by Home Assistant. It is never
    # returned to iOS, and request data cannot select its host or path shape.
    media_url = f"{handoff_base}/stream/{item_id}/{ino}/audio.{extension}"
    await perform_home_service_for_family(
        family_id,
        HomeServiceRequest(
            domain="media_player",
            service="play_media",
            data={
                "entity_id": request.entity_id,
                "media_content_id": media_url,
                "media_content_type": "music",
            },
        ),
    )
    if request.start_time is not None:
        await update_progress_for_family(
            family_id,
            item_id,
            AudiobookProgressRequest(current_time=request.start_time),
        )
    return AudiobookPlayResponse(available=True, handoff_id=str(uuid.uuid4()))
