"""Abuse-resistance contracts for private Fitness file storage."""

from __future__ import annotations

import asyncio
import io
import os
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite
import pytest
from fastapi import HTTPException
from PIL import Image

from app.config import settings
from app.services.account_deletion import process_deferred_fitness_file_deletions
from app.services.fitness.activity_import import cleanup_stale_uploads
from app.services.fitness.resource_limits import fitness_upload_slot


pytestmark = pytest.mark.asyncio


def _png() -> bytes:
    output = io.BytesIO()
    Image.new("RGB", (4, 4), "navy").save(output, format="PNG")
    return output.getvalue()


async def test_private_upload_enforces_owner_quota_without_leaving_a_file(
    client,
    adult_a_headers,
    monkeypatch,
    tmp_path,
):
    storage = tmp_path / "health"
    payload = _png()
    monkeypatch.setattr(settings, "fitness_storage_path", str(storage))
    monkeypatch.setattr(settings, "fitness_owner_storage_quota_bytes", len(payload) - 1)
    monkeypatch.setattr(settings, "fitness_family_storage_quota_bytes", len(payload) * 10)

    response = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": str(uuid.uuid4()), "asset_kind": "progress_photo"},
        files={"file": ("photo.png", payload, "image/png")},
    )

    assert response.status_code == 413
    assert list(storage.rglob("*.*")) == []


async def test_private_upload_enforces_family_quota_across_adults(
    client,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
    tmp_path,
):
    payload = _png()
    monkeypatch.setattr(settings, "fitness_storage_path", str(tmp_path / "health"))
    monkeypatch.setattr(settings, "fitness_owner_storage_quota_bytes", len(payload) * 10)
    monkeypatch.setattr(settings, "fitness_family_storage_quota_bytes", len(payload))

    first = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": str(uuid.uuid4()), "asset_kind": "progress_photo"},
        files={"file": ("dom.png", payload, "image/png")},
    )
    second = await client.post(
        "/api/fitness/files/private",
        headers=adult_b_headers,
        data={"asset_id": str(uuid.uuid4()), "asset_kind": "progress_photo"},
        files={"file": ("kat.png", payload, "image/png")},
    )

    assert first.status_code == 201, first.text
    assert second.status_code == 413


async def test_fitness_upload_rate_budget_is_durable(
    client,
    adult_a_headers,
    monkeypatch,
    tmp_path,
):
    payload = _png()
    monkeypatch.setattr(settings, "fitness_storage_path", str(tmp_path / "health"))
    monkeypatch.setattr(settings, "fitness_upload_rate_limit_requests", 1)
    monkeypatch.setattr(settings, "fitness_family_upload_rate_limit_requests", 10)

    first = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": str(uuid.uuid4()), "asset_kind": "progress_photo"},
        files={"file": ("one.png", payload, "image/png")},
    )
    second = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": str(uuid.uuid4()), "asset_kind": "progress_photo"},
        files={"file": ("two.png", payload, "image/png")},
    )

    assert first.status_code == 201, first.text
    assert second.status_code == 429
    assert int(second.headers["retry-after"]) >= 1


async def test_abandoned_private_upload_can_resume_with_the_same_offline_id(
    client,
    initialized_db,
    adult_a_headers,
    adult_a_user,
    monkeypatch,
    tmp_path,
):
    payload = _png()
    asset_id = str(uuid.uuid4())
    monkeypatch.setattr(settings, "fitness_storage_path", str(tmp_path / "health"))
    monkeypatch.setattr(settings, "fitness_cache_path", str(tmp_path / "cache" / "health"))
    monkeypatch.setattr(settings, "fitness_staged_asset_ttl_hours", 24)
    first = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": asset_id, "asset_kind": "progress_photo"},
        files={"file": ("photo.png", payload, "image/png")},
    )
    assert first.status_code == 201, first.text

    now = datetime(2026, 8, 3, 12, tzinfo=timezone.utc)
    old = (now - timedelta(days=2)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(
            "UPDATE health_file_assets SET created_at = ?, updated_at = ? WHERE id = ?",
            (old, old, asset_id),
        )
        await db.commit()
        cleanup = await cleanup_stale_uploads(db, user=adult_a_user, current_time=now)
    assert cleanup["stale_private_removed"] == 1

    resumed = await client.post(
        "/api/fitness/files/private",
        headers=adult_a_headers,
        data={"asset_id": asset_id, "asset_kind": "progress_photo"},
        files={"file": ("photo.png", payload, "image/png")},
    )
    assert resumed.status_code == 201, resumed.text
    async with aiosqlite.connect(initialized_db) as db:
        row = await (
            await db.execute(
                "SELECT state, deleted_at FROM health_file_assets WHERE id = ?", (asset_id,)
            )
        ).fetchone()
        queued_deletions = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_deferred_file_deletions "
                "WHERE storage_key LIKE ?",
                (f"%{asset_id}%",),
            )
        ).fetchone()
    assert row == ("staged", None)
    assert queued_deletions == (0,)


