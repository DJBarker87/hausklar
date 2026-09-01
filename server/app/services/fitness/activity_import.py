"""Durable FIT staging and the API-owned side of the isolated worker boundary."""

from __future__ import annotations

import asyncio
import hashlib
import json
import math
import os
import re
import secrets
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import pyarrow as pa
import pyarrow.parquet as pq
from fastapi import HTTPException, UploadFile

from app.config import settings
from app.fitness_worker import PARSER_VERSION, STREAM_SCHEMA
from app.fitness_registry import METRICS, SPORTS
from app.services.fitness.common import (
    FitnessConflictError,
    append_change,
    decoded_row,
    insert_owned,
    json_text,
    new_id,
    now_iso,
    owned_row,
    save_owned_rows_history,
    update_owned,
)
from app.services.fitness.resource_limits import ensure_fitness_storage_capacity
from app.services.record_history import save_history


@dataclass(frozen=True)
class FitImportProvenance:
    """Trusted server-side identity for a FIT obtained from another provider."""

    transport_key: str
    origin_provider_key: str
    source_namespace: str
    source_object_id: str
    source_name: str | None = None
    source_device_identifier: str | None = None
    raw_metadata: dict[str, Any] = field(default_factory=dict)


def fitness_storage_root() -> Path:
    root = Path(settings.fitness_storage_path).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def fitness_cache_root() -> Path:
    root = Path(settings.fitness_cache_path).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def fitness_worker_exchange_root() -> Path:
    """Return the dedicated one-job-at-a-time parser exchange volume."""
    root = Path(settings.fitness_worker_exchange_path).expanduser().resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    return root


def _owner_component(owner_id: str) -> str:
    try:
        return str(UUID(owner_id))
    except ValueError as exc:
        raise FitnessConflictError("Fitness owner identifier is invalid") from exc


def _contained(root: Path, candidate: str | Path, *, must_exist: bool = False) -> Path:
    resolved_root = root.resolve()
    resolved = Path(candidate).expanduser().resolve(strict=must_exist)
    if resolved != resolved_root and resolved_root not in resolved.parents:
        raise FitnessConflictError("Fitness asset path leaves its configured storage root")
    return resolved


def asset_path(asset: dict | Any) -> Path:
    row = dict(asset)
    root = (
        fitness_cache_root()
        if row["storage_class"] == "regenerable"
        else fitness_storage_root()
    )
    return _contained(root, root / row["storage_key"])


async def _write_upload(file: UploadFile, destination: Path) -> tuple[int, str, bytes]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    fingerprint = hashlib.sha256()
    byte_size = 0
    first_bytes = b""
    try:
        with destination.open("xb") as handle:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                if not first_bytes:
                    first_bytes = chunk[:16]
                byte_size += len(chunk)
                if byte_size > settings.fitness_fit_max_upload_bytes:
                    raise HTTPException(status_code=413, detail="FIT file is too large")
                fingerprint.update(chunk)
                handle.write(chunk)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    if byte_size == 0:
        destination.unlink(missing_ok=True)
        raise HTTPException(status_code=422, detail="FIT file is empty")
    return byte_size, fingerprint.hexdigest(), first_bytes


async def _source_is_retained(db, *, user: dict, import_row: dict | Any) -> bool:
    row = dict(import_row)
    asset = await (
        await db.execute(
            "SELECT * FROM health_file_assets WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND storage_class = 'source_required' "
            "AND state = 'ready' AND deleted_at IS NULL",
            (row["file_asset_id"], user["family_id"], user["id"]),
        )
    ).fetchone()
    return bool(asset and asset_path(asset).is_file())


