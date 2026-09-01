"""Owner isolation, token rotation and one-tap Strava activity import."""

import json
from datetime import date, datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse

import aiosqlite
import pytest
from cryptography.fernet import Fernet

from app.models.assistant import HermesAssistantResponse
from app.services.fitness import coach, strava, strava_enrichment
from app.services.hermes import FitnessHermesResponse
from app.utils.encryption import decrypt_value, encrypt_value


pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _strava_configuration(monkeypatch, tmp_path):
    monkeypatch.setattr(strava.settings, "strava_integration_enabled", True)
    monkeypatch.setattr(strava.settings, "strava_client_id", "client-id")
    monkeypatch.setattr(strava.settings, "strava_client_secret", "client-secret")
    monkeypatch.setattr(
        strava.settings,
        "strava_redirect_uri",
        "https://test/api/fitness/integrations/strava/callback",
    )
    monkeypatch.setattr(strava.settings, "web_app_url", "https://web.test")
    monkeypatch.setattr(
        strava.settings, "ha_token_encryption_key", Fernet.generate_key().decode()
    )
    monkeypatch.setattr(strava.settings, "fitness_cache_path", str(tmp_path / "fitness-cache"))


def _run(activity_id: int = 9001, *, name: str = "Morning run") -> dict:
    return {
        "id": activity_id,
        "name": name,
        "sport_type": "Run",
        "start_date": "2026-08-10T06:00:00Z",
        "timezone": "(GMT+01:00) Europe/London",
        "elapsed_time": 1_620,
        "moving_time": 1_580,
        "distance": 5_100.0,
        "total_elevation_gain": 48.0,
        "average_speed": 3.2278,
        "max_speed": 4.8,
        "has_heartrate": True,
        "average_heartrate": 151.5,
        "max_heartrate": 174,
        "average_cadence": 84.0,
        "device_name": "Garmin Forerunner",
        "map": {"summary_polyline": "_p~iF~ps|U_ulLnnqC_mqNvxq`@"},
        "private": True,
    }


def _recent_runs(count: int) -> list[dict]:
    latest = datetime(2026, 8, 12, 7, 24, tzinfo=timezone.utc)
    rows = []
    for index in range(count):
        item = _run(9_001 + index, name=f"Imported run {index + 1}")
        item["start_date"] = (latest - timedelta(days=index)).isoformat()
        rows.append(item)
    return rows


