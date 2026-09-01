"""Focused contracts for FIT ingestion, running plans and Fitness file privacy."""

import ast
import io
import json
import struct
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import aiosqlite
import fitdecode
import pytest
from starlette.datastructures import Headers, UploadFile

from app.config import settings
from app.fitness_worker import decode_fit_to_manifest, load_parser_job
from app.services.fitness.activity_import import FitImportProvenance, stage_fit_import
from app.services.fitness.run_plans import _definition, _fit_crc


pytestmark = pytest.mark.asyncio


def _activity_fit() -> bytes:
    """Build a small standards-valid running activity without a binary fixture."""
    fit_epoch = datetime(1989, 12, 31, tzinfo=timezone.utc)
    started = datetime(2026, 8, 2, 8, tzinfo=timezone.utc)
    start = int((started - fit_epoch).total_seconds())
    messages = [
        _definition(0, 0, [(0, 1, 0), (1, 2, 0x84), (2, 2, 0x84), (4, 4, 0x86)]),
        bytes([0]) + struct.pack("<BHHI", 4, 1, 123, start),
        _definition(
            1,
            20,
            [(253, 4, 0x86), (5, 4, 0x86), (6, 2, 0x84), (3, 1, 0x02)],
        ),
    ]
    for index in range(21):
        messages.append(
            bytes([1])
            + struct.pack(
                "<IIHB",
                start + index * 30,
                index * 15_000,
                5_000,
                140 + index % 5,
            )
        )
    messages.extend(
        [
            _definition(
                2,
                18,
                [
                    (253, 4, 0x86),
                    (2, 4, 0x86),
                    (5, 1, 0),
                    (6, 1, 0),
                    (7, 4, 0x86),
                    (8, 4, 0x86),
                    (9, 4, 0x86),
                    (11, 2, 0x84),
                    (14, 2, 0x84),
                    (15, 2, 0x84),
                    (16, 1, 0x02),
                    (17, 1, 0x02),
                ],
            ),
            bytes([2])
            + struct.pack(
                "<IIBBIIIHHHBB",
                start + 600,
                start,
                1,
                0,
                600_000,
                600_000,
                300_000,
                250,
                5_000,
                5_200,
                142,
                150,
            ),
        ]
    )
    data = b"".join(messages)
    header_without_crc = struct.pack("<BBHI4s", 14, 0x20, 2160, len(data), b".FIT")
    header = header_without_crc + struct.pack("<H", _fit_crc(header_without_crc))
    body = header + data
    return body + struct.pack("<H", _fit_crc(body))


def _fitness_paths(monkeypatch, tmp_path: Path) -> tuple[Path, Path]:
    source = tmp_path / "health"
    cache = tmp_path / "cache" / "health"
    exchange = tmp_path / "fitness-worker-exchange"
    monkeypatch.setattr(settings, "fitness_storage_path", str(source))
    monkeypatch.setattr(settings, "fitness_cache_path", str(cache))
    monkeypatch.setattr(settings, "fitness_worker_exchange_path", str(exchange))
    monkeypatch.setattr(settings, "fitness_worker_token", "w" * 48)
    return source, cache


