from __future__ import annotations

import json
import re
from datetime import UTC, datetime, timedelta
from urllib.parse import quote

import httpx

from app.config import settings
from app.database import database_lease
from app.http_clients import provider_client
from app.models.family_settings import validate_ha_origin
from app.models.home import (
    HomeActionRequest,
    HomeBroadActionRequest,
    HomeServiceRequest,
)
from app.services.home_layout import HOME_LAYOUT
from app.services.media_thumbnails import (
    fetch_registered_thumbnail,
    register_thumbnail,
)
from app.utils.encryption import decrypt_value

READABLE_DOMAINS = {
    "binary_sensor",
    "camera",
    "climate",
    "input_select",
    "light",
    "media_player",
    "scene",
    "script",
    "select",
    "sensor",
    "switch",
    "water_heater",
    "weather",
}

ACTION_DOMAINS = {
    "turn_on": {"light", "switch"},
    "turn_off": {"light", "switch"},
    "toggle": {"light", "switch"},
    "play_pause": {"media_player"},
    "set_temperature": {"climate"},
}

ALLOWED_SERVICES = {
    "climate": {"set_hvac_mode", "set_preset_mode", "set_temperature"},
    "input_select": {"select_option"},
    "light": {"toggle", "turn_off", "turn_on"},
    "media_player": {
        "browse_media",
        "join",
        "media_next_track",
        "media_play_pause",
        "media_previous_track",
        "play_media",
        "repeat_set",
        "select_source",
        "shuffle_set",
        "turn_off",
        "turn_on",
        "unjoin",
        "volume_mute",
        "volume_set",
    },
    "scene": {"turn_on"},
    "script": {"turn_on"},
    "select": {"select_option"},
    "spotifyplus": {
        "get_album_tracks",
        "get_artist_albums",
        "get_playlist_items",
        "search_artists",
        "search_playlists",
        "search_tracks",
    },
    "switch": {"toggle", "turn_off", "turn_on"},
    "tts": {"speak"},
    "water_heater": {"set_operation_mode", "turn_off", "turn_on"},
}

SERVICE_DATA_KEYS = {
    "brightness",
    "criteria",
    "entity_id",
    "extra",
    "group_members",
    "hvac_mode",
    "include_groups",
    "limit_total",
    "media_content_id",
    "media_content_type",
    "message",
    "operation_mode",
    "option",
    "playlist_id",
    "album_id",
    "artist_id",
    "preset_mode",
    "repeat",
    "shuffle",
    "source",
    "temperature",
    "volume_level",
    "is_volume_muted",
}
ENTITY_ID_RE = re.compile(r"^[a-z0-9_]+\.[a-z0-9_]+$")
SENSITIVE_RESPONSE_KEYS = {"access_token", "authorization", "password", "refresh_token", "secret", "token"}
DEFAULT_SAFE_ACTION_DOMAINS = {"climate", "light", "media_player"}
HOME_FAVOURITES_SETTING = "home_favourite_entity_ids"
HOME_TEMPERATURE_HISTORY_HOURS = 24
HOME_TEMPERATURE_HISTORY_MAX_POINTS = 576


async def _settings(db, family_id: str) -> tuple[str, str] | None:
    cursor = await db.execute(
        """
        SELECT setting_key, setting_value
        FROM family_settings
        WHERE family_id = ? AND setting_key IN ('ha_url', 'ha_token')
        """,
        (family_id,),
    )
    values = {row["setting_key"]: row["setting_value"] for row in await cursor.fetchall()}
    if not values.get("ha_url") or not values.get("ha_token"):
        return None
    ha_url = validate_ha_origin(values["ha_url"], settings.ha_allowed_origins)
    return ha_url.rstrip("/"), decrypt_value(values["ha_token"])


async def _favourite_ids(db, family_id: str) -> set[str] | None:
    cursor = await db.execute(
        "SELECT setting_value FROM family_settings "
        "WHERE family_id = ? AND setting_key = ?",
        (family_id, HOME_FAVOURITES_SETTING),
    )
    row = await cursor.fetchone()
    if row is None:
        return None
    try:
        value = json.loads(row[0])
    except (TypeError, ValueError):
        return set()
    if not isinstance(value, list):
        return set()
    return {
        item
        for item in value[:12]
        if isinstance(item, str) and ENTITY_ID_RE.fullmatch(item)
    }


def _normalise_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def _point_in_polygon(
    point: tuple[float, float],
    polygon: list[tuple[float, float]],
) -> bool:
    x, y = point
    inside = False
    previous = polygon[-1]
    for current in polygon:
        x1, y1 = previous
        x2, y2 = current
        crosses = (y1 > y) != (y2 > y)
        if crosses and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            inside = not inside
        previous = current
    return inside


def _room_for_point(floor_id: int, point: tuple[float, float]):
    floor = next((item for item in HOME_LAYOUT.floors if item.id == floor_id), None)
    if floor is None:
        return None
    matches = []
    for room in floor.rooms:
        bounds = room.bounds
        inside_bounds = (
            bounds.x <= point[0] <= bounds.x + bounds.width
            and bounds.y <= point[1] <= bounds.y + bounds.height
        )
        if not inside_bounds:
            continue
        if room.polygon and not _point_in_polygon(point, room.polygon):
            continue
        matches.append(room)
    if not matches:
        return None
    return min(matches, key=lambda item: item.bounds.width * item.bounds.height)