def _detailed_run(activity: dict) -> dict:
    return {
        **activity,
        # These fields only exist on DetailedActivity in Strava's contract.
        # They must not make the next summary-list sync look like a changed run.
        "calories": 420.0,
        "elev_high": 37.0,
        "elev_low": 22.0,
        "map": {
            **activity["map"],
            "polyline": "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        },
        "laps": [
            {
                "name": "Lap 1",
                "start_index": 0,
                "end_index": 2,
                "distance": 3_400.0,
                "elapsed_time": 1_000,
                "moving_time": 990,
                "average_heartrate": 148.0,
                "max_heartrate": 166.0,
                "average_speed": 3.4,
                "average_cadence": 83.0,
                "total_elevation_gain": 18.0,
            },
            {
                "name": "Lap 2",
                "start_index": 2,
                "end_index": 3,
                "distance": 1_700.0,
                "elapsed_time": 620,
                "moving_time": 590,
                "average_heartrate": 160.0,
                "max_heartrate": 174.0,
                "average_speed": 2.88,
                "average_cadence": 85.0,
                "total_elevation_gain": 2.0,
            },
        ],
    }


def _streams() -> dict:
    return {
        "time": {"data": [0, 500, 1_000, 1_580]},
        "distance": {"data": [0, 1_700, 3_400, 5_100]},
        "latlng": {"data": [[51.49, -0.12], [51.495, -0.115], [51.5, -0.11], [51.505, -0.105]]},
        "altitude": {"data": [22.0, 31.0, 37.0, 28.0]},
        "velocity_smooth": {"data": [3.0, 3.4, 3.3, 3.1]},
        "heartrate": {"data": [139, 148, 158, 174]},
        "cadence": {"data": [82, 84, 85, 85]},
        "watts": {"data": [250, 270, 265, 260]},
        "moving": {"data": [True, True, True, True]},
    }


async def _connect(client, headers, monkeypatch, activities=None):
    started = await client.post(
        "/api/fitness/integrations/strava/start",
        headers=headers,
        json={"return_surface": "web"},
    )
    assert started.status_code == 200, started.text
    query = parse_qs(urlparse(started.json()["authorization_url"]).query)
    assert query["scope"] == ["activity:read_all"]

    async def token_request(form):
        assert form["grant_type"] == "authorization_code"
        return {
            "access_token": "access-secret",
            "refresh_token": "refresh-secret",
            "expires_at": 2_000_000_000,
            "athlete": {"id": 42, "firstname": "Alex", "lastname": "Runner"},
        }

    async def provider(_token, path):
        rows = list(activities or [])
        if path.startswith("/athlete/activities?"):
            return rows
        if path.endswith("/streams?keys=time%2Cdistance%2Clatlng%2Caltitude%2Cvelocity_smooth%2Cheartrate%2Ccadence%2Cwatts%2Ctemp%2Cmoving%2Cgrade_smooth&key_by_type=true"):
            return _streams()
        activity_id = path.removeprefix("/activities/").split("?", 1)[0]
        matching = next((item for item in rows if str(item["id"]) == activity_id), None)
        assert matching is not None, path
        return _detailed_run(matching)

    monkeypatch.setattr(strava, "_token_request", token_request)
    monkeypatch.setattr(strava, "_strava_request", provider)
    callback = await client.get(
        "/api/fitness/integrations/strava/callback",
        params={
            "state": query["state"][0],
            "code": "provider-code",
            "scope": "read,activity:read_all",
        },
        follow_redirects=False,
    )
    assert callback.status_code == 303
    assert "strava=connected" in callback.headers["location"]


async def test_strava_connection_is_encrypted_owner_private_and_imports_on_connect(
    client, adult_a_headers, adult_b_headers, adult_a_user, initialized_db, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch, activities=[_run()])
    status = await client.get("/api/fitness/integrations/strava/status", headers=adult_a_headers)
    assert status.status_code == 200
    assert status.json()["connected"] is True
    assert status.json()["athlete_name"] == "Alex Runner"
    assert status.json()["imported_activity_count"] == 1
    assert (await client.get("/api/fitness/integrations/strava/status", headers=adult_b_headers)).json()["status"] == "not_connected"

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        connection = await (await db.execute("SELECT * FROM health_strava_connections")).fetchone()
        activity = await (await db.execute("SELECT * FROM health_activities WHERE title = 'Morning run'")).fetchone()
        source = await (await db.execute("SELECT * FROM health_source_records WHERE transport_key = 'strava_api'")).fetchone()
    assert connection["owner_user_id"] == adult_a_user["id"]
    assert "access-secret" not in connection["encrypted_token_json"]
    assert json.loads(decrypt_value(connection["encrypted_token_json"]))["refresh_token"] == "refresh-secret"
    assert activity["sport_key"] == "running"
    assert activity["distance_m"] == 5_100
    assert activity["energy_kcal"] == 420
    assert activity["primary_stream_asset_id"] is not None
    assert len(json.loads(activity["route_preview_json"])) == 4
    assert source["origin_provider_key"] == "strava"
    assert source["parser_version"] == strava.DETAILED_SOURCE_PARSER_VERSION
    assert source["source_device_identifier"] == "Garmin Forerunner"
    assert json.loads(connection["scopes_json"]) == ["activity:read_all", "read"]

    detail = await client.get(
        f"/api/fitness/activities/{activity['id']}", headers=adult_a_headers
    )
    assert detail.status_code == 200, detail.text
    assert {"route", "pace", "heart_rate", "elevation", "cadence", "power"}.issubset(
        set(detail.json()["recommended_panels"])
    )
    summary_metrics = {
        item["metric_key"]: item for item in detail.json()["summary_metrics"]
    }
    assert summary_metrics["running.average_pace_s_per_km"]["value_number"] == pytest.approx(
        1_000 / 3.2278
    )
    assert summary_metrics["running.average_pace_s_per_km"]["unit_key"] == "s/km"
    assert summary_metrics["cadence.average_spm"]["value_number"] == 168
    laps = [
        item
        for item in detail.json()["intervals"]
        if item["interval_kind"] == "source_lap"
    ]
    assert len(laps) == 2
    assert laps[0]["metrics"]["elapsed_duration_s"] == 1_000
    assert laps[0]["metrics"]["timer_duration_s"] == 990
    assert laps[0]["metrics"]["pace_s_per_km"] == pytest.approx(1_000 / 3.4)
    assert laps[0]["metrics"]["heart_rate.average_bpm"] == 148
    assert laps[0]["metrics"]["cadence.average_spm"] == 166
    assert laps[0]["metrics"]["elevation.change_m"] == 15
    assert laps[0]["metrics"]["elevation.gain_m"] == 18
    assert laps[1]["metrics"]["elevation.change_m"] == -9
    assert laps[1]["metrics"]["elevation.gain_m"] == 2
    kilometre_splits = [
        item
        for item in detail.json()["intervals"]
        if item["interval_kind"] == "kilometre_split"
    ]
    assert kilometre_splits[-1]["metrics"]["elevation.change_m"] < 0
    stream = await client.get(
        f"/api/fitness/activities/{activity['id']}/streams",
        headers=adult_a_headers,
        params={
            "metrics": (
                "pace_s_per_km,heart_rate_bpm,altitude_m,cadence_spm,power_w,"
                "latitude_deg,longitude_deg"
            )
        },
    )
    assert stream.status_code == 200, stream.text
    assert stream.json()["source_point_count"] == 4
    assert stream.json()["series"]["heart_rate_bpm"] == [139.0, 148.0, 158.0, 174.0]
    assert stream.json()["series"]["cadence_spm"] == [164.0, 168.0, 170.0, 170.0]
    assert stream.json()["series"]["altitude_m"] == [22.0, 31.0, 37.0, 28.0]
    assert stream.json()["series"]["latitude_deg"] == [51.49, 51.495, 51.5, 51.505]
    assert stream.json()["series"]["longitude_deg"] == [-0.12, -0.115, -0.11, -0.105]
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        evidence = await coach._activities_and_gear(
            db, user=adult_a_user, today=date(2026, 8, 10)
        )
    coach_activity = evidence["facts"]["recent_activities"][0]
    assert coach_activity["detail_level"] == "detailed"
    assert "heart_rate_bpm" in coach_activity["available_sample_metric_keys"]
    assert "running.average_pace_s_per_km" in {
        item["metric_key"] for item in coach_activity["summary_metrics"]
    }
    assert coach_activity["laps_and_splits"]
    assert {
        item["interval_kind"] for item in coach_activity["laps_and_splits"]
    } == {"kilometre_split"}


async def test_fitness_coach_gets_bounded_run_evidence_without_keyword_gating(
    client, adult_a_headers, adult_b_headers, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch, activities=_recent_runs(20))
    captured: list[dict] = []

    async def fake_coach(**kwargs):
        captured.append(kwargs)
        return FitnessHermesResponse(
            answer="I can see the recorded runs and can debrief them.",
            evidence_ids=["recent-activities-gear"],
            provider="openai-codex",
            model="fitness-test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", fake_coach)
    question = {
        "message": "Why didni fail my 10k attempt today",
        "intent": "discussion",
        "client_now": "2026-08-12T09:00:00+01:00",
        "timezone": "Europe/London",
    }
    response = await client.post(
        "/api/fitness/coach/message", headers=adult_a_headers, json=question
    )
    hidden = await client.post(
        "/api/fitness/coach/message", headers=adult_b_headers, json=question
    )

    assert response.status_code == 200, response.text
    assert hidden.status_code == 200, hidden.text
    evidence = {
        item["id"]: item for item in captured[0]["context"]["evidence"]
    }
    activity_evidence = evidence["recent-activities-gear"]
    activities = activity_evidence["facts"]["recent_activities"]
    assert len(activities) == 20
    assert [item["detail_level"] for item in activities[:4]] == [
        "detailed",
        "detailed",
        "detailed",
        "summary",
    ]
    latest = activities[0]
    assert latest["title"] == "Imported run 1"
    assert latest["started_at_utc"] == "2026-08-12T07:24:00+00:00"
    assert latest["distance_m"] == 5_100
    metric_values = {
        item["metric_key"]: item["value_number"]
        for item in latest["summary_metrics"]
    }
    assert metric_values["running.average_pace_s_per_km"] == pytest.approx(
        1_000 / 3.2278
    )
    assert metric_values["heart_rate.average_bpm"] == 151.5
    assert latest["laps_and_splits"]
    assert latest["analysis_findings"]
    assert "available_stream_metrics" not in latest
    assert len(json.dumps(captured[0]["context"], separators=(",", ":")).encode()) < 100_000

    adult_b_evidence_ids = {
        item["id"] for item in captured[1]["context"]["evidence"]
    }
    assert "recent-activities-gear" not in adult_b_evidence_ids

    bismarck_contexts: list[dict] = []

    async def fake_bismarck(*, message, history, context):
        bismarck_contexts.append(context)
        return HermesAssistantResponse(
            answer="Your most recent run is available here too.",
            actions=[],
        )

    monkeypatch.setattr("app.routers.assistant.ask_family_assistant", fake_bismarck)
    for headers in (adult_a_headers, adult_b_headers):
        bismarck = await client.post(
            "/api/assistant/message",
            headers=headers,
            json={
                "message": "Why didni fail my 10k attempt today",
                "client_now": "2026-08-12T09:00:00+01:00",
            },
        )
        assert bismarck.status_code == 200, bismarck.text

    adult_a_owner_fitness = bismarck_contexts[0]["family_records"]["owner_fitness"]
    bismarck_activities = next(
        item for item in adult_a_owner_fitness if item["id"] == "recent-activities-gear"
    )["facts"]["recent_activities"]
    assert bismarck_activities[0]["started_at_utc"] == "2026-08-12T07:24:00+00:00"
    assert bismarck_activities[0]["detail_level"] == "detailed"
    assert bismarck_contexts[1]["family_records"]["owner_fitness"] == []


async def test_fitness_coach_keeps_the_most_recent_run_even_when_it_is_old(
    client,
    adult_a_headers,
    monkeypatch,
):
    old_run = _run(9_099, name="January return run")
    old_run["start_date"] = "2025-01-15T07:00:00Z"
    await _connect(client, adult_a_headers, monkeypatch, activities=[old_run])
    captured: dict = {}

    async def fake_coach(**kwargs):
        captured.update(kwargs["context"])
        return FitnessHermesResponse(
            answer="I can see the latest recorded run.",
            evidence_ids=["recent-activities-gear"],
            provider="openai-codex",
            model="fitness-test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", fake_coach)
    response = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "Tell me about my most recent one",
            "intent": "discussion",
            "client_now": "2026-08-12T09:00:00+01:00",
            "timezone": "Europe/London",
        },
    )

    assert response.status_code == 200, response.text
    evidence = next(
        item for item in captured["evidence"] if item["id"] == "recent-activities-gear"
    )
    assert evidence["facts"]["recent_activities"][0]["title"] == "January return run"
    assert evidence["period"]["start"] == "2025-01-15"