async def test_fit_import_worker_stream_reconciliation_and_file_privacy(
    client,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    monkeypatch,
    tmp_path,
):
    source_root, cache_root = _fitness_paths(monkeypatch, tmp_path)
    client_import_id = str(uuid.uuid4())
    uploaded = await client.post(
        "/api/fitness/imports/fit",
        headers=adult_a_headers,
        data={"client_import_id": client_import_id},
        files={"file": ("morning.fit", _activity_fit(), "application/vnd.ant.fit")},
    )
    assert uploaded.status_code == 202, uploaded.text
    receipt = uploaded.json()
    assert receipt["source_retained"] is True
    assert receipt["source_record_id"]

    replay = await client.post(
        "/api/fitness/imports/fit",
        headers=adult_a_headers,
        data={"client_import_id": client_import_id},
        files={"file": ("morning.fit", _activity_fit(), "application/vnd.ant.fit")},
    )
    assert replay.json()["id"] == receipt["id"]
    assert (
        await client.get(f"/api/fitness/imports/{receipt['id']}", headers=adult_b_headers)
    ).status_code == 404
    adult_b_uploaded = await client.post(
        "/api/fitness/imports/fit",
        headers=adult_b_headers,
        data={"client_import_id": str(uuid.uuid4())},
        files={"file": ("kat-run.fit", _activity_fit(), "application/vnd.ant.fit")},
    )
    assert adult_b_uploaded.status_code == 202, adult_b_uploaded.text
    adult_b_receipt = adult_b_uploaded.json()

    worker_headers = {"X-Fitness-Worker-Token": "w" * 48}
    claimed = await client.post(
        "/api/internal/fitness/jobs/claim", headers=worker_headers
    )
    assert claimed.status_code == 200, claimed.text
    job = claimed.json()["job"]
    parser_job = load_parser_job(
        tmp_path / "fitness-worker-exchange" / job["id"] / "job.json"
    )
    worker_source = Path(parser_job["payload"]["source_path"])
    assert worker_source.parent == tmp_path / "fitness-worker-exchange" / job["id"]
    assert worker_source.name == "input.fit"
    assert worker_source.is_file()
    decode_fit_to_manifest(
        parser_job["payload"]["source_path"],
        parser_job["payload"]["rows_temporary_path"],
        parser_job["payload"]["manifest_path"],
    )
    manifest_path = Path(parser_job["payload"]["manifest_path"])
    valid_manifest = manifest_path.read_text()
    hostile_manifest = json.loads(valid_manifest)
    hostile_manifest["stream"]["metric_index"][0]["created_by"] = "parser"
    manifest_path.write_text(json.dumps(hostile_manifest))
    rejected_result = await client.post(
        f"/api/internal/fitness/jobs/{job['id']}/complete",
        headers=worker_headers,
        json={"lease_token": job["lease_token"]},
    )
    assert rejected_result.status_code == 409
    manifest_path.write_text(valid_manifest)
    completed = await client.post(
        f"/api/internal/fitness/jobs/{job['id']}/complete",
        headers=worker_headers,
        json={
            "lease_token": job["lease_token"],
        },
    )
    assert completed.status_code == 200, completed.text
    assert not worker_source.exists()
    activity_id = completed.json()["activity_id"]
    incremental = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json={
            "sync_protocol_version": 1,
            "client_schema_version": 1,
            "client_app_version": "1.0",
            "client_build": "1",
            "platform": "ios",
            "device_id": str(uuid.uuid4()),
            "cursor": 0,
            "mutations": [],
        },
    )
    assert incremental.status_code == 200, incremental.text
    imported_context = next(
        change
        for change in incremental.json()["changes"]
        if change["entity_type"] == "activity_context"
        and change["entity_id"] == activity_id
    )
    assert imported_context["data"]["title"]

    detail = await client.get(
        f"/api/fitness/activities/{activity_id}", headers=adult_a_headers
    )
    assert detail.status_code == 200, detail.text
    assert detail.json()["activity"]["distance_m"] == pytest.approx(3_000)
    assert detail.json()["activity"]["planned_session_id"] is None
    assert (
        await client.get(
            f"/api/fitness/activities/{activity_id}", headers=adult_b_headers
        )
    ).status_code == 404
    stream = await client.get(
        f"/api/fitness/activities/{activity_id}/streams",
        headers=adult_a_headers,
        params={"metrics": "pace_s_per_km,heart_rate_bpm", "max_points": 10},
    )
    assert stream.status_code == 200, stream.text
    assert stream.json()["source_point_count"] == 21
    assert len(stream.json()["offset_ms"]) <= 10
    analysis = await client.get(
        f"/api/fitness/activities/{activity_id}/analysis", headers=adult_a_headers
    )
    assert set(analysis.json()) == {
        "findings",
        "records",
        "achievements",
        "data_quality",
        "training_load",
    }
    finding_keys = {item["key"] for item in analysis.json()["findings"]}
    assert {"pacing_variability", "split_balance", "start_discipline"} <= finding_keys
    assert {item["interval_kind"] for item in detail.json()["intervals"]} >= {
        "kilometre_split",
        "mile_split",
    }
    overlay = await client.get(
        f"/api/fitness/activities/{activity_id}/comparison-overlay",
        headers=adult_a_headers,
        params={"metrics": "pace_s_per_km,heart_rate_bpm", "points": 20},
    )
    assert overlay.status_code == 200, overlay.text
    assert len(overlay.json()["distance_m"]) == 20
    assert overlay.json()["activities"][0]["activity_id"] == activity_id
    exported = await client.get("/api/fitness/export", headers=adult_a_headers)
    assert exported.status_code == 200, exported.text
    with zipfile.ZipFile(io.BytesIO(exported.content)) as archive:
        assert any(
            name.startswith("normalized-streams/") and name.endswith(".parquet")
            for name in archive.namelist()
        )
    reanalysis = await client.post(
        f"/api/fitness/activities/{activity_id}/reanalyse", headers=adult_a_headers
    )
    assert reanalysis.status_code == 202, reanalysis.text
    assert reanalysis.json()["activity_id"] == activity_id

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        stream_asset = await (
            await db.execute(
                "SELECT f.storage_key FROM health_activities a "
                "JOIN health_activity_stream_assets s ON s.id = a.primary_stream_asset_id "
                "JOIN health_file_assets f ON f.id = s.file_asset_id WHERE a.id = ?",
                (activity_id,),
            )
        ).fetchone()
        source_asset = await (
            await db.execute(
                "SELECT f.storage_key FROM health_imports i "
                "JOIN health_file_assets f ON f.id = i.file_asset_id WHERE i.id = ?",
                (receipt["id"],),
            )
        ).fetchone()
        adult_b_source_asset = await (
            await db.execute(
                "SELECT f.storage_key FROM health_imports i "
                "JOIN health_file_assets f ON f.id = i.file_asset_id WHERE i.id = ?",
                (adult_b_receipt["id"],),
            )
        ).fetchone()
    stream_path = cache_root / stream_asset["storage_key"]
    source_path = source_root / source_asset["storage_key"]
    adult_b_source_path = source_root / adult_b_source_asset["storage_key"]
    stream_path.unlink()
    orphan = cache_root / "untracked.bin"
    orphan.write_bytes(b"orphan")
    reconciled = await client.post("/api/fitness/files/reconcile", headers=adult_a_headers)
    assert reconciled.status_code == 200, reconciled.text
    result = reconciled.json()
    assert result["backup_eligible"] is True
    assert result["regeneration_job_ids"]
    assert {
        "root": "cache",
        "storage_class": "regenerable",
        "storage_key": "untracked.bin",
    } in result["orphan_storage_keys"]

    assert (await client.delete("/api/auth/me", headers=adult_a_headers)).status_code == 204
    assert not source_path.exists()
    assert not stream_path.exists()
    assert adult_b_source_path.is_file()
    assert (
        await client.get(
            f"/api/fitness/imports/{adult_b_receipt['id']}", headers=adult_b_headers
        )
    ).status_code == 200


