import httpx
import pytest
from cryptography.fernet import Fernet

from app.config import settings
from app.services.finance.providers.truelayer import TrueLayerAdapter
from app.services.finance.providers.truelayer_config import (
    TrueLayerConfigurationError,
    configured_truelayer_provider,
    truelayer_callback_url,
)


def _configure(monkeypatch, **overrides) -> None:
    values = {
        "truelayer_client_id": "hausklar-client",
        "truelayer_client_secret": "server-only-secret",
        "truelayer_callback_url": (
            "https://hausklar.example/api/finance/connections/truelayer/callback"
        ),
        "finance_provider_encryption_key": Fernet.generate_key().decode(),
        "ha_token_encryption_key": "",
    }
    values.update(overrides)
    for name, value in values.items():
        monkeypatch.setattr(settings, name, value)


def test_true_layer_callback_is_fixed_https_and_requires_encrypted_storage(monkeypatch):
    _configure(monkeypatch)
    assert truelayer_callback_url() == (
        "https://hausklar.example/api/finance/connections/truelayer/callback"
    )

    _configure(monkeypatch, truelayer_callback_url="https://evil.example/callback")
    with pytest.raises(TrueLayerConfigurationError, match="fixed HTTPS"):
        truelayer_callback_url()

    _configure(
        monkeypatch,
        truelayer_callback_url=(
            "https://hausklar.example:443/api/finance/connections/truelayer/callback"
        ),
    )
    with pytest.raises(TrueLayerConfigurationError, match="fixed HTTPS"):
        truelayer_callback_url()

    _configure(
        monkeypatch,
        truelayer_callback_url=(
            "https://hausklar.example:broken/api/finance/connections/truelayer/callback"
        ),
    )
    with pytest.raises(TrueLayerConfigurationError, match="fixed HTTPS"):
        truelayer_callback_url()

    _configure(monkeypatch, finance_provider_encryption_key="")
    with pytest.raises(TrueLayerConfigurationError, match="encrypted storage"):
        truelayer_callback_url()


def test_true_layer_rejects_a_shared_home_assistant_key(monkeypatch):
    key = Fernet.generate_key().decode()
    _configure(
        monkeypatch,
        finance_provider_encryption_key=key,
        ha_token_encryption_key=key,
    )
    with pytest.raises(TrueLayerConfigurationError, match="dedicated Finance key"):
        truelayer_callback_url()


@pytest.mark.asyncio
async def test_configured_adapter_uses_a_server_owned_bounded_client(monkeypatch):
    _configure(monkeypatch)
    constructed: dict = {}

    class FakeClient:
        def __init__(self, **kwargs):
            constructed.update(kwargs)

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

    monkeypatch.setattr(httpx, "AsyncClient", FakeClient)

    async with configured_truelayer_provider() as provider:
        assert isinstance(provider, TrueLayerAdapter)

    assert constructed["trust_env"] is False
    assert constructed["limits"].max_connections == 10