def _room_catalogue() -> tuple[list[dict], dict[str, tuple[str, str]]]:
    rooms: list[dict] = []
    entity_rooms: dict[str, tuple[str, str]] = {}
    for floor in HOME_LAYOUT.floors:
        for room in floor.rooms:
            rooms.append(
                {
                    "id": room.id,
                    "name": room.label,
                    "floor": floor.id,
                    "entity_ids": [],
                    "light_entity_ids": list(room.light_entity_ids),
                }
            )
            for entity_id in room.light_entity_ids:
                entity_rooms[entity_id] = (room.id, room.label)

    for marker in [*HOME_LAYOUT.temperatures, *HOME_LAYOUT.doors]:
        room = _room_for_point(marker.floor, marker.at)
        if room is None:
            continue
        for entity_id in marker.entity_ids:
            entity_rooms[entity_id] = (room.id, room.label)
    return rooms, entity_rooms


def _infer_room(
    entity: dict,
    explicit_rooms: dict[str, tuple[str, str]],
    rooms: list[dict],
) -> tuple[str, str] | None:
    entity_id = entity["entity_id"]
    if entity_id in explicit_rooms:
        return explicit_rooms[entity_id]
    haystack = _normalise_name(f"{entity_id} {entity['name']}")
    candidates: list[tuple[int, str, str]] = []
    for room in rooms:
        names = {_normalise_name(room["id"]), _normalise_name(room["name"])}
        score = max((len(name) for name in names if name and name in haystack), default=0)
        if score:
            candidates.append((score, room["id"], room["name"]))
    if not candidates:
        return None
    _, room_id, room_name = max(candidates)
    return room_id, room_name


def _entity_is_safe(entity_id: str) -> bool:
    domain = entity_id.split(".", 1)[0]
    if domain in DEFAULT_SAFE_ACTION_DOMAINS:
        return True
    explicit = {
        item.strip().lower()
        for item in settings.ha_safe_entity_ids.split(",")
        if item.strip()
    }
    return entity_id.lower() in explicit


def _control_profile(entity: dict) -> tuple[str, list[str], bool]:
    domain = entity["domain"]
    state = entity["state"]
    available = state not in {"unknown", "unavailable"}
    safe = _entity_is_safe(entity["entity_id"])
    capabilities = ["view"]
    if available and safe:
        if domain in {"light", "switch"}:
            capabilities = ["toggle", "turn_off", "turn_on"]
        elif domain == "climate":
            capabilities = ["set_temperature"]
        elif domain == "media_player":
            capabilities = ["play_pause"]
        elif domain in {"scene", "script"}:
            capabilities = ["activate"]
        elif domain in {"input_select", "select"} and entity.get("options"):
            capabilities = ["select_option"]

    if domain == "light":
        control_kind = "light"
    elif domain == "climate":
        control_kind = "climate"
    elif domain == "media_player":
        control_kind = "media"
    elif domain == "switch":
        control_kind = "switch"
    elif domain in {"scene", "script"}:
        control_kind = "scene"
    elif domain in {"input_select", "select"}:
        control_kind = "mode"
    elif domain == "camera":
        control_kind = "camera"
    else:
        control_kind = "sensor"

    entity_id = entity["entity_id"]
    advanced = domain == "camera" or any(
        marker in entity_id for marker in ("linkquality", "lqi", "signal_strength")
    )
    return control_kind, capabilities, advanced


def build_home_manifest(
    entities: list[dict],
    favourite_ids: set[str] | None = None,
) -> dict:
    """Build the client contract from live capabilities and the private room layout."""
    rooms, explicit_rooms = _room_catalogue()
    profiles: list[dict] = []
    source_by_id = {entity["entity_id"]: entity for entity in entities}
    for entity in entities:
        room = _infer_room(entity, explicit_rooms, rooms)
        control_kind, capabilities, advanced = _control_profile(entity)
        profiles.append(
            {
                "entity_id": entity["entity_id"],
                "name": entity["name"],
                "domain": entity["domain"],
                "room_id": room[0] if room else None,
                "room_name": room[1] if room else None,
                "control_kind": control_kind,
                "capabilities": capabilities,
                "favourite": False,
                "advanced": advanced,
            }
        )

    favouritable_ids = {
        profile["entity_id"]
        for profile in profiles
        if profile["control_kind"] != "mode" and not profile["advanced"]
    }
    if favourite_ids is None:
        actionable = [
            profile
            for profile in profiles
            if profile["capabilities"] != ["view"]
            and profile["control_kind"] != "mode"
            and not profile["advanced"]
        ]
        priority = {"light": 0, "climate": 1, "scene": 2, "media": 3}
        actionable.sort(
            key=lambda item: (
                priority.get(item["control_kind"], 9),
                0 if source_by_id[item["entity_id"]]["state"] == "on" else 1,
                item["name"].casefold(),
            )
        )
        effective_favourites = {item["entity_id"] for item in actionable[:6]}
    else:
        effective_favourites = set(favourite_ids) & favouritable_ids

    for profile in profiles:
        profile["favourite"] = profile["entity_id"] in effective_favourites
        if profile["room_id"]:
            room = next(item for item in rooms if item["id"] == profile["room_id"])
            room["entity_ids"].append(profile["entity_id"])

    mode_selector = None
    for profile in profiles:
        source = source_by_id[profile["entity_id"]]
        if profile["control_kind"] == "mode" and "select_option" in profile["capabilities"]:
            mode_selector = {
                "entity_id": profile["entity_id"],
                "name": profile["name"],
                "current": source["state"],
                "options": source.get("options") or [],
            }
            break

    advanced_features = ["diagnostics", "floor_plan_2d", "floor_plan_3d"]
    if any(profile["control_kind"] == "camera" for profile in profiles):
        advanced_features.append("cameras")
    if any(
        marker in profile["entity_id"]
        for profile in profiles
        for marker in ("linkquality", "lqi", "zigbee")
    ):
        advanced_features.append("mesh")

    profiles.sort(
        key=lambda item: (
            not item["favourite"],
            item["advanced"],
            item["room_name"] or "zzzz",
            item["name"].casefold(),
        )
    )
    for room in rooms:
        room["entity_ids"].sort()
        room["light_entity_ids"] = [
            item for item in room["light_entity_ids"] if item in source_by_id
        ]
    return {
        "rooms": rooms,
        "entities": profiles,
        "favourite_entity_ids": sorted(effective_favourites),
        "mode_selector": mode_selector,
        "broad_action_scopes": ["favourites", "room", "all"],
        "advanced_features": advanced_features,
    }


