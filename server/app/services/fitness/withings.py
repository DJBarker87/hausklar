"""Secure owner-bound Withings OAuth, import, notifications, and chart history."""

from __future__ import annotations

import asyncio
import hashlib
import ipaddress
import json
import math
import secrets
import uuid
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from urllib.parse import urlencode

import httpx

from app.config import settings
from app.database import standalone_db
from app.middleware.rate_limit import reserve_persistent_attempts
from app.models.fitness import BodyMeasurementPayload
from app.models.fitness_recovery import RecoveryObservationPayload
from app.services.fitness import nutrition, recovery
from app.services.fitness.common import (
    FitnessConflictError,
    insert_owned,
    json_text,
    update_owned,
)
from app.services.record_history import save_history
from app.utils.encryption import decrypt_value, encrypt_value


WITHINGS_AUTHORIZE_URL = "https://account.withings.com/oauth2_user/authorize2"
WITHINGS_API_BASE = "https://wbsapi.withings.net"
WITHINGS_TOKEN_URL = f"{WITHINGS_API_BASE}/v2/oauth2"
WITHINGS_MEASURE_URL = f"{WITHINGS_API_BASE}/measure"
WITHINGS_NOTIFY_URL = f"{WITHINGS_API_BASE}/notify"
WITHINGS_SCOPES = ("user.metrics",)
WITHINGS_NOTIFICATION_CATEGORIES = (1, 4)
WITHINGS_MEASURE_TYPES = (1, 4, 5, 6, 8, 9, 10, 11, 76, 77, 88)
OAUTH_STATE_TTL = timedelta(minutes=10)
ACCESS_TOKEN_REFRESH_SKEW = timedelta(minutes=5)
REFRESH_TOKEN_TTL = timedelta(days=365)
SYNC_LEASE_TTL = timedelta(minutes=10)
MAX_MEASURE_PAGES = 100
MAX_MEASURE_GROUPS = 50_000
TREND_HALF_LIFE_DAYS = 7.0
_ID_NAMESPACE = uuid.UUID("255e753f-1e55-4b82-ac7c-0262385d5767")
_WITHINGS_NOTIFY_DNS = "ipblock-notify.withings.net"
_WITHINGS_DOH_URL = "https://cloudflare-dns.com/dns-query"
_notification_networks: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...] = ()
_notification_networks_updated_at: datetime | None = None
_notification_network_lock = asyncio.Lock()


async def notification_source_allowed(source_ip: str) -> bool:
    """Fail closed to Withings' published notification networks."""
    try:
        address = ipaddress.ip_address(source_ip.strip())
    except ValueError:
        return False
    global _notification_networks, _notification_networks_updated_at
    now = datetime.now(timezone.utc)
    refresh_due = (
        not _notification_networks
        or _notification_networks_updated_at is None
        or now - _notification_networks_updated_at > timedelta(hours=24)
    )
    if refresh_due:
        async with _notification_network_lock:
            if (
                not _notification_networks
                or _notification_networks_updated_at is None
                or now - _notification_networks_updated_at > timedelta(hours=24)
            ):
                try:
                    async with httpx.AsyncClient(timeout=5.0) as client:
                        response = await client.get(
                            _WITHINGS_DOH_URL,
                            params={"name": _WITHINGS_NOTIFY_DNS, "type": "TXT"},
                            headers={"Accept": "application/dns-json"},
                        )
                        response.raise_for_status()
                        if len(response.content) > 64 * 1024:
                            raise ValueError("Withings DNS response is too large")
                        body = response.json()
                    answers = body.get("Answer", []) if isinstance(body, dict) else []
                    if not isinstance(answers, list) or len(answers) > 20:
                        raise ValueError("invalid Withings DNS response")
                    parsed: list[
                        ipaddress.IPv4Network | ipaddress.IPv6Network
                    ] = []
                    for answer in answers:
                        if not isinstance(answer, dict) or answer.get("type") != 16:
                            continue
                        data = answer.get("data")
                        if not isinstance(data, str) or len(data) > 4_096:
                            continue
                        for value in data.replace('"', "").split():
                            parsed.append(ipaddress.ip_network(value, strict=False))
                    if not parsed:
                        raise ValueError("Withings DNS allowlist is empty")
                    _notification_networks = tuple(parsed)
                    _notification_networks_updated_at = now
                except (httpx.HTTPError, json.JSONDecodeError, ValueError):
                    # A previously resolved list remains usable for eight days;
                    # scheduled pulls cover a cold-start DNS outage.
                    if (
                        _notification_networks_updated_at is None
                        or now - _notification_networks_updated_at > timedelta(days=8)
                    ):
                        return False
    return any(address in network for network in _notification_networks)


class WithingsError(ValueError):
    """A Withings operation could not safely complete."""


class WithingsNotConfiguredError(WithingsError):
    pass


class WithingsStateError(WithingsError):
    pass


class WithingsConnectionNotFoundError(WithingsError):
    pass


class WithingsProviderError(WithingsError):
    pass


class WithingsSyncBusyError(WithingsError):
    pass


@dataclass(frozen=True)
class _MeasureTarget:
    domain: str
    metric_key: str
    unit_key: str
    minimum: float
    maximum: float
    source_name: str


MEASURE_TARGETS = {
    1: _MeasureTarget("body", "body.weight_kg", "kg", 1, 500, "Withings scale"),
    4: _MeasureTarget("body", "body.height_m", "m", 0.5, 2.5, "Withings profile"),
    5: _MeasureTarget(
        "body", "body.fat_free_mass_kg", "kg", 0, 500, "Withings scale"
    ),
    6: _MeasureTarget(
        "body", "body.body_fat_pct", "%", 0, 100, "Withings scale"
    ),
    8: _MeasureTarget(
        "body", "body.fat_mass_kg", "kg", 0, 500, "Withings scale"
    ),
    9: _MeasureTarget(
        "recovery",
        "vitals.blood_pressure_diastolic_mmhg",
        "mmHg",
        20,
        350,
        "Withings blood pressure monitor",
    ),
    10: _MeasureTarget(
        "recovery",
        "vitals.blood_pressure_systolic_mmhg",
        "mmHg",
        20,
        350,
        "Withings blood pressure monitor",
    ),
    11: _MeasureTarget(
        "recovery",
        "vitals.heart_rate_bpm",
        "bpm",
        20,
        300,
        "Withings blood pressure monitor",
    ),
    76: _MeasureTarget(
        "body", "body.muscle_mass_kg", "kg", 0, 500, "Withings scale"
    ),
    77: _MeasureTarget(
        "body", "body.hydration_kg", "kg", 0, 500, "Withings scale"
    ),
    88: _MeasureTarget(
        "body", "body.bone_mass_kg", "kg", 0, 100, "Withings scale"
    ),
}


def configured() -> bool:
    return bool(
        settings.withings_integration_enabled
        and settings.withings_client_id.strip()
        and settings.withings_client_secret.strip()
        and settings.withings_redirect_uri.strip()
        and settings.withings_webhook_secret.strip()
        and settings.ha_token_encryption_key.strip()
    )


