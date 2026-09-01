"""Tests for the Fernet encryption utility (app.utils.encryption)."""

import pytest
from cryptography.fernet import Fernet, InvalidToken

from app.utils.encryption import (
    decrypt_finance_provider_value,
    decrypt_value,
    encrypt_finance_provider_value,
    encrypt_value,
)

# Fixed test key — never use this in production.
TEST_FERNET_KEY = Fernet.generate_key().decode()


@pytest.fixture(autouse=True)
def _set_encryption_key(monkeypatch):
    """Point the encryption module at a deterministic test key."""
    monkeypatch.setattr("app.config.settings.ha_token_encryption_key", TEST_FERNET_KEY)
    monkeypatch.setattr("app.config.settings.finance_provider_encryption_key", "")
    monkeypatch.setattr("app.config.settings.finance_provider_encryption_previous_keys", "")


def test_encrypt_decrypt_roundtrip():
    """Encrypting then decrypting should return the original plaintext."""
    assert decrypt_value(encrypt_value("hello")) == "hello"


def test_ciphertext_differs_from_plaintext():
    """The ciphertext must not equal the original plaintext."""
    assert encrypt_value("secret") != "secret"


def test_different_encryptions_differ():
    """Two encryptions of the same string should differ (Fernet uses a random IV)."""
    a = encrypt_value("x")
    b = encrypt_value("x")
    assert a != b


def test_decrypt_wrong_key_raises(monkeypatch):
    """Decrypting with a different key should raise InvalidToken."""
    ciphertext = encrypt_value("payload")

    # Swap to a brand-new key
    other_key = Fernet.generate_key().decode()
    monkeypatch.setattr("app.config.settings.ha_token_encryption_key", other_key)

    with pytest.raises(InvalidToken):
        decrypt_value(ciphertext)


def test_encrypt_empty_string():
    """An empty string should round-trip cleanly."""
    assert decrypt_value(encrypt_value("")) == ""


def test_finance_provider_uses_its_own_primary_and_only_explicit_legacy_fallback(
    monkeypatch,
):
    legacy_ciphertext = encrypt_value("legacy provider session")
    finance_key = Fernet.generate_key().decode()
    monkeypatch.setattr(
        "app.config.settings.finance_provider_encryption_key", finance_key
    )

    new_ciphertext = encrypt_finance_provider_value("new provider session")

    with pytest.raises(InvalidToken):
        Fernet(TEST_FERNET_KEY.encode()).decrypt(new_ciphertext.encode())
    assert decrypt_finance_provider_value(new_ciphertext) == "new provider session"
    with pytest.raises(InvalidToken):
        decrypt_finance_provider_value(legacy_ciphertext)

    monkeypatch.setattr(
        "app.config.settings.finance_provider_encryption_previous_keys",
        TEST_FERNET_KEY,
    )
    assert decrypt_finance_provider_value(legacy_ciphertext) == "legacy provider session"


def test_finance_provider_key_rotation_keeps_explicit_previous_fallback(monkeypatch):
    old_key = Fernet.generate_key().decode()
    monkeypatch.setattr("app.config.settings.finance_provider_encryption_key", old_key)
    old_ciphertext = encrypt_finance_provider_value("session before rotation")

    monkeypatch.setattr(
        "app.config.settings.finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    monkeypatch.setattr(
        "app.config.settings.finance_provider_encryption_previous_keys", old_key
    )

    assert decrypt_finance_provider_value(old_ciphertext) == "session before rotation"