def _is_routine_appliance_opening(entity: dict) -> bool:
    words = set(
        re.findall(
            r"[a-z0-9]+",
            f"{entity.get('entity_id', '')} {entity.get('name', '')}".casefold(),
        )
    )
    return (
        "dryer" in words
        or "drier" in words
        or "washer" in words
        or {"washing", "machine"} <= words
    )


def build_home_sitrep(entities: list[dict], manifest: dict) -> dict:
    """Return exceptions first; routine healthy state stays short and calm."""
    profiles = {item["entity_id"]: item for item in manifest["entities"]}
    exceptions: list[dict] = []

    def add(
        entity: dict,
        *,
        severity: str,
        title: str,
        detail: str,
        suffix: str,
    ) -> None:
        profile = profiles.get(entity["entity_id"], {})
        exceptions.append(
            {
                "id": f"{entity['entity_id']}:{suffix}",
                "severity": severity,
                "title": title,
                "detail": detail,
                "entity_id": entity["entity_id"],
                "room_id": profile.get("room_id"),
            }
        )

    safety_classes = {"gas", "moisture", "problem", "safety", "smoke"}
    opening_classes = {"door", "garage_door", "opening", "window"}
    for entity in entities:
        device_class = entity.get("device_class")
        if entity["domain"] == "binary_sensor" and entity["state"] == "on":
            if device_class in safety_classes:
                add(
                    entity,
                    severity="urgent",
                    title=f"{entity['name']} needs attention",
                    detail="A household safety sensor is active.",
                    suffix="safety",
                )
            elif device_class in opening_classes and not _is_routine_appliance_opening(entity):
                add(
                    entity,
                    severity="attention",
                    title=f"{entity['name']} is open",
                    detail="Close it when that is not expected.",
                    suffix="open",
                )
        temperature = entity.get("current_temperature")
        if entity["domain"] == "climate" and temperature is not None:
            if temperature < 5 or temperature > 30:
                add(
                    entity,
                    severity="urgent",
                    title=f"{entity['name']} is {temperature:.1f}°C",
                    detail="The room temperature is outside the usual household range.",
                    suffix="temperature",
                )
        battery_level = entity.get("battery_level")
        if battery_level is not None and battery_level <= 15:
            add(
                entity,
                severity="attention",
                title=f"{entity['name']} battery is low",
                detail=f"{battery_level}% remaining.",
                suffix="battery",
            )
        profile = profiles.get(entity["entity_id"])
        if (
            entity["state"] in {"unknown", "unavailable"}
            and profile
            and profile["favourite"]
        ):
            add(
                entity,
                severity="attention",
                title=f"{entity['name']} is unavailable",
                detail="Its last state cannot be confirmed right now.",
                suffix="unavailable",
            )

    exceptions.sort(
        key=lambda item: (0 if item["severity"] == "urgent" else 1, item["title"])
    )
    lights_on = sum(
        entity["domain"] == "light" and entity["state"] == "on" for entity in entities
    )
    heating = sum(entity.get("hvac_action") == "heating" for entity in entities)
    if not exceptions:
        headline = "All quiet"
        summary = (
            f"Doors and safety sensors are clear · {heating} room"
            f"{'s' if heating != 1 else ''} heating · {lights_on} light"
            f"{'s' if lights_on != 1 else ''} on"
        )
        tone = "calm"
    elif len(exceptions) == 1:
        headline = exceptions[0]["title"]
        summary = "One exception is worth a quick look. Everything else stays out of the way."
        tone = "attention"
    else:
        headline = f"{len(exceptions)} things need attention"
        summary = "The most important household exceptions are shown first."
        tone = "attention"
    return {
        "tone": tone,
        "headline": headline,
        "summary": summary,
        "exceptions": exceptions,
        "updated_at": datetime.now(UTC).isoformat(),
    }


