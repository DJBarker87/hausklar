"""Focused Stage 13 contracts for provenance, recovery and private photos."""

import io
import uuid
from pathlib import Path

import aiosqlite
import pytest
from PIL import Image

from app.config import settings
from app.database import init_db
from app.fitness_worker import _run_job, load_parser_job

pytestmark = pytest.mark.asyncio


def _mutation(
    entity_type: str,
    entity_id: str,
    payload: dict | None = None,
    *,
    operation: str = "upsert",
) -> dict:
    return {
        "mutation_id": str(uuid.uuid4()),
        "entity_type": entity_type,
        "entity_id": entity_id,
        "operation": operation,
        "payload_schema_version": 1,
        "base_revision": None,
        "payload": payload or {},
        "created_at_client": "2026-08-02T10:00:00+00:00",
    }


def _sync(mutations: list[dict], cursor: int = 0) -> dict:
    return {
        "sync_protocol_version": 1,
        "client_schema_version": 1,
        "client_app_version": "1.0",
        "client_build": "1",
        "platform": "ios",
        "device_id": str(uuid.uuid4()),
        "cursor": cursor,
        "mutations": mutations,
    }


def _source(
    source_id: str,
    *,
    kind: str,
    transport: str,
    provider: str,
    namespace: str,
    object_id: str,
    domain_type: str,
    domain_id: str,
    external_id: str | None = None,
) -> dict:
    return {
        "id": source_id,
        "record_kind": kind,
        "sample_type": "HKQuantityTypeIdentifierBodyMass",
        "transport_key": transport,
        "origin_provider_key": provider,
        "source_namespace": namespace,
        "source_object_id": object_id,
        "external_object_id": external_id,
        "device_json": {"model": "test"},
        "metadata_json": {"was_user_entered": False},
        "domain_entity_type": domain_type,
        "domain_entity_id": domain_id,
        "state": "active",
    }


def _body(source_id: str, measured_at: str) -> dict:
    return {
        "metric_key": "body.weight_kg",
        "measured_at_utc": measured_at,
        "local_timezone": "Europe/Berlin",
        "value": 80.0,
        "unit_key": "kg",
        "source_record_id": source_id,
        "measurement_quality": "measured",
    }


