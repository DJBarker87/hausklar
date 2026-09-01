"""Deployment-only construction of the Enable Banking read adapter."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse
from uuid import UUID

import httpx
from cryptography.fernet import Fernet

from app.config import settings
from app.services.finance.providers.base import ReadOnlyBankProvider
from app.services.finance.providers.enable_banking import EnableBankingAdapter
from app.services.finance.providers.enable_banking_auth import EnableBankingJwtFactory

MAX_PRIVATE_KEY_BYTES = 64 * 1024
CALLBACK_PATH = "/api/finance/connections/enable-banking/callback"


class EnableBankingConfigurationError(RuntimeError):
    """Enable Banking cannot run with the server's current configuration."""


def _private_key_bytes() -> tuple[str, bytes]:
    application_id = settings.enable_banking_application_id.strip()
    private_key_value = settings.enable_banking_private_key_path.strip()
    callback_url = settings.enable_banking_callback_url.strip()
    if not application_id or not private_key_value or not callback_url:
        raise EnableBankingConfigurationError("Enable Banking is not configured")
    try:
        UUID(application_id)
    except ValueError:
        raise EnableBankingConfigurationError("Enable Banking application ID is invalid") from None

    key_path = Path(private_key_value)
    if not key_path.is_absolute() or not key_path.is_file():
        raise EnableBankingConfigurationError("Enable Banking private key path is unavailable")
    try:
        size = key_path.stat().st_size
    except OSError:
        raise EnableBankingConfigurationError(
            "Enable Banking private key path is unavailable"
        ) from None
    if not 1 <= size <= MAX_PRIVATE_KEY_BYTES:
        raise EnableBankingConfigurationError("Enable Banking private key file is invalid")
    try:
        private_key = key_path.read_bytes()
    except OSError:
        raise EnableBankingConfigurationError(
            "Enable Banking private key path is unavailable"
        ) from None

    callback = urlparse(callback_url)
    if (
        callback.scheme != "https"
        or not callback.hostname
        or callback.username
        or callback.password
        or callback.query
        or callback.fragment
        or callback.path != CALLBACK_PATH
    ):
        raise EnableBankingConfigurationError(
            "Enable Banking callback URL is not the fixed HTTPS callback"
        )
    encryption_keys = [
        settings.finance_provider_encryption_key.strip(),
        *(
            value.strip()
            for value in settings.finance_provider_encryption_previous_keys.split(",")
            if value.strip()
        ),
    ]
    legacy_key = settings.ha_token_encryption_key.strip()
    if encryption_keys[0] and legacy_key and encryption_keys[0] == legacy_key:
        raise EnableBankingConfigurationError(
            "Enable Banking encrypted storage needs a dedicated Finance key"
        )
    try:
        if not encryption_keys[0]:
            raise ValueError
        for encryption_key in dict.fromkeys(encryption_keys):
            Fernet(encryption_key.encode())
    except (TypeError, ValueError):
        raise EnableBankingConfigurationError(
            "Enable Banking encrypted storage is not configured"
        ) from None
    return application_id, private_key


def enable_banking_callback_url() -> str:
    """Return the validated fixed callback without accepting a client override."""
    _private_key_bytes()
    return settings.enable_banking_callback_url.strip()


@asynccontextmanager
async def configured_enable_banking_provider() -> AsyncIterator[ReadOnlyBankProvider]:
    """Build one request-scoped adapter and close its bounded HTTP client."""
    application_id, private_key = _private_key_bytes()
    try:
        token_factory = EnableBankingJwtFactory(
            application_id=application_id,
            private_key_pem=private_key,
        )
    except ValueError:
        raise EnableBankingConfigurationError(
            "Enable Banking private key configuration is invalid"
        ) from None
    async with httpx.AsyncClient() as client:
        yield EnableBankingAdapter(client=client, token_factory=token_factory)
