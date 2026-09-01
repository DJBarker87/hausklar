"""Owner-private Intervals.icu connection and running-workout delivery."""

from __future__ import annotations

import hashlib
import gzip
import io
import json
import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlencode
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx
from starlette.datastructures import Headers, UploadFile

from app.config import settings
from app.database import standalone_db
from app.services.fitness.common import (
    FitnessConflictError,
    FitnessNotFoundError,
    insert_owned,
    json_text,
    new_id,
    owned_row,
)
from app.services.fitness.activity_import import (
    FitImportProvenance,
    retry_fit_import,
    stage_fit_import,
)
from app.services.fitness.run_plans import run_cues_for_version, run_steps_for_version
from app.services.record_history import save_history
from app.utils.encryption import decrypt_value, encrypt_value


INTERVALS_API_BASE = "https://intervals.icu/api/v1"
INTERVALS_AUTHORIZE_URL = "https://intervals.icu/oauth/authorize"
INTERVALS_TOKEN_URL = "https://intervals.icu/api/oauth/token"
INTERVALS_OAUTH_SCOPES = ("CALENDAR:WRITE", "SETTINGS:READ", "ACTIVITY:READ")
OAUTH_STATE_TTL = timedelta(minutes=10)
PROVIDER_TIMEOUT_SECONDS = 12.0
MAX_PUSH_ERRORS = 10
MAX_PUSH_ERROR_LENGTH = 300
MAX_SCHEDULED_RETRIES = 20
ACTIVITY_IMPORT_OVERLAP = timedelta(days=14)
MAX_ACTIVITY_LIST_RESULTS = 500
ACTIVITY_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,100}$")


class IntervalsError(ValueError):
    """An Intervals.icu operation could not safely complete."""


class IntervalsNotConfiguredError(IntervalsError):
    pass


class IntervalsConnectionNotFoundError(IntervalsError):
    pass


class IntervalsStateError(IntervalsError):
    pass


class IntervalsOAuthCompletionError(IntervalsError):
    def __init__(self, surface: str):
        self.surface = surface
        super().__init__("Intervals.icu authorisation could not be completed")


class IntervalsAuthorizationError(IntervalsError):
    pass


class IntervalsProviderError(IntervalsError):
    pass


class IntervalsActivityFileError(IntervalsError):
    def __init__(self, code: str):
        self.code = code
        super().__init__("Intervals.icu activity file could not be imported")


def configured() -> bool:
    return bool(
        settings.intervals_icu_integration_enabled
        and settings.ha_token_encryption_key.strip()
    )


def oauth_configured() -> bool:
    return bool(
        configured()
        and settings.intervals_icu_client_id.strip()
        and settings.intervals_icu_client_secret.strip()
        and settings.intervals_icu_redirect_uri.strip()
    )


def require_configured() -> None:
    if not configured():
        raise IntervalsNotConfiguredError(
            "Intervals.icu delivery is not configured on the HausKlar server"
        )


def require_oauth_configured() -> None:
    require_configured()
    if not oauth_configured():
        raise IntervalsNotConfiguredError(
            "Intervals.icu OAuth is not configured; use a personal API key"
        )


def _utc_now(value: datetime | None = None) -> datetime:
    observed = value or datetime.now(timezone.utc)
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=timezone.utc)
    return observed.astimezone(timezone.utc)


def _utc_text(value: datetime | None = None) -> str:
    return _utc_now(value).isoformat()


def _parse_json(raw: str | None, fallback: Any) -> Any:
    if not raw:
        return fallback
    try:
        return json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return fallback


def _state_digest(state: str) -> str:
    return hashlib.sha256(state.encode("utf-8")).hexdigest()


def _external_id(planned_session_id: str) -> str:
    return f"hausklar-planned-session-{planned_session_id}"


def _encrypt_credential(*, auth_method: str, secret: str) -> str:
    field = "access_token" if auth_method == "oauth" else "api_key"
    return encrypt_value(
        json.dumps(
            {"auth_method": auth_method, field: secret},
            separators=(",", ":"),
            sort_keys=True,
        )
    )


def _decrypt_credential(connection) -> dict[str, str]:
    encrypted = connection["encrypted_token_json"]
    if not encrypted:
        raise IntervalsConnectionNotFoundError(
            "Intervals.icu connection needs authorisation"
        )
    try:
        credential = json.loads(decrypt_value(encrypted))
    except Exception as exc:
        raise IntervalsConnectionNotFoundError(
            "Intervals.icu connection needs authorisation"
        ) from exc
    if not isinstance(credential, dict):
        raise IntervalsConnectionNotFoundError(
            "Intervals.icu connection needs authorisation"
        )
    auth_method = str(credential.get("auth_method") or "")
    field = "access_token" if auth_method == "oauth" else "api_key"
    secret = str(credential.get(field) or "")
    if auth_method not in {"oauth", "personal_api_key"} or not secret:
        raise IntervalsConnectionNotFoundError(
            "Intervals.icu connection needs authorisation"
        )
    return {"auth_method": auth_method, "secret": secret}


def _sanitised_push_errors(value: Any) -> list[str]:
    if value is None:
        return []
    raw_items = value if isinstance(value, list) else [value]
    result: list[str] = []
    for raw in raw_items[:MAX_PUSH_ERRORS]:
        if isinstance(raw, dict):
            raw = raw.get("message") or raw.get("error") or raw.get("detail")
        if raw is None:
            continue
        text = " ".join(str(raw).split())[:MAX_PUSH_ERROR_LENGTH]
        if text and text not in result:
            result.append(text)
    return result


async def _intervals_request(
    method: str,
    path: str,
    *,
    credential: dict[str, str],
    json_body: Any | None = None,
) -> Any:
    """Call one fixed Intervals.icu API path without accepting arbitrary URLs."""
    if not path.startswith("/") or "//" in path:
        raise IntervalsProviderError("Intervals.icu request path is invalid")
    headers = {"Accept": "application/json"}
    auth: httpx.BasicAuth | None = None
    if credential["auth_method"] == "oauth":
        headers["Authorization"] = f"Bearer {credential['secret']}"
    else:
        auth = httpx.BasicAuth("API_KEY", credential["secret"])
    try:
        async with httpx.AsyncClient(timeout=PROVIDER_TIMEOUT_SECONDS) as client:
            response = await client.request(
                method,
                f"{INTERVALS_API_BASE}{path}",
                headers=headers,
                auth=auth,
                json=json_body,
            )
    except httpx.HTTPError as exc:
        raise IntervalsProviderError("Intervals.icu could not be reached") from exc
    if response.status_code in {401, 403}:
        raise IntervalsAuthorizationError("Intervals.icu authorisation was rejected")
    if response.status_code < 200 or response.status_code >= 300:
        raise IntervalsProviderError("Intervals.icu rejected the request")
    if response.status_code == 204 or not response.content:
        return None
    try:
        return response.json()
    except ValueError as exc:
        raise IntervalsProviderError("Intervals.icu returned malformed JSON") from exc


async def _intervals_binary_request(
    path: str,
    *,
    credential: dict[str, str],
) -> bytes:
    """Download one fixed provider file with a decoded-size ceiling."""
    if not path.startswith("/") or "//" in path:
        raise IntervalsProviderError("Intervals.icu request path is invalid")
    headers = {"Accept": "application/octet-stream"}
    auth: httpx.BasicAuth | None = None
    if credential["auth_method"] == "oauth":
        headers["Authorization"] = f"Bearer {credential['secret']}"
    else:
        auth = httpx.BasicAuth("API_KEY", credential["secret"])
    payload = bytearray()
    try:
        async with httpx.AsyncClient(timeout=PROVIDER_TIMEOUT_SECONDS) as client:
            async with client.stream(
                "GET",
                f"{INTERVALS_API_BASE}{path}",
                headers=headers,
                auth=auth,
            ) as response:
                if response.status_code in {401, 403}:
                    raise IntervalsAuthorizationError(
                        "Intervals.icu authorisation was rejected"
                    )
                if response.status_code < 200 or response.status_code >= 300:
                    raise IntervalsProviderError("Intervals.icu rejected the request")
                async for chunk in response.aiter_bytes():
                    payload.extend(chunk)
                    if len(payload) > settings.fitness_fit_max_upload_bytes:
                        raise IntervalsActivityFileError("activity_file_too_large")
    except (IntervalsAuthorizationError, IntervalsActivityFileError):
        raise
    except httpx.HTTPError as exc:
        raise IntervalsProviderError("Intervals.icu could not be reached") from exc
    if not payload:
        raise IntervalsActivityFileError("activity_file_empty")
    return bytes(payload)


