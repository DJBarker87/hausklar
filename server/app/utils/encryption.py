"""Fernet encryption for server-side integration credentials at rest."""

from cryptography.fernet import Fernet, MultiFernet

from app.config import settings


def _get_fernet() -> Fernet:
    """Return a Fernet instance using the configured encryption key."""
    key = settings.ha_token_encryption_key
    if not key:
        raise RuntimeError(
            "HA_TOKEN_ENCRYPTION_KEY is not set. "
            "Generate one with: python -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\""
        )
    return Fernet(key.encode())


def encrypt_value(plaintext: str) -> str:
    """Encrypt a plaintext string and return the ciphertext as a base64 string."""
    f = _get_fernet()
    return f.encrypt(plaintext.encode()).decode()


def decrypt_value(ciphertext: str) -> str:
    """Decrypt a base64 ciphertext string and return the original plaintext."""
    f = _get_fernet()
    return f.decrypt(ciphertext.encode()).decode()


def _finance_provider_fernets() -> tuple[Fernet, ...]:
    """Return the Finance primary key followed by explicit rotation fallbacks."""
    primary = settings.finance_provider_encryption_key.strip()
    if not primary:
        raise RuntimeError(
            "FINANCE_PROVIDER_ENCRYPTION_KEY is not set for Finance provider storage"
        )
    values = [primary]
    values.extend(
        value.strip()
        for value in settings.finance_provider_encryption_previous_keys.split(",")
        if value.strip()
    )

    unique: list[str] = []
    for value in values:
        if value not in unique:
            unique.append(value)
    try:
        return tuple(Fernet(value.encode()) for value in unique)
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Finance provider encryption key configuration is invalid") from exc


def encrypt_finance_provider_value(plaintext: str) -> str:
    """Encrypt new provider material only with the current Finance primary key."""
    primary = settings.finance_provider_encryption_key.strip()
    if not primary:
        raise RuntimeError(
            "FINANCE_PROVIDER_ENCRYPTION_KEY is not set for Finance provider storage"
        )
    try:
        return Fernet(primary.encode()).encrypt(plaintext.encode()).decode()
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Finance provider encryption key configuration is invalid") from exc


def decrypt_finance_provider_value(ciphertext: str) -> str:
    """Decrypt with the Finance primary or explicitly configured previous keys."""
    return MultiFernet(list(_finance_provider_fernets())).decrypt(ciphertext.encode()).decode()