async def test_fitness_coach_focuses_an_activity_and_its_nearest_training(
    client,
    adult_a_headers,
    monkeypatch,
):
    await _connect(client, adult_a_headers, monkeypatch, activities=_recent_runs(30))
    history = await client.get(
        "/api/fitness/activities",
        headers=adult_a_headers,
        params={"limit": 100},
    )
    assert history.status_code == 200, history.text
    target = next(
        item for item in history.json() if item["title"] == "Imported run 25"
    )
    captured: dict = {}

    async def fake_coach(**kwargs):
        captured.update(kwargs["context"])
        return FitnessHermesResponse(
            answer="This session makes sense alongside the runs around it.",
            evidence_ids=["recent-activities-gear"],
            provider="openai-codex",
            model="fitness-test",
        )

    monkeypatch.setattr("app.routers.fitness_coach.ask_fitness_coach", fake_coach)
    response = await client.post(
        "/api/fitness/coach/message",
        headers=adult_a_headers,
        json={
            "message": "Review this activity in context.",
            "intent": "discussion",
            "context_ids": [target["id"]],
            "client_now": "2026-08-12T09:00:00+01:00",
            "timezone": "Europe/London",
        },
    )

    assert response.status_code == 200, response.text
    evidence = {
        item["id"]: item for item in captured["evidence"]
    }
    assert evidence["selected-context"]["source_ids"] == [target["id"]]
    activity_evidence = evidence["recent-activities-gear"]
    scope = activity_evidence["facts"]["activity_detail_scope"]
    assert scope["focus_activity_ids"] == [target["id"]]
    assert scope["selection"] == "nearest_to_focused_activity"
    activities = activity_evidence["facts"]["recent_activities"]
    focused = next(item for item in activities if item["id"] == target["id"])
    assert focused["detail_level"] == "detailed"
    assert {item["title"] for item in activities}.issuperset(
        {"Imported run 24", "Imported run 25", "Imported run 26"}
    )
    assert all(item["title"] != "Imported run 1" for item in activities)


