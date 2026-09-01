import pytest
from cryptography.fernet import Fernet

from app.config import settings, validate_security_configuration


def _minimal_production_config(monkeypatch) -> None:
    values = {
        "app_env": "production",
        "jwt_secret_key": "x" * 32,
        "legacy_health_integrations_enabled": False,
        "resend_api_key": "",
        "resend_webhook_secret": "",
        "resend_inbound_domain": "",
        "resend_inbound_address": "",
        "app_base_url": "https://api.example.test",
        "web_app_url": "https://app.example.test",
        "hermes_bridge_url": "",
        "hermes_bridge_token": "",
        "immich_url": "",
        "immich_api_key": "",
        "ha_token_encryption_key": "",
        "finance_provider_encryption_key": "",
        "finance_provider_encryption_previous_keys": "",
        "finance_ai_provider": "off",
        "enable_banking_application_id": "",
        "enable_banking_private_key_path": "",
        "enable_banking_callback_url": "",
        "truelayer_client_id": "",
        "truelayer_client_secret": "",
        "truelayer_callback_url": "",
        "web_push_vapid_private_key": "",
        "web_push_vapid_public_key": "",
    }
    for name, value in values.items():
        monkeypatch.setattr(settings, name, value)


def test_production_rejects_placeholder_resend_sender(monkeypatch):
    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(settings, "resend_api_key", "re_configured")
    monkeypatch.setattr(settings, "resend_from_email", "noreply@example.invalid")

    with pytest.raises(RuntimeError, match="valid non-local sender"):
        validate_security_configuration()


def test_production_accepts_named_resend_sender(monkeypatch):
    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(settings, "resend_api_key", "re_configured")
    monkeypatch.setattr(
        settings,
        "resend_from_email",
        "HausKlar <noreply@operator.example.com>",
    )

    validate_security_configuration()


def test_production_hermes_finance_requires_private_bridge(monkeypatch):
    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(settings, "finance_ai_provider", "hermes")

    with pytest.raises(RuntimeError, match="FINANCE_AI_PROVIDER=hermes"):
        validate_security_configuration()


def test_production_enable_banking_accepts_dedicated_finance_encryption_key(
    monkeypatch,
):
    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(settings, "enable_banking_application_id", "0ecb8be6-8c02-4f2a-b4d8-ae66866ea873")
    monkeypatch.setattr(settings, "enable_banking_private_key_path", "/run/secrets/enable-banking.pem")
    monkeypatch.setattr(
        settings,
        "enable_banking_callback_url",
        "https://api.example.test/api/finance/connections/enable-banking/callback",
    )
    monkeypatch.setattr(
        settings, "finance_provider_encryption_key", Fernet.generate_key().decode()
    )

    validate_security_configuration()


def test_production_enable_banking_rejects_shared_ha_key_as_primary(monkeypatch):
    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(
        settings,
        "enable_banking_application_id",
        "0ecb8be6-8c02-4f2a-b4d8-ae66866ea873",
    )
    monkeypatch.setattr(
        settings,
        "enable_banking_private_key_path",
        "/run/secrets/enable-banking.pem",
    )
    monkeypatch.setattr(
        settings,
        "enable_banking_callback_url",
        "https://api.example.test/api/finance/connections/enable-banking/callback",
    )
    monkeypatch.setattr(
        settings, "ha_token_encryption_key", Fernet.generate_key().decode()
    )

    with pytest.raises(RuntimeError, match="FINANCE_PROVIDER_ENCRYPTION_KEY"):
        validate_security_configuration()


def test_production_truelayer_requires_complete_fixed_server_configuration(monkeypatch):
    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(settings, "truelayer_client_id", "hausklar-client")
    with pytest.raises(RuntimeError, match="must be configured together"):
        validate_security_configuration()

    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(settings, "truelayer_client_id", "hausklar-client")
    monkeypatch.setattr(settings, "truelayer_client_secret", "server-only-secret")
    monkeypatch.setattr(
        settings,
        "truelayer_callback_url",
        "https://api.example.test/not-the-finance-callback",
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    with pytest.raises(RuntimeError, match="fixed HTTPS Finance callback"):
        validate_security_configuration()

    monkeypatch.setattr(
        settings,
        "truelayer_callback_url",
        "https://api.example.test:443/api/finance/connections/truelayer/callback",
    )
    with pytest.raises(RuntimeError, match="fixed HTTPS Finance callback"):
        validate_security_configuration()

    monkeypatch.setattr(
        settings,
        "truelayer_callback_url",
        "https://api.example.test:broken/api/finance/connections/truelayer/callback",
    )
    with pytest.raises(RuntimeError, match="fixed HTTPS Finance callback"):
        validate_security_configuration()


def test_production_truelayer_accepts_dedicated_encrypted_storage(monkeypatch):
    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(settings, "truelayer_client_id", "hausklar-client")
    monkeypatch.setattr(settings, "truelayer_client_secret", "server-only-secret")
    monkeypatch.setattr(
        settings,
        "truelayer_callback_url",
        "https://api.example.test/api/finance/connections/truelayer/callback",
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )

    validate_security_configuration()


def test_production_enable_banking_rejects_the_same_finance_and_ha_key(monkeypatch):
    _minimal_production_config(monkeypatch)
    shared_key = Fernet.generate_key().decode()
    monkeypatch.setattr(settings, "ha_token_encryption_key", shared_key)
    monkeypatch.setattr(settings, "finance_provider_encryption_key", shared_key)

    with pytest.raises(RuntimeError, match="must be distinct"):
        validate_security_configuration()


def test_production_rejects_invalid_finance_provider_rotation_key(monkeypatch):
    _minimal_production_config(monkeypatch)
    monkeypatch.setattr(
        settings, "finance_provider_encryption_previous_keys", "not-a-fernet-key"
    )

    with pytest.raises(RuntimeError, match="Finance provider encryption keys"):
        validate_security_configuration()
