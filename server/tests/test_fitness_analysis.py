"""Focused contracts for registered-key Fitness analysis and its worker path."""

import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import aiosqlite
import pyarrow as pa
import pyarrow.parquet as pq
import pytest

from app.config import settings
from app.fitness_worker import STREAM_SCHEMA, _run_job, load_parser_job
from app.services.fitness.common import insert_owned


pytestmark = pytest.mark.asyncio


async def _insert(db, table: str, user: dict, values: dict, *, record_id: str | None = None) -> str:
    identifier = record_id or str(uuid.uuid4())
    await insert_owned(
        db,
        table=table,
        record_id=identifier,
        values={**values, "revision": values.get("revision", 1)},
        user=user,
        now="2026-08-02T12:00:00+00:00",
        record_sync_change=False,
    )
    return identifier


def _query(
    measure_key: str,
    dimension_key: str,
    chart_type_key: str,
    *,
    start: str = "2026-07-01",
    end: str = "2026-07-31",
    comparison_key: str | None = None,
) -> dict:
    return {
        "measure_key": measure_key,
        "dimension_key": dimension_key,
        "chart_type_key": chart_type_key,
        "date_range": {"start": start, "end": end},
        "filters": [],
        "comparison_key": comparison_key,
        "max_points": 100,
    }


async def test_registry_validation_and_owner_private_saved_charts(
    client, adult_a_headers, adult_b_headers
):
    response = await client.get("/api/fitness/analysis/registry", headers=adult_a_headers)
    assert response.status_code == 200, response.text
    registry = response.json()
    assert set(registry) == {
        "dimensions",
        "measures",
        "chart_types",
        "filters",
        "comparisons",
        "limits",
        "default_queries",
    }
    advertised_charts = {item["key"] for item in registry["chart_types"]}
    reachable_charts = {
        chart for measure in registry["measures"] for chart in measure["chart_types"]
    }
    assert advertised_charts == reachable_charts
    meal_filter = next(item for item in registry["filters"] if item["key"] == "meal_key")
    assert {item["key"] for item in meal_filter["values"]} == {
        "breakfast",
        "lunch",
        "dinner",
        "snack",
        "drink",
        "pre_workout",
        "during_workout",
        "post_workout",
        "other",
    }

    unknown = await client.post(
        "/api/fitness/analysis/query",
        headers=adult_a_headers,
        json=_query("raw.sql", "date", "line"),
    )
    assert unknown.status_code == 409

    chart_id = str(uuid.uuid4())
    chart_payload = {
        "id": chart_id,
        "name": "Weekly distance",
        "measure_key": "running.distance_m",
        "dimension_key": "week",
        "chart_type_key": "bar",
        "filter_keys": ["sport_key"],
        "comparison_key": "previous_period",
        "date_window_days": 84,
    }
    rejected = await client.post(
        "/api/fitness/analysis/charts",
        headers=adult_a_headers,
        json={**chart_payload, "raw_sql": "select * from users"},
    )
    assert rejected.status_code == 422

    created = await client.post(
        "/api/fitness/analysis/charts", headers=adult_a_headers, json=chart_payload
    )
    assert created.status_code == 201, created.text
    saved = created.json()
    assert set(saved) == {
        "id",
        "name",
        "measure_key",
        "dimension_key",
        "chart_type_key",
        "filter_keys",
        "comparison_key",
        "date_window_days",
        "revision",
        "created_at",
        "updated_at",
    }
    assert saved["id"] == chart_id
    assert (await client.get("/api/fitness/analysis/charts", headers=adult_b_headers)).json() == []
    assert (
        await client.delete(
            f"/api/fitness/analysis/charts/{chart_id}", headers=adult_b_headers
        )
    ).status_code == 404
    deleted = await client.delete(
        f"/api/fitness/analysis/charts/{chart_id}", headers=adult_a_headers
    )
    assert deleted.status_code == 204
    assert deleted.content == b""