def _decode_original_fit(payload: bytes) -> bytes:
    """Accept provider gzip or already-decoded HTTP content, always bounded."""
    if not payload.startswith(b"\x1f\x8b"):
        return payload
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(payload)) as archive:
            decoded = archive.read(settings.fitness_fit_max_upload_bytes + 1)
    except (EOFError, OSError) as exc:
        raise IntervalsActivityFileError("activity_file_invalid") from exc
    if len(decoded) > settings.fitness_fit_max_upload_bytes:
        raise IntervalsActivityFileError("activity_file_too_large")
    if not decoded:
        raise IntervalsActivityFileError("activity_file_empty")
    return decoded


async def _exchange_oauth_code(code: str) -> str:
    try:
        async with httpx.AsyncClient(timeout=PROVIDER_TIMEOUT_SECONDS) as client:
            response = await client.post(
                INTERVALS_TOKEN_URL,
                data={
                    "client_id": settings.intervals_icu_client_id.strip(),
                    "client_secret": settings.intervals_icu_client_secret.strip(),
                    "code": code,
                },
                headers={"Accept": "application/json"},
            )
    except httpx.HTTPError as exc:
        raise IntervalsProviderError("Intervals.icu could not be reached") from exc
    if response.status_code in {401, 403}:
        raise IntervalsAuthorizationError("Intervals.icu authorisation was rejected")
    if response.status_code < 200 or response.status_code >= 300:
        raise IntervalsProviderError("Intervals.icu rejected the authorisation code")
    try:
        body = response.json()
    except ValueError as exc:
        raise IntervalsProviderError("Intervals.icu returned malformed JSON") from exc
    token = str(body.get("access_token") or "") if isinstance(body, dict) else ""
    if not token or len(token) > 2_000:
        raise IntervalsProviderError("Intervals.icu returned an invalid access token")
    return token


def _truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


async def _remote_identity(
    credential: dict[str, str],
) -> tuple[str, str | None, bool]:
    athlete = await _intervals_request("GET", "/athlete/0", credential=credential)
    connections = await _intervals_request(
        "GET", "/athlete/0/connections", credential=credential
    )
    if not isinstance(athlete, dict) or not isinstance(connections, dict):
        raise IntervalsProviderError("Intervals.icu returned an invalid profile")
    athlete_id = str(athlete.get("id") or athlete.get("athlete_id") or "").strip()
    if not athlete_id or len(athlete_id) > 100:
        raise IntervalsProviderError("Intervals.icu returned an invalid athlete")
    athlete_name = str(
        athlete.get("name")
        or " ".join(
            part
            for part in (
                str(athlete.get("firstname") or "").strip(),
                str(athlete.get("lastname") or "").strip(),
            )
            if part
        )
        or ""
    ).strip()
    athlete_name = athlete_name[:200] or None
    # A Garmin account link alone is insufficient: Intervals also has a user
    # setting that can disable pushing calendar workouts to Garmin.
    garmin_ready = _truthy(connections.get("garmin_training_connected")) and _truthy(
        athlete.get("icu_garmin_upload_workouts")
    )
    return athlete_id, athlete_name, garmin_ready


