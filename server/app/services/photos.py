"""Family photo memories and chapters backed by the local Immich archive."""

import asyncio
import io
import logging
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx
from PIL import Image, UnidentifiedImageError

from app.config import settings
from app.http_clients import provider_client

logger = logging.getLogger(__name__)

_MEMORY_YEARS = 10
_MEMORY_WINDOW_DAYS = 3
_CACHE_SECONDS = 3_600
_MAX_THUMBNAIL_BYTES = 5 * 1_024 * 1_024
_MAX_THUMBNAIL_WIDTH = 4_096
_MAX_THUMBNAIL_HEIGHT = 4_096
_MAX_THUMBNAIL_PIXELS = 4_000_000
_THUMBNAIL_MEDIA_TYPES = {"image/jpeg", "image/png", "image/webp"}
_THUMBNAIL_FORMAT_MEDIA_TYPES = {
    "JPEG": "image/jpeg",
    "PNG": "image/png",
    "WEBP": "image/webp",
}
_memories_cache: dict[str, tuple[float, list[dict]]] = {}
_memories_tasks: dict[str, asyncio.Task[list[dict]]] = {}
_memories_lock = asyncio.Lock()


def immich_is_configured() -> bool:
    return bool(settings.immich_url.strip() and settings.immich_api_key.strip())


def _zone(timezone_name: str) -> ZoneInfo:
    try:
        return ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("Europe/London")


async def _search_assets(
    client: httpx.AsyncClient,
    *,
    taken_after: datetime,
    taken_before: datetime,
    size: int,
) -> list[dict]:
    response = await client.post(
        f"{settings.immich_url.rstrip('/')}/api/search/metadata",
        headers={"x-api-key": settings.immich_api_key},
        json={
            "takenAfter": taken_after.astimezone(timezone.utc).isoformat(),
            "takenBefore": taken_before.astimezone(timezone.utc).isoformat(),
            "size": size,
            "withDeleted": False,
        },
    )
    response.raise_for_status()
    assets = response.json().get("assets", {})
    return assets.get("items", []) if isinstance(assets, dict) else []


def _pick_memory(items: list[dict]) -> dict | None:
    photos = [item for item in items if item.get("type") == "IMAGE"] or items
    if not photos:
        return None
    favourites = [item for item in photos if item.get("isFavorite")]
    return (favourites or photos)[0]


async def _fetch_photo_memories(*, timezone_name: str) -> list[dict]:
    zone = _zone(timezone_name)
    today = datetime.now(zone).date()
    limiter = asyncio.Semaphore(4)

    async def memory_for_year(client: httpx.AsyncClient, years_ago: int) -> dict | None:
        try:
            anniversary = today.replace(year=today.year - years_ago)
        except ValueError:
            anniversary = today.replace(year=today.year - years_ago, day=28)
        start = datetime.combine(
            anniversary - timedelta(days=_MEMORY_WINDOW_DAYS),
            datetime.min.time(),
            tzinfo=zone,
        )
        end = start + timedelta(days=2 * _MEMORY_WINDOW_DAYS + 1)
        async with limiter:
            items = await _search_assets(
                client, taken_after=start, taken_before=end, size=50
            )
        chosen = _pick_memory(items)
        taken_at = chosen and (
            chosen.get("fileCreatedAt") or chosen.get("localDateTime")
        )
        if not chosen or not taken_at:
            return None
        return {
            "asset_id": chosen["id"],
            "taken_at": taken_at,
            "years_ago": years_ago,
            "thumbnail_url": f"/photos/{chosen['id']}/thumbnail?size=preview",
        }

    try:
        client = await provider_client("immich", timeout=5.0)
        candidates = await asyncio.gather(
            *(memory_for_year(client, year) for year in range(1, _MEMORY_YEARS + 1))
        )
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        logger.warning("Photo memories unavailable: %s", exc)
        return []
    return [item for item in candidates if item is not None]


async def _refresh_photo_memories(
    *, timezone_name: str, cache_key: str
) -> list[dict]:
    memories = await _fetch_photo_memories(timezone_name=timezone_name)
    _memories_cache.clear()
    _memories_cache[cache_key] = (time.monotonic(), memories)
    return memories


def _clear_memories_task(cache_key: str, task: asyncio.Task[list[dict]]) -> None:
    if _memories_tasks.get(cache_key) is task:
        _memories_tasks.pop(cache_key, None)
    if not task.cancelled():
        task.exception()


