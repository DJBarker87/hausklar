from unittest.mock import AsyncMock, patch

import pytest

from app.config import settings
from app.services.home_assistant import (
    build_home_manifest,
    build_home_sitrep,
    sanitise_entities,
    sanitise_temperature_history,
)


def test_sanitise_home_entities_excludes_secrets_and_unsupported_domains():
    entities = sanitise_entities(
        [
            {
                "entity_id": "light.example_living_room",
                "state": "on",
                "attributes": {
                    "friendly_name": "Kitchen",
                    "brightness": 127,
                    "access_token": "must-not-leak",
                },
            },
            {
                "entity_id": "camera.front_door",
                "state": "recording",
                "attributes": {"friendly_name": "Front door", "access_token": "secret"},
            },
        ]
    )

    assert [entity["entity_id"] for entity in entities] == [
        "light.example_living_room",
        "camera.front_door",
    ]
    assert entities[0]["name"] == "Kitchen"
    assert entities[0]["brightness"] == 127
    assert entities[1]["name"] == "Front door"
    assert all("access_token" not in entity for entity in entities)


def test_temperature_history_keeps_only_bounded_sanitised_temperature_facts():
    raw = [[
        {
            "entity_id": "climate.example_9feafd80",
            "state": "heat",
            "last_changed": "2026-08-15T06:00:00+00:00",
            "attributes": {
                "current_temperature": 19.5,
                "temperature": 21.0,
                "hvac_action": "heating",
                "access_token": "must-not-leak",
            },
        },
        {
            "entity_id": "climate.example_9feafd80",
            "state": "heat",
            "last_changed": "2026-08-15T07:00:00Z",
            "attributes": {
                "current_temperature": 20.0,
                "temperature": 99,
                "hvac_action": "idle",
            },
        },
        {
            "entity_id": "sensor.unrelated",
            "state": "42",
            "last_changed": "2026-08-15T07:30:00Z",
            "attributes": {},
        },
    ]]

    points = sanitise_temperature_history(
        raw,
        entity_id="climate.example_9feafd80",
        maximum_points=2,
    )

    assert points == [
        {
            "recorded_at": "2026-08-15T06:00:00Z",
            "temperature": 19.5,
            "target_temperature": 21.0,
            "heating": True,
        },
        {
            "recorded_at": "2026-08-15T07:00:00Z",
            "temperature": 20.0,
            "target_temperature": None,
            "heating": False,
        },
    ]
    assert "access_token" not in str(points)


def test_home_manifest_owns_room_capabilities_favourites_and_advanced(monkeypatch):
    monkeypatch.setattr(
        settings,
        "ha_safe_entity_ids",
        "input_select.house_mode",
    )
    entities = sanitise_entities(
        [
            {
                "entity_id": "light.example_living_room",
                "state": "on",
                "attributes": {"friendly_name": "Example living-room light"},
            },
            {
                "entity_id": "climate.example_9feafd80",
                "state": "heat",
                "attributes": {
                    "friendly_name": "Kitchen heating",
                    "current_temperature": 20.5,
                    "temperature": 21,
                },
            },
            {
                "entity_id": "input_select.house_mode",
                "state": "Home",
                "attributes": {
                    "friendly_name": "House mode",
                    "options": ["Home", "Away", "Night"],
                },
            },
            {
                "entity_id": "camera.front_door",
                "state": "recording",
                "attributes": {"friendly_name": "Front door camera"},
            },
        ]
    )

    manifest = build_home_manifest(entities, {"light.example_living_room"})

    profiles = {item["entity_id"]: item for item in manifest["entities"]}
    assert profiles["light.example_living_room"] == {
        "entity_id": "light.example_living_room",
        "name": "Example living-room light",
        "domain": "light",
        "room_id": "example_living_room",
        "room_name": "Example Living Room",
        "control_kind": "light",
        "capabilities": ["toggle", "turn_off", "turn_on"],
        "favourite": True,
        "advanced": False,
    }
    assert profiles["climate.example_9feafd80"]["room_id"] is None
    assert manifest["mode_selector"] == {
        "entity_id": "input_select.house_mode",
        "name": "House mode",
        "current": "Home",
        "options": ["Home", "Away", "Night"],
    }
    assert profiles["camera.front_door"]["advanced"] is True
    assert "cameras" in manifest["advanced_features"]