def _number(value) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _integer(value) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def _string_list(value: object, *, max_items: int = 50, max_length: int = 200) -> list[str] | None:
    if not isinstance(value, list):
        return None
    return [item[:max_length] for item in value[:max_items] if isinstance(item, str)]


def sanitise_entities(
    raw_entities: object,
    *,
    family_id: str | None = None,
    ha_url: str | None = None,
) -> list[dict]:
    entities: list[dict] = []
    if not isinstance(raw_entities, list):
        return entities
    for item in raw_entities:
        if not isinstance(item, dict):
            continue
        entity_id = item.get("entity_id")
        if not isinstance(entity_id, str):
            continue
        domain, separator, _ = entity_id.partition(".")
        if not separator or domain not in READABLE_DOMAINS:
            continue
        attributes = item.get("attributes") if isinstance(item.get("attributes"), dict) else {}
        raw_entity_picture = attributes.get("entity_picture")
        entity_picture = (
            str(raw_entity_picture)[:1_000]
            if isinstance(raw_entity_picture, str)
            else None
        )
        if entity_picture is not None and family_id is not None and ha_url is not None:
            entity_picture = register_thumbnail(
                family_id,
                entity_picture,
                ha_url=ha_url,
            )
        entity = {
            "entity_id": entity_id[:200],
            "name": str(attributes.get("friendly_name") or entity_id)[:200],
            "domain": domain,
            "state": str(item.get("state", "unknown"))[:100],
            "device_class": str(attributes["device_class"])[:100] if isinstance(attributes.get("device_class"), str) else None,
            "unit_of_measurement": str(attributes["unit_of_measurement"])[:50] if isinstance(attributes.get("unit_of_measurement"), str) else None,
            "current_temperature": _number(attributes.get("current_temperature")),
            "temperature": _number(attributes.get("temperature")),
            "hvac_action": str(attributes["hvac_action"])[:100] if isinstance(attributes.get("hvac_action"), str) else None,
            "brightness": _integer(attributes.get("brightness")),
            "media_title": str(attributes["media_title"])[:200] if isinstance(attributes.get("media_title"), str) else None,
            "media_artist": str(attributes["media_artist"])[:200] if isinstance(attributes.get("media_artist"), str) else None,
            "volume_level": _number(attributes.get("volume_level")),
            "is_volume_muted": attributes.get("is_volume_muted") if isinstance(attributes.get("is_volume_muted"), bool) else None,
            "shuffle": attributes.get("shuffle") if isinstance(attributes.get("shuffle"), bool) else None,
            "repeat": str(attributes["repeat"])[:20] if isinstance(attributes.get("repeat"), str) else None,
            "media_album_name": str(attributes["media_album_name"])[:200] if isinstance(attributes.get("media_album_name"), str) else None,
            "media_duration": _number(attributes.get("media_duration")),
            "media_position": _number(attributes.get("media_position")),
            "media_position_updated_at": str(attributes["media_position_updated_at"])[:64] if isinstance(attributes.get("media_position_updated_at"), str) else None,
            "entity_picture": entity_picture,
            "options": _string_list(attributes.get("options")),
            "battery_level": _integer(attributes.get("battery_level")),
            "source": str(attributes["source"])[:200] if isinstance(attributes.get("source"), str) else None,
            "operation_mode": str(attributes["operation_mode"])[:100] if isinstance(attributes.get("operation_mode"), str) else None,
            "operation_list": _string_list(attributes.get("operation_list")),
            "group_members": _string_list(attributes.get("group_members")),
            "hvac_modes": _string_list(attributes.get("hvac_modes")),
            "preset_modes": _string_list(attributes.get("preset_modes")),
            "preset_mode": str(attributes["preset_mode"])[:100] if isinstance(attributes.get("preset_mode"), str) else None,
            "min_temp": _number(attributes.get("min_temp")),
            "max_temp": _number(attributes.get("max_temp")),
            "last_changed": str(item["last_changed"])[:64] if isinstance(item.get("last_changed"), str) else None,
            "last_updated": str(item["last_updated"])[:64] if isinstance(item.get("last_updated"), str) else None,
        }
        entities.append(entity)
        if len(entities) >= 200:
            break
    return entities