async def test_intervals_garmin_fit_promotes_matching_healthkit_summary(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
    tmp_path,
):
    _fitness_paths(monkeypatch, tmp_path)
    healthkit = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json={
            "source_bundle_identifier": "com.garmin.connect.mobile",
            "workout_uuid": str(uuid.uuid4()),
            "origin_provider_key": "garmin",
            "external_uuid": "healthkit-garmin-run",
            "source_name": "Garmin Connect",
            "source_device_identifier": "forerunner-970",
            "sport_key": "running",
            "title": "Edited morning run",
            "started_at_utc": "2026-08-02T08:00:00Z",
            "ended_at_utc": "2026-08-02T08:10:00Z",
            "duration_s": 600,
            "distance_m": 3000,
            "energy_kcal": 250,
            "local_timezone": "Europe/Berlin",
        },
    )
    assert healthkit.status_code == 200, healthkit.text
    activity_id = healthkit.json()["activity_id"]
    edited = await client.patch(
        f"/api/fitness/activities/{activity_id}/context",
        headers=adult_a_headers,
        json={
            "title": "My morning run",
            "notes": "Felt smooth",
            "session_rpe": 6,
            "workout_classification": "tempo",
        },
    )
    assert edited.status_code == 200, edited.text

    upload = UploadFile(
        io.BytesIO(_activity_fit()),
        filename="intervals-i-run.fit",
        headers=Headers({"content-type": "application/vnd.ant.fit"}),
    )
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        receipt = await stage_fit_import(
            db,
            user=adult_a_user,
            file=upload,
            client_import_id="intervals_icu:athlete:i-run",
            provenance=FitImportProvenance(
                transport_key="intervals_icu",
                origin_provider_key="garmin",
                source_namespace="intervals_icu:athlete",
                source_object_id="i-run",
                source_name="Intervals.icu / Garmin Connect",
            ),
        )
    await upload.close()

    worker_headers = {"X-Fitness-Worker-Token": "w" * 48}
    claimed = await client.post(
        "/api/internal/fitness/jobs/claim", headers=worker_headers
    )
    job = claimed.json()["job"]
    parser_job = load_parser_job(
        tmp_path / "fitness-worker-exchange" / job["id"] / "job.json"
    )
    assert parser_job["payload"]["import_id"] == receipt["id"]
    decode_fit_to_manifest(
        parser_job["payload"]["source_path"],
        parser_job["payload"]["rows_temporary_path"],
        parser_job["payload"]["manifest_path"],
    )
    completed = await client.post(
        f"/api/internal/fitness/jobs/{job['id']}/complete",
        headers=worker_headers,
        json={
            "lease_token": job["lease_token"],
        },
    )
    assert completed.status_code == 200, completed.text
    assert completed.json()["activity_id"] == activity_id

    detail = await client.get(
        f"/api/fitness/activities/{activity_id}", headers=adult_a_headers
    )
    assert detail.status_code == 200, detail.text
    assert detail.json()["activity"]["title"] == "My morning run"
    assert detail.json()["activity"]["distance_m"] == pytest.approx(3000)

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        activity = await (
            await db.execute(
                "SELECT * FROM health_activities WHERE id = ?", (activity_id,)
            )
        ).fetchone()
        roles = await (
            await db.execute(
                "SELECT s.transport_key, l.role FROM health_activity_source_records l "
                "JOIN health_source_records s ON s.id = l.source_record_id "
                "WHERE l.activity_id = ? AND l.deleted_at IS NULL ORDER BY s.transport_key",
                (activity_id,),
            )
        ).fetchall()
        count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_activities WHERE owner_user_id = ? "
                "AND deleted_at IS NULL",
                (adult_a_user["id"],),
            )
        ).fetchone()
    assert activity["primary_stream_asset_id"]
    assert activity["notes"] == "Felt smooth"
    assert activity["session_rpe"] == 6
    assert activity["workout_classification"] == "tempo"
    assert [(row["transport_key"], row["role"]) for row in roles] == [
        ("healthkit", "corroborating"),
        ("intervals_icu", "primary"),
    ]
    assert count[0] == 1