async def test_same_id_private_upload_race_is_idempotent_and_keeps_the_winner(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
    tmp_path,
):
    payload = _png()
    asset_id = str(uuid.uuid4())
    storage = tmp_path / "health"
    monkeypatch.setattr(settings, "fitness_storage_path", str(storage))
    monkeypatch.setattr(settings, "fitness_owner_concurrent_uploads", 2)

    async def upload():
        return await client.post(
            "/api/fitness/files/private",
            headers=adult_a_headers,
            data={"asset_id": asset_id, "asset_kind": "progress_photo"},
            files={"file": ("photo.png", payload, "image/png")},
        )

    responses = await asyncio.gather(upload(), upload())

    assert [response.status_code for response in responses] == [201, 201]
    async with aiosqlite.connect(initialized_db) as db:
        count = await (
            await db.execute(
                "SELECT COUNT(*) FROM health_file_assets WHERE id = ? "
                "AND state = 'staged' AND deleted_at IS NULL",
                (asset_id,),
            )
        ).fetchone()
    assert count == (1,)
    files = [path for path in storage.rglob("*") if path.is_file()]
    assert len(files) == 1
    assert files[0].read_bytes() == payload


async def test_upload_slot_bounds_the_pre_database_burst(adult_a_user, monkeypatch):
    monkeypatch.setattr(settings, "fitness_owner_concurrent_uploads", 1)
    monkeypatch.setattr(settings, "fitness_family_concurrent_uploads", 2)

    with fitness_upload_slot(user=adult_a_user):
        with pytest.raises(HTTPException) as raised:
            with fitness_upload_slot(user=adult_a_user):
                pass

    assert raised.value.status_code == 429


async def test_maintenance_removes_abandoned_and_nonretryable_files(
    initialized_db,
    adult_a_user,
    monkeypatch,
    tmp_path,
):
    storage = tmp_path / "health"
    cache = tmp_path / "cache" / "health"
    monkeypatch.setattr(settings, "fitness_storage_path", str(storage))
    monkeypatch.setattr(settings, "fitness_cache_path", str(cache))
    exchange = tmp_path / "fitness-worker-exchange"
    monkeypatch.setattr(settings, "fitness_worker_exchange_path", str(exchange))
    monkeypatch.setattr(settings, "fitness_staged_asset_ttl_hours", 24)
    monkeypatch.setattr(settings, "fitness_failed_import_retention_days", 7)
    now = datetime(2026, 8, 3, 12, tzinfo=timezone.utc)
    old = (now - timedelta(days=8)).isoformat()
    staged_id = str(uuid.uuid4())
    failed_id = str(uuid.uuid4())
    staged_key = f"private/{adult_a_user['id']}/{staged_id}.png"
    failed_key = f"source/{adult_a_user['id']}/{failed_id}.fit"
    staged_path = storage / staged_key
    failed_path = storage / failed_key
    temporary_path = storage / "staging" / adult_a_user["id"] / "old.upload"
    worker_input_path = exchange / str(uuid.uuid4()) / "input.fit"
    for path, contents in (
        (staged_path, b"photo"),
        (failed_path, b"invalid-fit"),
        (temporary_path, b"partial"),
        (worker_input_path, b"claimed-copy"),
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
    old_epoch = (now - timedelta(days=8)).timestamp()
    temporary_path.touch()
    os.utime(temporary_path, (old_epoch, old_epoch))
    os.utime(worker_input_path.parent, (old_epoch, old_epoch))

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        for identifier, kind, storage_class, storage_key, size, state in (
            (staged_id, "progress_photo", "private_required", staged_key, 5, "staged"),
            (failed_id, "fit_source", "source_required", failed_key, 11, "ready"),
        ):
            await db.execute(
                "INSERT INTO health_file_assets "
                "(id, owner_user_id, asset_kind, storage_class, storage_key, media_type, "
                "byte_size, state, revision, family_id, created_at, updated_at, created_by) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)",
                (
                    identifier,
                    adult_a_user["id"],
                    kind,
                    storage_class,
                    storage_key,
                    "application/octet-stream",
                    size,
                    state,
                    adult_a_user["family_id"],
                    old,
                    old,
                    adult_a_user["id"],
                ),
            )
        await db.execute(
            "INSERT INTO health_imports "
            "(id, owner_user_id, file_asset_id, source_record_id, status, retryable, "
            "revision, family_id, created_at, updated_at, created_by) "
            "VALUES (?, ?, ?, ?, 'error', 0, 1, ?, ?, ?, ?)",
            (
                str(uuid.uuid4()),
                adult_a_user["id"],
                failed_id,
                str(uuid.uuid4()),
                adult_a_user["family_id"],
                old,
                old,
                adult_a_user["id"],
            ),
        )
        await db.commit()

        result = await cleanup_stale_uploads(db, user=adult_a_user, current_time=now)
        staged = await (
            await db.execute(
                "SELECT state, deleted_at FROM health_file_assets WHERE id = ?", (staged_id,)
            )
        ).fetchone()
        failed = await (
            await db.execute(
                "SELECT state, deleted_at FROM health_file_assets WHERE id = ?", (failed_id,)
            )
        ).fetchone()
        assert staged_path.exists()
        assert failed_path.exists()
        deleted = await process_deferred_fitness_file_deletions(db)

    assert result == {
        "stale_private_removed": 1,
        "failed_fit_removed": 1,
        "staging_files_removed": 1,
        "worker_inputs_removed": 1,
    }
    assert staged["state"] == "deleted" and staged["deleted_at"] is not None
    assert failed["state"] == "deleted" and failed["deleted_at"] is None
    assert deleted == 2
    assert not staged_path.exists()
    assert not failed_path.exists()
    assert not temporary_path.exists()
    assert not worker_input_path.exists()