def require_configured() -> None:
    if not configured():
        raise WithingsNotConfiguredError(
            "Withings direct import is not configured on the HausKlar server"
        )


def _utc_now(value: datetime | None = None) -> datetime:
    observed = value or datetime.now(timezone.utc)
    return observed if observed.tzinfo else observed.replace(tzinfo=timezone.utc)


def _utc_text(value: datetime) -> str:
    return _utc_now(value).isoformat()


def _parse_utc(value: str | None) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _state_digest(state: str) -> str:
    return hashlib.sha256(state.encode("utf-8")).hexdigest()


def _deterministic_id(*parts: object) -> str:
    return str(uuid.uuid5(_ID_NAMESPACE, ":".join(str(part) for part in parts)))


def _webhook_url() -> str:
    base = settings.app_base_url.strip().rstrip("/")
    token = settings.withings_webhook_secret.strip()
    return f"{base}/api/fitness/integrations/withings/webhook?{urlencode({'token': token})}"


def callback_return_url(surface: str, outcome: str) -> str:
    safe_outcome = outcome if outcome in {"connected", "cancelled", "failed"} else "failed"
    if surface == "app":
        return f"hausklar://fitness/withings?status={safe_outcome}"
    base = settings.web_app_url.strip().rstrip("/")
    return f"{base}/?{urlencode({'view': 'fitness', 'section': 'progress', 'withings': safe_outcome})}"


async def start_authorization(
    db,
    *,
    user: dict,
    return_surface: str,
    now: datetime | None = None,
) -> tuple[str, datetime]:
    """Create an expiring, one-time OAuth state bound to one HausKlar owner."""
    require_configured()
    observed_at = _utc_now(now)
    expires_at = observed_at + OAUTH_STATE_TTL
    state = secrets.token_urlsafe(40)
    identifier = str(uuid.uuid4())
    await insert_owned(
        db,
        table="health_provider_oauth_states",
        record_id=identifier,
        values={
            "provider": "withings",
            "state_digest": _state_digest(state),
            "return_surface": return_surface,
            "expires_at": _utc_text(expires_at),
            "consumed_at": None,
            "revision": 1,
        },
        user=user,
        now=_utc_text(observed_at),
        record_sync_change=False,
    )
    # Bound stale state accumulation without hard deleting audit rows.
    await db.execute(
        "UPDATE health_provider_oauth_states SET deleted_at = ?, updated_at = ?, "
        "revision = revision + 1 WHERE owner_user_id = ? AND provider = 'withings' "
        "AND consumed_at IS NULL AND expires_at < ? AND deleted_at IS NULL",
        (
            _utc_text(observed_at),
            _utc_text(observed_at),
            user["id"],
            _utc_text(observed_at),
        ),
    )
    await db.commit()
    params = {
        "response_type": "code",
        "client_id": settings.withings_client_id.strip(),
        "redirect_uri": settings.withings_redirect_uri.strip(),
        "scope": ",".join(WITHINGS_SCOPES),
        "state": state,
    }
    return f"{WITHINGS_AUTHORIZE_URL}?{urlencode(params)}", expires_at


async def _claim_oauth_state(
    db, *, state: str, now: datetime | None = None
) -> tuple[dict, str]:
    observed_at = _utc_now(now)
    row = await (
        await db.execute(
            "SELECT oauth.*, user.* FROM health_provider_oauth_states oauth "
            "JOIN users user ON user.id = oauth.owner_user_id "
            "AND user.family_id = oauth.family_id AND user.deleted_at IS NULL "
            "WHERE oauth.provider = 'withings' AND oauth.state_digest = ? "
            "AND oauth.consumed_at IS NULL AND oauth.deleted_at IS NULL LIMIT 1",
            (_state_digest(state),),
        )
    ).fetchone()
    if row is None or (_parse_utc(row["expires_at"]) or observed_at) <= observed_at:
        raise WithingsStateError("Withings authorisation state is absent or expired")
    claimed = await db.execute(
        "UPDATE health_provider_oauth_states SET consumed_at = ?, updated_at = ?, "
        "revision = revision + 1 WHERE id = ? AND consumed_at IS NULL "
        "AND deleted_at IS NULL",
        (_utc_text(observed_at), _utc_text(observed_at), row["id"]),
    )
    if claimed.rowcount != 1:
        raise WithingsStateError("Withings authorisation state was already used")
    await db.commit()
    user = {
        key: row[key]
        for key in row.keys()
        if key
        in {
            "id",
            "name",
            "email",
            "role",
            "priority",
            "family_id",
            "created_at",
            "updated_at",
            "deleted_at",
        }
    }
    # SELECT oauth.*, user.* makes duplicate `id` fields resolve to the OAuth
    # row in sqlite.Row. Restore the owner identity explicitly.
    user["id"] = row["owner_user_id"]
    user["family_id"] = row["family_id"]
    return user, row["return_surface"]


async def _withings_post(
    url: str,
    *,
    data: dict[str, object],
    access_token: str | None = None,
) -> dict:
    headers = {"Accept": "application/json"}
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.post(url, data=data, headers=headers)
    except httpx.HTTPError as exc:
        raise WithingsProviderError("Withings could not be reached") from exc
    if response.status_code != 200:
        raise WithingsProviderError("Withings returned an unexpected HTTP response")
    try:
        payload = response.json()
    except ValueError as exc:
        raise WithingsProviderError("Withings returned malformed JSON") from exc
    if not isinstance(payload, dict) or payload.get("status") != 0:
        raise WithingsProviderError("Withings rejected the request")
    body = payload.get("body")
    if not isinstance(body, dict):
        raise WithingsProviderError("Withings returned a malformed response body")
    return body


def _validated_tokens(body: dict, *, now: datetime) -> tuple[str, str, str, int, list[str]]:
    provider_user_id = str(body.get("userid") or "").strip()
    access_token = str(body.get("access_token") or "").strip()
    refresh_token = str(body.get("refresh_token") or "").strip()
    try:
        expires_in = int(body.get("expires_in") or 10_800)
    except (TypeError, ValueError) as exc:
        raise WithingsProviderError("Withings returned an invalid token lifetime") from exc
    raw_scope = body.get("scope") or ""
    scopes = sorted(
        {item.strip() for item in str(raw_scope).replace(" ", ",").split(",") if item.strip()}
    )
    if (
        not provider_user_id
        or len(provider_user_id) > 100
        or not access_token
        or len(access_token) > 2_000
        or not refresh_token
        or len(refresh_token) > 2_000
        or expires_in < 60
        or expires_in > 86_400
        or "user.metrics" not in scopes
    ):
        raise WithingsProviderError("Withings returned incomplete metric access")
    return provider_user_id, access_token, refresh_token, expires_in, scopes


def _encrypt_tokens(access_token: str, refresh_token: str) -> str:
    return encrypt_value(
        json.dumps(
            {"access_token": access_token, "refresh_token": refresh_token},
            separators=(",", ":"),
            sort_keys=True,
        )
    )