async def test_running_plan_round_trip_accepts_and_exports_valid_fit(
    client, adult_a_headers, monkeypatch, tmp_path
):
    _, cache_root = _fitness_paths(monkeypatch, tmp_path)
    definition_id = str(uuid.uuid4())
    version_id = str(uuid.uuid4())
    leaf_id = str(uuid.uuid4())
    repeat_id = str(uuid.uuid4())
    recovery_id = str(uuid.uuid4())
    created = await client.post(
        "/api/fitness/workout-definitions",
        headers=adult_a_headers,
        json={
            "id": definition_id,
            "sport_key": "running",
            "name": "Controlled 2.2 km",
            "version": {
                "id": version_id,
                "title": "Controlled 2.2 km",
                "estimated_distance_m": 2200,
                "run_steps": [
                    {
                        "sequence": 0,
                        "duration_type": "distance_m",
                        "duration_value": 1000,
                        "target_type": "pace_s_per_km",
                        "target_low": 330,
                        "target_high": 345,
                        "target_unit": "s/km",
                        "intensity_label": "warmup",
                        "display_name": "Warm up",
                    },
                    {
                        "id": repeat_id,
                        "sequence": 1,
                        "step_kind": "repeat_block",
                        "repeat_count": 2,
                        "duration_type": "open",
                        "target_type": "none",
                        "display_name": "Two controlled reps",
                        "children": [
                            {
                                "id": leaf_id,
                                "sequence": 0,
                                "duration_type": "distance_m",
                                "duration_value": 400,
                                "target_type": "heart_rate_bpm",
                                "target_low": 145,
                                "target_high": 165,
                                "target_unit": "bpm",
                                "intensity_label": "interval",
                                "display_name": "Controlled effort",
                            },
                            {
                                "id": recovery_id,
                                "sequence": 1,
                                "duration_type": "distance_m",
                                "duration_value": 200,
                                "target_type": "none",
                                "intensity_label": "recovery",
                                "display_name": "Easy recovery",
                            },
                        ],
                    },
                ],
                "run_cues": [
                    {
                        "step_id": leaf_id,
                        "sequence": 0,
                        "trigger_type": "step_start",
                        "short_text": "Relax and settle",
                    }
                ],
            },
        },
    )
    assert created.status_code == 201, created.text
    version = created.json()["current_version"]
    assert version["run_steps"][1]["children"][0]["id"] == leaf_id
    assert version["run_cues"][0]["step_id"] == leaf_id

    accepted = await client.post(
        f"/api/fitness/workout-definitions/{definition_id}/versions/{version_id}/accept",
        headers=adult_a_headers,
        json={},
    )
    assert accepted.status_code == 200, accepted.text
    assert accepted.json()["accepted_at"]
    exported = await client.post(
        f"/api/fitness/workout-versions/{version_id}/garmin-exports",
        headers=adult_a_headers,
    )
    assert exported.status_code == 202, exported.text
    assert exported.json()["status"] == "ready"
    downloaded = await client.get(
        f"/api/fitness/garmin-exports/{exported.json()['id']}/download",
        headers=adult_a_headers,
    )
    assert downloaded.status_code == 200, downloaded.text
    fit_path = tmp_path / "export.fit"
    fit_path.write_bytes(downloaded.content)
    names = []
    sport = None
    with fitdecode.FitReader(fit_path, check_crc=fitdecode.CrcCheck.RAISE) as reader:
        for frame in reader:
            if frame.frame_type != fitdecode.FIT_FRAME_DATA:
                continue
            names.append(frame.name)
            if frame.name == "workout":
                sport = frame.get_value("sport")
    assert sport == "running"
    assert names.count("workout_step") == 4

    # A ready export is idempotent, but a missing regenerable cache file must
    # never strand the accepted plan after restore or cache cleanup.
    repeated = await client.post(
        f"/api/fitness/workout-versions/{version_id}/garmin-exports",
        headers=adult_a_headers,
    )
    assert repeated.json()["id"] == exported.json()["id"]
    generated_path = next(cache_root.rglob("*.fit"))
    generated_path.unlink()
    assert (
        await client.get(
            f"/api/fitness/garmin-exports/{exported.json()['id']}/download",
            headers=adult_a_headers,
        )
    ).status_code == 409
    retried = await client.post(
        f"/api/fitness/garmin-exports/{exported.json()['id']}/retry",
        headers=adult_a_headers,
    )
    assert retried.status_code == 202, retried.text
    assert retried.json()["id"] == exported.json()["id"]
    assert retried.json()["status"] == "ready"
    assert generated_path.is_file()


