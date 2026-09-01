from unittest.mock import AsyncMock

from app.config import settings
from app.services import weather


async def test_weather_summary_reuses_fresh_cache(monkeypatch):
    forecast = {
        "description": "clear sky",
        "temp_high": 21.0,
        "temp_low": 12.0,
        "rain_chance": 5,
    }
    fetch = AsyncMock(return_value=forecast)
    monkeypatch.setattr(settings, "openweathermap_api_key", "configured-for-test")
    monkeypatch.setattr(weather, "_fetch_weather_summary", fetch)
    weather.clear_weather_cache()

    assert await weather.get_weather_summary() == forecast
    assert await weather.get_weather_summary() == forecast
    fetch.assert_awaited_once()
    weather.clear_weather_cache()