def test_home_manifest_favourites_do_not_duplicate_house_mode(monkeypatch):
    monkeypatch.setattr(settings, "ha_safe_entity_ids", "input_select.house_mode")
    entities = sanitise_entities(
        [
            {
                "entity_id": "input_select.house_mode",
                "state": "Home",
                "attributes": {
                    "friendly_name": "House mode",
                    "options": ["Home", "Away"],
                },
            },
            {
                "entity_id": "light.example_living_room",
                "state": "off",
                "attributes": {"friendly_name": "Kitchen lights"},
            },
        ]
    )

    manifest = build_home_manifest(entities, {"input_select.house_mode", "light.example_living_room"})
    default_manifest = build_home_manifest(entities)

    assert manifest["favourite_entity_ids"] == ["light.example_living_room"]
    assert default_manifest["favourite_entity_ids"] == ["light.example_living_room"]
    assert manifest["mode_selector"]["entity_id"] == "input_select.house_mode"


def test_home_sitrep_is_calm_until_a_real_exception_appears():
    calm_entities = sanitise_entities(
        [
            {
                "entity_id": "binary_sensor.example_e1938001",
                "state": "off",
                "attributes": {
                    "friendly_name": "Front door",
                    "device_class": "door",
                },
            },
            {
                "entity_id": "light.example_living_room",
                "state": "on",
                "attributes": {"friendly_name": "Kitchen"},
            },
        ]
    )
    calm_manifest = build_home_manifest(calm_entities, set())
    calm = build_home_sitrep(calm_entities, calm_manifest)
    assert calm["tone"] == "calm"
    assert calm["headline"] == "All quiet"
    assert calm["exceptions"] == []

    attention_entities = sanitise_entities(
        [
            {
                "entity_id": "binary_sensor.example_e1938001",
                "state": "on",
                "attributes": {
                    "friendly_name": "Front door",
                    "device_class": "door",
                },
            },
            {
                "entity_id": "binary_sensor.utility_smoke",
                "state": "on",
                "attributes": {
                    "friendly_name": "Utility smoke alarm",
                    "device_class": "smoke",
                },
            },
        ]
    )
    attention_manifest = build_home_manifest(attention_entities, set())
    attention = build_home_sitrep(attention_entities, attention_manifest)
    assert attention["tone"] == "attention"
    assert [item["severity"] for item in attention["exceptions"]] == [
        "urgent",
        "attention",
    ]
    assert attention["exceptions"][0]["title"] == "Utility smoke alarm needs attention"


def test_home_sitrep_ignores_washing_machine_and_dryer_doors():
    entities = sanitise_entities(
        [
            {
                "entity_id": "binary_sensor.example_a401a1ce",
                "state": "on",
                "attributes": {"friendly_name": "Washing machine Door", "device_class": "door"},
            },
            {
                "entity_id": "binary_sensor.tumble_dryer_door",
                "state": "on",
                "attributes": {"friendly_name": "Dryer Door", "device_class": "door"},
            },
            {
                "entity_id": "binary_sensor.example_92877e76",
                "state": "on",
                "attributes": {"friendly_name": "Dishwasher Door", "device_class": "door"},
            },
        ]
    )

    sitrep = build_home_sitrep(entities, build_home_manifest(entities, set()))

    assert [item["title"] for item in sitrep["exceptions"]] == ["Dishwasher Door is open"]


@pytest.mark.asyncio
async def test_home_status_requires_authentication(client):
    response = await client.get("/api/home/status")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_home_status_is_scoped_to_authenticated_family(client, adult_a_headers, monkeypatch):
    snapshot = {"configured": True, "available": True, "entities": []}
    mocked = AsyncMock(return_value=snapshot)
    monkeypatch.setattr("app.routers.home.get_home_snapshot_for_family", mocked)

    response = await client.get("/api/home/status", headers=adult_a_headers)

    assert response.status_code == 200
    assert response.json() == snapshot
    assert mocked.await_args.args[0] == "00000000-0000-0000-0000-000000000100"