async def test_worker_module_has_no_database_dependency():
    worker_path = Path(__file__).parents[1] / "app" / "fitness_worker.py"
    tree = ast.parse(worker_path.read_text())
    imported = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.append(node.module)
    assert not any(name in {"aiosqlite", "sqlite3", "app.database"} for name in imported)


async def test_healthkit_workout_import_is_exact_idempotent_and_source_safe(
    client, adult_a_headers, adult_b_headers, initialized_db
):
    workout_uuid = str(uuid.uuid4())
    payload = {
        "source_bundle_identifier": "com.apple.health",
        "workout_uuid": workout_uuid,
        "origin_provider_key": "apple_health",
        "external_uuid": "provider-workout-42",
        "source_name": "Apple Watch",
        "source_device_identifier": "watch-dom",
        "product_type": "Watch7,5",
        "sport_key": "running",
        "title": "Morning run",
        "started_at_utc": "2026-08-03T06:00:00+00:00",
        "ended_at_utc": "2026-08-03T06:31:00+00:00",
        "duration_s": 1800,
        "distance_m": 5000,
        "energy_kcal": 360,
        "local_timezone": "Europe/Berlin",
    }
    created = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json=payload,
    )
    assert created.status_code == 200, created.text
    receipt = created.json()
    assert receipt["status"] == "created"
    assert receipt["deleted"] is False
    source_lookup_path = (
        f"/api/fitness/imports/healthkit-workout/{workout_uuid}/sources"
    )
    sources = await client.get(source_lookup_path, headers=adult_a_headers)
    assert sources.status_code == 200, sources.text
    assert sources.json() == [
        {
            "source_record_id": receipt["source_record_id"],
            "source_bundle_identifier": payload["source_bundle_identifier"],
            "workout_uuid": workout_uuid,
            "origin_provider_key": payload["origin_provider_key"],
            "external_uuid": payload["external_uuid"],
            "activity_id": receipt["activity_id"],
        }
    ]
    assert (
        await client.get(source_lookup_path, headers=adult_b_headers)
    ).json() == []
    assert (
        await client.get(
            "/api/fitness/imports/healthkit-workout/not-a-uuid/sources",
            headers=adult_a_headers,
        )
    ).status_code == 422

    replay = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json=payload,
    )
    assert replay.status_code == 200, replay.text
    assert replay.json() == {**receipt, "status": "unchanged"}

    corrected = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json={**payload, "distance_m": 5100},
    )
    assert corrected.status_code == 200, corrected.text
    assert corrected.json()["status"] == "updated"
    assert corrected.json()["source_record_id"] == receipt["source_record_id"]
    assert corrected.json()["activity_id"] == receipt["activity_id"]

    corroborating_payload = {
        **payload,
        "source_bundle_identifier": "com.apple.health.workout-mirror",
        "workout_uuid": str(uuid.uuid4()),
        "distance_m": 5100,
    }
    corroborating = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json=corroborating_payload,
    )
    assert corroborating.status_code == 200, corroborating.text
    assert corroborating.json()["status"] == "created"
    assert corroborating.json()["activity_id"] == receipt["activity_id"]
    assert corroborating.json()["source_record_id"] != receipt["source_record_id"]
    corroborating_replay = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json=corroborating_payload,
    )
    assert corroborating_replay.json()["status"] == "unchanged"

    adult_b_copy = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_b_headers,
        json=payload,
    )
    assert adult_b_copy.status_code == 200, adult_b_copy.text
    assert adult_b_copy.json()["status"] == "created"
    assert adult_b_copy.json()["source_record_id"] != receipt["source_record_id"]
    assert adult_b_copy.json()["activity_id"] != receipt["activity_id"]
    adult_b_sources = await client.get(source_lookup_path, headers=adult_b_headers)
    assert [item["source_record_id"] for item in adult_b_sources.json()] == [
        adult_b_copy.json()["source_record_id"]
    ]

    deleted_primary = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json={
            "source_bundle_identifier": payload["source_bundle_identifier"],
            "workout_uuid": payload["workout_uuid"],
            "origin_provider_key": payload["origin_provider_key"],
            "external_uuid": payload["external_uuid"],
            "deleted": True,
        },
    )
    assert deleted_primary.json()["status"] == "deleted"
    assert (
        await client.get(source_lookup_path, headers=adult_a_headers)
    ).json() == []
    assert len(
        (await client.get(source_lookup_path, headers=adult_b_headers)).json()
    ) == 1
    assert (
        await client.get(
            f"/api/fitness/activities/{receipt['activity_id']}",
            headers=adult_a_headers,
        )
    ).status_code == 200

    deleted_last = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json={
            "source_bundle_identifier": corroborating_payload[
                "source_bundle_identifier"
            ],
            "workout_uuid": corroborating_payload["workout_uuid"],
            "origin_provider_key": corroborating_payload["origin_provider_key"],
            "external_uuid": corroborating_payload["external_uuid"],
            "deleted": True,
        },
    )
    assert deleted_last.json()["status"] == "deleted"
    assert (
        await client.get(
            f"/api/fitness/activities/{receipt['activity_id']}",
            headers=adult_a_headers,
        )
    ).status_code == 404
    repeated_delete = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json={
            "source_bundle_identifier": corroborating_payload[
                "source_bundle_identifier"
            ],
            "workout_uuid": corroborating_payload["workout_uuid"],
            "origin_provider_key": corroborating_payload["origin_provider_key"],
            "deleted": True,
        },
    )
    assert repeated_delete.json()["status"] == "already_deleted"

    restored = await client.post(
        "/api/fitness/imports/healthkit-workout",
        headers=adult_a_headers,
        json=corroborating_payload,
    )
    assert restored.status_code == 200, restored.text
    assert restored.json()["status"] == "updated"
    assert restored.json()["activity_id"] == receipt["activity_id"]
    restored_sources = await client.get(
        "/api/fitness/imports/healthkit-workout/"
        f"{corroborating_payload['workout_uuid']}/sources",
        headers=adult_a_headers,
    )
    assert [item["source_record_id"] for item in restored_sources.json()] == [
        corroborating.json()["source_record_id"]
    ]
    async with aiosqlite.connect(initialized_db) as db:
        adult_a_sources = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_source_records WHERE owner_user_id = ? "
                "AND record_kind = 'activity' AND transport_key = 'healthkit'",
                ("00000000-0000-0000-0000-000000000001",),
            )
        ).fetchone()
        leaked_strength_changes = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_change_log WHERE owner_user_id = ? "
                "AND entity_type = 'strength_session' AND entity_id = ?",
                (
                    "00000000-0000-0000-0000-000000000001",
                    receipt["activity_id"],
                ),
            )
        ).fetchone()
    assert adult_a_sources[0] == 2
    assert leaked_strength_changes[0] == 0