async def test_strava_laps_keep_source_time_and_distance_without_sample_stream():
    enrichment = strava_enrichment.prepare_enrichment(
        _detailed_run(_run()),
        {},
    )

    laps = [
        item
        for item in enrichment.intervals
        if item["interval_kind"] == "source_lap"
    ]
    assert [
        (lap["start_offset_ms"], lap["end_offset_ms"])
        for lap in laps
    ] == [(0, 1_000_000), (1_000_000, 1_620_000)]
    assert [
        (lap["start_distance_m"], lap["end_distance_m"])
        for lap in laps
    ] == [(0.0, 3_400.0), (3_400.0, 5_100.0)]
    assert laps[1]["metrics"]["elapsed_duration_s"] == 620
    assert laps[1]["metrics"]["pace_s_per_km"] == pytest.approx(1_000 / 2.88)
    assert laps[1]["metrics"]["heart_rate.average_bpm"] == 160


@pytest.mark.parametrize("granted_scope", [None, "read", "activity:read"])
async def test_callback_rejects_missing_or_insufficient_provider_scope(
    client, adult_a_headers, initialized_db, monkeypatch, granted_scope
):
    started = await client.post(
        "/api/fitness/integrations/strava/start",
        headers=adult_a_headers,
        json={"return_surface": "web"},
    )
    assert started.status_code == 200, started.text
    query = parse_qs(urlparse(started.json()["authorization_url"]).query)
    token_request_called = False

    async def token_request(_form):
        nonlocal token_request_called
        token_request_called = True
        return {
            "access_token": "access-secret",
            "refresh_token": "refresh-secret",
            "expires_at": 2_000_000_000,
            "athlete": {"id": 42, "firstname": "Alex", "lastname": "Runner"},
        }

    monkeypatch.setattr(strava, "_token_request", token_request)
    params = {"state": query["state"][0], "code": "provider-code"}
    if granted_scope is not None:
        params["scope"] = granted_scope
    callback = await client.get(
        "/api/fitness/integrations/strava/callback",
        params=params,
        follow_redirects=False,
    )

    assert callback.status_code == 303
    assert "strava=failed" in callback.headers["location"]
    assert token_request_called is False
    status = await client.get(
        "/api/fitness/integrations/strava/status", headers=adult_a_headers
    )
    assert status.json()["status"] == "not_connected"
    async with aiosqlite.connect(initialized_db) as db:
        state_row = await (
            await db.execute(
                "SELECT consumed_at FROM health_strava_oauth_states"
            )
        ).fetchone()
        connection_count = await (
            await db.execute("SELECT COUNT(*) FROM health_strava_connections")
        ).fetchone()
    assert state_row[0] is not None
    assert connection_count[0] == 0