def _decrypt_tokens(connection) -> dict[str, str]:
    encrypted = connection["encrypted_token_json"]
    if not encrypted:
        raise WithingsConnectionNotFoundError("Withings connection needs authorisation")
    try:
        decoded = json.loads(decrypt_value(encrypted))
    except Exception as exc:
        raise WithingsConnectionNotFoundError("Withings connection needs authorisation") from exc
    if not isinstance(decoded, dict) or not decoded.get("access_token") or not decoded.get(
        "refresh_token"
    ):
        raise WithingsConnectionNotFoundError("Withings connection needs authorisation")
    return {"access_token": str(decoded["access_token"]), "refresh_token": str(decoded["refresh_token"])}


async def _save_connection_history(db, connection, *, user: dict) -> None:
    await save_history(
        db,
        "health_provider_connections",
        connection["id"],
        user["id"],
        family_id=user["family_id"],
        excluded_fields={"encrypted_token_json", "sync_lease_token"},
    )


async def _store_connection(
    db,
    *,
    user: dict,
    provider_user_id: str,
    access_token: str,
    refresh_token: str,
    expires_in: int,
    scopes: list[str],
    now: datetime,
) -> str:
    collision = await (
        await db.execute(
            "SELECT owner_user_id FROM health_provider_connections WHERE provider = 'withings' "
            "AND provider_user_id = ? AND owner_user_id <> ? AND status <> 'disconnected' "
            "AND deleted_at IS NULL LIMIT 1",
            (provider_user_id, user["id"]),
        )
    ).fetchone()
    if collision is not None:
        raise FitnessConflictError(
            "This Withings profile is already connected to another HausKlar account"
        )
    existing = await (
        await db.execute(
            "SELECT * FROM health_provider_connections WHERE owner_user_id = ? "
            "AND family_id = ? AND provider = 'withings' AND deleted_at IS NULL LIMIT 1",
            (user["id"], user["family_id"]),
        )
    ).fetchone()
    encrypted = _encrypt_tokens(access_token, refresh_token)
    access_expires = now + timedelta(seconds=expires_in)
    refresh_expires = now + REFRESH_TOKEN_TTL
    if existing is None:
        identifier = str(uuid.uuid4())
        await insert_owned(
            db,
            table="health_provider_connections",
            record_id=identifier,
            values={
                "provider": "withings",
                "provider_user_id": provider_user_id,
                "status": "connected",
                "scopes_json": scopes,
                "encrypted_token_json": encrypted,
                "access_token_expires_at": _utc_text(access_expires),
                "refresh_token_expires_at": _utc_text(refresh_expires),
                "last_error_code": None,
                "subscribed_categories_json": [],
                "webhook_status": "pending",
                "consecutive_sync_failures": 0,
                "revision": 1,
            },
            user=user,
            now=_utc_text(now),
            record_sync_change=False,
        )
    else:
        identifier = existing["id"]
        await _save_connection_history(db, existing, user=user)
        await db.execute(
            "UPDATE health_provider_connections SET provider_user_id = ?, status = 'connected', "
            "scopes_json = ?, encrypted_token_json = ?, access_token_expires_at = ?, "
            "refresh_token_expires_at = ?, last_error_code = NULL, webhook_status = 'pending', "
            "subscribed_categories_json = '[]', sync_lease_token = NULL, "
            "sync_lease_expires_at = NULL, next_retry_at = NULL, "
            "consecutive_sync_failures = 0, updated_at = ?, revision = revision + 1 "
            "WHERE id = ? AND owner_user_id = ? AND family_id = ? AND deleted_at IS NULL",
            (
                provider_user_id,
                json_text(scopes),
                encrypted,
                _utc_text(access_expires),
                _utc_text(refresh_expires),
                _utc_text(now),
                identifier,
                user["id"],
                user["family_id"],
            ),
        )
    await db.commit()
    return identifier


async def complete_authorization(
    db,
    *,
    state: str,
    code: str,
    now: datetime | None = None,
) -> tuple[str, str]:
    """Consume OAuth state, exchange the 30-second code, and retain encrypted tokens."""
    require_configured()
    observed_at = _utc_now(now)
    user, return_surface = await _claim_oauth_state(db, state=state, now=observed_at)
    body = await _withings_post(
        WITHINGS_TOKEN_URL,
        data={
            "action": "requesttoken",
            "client_id": settings.withings_client_id.strip(),
            "client_secret": settings.withings_client_secret.strip(),
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": settings.withings_redirect_uri.strip(),
        },
    )
    provider_user_id, access, refresh, expires_in, scopes = _validated_tokens(
        body, now=observed_at
    )
    identifier = await _store_connection(
        db,
        user=user,
        provider_user_id=provider_user_id,
        access_token=access,
        refresh_token=refresh,
        expires_in=expires_in,
        scopes=scopes,
        now=observed_at,
    )
    return identifier, return_surface


async def consume_cancelled_authorization(
    db, *, state: str, now: datetime | None = None
) -> str:
    _, return_surface = await _claim_oauth_state(db, state=state, now=now)
    return return_surface


async def _owned_connection(db, *, user: dict, connection_id: str | None = None):
    clauses = [
        "owner_user_id = ?",
        "family_id = ?",
        "provider = 'withings'",
        "deleted_at IS NULL",
    ]
    params: list[object] = [user["id"], user["family_id"]]
    if connection_id:
        clauses.append("id = ?")
        params.append(connection_id)
    row = await (
        await db.execute(
            f"SELECT * FROM health_provider_connections WHERE {' AND '.join(clauses)} LIMIT 1",
            params,
        )
    ).fetchone()
    if row is None:
        raise WithingsConnectionNotFoundError("Withings is not connected")
    return row


