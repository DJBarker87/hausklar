"""Deployment-only construction of the TrueLayer Data API v1 adapter."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import urlparse

import httpx
from cryptography.fernet import Fernet

from app.config import settings
from app.services.finance.providers.truelayer import TrueLayerAdapter

TRUELAYER_CALLBACK_PATH = "/api/finance/connections/truelayer/callback"


class TrueLayerConfigurationError(RuntimeError):
    """TrueLayer cannot run with the server's current configuration."""


def _configuration() -> tuple[str, str, str]:
    client_id = settings.truelayer_client_id.strip()
    client_secret = settings.truelayer_client_secret.strip()
    callback_url = settings.truelayer_callback_url.strip()
    if not client_id or not client_secret or not callback_url:
        raise TrueLayerConfigurationError("TrueLayer is not configured")
    if len(client_id) > 500 or len(client_secret) > 2_000:
        raise TrueLayerConfigurationError("TrueLayer credentials are invalid")
    callback = urlparse(callback_url)
    try:
        explicit_port = callback.port is not None
    except ValueError:
        explicit_port = True
    if (
        callback.scheme != "https"
        or not callback.hostname
        or explicit_port
        or callback.username
        or callback.password
        or callback.params
        or callback.query
        or callback.fragment
        or callback.path != TRUELAYER_CALLBACK_PATH
    ):
        raise TrueLayerConfigurationError(
            "TrueLayer callback URL is not the fixed HTTPS callback"
        )
    finance_key = settings.finance_provider_encryption_key.strip()
    legacy_key = settings.ha_token_encryption_key.strip()
    if finance_key and legacy_key and finance_key == legacy_key:
        raise TrueLayerConfigurationError(
            "TrueLayer encrypted storage needs a dedicated Finance key"
        )
    try:
        if not finance_key:
            raise ValueError
        Fernet(finance_key.encode())
    except (TypeError, ValueError):
        raise TrueLayerConfigurationError(
            "TrueLayer encrypted storage is not configured"
        ) from None
    return client_id, client_secret, callback_url


def truelayer_callback_url() -> str:
    """Return the validated callback without accepting a browser override."""
    return _configuration()[2]


@asynccontextmanager
async def configured_truelayer_provider() -> AsyncIterator[TrueLayerAdapter]:
    """Build one bounded server-side adapter and close its HTTP pool."""
    client_id, client_secret, callback_url = _configuration()
    limits = httpx.Limits(max_connections=10, max_keepalive_connections=5)
    async with httpx.AsyncClient(limits=limits, trust_env=False) as client:
        yield TrueLayerAdapter(
            client=client,
            client_id=client_id,
            client_secret=client_secret,
            redirect_uri=callback_url,
        )
