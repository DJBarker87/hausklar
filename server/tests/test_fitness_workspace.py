"""Fitness is an opt-in, owner-private adult workspace."""

from datetime import datetime, timezone

import pytest


pytestmark = pytest.mark.asyncio


async def _set_outcome(client, headers, outcome: str) -> None:
    response = await client.put(
        "/api/fitness/onboarding",
        headers=headers,
        json={"main_outcome": outcome},
    )
    assert response.status_code == 200, response.text


async def _record_weight(client, headers, value: float) -> None:
    response = await client.post(
        "/api/fitness/body/measurements",
        headers=headers,
        json={
            "metric_key": "body.weight",
            "measured_at_utc": datetime.now(timezone.utc).isoformat(),
            "local_timezone": "Europe/London",
            "value": value,
            "unit_key": "kg",
        },
    )
    assert response.status_code == 201, response.text


async def test_workspace_hide_and_pin_are_private_to_each_adult(
    client,
    adult_a_headers,
    adult_b_headers,
):
    assert (await client.get("/api/fitness/workspace", headers=adult_a_headers)).json() == {
        "enabled": False,
        "pinned": False,
        "show_nutrition_today": False,
    }
    assert (await client.get("/api/fitness/workspace", headers=adult_b_headers)).json() == {
        "enabled": False,
        "pinned": False,
        "show_nutrition_today": False,
    }

    enabled = await client.patch(
        "/api/fitness/workspace",
        headers=adult_a_headers,
        json={"pinned": True},
    )
    assert enabled.status_code == 200
    assert enabled.json() == {
        "enabled": True,
        "pinned": True,
        "show_nutrition_today": False,
    }
    assert (await client.get("/api/fitness/workspace", headers=adult_b_headers)).json() == {
        "enabled": False,
        "pinned": False,
        "show_nutrition_today": False,
    }

    hidden = await client.patch(
        "/api/fitness/workspace",
        headers=adult_a_headers,
        json={"enabled": False},
    )
    assert hidden.json() == {
        "enabled": False,
        "pinned": False,
        "show_nutrition_today": False,
    }
    today = (await client.get("/api/fitness/today-card", headers=adult_a_headers)).json()
    assert today["session"] is None
    assert today["primary_action"] is None


async def test_today_nutrition_preference_is_owner_private_and_enables_fitness(
    client,
    adult_a_headers,
    adult_b_headers,
):
    enabled = await client.patch(
        "/api/fitness/workspace",
        headers=adult_a_headers,
        json={"show_nutrition_today": True},
    )
    assert enabled.status_code == 200, enabled.text
    assert enabled.json() == {
        "enabled": True,
        "pinned": False,
        "show_nutrition_today": True,
    }
    assert (await client.get("/api/fitness/workspace", headers=adult_b_headers)).json() == {
        "enabled": False,
        "pinned": False,
        "show_nutrition_today": False,
    }


async def test_overview_fact_follows_outcome_and_never_defaults_to_weight(
    client,
    adult_a_headers,
    adult_b_headers,
):
    await _record_weight(client, adult_a_headers, 81.2)
    await _record_weight(client, adult_b_headers, 63.4)
    await _set_outcome(client, adult_a_headers, "Build strength")
    await _set_outcome(client, adult_b_headers, "Support my weight")

    dom = (await client.get("/api/fitness/overview", headers=adult_a_headers)).json()
    kat = (await client.get("/api/fitness/overview", headers=adult_b_headers)).json()

    assert dom["focus"]["outcome"] == "Build strength"
    assert dom["focus"]["label"] == "Strength this week"
    assert "81.2" not in str(dom)
    assert "63.4" not in str(dom)
    assert all(action["kind"] != "log_food" for action in dom["quick_actions"])

    assert kat["focus"]["outcome"] == "Support my weight"
    assert kat["focus"]["label"] == "Latest weight"
    assert kat["focus"]["value"] == "63.4 kg"
    assert "81.2" not in str(kat)
    assert any(action["kind"] == "log_food" for action in kat["quick_actions"])
