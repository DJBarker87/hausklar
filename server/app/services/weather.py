"""Weather service — fetches and briefly caches OpenWeatherMap forecasts."""

import asyncio
from time import monotonic

import httpx

from app.config import settings
from app.http_clients import provider_client

_weather_cache: tuple[float, dict | None] | None = None
_weather_lock = asyncio.Lock()
_weather_refresh_task: asyncio.Task[dict | None] | None = None


def clear_weather_cache() -> None:
    """Clear the process-local forecast cache (primarily for tests)."""
    global _weather_cache, _weather_refresh_task
    _weather_cache = None
    if _weather_refresh_task is not None and not _weather_refresh_task.done():
        _weather_refresh_task.cancel()
    _weather_refresh_task = None


def _weather_cache_value() -> dict | None:
    return _weather_cache[1] if _weather_cache is not None else None


def _clear_refresh_task(task: asyncio.Task[dict | None]) -> None:
    global _weather_refresh_task
    if _weather_refresh_task is task:
        _weather_refresh_task = None
    if not task.cancelled():
        task.exception()


async def cached_weather_summary() -> dict | None:
    """Return fresh-or-stale weather immediately and refresh it in the background."""
    global _weather_refresh_task
    if not settings.openweathermap_api_key:
        return None
    now = monotonic()
    if _weather_cache and now - _weather_cache[0] < settings.weather_cache_ttl_seconds:
        return _weather_cache[1]
    if _weather_refresh_task is None or _weather_refresh_task.done():
        _weather_refresh_task = asyncio.create_task(get_weather_summary())
        _weather_refresh_task.add_done_callback(_clear_refresh_task)
    return _weather_cache_value()


async def get_weather_summary() -> dict | None:
    """Fetch the next ~24 hours of weather from OpenWeatherMap.

    Returns a dict with keys: description, temp_high, temp_low, rain_chance.
    Returns None if the API key is not configured or the request fails.
    """
    global _weather_cache

    if not settings.openweathermap_api_key:
        return None

    now = monotonic()
    if _weather_cache and now - _weather_cache[0] < settings.weather_cache_ttl_seconds:
        return _weather_cache[1]

    async with _weather_lock:
        now = monotonic()
        if _weather_cache and now - _weather_cache[0] < settings.weather_cache_ttl_seconds:
            return _weather_cache[1]

        forecast = await _fetch_weather_summary()
        _weather_cache = (now, forecast)
        return forecast


async def _fetch_weather_summary() -> dict | None:
    """Fetch one uncached forecast from OpenWeatherMap."""

    url = "https://api.openweathermap.org/data/2.5/forecast"
    params = {
        "lat": settings.openweathermap_lat,
        "lon": settings.openweathermap_lon,
        "appid": settings.openweathermap_api_key,
        "units": "metric",
        "cnt": 8,  # 8 x 3-hour intervals = 24 hours
    }

    try:
        client = await provider_client("openweathermap", timeout=5.0)
        resp = await client.get(url, params=params)
        resp.raise_for_status()
        data = resp.json()
    except (httpx.HTTPError, Exception):
        return None

    if "list" not in data or not data["list"]:
        return None

    forecasts = data["list"]

    # Aggregate across all forecast periods
    temps = [f["main"]["temp"] for f in forecasts]
    temp_high = round(max(temps), 1)
    temp_low = round(min(temps), 1)

    # Rain chance: percentage of periods with precipitation probability > 0
    rain_probs = [f.get("pop", 0) for f in forecasts]
    rain_chance = round(max(rain_probs) * 100)  # highest probability as percentage

    # Use the first period's weather description as the summary
    description = forecasts[0]["weather"][0]["description"] if forecasts[0].get("weather") else "unknown"

    return {
        "description": description,
        "temp_high": temp_high,
        "temp_low": temp_low,
        "rain_chance": rain_chance,
    }