async def test_analysis_scoping_canonical_missingness_and_logical_groups(
    client,
    adult_a_headers,
    initialized_db,
    adult_a_user,
    adult_b_user,
):
    async with aiosqlite.connect(initialized_db) as db:
        for measured_at, value, state, owner in (
            ("2026-07-01T07:00:00+00:00", 70, "canonical", adult_a_user),
            ("2026-07-02T07:00:00+00:00", 72, "canonical", adult_a_user),
            ("2026-07-02T07:01:00+00:00", 99, "duplicate", adult_a_user),
            ("2026-07-01T07:00:00+00:00", 150, "canonical", adult_b_user),
        ):
            await _insert(
                db,
                "health_body_measurements",
                owner,
                {
                    "metric_key": "body.weight_kg",
                    "measured_at_utc": measured_at,
                    "local_timezone": "Europe/Berlin",
                    "value": value,
                    "unit_key": "kg",
                    "measurement_quality": "measured",
                    "canonical_state": state,
                },
            )

        for day, meal, calories, quality in (
            ("2026-06-29", "breakfast", 10, "measured"),
            ("2026-06-30", "dinner", 20, "estimated"),
            ("2026-07-01", "breakfast", 100, "measured"),
            ("2026-07-01", "dinner", None, "estimated"),
            ("2026-07-02", "lunch", 200, "measured"),
        ):
            await _insert(
                db,
                "health_food_log_entries",
                adult_a_user,
                {
                    "food_version_id": str(uuid.uuid4()),
                    "logged_at_utc": f"{day}T12:00:00+00:00",
                    "local_timezone": "Europe/Berlin",
                    "nutrition_date": day,
                    "meal_key": meal,
                    "entered_amount": 1,
                    "entered_unit": "serving",
                    "canonical_amount": 1,
                    "canonical_unit": "serving",
                    "measurement_quality": quality,
                    "calories_kcal": calories,
                },
            )

        for index in range(4):
            day = 3 + index
            activity_id = await _insert(
                db,
                "health_activities",
                adult_a_user,
                {
                    "sport_key": "running",
                    "title": f"Run {index}",
                    "status": "completed",
                    "started_at_utc": f"2026-07-{day:02d}T08:00:00+00:00",
                    "local_timezone": "Europe/Berlin",
                    "local_calendar_date": f"2026-07-{day:02d}",
                    "timer_duration_s": 1800,
                    "distance_m": 5000,
                    "measurement_quality": "measured",
                    "import_state": "not_imported",
                    "workout_classification": "easy",
                    "perceived_performance": index + 2,
                },
            )
            retrospective = index == 3
            await _insert(
                db,
                "health_session_checkins",
                adult_a_user,
                {
                    "activity_id": activity_id,
                    "timing": "pre",
                    "captured_at_utc": f"2026-07-{day:02d}T07:45:00+00:00",
                    "capture_quality": "retrospective" if retrospective else "contemporaneous",
                    "captured_before_activity_start": 0 if retrospective else 1,
                    "readiness_1_5": index + 1,
                },
            )

        adult_b_activity = await _insert(
            db,
            "health_activities",
            adult_b_user,
            {
                "sport_key": "running",
                "title": "Morgan run",
                "status": "completed",
                "started_at_utc": "2026-07-03T08:00:00+00:00",
                "local_timezone": "Europe/Berlin",
                "local_calendar_date": "2026-07-03",
                "timer_duration_s": 1800,
                "distance_m": 5000,
                "measurement_quality": "measured",
                "import_state": "not_imported",
                "workout_classification": "easy",
                "perceived_performance": 5,
            },
        )
        await _insert(
            db,
            "health_session_checkins",
            adult_b_user,
            {
                "activity_id": adult_b_activity,
                "timing": "pre",
                "captured_at_utc": "2026-07-03T07:45:00+00:00",
                "capture_quality": "contemporaneous",
                "captured_before_activity_start": 1,
                "readiness_1_5": 5,
            },
        )

        canonical_exercise = await _insert(
            db,
            "health_exercises",
            adult_a_user,
            {"name": "Canonical squat", "active": True},
        )
        alias_exercise = await _insert(
            db,
            "health_exercises",
            adult_a_user,
            {
                "name": "Old squat",
                "active": False,
                "merged_into_exercise_id": canonical_exercise,
            },
        )
        canonical_setup = await _insert(
            db,
            "health_exercise_setups",
            adult_a_user,
            {"exercise_id": canonical_exercise, "name": "Rack", "active": True},
        )
        alias_setup = await _insert(
            db,
            "health_exercise_setups",
            adult_a_user,
            {
                "exercise_id": alias_exercise,
                "name": "Old rack",
                "active": False,
                "merged_into_setup_id": canonical_setup,
            },
        )
        await _insert(
            db,
            "health_exercise_muscle_roles",
            adult_a_user,
            {
                "exercise_id": canonical_exercise,
                "muscle_group_key": "quadriceps",
                "role": "primary",
            },
        )
        strength_activity = await _insert(
            db,
            "health_activities",
            adult_a_user,
            {
                "sport_key": "strength",
                "title": "Squats",
                "status": "completed",
                "started_at_utc": "2026-07-07T08:00:00+00:00",
                "local_timezone": "Europe/Berlin",
                "local_calendar_date": "2026-07-07",
                "measurement_quality": "measured",
                "import_state": "not_imported",
            },
        )
        session_exercise = await _insert(
            db,
            "health_strength_session_exercises",
            adult_a_user,
            {
                "activity_id": strength_activity,
                "exercise_id": alias_exercise,
                "exercise_setup_id": alias_setup,
                "sequence": 0,
            },
        )
        group_id = await _insert(
            db,
            "health_strength_set_groups",
            adult_a_user,
            {
                "activity_id": strength_activity,
                "session_exercise_id": session_exercise,
                "sequence": 0,
                "training_role": "working",
                "structure_type": "drop",
                "status": "completed",
                "failure_state": "none",
            },
        )
        for component_index, load in enumerate((100, 80, 60)):
            await _insert(
                db,
                "health_strength_sets",
                adult_a_user,
                {
                    "set_group_id": group_id,
                    "component_index": component_index,
                    "component_status": "completed",
                    "reps": 5,
                    "normalized_external_load_kg": load,
                    "rir": 2,
                },
            )
        await db.commit()

    weight = await client.post(
        "/api/fitness/analysis/query",
        headers=adult_a_headers,
        json=_query(
            "body.weight_trend_kg",
            "date",
            "line",
            start="2026-07-01",
            end="2026-07-02",
        ),
    )
    assert weight.status_code == 200, weight.text
    assert weight.json()["status"] == "complete"
    assert weight.json()["metadata"]["sample_size"] == 2
    assert [point["value"] for point in weight.json()["series"][0]["points"]] == [70, 71]

    nutrition = await client.post(
        "/api/fitness/analysis/query",
        headers=adult_a_headers,
        json=_query(
            "nutrition.calories_kcal",
            "date",
            "stacked_bar",
            start="2026-07-01",
            end="2026-07-02",
        ),
    )
    assert nutrition.status_code == 200, nutrition.text
    nutrition_result = nutrition.json()
    assert nutrition_result["metadata"]["sample_size"] == 2
    assert nutrition_result["metadata"]["missing_count"] == 1
    assert {series["key"] for series in nutrition_result["series"]} == {
        "observed:breakfast",
        "observed:dinner",
        "observed:lunch",
    }

    comparison = await client.post(
        "/api/fitness/analysis/query",
        headers=adult_a_headers,
        json=_query(
            "nutrition.calories_kcal",
            "date",
            "line",
            start="2026-07-01",
            end="2026-07-02",
            comparison_key="previous_period",
        ),
    )
    assert comparison.status_code == 200, comparison.text
    assert comparison.json()["difference"]["value"] == 270

    readiness = await client.post(
        "/api/fitness/analysis/query",
        headers=adult_a_headers,
        json=_query(
            "relationship.readiness_outcome",
            "readiness",
            "scatter",
            start="2026-07-03",
            end="2026-07-06",
        ),
    )
    assert readiness.status_code == 200, readiness.text
    readiness_result = readiness.json()
    assert readiness_result["metadata"]["sample_size"] == 3
    assert len(readiness_result["series"][0]["points"]) == 3
    assert any("caused" in item for item in readiness_result["limitations"])

    hard_sets = await client.post(
        "/api/fitness/analysis/query",
        headers=adult_a_headers,
        json=_query(
            "strength.hard_sets",
            "exercise",
            "bar",
            start="2026-07-07",
            end="2026-07-07",
        ),
    )
    assert hard_sets.status_code == 200, hard_sets.text
    point = hard_sets.json()["series"][0]["points"][0]
    assert point["key"] == canonical_exercise
    assert point["label"] == "Canonical squat"
    assert point["value"] == 1