async def test_one_tap_sync_is_idempotent_and_disconnect_retains_history(
    client, adult_a_headers, initialized_db, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch, activities=[])
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_strava_connections SET status = 'provider_down', "
            "last_error_code = 'provider_unavailable'"
        )
        await db.commit()
    degraded = await client.get(
        "/api/fitness/integrations/strava/status", headers=adult_a_headers
    )
    assert degraded.json()["connected"] is True
    assert degraded.json()["status"] == "provider_down"
    calls = 0

    remote = _run(9002, name="Evening run")

    async def provider(_token, path):
        nonlocal calls
        calls += 1
        if path.startswith("/athlete/activities?"):
            return [remote]
        if "/streams?" in path:
            return _streams()
        return _detailed_run(remote)

    monkeypatch.setattr(strava, "_strava_request", provider)
    first = await client.post("/api/fitness/integrations/strava/sync", headers=adult_a_headers)
    second = await client.post("/api/fitness/integrations/strava/sync", headers=adult_a_headers)
    assert first.status_code == second.status_code == 200
    assert first.json()["imported_count"] == 1
    assert second.json()["unchanged_count"] == 1
    assert calls == 4

    disconnected = await client.delete("/api/fitness/integrations/strava", headers=adult_a_headers)
    assert disconnected.status_code == 200
    assert disconnected.json()["retained_activity_count"] == 1
    activities = await client.get("/api/fitness/activities?limit=50", headers=adult_a_headers)
    assert "Evening run" in {item["title"] for item in activities.json()}


