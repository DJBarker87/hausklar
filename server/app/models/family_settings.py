import ipaddress
from urllib.parse import urlsplit

from pydantic import BaseModel, Field, field_validator


def _validate_optional_http_url(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    if not value:
        return None
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("A valid HTTP or HTTPS URL is required")
    if parsed.username or parsed.password:
        raise ValueError("Credentials must not be embedded in URLs")
    return value.rstrip("/")


def normalised_origin(value: str) -> str:
    parsed = urlsplit(value)
    default_port = 443 if parsed.scheme == "https" else 80
    port = parsed.port or default_port
    return f"{parsed.scheme.lower()}://{parsed.hostname.lower()}:{port}"


def validate_ha_origin(value: str, allowed_origins: str = "") -> str:
    """Allow only the configured HA origin, or private LAN origins by default."""
    value = _validate_optional_http_url(value)
    if value is None:
        raise ValueError("A Home Assistant URL is required")
    origin = normalised_origin(value)
    configured = {
        normalised_origin(item.strip())
        for item in allowed_origins.split(",")
        if item.strip()
    }
    if configured:
        if origin not in configured:
            raise ValueError("Home Assistant URL is not an allowed server origin")
        return value

    hostname = urlsplit(value).hostname or ""
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        if not hostname.lower().endswith(".local"):
            raise ValueError("Home Assistant must use an approved private LAN origin")
    else:
        if not address.is_private or address.is_loopback or address.is_link_local:
            raise ValueError("Home Assistant must use an approved private LAN origin")
    return value


class HASettingsUpdate(BaseModel):
    """Request body for PUT /api/family/settings/ha"""
    dashboard_url: str | None = Field(default=None, max_length=2_048)
    ha_url: str | None = Field(default=None, max_length=2_048)
    ha_token: str | None = Field(default=None, min_length=20, max_length=4_096)
    config_api_url: str | None = Field(default=None, max_length=2_048)

    _validate_dashboard_url = field_validator("dashboard_url")(_validate_optional_http_url)
    _validate_ha_url = field_validator("ha_url")(_validate_optional_http_url)
    _validate_config_api_url = field_validator("config_api_url")(_validate_optional_http_url)

    @field_validator("ha_token")
    @classmethod
    def normalise_token(cls, value: str | None) -> str | None:
        return value.strip() if value is not None else None


class HASettingsTestRequest(BaseModel):
    """Candidate credentials for a connection check; values are never persisted."""

    ha_url: str | None = None
    ha_token: str | None = Field(default=None, min_length=20, max_length=4_096)

    _validate_ha_url = field_validator("ha_url")(_validate_optional_http_url)

    @field_validator("ha_token")
    @classmethod
    def normalise_token(cls, value: str | None) -> str | None:
        return value.strip() if value is not None else None


class HASettingsResponse(BaseModel):
    """Response body for GET /api/family/settings/ha"""
    dashboard_url: str | None = None
    ha_url: str | None = None
    config_api_url: str | None = None
    token_configured: bool = False
    configured: bool = False
