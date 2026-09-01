"""Bounded Apple Push Notification service delivery.

Device tokens are registered by the authenticated iOS app and encrypted at
rest. This module owns only the provider connection: it never chooses a topic,
URL, SQL statement, or arbitrary APNs payload from model output.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import time
from dataclasses import dataclass
from pathlib import Path

import httpx
import jwt

from app.config import settings

_TOKEN_LIFETIME_SECONDS = 50 * 60
_MAX_KEY_BYTES = 16 * 1024
_provider_token_lock = asyncio.Lock()
_provider_token: tuple[tuple[str, str, str], int, str] | None = None


def apns_configured() -> bool:
    return bool(
        settings.apns_team_id.strip()
        and settings.apns_key_id.strip()
        and settings.apns_private_key_path.strip()
        and settings.apns_bundle_id.strip()
    )


def device_token_hash(device_token: str, environment: str, bundle_id: str) -> str:
    material = f"{environment}\0{bundle_id}\0{device_token.lower()}"
    return hashlib.sha256(material.encode()).hexdigest()


@dataclass(frozen=True)
class APNSDeliveryError(Exception):
    status_code: int
    reason: str

    @property
    def invalidates_device(self) -> bool:
        return self.status_code == 410 or self.reason in {
            "BadDeviceToken",
            "DeviceTokenNotForTopic",
            "Unregistered",
        }

    def __str__(self) -> str:
        return f"APNs delivery failed ({self.status_code}: {self.reason})"


def _read_private_key(path_value: str) -> str:
    path = Path(path_value)
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        raise RuntimeError("APNs private key path is unavailable")
    if path.stat().st_size > _MAX_KEY_BYTES:
        raise RuntimeError("APNs private key is unexpectedly large")
    return path.read_text(encoding="utf-8")


async def _authorization_token() -> str:
    global _provider_token
    identity = (
        settings.apns_team_id.strip(),
        settings.apns_key_id.strip(),
        settings.apns_private_key_path.strip(),
    )
    now = int(time.time())
    async with _provider_token_lock:
        if (
            _provider_token is not None
            and _provider_token[0] == identity
            and now - _provider_token[1] < _TOKEN_LIFETIME_SECONDS
        ):
            return _provider_token[2]
        team_id, key_id, key_path = identity
        if not team_id or not key_id or not key_path:
            raise RuntimeError("APNs is not configured")
        encoded = jwt.encode(
            {"iss": team_id, "iat": now},
            _read_private_key(key_path),
            algorithm="ES256",
            headers={"alg": "ES256", "kid": key_id},
        )
        _provider_token = (identity, now, encoded)
        return encoded


def _bounded_text(value: object, maximum: int) -> str:
    text = str(value or "")
    return text if len(text) <= maximum else text[: maximum - 1] + "…"


async def send_apns(
    *,
    device_token: str,
    environment: str,
    payload: dict,
    collapse_key: str,
) -> None:
    """Send one fixed-topic alert payload over APNs HTTP/2."""
    if not apns_configured():
        raise RuntimeError("APNs is not configured")
    if environment not in {"sandbox", "production"}:
        raise RuntimeError("APNs environment is invalid")
    token = await _authorization_token()
    host = (
        "https://api.sandbox.push.apple.com"
        if environment == "sandbox"
        else "https://api.push.apple.com"
    )
    body = {
        "aps": {
            "alert": {
                "title": _bounded_text(payload.get("title"), 120),
                "body": _bounded_text(payload.get("body"), 512),
            },
            "sound": "default",
            "thread-id": _bounded_text(payload.get("tag", "hausklar"), 64),
        },
        "url": _bounded_text(payload.get("url", "/?view=today"), 512),
    }
    encoded_body = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
    if len(encoded_body) > 4_096:
        raise RuntimeError("APNs payload exceeds the 4 KB alert limit")
    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": settings.apns_bundle_id.strip(),
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": str(int(time.time()) + 3_600),
        "apns-collapse-id": hashlib.sha256(collapse_key.encode()).hexdigest()[:64],
        "content-type": "application/json",
    }
    async with httpx.AsyncClient(http2=True, timeout=10.0) as client:
        response = await client.post(
            f"{host}/3/device/{device_token}",
            content=encoded_body,
            headers=headers,
        )
    if response.status_code == 200:
        return
    reason = "Unknown"
    try:
        decoded = response.json()
        if isinstance(decoded, dict) and isinstance(decoded.get("reason"), str):
            reason = decoded["reason"][:80]
    except (ValueError, json.JSONDecodeError):
        pass
    raise APNSDeliveryError(response.status_code, reason)