async def test_strava_pull_matches_one_plausible_run_planned_for_that_day(
    client,
    adult_a_headers,
    adult_a_user,
    initialized_db,
    monkeypatch,
):
    await _connect(client, adult_a_headers, monkeypatch, activities=[])
    planned = await client.post(
        "/api/fitness/planned-sessions",
        headers=adult_a_headers,
        json={
            "sport_key": "running",
            "title": "Monday easy 5K",
            "local_timezone": "Europe/London",
            "status": "accepted",
            "session_source": "user",
            "scheduled_start_utc": "2026-08-10T18:00:00Z",
            "expected_duration_s": 1_800,
            "expected_distance_m": 5_000,
            "movable": True,
        },
    )
    assert planned.status_code == 201, planned.text
    remote = _run(9_050, name="Morning easy 5K")

    async def provider(_token, path):
        if path.startswith("/athlete/activities?"):
            return [remote]
        if "/streams?" in path:
            return _streams()
        return _detailed_run(remote)

    monkeypatch.setattr(strava, "_strava_request", provider)
    pulled = await client.post(
        "/api/fitness/integrations/strava/sync", headers=adult_a_headers
    )
    assert pulled.status_code == 200, pulled.text
    assert pulled.json()["imported_count"] == 1

    activities = await client.get("/api/fitness/activities", headers=adult_a_headers)
    assert activities.status_code == 200, activities.text
    imported = next(item for item in activities.json() if item["title"] == "Morning easy 5K")
    assert imported["planned_session_id"] == planned.json()["id"]
    assert imported["planned_session_title"] == "Monday easy 5K"
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        link = await (
            await db.execute(
                "SELECT match_method, user_confirmed FROM health_plan_activity_links "
                "WHERE planned_session_id = ? AND active = 1",
                (planned.json()["id"],),
            )
        ).fetchone()
    assert link["match_method"] == "conservative_same_day_sport_duration"
    assert link["user_confirmed"] == 0
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        evidence = await coach._plan_outcomes(
            db, user=adult_a_user, today=date(2026, 8, 10)
        )
    assert evidence is not None
    outcome = evidence["facts"]["plan_outcomes"][0]
    assert outcome["planned_title"] == "Monday easy 5K"
    assert outcome["activity_title"] == "Morning easy 5K"
    assert outcome["adherence"]["status"] == "complete"


async def test_changed_activity_does_not_erase_a_valid_stream_when_provider_returns_empty_streams(
    client, adult_a_headers, initialized_db, monkeypatch
):
    original = _run(9003, name="Morning run")
    await _connect(client, adult_a_headers, monkeypatch, activities=[original])
    async with aiosqlite.connect(initialized_db) as db:
        before = await (
            await db.execute(
                "SELECT primary_stream_asset_id FROM health_activities "
                "WHERE title = 'Morning run'"
            )
        ).fetchone()
    assert before[0] is not None

    changed = _run(9003, name="Renamed morning run")

    async def provider(_token, path):
        if path.startswith("/athlete/activities?"):
            return [changed]
        if "/streams?" in path:
            return {}
        return _detailed_run(changed)

    monkeypatch.setattr(strava, "_strava_request", provider)
    response = await client.post(
        "/api/fitness/integrations/strava/sync", headers=adult_a_headers
    )
    assert response.status_code == 200, response.text

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        activity = await (
            await db.execute(
                "SELECT primary_stream_asset_id FROM health_activities "
                "WHERE title = 'Renamed morning run'"
            )
        ).fetchone()
        active_streams = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_activity_stream_assets "
                "WHERE deleted_at IS NULL"
            )
        ).fetchone()
        metadata_row = await (
            await db.execute(
                "SELECT metadata_json FROM health_source_records "
                "WHERE transport_key = 'strava_api'"
            )
        ).fetchone()
    assert activity["primary_stream_asset_id"] == before[0]
    assert active_streams[0] == 1
    assert json.loads(metadata_row["metadata_json"])["summary_fingerprint"] == strava._summary_fingerprint(original)