def sanitise_temperature_history(
    raw_history: object,
    *,
    entity_id: str,
    maximum_points: int = HOME_TEMPERATURE_HISTORY_MAX_POINTS,
) -> list[dict]:
    """Keep only bounded room-temperature facts from Home Assistant history."""
    if maximum_points < 2 or not isinstance(raw_history, list):
        return []

    rows: list[object] = []
    for series in raw_history:
        if isinstance(series, list):
            rows.extend(series)

    points: list[dict] = []
    for row in rows:
        if not isinstance(row, dict) or row.get("entity_id") != entity_id:
            continue
        attributes = row.get("attributes")
        attributes = attributes if isinstance(attributes, dict) else {}
        temperature = _number(attributes.get("current_temperature"))
        if temperature is None:
            try:
                raw_state = row.get("state")
                temperature = float(raw_state) if isinstance(raw_state, str) else None
            except ValueError:
                temperature = None
        if temperature is None or not -80 <= temperature <= 80:
            continue

        raw_recorded_at = row.get("last_changed") or row.get("last_updated")
        if not isinstance(raw_recorded_at, str):
            continue
        try:
            recorded_at = datetime.fromisoformat(
                raw_recorded_at.replace("Z", "+00:00")
            )
        except ValueError:
            continue
        if recorded_at.tzinfo is None:
            continue

        target = _number(attributes.get("temperature"))
        if target is not None and not 5 <= target <= 30:
            target = None
        points.append(
            {
                "recorded_at": recorded_at.astimezone(UTC).isoformat().replace(
                    "+00:00", "Z"
                ),
                "temperature": temperature,
                "target_temperature": target,
                "heating": attributes.get("hvac_action") == "heating",
            }
        )

    points.sort(key=lambda point: point["recorded_at"])
    if len(points) <= maximum_points:
        return points
    last_index = len(points) - 1
    selected_indexes = {
        round(index * last_index / (maximum_points - 1))
        for index in range(maximum_points)
    }
    return [points[index] for index in sorted(selected_indexes)]


async def get_home_snapshot(db, family_id: str, *, timeout: float = 6.0) -> dict:
    try:
        connection = await _settings(db, family_id)
        favourite_ids = await _favourite_ids(db, family_id)
    except (ValueError, RuntimeError):
        return {"configured": True, "available": False, "entities": []}
    return await _get_home_snapshot(
        connection,
        timeout=timeout,
        favourite_ids=favourite_ids,
        family_id=family_id,
    )


async def get_home_snapshot_for_family(family_id: str, *, timeout: float = 6.0) -> dict:
    """Load credentials briefly, then contact Home Assistant without a DB lease."""
    try:
        async with database_lease() as db:
            connection = await _settings(db, family_id)
            favourite_ids = await _favourite_ids(db, family_id)
    except (ValueError, RuntimeError):
        return {"configured": True, "available": False, "entities": []}
    return await _get_home_snapshot(
        connection,
        timeout=timeout,
        favourite_ids=favourite_ids,
        family_id=family_id,
    )


async def get_home_temperature_history_for_family(
    family_id: str,
    entity_id: str,
    *,
    timeout: float = 10.0,
) -> dict:
    """Return one family's bounded 24-hour room-temperature history."""
    if not ENTITY_ID_RE.fullmatch(entity_id):
        raise ValueError("A valid Home Assistant entity ID is required")
    async with database_lease() as db:
        connection = await _settings(db, family_id)
    if connection is None:
        raise RuntimeError("Home Assistant is not configured")

    ha_url, token = connection
    headers = {"Authorization": f"Bearer {token}"}
    encoded_entity_id = quote(entity_id, safe="._")
    end = datetime.now(UTC)
    start = end - timedelta(hours=HOME_TEMPERATURE_HISTORY_HOURS)
    encoded_start = quote(start.isoformat(), safe="")
    async with httpx.AsyncClient(timeout=timeout) as client:
        current_response = await client.get(
            f"{ha_url}/api/states/{encoded_entity_id}",
            headers=headers,
        )
        if current_response.status_code == 404:
            raise ValueError("That room temperature is no longer available")
        current_response.raise_for_status()
        current_entities = sanitise_entities([current_response.json()])
        if not current_entities:
            raise ValueError("That Home Assistant entity is not available through HausKlar")
        current = current_entities[0]
        unit = (current.get("unit_of_measurement") or "").casefold()
        is_temperature = (
            current["domain"] == "climate"
            or current.get("device_class") == "temperature"
            or unit in {"°c", "°f"}
        )
        if not is_temperature:
            raise ValueError("That Home Assistant entity is not a room temperature")

        history_response = await client.get(
            f"{ha_url}/api/history/period/{encoded_start}",
            headers=headers,
            params={
                "end_time": end.isoformat(),
                "filter_entity_id": entity_id,
            },
        )
        history_response.raise_for_status()

    return {
        "entity_id": entity_id,
        "unit": current.get("unit_of_measurement"),
        "hours": HOME_TEMPERATURE_HISTORY_HOURS,
        "points": sanitise_temperature_history(
            history_response.json(),
            entity_id=entity_id,
        ),
    }


async def home_is_configured_for_family(family_id: str) -> bool:
    """Check family-scoped HA configuration without making a network request."""
    try:
        async with database_lease() as db:
            return await _settings(db, family_id) is not None
    except (ValueError, RuntimeError):
        return False


async def _get_home_snapshot(
    connection: tuple[str, str] | None,
    *,
    timeout: float,
    favourite_ids: set[str] | None = None,
    family_id: str | None = None,
) -> dict:
    if connection is None:
        return {"configured": False, "available": False, "entities": []}
    ha_url, token = connection
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.get(f"{ha_url}/api/states", headers={"Authorization": f"Bearer {token}"})
            response.raise_for_status()
        entities = sanitise_entities(
            response.json(),
            family_id=family_id,
            ha_url=ha_url,
        )
        manifest = build_home_manifest(entities, favourite_ids)
        return {
            "configured": True,
            "available": True,
            "entities": entities,
            "manifest": manifest,
            "sitrep": build_home_sitrep(entities, manifest),
        }
    except (ValueError, RuntimeError, httpx.HTTPError):
        return {"configured": True, "available": False, "entities": []}