async def _memory_task(*, timezone_name: str, cache_key: str) -> asyncio.Task[list[dict]]:
    async with _memories_lock:
        task = _memories_tasks.get(cache_key)
        if task is None or task.done():
            task = asyncio.create_task(
                _refresh_photo_memories(
                    timezone_name=timezone_name, cache_key=cache_key
                )
            )
            _memories_tasks[cache_key] = task
            task.add_done_callback(
                lambda completed: _clear_memories_task(cache_key, completed)
            )
        return task


def _memory_cache_key(timezone_name: str) -> str:
    today = datetime.now(_zone(timezone_name)).date()
    return f"{today.isoformat()}:{timezone_name}"


async def cached_photo_memories(*, timezone_name: str) -> list[dict]:
    """Return fresh-or-stale memories immediately and refresh in the background."""
    if not immich_is_configured():
        return []
    cache_key = _memory_cache_key(timezone_name)
    cached = _memories_cache.get(cache_key)
    if cached and time.monotonic() - cached[0] < _CACHE_SECONDS:
        return cached[1]
    await _memory_task(timezone_name=timezone_name, cache_key=cache_key)
    return cached[1] if cached else []


async def photo_memories(*, timezone_name: str) -> list[dict]:
    """One photo per past year, taken this calendar week."""
    if not immich_is_configured():
        return []
    cache_key = _memory_cache_key(timezone_name)
    cached = _memories_cache.get(cache_key)
    if cached and time.monotonic() - cached[0] < _CACHE_SECONDS:
        return cached[1]
    task = await _memory_task(timezone_name=timezone_name, cache_key=cache_key)
    return await task


async def photo_chapters(db, *, family_id: str, timezone_name: str) -> list[dict]:
    """Life-event date ranges from family data, with photo counts from Immich."""
    if not immich_is_configured():
        return []
    zone = _zone(timezone_name)
    today = datetime.now(zone).date()
    ranges: list[dict] = []

    cursor = await db.execute(
        """
        SELECT h.label, h.date, h.person_id
        FROM holiday_dates h
        WHERE h.family_id = ? AND h.deleted_at IS NULL AND h.date <= ?
        ORDER BY h.date DESC LIMIT 200
        """,
        (family_id, today.isoformat()),
    )
    holiday_rows = [dict(row) for row in await cursor.fetchall()]
    # Compress consecutive holiday dates into one chapter per stretch.
    stretch: list[str] = []
    for row in sorted(holiday_rows, key=lambda item: item["date"]):
        if stretch and (
            datetime.fromisoformat(row["date"]).date()
            - datetime.fromisoformat(stretch[-1]).date()
        ) > timedelta(days=1):
            if len(stretch) >= 5:
                ranges.append(
                    {
                        "title": f"School holidays {stretch[0][:4]}",
                        "start": stretch[0],
                        "end": stretch[-1],
                    }
                )
            stretch = []
        stretch.append(row["date"])
    if len(stretch) >= 5:
        ranges.append(
            {
                "title": f"School holidays {stretch[0][:4]}",
                "start": stretch[0],
                "end": stretch[-1],
            }
        )

    cursor = await db.execute(
        """
        SELECT person_name, date_of_birth FROM birthdays
        WHERE family_id = ? AND deleted_at IS NULL LIMIT 50
        """,
        (family_id,),
    )
    for row in await cursor.fetchall():
        birth = datetime.fromisoformat(row["date_of_birth"][:10]).date()
        for year in range(birth.year + 1, today.year + 1):
            try:
                day = birth.replace(year=year)
            except ValueError:
                day = birth.replace(year=year, day=28)
            if day <= today:
                ranges.append(
                    {
                        "title": f"{row['person_name']}'s birthday {year}",
                        "start": day.isoformat(),
                        "end": (day + timedelta(days=1)).isoformat(),
                    }
                )

    ranges.sort(key=lambda item: item["start"], reverse=True)
    chapters: list[dict] = []
    try:
        client = await provider_client("immich", timeout=5.0)
        for entry in ranges[:12]:
            start = datetime.combine(
                datetime.fromisoformat(entry["start"]).date(),
                datetime.min.time(),
                tzinfo=zone,
            )
            end = datetime.combine(
                datetime.fromisoformat(entry["end"]).date() + timedelta(days=1),
                datetime.min.time(),
                tzinfo=zone,
            )
            items = await _search_assets(
                client, taken_after=start, taken_before=end, size=4
            )
            if not items:
                continue
            chapters.append(
                {
                    "title": entry["title"],
                    "start": entry["start"],
                    "end": entry["end"],
                    "sample_asset_ids": [item["id"] for item in items],
                }
            )
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        logger.warning("Photo chapters unavailable: %s", exc)
        return []
    return chapters