@pytest.mark.asyncio
async def test_home_layout_requires_authentication(client):
    response = await client.get("/api/home/layout")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_home_layout_returns_fictional_fallback_geometry(client, adult_a_headers):
    with patch(
        "app.routers.home.home_is_configured_for_family", new=AsyncMock(return_value=True)
    ) as configured:
        response = await client.get("/api/home/layout", headers=adult_a_headers)

    assert response.status_code == 200
    body = response.json()
    assert body["width"] == 900
    assert [floor["name"] for floor in body["floors"]] == ["Example floor", "Unused example floor"]
    assert any(room["id"] == "example_kitchen" for room in body["floors"][0]["rooms"])
    assert "token" not in response.text.lower()
    assert configured.await_args.args == ("00000000-0000-0000-0000-000000000100",)


@pytest.mark.asyncio
async def test_home_layout_is_not_exposed_to_family_without_home_configuration(client, adult_a_headers):
    with patch("app.routers.home.home_is_configured_for_family", new=AsyncMock(return_value=False)):
        response = await client.get("/api/home/layout", headers=adult_a_headers)

    assert response.status_code == 404


@pytest.mark.asyncio
async def test_home_temperature_history_requires_authentication(client):
    response = await client.get("/api/home/temperature-history/climate.example_9feafd80")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_home_temperature_history_is_scoped_and_sanitised(
    client,
    adult_a_headers,
    monkeypatch,
):
    mocked = AsyncMock(
        return_value={
            "entity_id": "climate.example_9feafd80",
            "unit": "°C",
            "hours": 24,
            "points": [
                {
                    "recorded_at": "2026-08-15T07:00:00Z",
                    "temperature": 20.0,
                    "target_temperature": 21.0,
                    "heating": True,
                }
            ],
        }
    )
    monkeypatch.setattr(
        "app.routers.home.get_home_temperature_history_for_family",
        mocked,
    )

    response = await client.get(
        "/api/home/temperature-history/climate.example_9feafd80",
        headers=adult_a_headers,
    )

    assert response.status_code == 200
    assert response.json() == {
        "entity_id": "climate.example_9feafd80",
        "unit": "°C",
        "hours": 24,
        "points": [
            {
                "recorded_at": "2026-08-15T07:00:00Z",
                "temperature": 20.0,
                "target_temperature": 21.0,
                "heating": True,
            }
        ],
    }
    assert mocked.await_args.args == (
        "00000000-0000-0000-0000-000000000100",
        "climate.example_9feafd80",
    )


@pytest.mark.asyncio
async def test_home_action_rejects_action_for_wrong_domain(client, adult_a_headers):
    response = await client.post(
        "/api/home/actions",
        headers=adult_a_headers,
        json={"entity_id": "sensor.example_f978f96a", "action": "turn_on"},
    )
    assert response.status_code == 400
    assert "not allowed" in response.json()["detail"]


@pytest.mark.asyncio
async def test_home_action_passes_only_validated_request(client, adult_a_headers, monkeypatch):
    mocked = AsyncMock(return_value=None)
    monkeypatch.setattr("app.routers.home.perform_home_action_for_family", mocked)

    response = await client.post(
        "/api/home/actions",
        headers=adult_a_headers,
        json={"entity_id": "light.example_living_room", "action": "toggle"},
    )

    assert response.status_code == 200
    assert response.json() == {"success": True, "entity_id": "light.example_living_room", "action": "toggle"}
    request = mocked.await_args.args[1]
    assert request.entity_id == "light.example_living_room"
    assert request.action == "toggle"


@pytest.mark.asyncio
async def test_home_favourites_are_family_scoped_and_verified(client, adult_a_headers, monkeypatch):
    mocked = AsyncMock(return_value=["light.example_living_room"])
    monkeypatch.setattr(
        "app.routers.home.save_home_favourites_for_family",
        mocked,
    )

    response = await client.put(
        "/api/home/favourites",
        headers=adult_a_headers,
        json={"entity_ids": ["light.example_living_room"]},
    )

    assert response.status_code == 200
    assert response.json() == {"entity_ids": ["light.example_living_room"]}
    assert mocked.await_args.args == (
        "00000000-0000-0000-0000-000000000100",
        "00000000-0000-0000-0000-000000000001",
        ["light.example_living_room"],
    )


