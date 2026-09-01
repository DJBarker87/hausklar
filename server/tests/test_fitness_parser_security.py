"""Filesystem contracts for the disposable Fitness parser exchange."""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import aiosqlite
import pytest

from app import fitness_worker
from app.config import settings
from app.fitness_worker import decode_fit_to_manifest, load_parser_job
from app.services.fitness.activity_import import (
    _analysis_job_manifest_path,
    _remove_job_exchange,
    _validate_analysis_manifest,
    claim_job,
)
from app.services.fitness.common import FitnessConflictError


def test_parser_job_rejects_a_relative_path_escape(tmp_path):
    exchange = tmp_path / "exchange"
    job = exchange / str(uuid.uuid4())
    job.mkdir(parents=True)
    outside = exchange / "other-owner.fit"
    outside.write_bytes(b"private")
    job_file = job / "job.json"
    job_file.write_text(
        json.dumps(
            {
                "job_type": "fit_import",
                "payload": {
                    "source_path": "../other-owner.fit",
                    "rows_temporary_path": "rows.ndjson",
                    "manifest_path": "manifest.json",
                },
            }
        )
    )

    with pytest.raises(ValueError, match="path"):
        load_parser_job(job_file)
    assert outside.read_bytes() == b"private"


def test_exchange_cleanup_refuses_a_job_directory_symlink(monkeypatch, tmp_path):
    exchange = tmp_path / "exchange"
    exchange.mkdir()
    sentinel = exchange / "sentinel"
    sentinel.write_text("keep")
    job_id = str(uuid.uuid4())
    (exchange / job_id).symlink_to(exchange, target_is_directory=True)
    monkeypatch.setattr(settings, "fitness_worker_exchange_path", str(exchange))

    with pytest.raises(FitnessConflictError, match="directory"):
        _remove_job_exchange(job_id)
    assert sentinel.read_text() == "keep"


def test_fit_frame_limit_counts_non_data_frames(monkeypatch, tmp_path):
    class Reader:
        def __enter__(self):
            return iter(
                [
                    SimpleNamespace(frame_type="header"),
                    SimpleNamespace(frame_type="definition"),
                    SimpleNamespace(frame_type="crc"),
                ]
            )

        def __exit__(self, *_args):
            return False

    source = tmp_path / "hostile.fit"
    source.write_bytes(b"not parsed by the reader double")
    monkeypatch.setattr(fitness_worker, "MAX_FIT_FRAMES", 2)
    monkeypatch.setattr(fitness_worker.fitdecode, "FitReader", lambda *_args, **_kwargs: Reader())

    with pytest.raises(ValueError, match="too many frames"):
        decode_fit_to_manifest(
            source,
            tmp_path / "rows.ndjson",
            tmp_path / "manifest.json",
        )


def test_analysis_manifest_has_a_strict_point_contract(monkeypatch, tmp_path):
    exchange = tmp_path / "exchange"
    monkeypatch.setattr(settings, "fitness_worker_exchange_path", str(exchange))
    job_id = str(uuid.uuid4())
    manifest_path = _analysis_job_manifest_path(job_id)

    point = {
        "key": "pace-0",
        "label": "300–330",
        "x_value": 315.0,
        "value": 12.0,
        "low": 301.0,
        "high": 329.0,
        "sample_size": 12,
        "missing_rate": 0.0,
        "quality": "recorded_stream_sample",
    }

    def write(candidate: dict) -> None:
        manifest_path.write_text(
            json.dumps(
                {
                    "source_count": 1,
                    "sample_count": 12,
                    "missing_count": 0,
                    "points": [candidate],
                }
            )
        )

    write(point)
    assert _validate_analysis_manifest(job_id, str(manifest_path))["points"] == [point]

    hostile_points = [
        {**point, "x": {"unexpected": True}},
        {**point, "value": 1e308},
        {**point, "missing_rate": -4},
        {**point, "quality": "arbitrary"},
        {**point, "low": 500, "high": 400},
        {key: value for key, value in point.items() if key != "sample_size"},
    ]
    for hostile in hostile_points:
        write(hostile)
        with pytest.raises(FitnessConflictError, match="analysis point"):
            _validate_analysis_manifest(job_id, str(manifest_path))


@pytest.mark.asyncio
async def test_expired_poison_job_is_quarantined_after_three_attempts(
    initialized_db, adult_a_user, monkeypatch, tmp_path
):
    monkeypatch.setattr(
        settings, "fitness_worker_exchange_path", str(tmp_path / "exchange")
    )
    now = datetime.now(timezone.utc)
    job_id = str(uuid.uuid4())
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(
            "INSERT INTO health_jobs "
            "(id, owner_user_id, job_type, status, payload_json, attempt_count, "
            "available_at, lease_token, lease_expires_at, revision, family_id, "
            "created_at, updated_at, created_by) "
            "VALUES (?, ?, 'fit_import', 'running', '{}', 3, ?, 'expired', ?, 1, ?, ?, ?, ?)",
            (
                job_id,
                adult_a_user["id"],
                (now - timedelta(hours=1)).isoformat(),
                (now - timedelta(minutes=1)).isoformat(),
                adult_a_user["family_id"],
                (now - timedelta(hours=1)).isoformat(),
                (now - timedelta(minutes=1)).isoformat(),
                adult_a_user["id"],
            ),
        )
        await db.commit()

        assert await claim_job(db) is None
        row = await (
            await db.execute(
                "SELECT status, lease_token, last_error FROM health_jobs WHERE id = ?",
                (job_id,),
            )
        ).fetchone()
    assert tuple(row) == ("failed", None, "ParserAttemptLimit")
