"""Owner-bound Strava OAuth and coaching-grade activity import."""

from __future__ import annotations

import hashlib
import json
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlencode
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx

from app.config import settings
from app.services.fitness import activities
from app.services.fitness.common import insert_owned, json_text, new_id, update_owned
from app.services.fitness.strava_enrichment import (
    PARSER_VERSION as STRAVA_DETAIL_PARSER_VERSION,
    StravaEnrichment,
    decode_polyline,
    persist_enrichment,
    prepare_enrichment,
)
from app.services.record_history import save_history
from app.utils.encryption import decrypt_value, encrypt_value


STRAVA_API_BASE = "https://www.strava.com/api/v3"
STRAVA_AUTHORIZE_URL = "https://www.strava.com/oauth/authorize"
STRAVA_TOKEN_URL = "https://www.strava.com/oauth/token"
STRAVA_REVOKE_URL = "https://www.strava.com/oauth/revoke"
OAUTH_STATE_TTL = timedelta(minutes=10)
INITIAL_LOOKBACK = timedelta(days=30)
SYNC_OVERLAP = timedelta(days=7)
TOKEN_REFRESH_MARGIN = timedelta(hours=1)
PROVIDER_TIMEOUT_SECONDS = 12.0
MAX_PAGES = 4
PAGE_SIZE = 100
MAX_DETAILED_ACTIVITIES_PER_SYNC = 40
DETAILED_SOURCE_PARSER_VERSION = "3"
STREAM_KEYS = (
    "time,distance,latlng,altitude,velocity_smooth,heartrate,cadence,watts,"
    "temp,moving,grade_smooth"
)


class StravaError(ValueError):
    pass


class StravaNotConfiguredError(StravaError):
    pass


class StravaConnectionNotFoundError(StravaError):
    pass


class StravaStateError(StravaError):
    pass


class StravaAuthorizationError(StravaError):
    pass


class StravaProviderError(StravaError):
    pass


class StravaOAuthCompletionError(StravaError):
    def __init__(self, surface: str):
        self.surface = surface
        super().__init__("Strava authorisation could not be completed")


def configured() -> bool:
    return bool(settings.strava_integration_enabled) and all(
        value.strip()
        for value in (
            settings.strava_client_id,
            settings.strava_client_secret,
            settings.strava_redirect_uri,
            settings.ha_token_encryption_key,
        )
    )


def require_configured() -> None:
    if not configured():
        raise StravaNotConfiguredError("Strava is not configured on the HausKlar server")


def _utc_now(value: datetime | None = None) -> datetime:
    observed = value or datetime.now(timezone.utc)
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=timezone.utc)
    return observed.astimezone(timezone.utc)


def _utc_text(value: datetime | None = None) -> str:
    return _utc_now(value).isoformat()


def _state_digest(state: str) -> str:
    return hashlib.sha256(state.encode("utf-8")).hexdigest()


def _token_payload(value: dict[str, Any]) -> dict[str, Any]:
    access = str(value.get("access_token") or "")
    refresh = str(value.get("refresh_token") or "")
    expires = int(value.get("expires_at") or 0)
    if not access or not refresh or expires <= 0:
        raise StravaAuthorizationError("Strava returned incomplete credentials")
    return {
        "access_token": access,
        "refresh_token": refresh,
        "expires_at": expires,
        "token_type": str(value.get("token_type") or "Bearer"),
    }


def _granted_scopes(raw: str | None) -> list[str]:
    # Strava reports the athlete's granted scopes on the authorization callback,
    # not in its access-token response. Keep this separate from token parsing so
    # an omitted or reduced provider grant cannot be hidden by fabricated token
    # response data.
    scopes = [scope for scope in (raw or "").replace(",", " ").split() if scope]
    if "activity:read_all" not in scopes:
        raise StravaAuthorizationError(
            "Allow access to private activities to import your Strava history"
        )
    return sorted(set(scopes))


def _encrypt_token(value: dict[str, Any]) -> str:
    return encrypt_value(json.dumps(_token_payload(value), separators=(",", ":"), sort_keys=True))