async def test_heavy_analysis_uses_owner_scoped_single_worker_path(
    client,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    adult_a_user,
    monkeypatch,
    tmp_path: Path,
):
    cache_root = tmp_path / "cache" / "health"
    storage_root = tmp_path / "health"
    monkeypatch.setattr(settings, "fitness_cache_path", str(cache_root))
    monkeypatch.setattr(settings, "fitness_storage_path", str(storage_root))
    exchange_root = tmp_path / "fitness-worker-exchange"
    monkeypatch.setattr(settings, "fitness_worker_exchange_path", str(exchange_root))
    monkeypatch.setattr(settings, "fitness_worker_token", "w" * 48)

    storage_key = f"streams/{adult_a_user['id']}/analysis.parquet"
    parquet_path = cache_root / storage_key
    parquet_path.parent.mkdir(parents=True, exist_ok=True)
    started = datetime(2026, 7, 10, 8, tzinfo=timezone.utc)
    rows = []
    for index in range(13):
        rows.append(
            {
                "sample_index": index,
                "timestamp_utc": started + timedelta(seconds=index * 30),
                "elapsed_ms": index * 30_000,
                "timer_ms": index * 30_000,
                "pace_s_per_km": None if index == 12 else 300.0 + index,
            }
        )
    pq.write_table(pa.Table.from_pylist(rows, schema=STREAM_SCHEMA), parquet_path)

    async with aiosqlite.connect(initialized_db) as db:
        file_asset_id = await _insert(
            db,
            "health_file_assets",
            adult_a_user,
            {
                "asset_kind": "activity_stream",
                "storage_class": "regenerable",
                "storage_key": storage_key,
                "media_type": "application/vnd.apache.parquet",
                "byte_size": parquet_path.stat().st_size,
                "state": "ready",
            },
        )
        activity_id = str(uuid.uuid4())
        stream_id = await _insert(
            db,
            "health_activity_stream_assets",
            adult_a_user,
            {
                "activity_id": activity_id,
                "file_asset_id": file_asset_id,
                "stream_kind": "primary",
                "format": "parquet",
                "schema_version": 1,
                "parser_version": "test",
                "row_count": len(rows),
            },
        )
        await _insert(
            db,
            "health_activities",
            adult_a_user,
            {
                "sport_key": "running",
                "title": "Stream run",
                "status": "completed",
                "primary_stream_asset_id": stream_id,
                "started_at_utc": started.isoformat(),
                "local_timezone": "Europe/Berlin",
                "local_calendar_date": "2026-07-10",
                "measurement_quality": "source_reported",
                "import_state": "complete",
                "workout_classification": "easy",
            },
            record_id=activity_id,
        )
        await db.commit()

    queued = await client.post(
        "/api/fitness/analysis/query",
        headers=adult_a_headers,
        json=_query(
            "running.stream_pace_distribution",
            "pace_bucket",
            "histogram",
            start="2026-07-10",
            end="2026-07-10",
        ),
    )
    assert queued.status_code == 200, queued.text
    queued_result = queued.json()
    assert queued_result["status"] == "queued"
    assert queued_result["poll_after_ms"] == 1000
    job_id = queued_result["job_id"]
    assert (
        await client.get(
            f"/api/fitness/analysis/jobs/{job_id}", headers=adult_b_headers
        )
    ).status_code == 404

    worker_headers = {"X-Fitness-Worker-Token": "w" * 48}
    claimed = await client.post(
        "/api/internal/fitness/jobs/claim", headers=worker_headers
    )
    assert claimed.status_code == 200, claimed.text
    job = claimed.json()["job"]
    assert job["id"] == job_id
    assert job["job_type"] == "analysis_query"
    parser_job = load_parser_job(exchange_root / job_id / "job.json")
    staged_source = Path(parser_job["payload"]["source_paths"][0])
    assert staged_source.parent == exchange_root / job_id / "analysis-inputs"
    assert staged_source.read_bytes() == parquet_path.read_bytes()
    _run_job(parser_job)
    completed = await client.post(
        f"/api/internal/fitness/jobs/{job_id}/complete",
        headers=worker_headers,
        json={
            "lease_token": job["lease_token"],
        },
    )
    assert completed.status_code == 200, completed.text

    result_response = await client.get(
        f"/api/fitness/analysis/jobs/{job_id}", headers=adult_a_headers
    )
    assert result_response.status_code == 200, result_response.text
    result = result_response.json()
    assert result["status"] == "complete"
    assert result["metadata"]["sample_size"] == 12
    assert result["metadata"]["missing_count"] == 1
    assert sum(point["sample_size"] for point in result["series"][0]["points"]) == 12