async def save_home_favourites_for_family(
    family_id: str,
    user_id: str,
    entity_ids: list[str],
) -> list[str]:
    """Persist only entity IDs that exist in the family's current live snapshot."""
    async with database_lease() as db:
        connection = await _settings(db, family_id)
    snapshot = await _get_home_snapshot(
        connection,
        timeout=6.0,
        favourite_ids=set(entity_ids),
        family_id=family_id,
    )
    if not snapshot["available"]:
        raise RuntimeError("Home Assistant is unavailable through HausKlar")
    known_ids = {item["entity_id"] for item in snapshot["entities"]}
    unknown_ids = set(entity_ids) - known_ids
    if unknown_ids:
        raise ValueError("A favourite Home Assistant entity is no longer available")
    favouritable_ids = {
        item["entity_id"]
        for item in snapshot["manifest"]["entities"]
        if item["control_kind"] != "mode" and not item["advanced"]
    }
    if set(entity_ids) - favouritable_ids:
        raise ValueError("That Home Assistant entity belongs in House state or Advanced")
    async with database_lease() as db:
        await db.execute(
            "INSERT OR REPLACE INTO family_settings "
            "(family_id, setting_key, setting_value, updated_at, updated_by) "
            "VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?)",
            (
                family_id,
                HOME_FAVOURITES_SETTING,
                json.dumps(entity_ids, separators=(",", ":")),
                user_id,
            ),
        )
        await db.commit()
    return entity_ids


async def perform_home_broad_action_for_family(
    family_id: str,
    request: HomeBroadActionRequest,
) -> list[str]:
    """Resolve a manifest scope server-side, then execute only after confirmation."""
    if not request.confirmed:
        raise ValueError("Confirm this whole-house action before it runs")
    async with database_lease() as db:
        connection = await _settings(db, family_id)
        favourite_ids = await _favourite_ids(db, family_id)
    snapshot = await _get_home_snapshot(
        connection,
        timeout=6.0,
        favourite_ids=favourite_ids,
        family_id=family_id,
    )
    if not snapshot["available"]:
        raise RuntimeError("Home Assistant is unavailable through HausKlar")
    manifest = snapshot["manifest"]
    light_profiles = [
        item
        for item in manifest["entities"]
        if item["control_kind"] == "light"
        and ("turn_on" in item["capabilities"] or "turn_off" in item["capabilities"])
    ]
    if request.scope == "favourites":
        entity_ids = [item["entity_id"] for item in light_profiles if item["favourite"]]
    elif request.scope == "room":
        room_ids = {item["id"] for item in manifest["rooms"]}
        if request.room_id not in room_ids:
            raise ValueError("That room is not available in the house manifest")
        entity_ids = [
            item["entity_id"] for item in light_profiles if item["room_id"] == request.room_id
        ]
    else:
        entity_ids = [item["entity_id"] for item in light_profiles]
    if not entity_ids:
        raise ValueError("No controllable lights match that house action")
    if connection is None:
        raise RuntimeError("Home Assistant is not configured")
    ha_url, token = connection
    service = "turn_on" if request.action == "lights_on" else "turn_off"
    async with httpx.AsyncClient(timeout=15.0) as client:
        for start in range(0, len(entity_ids), 20):
            response = await client.post(
                f"{ha_url}/api/services/light/{service}",
                headers={"Authorization": f"Bearer {token}"},
                json={"entity_id": entity_ids[start : start + 20]},
            )
            response.raise_for_status()
    return entity_ids


async def perform_home_action(db, family_id: str, request: HomeActionRequest) -> None:
    connection = await _settings(db, family_id)
    await _perform_home_action(connection, request)


async def perform_home_action_for_family(
    family_id: str,
    request: HomeActionRequest,
) -> None:
    """Resolve credentials in SQLite, then release it before the service call."""
    async with database_lease() as db:
        connection = await _settings(db, family_id)
    await _perform_home_action(connection, request)


async def turn_all_lights_for_family(family_id: str, state: str) -> None:
    """Run the assistant's one fixed whole-house light command without a DB lease."""
    if state not in {"on", "off"}:
        raise ValueError("The light state is invalid")
    async with database_lease() as db:
        connection = await _settings(db, family_id)
    if connection is None:
        raise RuntimeError("Home Assistant is not configured")
    ha_url, token = connection
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            f"{ha_url}/api/services/light/turn_{state}",
            headers={"Authorization": f"Bearer {token}"},
            json={"entity_id": "all"},
        )
        response.raise_for_status()


async def _perform_home_action(
    connection: tuple[str, str] | None,
    request: HomeActionRequest,
) -> None:
    domain = request.entity_id.split(".", 1)[0]
    if domain not in ACTION_DOMAINS[request.action]:
        raise ValueError(f"{request.action} is not allowed for {domain} entities")
    _ensure_safe_entities([request.entity_id])
    if connection is None:
        raise RuntimeError("Home Assistant is not configured")
    ha_url, token = connection

    service = request.action
    body: dict[str, object] = {"entity_id": request.entity_id}
    if request.action == "play_pause":
        service = "media_play_pause"
    elif request.action == "set_temperature":
        if request.value is None or request.value < 5 or request.value > 30:
            raise ValueError("Temperature must be between 5 and 30 degrees")
        body["temperature"] = request.value

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.post(
            f"{ha_url}/api/services/{domain}/{service}",
            headers={"Authorization": f"Bearer {token}"},
            json=body,
        )
        response.raise_for_status()