def _decrypt_token(connection) -> dict[str, Any]:
    encrypted = connection["encrypted_token_json"]
    if not encrypted:
        raise StravaConnectionNotFoundError("Reconnect Strava to import activities")
    try:
        value = json.loads(decrypt_value(encrypted))
    except Exception as exc:
        raise StravaConnectionNotFoundError("Reconnect Strava to import activities") from exc
    if not isinstance(value, dict):
        raise StravaConnectionNotFoundError("Reconnect Strava to import activities")
    return _token_payload(value)


async def _token_request(form: dict[str, str]) -> dict[str, Any]:
    try:
        async with httpx.AsyncClient(timeout=PROVIDER_TIMEOUT_SECONDS) as client:
            response = await client.post(STRAVA_TOKEN_URL, data=form, headers={"Accept": "application/json"})
    except httpx.HTTPError as exc:
        raise StravaProviderError("Strava could not be reached") from exc
    if response.status_code in {400, 401, 403}:
        raise StravaAuthorizationError("Strava rejected the authorisation")
    if response.status_code < 200 or response.status_code >= 300:
        raise StravaProviderError("Strava rejected the request")
    try:
        payload = response.json()
    except ValueError as exc:
        raise StravaProviderError("Strava returned malformed JSON") from exc
    if not isinstance(payload, dict):
        raise StravaProviderError("Strava returned malformed JSON")
    return payload


async def _strava_request(token: str, path: str) -> Any:
    if not path.startswith("/") or "//" in path:
        raise StravaProviderError("Strava request path is invalid")
    try:
        async with httpx.AsyncClient(timeout=PROVIDER_TIMEOUT_SECONDS) as client:
            response = await client.get(
                f"{STRAVA_API_BASE}{path}",
                headers={"Accept": "application/json", "Authorization": f"Bearer {token}"},
            )
    except httpx.HTTPError as exc:
        raise StravaProviderError("Strava could not be reached") from exc
    if response.status_code in {401, 403}:
        raise StravaAuthorizationError("Strava rejected the token")
    if response.status_code < 200 or response.status_code >= 300:
        raise StravaProviderError("Strava rejected the request")
    try:
        return response.json()
    except ValueError as exc:
        raise StravaProviderError("Strava returned malformed JSON") from exc


async def _connection(db, *, user: dict, require_connected: bool = False):
    row = await (
        await db.execute(
            "SELECT * FROM health_strava_connections WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None or (
        require_connected and row["status"] not in {"connected", "provider_down"}
    ):
        raise StravaConnectionNotFoundError("Connect Strava before importing activities")
    return row


async def connection_status(db, *, user: dict) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM health_strava_connections WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    is_configured = configured()
    status = "not_configured" if not is_configured else "not_connected" if row is None else row["status"]
    connected = bool(
        is_configured
        and row is not None
        and status in {"connected", "provider_down"}
    )
    count = 0
    if row is not None and row["athlete_id"]:
        namespace = f"strava:{row['athlete_id']}"
        result = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_source_records WHERE family_id = ? "
                "AND owner_user_id = ? AND record_kind = 'activity' "
                "AND transport_key = 'strava_api' AND source_namespace = ? "
                "AND state = 'active' AND deleted_at IS NULL",
                (user["family_id"], user["id"], namespace),
            )
        ).fetchone()
        count = int(result[0]) if result else 0
    return {
        "configured": is_configured,
        "connected": connected,
        "status": status,
        "athlete_name": row["athlete_name"] if connected else None,
        "last_sync_at": row["last_sync_at"] if row is not None else None,
        "data_through_at": row["data_through_at"] if row is not None else None,
        "imported_activity_count": count,
        "last_error_code": row["last_error_code"] if row is not None else None,
    }


def callback_return_url(surface: str, outcome: str) -> str:
    safe = outcome if outcome in {"connected", "cancelled", "failed"} else "failed"
    if surface == "app":
        return f"hausklar://fitness/strava?status={safe}"
    return f"{settings.web_app_url.strip().rstrip('/')}/?{urlencode({'view': 'fitness', 'section': 'training', 'strava': safe})}"