async def test_provenance_orders_dependencies_reranks_and_recomputes_sleep(
    client, adult_a_headers, adult_b_headers, initialized_db
):
    direct_source, healthkit_source = str(uuid.uuid4()), str(uuid.uuid4())
    direct_weight, healthkit_weight = str(uuid.uuid4()), str(uuid.uuid4())
    sleep_id = str(uuid.uuid4())
    sleep_sources = [str(uuid.uuid4()) for _ in range(3)]
    recovery_sdnn, recovery_rmssd = str(uuid.uuid4()), str(uuid.uuid4())

    mutations = [
        # Dependents intentionally precede sources; the coordinator must sort them.
        _mutation("body_measurement", direct_weight, _body(direct_source, "2026-08-02T07:00:00Z")),
        _mutation("body_measurement", healthkit_weight, _body(healthkit_source, "2026-08-02T07:00:20Z")),
        _mutation(
            "sleep_session",
            sleep_id,
            {
                "sleep_start_utc": "2026-08-01T22:00:00Z",
                "sleep_end_utc": "2026-08-02T01:00:00Z",
                "duration_s": 10_800,
                "awake_duration_s": 0,
                "source_quality": "wearable",
                "source_record_id": sleep_sources[0],
                "source_stages": [
                    {
                        "stage": stage,
                        "start_at_utc": f"2026-08-0{day}T{hour}:00:00Z",
                        "end_at_utc": end,
                        "duration_s": 3_600,
                        "source_record_id": source_id,
                    }
                    for stage, day, hour, end, source_id in (
                        ("core", 1, 22, "2026-08-01T23:00:00Z", sleep_sources[0]),
                        ("deep", 1, 23, "2026-08-02T00:00:00Z", sleep_sources[1]),
                        ("rem", 2, "00", "2026-08-02T01:00:00Z", sleep_sources[2]),
                    )
                ],
            },
        ),
        _mutation(
            "recovery_observation",
            recovery_sdnn,
            {
                "metric_key": "recovery.hrv_sdnn_ms",
                "observed_at_utc": "2026-08-02T06:30:00Z",
                "value_number": 48,
                "unit_key": "ms",
            },
        ),
        _mutation(
            "recovery_observation",
            recovery_rmssd,
            {
                "metric_key": "recovery.hrv_rmssd_ms",
                "observed_at_utc": "2026-08-02T06:31:00Z",
                "value_number": 62,
                "unit_key": "ms",
            },
        ),
        _mutation(
            "source_record",
            direct_source,
            _source(
                direct_source,
                kind="body_measurement",
                transport="withings_api",
                provider="withings",
                namespace="withings",
                object_id="api-reading",
                external_id="same-reading",
                domain_type="body_measurement",
                domain_id=direct_weight,
            ),
        ),
        _mutation(
            "source_record",
            healthkit_source,
            _source(
                healthkit_source,
                kind="body_measurement",
                transport="healthkit",
                provider="withings",
                namespace="com.withings.wiScaleNG",
                object_id="hk-reading",
                external_id="same-reading",
                domain_type="body_measurement",
                domain_id=healthkit_weight,
            ),
        ),
        *[
            _mutation(
                "source_record",
                source_id,
                _source(
                    source_id,
                    kind="sleep_session",
                    transport="healthkit",
                    provider="apple_health",
                    namespace="com.apple.health",
                    object_id=f"sleep-stage-{index}",
                    domain_type="sleep_session",
                    domain_id=sleep_id,
                ),
            )
            for index, source_id in enumerate(sleep_sources)
        ],
    ]
    created = await client.post(
        "/api/fitness/sync", headers=adult_a_headers, json=_sync(mutations)
    )
    assert created.status_code == 200, created.text

    measurements = (
        await client.get(
            "/api/fitness/body/measurements",
            headers=adult_a_headers,
            params={"metric_key": "body.weight_kg"},
        )
    ).json()
    states = {item["id"]: item["canonical_state"] for item in measurements}
    assert states == {direct_weight: "canonical", healthkit_weight: "duplicate"}
    sources = {item["id"]: item["source"] for item in measurements}
    assert sources == {
        direct_weight: {
            "transport_key": "withings_api",
            "origin_provider_key": "withings",
            "source_namespace": "withings",
            "source_device_identifier": None,
            "state": "active",
        },
        healthkit_weight: {
            "transport_key": "healthkit",
            "origin_provider_key": "withings",
            "source_namespace": "com.withings.wiScaleNG",
            "source_device_identifier": None,
            "state": "active",
        },
    }

    priority_id = str(uuid.uuid4())
    preferred = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync(
            [
                _mutation(
                    "source_priority",
                    priority_id,
                    {
                        "metric_key": "body.weight_kg",
                        "origin_provider_key": "withings",
                        "transport_key": "healthkit",
                        "source_namespace": "com.withings.wiScaleNG",
                        "priority": 200,
                    },
                )
            ],
            cursor=created.json()["next_cursor"],
        ),
    )
    assert preferred.status_code == 200, preferred.text
    assert any(
        change["entity_type"] == "source_priority"
        and change["entity_id"] == priority_id
        for change in preferred.json()["changes"]
    )
    canonical_changes = {
        change["entity_id"]: change["data"]["canonical_state"]
        for change in preferred.json()["changes"]
        if change["entity_type"] == "body_measurement"
        and change["entity_id"] in {direct_weight, healthkit_weight}
    }
    assert canonical_changes == {
        direct_weight: "duplicate",
        healthkit_weight: "canonical",
    }

    async with aiosqlite.connect(initialized_db) as db:
        facts_before_override = await (
            await db.execute(
                "SELECT id, measured_at_utc, value, source_record_id "
                "FROM health_body_measurements WHERE id IN (?, ?) ORDER BY id",
                (direct_weight, healthkit_weight),
            )
        ).fetchall()
    assert (
        await client.post(
            f"/api/fitness/body/measurements/{direct_weight}/canonical-override",
            headers=adult_b_headers,
        )
    ).status_code == 404
    selected = await client.post(
        f"/api/fitness/body/measurements/{direct_weight}/canonical-override",
        headers=adult_a_headers,
    )
    assert selected.status_code == 200, selected.text
    assert selected.json() == {
        "canonical_measurement_id": direct_weight,
        "group_member_ids": [direct_weight, healthkit_weight],
        "manual_override": True,
    }
    overridden = (
        await client.get(
            "/api/fitness/body/measurements",
            headers=adult_a_headers,
            params={"metric_key": "body.weight_kg"},
        )
    ).json()
    assert {
        item["id"]: (
            item["canonical_state"],
            item["duplicate_of_measurement_id"],
            item["manual_canonical_override"],
        )
        for item in overridden
    } == {
        direct_weight: ("canonical", None, True),
        healthkit_weight: ("duplicate", direct_weight, False),
    }

    # A later source-priority rerank cannot undo the durable record choice.
    reprioritised = await client.post(
        "/api/fitness/source-priorities",
        headers=adult_a_headers,
        json={
            "id": priority_id,
            "metric_key": "body.weight_kg",
            "origin_provider_key": "withings",
            "transport_key": "healthkit",
            "source_namespace": "com.withings.wiScaleNG",
            "priority": 300,
        },
    )
    assert reprioritised.status_code == 201, reprioritised.text
    after_priority = (
        await client.get(
            "/api/fitness/body/measurements",
            headers=adult_a_headers,
            params={"metric_key": "body.weight_kg"},
        )
    ).json()
    assert next(
        item for item in after_priority if item["id"] == direct_weight
    )["canonical_state"] == "canonical"

    cleared = await client.delete(
        f"/api/fitness/body/measurements/{direct_weight}/canonical-override",
        headers=adult_a_headers,
    )
    assert cleared.status_code == 200, cleared.text
    assert cleared.json() == {
        "canonical_measurement_id": healthkit_weight,
        "group_member_ids": [direct_weight, healthkit_weight],
        "manual_override": False,
    }
    async with aiosqlite.connect(initialized_db) as db:
        facts_after_override = await (
            await db.execute(
                "SELECT id, measured_at_utc, value, source_record_id "
                "FROM health_body_measurements WHERE id IN (?, ?) ORDER BY id",
                (direct_weight, healthkit_weight),
            )
        ).fetchall()
    assert facts_after_override == facts_before_override

    bad_delete = _mutation("source_record", sleep_sources[2], {"tombstone": True}, operation="delete")
    rejected = await client.post(
        "/api/fitness/sync", headers=adult_a_headers, json=_sync([bad_delete])
    )
    assert rejected.status_code == 409

    deleted = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync([_mutation("source_record", sleep_sources[0], operation="delete")]),
    )
    assert deleted.status_code == 200, deleted.text
    sessions = (
        await client.get(
            "/api/fitness/sleep/sessions",
            headers=adult_a_headers,
            params={"from_date": "2026-08-01", "to_date": "2026-08-03"},
        )
    ).json()
    assert len(sessions) == 1
    session = sessions[0]
    assert session["source_record_id"] == sleep_sources[1]
    assert session["sleep_start_utc"].startswith("2026-08-01T23:00:00")
    assert session["duration_s"] == pytest.approx(7_200)
    assert {stage["source_record_id"] for stage in session["source_stages"]} == set(
        sleep_sources[1:]
    )

    summary = await client.get(
        "/api/fitness/recovery/summary",
        headers=adult_a_headers,
        params={"from_date": "2026-08-01", "to_date": "2026-08-03"},
    )
    assert summary.status_code == 200, summary.text
    baselines = {item["metric_key"]: item for item in summary.json()["baselines"]}
    assert baselines["recovery.hrv_sdnn_ms"]["current_value"] == 48
    assert baselines["recovery.hrv_rmssd_ms"]["current_value"] == 62
    async with aiosqlite.connect(initialized_db) as db:
        deleted_stage = await (
            await db.execute(
                "SELECT deleted_at FROM health_sleep_stages WHERE source_record_id = ?",
                (sleep_sources[0],),
            )
        ).fetchone()
        assert deleted_stage[0] is not None


