from datetime import datetime, timezone

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app.services.finance.providers import EnableBankingJwtFactory


def _key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _pem(private_key) -> bytes:
    from cryptography.hazmat.primitives import serialization

    return private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


def test_enable_banking_jwt_has_only_the_documented_short_lived_claims():
    private_key = _key()
    application_id = "497f6eca-6276-4993-bfeb-53cbbbba6f08"
    factory = EnableBankingJwtFactory(
        application_id=application_id,
        private_key_pem=_pem(private_key),
        clock=lambda: datetime(2026, 8, 1, 9, 30, tzinfo=timezone.utc),
    )

    token = factory()
    header = jwt.get_unverified_header(token)
    claims = jwt.decode(
        token,
        private_key.public_key(),
        algorithms=["RS256"],
        audience="api.enablebanking.com",
        issuer="enablebanking.com",
        options={"verify_exp": False, "verify_iat": False},
    )

    assert header == {"alg": "RS256", "kid": application_id, "typ": "JWT"}
    assert set(claims) == {"iss", "aud", "iat", "exp"}
    assert claims["exp"] - claims["iat"] == 3_600
    assert "payments" not in token


def test_enable_banking_jwt_rejects_bad_identity_key_and_lifetime():
    private_key = _key()
    with pytest.raises(ValueError, match="UUID"):
        EnableBankingJwtFactory(application_id="not-an-id", private_key_pem=_pem(private_key))
    with pytest.raises(ValueError, match="PEM"):
        EnableBankingJwtFactory(
            application_id="497f6eca-6276-4993-bfeb-53cbbbba6f08",
            private_key_pem="not a key",
        )
    with pytest.raises(ValueError, match="3,600"):
        EnableBankingJwtFactory(
            application_id="497f6eca-6276-4993-bfeb-53cbbbba6f08",
            private_key_pem=_pem(private_key),
            lifetime_seconds=3_601,
        )