async def start_authorization(
    db, *, user: dict, return_surface: str, now: datetime | None = None
) -> tuple[str, datetime]:
    require_configured()
    observed = _utc_now(now)
    expires = observed + OAUTH_STATE_TTL
    state = secrets.token_urlsafe(40)
    await insert_owned(
        db,
        table="health_strava_oauth_states",
        record_id=str(uuid.uuid4()),
        values={
            "state_digest": _state_digest(state),
            "return_surface": return_surface,
            "expires_at": _utc_text(expires),
            "consumed_at": None,
            "revision": 1,
        },
        user=user,
        now=_utc_text(observed),
        record_sync_change=False,
    )
    await db.commit()
    query = urlencode(
        {
            "client_id": settings.strava_client_id.strip(),
            "redirect_uri": settings.strava_redirect_uri.strip(),
            "response_type": "code",
            "approval_prompt": "auto",
            "scope": "activity:read_all",
            "state": state,
        }
    )
    return f"{STRAVA_AUTHORIZE_URL}?{query}", expires


async def _claim_state(db, *, state: str, now: datetime | None = None) -> tuple[dict, str]:
    observed = _utc_now(now)
    row = await (
        await db.execute(
            "SELECT oauth.*, user.name AS user_name, user.email AS user_email, "
            "user.role AS user_role, user.priority AS user_priority "
            "FROM health_strava_oauth_states oauth JOIN users user "
            "ON user.id = oauth.owner_user_id AND user.family_id = oauth.family_id "
            "AND user.deleted_at IS NULL WHERE oauth.state_digest = ? "
            "AND oauth.consumed_at IS NULL AND oauth.deleted_at IS NULL LIMIT 1",
            (_state_digest(state),),
        )
    ).fetchone()
    if row is None:
        raise StravaStateError("Strava authorisation state is absent or expired")
    try:
        expires = _utc_now(datetime.fromisoformat(str(row["expires_at"]).replace("Z", "+00:00")))
    except (TypeError, ValueError) as exc:
        raise StravaStateError("Strava authorisation state is absent or expired") from exc
    if expires <= observed:
        raise StravaStateError("Strava authorisation state is absent or expired")
    claimed = await db.execute(
        "UPDATE health_strava_oauth_states SET consumed_at = ?, updated_at = ?, "
        "revision = revision + 1 WHERE id = ? AND consumed_at IS NULL AND deleted_at IS NULL",
        (_utc_text(observed), _utc_text(observed), row["id"]),
    )
    if claimed.rowcount != 1:
        raise StravaStateError("Strava authorisation state was already used")
    await db.commit()
    return {
        "id": row["owner_user_id"],
        "family_id": row["family_id"],
        "name": row["user_name"],
        "email": row["user_email"],
        "role": row["user_role"],
        "priority": row["user_priority"],
    }, row["return_surface"]


def _athlete_name(athlete: dict[str, Any]) -> str:
    value = " ".join(str(athlete.get(key) or "").strip() for key in ("firstname", "lastname")).strip()
    return value or "Strava athlete"