@pytest.mark.asyncio
async def test_broad_house_action_requires_confirmation(client, adult_a_headers, monkeypatch):
    mocked = AsyncMock(side_effect=ValueError("Confirm this whole-house action before it runs"))
    monkeypatch.setattr(
        "app.routers.home.perform_home_broad_action_for_family",
        mocked,
    )

    response = await client.post(
        "/api/home/broad-actions",
        headers=adult_a_headers,
        json={"action": "lights_off", "scope": "all", "confirmed": False},
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Confirm this whole-house action before it runs"


@pytest.mark.asyncio
async def test_broad_house_action_returns_exact_manifest_targets(client, adult_a_headers, monkeypatch):
    mocked = AsyncMock(return_value=["light.example_living_room", "light.example_d7ab5b9b"])
    monkeypatch.setattr(
        "app.routers.home.perform_home_broad_action_for_family",
        mocked,
    )

    response = await client.post(
        "/api/home/broad-actions",
        headers=adult_a_headers,
        json={
            "action": "lights_off",
            "scope": "room",
            "room_id": "kitchen",
            "confirmed": True,
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "success": True,
        "action": "lights_off",
        "scope": "room",
        "entity_ids": ["light.example_living_room", "light.example_d7ab5b9b"],
    }
    request = mocked.await_args.args[1]
    assert request.scope == "room"
    assert request.confirmed is True


@pytest.mark.asyncio
async def test_home_service_requires_authentication(client):
    response = await client.post(
        "/api/home/services",
        json={
            "domain": "light",
            "service": "turn_on",
            "data": {"entity_id": "light.example_living_room"},
        },
    )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_home_service_rejects_non_allowlisted_service(client, adult_a_headers):
    response = await client.post(
        "/api/home/services",
        headers=adult_a_headers,
        json={
            "domain": "homeassistant",
            "service": "restart",
            "data": {"entity_id": "light.example_living_room"},
        },
    )

    assert response.status_code == 400
    assert "not available" in response.json()["detail"]


@pytest.mark.asyncio
async def test_home_service_rejects_unapproved_script_and_switch_entities(client, adult_a_headers):
    for domain, service, entity_id in (
        ("script", "turn_on", "script.unlock_front_door"),
        ("scene", "turn_on", "scene.disarm_house"),
        ("switch", "turn_on", "switch.garage_release"),
    ):
        response = await client.post(
            "/api/home/services",
            headers=adult_a_headers,
            json={
                "domain": domain,
                "service": service,
                "data": {"entity_id": entity_id},
            },
        )
        assert response.status_code == 400
        assert "not approved" in response.json()["detail"]

    simple_action = await client.post(
        "/api/home/actions",
        headers=adult_a_headers,
        json={"entity_id": "switch.garage_release", "action": "turn_on"},
    )
    assert simple_action.status_code == 400
    assert "not approved" in simple_action.json()["detail"]


@pytest.mark.asyncio
async def test_home_service_rejects_unexpected_payload_fields(client, adult_a_headers):
    response = await client.post(
        "/api/home/services",
        headers=adult_a_headers,
        json={
            "domain": "light",
            "service": "turn_on",
            "data": {
                "entity_id": "light.example_living_room",
                "evil": "not forwarded",
            },
        },
    )

    assert response.status_code == 400
    assert "unsupported fields" in response.json()["detail"]


@pytest.mark.asyncio
async def test_home_service_passes_validated_family_request(client, adult_a_headers, monkeypatch):
    mocked = AsyncMock(return_value={"success": True})
    monkeypatch.setattr("app.routers.home.perform_home_service_for_family", mocked)

    response = await client.post(
        "/api/home/services",
        headers=adult_a_headers,
        json={
            "domain": "light",
            "service": "turn_on",
            "data": {"entity_id": "light.example_living_room", "brightness": 120},
        },
    )

    assert response.status_code == 200
    assert response.json() == {"success": True}
    assert mocked.await_args.args[0] == "00000000-0000-0000-0000-000000000100"
    request = mocked.await_args.args[1]
    assert request.domain == "light"
    assert request.service == "turn_on"