async def test_manual_completed_run_uses_latest_canonical_weight_and_stays_unplanned(
    client,
    adult_a_headers,
):
    weight = await client.post(
        "/api/fitness/body/measurements",
        headers=adult_a_headers,
        json={
            "metric_key": "body.weight_kg",
            "measured_at_utc": "2026-08-03T06:30:00Z",
            "local_timezone": "Europe/Berlin",
            "value": 80,
            "unit_key": "kg",
            "measurement_quality": "measured",
        },
    )
    assert weight.status_code == 201, weight.text

    defaults = await client.get(
        "/api/fitness/activities/manual-defaults", headers=adult_a_headers
    )
    assert defaults.status_code == 200, defaults.text
    assert defaults.json()["latest_weight_kg"] == 80

    created = await client.post(
        "/api/fitness/activities/manual",
        headers=adult_a_headers,
        json={
            "sport_key": "running",
            "title": "Holiday run",
            "started_at_utc": "2026-08-03T07:00:00Z",
            "local_timezone": "Europe/Berlin",
            "duration_s": 1_800,
            "distance_m": 5_000,
            "session_rpe": 6,
            "notes": "Watch was flat",
        },
    )
    assert created.status_code == 201, created.text
    activity = created.json()
    assert activity["status"] == "completed"
    assert activity["planned_session_id"] is None
    assert activity["distance_m"] == 5_000
    assert activity["timer_duration_s"] == 1_800
    assert activity["energy_kcal"] == pytest.approx(440)
    assert activity["energy_estimation_weight_kg"] == 80
    assert activity["energy_estimation_met"] == 11
    assert activity["energy_estimation_method"] == "adult_compendium_2024_met"

    detail = await client.get(
        f"/api/fitness/activities/{activity['id']}", headers=adult_a_headers
    )
    assert detail.status_code == 200, detail.text
    assert detail.json()["sources"] == []
    assert detail.json()["notes"] == "Watch was flat"