async def _store_connection(
    db,
    *,
    user: dict,
    token: dict[str, Any],
    athlete: dict[str, Any],
    scopes: list[str],
) -> None:
    athlete_id = str(athlete.get("id") or "")
    if not athlete_id:
        raise StravaAuthorizationError("Strava did not identify the athlete")
    collision = await (
        await db.execute(
            "SELECT owner_user_id FROM health_strava_connections WHERE athlete_id = ? "
            "AND status <> 'disconnected' AND deleted_at IS NULL LIMIT 1",
            (athlete_id,),
        )
    ).fetchone()
    if collision is not None and collision["owner_user_id"] != user["id"]:
        raise StravaError("That Strava athlete is already connected to another HausKlar account")
    existing = await (
        await db.execute(
            "SELECT * FROM health_strava_connections WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    values = {
        "athlete_id": athlete_id,
        "athlete_name": _athlete_name(athlete),
        "status": "connected",
        "scopes_json": scopes,
        "encrypted_token_json": _encrypt_token(token),
        "access_token_expires_at": _utc_text(datetime.fromtimestamp(int(token["expires_at"]), timezone.utc)),
        "last_error_code": None,
    }
    if existing is None:
        await insert_owned(
            db,
            table="health_strava_connections",
            record_id=new_id(),
            values={**values, "last_sync_at": None, "data_through_at": None, "revision": 1},
            user=user,
            record_sync_change=False,
        )
    else:
        await update_owned(
            db,
            table="health_strava_connections",
            record_id=existing["id"],
            values=values,
            user=user,
            restore=True,
            record_sync_change=False,
        )
    await db.commit()


async def complete_authorization(
    db,
    *,
    state: str,
    code: str,
    granted_scope: str | None,
) -> str:
    require_configured()
    user, surface = await _claim_state(db, state=state)
    try:
        scopes = _granted_scopes(granted_scope)
        response = await _token_request(
            {
                "client_id": settings.strava_client_id.strip(),
                "client_secret": settings.strava_client_secret.strip(),
                "code": code,
                "grant_type": "authorization_code",
            }
        )
        token = _token_payload(response)
        athlete = response.get("athlete")
        if not isinstance(athlete, dict):
            raise StravaAuthorizationError("Strava did not identify the athlete")
        await _store_connection(
            db, user=user, token=token, athlete=athlete, scopes=scopes
        )
        try:
            await sync_activities(db, user=user)
        except StravaError:
            # The connection is useful even if the first provider read is briefly unavailable.
            pass
    except Exception as exc:
        raise StravaOAuthCompletionError(surface) from exc
    return surface


async def consume_cancelled_authorization(db, *, state: str) -> str:
    _, surface = await _claim_state(db, state=state)
    return surface


async def _fresh_token(db, *, user: dict, connection) -> tuple[Any, dict[str, Any]]:
    token = _decrypt_token(connection)
    expires = datetime.fromtimestamp(int(token["expires_at"]), timezone.utc)
    if expires > _utc_now() + TOKEN_REFRESH_MARGIN:
        return connection, token
    response = await _token_request(
        {
            "client_id": settings.strava_client_id.strip(),
            "client_secret": settings.strava_client_secret.strip(),
            "grant_type": "refresh_token",
            "refresh_token": str(token["refresh_token"]),
        }
    )
    refreshed = _token_payload(response)
    await update_owned(
        db,
        table="health_strava_connections",
        record_id=connection["id"],
        values={
            "encrypted_token_json": _encrypt_token(refreshed),
            "access_token_expires_at": _utc_text(datetime.fromtimestamp(int(refreshed["expires_at"]), timezone.utc)),
            "status": "connected",
            "last_error_code": None,
        },
        user=user,
        record_sync_change=False,
    )
    await db.commit()
    return await _connection(db, user=user, require_connected=True), refreshed


SPORT_MAP = {
    "Run": "running", "VirtualRun": "running", "TrailRun": "running",
    "Walk": "walking", "Hike": "hiking",
    "Ride": "cycling", "VirtualRide": "cycling", "GravelRide": "cycling",
    "EBikeRide": "cycling", "MountainBikeRide": "cycling",
    "WeightTraining": "strength", "Crossfit": "strength",
    "Rowing": "rowing_water", "VirtualRow": "rowing_indoor",
    "Swim": "swimming_open_water",
}


def _sport(activity: dict[str, Any]) -> str:
    return SPORT_MAP.get(str(activity.get("sport_type") or activity.get("type") or ""), "other")


def _timezone(activity: dict[str, Any]) -> str:
    raw = str(activity.get("timezone") or "")
    candidate = raw.rsplit(" ", 1)[-1].strip()
    try:
        ZoneInfo(candidate)
        return candidate
    except ZoneInfoNotFoundError:
        return "UTC"


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if number >= 0 else None


def _summary_fingerprint(activity: dict[str, Any]) -> str:
    map_value = activity.get("map") if isinstance(activity.get("map"), dict) else {}
    payload = {
        key: activity.get(key)
        for key in (
            "id", "name", "sport_type", "type", "start_date", "timezone",
            "elapsed_time", "moving_time", "distance", "calories",
            "total_elevation_gain", "average_speed", "max_speed",
            "has_heartrate", "average_heartrate", "max_heartrate",
            "average_cadence", "average_watts", "max_watts", "device_name",
            "trainer", "commute", "manual", "private",
        )
    }
    payload["summary_polyline"] = map_value.get("summary_polyline")
    return hashlib.sha256(json_text(payload).encode("utf-8")).hexdigest()


async def _needs_detailed_import(
    db, *, user: dict, connection, remote: dict[str, Any]
) -> bool:
    remote_id = str(remote.get("id") or "")
    namespace = f"strava:{connection['athlete_id']}"
    row = await (
        await db.execute(
            "SELECT s.parser_version, s.metadata_json, a.primary_stream_asset_id "
            "FROM health_source_records s LEFT JOIN health_activities a "
            "ON a.id = s.domain_entity_id AND a.family_id = s.family_id "
            "AND a.owner_user_id = s.owner_user_id AND a.deleted_at IS NULL "
            "WHERE s.family_id = ? AND s.owner_user_id = ? "
            "AND s.transport_key = 'strava_api' AND s.source_namespace = ? "
            "AND s.source_object_id = ? AND s.deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], namespace, remote_id),
        )
    ).fetchone()
    if row is None or row["parser_version"] != DETAILED_SOURCE_PARSER_VERSION:
        return True
    try:
        metadata = json.loads(row["metadata_json"] or "{}")
    except (TypeError, json.JSONDecodeError):
        return True
    return metadata.get("summary_fingerprint") != _summary_fingerprint(remote)


async def _heart_rate_boundaries(db, *, user: dict) -> list[int]:
    row = await (
        await db.execute(
            "SELECT heart_rate_zone_boundaries_bpm_json FROM health_user_settings "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    try:
        values = json.loads(row["heart_rate_zone_boundaries_bpm_json"] if row else "[120,140,155,170]")
    except (TypeError, json.JSONDecodeError):
        values = [120, 140, 155, 170]
    return values if isinstance(values, list) else [120, 140, 155, 170]


async def _detailed_activity(
    token: str,
    remote: dict[str, Any],
    *,
    heart_rate_boundaries: list[int],
) -> tuple[dict[str, Any], StravaEnrichment] | None:
    remote_id = str(remote.get("id") or "")
    try:
        detail = await _strava_request(
            token, f"/activities/{remote_id}?include_all_efforts=false"
        )
    except StravaProviderError:
        return None
    if not isinstance(detail, dict):
        return None
    try:
        query = urlencode({"keys": STREAM_KEYS, "key_by_type": "true"})
        streams = await _strava_request(token, f"/activities/{remote_id}/streams?{query}")
    except StravaProviderError:
        # Do not replace a previously imported stream after a transient detail
        # failure. Leaving this source at v1 makes the next pull retry it.
        return None
    merged = {**remote, **detail}
    return merged, prepare_enrichment(
        merged,
        streams,
        heart_rate_zone_boundaries_bpm=heart_rate_boundaries,
    )


def _activity_values(
    activity: dict[str, Any],
    *,
    source_id: str,
    enrichment: StravaEnrichment | None = None,
    summary_fingerprint: str | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        started = _utc_now(datetime.fromisoformat(str(activity["start_date"]).replace("Z", "+00:00")))
    except (KeyError, TypeError, ValueError) as exc:
        raise StravaProviderError("Strava returned an activity without a valid start time") from exc
    elapsed = _number(activity.get("elapsed_time"))
    moving = _number(activity.get("moving_time"))
    duration = elapsed if elapsed and elapsed > 0 else moving
    ended = started + timedelta(seconds=duration) if duration else None
    zone_name = _timezone(activity)
    zone = ZoneInfo(zone_name)
    sport = _sport(activity)
    title = str(activity.get("name") or "").strip()[:200] or sport.replace("_", " ").title()
    map_value = activity.get("map") if isinstance(activity.get("map"), dict) else {}
    route_preview = (
        enrichment.route_preview
        if enrichment is not None
        else decode_polyline(map_value.get("summary_polyline"))
    )
    values = {
        "sport_key": sport,
        "sub_sport_key": str(activity.get("sport_type") or "")[:80] or None,
        "title": title,
        "status": "completed",
        "primary_source_record_id": source_id,
        "started_at_utc": started,
        "ended_at_utc": ended,
        "local_timezone": zone_name,
        "local_calendar_date": started.astimezone(zone).date(),
        "elapsed_duration_s": elapsed,
        "timer_duration_s": moving,
        "moving_duration_s": moving,
        "distance_m": _number(activity.get("distance")),
        "energy_kcal": _number(activity.get("calories")),
        "measurement_quality": "measured",
        "import_state": "complete",
        "parser_version": STRAVA_DETAIL_PARSER_VERSION if enrichment is not None else "strava-summary-v1",
        "route_preview_json": json_text(route_preview) if route_preview else None,
        "revision": 1,
    }
    metadata = {
        "strava_activity_id": str(activity.get("id")),
        "sport_type": str(activity.get("sport_type") or activity.get("type") or ""),
        "trainer": bool(activity.get("trainer")),
        "commute": bool(activity.get("commute")),
        "manual": bool(activity.get("manual")),
        "private": bool(activity.get("private")),
        "device_name": str(activity.get("device_name") or "")[:200] or None,
        # DetailedActivity contains fields (for example calories) that are not
        # present in the list response. Persist the fingerprint of the list
        # representation so an unchanged run does not fetch all detail again.
        "summary_fingerprint": summary_fingerprint or _summary_fingerprint(activity),
        "detail_imported": enrichment is not None,
        "stream_imported": bool(enrichment and enrichment.has_stream),
        "lap_count": sum(
            interval.get("interval_kind") == "source_lap"
            for interval in enrichment.intervals
        ) if enrichment else 0,
    }
    return values, metadata


async def _upsert_activity(
    db,
    *,
    user: dict,
    connection,
    remote: dict[str, Any],
    enrichment: StravaEnrichment | None = None,
    summary_fingerprint: str | None = None,
) -> tuple[str, dict[str, Any]]:
    remote_id = str(remote.get("id") or "")
    if not remote_id or len(remote_id) > 100:
        raise StravaProviderError("Strava returned an invalid activity identifier")
    namespace = f"strava:{connection['athlete_id']}"
    source = await (
        await db.execute(
            "SELECT * FROM health_source_records WHERE family_id = ? AND owner_user_id = ? "
            "AND record_kind = 'activity' AND transport_key = 'strava_api' "
            "AND source_namespace = ? AND source_object_id = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], namespace, remote_id),
        )
    ).fetchone()
    source_id = source["id"] if source is not None else new_id()
    activity_values, metadata = _activity_values(
        remote,
        source_id=source_id,
        enrichment=enrichment,
        summary_fingerprint=summary_fingerprint,
    )
    activity_id = source["domain_entity_id"] if source is not None else None
    existing_activity = None
    if activity_id:
        existing_activity = await (
            await db.execute(
                "SELECT * FROM health_activities WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ? LIMIT 1",
                (activity_id, user["family_id"], user["id"]),
            )
        ).fetchone()
    preserve_enrichment = bool(
        enrichment is None
        and source is not None
        and str(source["parser_version"] or "") not in {"", "1"}
        and existing_activity is not None
    )
    preserve_existing_stream = bool(
        enrichment is not None
        and not enrichment.has_stream
        and existing_activity is not None
        and existing_activity["primary_stream_asset_id"] is not None
    )
    if preserve_enrichment or preserve_existing_stream:
        activity_values["parser_version"] = existing_activity["parser_version"]
        activity_values["route_preview_json"] = existing_activity["route_preview_json"]
        if remote.get("calories") is None:
            activity_values["energy_kcal"] = existing_activity["energy_kcal"]
        try:
            stored_metadata = json.loads(source["metadata_json"] or "{}")
        except (TypeError, json.JSONDecodeError):
            stored_metadata = {}
        if isinstance(stored_metadata, dict):
            if preserve_enrichment:
                # Keep the old fingerprint until a bounded detailed-import slot
                # is available, without discarding imported detail meanwhile.
                metadata.update(stored_metadata)
            else:
                # An empty replacement stream is not evidence that valid stored
                # samples disappeared. Retain them and retry this fingerprint.
                metadata["summary_fingerprint"] = stored_metadata.get(
                    "summary_fingerprint"
                )
                metadata["stream_imported"] = True
    if existing_activity is None:
        activity_id = new_id()
        await insert_owned(
            db, table="health_activities", record_id=activity_id,
            values=activity_values, user=user, record_sync_change=False,
        )
        operation = "created"
    else:
        comparable = {key: activity_values[key] for key in activity_values if key != "revision"}
        unchanged = all(
            existing_activity[key] == (value.isoformat() if hasattr(value, "isoformat") else int(value) if isinstance(value, bool) else value)
            for key, value in comparable.items()
        )
        if unchanged and source is not None and enrichment is None:
            return "unchanged", {
                "id": activity_id, "title": activity_values["title"], "sport_key": activity_values["sport_key"],
                "started_at_utc": activity_values["started_at_utc"], "duration_s": activity_values["moving_duration_s"],
                "distance_m": activity_values["distance_m"],
            }
        await update_owned(
            db, table="health_activities", record_id=activity_id,
            values=comparable, user=user, restore=True, record_sync_change=False,
        )
        operation = "updated"
    source_values = {
        "record_kind": "activity", "sample_type": "workout",
        "transport_key": "strava_api", "origin_provider_key": "strava",
        "source_namespace": namespace, "source_object_id": remote_id,
        "external_object_id": remote_id, "source_name": "Strava",
        "source_device_identifier": metadata.get("device_name"),
        "metadata_json": metadata, "domain_entity_type": "activity",
        "domain_entity_id": activity_id, "source_created_at_utc": activity_values["started_at_utc"],
        "state": "active",
        "parser_name": "strava_activity" if enrichment is not None or preserve_enrichment else "strava_summary",
        "parser_version": (
            DETAILED_SOURCE_PARSER_VERSION
            if enrichment is not None
            else str(source["parser_version"])
            if preserve_enrichment and source is not None
            else "1"
        ),
        "revision": 1,
    }
    if source is None:
        await insert_owned(
            db, table="health_source_records", record_id=source_id,
            values=source_values, user=user, record_sync_change=False,
        )
    else:
        source_values.pop("revision")
        await update_owned(
            db, table="health_source_records", record_id=source_id,
            values=source_values, user=user, restore=True, record_sync_change=False,
        )
    link = await (
        await db.execute(
            "SELECT id FROM health_activity_source_records WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND source_record_id = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], activity_id, source_id),
        )
    ).fetchone()
    if link is None:
        await insert_owned(
            db, table="health_activity_source_records", record_id=new_id(),
            values={"activity_id": activity_id, "source_record_id": source_id, "role": "primary", "revision": 1},
            user=user, record_sync_change=False,
        )
    if enrichment is not None:
        await persist_enrichment(
            db, user=user, activity_id=activity_id, enrichment=enrichment
        )
    if operation in {"created", "updated"}:
        await activities.auto_match_activity(
            db, user=user, activity_id=activity_id, record_activity_sync_change=False
        )
    return operation, {
        "id": activity_id, "title": activity_values["title"], "sport_key": activity_values["sport_key"],
        "started_at_utc": activity_values["started_at_utc"], "duration_s": activity_values["moving_duration_s"],
        "distance_m": activity_values["distance_m"],
    }


async def sync_activities(db, *, user: dict, now: datetime | None = None) -> dict:
    require_configured()
    connection = await _connection(db, user=user, require_connected=True)
    try:
        connection, token = await _fresh_token(db, user=user, connection=connection)
        observed = _utc_now(now)
        namespace = f"strava:{connection['athlete_id']}"
        pending_backfill = await (
            await db.execute(
                "SELECT 1 FROM health_source_records s JOIN health_activities a "
                "ON a.id = s.domain_entity_id AND a.family_id = s.family_id "
                "AND a.owner_user_id = s.owner_user_id AND a.deleted_at IS NULL "
                "WHERE s.family_id = ? AND s.owner_user_id = ? "
                "AND s.transport_key = 'strava_api' AND s.source_namespace = ? "
                "AND COALESCE(s.parser_version, '1') <> ? "
                "AND a.started_at_utc >= ? AND s.deleted_at IS NULL LIMIT 1",
                (
                    user["family_id"], user["id"], namespace,
                    DETAILED_SOURCE_PARSER_VERSION,
                    _utc_text(observed - INITIAL_LOOKBACK),
                ),
            )
        ).fetchone()
        if connection["last_sync_at"] and pending_backfill is None:
            previous = _utc_now(datetime.fromisoformat(str(connection["last_sync_at"]).replace("Z", "+00:00")))
            after = previous - SYNC_OVERLAP
        else:
            after = observed - INITIAL_LOOKBACK
        rows: list[dict[str, Any]] = []
        for page in range(1, MAX_PAGES + 1):
            payload = await _strava_request(
                str(token["access_token"]),
                f"/athlete/activities?after={int(after.timestamp())}&page={page}&per_page={PAGE_SIZE}",
            )
            if not isinstance(payload, list):
                raise StravaProviderError("Strava returned malformed activity data")
            page_rows = [item for item in payload if isinstance(item, dict)]
            rows.extend(page_rows)
            if len(page_rows) < PAGE_SIZE:
                break
        counts = {"created": 0, "updated": 0, "unchanged": 0}
        latest = None
        latest_started = None
        detailed_attempts = 0
        heart_rate_boundaries = await _heart_rate_boundaries(db, user=user)
        # Spend the bounded detail/stream budget on the newest activities first,
        # so a one-tap "Pull latest" always makes the run the user just did
        # coaching-ready before older backfill continues on later pulls.
        for remote in sorted(
            rows,
            key=lambda item: str(item.get("start_date") or ""),
            reverse=True,
        ):
            summary_fingerprint = _summary_fingerprint(remote)
            imported_remote = remote
            enrichment = None
            if (
                detailed_attempts < MAX_DETAILED_ACTIVITIES_PER_SYNC
                and await _needs_detailed_import(
                    db, user=user, connection=connection, remote=remote
                )
            ):
                detailed_attempts += 1
                detailed = await _detailed_activity(
                    str(token["access_token"]),
                    remote,
                    heart_rate_boundaries=heart_rate_boundaries,
                )
                if detailed is not None:
                    imported_remote, enrichment = detailed
            operation, summary = await _upsert_activity(
                db,
                user=user,
                connection=connection,
                remote=imported_remote,
                enrichment=enrichment,
                summary_fingerprint=summary_fingerprint,
            )
            counts[operation] += 1
            started = summary["started_at_utc"]
            if latest_started is None or started > latest_started:
                latest, latest_started = summary, started
        through = latest_started or (
            _utc_now(datetime.fromisoformat(str(connection["data_through_at"]).replace("Z", "+00:00")))
            if connection["data_through_at"] else None
        )
        await update_owned(
            db, table="health_strava_connections", record_id=connection["id"],
            values={
                "status": "connected", "last_sync_at": _utc_text(observed),
                "data_through_at": _utc_text(through) if through else None,
                "last_error_code": None,
            },
            user=user, record_sync_change=False,
        )
        await db.commit()
    except StravaAuthorizationError:
        await _mark_failure(db, user=user, connection=connection, status="reauth_required", code="authorization_failed")
        raise
    except StravaProviderError:
        await _mark_failure(db, user=user, connection=connection, status="provider_down", code="provider_unavailable")
        raise
    return {
        "imported_count": counts["created"], "updated_count": counts["updated"],
        "unchanged_count": counts["unchanged"], "latest_activity": latest,
        "status": await connection_status(db, user=user),
    }


async def _mark_failure(db, *, user: dict, connection, status: str, code: str) -> None:
    await save_history(
        db, "health_strava_connections", connection["id"], user["id"],
        family_id=user["family_id"], excluded_fields={"encrypted_token_json"},
    )
    observed = _utc_text()
    await db.execute(
        "UPDATE health_strava_connections SET status = ?, last_error_code = ?, "
        "updated_at = ?, revision = revision + 1 WHERE id = ? AND family_id = ? "
        "AND owner_user_id = ? AND deleted_at IS NULL",
        (status, code, observed, connection["id"], user["family_id"], user["id"]),
    )
    await db.commit()


async def _revoke(token: str) -> None:
    try:
        async with httpx.AsyncClient(timeout=PROVIDER_TIMEOUT_SECONDS) as client:
            await client.post(
                STRAVA_REVOKE_URL,
                auth=httpx.BasicAuth(settings.strava_client_id.strip(), settings.strava_client_secret.strip()),
                data={"token": token},
            )
    except httpx.HTTPError:
        return


async def disconnect(db, *, user: dict) -> int:
    connection = await _connection(db, user=user)
    try:
        token = _decrypt_token(connection)
        await _revoke(str(token["access_token"]))
    except StravaError:
        pass
    count = await (
        await db.execute(
            "SELECT COUNT(*) FROM health_source_records WHERE family_id = ? "
            "AND owner_user_id = ? AND transport_key = 'strava_api' AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    await update_owned(
        db, table="health_strava_connections", record_id=connection["id"],
        values={
            "athlete_id": None, "athlete_name": None, "status": "disconnected",
            "encrypted_token_json": None, "access_token_expires_at": None,
            "last_error_code": None,
        },
        user=user, record_sync_change=False,
    )
    await db.commit()
    return int(count[0]) if count else 0
