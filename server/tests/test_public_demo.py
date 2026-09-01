import pytest

from app.config import Settings
from app.db import seed as demo_seed


@pytest.mark.asyncio
async def test_demo_seed_refuses_production_before_opening_database(monkeypatch):
    monkeypatch.setattr(demo_seed.settings, "app_env", "production")
    monkeypatch.setenv("DEMO_PASSWORD", "synthetic-demo-password")
    with pytest.raises(RuntimeError, match="development or demo"):
        await demo_seed.seed()


def test_public_defaults_disable_external_integrations(monkeypatch):
    for key in (
        "ALLOW_PUBLIC_REGISTRATION",
        "SCHEDULER_ENABLED",
        "FINANCE_AI_PROVIDER",
        "LEGACY_HEALTH_INTEGRATIONS_ENABLED",
        "STRAVA_INTEGRATION_ENABLED",
        "WITHINGS_INTEGRATION_ENABLED",
        "HERMES_BRIDGE_URL",
        "RESEND_API_KEY",
        "HA_TOKEN_ENCRYPTION_KEY",
    ):
        monkeypatch.delenv(key, raising=False)
    public = Settings(_env_file=None)
    assert public.app_env == "development"
    assert public.allow_public_registration is False
    assert public.scheduler_enabled is False
    assert public.finance_ai_provider == "off"
    assert public.legacy_health_integrations_enabled is False
    assert public.strava_integration_enabled is False
    assert public.withings_integration_enabled is False
    assert public.hermes_bridge_url == ""
    assert public.resend_api_key == ""
    assert public.ha_token_encryption_key == ""