async def test_body_canonical_override_migration_is_idempotent(tmp_path):
    path = tmp_path / "body-canonical-override.db"
    await init_db(str(path))
    async with aiosqlite.connect(path) as db:
        await db.execute(
            "ALTER TABLE health_body_measurements DROP COLUMN manual_canonical_override"
        )
        await db.commit()

    await init_db(str(path))
    await init_db(str(path))
    async with aiosqlite.connect(path) as db:
        columns = await (
            await db.execute("PRAGMA table_info(health_body_measurements)")
        ).fetchall()
    override = next(row for row in columns if row[1] == "manual_canonical_override")
    assert override[2].upper() == "INTEGER"
    assert override[3] == 1
    assert override[4] == "0"


def _png_bytes() -> bytes:
    output = io.BytesIO()
    Image.new("RGB", (64, 96), "navy").save(output, format="PNG")
    return output.getvalue()


async def test_private_photo_two_phase_worker_reconciliation_and_cancellation(
    client,
    adult_a_headers,
    adult_b_headers,
    initialized_db,
    monkeypatch,
    tmp_path: Path,
):
    source_root = tmp_path / "health"
    cache_root = tmp_path / "cache" / "health"
    monkeypatch.setattr(settings, "fitness_storage_path", str(source_root))
    monkeypatch.setattr(settings, "fitness_cache_path", str(cache_root))
    exchange_root = tmp_path / "fitness-worker-exchange"
    monkeypatch.setattr(settings, "fitness_worker_exchange_path", str(exchange_root))
    monkeypatch.setattr(settings, "fitness_worker_token", "p" * 48)
    original = _png_bytes()
    asset_id, photo_id = str(uuid.uuid4()), str(uuid.uuid4())
    uploaded = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": asset_id, "asset_kind": "progress_photo"},
        files={"file": ("front.png", original, "image/png")},
    )
    assert uploaded.status_code == 201, uploaded.text
    assert uploaded.json() == {
        "asset_id": asset_id,
        "state": "staged",
        "storage_class": "private_required",
        "upload_acknowledged": True,
    }
    assert (
        await client.delete(
            f"/api/fitness/files/private/{asset_id}", headers=adult_b_headers
        )
    ).status_code == 204

    saved_sync = await client.post(
        "/api/fitness/sync",
        headers=adult_a_headers,
        json=_sync(
            [
                _mutation(
                    "progress_photo",
                    photo_id,
                    {
                        "id": photo_id,
                        "captured_at": "2026-08-02T07:30:00Z",
                        "pose": "front",
                        "body_weight_kg": 80,
                        "measurement_snapshot_json": {"waist_cm": 83.5},
                        "original_asset_id": asset_id,
                        "notes": "Baseline",
                    },
                )
            ]
        ),
    )
    assert saved_sync.status_code == 200, saved_sync.text
    assert saved_sync.json()["accepted"][0]["entity_id"] == photo_id
    saved = await client.get(
        f"/api/fitness/progress-photos/{photo_id}", headers=adult_a_headers
    )
    assert saved.status_code == 200, saved.text
    assert saved.json()["metadata_acknowledged"] is True
    assert saved.json()["original_state"] == "ready"
    assert saved.json()["measurement_snapshot_json"] == {"waist_cm": 83.5}
    assert (
        await client.get(
            f"/api/fitness/progress-photos/{photo_id}", headers=adult_b_headers
        )
    ).status_code == 404
    original_response = await client.get(
        f"/api/fitness/progress-photos/{photo_id}/original", headers=adult_a_headers
    )
    assert original_response.status_code == 200
    assert original_response.content == original

    queued = await client.post(
        f"/api/fitness/progress-photos/{photo_id}/thumbnail/regenerate",
        headers=adult_a_headers,
    )
    assert queued.status_code == 200, queued.text
    assert queued.json()["id"] == photo_id
    assert queued.json()["status"] == "queued"
    worker_headers = {"X-Fitness-Worker-Token": "p" * 48}
    claim = await client.post("/api/internal/fitness/jobs/claim", headers=worker_headers)
    assert claim.status_code == 200, claim.text
    job = claim.json()["job"]
    assert job["job_type"] == "photo_thumbnail"
    parser_job = load_parser_job(exchange_root / job["id"] / "job.json")
    worker_source = Path(parser_job["payload"]["source_path"])
    assert worker_source.parent == exchange_root / job["id"]
    assert worker_source.name == "input.photo"
    assert worker_source.is_file()
    _run_job(parser_job)
    completed = await client.post(
        f"/api/internal/fitness/jobs/{job['id']}/complete",
        headers=worker_headers,
        json={
            "lease_token": job["lease_token"],
        },
    )
    assert completed.status_code == 200, completed.text
    assert not worker_source.exists()
    thumbnail = await client.get(
        f"/api/fitness/progress-photos/{photo_id}/thumbnail", headers=adult_a_headers
    )
    assert thumbnail.status_code == 200
    assert thumbnail.content.startswith(b"\xff\xd8")

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        assets = await (
            await db.execute(
                "SELECT id, storage_key, storage_class FROM health_file_assets "
                "WHERE owner_user_id = ? AND deleted_at IS NULL",
                ("00000000-0000-0000-0000-000000000001",),
            )
        ).fetchall()
    original_asset = next(row for row in assets if row["id"] == asset_id)
    thumbnail_asset = next(row for row in assets if row["storage_class"] == "regenerable")
    thumbnail_path = cache_root / thumbnail_asset["storage_key"]
    thumbnail_path.unlink()
    reconciled = await client.post("/api/fitness/files/reconcile", headers=adult_a_headers)
    assert reconciled.status_code == 200, reconciled.text
    assert thumbnail_asset["id"] in reconciled.json()["regenerable_missing_asset_ids"]
    assert reconciled.json()["regeneration_job_ids"]

    staged_id = str(uuid.uuid4())
    staged = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": staged_id, "asset_kind": "progress_photo"},
        files={"file": ("unused.png", original, "image/png")},
    )
    assert staged.status_code == 201
    cancelled = await client.delete(
        f"/api/fitness/files/private/{staged_id}", headers=adult_a_headers
    )
    assert cancelled.status_code == 204 and cancelled.content == b""
    assert (
        await client.delete(
            f"/api/fitness/files/private/{staged_id}", headers=adult_a_headers
        )
    ).status_code == 204

    original_path = source_root / original_asset["storage_key"]
    assert original_path.is_file()
    assert (await client.delete("/api/auth/me", headers=adult_a_headers)).status_code == 204
    assert not original_path.exists()
    async with aiosqlite.connect(initialized_db) as db:
        assert (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM health_progress_photos WHERE owner_user_id = ?",
                    ("00000000-0000-0000-0000-000000000001",),
                )
            ).fetchone()
        )[0] == 0