async def test_sync_upgrades_v2_laps_to_signed_elevation_change(
    client, adult_a_headers, initialized_db, monkeypatch
):
    run = _run(9004, name="Signed elevation run")
    await _connect(client, adult_a_headers, monkeypatch, activities=[run])
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_source_records SET parser_version = '2' "
            "WHERE transport_key = 'strava_api'"
        )
        await db.execute(
            "UPDATE health_activity_intervals SET metrics_json = ? "
            "WHERE interval_kind = 'source_lap' AND label = 'Lap 2'",
            (json.dumps({"elevation.gain_m": 2}),),
        )
        await db.commit()

    detailed_ids: list[str] = []

    async def provider(_token, path):
        if path.startswith("/athlete/activities?"):
            return [run]
        if "/streams?" in path:
            return _streams()
        detailed_ids.append(path.removeprefix("/activities/").split("?", 1)[0])
        return _detailed_run(run)

    monkeypatch.setattr(strava, "_strava_request", provider)
    response = await client.post(
        "/api/fitness/integrations/strava/sync", headers=adult_a_headers
    )
    assert response.status_code == 200, response.text
    assert detailed_ids == [str(run["id"])]

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        source = await (
            await db.execute(
                "SELECT parser_version, domain_entity_id FROM health_source_records "
                "WHERE transport_key = 'strava_api'"
            )
        ).fetchone()
        lap = await (
            await db.execute(
                "SELECT metrics_json FROM health_activity_intervals "
                "WHERE activity_id = ? AND interval_kind = 'source_lap' "
                "AND label = 'Lap 2' AND deleted_at IS NULL",
                (source["domain_entity_id"],),
            )
        ).fetchone()
    assert source["parser_version"] == strava.DETAILED_SOURCE_PARSER_VERSION
    assert json.loads(lap["metrics_json"])["elevation.change_m"] == -9


async def test_one_tap_sync_enriches_the_newest_activity_before_older_backfill(
    client, adult_a_headers, initialized_db, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch, activities=[])
    older = {**_run(9010, name="Older run"), "start_date": "2026-08-08T06:00:00Z"}
    newest = {**_run(9011, name="Newest run"), "start_date": "2026-08-10T06:00:00Z"}
    detailed_ids: list[str] = []

    async def provider(_token, path):
        if path.startswith("/athlete/activities?"):
            return [older, newest]
        if "/streams?" in path:
            return _streams()
        activity_id = path.removeprefix("/activities/").split("?", 1)[0]
        detailed_ids.append(activity_id)
        return _detailed_run(newest if activity_id == str(newest["id"]) else older)

    monkeypatch.setattr(strava, "MAX_DETAILED_ACTIVITIES_PER_SYNC", 1)
    monkeypatch.setattr(strava, "_strava_request", provider)
    response = await client.post(
        "/api/fitness/integrations/strava/sync", headers=adult_a_headers
    )

    assert response.status_code == 200, response.text
    assert response.json()["imported_count"] == 2
    assert detailed_ids == [str(newest["id"])]
    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT source_object_id, parser_version FROM health_source_records "
                "WHERE transport_key = 'strava_api' ORDER BY source_object_id"
            )
        ).fetchall()
    assert rows == [
        (str(older["id"]), "1"),
        (str(newest["id"]), strava.DETAILED_SOURCE_PARSER_VERSION),
    ]


async def test_sync_persists_stravas_rotated_refresh_token(
    client, adult_a_headers, initialized_db, monkeypatch
):
    await _connect(client, adult_a_headers, monkeypatch, activities=[])
    expired = encrypt_value(
        json.dumps(
            {
                "access_token": "expired-access",
                "refresh_token": "old-refresh",
                "expires_at": 1,
                "token_type": "Bearer",
            }
        )
    )
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE health_strava_connections SET encrypted_token_json = ?, "
            "access_token_expires_at = ?",
            (expired, "1970-01-01T00:00:01+00:00"),
        )
        await db.commit()

    async def token_request(form):
        assert form == {
            "client_id": "client-id",
            "client_secret": "client-secret",
            "grant_type": "refresh_token",
            "refresh_token": "old-refresh",
        }
        return {
            "access_token": "rotated-access",
            "refresh_token": "rotated-refresh",
            "expires_at": 2_100_000_000,
        }

    async def provider(token, _path):
        assert token == "rotated-access"
        return []

    monkeypatch.setattr(strava, "_token_request", token_request)
    monkeypatch.setattr(strava, "_strava_request", provider)
    response = await client.post(
        "/api/fitness/integrations/strava/sync", headers=adult_a_headers
    )
    assert response.status_code == 200

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        connection = await (
            await db.execute("SELECT * FROM health_strava_connections")
        ).fetchone()
    stored = json.loads(decrypt_value(connection["encrypted_token_json"]))
    assert stored["access_token"] == "rotated-access"
    assert stored["refresh_token"] == "rotated-refresh"