def _validate_entity_ids(value: object) -> None:
    entity_ids = value if isinstance(value, list) else [value]
    if not entity_ids or len(entity_ids) > 20:
        raise ValueError("Between one and 20 Home Assistant entities are required")
    if any(not isinstance(item, str) or not ENTITY_ID_RE.fullmatch(item) for item in entity_ids):
        raise ValueError("A valid Home Assistant entity ID is required")


def _ensure_safe_entities(entity_ids: list[str]) -> None:
    for entity_id in entity_ids:
        if not _entity_is_safe(entity_id):
            raise ValueError("That Home Assistant entity is not approved for HausKlar control")


def _validate_service_data(request: HomeServiceRequest) -> dict:
    if request.service not in ALLOWED_SERVICES.get(request.domain, set()):
        raise ValueError("That Home Assistant service is not available through HausKlar")
    if set(request.data) - SERVICE_DATA_KEYS:
        raise ValueError("The Home Assistant action contains unsupported fields")
    try:
        encoded = json.dumps(request.data, separators=(",", ":"))
    except (TypeError, ValueError) as exc:
        raise ValueError("The Home Assistant action payload is invalid") from exc
    if len(encoded.encode()) > 20_000:
        raise ValueError("The Home Assistant action payload is too large")

    data = dict(request.data)
    if "entity_id" not in data:
        raise ValueError("A Home Assistant entity is required")
    _validate_entity_ids(data["entity_id"])
    main_entity_ids = data["entity_id"] if isinstance(data["entity_id"], list) else [data["entity_id"]]
    _ensure_safe_entities(main_entity_ids)
    expected_domains = {request.domain}
    if request.domain == "spotifyplus":
        expected_domains = {"media_player"}
    elif request.domain == "tts":
        expected_domains = {"media_player", "tts"}
    if any(item.split(".", 1)[0] not in expected_domains for item in main_entity_ids):
        raise ValueError("The Home Assistant entity does not match the requested service")
    if request.return_response and not (
        request.domain == "spotifyplus"
        or (request.domain == "media_player" and request.service == "browse_media")
    ):
        raise ValueError("That Home Assistant service cannot return data through HausKlar")
    for key, value in data.items():
        if key in {"entity_id", "group_members"}:
            _validate_entity_ids(value)
            if key == "group_members":
                _ensure_safe_entities(value if isinstance(value, list) else [value])
        elif key in {"brightness", "limit_total"}:
            if not isinstance(value, int) or isinstance(value, bool) or value < 0 or value > (255 if key == "brightness" else 100):
                raise ValueError(f"{key} is outside the allowed range")
        elif key == "temperature":
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 5 or value > 30:
                raise ValueError("temperature is outside the allowed range")
        elif key == "volume_level":
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0 or value > 1:
                raise ValueError("volume_level is outside the allowed range")
        elif key in {"shuffle", "is_volume_muted"} and not isinstance(value, bool):
            raise ValueError(f"{key} must be true or false")
        elif key == "extra":
            if not isinstance(value, dict) or set(value) != {"enqueue"} or value["enqueue"] not in {"add", "next", "play", "replace"}:
                raise ValueError("extra contains unsupported media options")
        elif not isinstance(value, (str, int, float, bool, list, dict)):
            raise ValueError(f"{key} has an invalid value")
        elif isinstance(value, str) and len(value) > (500 if key == "message" else 2_000):
            raise ValueError(f"{key} is too long")
    return data


def _is_thumbnail_response_field(key: str, container: dict) -> bool:
    key = key.lower()
    if key in {"image_url", "thumbnail"}:
        return True
    return key == "url" and ("height" in container or "width" in container)


def _sanitise_service_response(
    value: object,
    *,
    depth: int = 0,
    family_id: str | None = None,
    ha_url: str | None = None,
) -> object:
    if depth > 8:
        return None
    if isinstance(value, dict):
        cleaned = {}
        for key, item in list(value.items())[:200]:
            if str(key).lower() in SENSITIVE_RESPONSE_KEYS:
                continue
            safe_key = str(key)[:200]
            if (
                family_id is not None
                and ha_url is not None
                and isinstance(item, str)
                and _is_thumbnail_response_field(safe_key, value)
            ):
                proxy_path = register_thumbnail(family_id, item, ha_url=ha_url)
                if proxy_path is not None:
                    cleaned[safe_key] = proxy_path
                continue
            cleaned[safe_key] = _sanitise_service_response(
                item,
                depth=depth + 1,
                family_id=family_id,
                ha_url=ha_url,
            )
        return cleaned
    if isinstance(value, list):
        return [
            _sanitise_service_response(
                item,
                depth=depth + 1,
                family_id=family_id,
                ha_url=ha_url,
            )
            for item in value[:500]
        ]
    if isinstance(value, str):
        return value[:5_000]
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return str(value)[:1_000]