async def test_comparable_runs_suggest_exactly_five_and_keep_a_true_distance_peer(
    client,
    adult_a_headers,
):
    async def create_run(title: str, started_at: str, duration_s: float) -> str:
        response = await client.post(
            "/api/fitness/activities/manual",
            headers=adult_a_headers,
            json={
                "sport_key": "running",
                "title": title,
                "started_at_utc": started_at,
                "local_timezone": "Europe/London",
                "duration_s": duration_s,
                "distance_m": 5_000,
                "estimate_energy": False,
            },
        )
        assert response.status_code == 201, response.text
        return response.json()["id"]

    target_id = await create_run("Target 5K", "2026-08-09T08:00:00Z", 1_800)
    for index in range(6):
        await create_run(
            f"Recent 5K {index + 1}",
            f"2026-08-0{8 - index}T08:00:00Z",
            1_810 + index * 10,
        )
    old_distance_peer_id = await create_run(
        "Old slow 5K",
        "2024-01-01T08:00:00Z",
        9_000,
    )

    response = await client.get(
        f"/api/fitness/activities/{target_id}/comparisons",
        headers=adult_a_headers,
    )
    assert response.status_code == 200, response.text
    comparisons = response.json()

    assert len(comparisons) == 7
    assert [item["score"] for item in comparisons] == sorted(
        (item["score"] for item in comparisons), reverse=True
    )
    assert [item["selected"] for item in comparisons] == [
        True,
        True,
        True,
        True,
        True,
        False,
        False,
    ]
    old_distance_peer = next(
        item for item in comparisons if item["activity"]["id"] == old_distance_peer_id
    )
    assert old_distance_peer["score"] < 0.35
    assert "similar distance" in old_distance_peer["reasons"]
    assert old_distance_peer["algorithm_version"] == "comparable-runs-v3"