async def connection_status(db, *, user: dict) -> dict:
    if not configured():
        return {
            "configured": False,
            "connected": False,
            "status": "not_configured",
            "subscribed_categories": [],
            "imported_measurement_count": 0,
        }
    try:
        connection = await _owned_connection(db, user=user)
    except WithingsConnectionNotFoundError:
        return {
            "configured": True,
            "connected": False,
            "status": "not_connected",
            "subscribed_categories": [],
            "imported_measurement_count": 0,
        }
    count = await (
        await db.execute(
            "SELECT COUNT(*) FROM health_source_records WHERE family_id = ? "
            "AND owner_user_id = ? AND origin_provider_key = 'withings' "
            "AND transport_key = 'withings_api' AND state = 'active' AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    try:
        categories = json.loads(connection["subscribed_categories_json"] or "[]")
    except (TypeError, json.JSONDecodeError):
        categories = []
    status = connection["status"]
    return {
        "configured": True,
        "connected": status == "connected",
        "status": status,
        "last_sync_at": connection["last_sync_at"],
        "data_through_at": connection["data_through_at"],
        "last_error_code": connection["last_error_code"],
        "webhook_status": connection["webhook_status"],
        "subscribed_categories": [int(value) for value in categories if isinstance(value, int)],
        "imported_measurement_count": int(count[0] if count else 0),
    }


async def _claim_sync_lease(
    db, *, user: dict, connection_id: str, now: datetime
):
    lease_token = secrets.token_urlsafe(24)
    lease_expires = now + SYNC_LEASE_TTL
    claimed = await db.execute(
        "UPDATE health_provider_connections SET sync_lease_token = ?, "
        "sync_lease_expires_at = ?, updated_at = ? WHERE id = ? AND owner_user_id = ? "
        "AND family_id = ? AND provider = 'withings' AND status IN "
        "('connected','provider_down') AND (sync_lease_expires_at IS NULL "
        "OR sync_lease_expires_at <= ?) AND deleted_at IS NULL",
        (
            lease_token,
            _utc_text(lease_expires),
            _utc_text(now),
            connection_id,
            user["id"],
            user["family_id"],
            _utc_text(now),
        ),
    )
    if claimed.rowcount != 1:
        raise WithingsSyncBusyError("Withings sync is already running")
    await db.commit()
    return lease_token


async def _refresh_access_token(
    db, *, connection, user: dict, now: datetime
) -> tuple[str, object]:
    tokens = _decrypt_tokens(connection)
    access_expiry = _parse_utc(connection["access_token_expires_at"])
    if access_expiry and access_expiry > now + ACCESS_TOKEN_REFRESH_SKEW:
        return tokens["access_token"], connection
    body = await _withings_post(
        WITHINGS_TOKEN_URL,
        data={
            "action": "requesttoken",
            "client_id": settings.withings_client_id.strip(),
            "client_secret": settings.withings_client_secret.strip(),
            "grant_type": "refresh_token",
            "refresh_token": tokens["refresh_token"],
        },
    )
    provider_user_id, access, refresh, expires_in, scopes = _validated_tokens(body, now=now)
    if provider_user_id != connection["provider_user_id"]:
        raise WithingsProviderError("Withings returned a different account during refresh")
    await _save_connection_history(db, connection, user=user)
    await db.execute(
        "UPDATE health_provider_connections SET encrypted_token_json = ?, scopes_json = ?, "
        "access_token_expires_at = ?, refresh_token_expires_at = ?, status = 'connected', "
        "last_error_code = NULL, updated_at = ?, revision = revision + 1 "
        "WHERE id = ? AND owner_user_id = ? AND family_id = ? AND deleted_at IS NULL",
        (
            _encrypt_tokens(access, refresh),
            json_text(scopes),
            _utc_text(now + timedelta(seconds=expires_in)),
            _utc_text(now + REFRESH_TOKEN_TTL),
            _utc_text(now),
            connection["id"],
            user["id"],
            user["family_id"],
        ),
    )
    await db.commit()
    refreshed = await _owned_connection(db, user=user, connection_id=connection["id"])
    return access, refreshed


async def _fetch_measure_groups(
    *,
    access_token: str,
    last_update: int | None,
    start_at: int | None,
    end_at: int | None,
    measure_types: tuple[int, ...] = WITHINGS_MEASURE_TYPES,
) -> tuple[list[dict], int | None, str | None]:
    offset: int | None = None
    groups: list[dict] = []
    latest_update: int | None = None
    reported_timezone: str | None = None
    for _ in range(MAX_MEASURE_PAGES):
        data: dict[str, object] = {
            "action": "getmeas",
            "meastypes": ",".join(str(value) for value in measure_types),
        }
        if last_update is not None:
            data["lastupdate"] = last_update
        else:
            data["startdate"] = max(0, int(start_at or 0))
            data["enddate"] = max(int(start_at or 0), int(end_at or datetime.now(timezone.utc).timestamp()))
        if offset is not None:
            data["offset"] = offset
        body = await _withings_post(
            WITHINGS_MEASURE_URL, data=data, access_token=access_token
        )
        page = body.get("measuregrps") or []
        if not isinstance(page, list) or any(not isinstance(item, dict) for item in page):
            raise WithingsProviderError("Withings returned malformed measurements")
        groups.extend(page)
        if len(groups) > MAX_MEASURE_GROUPS:
            raise WithingsProviderError("Withings returned too many measurements at once")
        try:
            update_value = int(body.get("updatetime"))
        except (TypeError, ValueError):
            update_value = None
        if update_value is not None:
            latest_update = max(latest_update or update_value, update_value)
        timezone_value = body.get("timezone")
        if isinstance(timezone_value, str) and 0 < len(timezone_value) <= 100:
            reported_timezone = timezone_value
        if body.get("more") not in {1, True, "1"}:
            return groups, latest_update, reported_timezone
        try:
            next_offset = int(body.get("offset"))
        except (TypeError, ValueError) as exc:
            raise WithingsProviderError("Withings pagination was incomplete") from exc
        if offset == next_offset:
            raise WithingsProviderError("Withings pagination did not advance")
        offset = next_offset
    raise WithingsProviderError("Withings returned too many measurement pages")


def _decoded_measure_value(measure: dict, target: _MeasureTarget) -> float | None:
    try:
        raw = float(measure["value"])
        power = int(measure["unit"])
        value = raw * (10**power)
    except (KeyError, TypeError, ValueError, OverflowError):
        return None
    if not math.isfinite(value) or value < target.minimum or value > target.maximum:
        return None
    return value


def _group_timestamp(group: dict, *, now: datetime) -> datetime | None:
    try:
        timestamp = int(group.get("date"))
        measured = datetime.fromtimestamp(timestamp, tz=timezone.utc)
    except (TypeError, ValueError, OSError, OverflowError):
        return None
    if measured < datetime(1970, 1, 2, tzinfo=timezone.utc) or measured > now + timedelta(days=1):
        return None
    return measured


async def _upsert_source(
    db,
    *,
    user: dict,
    connection,
    group: dict,
    measure_type: int,
    target: _MeasureTarget,
    entity_id: str,
    measured_at: datetime,
) -> tuple[str, bool]:
    provider_user_id = connection["provider_user_id"]
    group_id = str(group.get("grpid") or "").strip()
    source_object_id = f"{provider_user_id}:{group_id}:{measure_type}"
    source_id = _deterministic_id("withings-source", source_object_id)
    device_id = str(group.get("deviceid") or group.get("hash_deviceid") or "").strip() or None
    metadata = {
        "measure_type": measure_type,
        "category": group.get("category"),
        "attrib": group.get("attrib"),
        "modified": group.get("modified"),
    }
    metadata = {key: value for key, value in metadata.items() if value is not None}
    source_created = group.get("created")
    try:
        source_created_at = datetime.fromtimestamp(int(source_created), tz=timezone.utc).isoformat()
    except (TypeError, ValueError, OSError, OverflowError):
        source_created_at = measured_at.isoformat()
    values = {
        "record_kind": "body_measurement" if target.domain == "body" else "recovery_metric",
        "sample_type": str(measure_type),
        "transport_key": "withings_api",
        "origin_provider_key": "withings",
        "source_namespace": "withings",
        "source_object_id": source_object_id,
        "external_object_id": group_id,
        "source_device_identifier": device_id,
        "source_name": target.source_name,
        "product_type": None,
        "device_json": {},
        "metadata_json": metadata,
        "domain_entity_type": "body_measurement"
        if target.domain == "body"
        else "recovery_observation",
        "domain_entity_id": entity_id,
        "source_created_at_utc": source_created_at,
        "raw_asset_id": None,
        "file_fingerprint": None,
        "state": "active",
        "raw_metadata_json": metadata,
        "parser_name": "withings_api",
        "parser_version": "1",
    }
    existing = await (
        await db.execute(
            "SELECT * FROM health_source_records WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? LIMIT 1",
            (source_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_source_records",
            record_id=source_id,
            values={**values, "revision": 1},
            user=user,
        )
        return source_id, True
    comparable = {
        key: json_text(value) if isinstance(value, dict) else value for key, value in values.items()
    }
    if all(existing[key] == value for key, value in comparable.items()) and existing["deleted_at"] is None:
        return source_id, False
    await update_owned(
        db,
        table="health_source_records",
        record_id=source_id,
        values=values,
        user=user,
        restore=True,
    )
    return source_id, True


async def _upsert_body_measurement(
    db,
    *,
    user: dict,
    target: _MeasureTarget,
    entity_id: str,
    source_id: str,
    measured_at: datetime,
    timezone_name: str,
    value: float,
) -> str:
    existing = await (
        await db.execute(
            "SELECT * FROM health_body_measurements WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? LIMIT 1",
            (entity_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None and all(
        (
            existing["metric_key"] == target.metric_key,
            existing["measured_at_utc"] == measured_at.isoformat(),
            math.isclose(float(existing["value"]), value, abs_tol=1e-9),
            existing["unit_key"] == target.unit_key,
            existing["source_record_id"] == source_id,
            existing["deleted_at"] is None,
        )
    ):
        return "unchanged"
    body = BodyMeasurementPayload(
        id=uuid.UUID(entity_id),
        metric_key=target.metric_key,
        measured_at_utc=measured_at,
        local_timezone=timezone_name,
        value=value,
        unit_key=target.unit_key,
        source_record_id=uuid.UUID(source_id),
        measurement_quality="measured",
        canonical_state="canonical",
    )
    await nutrition.upsert_body_measurement(
        db, user=user, body=body, record_id=entity_id
    )
    return "updated" if existing is not None else "imported"


async def _upsert_recovery_measurement(
    db,
    *,
    user: dict,
    target: _MeasureTarget,
    entity_id: str,
    source_id: str,
    measured_at: datetime,
    value: float,
) -> str:
    existing = await (
        await db.execute(
            "SELECT * FROM health_recovery_observations WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? LIMIT 1",
            (entity_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None and all(
        (
            existing["metric_key"] == target.metric_key,
            existing["observed_at_utc"] == measured_at.isoformat(),
            existing["value_number"] is not None
            and math.isclose(float(existing["value_number"]), value, abs_tol=1e-9),
            existing["unit_key"] == target.unit_key,
            existing["source_record_id"] == source_id,
            existing["deleted_at"] is None,
        )
    ):
        return "unchanged"
    body = RecoveryObservationPayload(
        id=uuid.UUID(entity_id),
        metric_key=target.metric_key,
        observed_at_utc=measured_at,
        value_number=value,
        unit_key=target.unit_key,
        source_quality="wearable",
        source_record_id=uuid.UUID(source_id),
    )
    await recovery.upsert_recovery_observation(
        db, user=user, body=body, record_id=entity_id
    )
    return "updated" if existing is not None else "imported"


async def _import_groups(
    db,
    *,
    user: dict,
    connection,
    groups: list[dict],
    reported_timezone: str | None,
    now: datetime,
) -> dict[str, int]:
    counts = {"imported": 0, "updated": 0, "unchanged": 0, "ignored": 0}
    timezone_name = reported_timezone or "UTC"
    for group in groups:
        # Withings category 2 represents a user objective rather than a measured sample.
        if group.get("category") not in {None, 1, "1"}:
            counts["ignored"] += 1
            continue
        measured_at = _group_timestamp(group, now=now)
        group_id = str(group.get("grpid") or "").strip()
        measures = group.get("measures")
        if not measured_at or not group_id or not isinstance(measures, list):
            counts["ignored"] += 1
            continue
        for measure in measures:
            if not isinstance(measure, dict):
                counts["ignored"] += 1
                continue
            try:
                measure_type = int(measure.get("type"))
            except (TypeError, ValueError):
                counts["ignored"] += 1
                continue
            target = MEASURE_TARGETS.get(measure_type)
            if target is None:
                counts["ignored"] += 1
                continue
            value = _decoded_measure_value(measure, target)
            if value is None:
                counts["ignored"] += 1
                continue
            entity_id = _deterministic_id(
                "withings-measurement",
                connection["provider_user_id"],
                group_id,
                measure_type,
            )
            source_id, source_changed = await _upsert_source(
                db,
                user=user,
                connection=connection,
                group=group,
                measure_type=measure_type,
                target=target,
                entity_id=entity_id,
                measured_at=measured_at,
            )
            if target.domain == "body":
                outcome = await _upsert_body_measurement(
                    db,
                    user=user,
                    target=target,
                    entity_id=entity_id,
                    source_id=source_id,
                    measured_at=measured_at,
                    timezone_name=timezone_name,
                    value=value,
                )
            else:
                outcome = await _upsert_recovery_measurement(
                    db,
                    user=user,
                    target=target,
                    entity_id=entity_id,
                    source_id=source_id,
                    measured_at=measured_at,
                    value=value,
                )
            if outcome == "unchanged" and source_changed:
                outcome = "updated"
            counts[outcome] += 1
    return counts


def _retry_at(now: datetime, failures: int) -> datetime:
    delay_minutes = min(360, 5 * (2 ** min(max(failures - 1, 0), 6)))
    return now + timedelta(minutes=delay_minutes)


async def sync_connection(
    db,
    *,
    user: dict,
    connection_id: str | None = None,
    start_at: int | None = None,
    end_at: int | None = None,
    now: datetime | None = None,
) -> dict:
    """Refresh one owner connection with a lease and rotating token handling."""
    require_configured()
    observed_at = _utc_now(now)
    connection = await _owned_connection(db, user=user, connection_id=connection_id)
    if connection["status"] not in {"connected", "provider_down"}:
        raise WithingsConnectionNotFoundError("Withings connection needs authorisation")
    lease_token = await _claim_sync_lease(
        db, user=user, connection_id=connection["id"], now=observed_at
    )
    try:
        connection = await _owned_connection(db, user=user, connection_id=connection["id"])
        access_token, connection = await _refresh_access_token(
            db, connection=connection, user=user, now=observed_at
        )
        last_update: int | None = None
        if start_at is None and end_at is None:
            through = _parse_utc(connection["data_through_at"])
            if through is not None:
                last_update = max(0, int(through.timestamp()) - 300)
            else:
                start_at = int((observed_at - timedelta(days=30)).timestamp())
                end_at = int(observed_at.timestamp())
        groups, updatetime, reported_timezone = await _fetch_measure_groups(
            access_token=access_token,
            last_update=last_update,
            start_at=start_at,
            end_at=end_at,
        )
        counts = await _import_groups(
            db,
            user=user,
            connection=connection,
            groups=groups,
            reported_timezone=reported_timezone,
            now=observed_at,
        )
        has_height = await (
            await db.execute(
                "SELECT 1 FROM health_body_measurements WHERE family_id = ? "
                "AND owner_user_id = ? AND metric_key IN ('body.height_cm','body.height_m') "
                "AND canonical_state NOT IN ('excluded','duplicate') AND deleted_at IS NULL LIMIT 1",
                (user["family_id"], user["id"]),
            )
        ).fetchone()
        if has_height is None:
            height_groups, _, height_timezone = await _fetch_measure_groups(
                access_token=access_token,
                last_update=None,
                start_at=0,
                end_at=int(observed_at.timestamp()),
                measure_types=(4,),
            )
            height_counts = await _import_groups(
                db,
                user=user,
                connection=connection,
                groups=height_groups,
                reported_timezone=height_timezone or reported_timezone,
                now=observed_at,
            )
            for key, value in height_counts.items():
                counts[key] += value
        data_through = (
            datetime.fromtimestamp(updatetime, tz=timezone.utc)
            if updatetime is not None
            else observed_at
        )
        current = await _owned_connection(db, user=user, connection_id=connection["id"])
        await _save_connection_history(db, current, user=user)
        await db.execute(
            "UPDATE health_provider_connections SET status = 'connected', last_sync_at = ?, "
            "data_through_at = ?, last_error_code = NULL, sync_lease_token = NULL, "
            "sync_lease_expires_at = NULL, next_retry_at = NULL, "
            "consecutive_sync_failures = 0, updated_at = ?, revision = revision + 1 "
            "WHERE id = ? AND owner_user_id = ? AND family_id = ? AND sync_lease_token = ? "
            "AND deleted_at IS NULL",
            (
                _utc_text(observed_at),
                _utc_text(data_through),
                _utc_text(observed_at),
                connection["id"],
                user["id"],
                user["family_id"],
                lease_token,
            ),
        )
        await db.commit()
        return {**counts, "data_through_at": data_through}
    except Exception as exc:
        if db.in_transaction:
            await db.rollback()
        connection = await _owned_connection(db, user=user, connection_id=connection["id"])
        failures = int(connection["consecutive_sync_failures"] or 0) + 1
        error_code = (
            "TOKEN_REFRESH_FAILED"
            if isinstance(exc, WithingsConnectionNotFoundError)
            else "PROVIDER_SYNC_FAILED"
        )
        status = "reauth_required" if error_code == "TOKEN_REFRESH_FAILED" else "provider_down"
        await _save_connection_history(db, connection, user=user)
        await db.execute(
            "UPDATE health_provider_connections SET status = ?, last_error_code = ?, "
            "sync_lease_token = NULL, sync_lease_expires_at = NULL, next_retry_at = ?, "
            "consecutive_sync_failures = ?, updated_at = ?, revision = revision + 1 "
            "WHERE id = ? AND owner_user_id = ? AND family_id = ? AND deleted_at IS NULL",
            (
                status,
                error_code,
                _utc_text(_retry_at(observed_at, failures)),
                failures,
                _utc_text(observed_at),
                connection["id"],
                user["id"],
                user["family_id"],
            ),
        )
        await db.commit()
        raise


async def subscribe_notifications(
    db, *, user: dict, connection_id: str, now: datetime | None = None
) -> list[int]:
    observed_at = _utc_now(now)
    connection = await _owned_connection(db, user=user, connection_id=connection_id)
    access_token, connection = await _refresh_access_token(
        db, connection=connection, user=user, now=observed_at
    )
    subscribed: list[int] = []
    try:
        for category in WITHINGS_NOTIFICATION_CATEGORIES:
            await _withings_post(
                WITHINGS_NOTIFY_URL,
                access_token=access_token,
                data={
                    "action": "subscribe",
                    "callbackurl": _webhook_url(),
                    "appli": category,
                    "comment": "HausKlar direct health import",
                },
            )
            subscribed.append(category)
    except Exception:
        current = await _owned_connection(db, user=user, connection_id=connection_id)
        await _save_connection_history(db, current, user=user)
        await db.execute(
            "UPDATE health_provider_connections SET webhook_status = 'error', "
            "last_error_code = 'WEBHOOK_SUBSCRIBE_FAILED', updated_at = ?, "
            "revision = revision + 1 WHERE id = ? AND owner_user_id = ? "
            "AND family_id = ? AND deleted_at IS NULL",
            (_utc_text(observed_at), connection_id, user["id"], user["family_id"]),
        )
        await db.commit()
        raise
    current = await _owned_connection(db, user=user, connection_id=connection_id)
    await _save_connection_history(db, current, user=user)
    await db.execute(
        "UPDATE health_provider_connections SET webhook_status = 'active', "
        "subscribed_categories_json = ?, last_error_code = NULL, updated_at = ?, "
        "revision = revision + 1 WHERE id = ? AND owner_user_id = ? AND family_id = ? "
        "AND deleted_at IS NULL",
        (
            json_text(subscribed),
            _utc_text(observed_at),
            connection_id,
            user["id"],
            user["family_id"],
        ),
    )
    await db.commit()
    return subscribed


async def finish_connection_setup(connection_id: str) -> None:
    """Background initial subscription and historical import after OAuth redirect."""
    try:
        async with standalone_db() as db:
            row = await (
                await db.execute(
                    "SELECT connection.*, user.* FROM health_provider_connections connection "
                    "JOIN users user ON user.id = connection.owner_user_id "
                    "AND user.family_id = connection.family_id AND user.deleted_at IS NULL "
                    "WHERE connection.id = ? AND connection.deleted_at IS NULL LIMIT 1",
                    (connection_id,),
                )
            ).fetchone()
            if row is None:
                return
            user = dict(row)
            user["id"] = row["owner_user_id"]
            user["family_id"] = row["family_id"]
            try:
                await subscribe_notifications(
                    db, user=user, connection_id=connection_id
                )
            except Exception:
                # Scheduled pulls remain active when a webhook subscription is unavailable.
                pass
            try:
                await sync_connection(
                    db,
                    user=user,
                    connection_id=connection_id,
                    start_at=0,
                    end_at=int(datetime.now(timezone.utc).timestamp()),
                )
            except Exception:
                pass
    except Exception:
        # Provider and account details are private; durable status is owner-visible.
        return


async def disconnect(
    db, *, user: dict, now: datetime | None = None
) -> int:
    observed_at = _utc_now(now)
    connection = await _owned_connection(db, user=user)
    try:
        access, _ = await _refresh_access_token(
            db, connection=connection, user=user, now=observed_at
        )
        for category in WITHINGS_NOTIFICATION_CATEGORIES:
            try:
                await _withings_post(
                    WITHINGS_NOTIFY_URL,
                    access_token=access,
                    data={
                        "action": "revoke",
                        "callbackurl": _webhook_url(),
                        "appli": category,
                    },
                )
            except Exception:
                pass
    except Exception:
        pass
    connection = await _owned_connection(db, user=user, connection_id=connection["id"])
    await _save_connection_history(db, connection, user=user)
    await db.execute(
        "UPDATE health_provider_connections SET status = 'disconnected', "
        "encrypted_token_json = NULL, access_token_expires_at = NULL, "
        "refresh_token_expires_at = NULL, webhook_status = 'disabled', "
        "subscribed_categories_json = '[]', sync_lease_token = NULL, "
        "sync_lease_expires_at = NULL, next_retry_at = NULL, updated_at = ?, "
        "revision = revision + 1 WHERE id = ? AND owner_user_id = ? AND family_id = ? "
        "AND deleted_at IS NULL",
        (
            _utc_text(observed_at),
            connection["id"],
            user["id"],
            user["family_id"],
        ),
    )
    count = await (
        await db.execute(
            "SELECT COUNT(*) FROM health_source_records WHERE family_id = ? "
            "AND owner_user_id = ? AND origin_provider_key = 'withings' "
            "AND transport_key = 'withings_api' AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    await db.commit()
    return int(count[0] if count else 0)


async def enqueue_notification(
    db,
    *,
    provider_user_id: str,
    category: int,
    start_at: int,
    end_at: int,
    now: datetime | None = None,
) -> str | None:
    observed_at = _utc_now(now)
    if category not in WITHINGS_NOTIFICATION_CATEGORIES:
        return None
    connection = await (
        await db.execute(
            "SELECT * FROM health_provider_connections WHERE provider = 'withings' "
            "AND provider_user_id = ? AND status IN ('connected','provider_down') "
            "AND deleted_at IS NULL LIMIT 1",
            (provider_user_id,),
        )
    ).fetchone()
    if connection is None:
        return None
    user_row = await (
        await db.execute(
            "SELECT * FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (connection["owner_user_id"], connection["family_id"]),
        )
    ).fetchone()
    if user_row is None:
        return None
    await reserve_persistent_attempts(
        db,
        [
            (
                "withings:webhook:global",
                settings.withings_webhook_global_rate_limit_requests,
                settings.withings_webhook_rate_limit_window_seconds,
            ),
            (
                f"withings:webhook:connection:{connection['id']}",
                settings.withings_webhook_connection_rate_limit_requests,
                settings.withings_webhook_rate_limit_window_seconds,
            ),
        ],
        detail_prefix="Too many Withings notifications",
    )
    # One canonical wake-up per connection/category. Provider ranges are kept
    # only as bounded audit context; retrieval uses the connection watermark.
    event_key = hashlib.sha256(
        f"{connection['id']}:{category}:wake".encode("utf-8")
    ).hexdigest()
    await db.execute("BEGIN IMMEDIATE")
    existing = await (
        await db.execute(
            "SELECT * FROM health_provider_notifications WHERE connection_id = ? "
            "AND event_key = ? AND deleted_at IS NULL LIMIT 1",
            (connection["id"], event_key),
        )
    ).fetchone()
    if existing is not None:
        processing = existing["status"] == "processing"
        await db.execute(
            "UPDATE health_provider_notifications SET start_at_unix = ?, end_at_unix = ?, "
            "status = ?, attempt_count = ?, next_retry_at = NULL, last_error_code = ?, "
            "processed_at = NULL, "
            "updated_at = ?, revision = revision + 1 WHERE id = ? AND deleted_at IS NULL",
            (
                min(int(existing["start_at_unix"]), start_at),
                max(int(existing["end_at_unix"]), end_at),
                "processing" if processing else "pending",
                int(existing["attempt_count"]) if processing else 0,
                "DIRTY" if processing else None,
                _utc_text(observed_at),
                existing["id"],
            ),
        )
        await db.commit()
        return existing["id"]
    identifier = str(uuid.uuid4())
    await insert_owned(
        db,
        table="health_provider_notifications",
        record_id=identifier,
        values={
            "connection_id": connection["id"],
            "provider": "withings",
            "provider_user_id": provider_user_id,
            "event_key": event_key,
            "category": category,
            "start_at_unix": start_at,
            "end_at_unix": end_at,
            "status": "pending",
            "attempt_count": 0,
            "revision": 1,
        },
        user=dict(user_row),
        now=_utc_text(observed_at),
        record_sync_change=False,
    )
    await db.commit()
    return identifier


async def process_notification(notification_id: str) -> None:
    try:
        async with standalone_db() as db:
            notification = await (
                await db.execute(
                    "SELECT * FROM health_provider_notifications WHERE id = ? "
                    "AND deleted_at IS NULL LIMIT 1",
                    (notification_id,),
                )
            ).fetchone()
            if notification is None or notification["status"] == "complete":
                return
            user_row = await (
                await db.execute(
                    "SELECT * FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                    (notification["owner_user_id"], notification["family_id"]),
                )
            ).fetchone()
            if user_row is None:
                return
            now = datetime.now(timezone.utc)
            claimed = await db.execute(
                "UPDATE health_provider_notifications SET status = 'processing', "
                "attempt_count = attempt_count + 1, last_error_code = NULL, updated_at = ?, "
                "revision = revision + 1 "
                "WHERE id = ? AND status IN ('pending','error') AND deleted_at IS NULL",
                (_utc_text(now), notification_id),
            )
            if claimed.rowcount != 1:
                return
            await db.commit()
            claimed_notification = await (
                await db.execute(
                    "SELECT * FROM health_provider_notifications WHERE id = ? "
                    "AND status = 'processing' AND deleted_at IS NULL",
                    (notification_id,),
                )
            ).fetchone()
            if claimed_notification is None:
                return
            claimed_revision = int(claimed_notification["revision"])
            try:
                await sync_connection(
                    db,
                    user=dict(user_row),
                    connection_id=notification["connection_id"],
                    now=now,
                )
                current = await (
                    await db.execute(
                        "SELECT status, revision, last_error_code "
                        "FROM health_provider_notifications WHERE id = ? "
                        "AND deleted_at IS NULL",
                        (notification_id,),
                    )
                ).fetchone()
                if (
                    current is not None
                    and current["status"] == "processing"
                    and int(current["revision"]) == claimed_revision
                ):
                    await db.execute(
                        "UPDATE health_provider_notifications SET status = 'complete', "
                        "processed_at = ?, next_retry_at = NULL, last_error_code = NULL, "
                        "updated_at = ?, revision = revision + 1 WHERE id = ? "
                        "AND revision = ? AND status = 'processing' AND deleted_at IS NULL",
                        (
                            _utc_text(now),
                            _utc_text(now),
                            notification_id,
                            claimed_revision,
                        ),
                    )
                elif current is not None and current["last_error_code"] == "DIRTY":
                    await db.execute(
                        "UPDATE health_provider_notifications SET status = 'pending', "
                        "attempt_count = 0, processed_at = NULL, next_retry_at = NULL, "
                        "last_error_code = NULL, updated_at = ?, revision = revision + 1 "
                        "WHERE id = ? AND status = 'processing' AND last_error_code = 'DIRTY' "
                        "AND deleted_at IS NULL",
                        (_utc_text(now), notification_id),
                    )
            except Exception:
                refreshed = await (
                    await db.execute(
                        "SELECT attempt_count FROM health_provider_notifications WHERE id = ?",
                        (notification_id,),
                    )
                ).fetchone()
                attempts = int(refreshed["attempt_count"] if refreshed else 1)
                await db.execute(
                    "UPDATE health_provider_notifications SET status = 'error', "
                    "next_retry_at = ?, last_error_code = 'SYNC_FAILED', updated_at = ?, "
                    "revision = revision + 1 WHERE id = ? AND deleted_at IS NULL",
                    (
                        _utc_text(_retry_at(now, attempts)),
                        _utc_text(now),
                        notification_id,
                    ),
                )
            await db.commit()
    except Exception:
        return


async def process_pending_notifications() -> int:
    if not configured():
        return 0
    now = datetime.now(timezone.utc)
    async with standalone_db() as db:
        rows = await (
            await db.execute(
                "SELECT id FROM health_provider_notifications WHERE status IN ('pending','error') "
                "AND (next_retry_at IS NULL OR next_retry_at <= ?) AND attempt_count < 12 "
                "AND deleted_at IS NULL ORDER BY created_at LIMIT 50",
                (_utc_text(now),),
            )
        ).fetchall()
    for row in rows:
        await process_notification(row["id"])
    return len(rows)


async def sync_due_connections() -> int:
    if not configured():
        return 0
    now = datetime.now(timezone.utc)
    completed = 0
    async with standalone_db() as db:
        rows = await (
            await db.execute(
                "SELECT connection.id, connection.owner_user_id, connection.family_id "
                "FROM health_provider_connections connection JOIN users user "
                "ON user.id = connection.owner_user_id AND user.family_id = connection.family_id "
                "AND user.deleted_at IS NULL WHERE connection.provider = 'withings' "
                "AND connection.status IN ('connected','provider_down') "
                "AND (connection.next_retry_at IS NULL OR connection.next_retry_at <= ?) "
                "AND (connection.sync_lease_expires_at IS NULL OR connection.sync_lease_expires_at <= ?) "
                "AND connection.deleted_at IS NULL ORDER BY connection.last_sync_at, connection.id",
                (_utc_text(now), _utc_text(now)),
            )
        ).fetchall()
        for connection in rows:
            user = await (
                await db.execute(
                    "SELECT * FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                    (connection["owner_user_id"], connection["family_id"]),
                )
            ).fetchone()
            if user is None:
                continue
            try:
                await sync_connection(
                    db,
                    user=dict(user),
                    connection_id=connection["id"],
                    now=now,
                )
            except Exception:
                continue
            completed += 1
    return completed


def _daily_exponential_trend(points: list[dict]) -> dict[str, float]:
    """Return a stable, time-aware daily smoothed trend."""
    by_day: dict[date, list[float]] = defaultdict(list)
    for point in points:
        by_day[point["measured_at"].date()].append(point["value"])
    trend_by_day: dict[date, float] = {}
    trend: float | None = None
    previous_day: date | None = None
    for day in sorted(by_day):
        daily_value = sum(by_day[day]) / len(by_day[day])
        if trend is None or previous_day is None:
            trend = daily_value
        else:
            elapsed_days = max(1, (day - previous_day).days)
            alpha = 1 - (0.5 ** (elapsed_days / TREND_HALF_LIFE_DAYS))
            trend += alpha * (daily_value - trend)
        trend_by_day[day] = trend
        previous_day = day
    return {point["id"]: trend_by_day[point["measured_at"].date()] for point in points}


HISTORY_REGISTRY = {
    "weight": {
        "title": "Weight",
        "unit": "kg",
        "series": (("body.weight_kg", "weight", "Weight", "body"),),
    },
    "body_fat": {
        "title": "Body fat",
        "unit": "%",
        "series": (("body.body_fat_pct", "body_fat", "Body fat", "body"),),
    },
    "blood_pressure": {
        "title": "Blood pressure",
        "unit": "mmHg",
        "series": (
            (
                "vitals.blood_pressure_systolic_mmhg",
                "systolic",
                "Systolic",
                "recovery",
            ),
            (
                "vitals.blood_pressure_diastolic_mmhg",
                "diastolic",
                "Diastolic",
                "recovery",
            ),
        ),
    },
}


async def measurement_history(
    db,
    *,
    user: dict,
    metric: str,
    start_on: date | None,
    end_on: date | None,
) -> dict:
    definition = HISTORY_REGISTRY[metric]
    output_series = []
    sample_count = 0
    last_updated: datetime | None = None
    for metric_key, series_key, label, domain in definition["series"]:
        if domain == "body":
            rows = await (
                await db.execute(
                    "SELECT m.id, m.measured_at_utc AS measured_at, m.value, m.updated_at, "
                    "s.source_name, s.origin_provider_key FROM health_body_measurements m "
                    "LEFT JOIN health_source_records s ON s.id = m.source_record_id "
                    "AND s.family_id = m.family_id AND s.owner_user_id = m.owner_user_id "
                    "WHERE m.family_id = ? AND m.owner_user_id = ? AND m.metric_key = ? "
                    "AND m.canonical_state = 'canonical' AND m.deleted_at IS NULL "
                    "ORDER BY m.measured_at_utc, m.id LIMIT 20000",
                    (user["family_id"], user["id"], metric_key),
                )
            ).fetchall()
        else:
            rows = await (
                await db.execute(
                    "SELECT o.id, o.observed_at_utc AS measured_at, o.value_number AS value, "
                    "o.updated_at, s.source_name, s.origin_provider_key "
                    "FROM health_recovery_observations o LEFT JOIN health_source_records s "
                    "ON s.id = o.source_record_id AND s.family_id = o.family_id "
                    "AND s.owner_user_id = o.owner_user_id WHERE o.family_id = ? "
                    "AND o.owner_user_id = ? AND o.metric_key = ? AND o.value_number IS NOT NULL "
                    "AND o.deleted_at IS NULL ORDER BY o.observed_at_utc, o.id LIMIT 20000",
                    (user["family_id"], user["id"], metric_key),
                )
            ).fetchall()
        all_points: list[dict] = []
        for row in rows:
            measured_at = _parse_utc(row["measured_at"])
            if measured_at is None:
                continue
            value = float(row["value"])
            if not math.isfinite(value):
                continue
            updated_at = _parse_utc(row["updated_at"])
            if updated_at and (last_updated is None or updated_at > last_updated):
                last_updated = updated_at
            all_points.append(
                {
                    "id": row["id"],
                    "measured_at": measured_at,
                    "value": value,
                    "source_label": row["source_name"]
                    or (str(row["origin_provider_key"]).title() if row["origin_provider_key"] else "Manual"),
                }
            )
        trend_values = _daily_exponential_trend(all_points)
        selected = [
            point
            for point in all_points
            if (start_on is None or point["measured_at"].date() >= start_on)
            and (end_on is None or point["measured_at"].date() <= end_on)
        ]
        points = [
            {
                "id": point["id"],
                "measured_at_utc": point["measured_at"],
                "raw_value": point["value"],
                "trend_value": trend_values[point["id"]],
                "source_label": point["source_label"],
            }
            for point in selected
        ]
        sample_count += len(points)
        output_series.append(
            {
                "key": series_key,
                "label": label,
                "unit": definition["unit"],
                "points": points,
            }
        )
    return {
        "metric": metric,
        "title": definition["title"],
        "unit": definition["unit"],
        "smoothing_method": "time_weighted_exponential",
        "smoothing_half_life_days": TREND_HALF_LIFE_DAYS,
        "series": output_series,
        "sample_count": sample_count,
        "last_updated_at": last_updated,
    }