async def perform_home_service(db, family_id: str, request: HomeServiceRequest) -> object:
    connection = await _settings(db, family_id)
    return await _perform_home_service(connection, request, family_id=family_id)


async def perform_home_service_for_family(
    family_id: str,
    request: HomeServiceRequest,
) -> object:
    """Resolve credentials in SQLite, then release it before the service call."""
    async with database_lease() as db:
        connection = await _settings(db, family_id)
    return await _perform_home_service(connection, request, family_id=family_id)


async def get_media_thumbnail_for_family(
    family_id: str,
    thumbnail_id: str,
) -> tuple[bytes, str]:
    """Resolve a family-scoped opaque artwork ID through current HA credentials."""
    async with database_lease() as db:
        connection = await _settings(db, family_id)
    if connection is None:
        raise RuntimeError("Home Assistant is not configured")
    ha_url, token = connection
    return await fetch_registered_thumbnail(
        family_id,
        thumbnail_id,
        ha_url=ha_url,
        ha_token=token,
    )


def validate_camera_snapshot_entity_id(entity_id: str) -> str:
    """Accept only one concrete Home Assistant camera entity identifier."""
    if not ENTITY_ID_RE.fullmatch(entity_id) or not entity_id.startswith("camera."):
        raise ValueError("A valid camera entity is required")
    return entity_id


def valid_image_signature(body: bytes | bytearray, media_type: str) -> bool:
    prefix = bytes(body[:16])
    if media_type == "image/jpeg":
        return prefix.startswith(b"\xff\xd8\xff")
    if media_type == "image/png":
        return prefix.startswith(b"\x89PNG\r\n\x1a\n")
    if media_type == "image/webp":
        return len(prefix) >= 12 and prefix[:4] == b"RIFF" and prefix[8:12] == b"WEBP"
    return False


def validate_bounded_content_length(value: str | None, maximum_bytes: int) -> None:
    if value is None:
        return
    try:
        length = int(value)
    except ValueError as exc:
        raise RuntimeError("The upstream returned an invalid content length") from exc
    if length < 0:
        raise RuntimeError("The upstream returned an invalid content length")
    if length > maximum_bytes:
        raise RuntimeError("The upstream response is too large")


async def get_camera_snapshot_for_family(
    family_id: str,
    entity_id: str,
) -> tuple[bytes, str]:
    """Fetch one bounded camera image without exposing HA topology or credentials."""
    entity_id = validate_camera_snapshot_entity_id(entity_id)
    async with database_lease() as db:
        connection = await _settings(db, family_id)
    if connection is None:
        raise RuntimeError("Home Assistant is not configured")
    ha_url, token = connection
    timeout = httpx.Timeout(connect=3.0, read=8.0, write=3.0, pool=3.0)
    maximum_bytes = 5 * 1024 * 1024
    client = await provider_client(
        "home_assistant",
        timeout=timeout,
        follow_redirects=False,
    )
    async with client.stream(
            "GET",
            f"{ha_url}/api/camera_proxy/{entity_id}",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "image/jpeg, image/png, image/webp",
            },
        ) as response:
        if response.is_redirect:
            raise RuntimeError("Home Assistant redirected the camera image")
        if response.status_code == 404:
            raise ValueError("That camera is not available")
        response.raise_for_status()
        media_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
        if media_type not in {"image/jpeg", "image/png", "image/webp"}:
            raise RuntimeError("Home Assistant returned an invalid camera image")
        try:
            validate_bounded_content_length(
                response.headers.get("content-length"), maximum_bytes
            )
        except RuntimeError as exc:
            if "too large" in str(exc):
                raise RuntimeError("The camera image is too large") from exc
            raise RuntimeError("Home Assistant returned an invalid image length") from exc
        body = bytearray()
        async for chunk in response.aiter_bytes():
            body.extend(chunk)
            if len(body) > maximum_bytes:
                raise RuntimeError("The camera image is too large")
    if not body:
        raise RuntimeError("Home Assistant returned an empty camera image")
    if not valid_image_signature(body, media_type):
        raise RuntimeError("Home Assistant returned an invalid camera image")
    return bytes(body), media_type


async def _perform_home_service(
    connection: tuple[str, str] | None,
    request: HomeServiceRequest,
    *,
    family_id: str | None = None,
) -> object:
    data = _validate_service_data(request)
    if connection is None:
        raise RuntimeError("Home Assistant is not configured")
    ha_url, token = connection
    suffix = "?return_response" if request.return_response else ""
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            f"{ha_url}/api/services/{request.domain}/{request.service}{suffix}",
            headers={"Authorization": f"Bearer {token}"},
            json=data,
        )
        response.raise_for_status()
    if not request.return_response:
        return {"success": True}
    if len(response.content) > 1_000_000:
        raise RuntimeError("Home Assistant returned too much data")
    try:
        payload = response.json()
    except ValueError as exc:
        raise RuntimeError("Home Assistant returned an invalid response") from exc
    if isinstance(payload, dict) and "service_response" in payload:
        payload = payload["service_response"]
    return _sanitise_service_response(
        payload,
        family_id=family_id,
        ha_url=ha_url,
    )