async def _connection_for_user(db, *, user: dict, require_connected: bool = False):
    row = await (
        await db.execute(
            "SELECT * FROM health_intervals_connections WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None or (require_connected and row["status"] != "connected"):
        raise IntervalsConnectionNotFoundError(
            "Connect Intervals.icu before sending a workout"
        )
    return row


async def _save_connection_history(db, connection, *, user: dict) -> None:
    await save_history(
        db,
        "health_intervals_connections",
        connection["id"],
        user["id"],
        family_id=user["family_id"],
        excluded_fields={"encrypted_token_json"},
    )


async def _store_connection(
    db,
    *,
    user: dict,
    auth_method: str,
    secret: str,
    athlete_id: str,
    athlete_name: str | None,
    garmin_ready: bool,
    now: datetime | None = None,
) -> str:
    observed_at = _utc_now(now)
    collision = await (
        await db.execute(
            "SELECT owner_user_id FROM health_intervals_connections "
            "WHERE provider_user_id = ? AND owner_user_id <> ? "
            "AND status <> 'disconnected' AND deleted_at IS NULL LIMIT 1",
            (athlete_id, user["id"]),
        )
    ).fetchone()
    if collision is not None:
        raise FitnessConflictError(
            "This Intervals.icu athlete is already connected to another HausKlar account"
        )
    existing = await (
        await db.execute(
            "SELECT * FROM health_intervals_connections WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    encrypted = _encrypt_credential(auth_method=auth_method, secret=secret)
    values = {
        "provider_user_id": athlete_id,
        "provider_display_name": athlete_name,
        "status": "connected",
        "auth_method": auth_method,
        "scopes_json": (
            list(INTERVALS_OAUTH_SCOPES)
            if auth_method == "oauth"
            else ["PERSONAL_API_KEY_BROAD"]
        ),
        "encrypted_token_json": encrypted,
        "access_token_expires_at": None,
        "garmin_training_connected": garmin_ready,
        "last_tested_at": _utc_text(observed_at),
        "last_error_code": None,
    }
    if existing is None:
        identifier = str(uuid.uuid4())
        await insert_owned(
            db,
            table="health_intervals_connections",
            record_id=identifier,
            values={**values, "revision": 1},
            user=user,
            now=_utc_text(observed_at),
            record_sync_change=False,
        )
    else:
        identifier = existing["id"]
        same_athlete = existing["provider_user_id"] == athlete_id
        await _save_connection_history(db, existing, user=user)
        await db.execute(
            "UPDATE health_intervals_connections SET provider_user_id = ?, "
            "provider_display_name = ?, status = 'connected', auth_method = ?, "
            "scopes_json = ?, encrypted_token_json = ?, access_token_expires_at = NULL, "
            "garmin_training_connected = ?, last_tested_at = ?, last_error_code = NULL, "
            "activity_import_enabled = ?, activity_import_since = ?, "
            "last_activity_import_at = ?, last_activity_import_error_code = ?, "
            "updated_at = ?, revision = revision + 1 WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (
                athlete_id,
                athlete_name,
                auth_method,
                json_text(
                    list(INTERVALS_OAUTH_SCOPES)
                    if auth_method == "oauth"
                    else ["PERSONAL_API_KEY_BROAD"]
                ),
                encrypted,
                int(garmin_ready),
                _utc_text(observed_at),
                int(bool(existing["activity_import_enabled"]) and same_athlete),
                existing["activity_import_since"] if same_athlete else None,
                existing["last_activity_import_at"] if same_athlete else None,
                (
                    existing["last_activity_import_error_code"]
                    if same_athlete
                    else None
                ),
                _utc_text(observed_at),
                identifier,
                user["family_id"],
                user["id"],
            ),
        )
    await db.commit()
    return identifier


async def connection_status(db, *, user: dict) -> dict:
    is_configured = configured()
    row = await (
        await db.execute(
            "SELECT * FROM health_intervals_connections WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if not is_configured:
        status = "not_configured"
    elif row is None:
        status = "not_connected"
    else:
        status = row["status"]
    connected = bool(is_configured and row is not None and status == "connected")
    stored_scopes = _parse_json(row["scopes_json"], []) if row is not None else []
    activity_read_authorized = bool(
        connected
        and (
            row["auth_method"] == "personal_api_key"
            or "ACTIVITY:READ" in stored_scopes
        )
    )
    counts = {
        "imported": 0,
        "pending": 0,
        "error": 0,
    }
    if row is not None and row["provider_user_id"]:
        namespace = f"intervals_icu:{row['provider_user_id']}"
        count_row = await (
            await db.execute(
                "SELECT "
                "COALESCE(SUM(CASE WHEN i.status = 'complete' THEN 1 ELSE 0 END), 0) "
                "AS imported, COALESCE(SUM(CASE WHEN i.status IN ('queued','processing') "
                "THEN 1 ELSE 0 END), 0) AS pending, "
                "COALESCE(SUM(CASE WHEN i.status = 'error' THEN 1 ELSE 0 END), 0) "
                "AS error FROM health_source_records s JOIN health_imports i "
                "ON i.source_record_id = s.id AND i.deleted_at IS NULL "
                "WHERE s.family_id = ? AND s.owner_user_id = ? "
                "AND s.record_kind = 'activity' AND s.transport_key = 'intervals_icu' "
                "AND s.source_namespace = ? AND s.deleted_at IS NULL",
                (user["family_id"], user["id"], namespace),
            )
        ).fetchone()
        if count_row is not None:
            counts = {
                "imported": int(count_row["imported"]),
                "pending": int(count_row["pending"]),
                "error": int(count_row["error"]),
            }
    return {
        "configured": is_configured,
        "oauth_available": oauth_configured(),
        "personal_api_key_available": is_configured,
        "oauth_scopes": list(INTERVALS_OAUTH_SCOPES),
        "connected": connected,
        "status": status,
        "auth_method": row["auth_method"] if connected else None,
        "athlete_id": row["provider_user_id"] if connected else None,
        "athlete_name": row["provider_display_name"] if connected else None,
        "garmin_training_connected": (
            bool(row["garmin_training_connected"])
            if connected and row["garmin_training_connected"] is not None
            else None
        ),
        "last_tested_at": row["last_tested_at"] if row is not None else None,
        "last_error_code": row["last_error_code"] if row is not None else None,
        "activity_read_authorized": activity_read_authorized,
        "activity_import_enabled": bool(
            row["activity_import_enabled"] if row is not None else False
        ),
        "activity_import_since": (
            row["activity_import_since"] if row is not None else None
        ),
        "last_activity_import_at": (
            row["last_activity_import_at"] if row is not None else None
        ),
        "last_activity_import_error_code": (
            row["last_activity_import_error_code"] if row is not None else None
        ),
        "activity_imported_count": counts["imported"],
        "activity_import_pending_count": counts["pending"],
        "activity_import_error_count": counts["error"],
    }


async def connect_api_key(db, *, user: dict, api_key: str) -> dict:
    require_configured()
    value = api_key.strip()
    if len(value) < 8 or len(value) > 2_000:
        raise IntervalsAuthorizationError("Intervals.icu API key is invalid")
    credential = {"auth_method": "personal_api_key", "secret": value}
    athlete_id, athlete_name, garmin_ready = await _remote_identity(credential)
    await _store_connection(
        db,
        user=user,
        auth_method="personal_api_key",
        secret=value,
        athlete_id=athlete_id,
        athlete_name=athlete_name,
        garmin_ready=garmin_ready,
    )
    return await connection_status(db, user=user)


async def _mark_connection_failure(
    db,
    *,
    connection,
    user: dict,
    status: str,
    error_code: str,
    now: datetime | None = None,
) -> None:
    observed_at = _utc_text(now)
    await _save_connection_history(db, connection, user=user)
    await db.execute(
        "UPDATE health_intervals_connections SET status = ?, last_tested_at = ?, "
        "last_error_code = ?, updated_at = ?, revision = revision + 1 "
        "WHERE id = ? AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
        (
            status,
            observed_at,
            error_code,
            observed_at,
            connection["id"],
            user["family_id"],
            user["id"],
        ),
    )
    await db.commit()


async def test_connection(db, *, user: dict) -> dict:
    require_configured()
    connection = await _connection_for_user(db, user=user)
    credential = _decrypt_credential(connection)
    try:
        athlete_id, athlete_name, garmin_ready = await _remote_identity(credential)
    except IntervalsAuthorizationError:
        await _mark_connection_failure(
            db,
            connection=connection,
            user=user,
            status="reauth_required",
            error_code="authorization_failed",
        )
        return await connection_status(db, user=user)
    except IntervalsProviderError:
        await _mark_connection_failure(
            db,
            connection=connection,
            user=user,
            status="provider_down",
            error_code="provider_unavailable",
        )
        return await connection_status(db, user=user)
    observed_at = _utc_text()
    await _save_connection_history(db, connection, user=user)
    await db.execute(
        "UPDATE health_intervals_connections SET provider_user_id = ?, "
        "provider_display_name = ?, status = 'connected', garmin_training_connected = ?, "
        "last_tested_at = ?, last_error_code = NULL, updated_at = ?, "
        "revision = revision + 1 WHERE id = ? AND family_id = ? AND owner_user_id = ? "
        "AND deleted_at IS NULL",
        (
            athlete_id,
            athlete_name,
            int(garmin_ready),
            observed_at,
            observed_at,
            connection["id"],
            user["family_id"],
            user["id"],
        ),
    )
    await db.commit()
    return await connection_status(db, user=user)


def _connection_can_read_activities(connection) -> bool:
    if connection["auth_method"] == "personal_api_key":
        return True
    return "ACTIVITY:READ" in _parse_json(connection["scopes_json"], [])


async def set_activity_import(
    db,
    *,
    user: dict,
    enabled: bool,
    lookback_days: int,
    now: datetime | None = None,
) -> dict:
    require_configured()
    connection = await _connection_for_user(db, user=user, require_connected=True)
    if enabled and not _connection_can_read_activities(connection):
        raise IntervalsStateError(
            "Reconnect Intervals.icu once to allow completed activity imports"
        )
    observed_at = _utc_now(now)
    import_since = connection["activity_import_since"]
    if enabled and not bool(connection["activity_import_enabled"]):
        import_since = _utc_text(observed_at - timedelta(days=lookback_days))
    await _save_connection_history(db, connection, user=user)
    await db.execute(
        "UPDATE health_intervals_connections SET activity_import_enabled = ?, "
        "activity_import_since = ?, last_activity_import_error_code = NULL, "
        "updated_at = ?, revision = revision + 1 WHERE id = ? AND family_id = ? "
        "AND owner_user_id = ? AND status = 'connected' AND deleted_at IS NULL",
        (
            int(enabled),
            import_since,
            _utc_text(observed_at),
            connection["id"],
            user["family_id"],
            user["id"],
        ),
    )
    await db.commit()
    return await connection_status(db, user=user)


def _parsed_utc_text(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return _utc_now(parsed)


async def _existing_activity_import(
    db,
    *,
    user: dict,
    namespace: str,
    provider_activity_id: str,
):
    return await (
        await db.execute(
            "SELECT i.* FROM health_source_records s JOIN health_imports i "
            "ON i.source_record_id = s.id AND i.deleted_at IS NULL "
            "WHERE s.family_id = ? AND s.owner_user_id = ? "
            "AND s.record_kind = 'activity' AND s.transport_key = 'intervals_icu' "
            "AND s.source_namespace = ? AND s.source_object_id = ? "
            "AND s.deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], namespace, provider_activity_id),
        )
    ).fetchone()


async def _activity_import_connection_is_current(
    db,
    *,
    user: dict,
    connection,
) -> bool:
    current = await (
        await db.execute(
            "SELECT revision FROM health_intervals_connections WHERE id = ? "
            "AND family_id = ? AND owner_user_id = ? AND provider_user_id = ? "
            "AND status = 'connected' AND activity_import_enabled = 1 "
            "AND encrypted_token_json IS NOT NULL AND deleted_at IS NULL LIMIT 1",
            (
                connection["id"],
                user["family_id"],
                user["id"],
                connection["provider_user_id"],
            ),
        )
    ).fetchone()
    return bool(current and int(current["revision"]) == int(connection["revision"]))


async def _mark_activity_import_error(
    db,
    *,
    user: dict,
    connection,
    error_code: str,
    authorization_failed: bool = False,
) -> None:
    current = await (
        await db.execute(
            "SELECT * FROM health_intervals_connections WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (connection["id"], user["family_id"], user["id"]),
        )
    ).fetchone()
    if current is None:
        return
    await _save_connection_history(db, current, user=user)
    observed_at = _utc_text()
    await db.execute(
        "UPDATE health_intervals_connections SET status = CASE WHEN ? = 1 "
        "THEN 'reauth_required' ELSE status END, last_error_code = CASE WHEN ? = 1 "
        "THEN 'authorization_failed' ELSE last_error_code END, "
        "last_activity_import_error_code = ?, updated_at = ?, revision = revision + 1 "
        "WHERE id = ? AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
        (
            int(authorization_failed),
            int(authorization_failed),
            error_code,
            observed_at,
            connection["id"],
            user["family_id"],
            user["id"],
        ),
    )
    await db.commit()


def _activity_list(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        values = payload
    elif isinstance(payload, dict) and isinstance(payload.get("activities"), list):
        values = payload["activities"]
    else:
        raise IntervalsProviderError("Intervals.icu returned an invalid activity list")
    return [value for value in values if isinstance(value, dict)]


async def sync_activity_imports(
    db,
    *,
    user: dict,
    now: datetime | None = None,
) -> dict:
    """Queue new Garmin FIT files from one explicitly enabled connection."""
    require_configured()
    connection = await _connection_for_user(db, user=user, require_connected=True)
    if not bool(connection["activity_import_enabled"]):
        raise IntervalsStateError("Turn on Garmin activity imports first")
    if not _connection_can_read_activities(connection):
        raise IntervalsStateError(
            "Reconnect Intervals.icu once to allow completed activity imports"
        )
    credential = _decrypt_credential(connection)
    observed_at = _utc_now(now)
    initial_since = _parsed_utc_text(connection["activity_import_since"])
    last_import = _parsed_utc_text(connection["last_activity_import_at"])
    oldest = initial_since or observed_at - timedelta(days=30)
    if last_import is not None:
        oldest = max(oldest, last_import - ACTIVITY_IMPORT_OVERLAP)
    query = urlencode(
        {
            "oldest": oldest.date().isoformat(),
            "newest": observed_at.date().isoformat(),
        }
    )
    try:
        remote_payload = await _intervals_request(
            "GET",
            f"/athlete/0/activities?{query}",
            credential=credential,
        )
    except IntervalsAuthorizationError:
        await _mark_activity_import_error(
            db,
            user=user,
            connection=connection,
            error_code="authorization_failed",
            authorization_failed=True,
        )
        raise
    except IntervalsProviderError:
        await _mark_activity_import_error(
            db,
            user=user,
            connection=connection,
            error_code="provider_unavailable",
        )
        raise

    activities = _activity_list(remote_payload)
    discovered_count = len(activities)
    skipped_count = max(0, discovered_count - MAX_ACTIVITY_LIST_RESULTS)
    queued_count = 0
    existing_count = 0
    item_error_code: str | None = None
    namespace = f"intervals_icu:{connection['provider_user_id']}"
    ordered = sorted(
        activities[:MAX_ACTIVITY_LIST_RESULTS],
        key=lambda item: str(
            item.get("start_date") or item.get("start_date_local") or ""
        ),
    )
    for activity in ordered:
        provider_activity_id = str(activity.get("id") or "").strip()
        provider_source = str(activity.get("source") or "").strip().upper()
        file_type = str(activity.get("file_type") or "").strip().lower()
        if (
            not ACTIVITY_ID_PATTERN.fullmatch(provider_activity_id)
            or provider_source != "GARMIN_CONNECT"
            or file_type not in {"", "fit"}
        ):
            skipped_count += 1
            continue
        existing = await _existing_activity_import(
            db,
            user=user,
            namespace=namespace,
            provider_activity_id=provider_activity_id,
        )
        if existing is not None:
            if existing["status"] == "error" and bool(existing["retryable"]):
                await retry_fit_import(
                    db,
                    user=user,
                    import_id=existing["id"],
                )
                queued_count += 1
            else:
                existing_count += 1
            continue
        if not await _activity_import_connection_is_current(
            db, user=user, connection=connection
        ):
            raise IntervalsStateError("Garmin activity import was turned off")
        try:
            payload = _decode_original_fit(
                await _intervals_binary_request(
                    f"/activity/{provider_activity_id}/file",
                    credential=credential,
                )
            )
        except IntervalsActivityFileError as exc:
            skipped_count += 1
            item_error_code = exc.code
            continue
        except IntervalsAuthorizationError:
            await _mark_activity_import_error(
                db,
                user=user,
                connection=connection,
                error_code="authorization_failed",
                authorization_failed=True,
            )
            raise
        except IntervalsProviderError:
            await _mark_activity_import_error(
                db,
                user=user,
                connection=connection,
                error_code="provider_unavailable",
            )
            raise
        if not await _activity_import_connection_is_current(
            db, user=user, connection=connection
        ):
            raise IntervalsStateError("Garmin activity import was turned off")
        device_name = str(activity.get("device_name") or "").strip()[:200] or None
        started_at = str(
            activity.get("start_date") or activity.get("start_date_local") or ""
        ).strip()[:100] or None
        upload = UploadFile(
            io.BytesIO(payload),
            filename=f"intervals-{provider_activity_id}.fit",
            headers=Headers({"content-type": "application/vnd.ant.fit"}),
        )
        try:
            await stage_fit_import(
                db,
                user=user,
                file=upload,
                client_import_id=(
                    f"intervals_icu:{connection['provider_user_id']}:"
                    f"{provider_activity_id}"
                ),
                provenance=FitImportProvenance(
                    transport_key="intervals_icu",
                    origin_provider_key="garmin",
                    source_namespace=namespace,
                    source_object_id=provider_activity_id,
                    source_name="Intervals.icu / Garmin Connect",
                    source_device_identifier=device_name,
                    raw_metadata={
                        "provider_activity_id": provider_activity_id,
                        "provider_source": provider_source,
                        "provider_file_type": file_type or "fit",
                        "provider_start_at": started_at,
                    },
                ),
            )
        finally:
            await upload.close()
        queued_count += 1

    current = await (
        await db.execute(
            "SELECT * FROM health_intervals_connections WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND status = 'connected' "
            "AND activity_import_enabled = 1 AND deleted_at IS NULL LIMIT 1",
            (connection["id"], user["family_id"], user["id"]),
        )
    ).fetchone()
    if current is not None:
        await _save_connection_history(db, current, user=user)
        await db.execute(
            "UPDATE health_intervals_connections SET last_activity_import_at = ?, "
            "last_activity_import_error_code = ?, updated_at = ?, "
            "revision = revision + 1 WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND status = 'connected' "
            "AND activity_import_enabled = 1 AND deleted_at IS NULL",
            (
                _utc_text(observed_at),
                item_error_code,
                _utc_text(observed_at),
                connection["id"],
                user["family_id"],
                user["id"],
            ),
        )
        await db.commit()
    return {
        "discovered_count": discovered_count,
        "queued_count": queued_count,
        "existing_count": existing_count,
        "skipped_count": skipped_count,
        "status": await connection_status(db, user=user),
    }


def callback_return_url(surface: str, outcome: str) -> str:
    safe_outcome = outcome if outcome in {"connected", "cancelled", "failed"} else "failed"
    if surface == "app":
        return f"hausklar://fitness/intervals?status={safe_outcome}"
    base = settings.web_app_url.strip().rstrip("/")
    return (
        f"{base}/?"
        f"{urlencode({'view': 'fitness', 'section': 'plan', 'intervals': safe_outcome})}"
    )


async def start_authorization(
    db,
    *,
    user: dict,
    return_surface: str,
    now: datetime | None = None,
) -> tuple[str, datetime]:
    require_oauth_configured()
    observed_at = _utc_now(now)
    expires_at = observed_at + OAUTH_STATE_TTL
    state = secrets.token_urlsafe(40)
    await insert_owned(
        db,
        table="health_intervals_oauth_states",
        record_id=str(uuid.uuid4()),
        values={
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
    await db.execute(
        "UPDATE health_intervals_oauth_states SET deleted_at = ?, updated_at = ?, "
        "revision = revision + 1 WHERE owner_user_id = ? AND consumed_at IS NULL "
        "AND expires_at < ? AND deleted_at IS NULL",
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
        "client_id": settings.intervals_icu_client_id.strip(),
        "redirect_uri": settings.intervals_icu_redirect_uri.strip(),
        "scope": ",".join(INTERVALS_OAUTH_SCOPES),
        "state": state,
    }
    return f"{INTERVALS_AUTHORIZE_URL}?{urlencode(params)}", expires_at


async def _claim_oauth_state(
    db, *, state: str, now: datetime | None = None
) -> tuple[dict, str]:
    observed_at = _utc_now(now)
    row = await (
        await db.execute(
            "SELECT oauth.*, user.name AS user_name, user.email AS user_email, "
            "user.role AS user_role, user.priority AS user_priority "
            "FROM health_intervals_oauth_states oauth JOIN users user "
            "ON user.id = oauth.owner_user_id AND user.family_id = oauth.family_id "
            "AND user.deleted_at IS NULL WHERE oauth.state_digest = ? "
            "AND oauth.consumed_at IS NULL AND oauth.deleted_at IS NULL LIMIT 1",
            (_state_digest(state),),
        )
    ).fetchone()
    if row is None:
        raise IntervalsStateError("Intervals.icu authorisation state is absent or expired")
    try:
        expires_at = datetime.fromisoformat(str(row["expires_at"]).replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        raise IntervalsStateError(
            "Intervals.icu authorisation state is absent or expired"
        ) from exc
    if _utc_now(expires_at) <= observed_at:
        raise IntervalsStateError("Intervals.icu authorisation state is absent or expired")
    claimed = await db.execute(
        "UPDATE health_intervals_oauth_states SET consumed_at = ?, updated_at = ?, "
        "revision = revision + 1 WHERE id = ? AND consumed_at IS NULL "
        "AND deleted_at IS NULL",
        (_utc_text(observed_at), _utc_text(observed_at), row["id"]),
    )
    if claimed.rowcount != 1:
        raise IntervalsStateError("Intervals.icu authorisation state was already used")
    await db.commit()
    user = {
        "id": row["owner_user_id"],
        "family_id": row["family_id"],
        "name": row["user_name"],
        "email": row["user_email"],
        "role": row["user_role"],
        "priority": row["user_priority"],
    }
    return user, row["return_surface"]


async def complete_authorization(db, *, state: str, code: str) -> str:
    require_oauth_configured()
    user, surface = await _claim_oauth_state(db, state=state)
    try:
        token = await _exchange_oauth_code(code)
        credential = {"auth_method": "oauth", "secret": token}
        athlete_id, athlete_name, garmin_ready = await _remote_identity(credential)
        await _store_connection(
            db,
            user=user,
            auth_method="oauth",
            secret=token,
            athlete_id=athlete_id,
            athlete_name=athlete_name,
            garmin_ready=garmin_ready,
        )
    except Exception as exc:
        raise IntervalsOAuthCompletionError(surface) from exc
    return surface


async def consume_cancelled_authorization(db, *, state: str) -> str:
    _, surface = await _claim_oauth_state(db, state=state)
    return surface


async def disconnect(db, *, user: dict) -> int:
    connection = await _connection_for_user(db, user=user)
    await _save_connection_history(db, connection, user=user)
    rows = await (
        await db.execute(
            "SELECT id FROM health_intervals_publications WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    for row in rows:
        await save_history(
            db,
            "health_intervals_publications",
            row["id"],
            user["id"],
            family_id=user["family_id"],
            excluded_fields={"payload_json"},
        )
    observed_at = _utc_text()
    await db.execute(
        "UPDATE health_intervals_connections SET provider_user_id = NULL, "
        "provider_display_name = NULL, status = 'disconnected', "
        "encrypted_token_json = NULL, access_token_expires_at = NULL, "
        "garmin_training_connected = NULL, last_error_code = NULL, "
        "activity_import_enabled = 0, activity_import_since = NULL, "
        "last_activity_import_error_code = NULL, updated_at = ?, "
        "revision = revision + 1 WHERE id = ? AND family_id = ? AND owner_user_id = ? "
        "AND deleted_at IS NULL",
        (observed_at, connection["id"], user["family_id"], user["id"]),
    )
    await db.execute(
        "UPDATE health_intervals_publications SET payload_json = NULL, "
        "mapping_warnings_json = '[]', push_errors_json = '[]', next_retry_at = NULL, "
        "state = CASE WHEN state = 'pending' THEN 'error' ELSE state END, "
        "last_error_code = CASE WHEN state = 'pending' THEN 'disconnected' "
        "ELSE last_error_code END, updated_at = ?, revision = revision + 1 "
        "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
        (observed_at, user["family_id"], user["id"]),
    )
    await db.commit()
    return len(rows)


def _format_number(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else f"{value:g}"


def _format_duration(step: dict) -> tuple[str | None, str | None]:
    value = float(step.get("duration_value") or 0)
    kind = step.get("duration_type")
    if kind == "distance_m":
        if value >= 1_000:
            return f"{_format_number(value / 1_000)}km", None
        return f"{_format_number(value)}mtr", None
    if kind == "time_s":
        seconds = int(round(value))
        minutes, remaining = divmod(seconds, 60)
        if minutes and remaining:
            return f"{minutes}m{remaining}s", None
        if minutes:
            return f"{minutes}m", None
        return f"{remaining}s", None
    display_name = str(step.get("display_name") or "Run step")[:80]
    return (
        None,
        f"{display_name}: {kind or 'open'} duration remains in HausKlar because "
        "Intervals.icu cannot safely map it to an enforced Garmin step.",
    )


def _pace(value: float) -> str:
    total_seconds = max(0, int(round(value)))
    minutes, seconds = divmod(total_seconds, 60)
    return f"{minutes}:{seconds:02d}"


def _format_target(step: dict) -> tuple[str, str | None]:
    target_type = step.get("target_type")
    low = step.get("target_low")
    high = step.get("target_high")
    if target_type == "none" or low is None or high is None:
        return "", None
    low_value = float(low)
    high_value = float(high)
    if target_type == "pace_s_per_km":
        return f"{_pace(low_value)}-{_pace(high_value)}/km Pace", None
    if target_type == "heart_rate_zone":
        return f"Z{_format_number(low_value)}-Z{_format_number(high_value)} HR", None
    if target_type == "power_zone":
        return f"Z{_format_number(low_value)}-Z{_format_number(high_value)}", None
    if target_type == "power_w":
        return f"{_format_number(low_value)}-{_format_number(high_value)}w", None
    target_label = {
        "heart_rate_bpm": "absolute heart-rate",
        "cadence_spm": "cadence",
        "rpe": "RPE",
    }.get(str(target_type), "unsupported")
    display_name = str(step.get("display_name") or "Run step")[:80]
    return (
        "",
        f"{display_name}: {target_label} guidance remains in HausKlar and is not "
        "enforced by Intervals.icu or Garmin.",
    )


def _workout_description(steps: list[dict], cues: list[dict]) -> tuple[str, list[str]]:
    lines: list[str] = []
    warnings: list[str] = []
    cues_by_step: dict[str, list[str]] = {}
    for cue in cues:
        step_id = str(cue.get("step_id") or "")
        text = " ".join(str(cue.get("short_text") or "").split())
        if step_id and text:
            cues_by_step.setdefault(step_id, []).append(text)

    def warn(message: str) -> None:
        if message not in warnings:
            warnings.append(message)

    def append_line(line: str) -> None:
        if len(lines) >= 1_000:
            raise FitnessConflictError(
                "This workout is too deeply repeated for safe Intervals.icu delivery"
            )
        lines.append(line)

    def blank_line() -> None:
        if lines and lines[-1] != "":
            append_line("")

    def step_text(step: dict) -> tuple[str, bool]:
        parts: list[str] = []
        extra_values = (
            step.get("instruction_text"),
            step.get("mental_cue_text"),
            step.get("spoken_cue_text"),
            *cues_by_step.get(str(step.get("id") or ""), []),
        )
        for value in (step.get("display_name"), *extra_values):
            text = " ".join(str(value or "").split())
            if text and text not in parts:
                parts.append(text)
        combined = " — ".join(parts)
        return combined[:120], any(
            " ".join(str(value or "").split()) for value in extra_values
        )

    def add(items: list[dict], repeat_depth: int) -> None:
        for step in sorted(items, key=lambda item: int(item.get("sequence") or 0)):
            if step.get("step_kind") == "repeat_block":
                repeat_count = int(step.get("repeat_count") or 1)
                if repeat_depth == 0:
                    blank_line()
                    block_start = len(lines)
                    append_line(f"{repeat_count}x")
                    add(list(step.get("children") or []), repeat_depth + 1)
                    has_deliverable_child = any(
                        line.startswith("- ") for line in lines[block_start + 1 :]
                    )
                    if has_deliverable_child:
                        blank_line()
                    else:
                        del lines[block_start:]
                        while lines and lines[-1] == "":
                            lines.pop()
                        warn(
                            "A repeat block with no safely deliverable child steps "
                            "remains in HausKlar."
                        )
                else:
                    warn(
                        "Nested repeats were flattened for Intervals.icu; review the "
                        "workout there before relying on Garmin delivery."
                    )
                    for _ in range(repeat_count):
                        add(list(step.get("children") or []), repeat_depth)
                continue
            target, target_warning = _format_target(step)
            if target_warning:
                warn(target_warning)
            duration, duration_warning = _format_duration(step)
            if duration_warning:
                warn(duration_warning)
            if duration is None:
                continue
            label, has_cue = step_text(step)
            line = f"- {label} {duration}" if label else f"- {duration}"
            if target:
                line = f"{line} {target}"
            append_line(line)
            if has_cue:
                warn(
                    "Short step text is sent to Intervals.icu, but Garmin display "
                    "and speech are not guaranteed."
                )

    add(steps, 0)
    while lines and lines[-1] == "":
        lines.pop()
    description = "\n".join(lines)
    if not description:
        raise FitnessConflictError("This running workout has no executable steps")
    if cues and not cues_by_step:
        warn(
            "Unattached workout cues remain in HausKlar; Garmin display and speech "
            "are not guaranteed."
        )
    return description[:20_000], warnings


def _scheduled_local(plan) -> str:
    scheduled_value = plan["scheduled_start_utc"] or plan["time_window_start_utc"]
    if scheduled_value:
        try:
            zone = ZoneInfo(plan["local_timezone"])
            scheduled = datetime.fromisoformat(
                str(scheduled_value).replace("Z", "+00:00")
            )
            if scheduled.tzinfo is None:
                scheduled = scheduled.replace(tzinfo=timezone.utc)
            return scheduled.astimezone(zone).replace(tzinfo=None).isoformat(timespec="seconds")
        except (TypeError, ValueError, ZoneInfoNotFoundError) as exc:
            raise FitnessConflictError("The planned run has an invalid local schedule") from exc
    if plan["scheduled_date"]:
        return str(plan["scheduled_date"])
    raise FitnessConflictError("Schedule this run before sending it to Intervals.icu")


async def _event_payload(
    db, *, user: dict, planned_session_id: str
) -> tuple[dict, int, list[str]]:
    plan = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
    )
    if plan["sport_key"] != "running":
        raise FitnessConflictError("Only scheduled running workouts can be sent")
    if plan["status"] not in {"accepted", "scheduled"}:
        raise FitnessConflictError("Accept this scheduled run before sending it")
    if not plan["workout_version_id"]:
        raise FitnessConflictError("This planned run has no structured workout")
    version = await owned_row(
        db,
        table="health_workout_versions",
        record_id=plan["workout_version_id"],
        user=user,
    )
    if version["sport_key"] != "running":
        raise FitnessConflictError("This planned run does not use a running workout")
    steps = await run_steps_for_version(
        db, user=user, version_id=plan["workout_version_id"]
    )
    cues = await run_cues_for_version(
        db, user=user, version_id=plan["workout_version_id"]
    )
    description, mapping_warnings = _workout_description(steps, cues)
    payload: dict[str, Any] = {
        "category": "WORKOUT",
        "type": "Run",
        "start_date_local": _scheduled_local(plan),
        "name": str(plan["title"])[:200],
        "description": description,
        "external_id": _external_id(planned_session_id),
    }
    moving_time = plan["expected_duration_s"] or version["estimated_duration_s"]
    if moving_time:
        payload["moving_time"] = int(moving_time)
    return payload, int(plan["revision"]), mapping_warnings


async def _publication_row(db, *, user: dict, planned_session_id: str):
    return await (
        await db.execute(
            "SELECT * FROM health_intervals_publications WHERE family_id = ? "
            "AND owner_user_id = ? AND planned_session_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], planned_session_id),
        )
    ).fetchone()


def _publication_response(
    planned_session_id: str,
    row=None,
    *,
    operation: str = "none",
) -> dict:
    if row is None:
        return {
            "planned_session_id": planned_session_id,
            "state": "not_sent",
            "operation": operation,
            "external_id": None,
            "provider_event_id": None,
            "sent_at": None,
            "last_error_code": None,
            "push_errors": [],
        }
    return {
        "planned_session_id": planned_session_id,
        "state": row["state"],
        "operation": operation,
        "external_id": row["external_id"],
        "provider_event_id": row["provider_event_id"],
        "sent_at": row["sent_at"],
        "last_error_code": row["last_error_code"],
        "push_errors": _sanitised_push_errors(
            [
                *_parse_json(row["mapping_warnings_json"], []),
                *_parse_json(row["push_errors_json"], []),
            ]
        ),
    }


def _event_from_provider(payload: Any) -> dict:
    if isinstance(payload, list):
        candidate = payload[0] if payload else {}
    elif isinstance(payload, dict) and isinstance(payload.get("events"), list):
        candidate = payload["events"][0] if payload["events"] else {}
    else:
        candidate = payload
    if not isinstance(candidate, dict):
        raise IntervalsProviderError("Intervals.icu returned an invalid event")
    return candidate


async def _provider_publish(credential: dict[str, str], payload: dict) -> dict:
    result = await _intervals_request(
        "POST",
        "/athlete/0/events/bulk?upsert=true",
        credential=credential,
        json_body=[payload],
    )
    return _event_from_provider(result)


async def _provider_cancel(credential: dict[str, str], external_id: str) -> None:
    await _intervals_request(
        "PUT",
        "/athlete/0/events/bulk-delete",
        credential=credential,
        json_body=[{"external_id": external_id}],
    )


def _retry_at(attempt_count: int, now: datetime) -> str:
    delay_minutes = min(60, 2 ** min(max(attempt_count, 1), 6))
    return _utc_text(now + timedelta(minutes=delay_minutes))


def _desired_action_for_plan(plan) -> str | None:
    """Return convergence work for an existing publication after a plan change."""
    if plan["deleted_at"] is not None:
        return "cancel"
    if plan["status"] in {"completed", "partially_completed", "in_progress"}:
        return None
    eligible = bool(
        plan["sport_key"] == "running"
        and plan["status"] in {"accepted", "scheduled"}
        and plan["workout_version_id"]
        and (
            plan["scheduled_start_utc"]
            or plan["time_window_start_utc"]
            or plan["scheduled_date"]
        )
    )
    return "publish" if eligible else "cancel"


async def _record_publication_failure(
    db,
    *,
    user: dict,
    connection,
    planned_session_id: str,
    payload: dict | None,
    mapping_warnings: list[str],
    source_revision: int,
    desired_action: str,
    error_code: str,
    now: datetime,
) -> None:
    await db.execute("BEGIN IMMEDIATE")
    current_connection = await (
        await db.execute(
            "SELECT status, encrypted_token_json FROM health_intervals_connections "
            "WHERE id = ? AND family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (connection["id"], user["family_id"], user["id"]),
        )
    ).fetchone()
    current_plan = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
        include_deleted=True,
    )
    if int(current_plan["revision"]) != source_revision:
        current_action = _desired_action_for_plan(current_plan)
        desired_action = current_action or "cancel"
        source_revision = int(current_plan["revision"])
        if desired_action == "cancel":
            payload = None
            mapping_warnings = []
    existing = await _publication_row(
        db, user=user, planned_session_id=planned_session_id
    )
    attempt_count = int(existing["attempt_count"] if existing else 0) + 1
    connection_was_removed = bool(
        current_connection is None
        or current_connection["status"] == "disconnected"
        or not current_connection["encrypted_token_json"]
    )
    if connection_was_removed:
        payload = None
        mapping_warnings = []
        error_code = "disconnected"
        attempt_count = MAX_SCHEDULED_RETRIES
    next_retry_at = None if connection_was_removed else _retry_at(attempt_count, now)
    values = {
        "connection_id": connection["id"],
        "planned_session_id": planned_session_id,
        "external_id": _external_id(planned_session_id),
        "provider_event_id": existing["provider_event_id"] if existing else None,
        "state": "error",
        "desired_action": desired_action,
        "source_revision": max(source_revision, 1),
        "payload_json": json_text(payload) if payload is not None else None,
        "mapping_warnings_json": mapping_warnings,
        "push_errors_json": [],
        "sent_at": existing["sent_at"] if existing else None,
        "last_attempt_at": _utc_text(now),
        "next_retry_at": next_retry_at,
        "attempt_count": attempt_count,
        "last_error_code": error_code,
    }
    if existing is None:
        await insert_owned(
            db,
            table="health_intervals_publications",
            record_id=new_id(),
            values={**values, "revision": 1},
            user=user,
            now=_utc_text(now),
            record_sync_change=False,
        )
    else:
        await save_history(
            db,
            "health_intervals_publications",
            existing["id"],
            user["id"],
            family_id=user["family_id"],
            excluded_fields={"payload_json"},
        )
        await db.execute(
            "UPDATE health_intervals_publications SET connection_id = ?, state = 'error', "
            "desired_action = ?, source_revision = ?, payload_json = ?, "
            "mapping_warnings_json = ?, push_errors_json = '[]', "
            "last_attempt_at = ?, next_retry_at = ?, "
            "attempt_count = ?, last_error_code = ?, updated_at = ?, "
            "revision = revision + 1 WHERE id = ? AND family_id = ? AND owner_user_id = ?",
            (
                connection["id"],
                desired_action,
                max(source_revision, 1),
                json_text(payload) if payload is not None else None,
                json_text(mapping_warnings),
                _utc_text(now),
                next_retry_at,
                attempt_count,
                error_code,
                _utc_text(now),
                existing["id"],
                user["family_id"],
                user["id"],
            ),
        )
    await db.commit()


async def publish_workout(
    db,
    *,
    user: dict,
    planned_session_id: str,
    force: bool = False,
) -> dict:
    require_configured()
    connection = await _connection_for_user(db, user=user, require_connected=True)
    credential = _decrypt_credential(connection)
    payload, source_revision, mapping_warnings = await _event_payload(
        db, user=user, planned_session_id=planned_session_id
    )
    payload_text = json_text(payload)
    existing = await _publication_row(
        db, user=user, planned_session_id=planned_session_id
    )
    if (
        not force
        and existing is not None
        and existing["state"] == "sent"
        and existing["desired_action"] == "publish"
        and existing["payload_json"] == payload_text
        and int(existing["source_revision"]) == source_revision
    ):
        return _publication_response(
            planned_session_id, existing, operation="unchanged"
        )
    operation = "created"
    if existing is not None:
        operation = "retried" if existing["state"] == "error" else "updated"
    observed_at = _utc_now()
    try:
        provider_event = await _provider_publish(credential, payload)
    except IntervalsAuthorizationError:
        await _mark_connection_failure(
            db,
            connection=connection,
            user=user,
            status="reauth_required",
            error_code="authorization_failed",
            now=observed_at,
        )
        await _record_publication_failure(
            db,
            user=user,
            connection=connection,
            planned_session_id=planned_session_id,
            payload=payload,
            mapping_warnings=mapping_warnings,
            source_revision=source_revision,
            desired_action="publish",
            error_code="authorization_failed",
            now=observed_at,
        )
        raise
    except IntervalsProviderError:
        await _record_publication_failure(
            db,
            user=user,
            connection=connection,
            planned_session_id=planned_session_id,
            payload=payload,
            mapping_warnings=mapping_warnings,
            source_revision=source_revision,
            desired_action="publish",
            error_code="provider_unavailable",
            now=observed_at,
        )
        raise
    provider_event_id = str(
        provider_event.get("id") or provider_event.get("event_id") or ""
    ).strip() or (existing["provider_event_id"] if existing else None)
    push_errors = _sanitised_push_errors(provider_event.get("push_errors"))
    # The provider call is complete before taking a write lock. Revision recheck
    # and publication update are atomic, so an edit either appears here or its
    # planning transaction queues itself immediately after this commit.
    await db.execute("BEGIN IMMEDIATE")
    current_connection = await (
        await db.execute(
            "SELECT * FROM health_intervals_connections WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (connection["id"], user["family_id"], user["id"]),
        )
    ).fetchone()
    current_plan = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
        include_deleted=True,
    )
    current_publication = await _publication_row(
        db, user=user, planned_session_id=planned_session_id
    )
    connection_is_current = bool(
        current_connection is not None
        and current_connection["status"] == "connected"
        and current_connection["encrypted_token_json"]
        and int(current_connection["revision"]) == int(connection["revision"])
    )
    if not connection_is_current:
        disconnected_values = {
            "connection_id": connection["id"],
            "planned_session_id": planned_session_id,
            "external_id": payload["external_id"],
            "provider_event_id": provider_event_id,
            "state": "error",
            "desired_action": "publish",
            "source_revision": int(current_plan["revision"]),
            "payload_json": None,
            "mapping_warnings_json": [],
            "push_errors_json": [],
            "sent_at": None,
            "last_attempt_at": _utc_text(observed_at),
            "next_retry_at": None,
            "attempt_count": MAX_SCHEDULED_RETRIES,
            "last_error_code": "disconnected",
        }
        if current_publication is None:
            await insert_owned(
                db,
                table="health_intervals_publications",
                record_id=new_id(),
                values={**disconnected_values, "revision": 1},
                user=user,
                now=_utc_text(observed_at),
                record_sync_change=False,
            )
        else:
            await save_history(
                db,
                "health_intervals_publications",
                current_publication["id"],
                user["id"],
                family_id=user["family_id"],
                excluded_fields={"payload_json"},
            )
            await db.execute(
                "UPDATE health_intervals_publications SET provider_event_id = ?, "
                "state = 'error', desired_action = 'publish', source_revision = ?, "
                "payload_json = NULL, mapping_warnings_json = '[]', "
                "push_errors_json = '[]', sent_at = NULL, last_attempt_at = ?, "
                "next_retry_at = NULL, attempt_count = ?, "
                "last_error_code = 'disconnected', updated_at = ?, "
                "revision = revision + 1 WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ? AND deleted_at IS NULL",
                (
                    provider_event_id,
                    int(current_plan["revision"]),
                    _utc_text(observed_at),
                    MAX_SCHEDULED_RETRIES,
                    _utc_text(observed_at),
                    current_publication["id"],
                    user["family_id"],
                    user["id"],
                ),
            )
        await db.commit()
        row = await _publication_row(
            db, user=user, planned_session_id=planned_session_id
        )
        return _publication_response(planned_session_id, row, operation=operation)
    publication_changed = bool(
        existing is not None
        and (
            current_publication is None
            or int(current_publication["revision"]) != int(existing["revision"])
        )
    )
    desired_after_send: str | None = None
    if publication_changed and current_publication is not None:
        desired_after_send = current_publication["desired_action"]
    elif int(current_plan["revision"]) != source_revision:
        desired_after_send = _desired_action_for_plan(current_plan)
    pending_after_send = desired_after_send in {"publish", "cancel"}
    stored_source_revision = (
        int(current_plan["revision"]) if pending_after_send else source_revision
    )
    values = {
        "connection_id": connection["id"],
        "planned_session_id": planned_session_id,
        "external_id": payload["external_id"],
        "provider_event_id": provider_event_id,
        "state": "pending" if pending_after_send else "sent",
        "desired_action": desired_after_send or "publish",
        "source_revision": stored_source_revision,
        "payload_json": payload,
        "mapping_warnings_json": mapping_warnings,
        "push_errors_json": push_errors,
        "sent_at": _utc_text(observed_at),
        "last_attempt_at": _utc_text(observed_at),
        "next_retry_at": _utc_text(observed_at) if pending_after_send else None,
        "attempt_count": 0,
        "last_error_code": None,
    }
    if current_publication is None:
        identifier = new_id()
        await insert_owned(
            db,
            table="health_intervals_publications",
            record_id=identifier,
            values={**values, "revision": 1},
            user=user,
            now=_utc_text(observed_at),
            record_sync_change=False,
        )
    else:
        identifier = current_publication["id"]
        await save_history(
            db,
            "health_intervals_publications",
            identifier,
            user["id"],
            family_id=user["family_id"],
            excluded_fields={"payload_json"},
        )
        await db.execute(
            "UPDATE health_intervals_publications SET connection_id = ?, "
            "provider_event_id = ?, state = ?, desired_action = ?, "
            "source_revision = ?, payload_json = ?, mapping_warnings_json = ?, "
            "push_errors_json = ?, sent_at = ?, "
            "last_attempt_at = ?, next_retry_at = ?, attempt_count = 0, "
            "last_error_code = NULL, updated_at = ?, revision = revision + 1 "
            "WHERE id = ? AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
            (
                connection["id"],
                provider_event_id,
                values["state"],
                values["desired_action"],
                stored_source_revision,
                payload_text,
                json_text(mapping_warnings),
                json_text(push_errors),
                _utc_text(observed_at),
                _utc_text(observed_at),
                values["next_retry_at"],
                _utc_text(observed_at),
                identifier,
                user["family_id"],
                user["id"],
            ),
        )
    await db.commit()
    row = await _publication_row(db, user=user, planned_session_id=planned_session_id)
    return _publication_response(planned_session_id, row, operation=operation)


async def cancel_workout(
    db,
    *,
    user: dict,
    planned_session_id: str,
    force: bool = False,
) -> dict:
    require_configured()
    await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
        include_deleted=True,
    )
    existing = await _publication_row(
        db, user=user, planned_session_id=planned_session_id
    )
    if existing is None:
        return _publication_response(planned_session_id, operation="unchanged")
    if not force and existing["state"] == "cancelled":
        return _publication_response(
            planned_session_id, existing, operation="unchanged"
        )
    connection = await _connection_for_user(db, user=user, require_connected=True)
    credential = _decrypt_credential(connection)
    observed_at = _utc_now()
    try:
        await _provider_cancel(credential, existing["external_id"])
    except IntervalsAuthorizationError:
        await _mark_connection_failure(
            db,
            connection=connection,
            user=user,
            status="reauth_required",
            error_code="authorization_failed",
            now=observed_at,
        )
        await _record_publication_failure(
            db,
            user=user,
            connection=connection,
            planned_session_id=planned_session_id,
            payload=None,
            mapping_warnings=[],
            source_revision=int(existing["source_revision"]),
            desired_action="cancel",
            error_code="authorization_failed",
            now=observed_at,
        )
        raise
    except IntervalsProviderError:
        await _record_publication_failure(
            db,
            user=user,
            connection=connection,
            planned_session_id=planned_session_id,
            payload=None,
            mapping_warnings=[],
            source_revision=int(existing["source_revision"]),
            desired_action="cancel",
            error_code="provider_unavailable",
            now=observed_at,
        )
        raise
    # A concurrent reactivation/reschedule wins over this remote delete. Take a
    # short write lock, inspect the latest desired state, and queue convergence
    # rather than overwriting it with a stale local cancellation.
    await db.execute("BEGIN IMMEDIATE")
    current_plan = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
        include_deleted=True,
    )
    current_publication = await _publication_row(
        db, user=user, planned_session_id=planned_session_id
    )
    if current_publication is None:
        await db.commit()
        return _publication_response(planned_session_id, operation="cancelled")
    publication_changed = int(current_publication["revision"]) != int(
        existing["revision"]
    )
    newer_plan_revision = int(current_plan["revision"]) != int(
        existing["source_revision"]
    )
    preserve_publish = bool(
        _desired_action_for_plan(current_plan) == "publish"
        and (
            newer_plan_revision
            or (
                publication_changed
                and current_publication["desired_action"] == "publish"
            )
        )
    )
    await save_history(
        db,
        "health_intervals_publications",
        current_publication["id"],
        user["id"],
        family_id=user["family_id"],
        excluded_fields={"payload_json"},
    )
    if preserve_publish:
        await db.execute(
            "UPDATE health_intervals_publications SET state = 'pending', "
            "desired_action = 'publish', source_revision = ?, next_retry_at = ?, "
            "last_attempt_at = ?, last_error_code = NULL, updated_at = ?, "
            "revision = revision + 1 WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (
                int(current_plan["revision"]),
                _utc_text(observed_at),
                _utc_text(observed_at),
                _utc_text(observed_at),
                current_publication["id"],
                user["family_id"],
                user["id"],
            ),
        )
    else:
        await db.execute(
            "UPDATE health_intervals_publications SET state = 'cancelled', "
            "desired_action = 'cancel', payload_json = NULL, "
            "mapping_warnings_json = '[]', push_errors_json = '[]', "
            "last_attempt_at = ?, next_retry_at = NULL, attempt_count = 0, "
            "last_error_code = NULL, updated_at = ?, revision = revision + 1 "
            "WHERE id = ? AND family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL",
            (
                _utc_text(observed_at),
                _utc_text(observed_at),
                current_publication["id"],
                user["family_id"],
                user["id"],
            ),
        )
    await db.commit()
    row = await _publication_row(db, user=user, planned_session_id=planned_session_id)
    return _publication_response(planned_session_id, row, operation="cancelled")


async def queue_planned_session_delivery(
    db, *, user: dict, planned_session_id: str
) -> None:
    """Queue a previously published run after a local edit; never call the provider."""
    publication = await _publication_row(
        db, user=user, planned_session_id=planned_session_id
    )
    if publication is None:
        return
    plan = await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
        include_deleted=True,
    )
    desired_action = _desired_action_for_plan(plan)
    if desired_action is None:
        return
    source_revision = int(plan["revision"])
    if publication["state"] == "cancelled" and desired_action == "cancel":
        return
    if (
        publication["state"] == "pending"
        and publication["desired_action"] == desired_action
        and int(publication["source_revision"]) == source_revision
    ):
        return
    observed_at = _utc_text()
    await save_history(
        db,
        "health_intervals_publications",
        publication["id"],
        user["id"],
        family_id=user["family_id"],
        excluded_fields={"payload_json"},
    )
    await db.execute(
        "UPDATE health_intervals_publications SET state = 'pending', "
        "desired_action = ?, source_revision = ?, next_retry_at = ?, "
        "last_error_code = NULL, updated_at = ?, revision = revision + 1 "
        "WHERE id = ? AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
        (
            desired_action,
            source_revision,
            observed_at,
            observed_at,
            publication["id"],
            user["family_id"],
            user["id"],
        ),
    )


async def delivery_status(
    db, *, user: dict, planned_session_id: str, refresh: bool = False
) -> dict:
    await owned_row(
        db,
        table="health_planned_sessions",
        record_id=planned_session_id,
        user=user,
        include_deleted=True,
    )
    publication = await _publication_row(
        db, user=user, planned_session_id=planned_session_id
    )
    if publication is None:
        return _publication_response(planned_session_id)
    if (
        refresh
        and publication["state"] == "sent"
        and publication["provider_event_id"]
        and configured()
    ):
        try:
            connection = await _connection_for_user(
                db, user=user, require_connected=True
            )
            credential = _decrypt_credential(connection)
            event = await _intervals_request(
                "GET",
                f"/athlete/0/events/{publication['provider_event_id']}",
                credential=credential,
            )
            if isinstance(event, dict):
                push_errors = _sanitised_push_errors(event.get("push_errors"))
                if push_errors != _sanitised_push_errors(
                    _parse_json(publication["push_errors_json"], [])
                ):
                    observed_at = _utc_text()
                    await save_history(
                        db,
                        "health_intervals_publications",
                        publication["id"],
                        user["id"],
                        family_id=user["family_id"],
                        excluded_fields={"payload_json"},
                    )
                    await db.execute(
                        "UPDATE health_intervals_publications SET push_errors_json = ?, "
                        "updated_at = ?, revision = revision + 1 WHERE id = ? "
                        "AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
                        (
                            json_text(push_errors),
                            observed_at,
                            publication["id"],
                            user["family_id"],
                            user["id"],
                        ),
                    )
                    await db.commit()
                    publication = await _publication_row(
                        db, user=user, planned_session_id=planned_session_id
                    )
        except (IntervalsError, httpx.HTTPError):
            # Cached delivery state remains useful when a bounded refresh fails.
            pass
    return _publication_response(planned_session_id, publication)


async def process_pending_deliveries() -> int:
    """Retry a bounded batch of queued workout updates/cancellations."""
    if not configured():
        return 0
    completed = 0
    async with standalone_db() as db:
        observed_at = _utc_text()
        rows = await (
            await db.execute(
                "SELECT publication.id AS publication_id, "
                "publication.owner_user_id AS publication_owner_user_id, "
                "publication.family_id AS publication_family_id, "
                "publication.planned_session_id, publication.desired_action, "
                "user.name AS user_name, user.email AS user_email, "
                "user.role AS user_role, user.priority AS user_priority "
                "FROM health_intervals_publications "
                "publication JOIN health_intervals_connections connection "
                "ON connection.id = publication.connection_id "
                "AND connection.owner_user_id = publication.owner_user_id "
                "AND connection.family_id = publication.family_id "
                "AND connection.status = 'connected' AND connection.deleted_at IS NULL "
                "JOIN users user ON user.id = publication.owner_user_id "
                "AND user.family_id = publication.family_id AND user.deleted_at IS NULL "
                "WHERE publication.state IN ('pending','error') "
                "AND (publication.next_retry_at IS NULL OR publication.next_retry_at <= ?) "
                "AND publication.attempt_count < ? AND publication.deleted_at IS NULL "
                "ORDER BY publication.next_retry_at, publication.updated_at LIMIT ?",
                (observed_at, MAX_SCHEDULED_RETRIES, MAX_SCHEDULED_RETRIES),
            )
        ).fetchall()
        for raw in rows:
            user = {
                "id": raw["publication_owner_user_id"],
                "family_id": raw["publication_family_id"],
                "name": raw["user_name"],
                "email": raw["user_email"],
                "role": raw["user_role"],
                "priority": raw["user_priority"],
            }
            try:
                if raw["desired_action"] == "cancel":
                    await cancel_workout(
                        db,
                        user=user,
                        planned_session_id=raw["planned_session_id"],
                        force=True,
                    )
                else:
                    await publish_workout(
                        db,
                        user=user,
                        planned_session_id=raw["planned_session_id"],
                        force=True,
                    )
                completed += 1
            except (IntervalsError, FitnessConflictError, FitnessNotFoundError):
                if db.in_transaction:
                    await db.rollback()
                continue
    return completed


async def process_enabled_activity_imports() -> int:
    """Check each owner who has switched on Garmin activity imports."""
    if not configured():
        return 0
    completed = 0
    async with standalone_db() as db:
        rows = await (
            await db.execute(
                "SELECT connection.owner_user_id, connection.family_id, "
                "user.name AS user_name, user.email AS user_email, "
                "user.role AS user_role, user.priority AS user_priority "
                "FROM health_intervals_connections connection JOIN users user "
                "ON user.id = connection.owner_user_id "
                "AND user.family_id = connection.family_id AND user.deleted_at IS NULL "
                "WHERE connection.status = 'connected' "
                "AND connection.activity_import_enabled = 1 "
                "AND connection.encrypted_token_json IS NOT NULL "
                "AND connection.deleted_at IS NULL ORDER BY connection.updated_at LIMIT 50"
            )
        ).fetchall()
        for raw in rows:
            user = {
                "id": raw["owner_user_id"],
                "family_id": raw["family_id"],
                "name": raw["user_name"],
                "email": raw["user_email"],
                "role": raw["user_role"],
                "priority": raw["user_priority"],
            }
            try:
                await sync_activity_imports(db, user=user)
                completed += 1
            except (IntervalsError, FitnessConflictError, FitnessNotFoundError):
                if db.in_transaction:
                    await db.rollback()
                continue
    return completed