async def photo_year_summary(*, year: int) -> dict:
    """Count and a few highlight thumbnails for photos taken in a calendar year."""
    if not immich_is_configured():
        return {"count": 0, "highlights": []}
    start = datetime(year, 1, 1, tzinfo=timezone.utc)
    end = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    try:
        client = await provider_client("immich", timeout=5.0)
        items = await _search_assets(
            client, taken_after=start, taken_before=end, size=250
        )
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        logger.warning("Photo year summary unavailable: %s", exc)
        return {"count": 0, "highlights": []}
    images = [item for item in items if item.get("type") == "IMAGE"]
    favourites = [item for item in images if item.get("isFavorite")]
    highlights = (favourites or images)[:6]
    return {
        "count": len(images),
        "highlights": [
            {
                "asset_id": item["id"],
                "thumbnail_url": f"/photos/{item['id']}/thumbnail?size=preview",
            }
            for item in highlights
        ],
    }


async def search_photos(*, query: str, limit: int) -> list[dict]:
    """Semantic photo search over Immich (CLIP smart search, metadata fallback)."""
    if not immich_is_configured() or not query.strip():
        return []
    base = settings.immich_url.rstrip("/")
    headers = {"x-api-key": settings.immich_api_key}
    payload = {"query": query.strip()[:200], "size": min(limit, 60)}
    try:
        client = await provider_client("immich", timeout=5.0)
        response = await client.post(f"{base}/api/search/smart", headers=headers, json=payload)
        if response.status_code == 404:
            response = await client.post(
                f"{base}/api/search/metadata", headers=headers, json=payload
            )
        response.raise_for_status()
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("Photo search unavailable: %s", exc)
        return []
    assets = response.json().get("assets", {})
    items = assets.get("items", []) if isinstance(assets, dict) else []
    return [
        {
            "asset_id": item["id"],
            "taken_at": item.get("fileCreatedAt") or item.get("localDateTime"),
            "thumbnail_url": f"/photos/{item['id']}/thumbnail?size=preview",
        }
        for item in items
        if item.get("type") == "IMAGE"
    ][:limit]


async def fetch_thumbnail(asset_id: str, size: str) -> tuple[bytes, str] | None:
    """Proxy an asset thumbnail from Immich, keeping the API key server-side."""
    if not immich_is_configured():
        return None
    size = size if size in {"thumbnail", "preview"} else "preview"
    try:
        client = await provider_client("immich", timeout=8.0)
        async with client.stream(
            "GET",
            f"{settings.immich_url.rstrip('/')}/api/assets/{asset_id}/thumbnail",
            headers={"x-api-key": settings.immich_api_key},
            params={"size": size},
        ) as response:
            response.raise_for_status()
            media_type = response.headers.get("content-type", "").split(";", 1)[0]
            media_type = media_type.strip().lower()
            if media_type not in _THUMBNAIL_MEDIA_TYPES:
                logger.warning("Immich thumbnail rejected: unsupported media type")
                return None

            content_length = response.headers.get("content-length")
            if content_length is not None:
                try:
                    declared_length = int(content_length)
                except ValueError:
                    logger.warning("Immich thumbnail rejected: invalid content length")
                    return None
                if declared_length <= 0 or declared_length > _MAX_THUMBNAIL_BYTES:
                    logger.warning("Immich thumbnail rejected: declared size outside limit")
                    return None

            payload = bytearray()
            async for chunk in response.aiter_bytes():
                if len(payload) + len(chunk) > _MAX_THUMBNAIL_BYTES:
                    logger.warning("Immich thumbnail rejected: streamed body exceeds limit")
                    return None
                payload.extend(chunk)

        return _validated_thumbnail(bytes(payload), declared_media_type=media_type)
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("Immich thumbnail unavailable: %s", exc)
        return None


def _validated_thumbnail(
    content: bytes, *, declared_media_type: str
) -> tuple[bytes, str] | None:
    if not content or len(content) > _MAX_THUMBNAIL_BYTES:
        return None
    try:
        with Image.open(io.BytesIO(content)) as image:
            media_type = _THUMBNAIL_FORMAT_MEDIA_TYPES.get(image.format or "")
            width, height = image.size
            if (
                media_type is None
                or media_type != declared_media_type
                or width <= 0
                or height <= 0
                or width > _MAX_THUMBNAIL_WIDTH
                or height > _MAX_THUMBNAIL_HEIGHT
                or width * height > _MAX_THUMBNAIL_PIXELS
            ):
                return None
            image.verify()
    except (Image.DecompressionBombError, OSError, UnidentifiedImageError, ValueError):
        return None
    return content, media_type
