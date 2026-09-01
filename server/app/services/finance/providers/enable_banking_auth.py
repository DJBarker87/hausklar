"""Server-only application JWTs for Enable Banking's read-only API."""

from collections.abc import Callable
from datetime import datetime, timezone
from uuid import UUID

import jwt
from cryptography.hazmat.primitives import serialization


class EnableBankingJwtFactory:
    """Create short-lived RS256 tokens without exposing the private key to clients."""

    def __init__(
        self,
        *,
        application_id: str,
        private_key_pem: str | bytes,
        lifetime_seconds: int = 3_600,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        try:
            UUID(application_id)
        except (TypeError, ValueError) as exc:
            raise ValueError("Enable Banking application ID must be a UUID") from exc
        if not 60 <= lifetime_seconds <= 3_600:
            raise ValueError("Enable Banking JWT lifetime must be between 60 and 3,600 seconds")
        encoded_key = (
            private_key_pem.encode("utf-8")
            if isinstance(private_key_pem, str)
            else private_key_pem
        )
        try:
            private_key = serialization.load_pem_private_key(encoded_key, password=None)
        except (TypeError, ValueError) as exc:
            raise ValueError("Enable Banking private key is not valid unencrypted PEM") from exc
        if private_key.key_size < 2_048:
            raise ValueError("Enable Banking RSA private key must be at least 2,048 bits")
        self._application_id = application_id
        self._private_key = private_key
        self._lifetime_seconds = lifetime_seconds
        self._clock = clock or (lambda: datetime.now(timezone.utc))

    def __call__(self) -> str:
        now = self._clock()
        if now.tzinfo is None or now.utcoffset() is None:
            raise ValueError("Enable Banking JWT clock must be timezone-aware")
        issued_at = int(now.astimezone(timezone.utc).timestamp())
        return jwt.encode(
            {
                "iss": "enablebanking.com",
                "aud": "api.enablebanking.com",
                "iat": issued_at,
                "exp": issued_at + self._lifetime_seconds,
            },
            self._private_key,
            algorithm="RS256",
            headers={"typ": "JWT", "kid": self._application_id},
        )