async def import_response(db, *, user: dict, import_id: str) -> dict:
    row = decoded_row(
        await owned_row(db, table="health_imports", record_id=import_id, user=user)
    )
    status = "processing" if row["status"] in {"queued", "processing"} else row["status"]
    asset = await owned_row(
        db, table="health_file_assets", record_id=row["file_asset_id"], user=user
    )
    return {
        "id": row["id"],
        "status": status,
        "activity_id": row.get("activity_id"),
        "file_name": asset["original_filename"],
        "error": row.get("error_message"),
        "error_code": row.get("error_code"),
        "retryable": bool(row.get("retryable")),
        "source_record_id": row["source_record_id"],
        "source_retained": await _source_is_retained(db, user=user, import_row=row),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


async def _enqueue_import_job(db, *, user: dict, import_id: str) -> str:
    timestamp = now_iso()
    job_id = new_id()
    await insert_owned(
        db,
        table="health_jobs",
        record_id=job_id,
        values={
            "job_type": "fit_import",
            "status": "queued",
            "payload_json": {"import_id": import_id},
            "attempt_count": 0,
            "available_at": timestamp,
            "revision": 1,
        },
        user=user,
        now=timestamp,
    )
    await update_owned(
        db,
        table="health_imports",
        record_id=import_id,
        values={
            "job_id": job_id,
            "status": "processing",
            "error_code": None,
            "error_message": None,
            "retryable": True,
        },
        user=user,
        now=timestamp,
    )
    return job_id


async def _enqueue_regeneration_job(
    db,
    *,
    user: dict,
    import_id: str,
    activity_id: str,
) -> str:
    """Queue a derived-stream rebuild while preserving the completed import."""
    existing = await (
        await db.execute(
            "SELECT id FROM health_jobs WHERE family_id = ? AND owner_user_id = ? "
            "AND status IN ('queued','running') "
            "AND json_extract(payload_json, '$.regenerate_activity_id') = ? "
            "AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchone()
    if existing:
        return existing["id"]
    timestamp = now_iso()
    job_id = new_id()
    await insert_owned(
        db,
        table="health_jobs",
        record_id=job_id,
        values={
            "job_type": "fit_import",
            "status": "queued",
            "payload_json": {
                "import_id": import_id,
                "regenerate_activity_id": activity_id,
            },
            "attempt_count": 0,
            "available_at": timestamp,
            "revision": 1,
        },
        user=user,
        now=timestamp,
    )
    await update_owned(
        db,
        table="health_activities",
        record_id=activity_id,
        values={"import_state": "regenerating"},
        user=user,
        now=timestamp,
        record_sync_change=False,
    )
    return job_id


async def regenerate_activity_analysis(
    db,
    *,
    user: dict,
    activity_id: str,
) -> dict:
    """Rebuild one activity from its retained FIT source with the current parser.

    The activity identity and user-authored context are preserved by the normal
    regeneration completion path.  Only source/derived rows and the regenerable
    Parquet stream are replaced.
    """
    activity = await owned_row(
        db,
        table="health_activities",
        record_id=activity_id,
        user=user,
    )
    import_row = await (
        await db.execute(
            "SELECT i.id, i.file_asset_id, f.state AS asset_state "
            "FROM health_imports i JOIN health_file_assets f ON f.id = i.file_asset_id "
            "WHERE i.family_id = ? AND i.owner_user_id = ? AND i.activity_id = ? "
            "AND i.deleted_at IS NULL AND f.family_id = i.family_id "
            "AND f.owner_user_id = i.owner_user_id AND f.deleted_at IS NULL "
            "ORDER BY i.created_at DESC LIMIT 1",
            (user["family_id"], user["id"], activity_id),
        )
    ).fetchone()
    if import_row is None:
        raise FitnessConflictError(
            "This activity has no retained FIT source and cannot be regenerated"
        )
    if import_row["asset_state"] != "ready":
        raise FitnessConflictError(
            "The retained FIT source is unavailable; reconcile private files first"
        )
    if activity["import_state"] == "regenerating":
        job_id = await _enqueue_regeneration_job(
            db,
            user=user,
            import_id=import_row["id"],
            activity_id=activity_id,
        )
        return {"status": "regenerating", "job_id": job_id, "activity_id": activity_id}
    job_id = await _enqueue_regeneration_job(
        db,
        user=user,
        import_id=import_row["id"],
        activity_id=activity_id,
    )
    return {"status": "queued", "job_id": job_id, "activity_id": activity_id}


async def enqueue_photo_thumbnail_job(
    db,
    *,
    user: dict,
    photo_id: str,
) -> str:
    """Queue one regenerable thumbnail without duplicating active work."""
    photo = await owned_row(
        db,
        table="health_progress_photos",
        record_id=photo_id,
        user=user,
    )
    source_asset = await owned_row(
        db,
        table="health_file_assets",
        record_id=photo["original_asset_id"],
        user=user,
    )
    if (
        source_asset["storage_class"] != "private_required"
        or source_asset["state"] != "ready"
        or not asset_path(source_asset).is_file()
    ):
        raise FitnessConflictError("Progress-photo original is not available")
    existing = await (
        await db.execute(
            "SELECT id FROM health_jobs WHERE family_id = ? AND owner_user_id = ? "
            "AND job_type = 'photo_thumbnail' AND status IN ('queued','running') "
            "AND json_extract(payload_json, '$.photo_id') = ? AND deleted_at IS NULL "
            "ORDER BY created_at DESC LIMIT 1",
            (user["family_id"], user["id"], photo_id),
        )
    ).fetchone()
    if existing:
        return existing["id"]
    job_id = new_id()
    timestamp = now_iso()
    await insert_owned(
        db,
        table="health_jobs",
        record_id=job_id,
        values={
            "job_type": "photo_thumbnail",
            "status": "queued",
            "payload_json": {
                "photo_id": photo_id,
                "source_asset_id": source_asset["id"],
            },
            "attempt_count": 0,
            "available_at": timestamp,
            "revision": 1,
        },
        user=user,
        now=timestamp,
        record_sync_change=False,
    )
    return job_id


async def stage_fit_import(
    db,
    *,
    user: dict,
    file: UploadFile,
    client_import_id: str | None,
    provenance: FitImportProvenance | None = None,
) -> dict:
    if client_import_id:
        replay = await (
            await db.execute(
                "SELECT id FROM health_imports WHERE family_id = ? AND owner_user_id = ? "
                "AND client_import_id = ? AND deleted_at IS NULL",
                (user["family_id"], user["id"], client_import_id),
            )
        ).fetchone()
        if replay:
            return await import_response(db, user=user, import_id=replay["id"])

    if provenance is not None:
        replay = await (
            await db.execute(
                "SELECT i.id FROM health_source_records s JOIN health_imports i "
                "ON i.source_record_id = s.id AND i.deleted_at IS NULL "
                "WHERE s.family_id = ? AND s.owner_user_id = ? "
                "AND s.record_kind = 'activity' AND s.transport_key = ? "
                "AND s.source_namespace = ? AND s.source_object_id = ? "
                "AND s.deleted_at IS NULL LIMIT 1",
                (
                    user["family_id"],
                    user["id"],
                    provenance.transport_key,
                    provenance.source_namespace,
                    provenance.source_object_id,
                ),
            )
        ).fetchone()
        if replay:
            return await import_response(db, user=user, import_id=replay["id"])

    filename = Path(file.filename or "activity.fit").name
    if not filename.lower().endswith(".fit"):
        raise HTTPException(status_code=422, detail="Choose a file ending in .fit")
    media_type = (file.content_type or "application/octet-stream").lower()
    if media_type not in {
        "application/octet-stream",
        "application/vnd.ant.fit",
        "application/fit",
        "binary/octet-stream",
    }:
        raise HTTPException(status_code=415, detail="Unsupported FIT media type")

    owner = _owner_component(user["id"])
    asset_id = new_id()
    temporary = _contained(
        fitness_storage_root(),
        fitness_storage_root() / "staging" / owner / f"{asset_id}.upload",
    )
    byte_size, fingerprint, _ = await _write_upload(file, temporary)

    duplicate = await (
        await db.execute(
            "SELECT i.id, i.file_asset_id, i.activity_id, i.status "
            "FROM health_source_records s JOIN health_imports i "
            "ON i.source_record_id = s.id AND i.deleted_at IS NULL "
            "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.record_kind = 'activity' "
            "AND s.file_fingerprint = ? AND s.deleted_at IS NULL "
            "ORDER BY i.created_at DESC LIMIT 1",
            (user["family_id"], user["id"], fingerprint),
        )
    ).fetchone()
    if duplicate:
        temporary.unlink(missing_ok=True)
        if (
            provenance is not None
            and duplicate["status"] == "complete"
            and duplicate["activity_id"]
        ):
            source_id = new_id()
            import_id = new_id()
            timestamp = now_iso()
            await db.execute("BEGIN IMMEDIATE")
            concurrent = await (
                await db.execute(
                    "SELECT i.id FROM health_source_records s JOIN health_imports i "
                    "ON i.source_record_id = s.id AND i.deleted_at IS NULL "
                    "WHERE s.family_id = ? AND s.owner_user_id = ? "
                    "AND s.record_kind = 'activity' AND s.transport_key = ? "
                    "AND s.source_namespace = ? AND s.source_object_id = ? "
                    "AND s.deleted_at IS NULL LIMIT 1",
                    (
                        user["family_id"],
                        user["id"],
                        provenance.transport_key,
                        provenance.source_namespace,
                        provenance.source_object_id,
                    ),
                )
            ).fetchone()
            if concurrent:
                await db.rollback()
                return await import_response(
                    db, user=user, import_id=concurrent["id"]
                )
            try:
                await insert_owned(
                    db,
                    table="health_source_records",
                    record_id=source_id,
                    values={
                        "record_kind": "activity",
                        "transport_key": provenance.transport_key,
                        "origin_provider_key": provenance.origin_provider_key,
                        "source_namespace": provenance.source_namespace,
                        "source_object_id": provenance.source_object_id,
                        "source_device_identifier": (
                            provenance.source_device_identifier
                        ),
                        "source_name": provenance.source_name,
                        "raw_asset_id": duplicate["file_asset_id"],
                        "file_fingerprint": fingerprint,
                        "state": "active",
                        "raw_metadata_json": {
                            "original_filename": filename,
                            **provenance.raw_metadata,
                            "reused_retained_fit": True,
                        },
                        "revision": 1,
                    },
                    user=user,
                    now=timestamp,
                )
                await insert_owned(
                    db,
                    table="health_imports",
                    record_id=import_id,
                    values={
                        "client_import_id": client_import_id,
                        "file_asset_id": duplicate["file_asset_id"],
                        "source_record_id": source_id,
                        "activity_id": duplicate["activity_id"],
                        "status": "complete",
                        "attempt_count": 0,
                        "retryable": False,
                        "revision": 1,
                    },
                    user=user,
                    now=timestamp,
                )
                await insert_owned(
                    db,
                    table="health_activity_source_records",
                    record_id=new_id(),
                    values={
                        "activity_id": duplicate["activity_id"],
                        "source_record_id": source_id,
                        "role": "corroborating",
                        "revision": 1,
                    },
                    user=user,
                    now=timestamp,
                )
                await db.commit()
            except BaseException:
                await db.rollback()
                raise
            return await import_response(db, user=user, import_id=import_id)
        return await import_response(db, user=user, import_id=duplicate["id"])

    storage_key = str(Path("source") / owner / f"{asset_id}.fit")
    final_path = _contained(fitness_storage_root(), fitness_storage_root() / storage_key)
    source_id = new_id()
    import_id = new_id()
    timestamp = now_iso()
    try:
        await db.execute("BEGIN IMMEDIATE")
        await ensure_fitness_storage_capacity(
            db,
            user=user,
            incoming_bytes=byte_size,
        )
        final_path.parent.mkdir(parents=True, exist_ok=True)
        os.replace(temporary, final_path)
        await insert_owned(
            db,
            table="health_file_assets",
            record_id=asset_id,
            values={
                "asset_kind": "fit_source",
                "storage_class": "source_required",
                "storage_key": storage_key,
                "original_filename": filename,
                "media_type": media_type,
                "byte_size": byte_size,
                "file_fingerprint": fingerprint,
                "state": "ready",
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )
        await insert_owned(
            db,
            table="health_source_records",
            record_id=source_id,
            values={
                "record_kind": "activity",
                "transport_key": (
                    provenance.transport_key if provenance else "manual_fit"
                ),
                "origin_provider_key": (
                    provenance.origin_provider_key if provenance else "other"
                ),
                "source_namespace": (
                    provenance.source_namespace if provenance else "manual_fit"
                ),
                # The upload/source UUID is the exact identity. The fingerprint
                # remains a separate repeated-file check and is never promoted
                # into the source key or filesystem layout.
                "source_object_id": (
                    provenance.source_object_id if provenance else source_id
                ),
                "source_device_identifier": (
                    provenance.source_device_identifier if provenance else None
                ),
                "source_name": provenance.source_name if provenance else None,
                "raw_asset_id": asset_id,
                "file_fingerprint": fingerprint,
                "state": "active",
                "raw_metadata_json": {
                    "original_filename": filename,
                    **(provenance.raw_metadata if provenance else {}),
                },
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )
        await insert_owned(
            db,
            table="health_imports",
            record_id=import_id,
            values={
                "client_import_id": client_import_id,
                "file_asset_id": asset_id,
                "source_record_id": source_id,
                "status": "queued",
                "attempt_count": 0,
                "retryable": True,
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )
        await _enqueue_import_job(db, user=user, import_id=import_id)
        await db.commit()
    except BaseException:
        await db.rollback()
        final_path.unlink(missing_ok=True)
        temporary.unlink(missing_ok=True)
        raise
    return await import_response(db, user=user, import_id=import_id)


async def retry_fit_import(db, *, user: dict, import_id: str) -> dict:
    row = await owned_row(db, table="health_imports", record_id=import_id, user=user)
    if row["status"] == "complete":
        return await import_response(db, user=user, import_id=import_id)
    if not row["retryable"]:
        raise FitnessConflictError("This FIT import cannot be retried")
    asset = await owned_row(
        db, table="health_file_assets", record_id=row["file_asset_id"], user=user
    )
    if asset["state"] != "ready" or not asset_path(asset).is_file():
        raise FitnessConflictError("The retained FIT source is missing")
    await db.execute("BEGIN IMMEDIATE")
    await _enqueue_import_job(db, user=user, import_id=import_id)
    await save_owned_rows_history(
        db,
        table="health_imports",
        user=user,
        where="id = ?",
        params=(import_id,),
    )
    await db.execute(
        "UPDATE health_imports SET attempt_count = attempt_count + 1 WHERE id = ?",
        (import_id,),
    )
    await db.commit()
    return await import_response(db, user=user, import_id=import_id)


def ensure_worker_token(token: str | None) -> None:
    expected = settings.fitness_worker_token.strip()
    if len(expected) < 32:
        raise HTTPException(status_code=503, detail="Fitness worker is not configured")
    if not token or not secrets.compare_digest(token, expected):
        raise HTTPException(status_code=401, detail="Invalid Fitness worker token")


def _job_exchange_dir(job_id: str, *, create: bool = True) -> Path:
    try:
        component = str(UUID(job_id))
    except ValueError as exc:
        raise FitnessConflictError("Fitness job identifier is invalid") from exc
    root = fitness_worker_exchange_root()
    directory = root / component
    if directory.parent != root or directory == root:
        raise FitnessConflictError("Fitness job exchange path is invalid")
    if directory.is_symlink():
        raise FitnessConflictError("Fitness job exchange directory is invalid")
    resolved = directory.resolve(strict=False)
    if resolved == root or root not in resolved.parents:
        raise FitnessConflictError("Fitness job exchange directory is invalid")
    if create:
        directory.mkdir(mode=0o700, parents=False, exist_ok=True)
        if directory.is_symlink() or not directory.is_dir():
            raise FitnessConflictError("Fitness job exchange directory is invalid")
        directory.chmod(0o700)
    return directory


def _prepare_job_exchange(job_id: str) -> Path:
    directory = _job_exchange_dir(job_id, create=False)
    if directory.exists():
        if directory.is_symlink() or not directory.is_dir():
            raise FitnessConflictError("Fitness job exchange directory is invalid")
        shutil.rmtree(directory)
    directory.mkdir(mode=0o700, parents=False)
    return directory


def _write_parser_job(job_id: str, *, job_type: str, payload: dict[str, Any]) -> None:
    """Write the fixed, token-free contract consumed by one parser container."""
    directory = _job_exchange_dir(job_id)
    destination = directory / "job.json"
    temporary = directory / "job.json.tmp"
    encoded = json.dumps(
        {"job_type": job_type, "payload": payload}, separators=(",", ":")
    ).encode("utf-8")
    if len(encoded) > 256 * 1024:
        raise FitnessConflictError("Fitness parser job is too large")
    temporary.unlink(missing_ok=True)
    try:
        with temporary.open("xb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        destination.chmod(0o600)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _job_output_paths(job_id: str) -> tuple[Path, Path]:
    exchange = _job_exchange_dir(job_id)
    return exchange / "rows.ndjson", exchange / "manifest.json"


def _validated_parquet_path(job_id: str) -> Path:
    staging = _contained(fitness_cache_root(), fitness_cache_root() / "staging")
    staging.mkdir(mode=0o700, parents=True, exist_ok=True)
    return staging / f"{job_id}.validated.parquet"


def _photo_job_output_paths(job_id: str) -> tuple[Path, Path]:
    exchange = _job_exchange_dir(job_id)
    return exchange / "result.jpg", exchange / "manifest.json"


def _analysis_job_manifest_path(job_id: str) -> Path:
    return _job_exchange_dir(job_id) / "manifest.json"


def _job_input_path(job_id: str, suffix: str) -> Path:
    return _job_exchange_dir(job_id) / f"input{suffix}"


def _stage_worker_input(
    source: Path,
    *,
    job_id: str,
    suffix: str,
    max_bytes: int,
) -> Path:
    """Copy one validated job source into its isolated exchange directory."""
    if source.stat().st_size <= 0 or source.stat().st_size > max_bytes:
        raise FitnessConflictError("Fitness worker source size is invalid")
    destination = _job_input_path(job_id, suffix)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.unlink(missing_ok=True)
    try:
        with source.open("rb") as input_handle, temporary.open("xb") as output_handle:
            shutil.copyfileobj(input_handle, output_handle, length=1024 * 1024)
            output_handle.flush()
            os.fsync(output_handle.fileno())
        if temporary.stat().st_size != source.stat().st_size:
            raise FitnessConflictError("Fitness worker source copy is incomplete")
        os.replace(temporary, destination)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return destination


MAX_ANALYSIS_EXCHANGE_BYTES = 128 * 1024 * 1024


def _stage_analysis_inputs(job_id: str, sources: list[Path]) -> list[str]:
    directory = _job_exchange_dir(job_id) / "analysis-inputs"
    directory.mkdir(mode=0o700, parents=False, exist_ok=False)
    selected: list[str] = []
    total_bytes = 0
    for index, source in enumerate(sources[:50]):
        source_size = source.stat().st_size
        if source_size <= 0:
            continue
        if total_bytes + source_size > MAX_ANALYSIS_EXCHANGE_BYTES:
            break
        destination = directory / f"{index:02d}.parquet"
        with source.open("rb") as input_handle, destination.open("xb") as output_handle:
            shutil.copyfileobj(input_handle, output_handle, length=1024 * 1024)
            output_handle.flush()
            os.fsync(output_handle.fileno())
        if destination.stat().st_size != source_size:
            destination.unlink(missing_ok=True)
            raise FitnessConflictError("Fitness analysis source copy is incomplete")
        total_bytes += source_size
        selected.append(str(destination))
    return selected


def _remove_job_inputs(job_id: str) -> None:
    for suffix in (".fit", ".photo"):
        path = _job_input_path(job_id, suffix)
        for candidate in (path, path.with_suffix(path.suffix + ".tmp")):
            try:
                candidate.unlink(missing_ok=True)
            except OSError:
                continue


def _remove_job_exchange(job_id: str) -> None:
    directory = _job_exchange_dir(job_id, create=False)
    try:
        if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
            raise FitnessConflictError("Fitness job exchange directory is invalid")
        shutil.rmtree(directory)
    except FileNotFoundError:
        pass


async def claim_job(db) -> dict | None:
    now = datetime.now(timezone.utc)
    expires = (now + timedelta(seconds=settings.fitness_worker_lease_seconds)).isoformat()
    lease_token = secrets.token_urlsafe(32)
    await db.execute("BEGIN IMMEDIATE")
    exhausted = await (
        await db.execute(
            "SELECT id, owner_user_id, family_id FROM health_jobs "
            "WHERE status = 'running' AND lease_expires_at <= ? "
            "AND attempt_count >= 3 AND deleted_at IS NULL LIMIT 50",
            (now.isoformat(),),
        )
    ).fetchall()
    exhausted_job_ids = [item["id"] for item in exhausted]
    for exhausted_job in exhausted:
        await save_history(
            db,
            "health_jobs",
            exhausted_job["id"],
            exhausted_job["owner_user_id"],
            family_id=exhausted_job["family_id"],
        )
        linked_import = await (
            await db.execute(
                "SELECT id FROM health_imports WHERE job_id = ? AND family_id = ? "
                "AND owner_user_id = ? AND deleted_at IS NULL",
                (
                    exhausted_job["id"],
                    exhausted_job["family_id"],
                    exhausted_job["owner_user_id"],
                ),
            )
        ).fetchone()
        if linked_import is not None:
            await save_history(
                db,
                "health_imports",
                linked_import["id"],
                exhausted_job["owner_user_id"],
                family_id=exhausted_job["family_id"],
            )
            await db.execute(
                "UPDATE health_imports SET status = 'error', error_code = ?, "
                "error_message = ?, retryable = 0, updated_at = ?, revision = revision + 1 "
                "WHERE id = ?",
                (
                    "ParserAttemptLimit",
                    "The isolated parser could not complete this file",
                    now.isoformat(),
                    linked_import["id"],
                ),
            )
        await db.execute(
            "UPDATE health_jobs SET status = 'failed', last_error = ?, lease_token = NULL, "
            "lease_expires_at = NULL, updated_at = ? WHERE id = ?",
            ("ParserAttemptLimit", now.isoformat(), exhausted_job["id"]),
        )
    row = await (
        await db.execute(
            "SELECT * FROM health_jobs WHERE deleted_at IS NULL AND "
            "((status = 'queued' AND available_at <= ?) OR "
            " (status = 'running' AND lease_expires_at <= ?)) "
            "AND attempt_count < 3 ORDER BY available_at, created_at LIMIT 1",
            (now.isoformat(), now.isoformat()),
        )
    ).fetchone()
    if row is None:
        await db.commit()
        for exhausted_job_id in exhausted_job_ids:
            await asyncio.to_thread(_remove_job_exchange, exhausted_job_id)
        return None
    await save_history(
        db,
        "health_jobs",
        row["id"],
        row["owner_user_id"],
        family_id=row["family_id"],
    )
    claimed = await db.execute(
        "UPDATE health_jobs SET status = 'running', lease_token = ?, lease_expires_at = ?, "
        "attempt_count = attempt_count + 1, updated_at = ? WHERE id = ? AND "
        "((status = 'queued' AND available_at <= ?) OR "
        " (status = 'running' AND lease_expires_at <= ?))",
        (
            lease_token,
            expires,
            now.isoformat(),
            row["id"],
            now.isoformat(),
            now.isoformat(),
        ),
    )
    if claimed.rowcount != 1:
        await db.rollback()
        return None

    payload = json.loads(row["payload_json"] or "{}")

    async def release_claim(*, prepare_exchange: bool) -> None:
        # The lease fences this job once the transaction commits. No filesystem
        # copying is allowed while SQLite's global writer lock is held.
        await db.commit()
        for exhausted_job_id in exhausted_job_ids:
            await asyncio.to_thread(_remove_job_exchange, exhausted_job_id)
        if prepare_exchange:
            await asyncio.to_thread(_prepare_job_exchange, row["id"])

    async def fail_claim_preparation(_exc: Exception) -> None:
        await fail_job(
            db,
            job_id=row["id"],
            lease_token=lease_token,
            error_code="ParserStagingFailure",
            error="The isolated parser job could not be prepared",
            retryable=False,
        )

    if row["job_type"] == "analysis_query":
        from app.models.fitness_analysis import AnalysisQueryPayload
        from app.services.fitness.analysis import _matches_filters, validate_query

        body = AnalysisQueryPayload.model_validate(payload.get("query"))
        measure = validate_query(body)
        if not measure["_heavy"]:
            await db.rollback()
            raise FitnessConflictError("Queued analysis measure is not worker-backed")
        candidates = await (
            await db.execute(
                "SELECT a.id, a.workout_classification, a.phase_id, "
                "s.file_asset_id, f.* FROM health_activities a "
                "JOIN health_activity_stream_assets s ON s.id = a.primary_stream_asset_id "
                "AND s.family_id = a.family_id AND s.owner_user_id = a.owner_user_id "
                "AND s.deleted_at IS NULL JOIN health_file_assets f ON f.id = s.file_asset_id "
                "AND f.family_id = a.family_id AND f.owner_user_id = a.owner_user_id "
                "AND f.storage_class = 'regenerable' AND f.state = 'ready' "
                "AND f.deleted_at IS NULL WHERE a.family_id = ? AND a.owner_user_id = ? "
                "AND a.sport_key = 'running' AND a.status = 'completed' "
                "AND a.deleted_at IS NULL AND COALESCE(a.local_calendar_date, "
                "substr(a.started_at_utc,1,10)) BETWEEN ? AND ? "
                "ORDER BY a.started_at_utc DESC LIMIT 100",
                (
                    row["family_id"],
                    row["owner_user_id"],
                    body.date_range.start.isoformat(),
                    body.date_range.end.isoformat(),
                ),
            )
        ).fetchall()
        selected_sources: list[Path] = []
        for candidate in candidates:
            gear = await (
                await db.execute(
                    "SELECT gear_id FROM health_activity_gear_links WHERE family_id = ? "
                    "AND owner_user_id = ? AND activity_id = ? AND role = 'primary' "
                    "AND deleted_at IS NULL ORDER BY created_at LIMIT 1",
                    (row["family_id"], row["owner_user_id"], candidate["id"]),
                )
            ).fetchone()
            fake_sample = {
                "filters": {
                    "workout_classification": candidate["workout_classification"]
                    or "unclassified",
                    "phase_id": candidate["phase_id"],
                    "gear_id": gear["gear_id"] if gear else None,
                }
            }
            if not _matches_filters(fake_sample, body.filters):
                continue
            path = asset_path(candidate)
            if path.is_file():
                selected_sources.append(
                    _contained(fitness_cache_root(), path, must_exist=True)
                )
            if len(selected_sources) >= 50:
                break
        try:
            await release_claim(prepare_exchange=True)
            selected_paths = await asyncio.to_thread(
                _stage_analysis_inputs, row["id"], selected_sources
            )
            manifest_path = _analysis_job_manifest_path(row["id"])
            manifest_path.unlink(missing_ok=True)
            job_directory = _job_exchange_dir(row["id"])
            await asyncio.to_thread(
                _write_parser_job,
                row["id"],
                job_type=row["job_type"],
                payload={
                    "source_paths": [
                        str(Path(path).relative_to(job_directory))
                        for path in selected_paths
                    ],
                    "manifest_path": "manifest.json",
                    "max_stream_samples": 200_000,
                },
            )
        except Exception as exc:
            await fail_claim_preparation(exc)
            return None
        return {
            "id": row["id"],
            "job_type": row["job_type"],
            "lease_token": lease_token,
            "lease_expires_at": expires,
            "attempt_count": int(row["attempt_count"]) + 1,
        }
    if row["job_type"] == "photo_thumbnail":
        photo = await (
            await db.execute(
                "SELECT * FROM health_progress_photos WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ? AND deleted_at IS NULL",
                (payload.get("photo_id"), row["family_id"], row["owner_user_id"]),
            )
        ).fetchone()
        asset = await (
            await db.execute(
                "SELECT * FROM health_file_assets WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ? AND storage_class = 'private_required' "
                "AND state = 'ready' AND deleted_at IS NULL",
                (payload.get("source_asset_id"), row["family_id"], row["owner_user_id"]),
            )
        ).fetchone()
        if photo is None or asset is None or photo["original_asset_id"] != asset["id"]:
            await release_claim(prepare_exchange=False)
            await fail_claim_preparation(
                FitnessConflictError("Progress-photo thumbnail source is not ready")
            )
            return None
        durable_source = _contained(
            fitness_storage_root(), asset_path(asset), must_exist=True
        )
        try:
            await release_claim(prepare_exchange=True)
            thumbnail_path, manifest_path = _photo_job_output_paths(row["id"])
            thumbnail_path.unlink(missing_ok=True)
            manifest_path.unlink(missing_ok=True)
            source_path = await asyncio.to_thread(
                _stage_worker_input,
                durable_source,
                job_id=row["id"],
                suffix=".photo",
                max_bytes=settings.fitness_photo_max_upload_bytes,
            )
            await asyncio.to_thread(
                _write_parser_job,
                row["id"],
                job_type=row["job_type"],
                payload={
                    "photo_id": photo["id"],
                    "source_path": source_path.name,
                    "thumbnail_temporary_path": thumbnail_path.name,
                    "manifest_path": manifest_path.name,
                },
            )
        except Exception as exc:
            await fail_claim_preparation(exc)
            return None
        return {
            "id": row["id"],
            "job_type": row["job_type"],
            "lease_token": lease_token,
            "lease_expires_at": expires,
            "attempt_count": int(row["attempt_count"]) + 1,
        }
    if row["job_type"] != "fit_import":
        await db.rollback()
        raise FitnessConflictError("Fitness job type is not supported")
    import_row = await (
        await db.execute(
            "SELECT * FROM health_imports WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (payload.get("import_id"), row["family_id"], row["owner_user_id"]),
        )
    ).fetchone()
    if import_row is None:
        await release_claim(prepare_exchange=False)
        await fail_claim_preparation(FitnessConflictError("Fitness job import is missing"))
        return None
    asset = await (
        await db.execute(
            "SELECT * FROM health_file_assets WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND storage_class = 'source_required' "
            "AND state = 'ready' AND deleted_at IS NULL",
            (import_row["file_asset_id"], row["family_id"], row["owner_user_id"]),
        )
    ).fetchone()
    if asset is None:
        await release_claim(prepare_exchange=False)
        await fail_claim_preparation(
            FitnessConflictError("Fitness job source asset is not ready")
        )
        return None
    durable_source = _contained(
        fitness_storage_root(), asset_path(asset), must_exist=True
    )
    owner_settings = await (
        await db.execute(
            "SELECT heart_rate_zone_boundaries_bpm_json FROM health_user_settings "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL LIMIT 1",
            (row["family_id"], row["owner_user_id"]),
        )
    ).fetchone()
    try:
        heart_rate_zone_boundaries = json.loads(
            owner_settings["heart_rate_zone_boundaries_bpm_json"]
            if owner_settings
            else "[120,140,155,170]"
        )
    except (TypeError, json.JSONDecodeError):
        heart_rate_zone_boundaries = [120, 140, 155, 170]
    try:
        await release_claim(prepare_exchange=True)
        rows_path, manifest_path = _job_output_paths(row["id"])
        rows_path.unlink(missing_ok=True)
        manifest_path.unlink(missing_ok=True)
        source_path = await asyncio.to_thread(
            _stage_worker_input,
            durable_source,
            job_id=row["id"],
            suffix=".fit",
            max_bytes=settings.fitness_fit_max_upload_bytes,
        )
        await asyncio.to_thread(
            _write_parser_job,
            row["id"],
            job_type=row["job_type"],
            payload={
                "import_id": import_row["id"],
                "regenerate_activity_id": payload.get("regenerate_activity_id"),
                "source_path": source_path.name,
                "rows_temporary_path": rows_path.name,
                "manifest_path": manifest_path.name,
                "heart_rate_zone_boundaries_bpm": heart_rate_zone_boundaries,
            },
        )
    except Exception as exc:
        await fail_claim_preparation(exc)
        return None
    return {
        "id": row["id"],
        "job_type": row["job_type"],
        "lease_token": lease_token,
        "lease_expires_at": expires,
        "attempt_count": int(row["attempt_count"]) + 1,
    }


async def heartbeat_job(db, *, job_id: str, lease_token: str) -> dict:
    now = datetime.now(timezone.utc)
    expires = (now + timedelta(seconds=settings.fitness_worker_lease_seconds)).isoformat()
    job = await (
        await db.execute(
            "SELECT owner_user_id, family_id FROM health_jobs WHERE id = ? "
            "AND status = 'running' AND lease_token = ? AND deleted_at IS NULL",
            (job_id, lease_token),
        )
    ).fetchone()
    if job is None:
        raise FitnessConflictError("Fitness job lease is no longer valid")
    await save_history(
        db,
        "health_jobs",
        job_id,
        job["owner_user_id"],
        family_id=job["family_id"],
    )
    result = await db.execute(
        "UPDATE health_jobs SET lease_expires_at = ?, updated_at = ? WHERE id = ? "
        "AND status = 'running' AND lease_token = ? AND lease_expires_at > ? "
        "AND deleted_at IS NULL",
        (expires, now.isoformat(), job_id, lease_token, now.isoformat()),
    )
    if result.rowcount != 1:
        raise FitnessConflictError("Fitness job lease is no longer valid")
    await db.commit()
    return {"id": job_id, "lease_expires_at": expires}


_MANIFEST_KEY = re.compile(r"^[a-z][a-z0-9_.-]{0,79}$")
_SPORT_KEYS = {item["key"] for item in SPORTS}
_METRIC_KEYS = {item["key"] for item in METRICS}
_WORKOUT_CLASSIFICATIONS = {
    "unclassified",
    "recovery",
    "easy",
    "steady",
    "long",
    "tempo",
    "threshold",
    "interval",
    "hill",
    "race",
    "time_trial",
    "progression",
    "mixed",
}


def _manifest_dict(
    value: Any,
    *,
    allowed: set[str],
    required: set[str] = frozenset(),
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) - allowed or not required.issubset(value):
        raise FitnessConflictError(f"Worker {label} is invalid")
    return value


def _manifest_string(
    value: Any,
    *,
    label: str,
    maximum: int = 256,
    nullable: bool = False,
) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise FitnessConflictError(f"Worker {label} is invalid")
    return value


def _manifest_number(
    value: Any,
    *,
    label: str,
    minimum: float | None = None,
    maximum: float | None = None,
    nullable: bool = False,
) -> float | int | None:
    if value is None and nullable:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise FitnessConflictError(f"Worker {label} is invalid")
    numeric = float(value)
    if not math.isfinite(numeric):
        raise FitnessConflictError(f"Worker {label} is invalid")
    if minimum is not None and numeric < minimum:
        raise FitnessConflictError(f"Worker {label} is invalid")
    if maximum is not None and numeric > maximum:
        raise FitnessConflictError(f"Worker {label} is invalid")
    return value


def _bounded_json(value: Any, *, depth: int = 0, budget: list[int] | None = None) -> None:
    budget = budget or [0]
    budget[0] += 1
    if depth > 6 or budget[0] > 4_000:
        raise FitnessConflictError("Worker result is too complex")
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, (int, float)):
        _manifest_number(value, label="result number")
        return
    if isinstance(value, str):
        if len(value) > 512:
            raise FitnessConflictError("Worker result text is too long")
        return
    if isinstance(value, list):
        if len(value) > 500:
            raise FitnessConflictError("Worker result list is too long")
        for item in value:
            _bounded_json(item, depth=depth + 1, budget=budget)
        return
    if isinstance(value, dict):
        if len(value) > 100:
            raise FitnessConflictError("Worker result object is too large")
        for key, item in value.items():
            if not isinstance(key, str) or len(key) > 80:
                raise FitnessConflictError("Worker result key is invalid")
            _bounded_json(item, depth=depth + 1, budget=budget)
        return
    raise FitnessConflictError("Worker result value is invalid")


def _validate_fit_manifest_contract(manifest: Any) -> dict[str, Any]:
    top = _manifest_dict(
        manifest,
        allowed={
            "parser_name",
            "parser_version",
            "source",
            "activity",
            "stream",
            "summary_metrics",
            "intervals",
            "markers",
            "features",
            "analysis_findings",
            "records",
            "quality_findings",
        },
        required={"parser_name", "parser_version", "source", "activity", "stream"},
        label="manifest",
    )
    if top["parser_name"] != "fitdecode" or top["parser_version"] != PARSER_VERSION:
        raise FitnessConflictError("Worker parser identity is invalid")

    source = _manifest_dict(
        top["source"],
        allowed={"fit_identity", "device_name", "manufacturer", "source_created_at_utc"},
        required={"fit_identity"},
        label="source result",
    )
    _manifest_string(source["fit_identity"], label="FIT identity", maximum=512)
    for key in ("device_name", "manufacturer", "source_created_at_utc"):
        _manifest_string(source.get(key), label=key, maximum=256, nullable=True)

    activity = _manifest_dict(
        top["activity"],
        allowed={
            "sport_key",
            "sub_sport_key",
            "title",
            "started_at_utc",
            "ended_at_utc",
            "elapsed_duration_s",
            "timer_duration_s",
            "moving_duration_s",
            "distance_m",
            "energy_kcal",
            "measurement_quality",
            "workout_classification",
            "classification_source",
            "route_preview",
        },
        required={"sport_key", "title", "started_at_utc", "ended_at_utc"},
        label="activity result",
    )
    if activity["sport_key"] not in _SPORT_KEYS:
        raise FitnessConflictError("Worker activity sport is invalid")
    _manifest_string(activity["title"], label="activity title", maximum=160)
    _manifest_string(activity.get("sub_sport_key"), label="sub-sport", maximum=80, nullable=True)
    try:
        started = datetime.fromisoformat(
            _manifest_string(activity["started_at_utc"], label="activity start", maximum=64).replace("Z", "+00:00")
        )
        ended = datetime.fromisoformat(
            _manifest_string(activity["ended_at_utc"], label="activity end", maximum=64).replace("Z", "+00:00")
        )
    except ValueError as exc:
        raise FitnessConflictError("Worker activity timestamps are invalid") from exc
    if started.tzinfo is None or ended.tzinfo is None or ended < started or ended - started > timedelta(days=31):
        raise FitnessConflictError("Worker activity timestamps are invalid")
    for key in ("elapsed_duration_s", "timer_duration_s", "moving_duration_s"):
        _manifest_number(activity.get(key), label=key, minimum=0, maximum=31 * 86_400, nullable=True)
    _manifest_number(activity.get("distance_m"), label="distance", minimum=0, maximum=10_000_000, nullable=True)
    _manifest_number(activity.get("energy_kcal"), label="energy", minimum=0, maximum=1_000_000, nullable=True)
    if activity.get("measurement_quality") != "source_reported":
        raise FitnessConflictError("Worker activity quality is invalid")
    if activity.get("workout_classification") not in _WORKOUT_CLASSIFICATIONS:
        raise FitnessConflictError("Worker activity classification is invalid")
    if activity.get("classification_source") not in {"source", "derived"}:
        raise FitnessConflictError("Worker classification source is invalid")
    route = activity.get("route_preview", [])
    if not isinstance(route, list) or len(route) > 101:
        raise FitnessConflictError("Worker route preview is invalid")
    for coordinate in route:
        if not isinstance(coordinate, list) or len(coordinate) != 2:
            raise FitnessConflictError("Worker route preview is invalid")
        _manifest_number(coordinate[0], label="latitude", minimum=-90, maximum=90)
        _manifest_number(coordinate[1], label="longitude", minimum=-180, maximum=180)

    stream = _manifest_dict(
        top["stream"],
        allowed={
            "temporary_path",
            "byte_size",
            "sha256",
            "row_count",
            "start_offset_ms",
            "end_offset_ms",
            "schema_version",
            "metric_index",
        },
        required={"temporary_path", "byte_size", "sha256", "row_count", "schema_version"},
        label="stream result",
    )
    row_count = _manifest_number(stream["row_count"], label="stream row count", minimum=1, maximum=750_000)
    if not isinstance(row_count, int) or stream["schema_version"] != 1:
        raise FitnessConflictError("Worker stream version is invalid")
    byte_size = _manifest_number(
        stream["byte_size"],
        label="stream byte size",
        minimum=1,
        maximum=256 * 1024 * 1024,
    )
    if not isinstance(byte_size, int):
        raise FitnessConflictError("Worker stream byte size is invalid")
    digest = _manifest_string(stream["sha256"], label="stream digest", maximum=64)
    if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
        raise FitnessConflictError("Worker stream digest is invalid")
    start_offset = _manifest_number(stream.get("start_offset_ms"), label="stream start", minimum=0, maximum=31 * 86_400_000, nullable=True)
    end_offset = _manifest_number(stream.get("end_offset_ms"), label="stream end", minimum=0, maximum=31 * 86_400_000, nullable=True)
    if start_offset is not None and end_offset is not None and end_offset < start_offset:
        raise FitnessConflictError("Worker stream offsets are invalid")

    metric_index = stream.get("metric_index", [])
    if not isinstance(metric_index, list) or len(metric_index) > len(_METRIC_KEYS):
        raise FitnessConflictError("Worker stream metric index is invalid")
    seen_metrics: set[str] = set()
    for metric in metric_index:
        item = _manifest_dict(
            metric,
            allowed={"metric_key", "sample_count", "non_null_count", "minimum", "maximum", "average", "unit_key", "quality", "source_field"},
            required={"metric_key", "sample_count", "non_null_count", "quality"},
            label="stream metric",
        )
        key = _manifest_string(item["metric_key"], label="metric key", maximum=80)
        if key not in _METRIC_KEYS or key in seen_metrics:
            raise FitnessConflictError("Worker stream metric key is invalid")
        seen_metrics.add(key)
        sample_count = _manifest_number(item["sample_count"], label="metric sample count", minimum=0, maximum=row_count)
        non_null = _manifest_number(item["non_null_count"], label="metric non-null count", minimum=0, maximum=row_count)
        if not isinstance(sample_count, int) or not isinstance(non_null, int) or non_null > sample_count:
            raise FitnessConflictError("Worker stream metric counts are invalid")
        for key_name in ("minimum", "maximum", "average"):
            _manifest_number(item.get(key_name), label=key_name, nullable=True)
        _manifest_string(item.get("unit_key"), label="metric unit", maximum=32, nullable=True)
        _manifest_string(item.get("source_field"), label="metric source", maximum=80, nullable=True)
        if item["quality"] not in {"measured", "derived"}:
            raise FitnessConflictError("Worker stream metric quality is invalid")

    summary_metrics = top.get("summary_metrics", [])
    if not isinstance(summary_metrics, list) or len(summary_metrics) > 50:
        raise FitnessConflictError("Worker summary metrics are invalid")
    for metric in summary_metrics:
        item = _manifest_dict(
            metric,
            allowed={"metric_key", "value_number", "unit_key", "origin", "quality", "calculation_version"},
            required={"metric_key", "value_number", "origin", "quality"},
            label="summary metric",
        )
        _manifest_string(item["metric_key"], label="summary metric key", maximum=80)
        _manifest_number(item["value_number"], label="summary metric value")
        _manifest_string(item.get("unit_key"), label="summary metric unit", maximum=32, nullable=True)
        if item["origin"] not in {"source", "derived"} or item["quality"] not in {"measured", "derived"}:
            raise FitnessConflictError("Worker summary metric provenance is invalid")
        _manifest_string(item.get("calculation_version"), label="calculation version", maximum=80, nullable=True)

    intervals = top.get("intervals", [])
    if not isinstance(intervals, list) or len(intervals) > 10_000:
        raise FitnessConflictError("Worker intervals are invalid")
    for interval in intervals:
        item = _manifest_dict(
            interval,
            allowed={"sequence", "interval_kind", "origin", "start_offset_ms", "end_offset_ms", "start_distance_m", "end_distance_m", "label", "metrics"},
            required={"sequence", "interval_kind", "origin", "start_offset_ms", "end_offset_ms"},
            label="interval",
        )
        sequence = _manifest_number(item["sequence"], label="interval sequence", minimum=0, maximum=10_000)
        if not isinstance(sequence, int) or item["origin"] not in {"source", "derived"}:
            raise FitnessConflictError("Worker interval provenance is invalid")
        _manifest_string(item["interval_kind"], label="interval kind", maximum=80)
        left = _manifest_number(item["start_offset_ms"], label="interval start", minimum=0, maximum=31 * 86_400_000)
        right = _manifest_number(item["end_offset_ms"], label="interval end", minimum=0, maximum=31 * 86_400_000)
        if not isinstance(left, int) or not isinstance(right, int) or right < left:
            raise FitnessConflictError("Worker interval offsets are invalid")
        for key_name in ("start_distance_m", "end_distance_m"):
            _manifest_number(item.get(key_name), label=key_name, minimum=0, maximum=10_000_000, nullable=True)
        _manifest_string(item.get("label"), label="interval label", maximum=120, nullable=True)
        metrics = _manifest_dict(
            item.get("metrics", {}),
            allowed={
                "duration_s",
                "pace_s_per_km",
                "distance_m",
                "elapsed_duration_s",
                "timer_duration_s",
                "heart_rate.average_bpm",
                "speed.average_mps",
                "elevation.change_m",
            },
            label="interval metrics",
        )
        for metric_value in metrics.values():
            _manifest_number(metric_value, label="interval metric", nullable=True)

    markers = top.get("markers", [])
    if not isinstance(markers, list) or len(markers) > 10_000:
        raise FitnessConflictError("Worker markers are invalid")
    for marker in markers:
        item = _manifest_dict(
            marker,
            allowed={"offset_ms", "distance_m", "marker_key", "label", "payload"},
            required={"offset_ms", "marker_key"},
            label="marker",
        )
        offset = _manifest_number(item["offset_ms"], label="marker offset", minimum=0, maximum=31 * 86_400_000)
        if not isinstance(offset, int):
            raise FitnessConflictError("Worker marker offset is invalid")
        _manifest_number(item.get("distance_m"), label="marker distance", minimum=0, maximum=10_000_000, nullable=True)
        _manifest_string(item["marker_key"], label="marker key", maximum=80)
        _manifest_string(item.get("label"), label="marker label", maximum=120, nullable=True)
        payload = _manifest_dict(item.get("payload", {}), allowed={"event", "event_type"}, label="marker payload")
        for payload_value in payload.values():
            _manifest_string(payload_value, label="marker payload", maximum=80)

    features = top.get("features", {})
    if not isinstance(features, dict) or len(features) > 100:
        raise FitnessConflictError("Worker features are invalid")
    for key, value in features.items():
        if not isinstance(key, str) or not _MANIFEST_KEY.fullmatch(key):
            raise FitnessConflictError("Worker feature key is invalid")
        _bounded_json(value)

    findings = top.get("analysis_findings", [])
    if not isinstance(findings, list) or len(findings) > 100:
        raise FitnessConflictError("Worker analysis findings are invalid")
    for finding in findings:
        item = _manifest_dict(
            finding,
            allowed={"key", "title", "summary", "status", "value", "unit_key", "quality", "confidence", "calculation_version", "evidence"},
            required={"key", "title", "summary", "status", "quality", "confidence"},
            label="analysis finding",
        )
        key = _manifest_string(item["key"], label="analysis key", maximum=80)
        if not _MANIFEST_KEY.fullmatch(key):
            raise FitnessConflictError("Worker analysis key is invalid")
        _manifest_string(item["title"], label="analysis title", maximum=160)
        _manifest_string(item["summary"], label="analysis summary", maximum=512)
        if item["status"] not in {"valid", "limited"} or item["quality"] not in {"derived", "limited_by_source_data"}:
            raise FitnessConflictError("Worker analysis status is invalid")
        _manifest_number(item["confidence"], label="analysis confidence", minimum=0, maximum=1)
        _manifest_string(item.get("unit_key"), label="analysis unit", maximum=32, nullable=True)
        _manifest_string(item.get("calculation_version"), label="analysis version", maximum=80, nullable=True)
        _bounded_json(item.get("value"))
        evidence = item.get("evidence", [])
        if not isinstance(evidence, list) or len(evidence) > 20:
            raise FitnessConflictError("Worker analysis evidence is invalid")
        for evidence_item in evidence:
            evidence_row = _manifest_dict(evidence_item, allowed={"label", "value"}, required={"label", "value"}, label="analysis evidence")
            _manifest_string(evidence_row["label"], label="evidence label", maximum=120)
            _manifest_string(evidence_row["value"], label="evidence value", maximum=256)

    records = top.get("records", [])
    if not isinstance(records, list) or len(records) > 20:
        raise FitnessConflictError("Worker records are invalid")
    _bounded_json(records)

    quality_findings = top.get("quality_findings", [])
    if not isinstance(quality_findings, list) or len(quality_findings) > 100:
        raise FitnessConflictError("Worker quality findings are invalid")
    for quality in quality_findings:
        item = _manifest_dict(
            quality,
            allowed={"key", "severity", "message", "start_offset_ms", "end_offset_ms", "limits_analysis_keys"},
            required={"key", "severity", "message"},
            label="quality finding",
        )
        key = _manifest_string(item["key"], label="quality key", maximum=80)
        if not _MANIFEST_KEY.fullmatch(key) or item["severity"] not in {"info", "warning", "error"}:
            raise FitnessConflictError("Worker quality finding is invalid")
        _manifest_string(item["message"], label="quality message", maximum=512)
        for key_name in ("start_offset_ms", "end_offset_ms"):
            value = _manifest_number(item.get(key_name), label=key_name, minimum=0, maximum=31 * 86_400_000, nullable=True)
            if value is not None and not isinstance(value, int):
                raise FitnessConflictError("Worker quality offset is invalid")
        limited = item.get("limits_analysis_keys", [])
        if not isinstance(limited, list) or len(limited) > 50:
            raise FitnessConflictError("Worker quality limits are invalid")
        for limited_key in limited:
            if not isinstance(limited_key, str) or not _MANIFEST_KEY.fullmatch(limited_key):
                raise FitnessConflictError("Worker quality limit key is invalid")
    return top


_STREAM_ROW_KEYS = {field.name for field in STREAM_SCHEMA}
_STREAM_NUMERIC_LIMITS: dict[str, tuple[float, float]] = {
    "distance_m": (0, 10_000_000),
    "latitude_deg": (-90, 90),
    "longitude_deg": (-180, 180),
    "speed_mps": (0, 200),
    "pace_s_per_km": (0, 86_400),
    "heart_rate_bpm": (0, 300),
    "altitude_m": (-1_000, 10_000),
    "cadence_spm": (0, 1_000),
    "power_w": (0, 10_000),
    "temperature_c": (-100, 100),
    "stride_length_m": (0, 10),
    "vertical_oscillation_mm": (0, 1_000),
    "vertical_ratio_pct": (0, 100),
    "ground_contact_time_ms": (0, 5_000),
    "ground_contact_balance_pct": (0, 100),
    "respiration_rate_bpm": (0, 300),
}


def _json_without_duplicate_keys(raw: bytes) -> Any:
    def pairs_hook(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    return json.loads(raw, object_pairs_hook=pairs_hook)


def _regular_exchange_file(path: Path, *, maximum: int) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise FitnessConflictError("Worker result file is missing") from exc
    if path.is_symlink() or not path.is_file() or metadata.st_nlink != 1:
        raise FitnessConflictError("Worker result file is invalid")
    if metadata.st_size <= 0 or metadata.st_size > maximum:
        raise FitnessConflictError("Worker result file is too large")
    return metadata


def _validate_and_write_stream(job_id: str, rows_path: Path, stream: dict[str, Any]) -> Path:
    metadata = _regular_exchange_file(rows_path, maximum=256 * 1024 * 1024)
    if metadata.st_size != stream["byte_size"]:
        raise FitnessConflictError("Worker stream byte count does not match")
    destination = _validated_parquet_path(job_id)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    destination.unlink(missing_ok=True)
    temporary.unlink(missing_ok=True)
    digest = hashlib.sha256()
    row_count = 0
    previous_timestamp: datetime | None = None
    previous_elapsed = -1
    previous_timer = -1
    writer: pq.ParquetWriter | None = None
    batch: list[dict[str, Any]] = []
    try:
        with rows_path.open("rb") as handle:
            for raw_line in handle:
                digest.update(raw_line)
                if len(raw_line) > 8_192 or not raw_line.endswith(b"\n"):
                    raise FitnessConflictError("Worker stream row is invalid")
                try:
                    row = _json_without_duplicate_keys(raw_line)
                except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as exc:
                    raise FitnessConflictError("Worker stream row is invalid") from exc
                if not isinstance(row, dict) or set(row) != _STREAM_ROW_KEYS:
                    raise FitnessConflictError("Worker stream row shape is invalid")
                if row.get("sample_index") != row_count or isinstance(
                    row.get("sample_index"), bool
                ):
                    raise FitnessConflictError("Worker stream sequence is invalid")
                try:
                    timestamp = datetime.fromisoformat(
                        str(row["timestamp_utc"]).replace("Z", "+00:00")
                    )
                except (TypeError, ValueError) as exc:
                    raise FitnessConflictError("Worker stream timestamp is invalid") from exc
                if timestamp.tzinfo is None:
                    raise FitnessConflictError("Worker stream timestamp is invalid")
                timestamp = timestamp.astimezone(timezone.utc)
                elapsed = row.get("elapsed_ms")
                timer = row.get("timer_ms")
                if (
                    isinstance(elapsed, bool)
                    or not isinstance(elapsed, int)
                    or isinstance(timer, bool)
                    or not isinstance(timer, int)
                    or elapsed < previous_elapsed
                    or timer < previous_timer
                    or timer > elapsed
                    or elapsed > 31 * 86_400_000
                ):
                    raise FitnessConflictError("Worker stream timing is invalid")
                if previous_timestamp is not None and timestamp < previous_timestamp:
                    raise FitnessConflictError("Worker stream timestamps are out of order")
                for metric_key, (minimum, maximum) in _STREAM_NUMERIC_LIMITS.items():
                    value = row.get(metric_key)
                    if value is None:
                        continue
                    _manifest_number(
                        value,
                        label=f"stream {metric_key}",
                        minimum=minimum,
                        maximum=maximum,
                    )
                row["timestamp_utc"] = timestamp
                batch.append(row)
                row_count += 1
                previous_timestamp = timestamp
                previous_elapsed = elapsed
                previous_timer = timer
                if len(batch) >= 4_096:
                    table = pa.Table.from_pylist(batch, schema=STREAM_SCHEMA)
                    writer = writer or pq.ParquetWriter(
                        temporary, STREAM_SCHEMA, compression="zstd"
                    )
                    writer.write_table(table)
                    batch.clear()
                if row_count > 750_000:
                    raise FitnessConflictError("Worker stream has too many rows")
        if batch:
            table = pa.Table.from_pylist(batch, schema=STREAM_SCHEMA)
            writer = writer or pq.ParquetWriter(
                temporary, STREAM_SCHEMA, compression="zstd"
            )
            writer.write_table(table)
        if writer is None:
            raise FitnessConflictError("Worker stream has no rows")
        writer.close()
        writer = None
        if row_count != stream["row_count"]:
            raise FitnessConflictError("Worker stream row count does not match")
        if digest.hexdigest() != stream["sha256"]:
            raise FitnessConflictError("Worker stream digest does not match")
        os.replace(temporary, destination)
    except BaseException:
        if writer is not None:
            writer.close()
        temporary.unlink(missing_ok=True)
        destination.unlink(missing_ok=True)
        raise
    return destination


def _validate_manifest(job_id: str, requested_path: str) -> tuple[dict, Path]:
    expected_rows, expected_manifest = _job_output_paths(job_id)
    supplied = Path(requested_path)
    if supplied != expected_manifest:
        raise FitnessConflictError("Worker manifest path does not match its claimed job")
    _regular_exchange_file(supplied, maximum=4 * 1024 * 1024)
    try:
        manifest = _validate_fit_manifest_contract(
            _json_without_duplicate_keys(supplied.read_bytes())
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise FitnessConflictError("Worker manifest is invalid") from exc
    stream = manifest.get("stream")
    activity = manifest.get("activity")
    if not isinstance(stream, dict) or not isinstance(activity, dict):
        raise FitnessConflictError("Worker manifest is missing activity or stream data")
    if stream.get("temporary_path") != expected_rows.name:
        raise FitnessConflictError("Worker stream path does not match its claimed job")
    temporary_rows = expected_rows
    temporary_parquet = _validate_and_write_stream(job_id, temporary_rows, stream)
    required_activity = {"sport_key", "title", "started_at_utc", "ended_at_utc"}
    if not required_activity.issubset(activity):
        raise FitnessConflictError("Worker activity result is incomplete")
    return manifest, temporary_parquet


async def _probable_duplicates(
    db, *, user: dict, import_id: str, activity_id: str, activity: dict
) -> None:
    try:
        started = datetime.fromisoformat(activity["started_at_utc"].replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return
    lower = (started - timedelta(minutes=15)).isoformat()
    upper = (started + timedelta(minutes=15)).isoformat()
    candidates = await (
        await db.execute(
            "SELECT id, distance_m, timer_duration_s FROM health_activities "
            "WHERE family_id = ? AND owner_user_id = ? AND id <> ? AND sport_key = ? "
            "AND started_at_utc BETWEEN ? AND ? AND deleted_at IS NULL",
            (
                user["family_id"],
                user["id"],
                activity_id,
                activity["sport_key"],
                lower,
                upper,
            ),
        )
    ).fetchall()
    for candidate in candidates:
        distance = float(activity.get("distance_m") or 0)
        duration = float(activity.get("timer_duration_s") or 0)
        distance_close = not distance or abs(float(candidate["distance_m"] or 0) - distance) <= max(
            250, distance * 0.05
        )
        duration_close = not duration or abs(
            float(candidate["timer_duration_s"] or 0) - duration
        ) <= max(120, duration * 0.1)
        if distance_close and duration_close:
            await insert_owned(
                db,
                table="health_import_review_candidates",
                record_id=new_id(),
                values={
                    "import_id": import_id,
                    "candidate_activity_id": candidate["id"],
                    "reason": "Similar sport, start time, duration and distance",
                    "confidence": 0.65,
                    "state": "pending",
                    "revision": 1,
                },
                user=user,
            )


def _validate_photo_manifest(job_id: str, requested_path: str) -> tuple[dict, Path]:
    expected_thumbnail, expected_manifest = _photo_job_output_paths(job_id)
    supplied = Path(requested_path)
    if supplied != expected_manifest:
        raise FitnessConflictError("Worker thumbnail manifest is invalid")
    _regular_exchange_file(supplied, maximum=16 * 1024)
    try:
        manifest = _json_without_duplicate_keys(supplied.read_bytes())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise FitnessConflictError("Worker thumbnail manifest is invalid") from exc
    if not isinstance(manifest, dict) or set(manifest) != {"thumbnail"}:
        raise FitnessConflictError("Worker thumbnail result is missing")
    thumbnail = manifest["thumbnail"]
    if not isinstance(thumbnail, dict) or set(thumbnail) != {
        "temporary_path",
        "byte_size",
        "media_type",
    }:
        raise FitnessConflictError("Worker thumbnail result is missing")
    if thumbnail.get("temporary_path") != expected_thumbnail.name:
        raise FitnessConflictError("Worker thumbnail path does not match its claimed job")
    temporary = expected_thumbnail
    metadata = _regular_exchange_file(temporary, maximum=2 * 1024 * 1024)
    byte_size = thumbnail.get("byte_size")
    if (
        thumbnail.get("media_type") != "image/jpeg"
        or isinstance(byte_size, bool)
        or not isinstance(byte_size, int)
    ):
        raise FitnessConflictError("Worker thumbnail result is invalid")
    if byte_size != metadata.st_size:
        raise FitnessConflictError("Worker thumbnail byte count does not match")
    width, height = _jpeg_dimensions(temporary.read_bytes())
    if not 1 <= width <= 512 or not 1 <= height <= 512:
        raise FitnessConflictError("Worker thumbnail dimensions are invalid")
    return manifest, temporary


def _jpeg_dimensions(data: bytes) -> tuple[int, int]:
    if len(data) < 12 or not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
        raise FitnessConflictError("Worker thumbnail is not a complete JPEG")
    index = 2
    start_of_frame = {
        0xC0,
        0xC1,
        0xC2,
        0xC3,
        0xC5,
        0xC6,
        0xC7,
        0xC9,
        0xCA,
        0xCB,
        0xCD,
        0xCE,
        0xCF,
    }
    while index + 4 <= len(data):
        if data[index] != 0xFF:
            index += 1
            continue
        while index < len(data) and data[index] == 0xFF:
            index += 1
        if index >= len(data):
            break
        marker = data[index]
        index += 1
        if marker in {0x01, 0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
            continue
        if index + 2 > len(data):
            break
        segment_length = int.from_bytes(data[index : index + 2], "big")
        if segment_length < 2 or index + segment_length > len(data):
            break
        if marker in start_of_frame:
            if segment_length < 7:
                break
            height = int.from_bytes(data[index + 3 : index + 5], "big")
            width = int.from_bytes(data[index + 5 : index + 7], "big")
            return width, height
        index += segment_length
    raise FitnessConflictError("Worker thumbnail dimensions are invalid")


def _validate_analysis_manifest(job_id: str, requested_path: str) -> dict:
    expected = _analysis_job_manifest_path(job_id)
    supplied = Path(requested_path)
    if supplied != expected:
        raise FitnessConflictError("Worker analysis manifest is invalid")
    _regular_exchange_file(supplied, maximum=256 * 1024)
    try:
        manifest = _json_without_duplicate_keys(supplied.read_bytes())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise FitnessConflictError("Worker analysis manifest is invalid") from exc
    if not isinstance(manifest, dict) or set(manifest) != {
        "source_count",
        "sample_count",
        "missing_count",
        "points",
    }:
        raise FitnessConflictError("Worker analysis result is invalid")
    points = manifest["points"]
    if (
        not isinstance(points, list)
        or len(points) > MAX_ANALYSIS_MANIFEST_POINTS
        or any(
            isinstance(manifest[key], bool) or not isinstance(manifest[key], int)
            for key in ("source_count", "sample_count", "missing_count")
        )
        or not 0 <= manifest["source_count"] <= 50
        or not 0 <= manifest["sample_count"] <= 200_000
        or not 0 <= manifest["missing_count"] <= 200_000
        or manifest["sample_count"] + manifest["missing_count"] > 200_000
    ):
        raise FitnessConflictError("Worker analysis result is invalid")
    allowed_point_keys = {
        "key",
        "label",
        "x",
        "x_value",
        "value",
        "low",
        "high",
        "sample_size",
        "missing_rate",
        "quality",
    }
    required_point_keys = {
        "key",
        "label",
        "x_value",
        "value",
        "low",
        "high",
        "sample_size",
        "missing_rate",
        "quality",
    }
    for point in points:
        if (
            not isinstance(point, dict)
            or set(point) - allowed_point_keys
            or not required_point_keys.issubset(point)
        ):
            raise FitnessConflictError("Worker analysis point is invalid")
        if (
            not isinstance(point.get("key"), str)
            or not _MANIFEST_KEY.fullmatch(point["key"])
            or not isinstance(point.get("label"), str)
            or not 1 <= len(point["label"]) <= 120
        ):
            raise FitnessConflictError("Worker analysis point is invalid")
        x = point.get("x")
        if x is not None and not (
            (isinstance(x, str) and 1 <= len(x) <= 120)
            or (
                not isinstance(x, bool)
                and isinstance(x, (int, float))
                and math.isfinite(x)
                and abs(float(x)) <= MAX_ANALYSIS_POINT_ABS
            )
        ):
            raise FitnessConflictError("Worker analysis point is invalid")
        for key in ("x_value", "value", "low", "high"):
            value = point[key]
            if value is not None and (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                or abs(float(value)) > MAX_ANALYSIS_POINT_ABS
            ):
                raise FitnessConflictError("Worker analysis point is invalid")
        missing_rate = point["missing_rate"]
        if (
            isinstance(missing_rate, bool)
            or not isinstance(missing_rate, (int, float))
            or not math.isfinite(missing_rate)
            or not 0 <= float(missing_rate) <= 1
        ):
            raise FitnessConflictError("Worker analysis point is invalid")
        sample_size = point.get("sample_size")
        if (
            isinstance(sample_size, bool)
            or not isinstance(sample_size, int)
            or not 0 <= sample_size <= 200_000
        ):
            raise FitnessConflictError("Worker analysis point is invalid")
        if point["quality"] not in ANALYSIS_POINT_QUALITIES:
            raise FitnessConflictError("Worker analysis point is invalid")
        if (
            point["low"] is not None
            and point["high"] is not None
            and float(point["low"]) > float(point["high"])
        ):
            raise FitnessConflictError("Worker analysis point is invalid")
    return manifest


MAX_ANALYSIS_MANIFEST_POINTS = 200
MAX_ANALYSIS_POINT_ABS = 1_000_000_000.0
ANALYSIS_POINT_QUALITIES = {"recorded_stream_sample"}


async def _complete_photo_thumbnail_job(
    db,
    *,
    job,
    lease_token: str,
    manifest_path: str,
) -> dict:
    _manifest, temporary = await asyncio.to_thread(
        _validate_photo_manifest, job["id"], manifest_path
    )
    user = {"id": job["owner_user_id"], "family_id": job["family_id"]}
    payload = json.loads(job["payload_json"] or "{}")
    photo = await owned_row(
        db,
        table="health_progress_photos",
        record_id=payload["photo_id"],
        user=user,
    )
    source = await owned_row(
        db,
        table="health_file_assets",
        record_id=payload["source_asset_id"],
        user=user,
    )
    if (
        photo["original_asset_id"] != source["id"]
        or source["storage_class"] != "private_required"
        or source["state"] != "ready"
        or not asset_path(source).is_file()
    ):
        raise FitnessConflictError("Progress-photo original disappeared before commit")
    asset_id = new_id()
    storage_key = str(
        Path("thumbnails") / _owner_component(user["id"]) / f"{asset_id}.jpg"
    )
    destination = _contained(fitness_cache_root(), fitness_cache_root() / storage_key)
    destination.parent.mkdir(parents=True, exist_ok=True)
    os.replace(temporary, destination)
    old_asset = None
    if photo["thumbnail_asset_id"]:
        old_asset = await (
            await db.execute(
                "SELECT * FROM health_file_assets WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ?",
                (photo["thumbnail_asset_id"], user["family_id"], user["id"]),
            )
        ).fetchone()
    await db.execute("BEGIN IMMEDIATE")
    try:
        timestamp = now_iso()
        await insert_owned(
            db,
            table="health_file_assets",
            record_id=asset_id,
            values={
                "asset_kind": "progress_photo_thumbnail",
                "storage_class": "regenerable",
                "storage_key": storage_key,
                "original_filename": None,
                "media_type": "image/jpeg",
                "byte_size": destination.stat().st_size,
                "file_fingerprint": hashlib.sha256(destination.read_bytes()).hexdigest(),
                "state": "ready",
                "source_asset_id": source["id"],
                "revision": 1,
            },
            user=user,
            record_sync_change=False,
        )
        if old_asset is not None and old_asset["deleted_at"] is None:
            await update_owned(
                db,
                table="health_file_assets",
                record_id=old_asset["id"],
                values={"state": "deleted", "deleted_at": timestamp},
                user=user,
                record_sync_change=False,
            )
        await update_owned(
            db,
            table="health_progress_photos",
            record_id=photo["id"],
            values={"thumbnail_asset_id": asset_id},
            user=user,
            record_sync_change=False,
        )
        await save_history(
            db,
            "health_jobs",
            job["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE health_jobs SET status = 'complete', result_json = ?, "
            "lease_token = NULL, lease_expires_at = NULL, last_error = NULL, updated_at = ? "
            "WHERE id = ? AND lease_token = ?",
            (
                json_text({"photo_id": photo["id"], "thumbnail_asset_id": asset_id}),
                timestamp,
                job["id"],
                lease_token,
            ),
        )
        await db.commit()
    except BaseException:
        await db.rollback()
        destination.unlink(missing_ok=True)
        raise
    Path(manifest_path).unlink(missing_ok=True)
    if old_asset is not None:
        await remove_fitness_storage_key(
            old_asset["storage_key"], old_asset["storage_class"]
        )
    from app.services.fitness.progress_photos import progress_photo_response

    result = await progress_photo_response(db, user=user, photo_id=photo["id"])
    result.update({"id": job["id"], "status": "ready", "photo_id": photo["id"]})
    return result


def _duration_for_match(row: dict[str, Any]) -> float | None:
    for key in ("timer_duration_s", "elapsed_duration_s"):
        value = row.get(key)
        if value is not None:
            try:
                return float(value)
            except (TypeError, ValueError):
                return None
    return None


async def _healthkit_garmin_promotion_candidate(
    db,
    *,
    user: dict,
    source: dict | Any,
    activity: dict[str, Any],
) -> dict[str, Any] | None:
    """Find one strongly matching summary that can safely receive FIT detail."""
    source_row = dict(source)
    if (
        source_row["transport_key"] != "intervals_icu"
        or source_row["origin_provider_key"] != "garmin"
    ):
        return None
    candidates = await (
        await db.execute(
            "SELECT DISTINCT a.* FROM health_activities a "
            "JOIN health_activity_source_records l ON l.activity_id = a.id "
            "AND l.deleted_at IS NULL JOIN health_source_records s "
            "ON s.id = l.source_record_id AND s.deleted_at IS NULL "
            "WHERE a.family_id = ? AND a.owner_user_id = ? "
            "AND a.sport_key = ? AND a.primary_stream_asset_id IS NULL "
            "AND a.deleted_at IS NULL AND s.transport_key = 'healthkit' "
            "AND s.origin_provider_key = 'garmin' "
            "AND ABS((julianday(a.started_at_utc) - julianday(?)) * 86400.0) <= 2.0 "
            "LIMIT 10",
            (
                user["family_id"],
                user["id"],
                activity["sport_key"],
                activity["started_at_utc"],
            ),
        )
    ).fetchall()
    incoming_duration = _duration_for_match(activity)
    if incoming_duration is None:
        return None
    matches: list[dict[str, Any]] = []
    for raw in candidates:
        candidate = dict(raw)
        candidate_duration = _duration_for_match(candidate)
        if candidate_duration is None or abs(candidate_duration - incoming_duration) > 3:
            continue
        incoming_distance = activity.get("distance_m")
        candidate_distance = candidate.get("distance_m")
        if incoming_distance is not None and candidate_distance is not None:
            incoming_value = float(incoming_distance)
            candidate_value = float(candidate_distance)
            tolerance = max(25.0, max(incoming_value, candidate_value) * 0.01)
            if abs(incoming_value - candidate_value) > tolerance:
                continue
        matches.append(candidate)
    return matches[0] if len(matches) == 1 else None


async def complete_job(db, *, job_id: str, lease_token: str) -> dict:
    now = datetime.now(timezone.utc)
    job = await (
        await db.execute(
            "SELECT * FROM health_jobs WHERE id = ? AND status = 'running' "
            "AND lease_token = ? AND lease_expires_at > ? AND deleted_at IS NULL",
            (job_id, lease_token, now.isoformat()),
        )
    ).fetchone()
    if job is None:
        raise FitnessConflictError("Fitness job lease is no longer valid")
    if job["job_type"] == "analysis_query":
        from app.models.fitness_analysis import AnalysisQueryPayload
        from app.services.fitness.analysis import complete_heavy_query

        manifest_path = str(_analysis_job_manifest_path(job_id))
        manifest = await asyncio.to_thread(
            _validate_analysis_manifest, job_id, manifest_path
        )
        payload = json.loads(job["payload_json"] or "{}")
        body = AnalysisQueryPayload.model_validate(payload.get("query"))
        result = complete_heavy_query(
            body,
            points=manifest["points"],
            source_count=manifest["source_count"],
            sample_count=manifest["sample_count"],
            missing_count=manifest["missing_count"],
        )
        await db.execute("BEGIN IMMEDIATE")
        await save_history(
            db,
            "health_jobs",
            job_id,
            job["owner_user_id"],
            family_id=job["family_id"],
        )
        await db.execute(
            "UPDATE health_jobs SET status = 'complete', result_json = ?, "
            "lease_token = NULL, lease_expires_at = NULL, last_error = NULL, updated_at = ? "
            "WHERE id = ? AND lease_token = ?",
            (json_text(result), now_iso(), job_id, lease_token),
        )
        await db.commit()
        Path(manifest_path).unlink(missing_ok=True)
        await asyncio.to_thread(_remove_job_exchange, job_id)
        return {"id": job_id, "status": "complete"}
    if job["job_type"] == "photo_thumbnail":
        manifest_path = str(_photo_job_output_paths(job_id)[1])
        result = await _complete_photo_thumbnail_job(
            db,
            job=job,
            lease_token=lease_token,
            manifest_path=manifest_path,
        )
        await asyncio.to_thread(_remove_job_exchange, job_id)
        return result
    if job["job_type"] != "fit_import":
        raise FitnessConflictError("Fitness job type is not supported")
    manifest_path = str(_job_output_paths(job_id)[1])
    manifest, temporary_parquet = await asyncio.to_thread(
        _validate_manifest, job_id, manifest_path
    )
    user = {"id": job["owner_user_id"], "family_id": job["family_id"]}
    payload = json.loads(job["payload_json"] or "{}")
    regeneration_activity_id = payload.get("regenerate_activity_id")
    import_row = await owned_row(
        db, table="health_imports", record_id=payload["import_id"], user=user
    )
    source = await owned_row(
        db,
        table="health_source_records",
        record_id=import_row["source_record_id"],
        user=user,
    )
    source_asset = await owned_row(
        db, table="health_file_assets", record_id=source["raw_asset_id"], user=user
    )
    if source_asset["state"] != "ready" or not asset_path(source_asset).is_file():
        raise FitnessConflictError("Retained source disappeared before result commit")

    source_result = manifest["source"]
    manufacturer = str(source_result.get("manufacturer") or "").lower()
    trusted_intervals_garmin = bool(
        source["transport_key"] == "intervals_icu"
        and source["origin_provider_key"] == "garmin"
    )
    parsed_provider = (
        "garmin" if "garmin" in manufacturer or trusted_intervals_garmin else "other"
    )
    duplicate_activity = None
    if not regeneration_activity_id and source_result.get("fit_identity"):
        duplicate_activity = await (
            await db.execute(
                "SELECT a.* FROM health_source_records s "
                "JOIN health_activity_source_records l ON l.source_record_id = s.id "
                "AND l.deleted_at IS NULL JOIN health_activities a ON a.id = l.activity_id "
                "AND a.deleted_at IS NULL WHERE s.family_id = ? AND s.owner_user_id = ? "
                "AND s.id <> ? AND s.origin_provider_key = ? AND s.external_object_id = ? "
                "AND s.deleted_at IS NULL ORDER BY l.created_at LIMIT 1",
                (
                    user["family_id"],
                    user["id"],
                    source["id"],
                    parsed_provider,
                    source_result["fit_identity"],
                ),
            )
        ).fetchone()

    activity_data = manifest["activity"]
    replacement_activity: dict[str, Any] | None = None
    if duplicate_activity is not None and not duplicate_activity["primary_stream_asset_id"]:
        replacement_activity = dict(duplicate_activity)
        duplicate_activity = None
    if (
        not regeneration_activity_id
        and duplicate_activity is None
        and replacement_activity is None
    ):
        replacement_activity = await _healthkit_garmin_promotion_candidate(
            db,
            user=user,
            source=source,
            activity=activity_data,
        )
    if regeneration_activity_id:
        activity_id = regeneration_activity_id
        regeneration_activity = await owned_row(
            db,
            table="health_activities",
            record_id=activity_id,
            user=user,
        )
        if regeneration_activity["primary_source_record_id"] != source["id"]:
            raise FitnessConflictError("Activity regeneration source does not match")
        replacement_activity = dict(regeneration_activity)
    else:
        activity_id = (
            duplicate_activity["id"]
            if duplicate_activity is not None
            else replacement_activity["id"]
            if replacement_activity is not None
            else new_id()
        )
    stream_id = new_id()
    stream_asset_id = new_id()
    stream_storage_key = str(Path("streams") / _owner_component(user["id"]) / f"{stream_id}.parquet")
    final_parquet = _contained(fitness_cache_root(), fitness_cache_root() / stream_storage_key)
    final_parquet.parent.mkdir(parents=True, exist_ok=True)

    await db.execute("BEGIN IMMEDIATE")
    try:
        if duplicate_activity:
            temporary_parquet.unlink(missing_ok=True)
        else:
            os.replace(temporary_parquet, final_parquet)
            settings_row = await (
                await db.execute(
                    "SELECT timezone FROM health_user_settings WHERE family_id = ? "
                    "AND owner_user_id = ? AND deleted_at IS NULL",
                    (user["family_id"], user["id"]),
                )
            ).fetchone()
            timezone_name = settings_row["timezone"] if settings_row else "Europe/London"
            try:
                local_zone = ZoneInfo(timezone_name)
            except ZoneInfoNotFoundError:
                timezone_name = "Europe/London"
                local_zone = ZoneInfo(timezone_name)
            started = datetime.fromisoformat(
                activity_data["started_at_utc"].replace("Z", "+00:00")
            )
            if started.tzinfo is None:
                started = started.replace(tzinfo=timezone.utc)
            activity_values = {
                    "sport_key": activity_data["sport_key"],
                    "sub_sport_key": activity_data.get("sub_sport_key"),
                    "status": "completed",
                    "started_at_utc": activity_data["started_at_utc"],
                    "ended_at_utc": activity_data.get("ended_at_utc"),
                    "local_timezone": timezone_name,
                    "local_calendar_date": started.astimezone(local_zone).date().isoformat(),
                    "elapsed_duration_s": activity_data.get("elapsed_duration_s"),
                    "timer_duration_s": activity_data.get("timer_duration_s"),
                    "moving_duration_s": activity_data.get("moving_duration_s"),
                    "distance_m": activity_data.get("distance_m"),
                    "energy_kcal": activity_data.get("energy_kcal"),
                    "measurement_quality": activity_data.get(
                        "measurement_quality", "source_reported"
                    ),
                    "import_state": "complete",
                    "parser_version": manifest.get("parser_version", PARSER_VERSION),
                    "workout_classification": activity_data.get("workout_classification"),
                    "classification_source": activity_data.get(
                        "classification_source", "derived"
                    ),
                    "route_preview_json": activity_data.get("route_preview", []),
                    "primary_source_record_id": source["id"],
                    "primary_stream_asset_id": stream_id,
            }
            if replacement_activity is not None:
                timestamp = now_iso()
                old_stream_id = replacement_activity["primary_stream_asset_id"]
                if old_stream_id:
                    await save_owned_rows_history(
                        db,
                        table="health_activity_stream_assets",
                        user=user,
                        where="id = ? AND deleted_at IS NULL",
                        params=(old_stream_id,),
                    )
                    await db.execute(
                        "UPDATE health_activity_stream_assets SET deleted_at = ?, updated_at = ?, "
                        "revision = revision + 1 WHERE id = ? AND family_id = ? "
                        "AND owner_user_id = ? AND deleted_at IS NULL",
                        (timestamp, timestamp, old_stream_id, user["family_id"], user["id"]),
                    )
                for table in (
                    "health_activity_metric_index",
                    "health_activity_features",
                    "health_activity_analysis_results",
                    "health_activity_quality_findings",
                ):
                    await save_owned_rows_history(
                        db,
                        table=table,
                        user=user,
                        where="activity_id = ? AND deleted_at IS NULL",
                        params=(activity_id,),
                    )
                    await db.execute(
                        f"UPDATE {table} SET deleted_at = ?, updated_at = ?, "
                        "revision = revision + 1 WHERE family_id = ? AND owner_user_id = ? "
                        "AND activity_id = ? AND deleted_at IS NULL",
                        (timestamp, timestamp, user["family_id"], user["id"], activity_id),
                    )
                for table in ("health_activity_intervals", "health_activity_summary_metrics"):
                    await save_owned_rows_history(
                        db,
                        table=table,
                        user=user,
                        where="activity_id = ? AND origin IN ('source','derived') "
                        "AND deleted_at IS NULL",
                        params=(activity_id,),
                    )
                    await db.execute(
                        f"UPDATE {table} SET deleted_at = ?, updated_at = ?, "
                        "revision = revision + 1 WHERE family_id = ? AND owner_user_id = ? "
                        "AND activity_id = ? AND origin IN ('source','derived') "
                        "AND deleted_at IS NULL",
                        (timestamp, timestamp, user["family_id"], user["id"], activity_id),
                    )
                await save_owned_rows_history(
                    db,
                    table="health_activity_markers",
                    user=user,
                    where="activity_id = ? AND deleted_at IS NULL",
                    params=(activity_id,),
                )
                await db.execute(
                    "UPDATE health_activity_markers SET deleted_at = ?, updated_at = ?, "
                    "revision = revision + 1 WHERE family_id = ? AND owner_user_id = ? "
                    "AND activity_id = ? AND deleted_at IS NULL",
                    (timestamp, timestamp, user["family_id"], user["id"], activity_id),
                )
                if replacement_activity.get("classification_source") == "user":
                    activity_values.pop("workout_classification", None)
                    activity_values.pop("classification_source", None)
                await update_owned(
                    db,
                    table="health_activities",
                    record_id=activity_id,
                    values=activity_values,
                    user=user,
                    now=timestamp,
                    record_sync_change=False,
                )
            else:
                await insert_owned(
                    db,
                    table="health_activities",
                    record_id=activity_id,
                    values={
                        **activity_values,
                        "title": activity_data["title"],
                        "revision": 1,
                    },
                    user=user,
                    record_sync_change=False,
                )
            await insert_owned(
                db,
                table="health_file_assets",
                record_id=stream_asset_id,
                values={
                    "asset_kind": "activity_stream",
                    "storage_class": "regenerable",
                    "storage_key": stream_storage_key,
                    "original_filename": None,
                    "media_type": "application/vnd.apache.parquet",
                    "byte_size": final_parquet.stat().st_size,
                    "state": "ready",
                    "source_asset_id": source_asset["id"],
                    "revision": 1,
                },
                user=user,
            )
            await insert_owned(
                db,
                table="health_activity_stream_assets",
                record_id=stream_id,
                values={
                    "activity_id": activity_id,
                    "file_asset_id": stream_asset_id,
                    "stream_kind": "primary",
                    "format": "parquet",
                    "schema_version": manifest["stream"]["schema_version"],
                    "parser_version": manifest["parser_version"],
                    "row_count": manifest["stream"]["row_count"],
                    "start_offset_ms": manifest["stream"].get("start_offset_ms"),
                    "end_offset_ms": manifest["stream"].get("end_offset_ms"),
                    "revision": 1,
                },
                user=user,
            )
            for metric in manifest["stream"].get("metric_index", []):
                await insert_owned(
                    db,
                    table="health_activity_metric_index",
                    record_id=new_id(),
                    values={**metric, "activity_id": activity_id, "stream_asset_id": stream_id, "revision": 1},
                    user=user,
                )
            for metric in manifest.get("summary_metrics", []):
                await insert_owned(
                    db,
                    table="health_activity_summary_metrics",
                    record_id=new_id(),
                    values={**metric, "activity_id": activity_id, "revision": 1},
                    user=user,
                )
            for interval in manifest.get("intervals", []):
                await insert_owned(
                    db,
                    table="health_activity_intervals",
                    record_id=new_id(),
                    values={
                        **{key: value for key, value in interval.items() if key != "metrics"},
                        "activity_id": activity_id,
                        "metrics_json": interval.get("metrics", {}),
                        "revision": 1,
                    },
                    user=user,
                )
            for marker in manifest.get("markers", []):
                await insert_owned(
                    db,
                    table="health_activity_markers",
                    record_id=new_id(),
                    values={
                        **{key: value for key, value in marker.items() if key != "payload"},
                        "activity_id": activity_id,
                        "payload_json": marker.get("payload", {}),
                        "revision": 1,
                    },
                    user=user,
                )
            for key, value in manifest.get("features", {}).items():
                await insert_owned(
                    db,
                    table="health_activity_features",
                    record_id=new_id(),
                    values={
                        "activity_id": activity_id,
                        "feature_key": key,
                        "feature_version": manifest["parser_version"],
                        "value_json": value if isinstance(value, dict) else {"value": value},
                        "quality": "derived",
                        "revision": 1,
                    },
                    user=user,
                )
            if manifest.get("records"):
                await insert_owned(
                    db,
                    table="health_activity_features",
                    record_id=new_id(),
                    values={
                        "activity_id": activity_id,
                        "feature_key": "running.records",
                        "feature_version": manifest["parser_version"],
                        "value_json": manifest["records"],
                        "quality": "derived",
                        "revision": 1,
                    },
                    user=user,
                )
            for finding in manifest.get("analysis_findings", []):
                await insert_owned(
                    db,
                    table="health_activity_analysis_results",
                    record_id=new_id(),
                    values={
                        "activity_id": activity_id,
                        "analysis_key": finding["key"],
                        "calculation_version": manifest["parser_version"],
                        "status": finding.get("status", "valid"),
                        "result_json": finding,
                        "revision": 1,
                    },
                    user=user,
                )
            for quality in manifest.get("quality_findings", []):
                await insert_owned(
                    db,
                    table="health_activity_quality_findings",
                    record_id=new_id(),
                    values={
                        "activity_id": activity_id,
                        "finding_key": quality["key"],
                        "severity": quality["severity"],
                        "message": quality["message"],
                        "start_offset_ms": quality.get("start_offset_ms"),
                        "end_offset_ms": quality.get("end_offset_ms"),
                        "limits_analysis_keys_json": quality.get("limits_analysis_keys", []),
                        "revision": 1,
                    },
                    user=user,
                )

        if replacement_activity is not None and not regeneration_activity_id:
            timestamp = now_iso()
            await save_owned_rows_history(
                db,
                table="health_activity_source_records",
                user=user,
                where="activity_id = ? AND role = 'primary' AND source_record_id <> ? "
                "AND deleted_at IS NULL",
                params=(activity_id, source["id"]),
            )
            await db.execute(
                "UPDATE health_activity_source_records SET role = 'corroborating', "
                "updated_at = ?, revision = revision + 1 WHERE family_id = ? "
                "AND owner_user_id = ? AND activity_id = ? AND role = 'primary' "
                "AND source_record_id <> ? AND deleted_at IS NULL",
                (
                    timestamp,
                    user["family_id"],
                    user["id"],
                    activity_id,
                    source["id"],
                ),
            )
        existing_link = await (
            await db.execute(
                "SELECT id FROM health_activity_source_records WHERE family_id = ? "
                "AND owner_user_id = ? AND activity_id = ? AND source_record_id = ? "
                "AND deleted_at IS NULL",
                (user["family_id"], user["id"], activity_id, source["id"]),
            )
        ).fetchone()
        if existing_link is None:
            await insert_owned(
                db,
                table="health_activity_source_records",
                record_id=new_id(),
                values={
                    "activity_id": activity_id,
                    "source_record_id": source["id"],
                    "role": "corroborating" if duplicate_activity else "primary",
                    "revision": 1,
                },
                user=user,
            )
        metadata = json.loads(source["raw_metadata_json"] or "{}")
        metadata.update(source_result)
        await update_owned(
            db,
            table="health_source_records",
            record_id=source["id"],
            values={
                "external_object_id": source_result.get("fit_identity"),
                "origin_provider_key": parsed_provider,
                "source_device_identifier": (
                    source_result.get("device_name")
                    or source["source_device_identifier"]
                ),
                "source_created_at_utc": source_result.get("source_created_at_utc"),
                "raw_metadata_json": metadata,
                "parser_name": manifest.get("parser_name"),
                "parser_version": manifest.get("parser_version"),
            },
            user=user,
        )
        await update_owned(
            db,
            table="health_imports",
            record_id=import_row["id"],
            values={
                "activity_id": activity_id,
                "status": "complete",
                "error_code": None,
                "error_message": None,
                "retryable": False,
            },
            user=user,
        )
        await save_history(
            db,
            "health_jobs",
            job_id,
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            "UPDATE health_jobs SET status = 'complete', result_json = ?, lease_token = NULL, "
            "lease_expires_at = NULL, last_error = NULL, updated_at = ? WHERE id = ? "
            "AND lease_token = ?",
            (json_text({"activity_id": activity_id}), now_iso(), job_id, lease_token),
        )
        if (
            not duplicate_activity
            and replacement_activity is None
            and not regeneration_activity_id
        ):
            await _probable_duplicates(
                db,
                user=user,
                import_id=import_row["id"],
                activity_id=activity_id,
                activity=activity_data,
            )
            from app.services.fitness.activities import auto_match_activity

            await auto_match_activity(db, user=user, activity_id=activity_id)
        if not duplicate_activity:
            final_activity = await owned_row(
                db,
                table="health_activities",
                record_id=activity_id,
                user=user,
            )
            gear_rows = await (
                await db.execute(
                    "SELECT gear_id FROM health_activity_gear_links WHERE family_id = ? "
                    "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL "
                    "ORDER BY CASE role WHEN 'primary' THEN 0 WHEN 'sensor' THEN 1 ELSE 2 END, id",
                    (user["family_id"], user["id"], activity_id),
                )
            ).fetchall()
            goal_link_rows = await (
                await db.execute(
                    "SELECT id, activity_id, goal_id, role, revision, created_at, updated_at "
                    "FROM health_activity_goal_links WHERE family_id = ? "
                    "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL "
                    "ORDER BY CASE role WHEN 'planned' THEN 0 WHEN 'user_assigned' THEN 1 ELSE 2 END, id",
                    (user["family_id"], user["id"], activity_id),
                )
            ).fetchall()
            await append_change(
                db,
                entity_type="activity_context",
                entity_id=activity_id,
                revision=int(final_activity["revision"]),
                operation="upsert",
                user=user,
                data={
                    "id": activity_id,
                    "title": final_activity["title"],
                    "notes": final_activity["notes"],
                    "session_rpe": final_activity["session_rpe"],
                    "workout_classification": final_activity[
                        "workout_classification"
                    ],
                    "planned_session_id": final_activity["planned_session_id"],
                    "gear_ids": [row["gear_id"] for row in gear_rows],
                    "goal_links": [dict(row) for row in goal_link_rows],
                    "revision": int(final_activity["revision"]),
                },
            )
        await db.commit()
    except BaseException:
        await db.rollback()
        if not duplicate_activity:
            final_parquet.unlink(missing_ok=True)
        raise
    Path(manifest_path).unlink(missing_ok=True)
    await asyncio.to_thread(_remove_job_exchange, job_id)
    return {"id": job_id, "status": "complete", "activity_id": activity_id}


async def fail_job(
    db,
    *,
    job_id: str,
    lease_token: str,
    error_code: str,
    error: str,
    retryable: bool,
) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    job = await (
        await db.execute(
            "SELECT * FROM health_jobs WHERE id = ? AND status = 'running' "
            "AND lease_token = ? AND deleted_at IS NULL",
            (job_id, lease_token),
        )
    ).fetchone()
    if job is None:
        raise FitnessConflictError("Fitness job lease is no longer valid")
    payload = json.loads(job["payload_json"] or "{}")
    await db.execute("BEGIN IMMEDIATE")
    job_user = {"id": job["owner_user_id"], "family_id": job["family_id"]}
    await save_history(
        db,
        "health_jobs",
        job_id,
        job_user["id"],
        family_id=job_user["family_id"],
    )
    await db.execute(
        "UPDATE health_jobs SET status = 'failed', last_error = ?, lease_token = NULL, "
        "lease_expires_at = NULL, updated_at = ? WHERE id = ? AND lease_token = ?",
        (f"{error_code}: {error}"[:2_000], now, job_id, lease_token),
    )
    if job["job_type"] in {"photo_thumbnail", "analysis_query"}:
        pass
    elif payload.get("regenerate_activity_id"):
        await save_owned_rows_history(
            db,
            table="health_activities",
            user=job_user,
            where="id = ? AND deleted_at IS NULL",
            params=(payload["regenerate_activity_id"],),
        )
        await db.execute(
            "UPDATE health_activities SET import_state = 'failed', updated_at = ?, "
            "revision = revision + 1 WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (
                now,
                payload["regenerate_activity_id"],
                job["family_id"],
                job["owner_user_id"],
            ),
        )
    else:
        await save_owned_rows_history(
            db,
            table="health_imports",
            user=job_user,
            where="id = ? AND deleted_at IS NULL",
            params=(payload.get("import_id"),),
        )
        await db.execute(
            "UPDATE health_imports SET status = 'error', error_code = ?, error_message = ?, "
            "retryable = ?, updated_at = ?, revision = revision + 1 WHERE id = ? "
            "AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
            (
                error_code,
                error[:2_000],
                int(retryable),
                now,
                payload.get("import_id"),
                job["family_id"],
                job["owner_user_id"],
            ),
        )
    await db.commit()
    parquet_path, manifest_path = _job_output_paths(job_id)
    parquet_path.unlink(missing_ok=True)
    _validated_parquet_path(job_id).unlink(missing_ok=True)
    thumbnail_path, _ = _photo_job_output_paths(job_id)
    thumbnail_path.unlink(missing_ok=True)
    _analysis_job_manifest_path(job_id).unlink(missing_ok=True)
    manifest_path.unlink(missing_ok=True)
    await asyncio.to_thread(_remove_job_exchange, job_id)
    return {"id": job_id, "status": "failed", "retryable": retryable}


async def _queue_deferred_file_deletion(
    db,
    *,
    asset,
    user: dict,
    timestamp: str,
) -> None:
    await db.execute(
        "INSERT INTO health_deferred_file_deletions "
        "(id, storage_key, storage_class, status, attempt_count, revision, "
        "family_id, owner_user_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, 'pending', 0, 1, ?, ?, ?, ?, ?)",
        (
            new_id(),
            asset["storage_key"],
            asset["storage_class"],
            user["family_id"],
            user["id"],
            timestamp,
            timestamp,
            user["id"],
        ),
    )


async def cleanup_stale_uploads(
    db,
    *,
    user: dict,
    limit: int = 200,
    current_time: datetime | None = None,
) -> dict[str, int]:
    """Reclaim abandoned private uploads and non-retryable failed FIT sources."""
    now = current_time or datetime.now(timezone.utc)
    staged_cutoff = (now - timedelta(hours=settings.fitness_staged_asset_ttl_hours)).isoformat()
    failed_cutoff = (
        now - timedelta(days=settings.fitness_failed_import_retention_days)
    ).isoformat()
    timestamp = now.isoformat()
    staged_rows = await (
        await db.execute(
            "SELECT f.* FROM health_file_assets f "
            "WHERE f.family_id = ? AND f.owner_user_id = ? "
            "AND f.storage_class = 'private_required' AND f.state = 'staged' "
            "AND f.deleted_at IS NULL AND f.updated_at < ? "
            "AND NOT EXISTS (SELECT 1 FROM health_progress_photos p "
            "WHERE p.family_id = f.family_id AND p.owner_user_id = f.owner_user_id "
            "AND p.original_asset_id = f.id AND p.deleted_at IS NULL) "
            "AND NOT EXISTS (SELECT 1 FROM health_food_versions v "
            "WHERE v.family_id = f.family_id AND v.owner_user_id = f.owner_user_id "
            "AND v.label_asset_id = f.id AND v.deleted_at IS NULL) "
            "ORDER BY f.updated_at LIMIT ?",
            (user["family_id"], user["id"], staged_cutoff, limit),
        )
    ).fetchall()
    stale_private_removed = 0
    for candidate in staged_rows:
        await db.execute("BEGIN IMMEDIATE")
        try:
            current = await (
                await db.execute(
                    "SELECT f.* FROM health_file_assets f "
                    "WHERE f.id = ? AND f.family_id = ? AND f.owner_user_id = ? "
                    "AND f.storage_class = 'private_required' AND f.state = 'staged' "
                    "AND f.deleted_at IS NULL AND f.updated_at < ? "
                    "AND NOT EXISTS (SELECT 1 FROM health_progress_photos p "
                    "WHERE p.family_id = f.family_id AND p.owner_user_id = f.owner_user_id "
                    "AND p.original_asset_id = f.id AND p.deleted_at IS NULL) "
                    "AND NOT EXISTS (SELECT 1 FROM health_food_versions v "
                    "WHERE v.family_id = f.family_id AND v.owner_user_id = f.owner_user_id "
                    "AND v.label_asset_id = f.id AND v.deleted_at IS NULL)",
                    (candidate["id"], user["family_id"], user["id"], staged_cutoff),
                )
            ).fetchone()
            if current is None:
                await db.rollback()
                continue
            await update_owned(
                db,
                table="health_file_assets",
                record_id=current["id"],
                values={"state": "deleted", "deleted_at": timestamp},
                user=user,
                now=timestamp,
                record_sync_change=False,
            )
            await _queue_deferred_file_deletion(
                db,
                asset=current,
                user=user,
                timestamp=timestamp,
            )
            await db.commit()
            stale_private_removed += 1
        except BaseException:
            if db.in_transaction:
                await db.rollback()
            raise

    remaining = max(0, limit - stale_private_removed)
    failed_rows = await (
        await db.execute(
            "SELECT f.* FROM health_file_assets f "
            "WHERE f.family_id = ? AND f.owner_user_id = ? "
            "AND f.storage_class = 'source_required' AND f.state = 'ready' "
            "AND f.deleted_at IS NULL "
            "AND EXISTS (SELECT 1 FROM health_imports i WHERE i.file_asset_id = f.id "
            "AND i.family_id = f.family_id AND i.owner_user_id = f.owner_user_id "
            "AND i.status = 'error' AND i.retryable = 0 AND i.updated_at < ? "
            "AND i.deleted_at IS NULL) "
            "AND NOT EXISTS (SELECT 1 FROM health_imports live WHERE live.file_asset_id = f.id "
            "AND live.family_id = f.family_id AND live.owner_user_id = f.owner_user_id "
            "AND live.deleted_at IS NULL AND (live.status != 'error' OR live.retryable != 0 "
            "OR live.updated_at >= ?)) "
            "ORDER BY f.updated_at LIMIT ?",
            (user["family_id"], user["id"], failed_cutoff, failed_cutoff, remaining),
        )
    ).fetchall()
    failed_fit_removed = 0
    for candidate in failed_rows:
        await db.execute("BEGIN IMMEDIATE")
        try:
            current = await (
                await db.execute(
                    "SELECT f.* FROM health_file_assets f "
                    "WHERE f.id = ? AND f.family_id = ? AND f.owner_user_id = ? "
                    "AND f.storage_class = 'source_required' AND f.state = 'ready' "
                    "AND f.deleted_at IS NULL "
                    "AND EXISTS (SELECT 1 FROM health_imports i WHERE i.file_asset_id = f.id "
                    "AND i.family_id = f.family_id AND i.owner_user_id = f.owner_user_id "
                    "AND i.status = 'error' AND i.retryable = 0 AND i.updated_at < ? "
                    "AND i.deleted_at IS NULL) "
                    "AND NOT EXISTS (SELECT 1 FROM health_imports live "
                    "WHERE live.file_asset_id = f.id AND live.family_id = f.family_id "
                    "AND live.owner_user_id = f.owner_user_id AND live.deleted_at IS NULL "
                    "AND (live.status != 'error' OR live.retryable != 0 "
                    "OR live.updated_at >= ?))",
                    (
                        candidate["id"],
                        user["family_id"],
                        user["id"],
                        failed_cutoff,
                        failed_cutoff,
                    ),
                )
            ).fetchone()
            if current is None:
                await db.rollback()
                continue
            await update_owned(
                db,
                table="health_file_assets",
                record_id=current["id"],
                values={"state": "deleted"},
                user=user,
                now=timestamp,
                record_sync_change=False,
            )
            await _queue_deferred_file_deletion(
                db,
                asset=current,
                user=user,
                timestamp=timestamp,
            )
            await db.commit()
            failed_fit_removed += 1
        except BaseException:
            if db.in_transaction:
                await db.rollback()
            raise

    staging_files_removed = 0
    staging_root = _contained(
        fitness_storage_root(), fitness_storage_root() / "staging"
    )
    if staging_root.is_dir():
        cutoff_timestamp = (now - timedelta(hours=settings.fitness_staged_asset_ttl_hours)).timestamp()
        for path in list(staging_root.glob("*/*.upload"))[:limit]:
            safe_path = _contained(fitness_storage_root(), path)
            try:
                if safe_path.is_file() and safe_path.stat().st_mtime < cutoff_timestamp:
                    safe_path.unlink(missing_ok=True)
                    staging_files_removed += 1
            except OSError:
                continue
    worker_inputs_removed = 0
    exchange_root = fitness_worker_exchange_root()
    cutoff_timestamp = (
        now - timedelta(hours=settings.fitness_staged_asset_ttl_hours)
    ).timestamp()
    for path in list(exchange_root.iterdir())[:limit]:
        try:
            UUID(path.name)
            safe_path = _contained(exchange_root, path)
            if safe_path.is_dir() and safe_path.stat().st_mtime < cutoff_timestamp:
                await asyncio.to_thread(shutil.rmtree, safe_path)
                worker_inputs_removed += 1
        except (OSError, ValueError):
            continue
    return {
        "stale_private_removed": stale_private_removed,
        "failed_fit_removed": failed_fit_removed,
        "staging_files_removed": staging_files_removed,
        "worker_inputs_removed": worker_inputs_removed,
    }


async def reconcile_assets(db, *, user: dict, reason: str = "manual") -> dict:
    """Report DB/filesystem drift and queue stream regeneration when possible."""
    rows = await (
        await db.execute(
            "SELECT * FROM health_file_assets WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    required_missing: list[str] = []
    regenerable_missing: list[str] = []
    regeneration_job_ids: list[str] = []
    staged_unreferenced: list[str] = []
    known_paths: set[Path] = set()
    for row in rows:
        path = asset_path(row)
        exists = path.is_file()
        if row["storage_class"] == "private_required" and row["state"] == "staged":
            progress_reference = await (
                await db.execute(
                    "SELECT 1 FROM health_progress_photos WHERE family_id = ? "
                    "AND owner_user_id = ? AND original_asset_id = ? "
                    "AND deleted_at IS NULL LIMIT 1",
                    (user["family_id"], user["id"], row["id"]),
                )
            ).fetchone()
            label_reference = await (
                await db.execute(
                    "SELECT 1 FROM health_food_versions WHERE family_id = ? "
                    "AND owner_user_id = ? AND label_asset_id = ? "
                    "AND deleted_at IS NULL LIMIT 1",
                    (user["family_id"], user["id"], row["id"]),
                )
            ).fetchone()
            if progress_reference is None and label_reference is None:
                staged_unreferenced.append(row["id"])
                if exists:
                    known_paths.add(path)
                continue
        if exists and row["state"] in {"staged", "ready", "missing"}:
            known_paths.add(path)
            if row["state"] == "missing":
                await save_owned_rows_history(
                    db,
                    table="health_file_assets",
                    user=user,
                    where="id = ?",
                    params=(row["id"],),
                )
                await db.execute(
                    "UPDATE health_file_assets SET state = 'ready', updated_at = ?, "
                    "revision = revision + 1 WHERE id = ?",
                    (now_iso(), row["id"]),
                )
            continue
        if not exists and row["state"] in {"staged", "ready", "missing"}:
            if row["storage_class"] == "regenerable":
                regenerable_missing.append(row["id"])
                if row["asset_kind"] == "progress_photo_thumbnail":
                    photo = await (
                        await db.execute(
                            "SELECT p.id FROM health_progress_photos p "
                            "JOIN health_file_assets source ON source.id = p.original_asset_id "
                            "AND source.storage_class = 'private_required' "
                            "AND source.state = 'ready' AND source.deleted_at IS NULL "
                            "WHERE p.thumbnail_asset_id = ? AND p.family_id = ? "
                            "AND p.owner_user_id = ? AND p.deleted_at IS NULL LIMIT 1",
                            (row["id"], user["family_id"], user["id"]),
                        )
                    ).fetchone()
                    if photo:
                        regeneration_job_ids.append(
                            await enqueue_photo_thumbnail_job(
                                db,
                                user=user,
                                photo_id=photo["id"],
                            )
                        )
                candidate = await (
                    await db.execute(
                        "SELECT a.id AS activity_id, i.id AS import_id "
                        "FROM health_activity_stream_assets s "
                        "JOIN health_activities a ON a.primary_stream_asset_id = s.id "
                        "AND a.deleted_at IS NULL "
                        "JOIN health_imports i ON i.source_record_id = a.primary_source_record_id "
                        "AND i.activity_id = a.id AND i.deleted_at IS NULL "
                        "JOIN health_file_assets source_asset ON source_asset.id = i.file_asset_id "
                        "AND source_asset.storage_class = 'source_required' "
                        "AND source_asset.state = 'ready' AND source_asset.deleted_at IS NULL "
                        "WHERE s.file_asset_id = ? AND s.family_id = ? "
                        "AND s.owner_user_id = ? AND s.deleted_at IS NULL "
                        "ORDER BY i.created_at DESC LIMIT 1",
                        (row["id"], user["family_id"], user["id"]),
                    )
                ).fetchone()
                if candidate:
                    source_asset = await (
                        await db.execute(
                            "SELECT f.* FROM health_imports i "
                            "JOIN health_file_assets f ON f.id = i.file_asset_id "
                            "WHERE i.id = ? AND i.family_id = ? AND i.owner_user_id = ?",
                            (candidate["import_id"], user["family_id"], user["id"]),
                        )
                    ).fetchone()
                    if source_asset and asset_path(source_asset).is_file():
                        regeneration_job_ids.append(
                            await _enqueue_regeneration_job(
                                db,
                                user=user,
                                import_id=candidate["import_id"],
                                activity_id=candidate["activity_id"],
                            )
                        )
            else:
                required_missing.append(row["id"])
            if row["state"] != "missing":
                await save_owned_rows_history(
                    db,
                    table="health_file_assets",
                    user=user,
                    where="id = ?",
                    params=(row["id"],),
                )
                await db.execute(
                    "UPDATE health_file_assets SET state = 'missing', updated_at = ?, "
                    "revision = revision + 1 WHERE id = ?",
                    (now_iso(), row["id"]),
                )
    roots = (("health", fitness_storage_root()), ("cache", fitness_cache_root()))
    orphans: list[dict[str, str]] = []
    for root_key, root in roots:
        for path in root.rglob("*"):
            if path.is_file() and path not in known_paths and "staging" not in path.parts:
                storage_key = path.relative_to(root)
                storage_class = "regenerable"
                if root_key == "health":
                    storage_class = (
                        "private_required"
                        if storage_key.parts and storage_key.parts[0] == "private"
                        else "source_required"
                    )
                orphans.append(
                    {
                        "root": root_key,
                        "storage_class": storage_class,
                        "storage_key": str(storage_key),
                    }
                )
    status = "blocked" if required_missing else "complete"
    result = {
        "status": status,
        "backup_eligible": not required_missing,
        "required_missing_asset_ids": required_missing,
        "regenerable_missing_asset_ids": regenerable_missing,
        "regeneration_job_ids": list(dict.fromkeys(regeneration_job_ids)),
        "staged_unreferenced_asset_ids": staged_unreferenced,
        "orphan_storage_keys": orphans,
    }
    await insert_owned(
        db,
        table="health_file_reconciliation_runs",
        record_id=new_id(),
        values={
            "reason": reason,
            "status": status,
            "required_missing_count": len(required_missing),
            "regenerable_missing_count": len(regenerable_missing),
            "orphan_count": len(orphans),
            "result_json": result,
            "revision": 1,
        },
        user=user,
    )
    await db.commit()
    return result


async def remove_fitness_storage_key(storage_key: str, storage_class: str) -> None:
    root = fitness_cache_root() if storage_class == "regenerable" else fitness_storage_root()
    path = _contained(root, root / storage_key)
    path.unlink(missing_ok=True)