async def test_five_k_comparisons_default_to_five_similar_distance_runs(
    client,
    adult_a_headers,
):
    created = []
    for index, (distance_m, duration_s) in enumerate(
        [
            (4_980, 1_620),
            (5_010, 1_590),
            (5_030, 1_680),
            (4_950, 1_710),
            (5_050, 1_650),
            (5_000, 1_560),
            (5_000, 1_600),
        ]
    ):
        response = await client.post(
            "/api/fitness/activities/manual",
            headers=adult_a_headers,
            json={
                "sport_key": "running",
                "title": f"Recorded 5K {index + 1}",
                "started_at_utc": f"2026-07-{20 + index:02d}T07:00:00Z",
                "local_timezone": "Europe/London",
                "duration_s": duration_s,
                "distance_m": distance_m,
                "estimate_energy": False,
            },
        )
        assert response.status_code == 201, response.text
        created.append(response.json())

    target = created[-1]
    response = await client.get(
        f"/api/fitness/activities/{target['id']}/comparisons", headers=adult_a_headers
    )
    assert response.status_code == 200, response.text
    comparisons = response.json()
    assert len(comparisons) == 6
    assert sum(item["selected"] for item in comparisons) == 5
    assert all("similar distance" in item["reasons"] for item in comparisons)
    assert all(item["algorithm_version"] == "comparable-runs-v3" for item in comparisons)
    automatic = next(item for item in comparisons if item.get("is_previous_similar_distance"))
    assert automatic["activity"]["id"] == created[-2]["id"]
    assert automatic["automatic_comparison"] == {
        "algorithm_version": "previous-similar-distance-v1",
        "distance_label": "5K",
        "current_distance_m": 5_000,
        "previous_distance_m": 5_000,
        "distance_delta_m": 0,
        "current_duration_s": 1_600,
        "previous_duration_s": 1_560,
        "duration_delta_s": 40,
        "duration_improvement_s": -40,
        "current_pace_s_per_km": 320,
        "previous_pace_s_per_km": 312,
        "pace_delta_s_per_km": 8,
        "pace_improvement_s_per_km": -8,
    }


async def test_manual_activity_sync_saves_without_inventing_energy_when_weight_missing(
    client,
    adult_b_headers,
):
    activity_id = str(uuid.uuid4())
    mutation_id = str(uuid.uuid4())
    synced = await client.post(
        "/api/fitness/sync",
        headers=adult_b_headers,
        json={
            "sync_protocol_version": 1,
            "client_schema_version": 1,
            "client_app_version": "1.0",
            "client_build": "1",
            "platform": "ios",
            "device_id": str(uuid.uuid4()),
            "cursor": 0,
            "mutations": [
                {
                    "mutation_id": mutation_id,
                    "entity_type": "manual_activity",
                    "entity_id": activity_id,
                    "operation": "upsert",
                    "payload_schema_version": 1,
                    "base_revision": None,
                    "payload": {
                        "id": activity_id,
                        "sport_key": "walking",
                        "title": "Beach walk",
                        "started_at_utc": "2026-08-03T08:00:00Z",
                        "local_timezone": "Europe/Berlin",
                        "duration_s": 2_400,
                        "distance_m": 3_000,
                    },
                    "created_at_client": "2026-08-03T09:00:00Z",
                }
            ],
        },
    )
    assert synced.status_code == 200, synced.text
    assert synced.json()["accepted"] == [
        {"mutation_id": mutation_id, "entity_id": activity_id, "revision": 1}
    ]
    manual_change = next(
        change
        for change in synced.json()["changes"]
        if change["entity_type"] == "manual_activity"
        and change["entity_id"] == activity_id
    )
    assert manual_change["data"]["energy_kcal"] is None
    assert manual_change["data"]["status"] == "completed"
