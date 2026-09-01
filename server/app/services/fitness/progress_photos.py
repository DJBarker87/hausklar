"""Owner-private, two-phase progress-photo storage and metadata lifecycle."""

from __future__ import annotations

import asyncio
import hashlib
import io
import json
import os
import warnings
from datetime import date
from pathlib import Path
from uuid import UUID

from fastapi import HTTPException, UploadFile
from PIL import Image, UnidentifiedImageError
from pillow_heif import register_heif_opener

from app.config import settings
from app.models.fitness_recovery import ProgressPhotoPayload
from app.services.fitness.activity_import import (
    asset_path,
    fitness_storage_root,
    remove_fitness_storage_key,
)
from app.services.fitness.common import (
    FitnessConflictError,
    FitnessNotFoundError,
    decoded_row,
    insert_owned,
    new_id,
    now_iso,
    owned_row,
    soft_delete_owned,
    update_owned,
    validate_owned_reference,
)
from app.services.fitness.resource_limits import ensure_fitness_storage_capacity

register_heif_opener()
Image.MAX_IMAGE_PIXELS = 50_000_000

PHOTO_MEDIA_TYPES = {
    "image/jpeg": (".jpg", {"JPEG"}),
    "image/png": (".png", {"PNG"}),
    "image/heic": (".heic", {"HEIF", "HEIC"}),
    "image/heif": (".heif", {"HEIF", "HEIC"}),
}


def _owner_component(owner_id: str) -> str:
    try:
        return str(UUID(owner_id))
    except ValueError as exc:
        raise FitnessConflictError("Fitness owner identifier is invalid") from exc


def _validate_image_bytes(
    data: bytes, media_type: str, description: str = "Progress photo"
) -> None:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as image:
                image.verify()
                image_format = str(image.format or "").upper()
    except (
        UnidentifiedImageError,
        OSError,
        ValueError,
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
    ) as exc:
        raise HTTPException(
            status_code=422, detail=f"{description} could not be read"
        ) from exc
    if image_format not in PHOTO_MEDIA_TYPES[media_type][1]:
        raise HTTPException(
            status_code=422,
            detail=f"{description} content does not match its media type",
        )


async def _read_photo(
    upload: UploadFile,
    *,
    description: str = "Progress photo",
    max_upload_bytes: int,
) -> tuple[bytes, str, str]:
    media_type = (upload.content_type or "").lower().split(";", 1)[0].strip()
    if media_type not in PHOTO_MEDIA_TYPES:
        raise HTTPException(
            status_code=415,
            detail=f"{description}s must be JPEG, PNG, HEIC, or HEIF",
        )
    data = await upload.read(max_upload_bytes + 1)
    if not data:
        raise HTTPException(status_code=422, detail=f"{description} is empty")
    if len(data) > max_upload_bytes:
        raise HTTPException(status_code=413, detail=f"{description} is too large")
    await asyncio.to_thread(_validate_image_bytes, data, media_type, description)
    return data, media_type, hashlib.sha256(data).hexdigest()


def _write_immutable(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    created = False
    try:
        with path.open("xb") as handle:
            created = True
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        if created:
            path.unlink(missing_ok=True)
        raise


def _file_matches(path: Path, *, byte_size: int, fingerprint: str) -> bool:
    try:
        if not path.is_file() or path.stat().st_size != byte_size:
            return False
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest() == fingerprint
    except OSError:
        return False


async def stage_private_photo(
    db,
    *,
    user: dict,
    upload: UploadFile,
    asset_id: str,
    asset_kind: str,
) -> dict:
    try:
        asset_id = str(UUID(asset_id))
    except ValueError as exc:
        raise FitnessConflictError("Private asset identifier is invalid") from exc
    if asset_kind not in {"progress_photo", "nutrition_label"}:
        raise FitnessConflictError("Private asset kind is not supported")
    description = (
        "Nutrition-label image" if asset_kind == "nutrition_label" else "Progress photo"
    )
    data, media_type, fingerprint = await _read_photo(
        upload,
        description=description,
        max_upload_bytes=(
            settings.fitness_label_max_upload_bytes
            if asset_kind == "nutrition_label"
            else settings.fitness_photo_max_upload_bytes
        ),
    )
    suffix = PHOTO_MEDIA_TYPES[media_type][0]
    storage_key = str(Path("private") / _owner_component(user["id"]) / f"{asset_id}{suffix}")
    destination = fitness_storage_root() / storage_key
    created_file = False
    try:
        await db.execute("BEGIN IMMEDIATE")
        existing = await (
            await db.execute(
                "SELECT * FROM health_file_assets WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ?",
                (asset_id, user["family_id"], user["id"]),
            )
        ).fetchone()
        if existing is not None:
            active_replay = (
                existing["deleted_at"] is None
                and existing["state"] in {"staged", "ready"}
            )
            restorable_replay = (
                existing["deleted_at"] is not None
                and existing["state"] == "deleted"
            )
            if not (active_replay or restorable_replay) or (
                existing["asset_kind"] != asset_kind
                or existing["storage_class"] != "private_required"
                or existing["storage_key"] != storage_key
                or existing["file_fingerprint"] != fingerprint
                or int(existing["byte_size"]) != len(data)
            ):
                raise FitnessConflictError("Private asset identifier is already in use")
            if active_replay:
                if not _file_matches(
                    destination,
                    byte_size=len(data),
                    fingerprint=fingerprint,
                ):
                    raise FitnessConflictError("Private asset identifier is already in use")
                await db.commit()
                return {
                    "asset_id": asset_id,
                    "state": "staged",
                    "storage_class": "private_required",
                    "upload_acknowledged": True,
                }
        await ensure_fitness_storage_capacity(
            db,
            user=user,
            incoming_bytes=len(data),
        )
        if destination.exists():
            if not _file_matches(
                destination,
                byte_size=len(data),
                fingerprint=fingerprint,
            ):
                raise FitnessConflictError("Private asset identifier is already in use")
        else:
            await asyncio.to_thread(_write_immutable, destination, data)
            created_file = True
        values = {
            "asset_kind": asset_kind,
            "storage_class": "private_required",
            "storage_key": storage_key,
            "original_filename": Path(upload.filename or f"image{suffix}").name,
            "media_type": media_type,
            "byte_size": len(data),
            "file_fingerprint": fingerprint,
            "state": "staged",
            "revision": 1,
        }
        if existing is not None:
            values.pop("revision")
            await db.execute(
                "DELETE FROM health_deferred_file_deletions "
                "WHERE storage_key = ? AND storage_class = 'private_required'",
                (storage_key,),
            )
            await update_owned(
                db,
                table="health_file_assets",
                record_id=asset_id,
                values=values,
                user=user,
                restore=True,
                record_sync_change=False,
            )
        else:
            await insert_owned(
                db,
                table="health_file_assets",
                record_id=asset_id,
                values=values,
                user=user,
                record_sync_change=False,
            )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        if created_file:
            destination.unlink(missing_ok=True)
        raise
    return {
        "asset_id": asset_id,
        "state": "staged",
        "storage_class": "private_required",
        "upload_acknowledged": True,
    }


async def _photo_row(db, *, user: dict, photo_id: str, include_deleted: bool = False):
    return await owned_row(
        db,
        table="health_progress_photos",
        record_id=photo_id,
        user=user,
        include_deleted=include_deleted,
    )


async def progress_photo_response(db, *, user: dict, photo_id: str) -> dict:
    row = await _photo_row(db, user=user, photo_id=photo_id)
    original = await owned_row(
        db,
        table="health_file_assets",
        record_id=row["original_asset_id"],
        user=user,
        include_deleted=True,
    )
    thumbnail = None
    if row["thumbnail_asset_id"]:
        try:
            thumbnail = await owned_row(
                db,
                table="health_file_assets",
                record_id=row["thumbnail_asset_id"],
                user=user,
                include_deleted=True,
            )
        except FitnessNotFoundError:
            thumbnail = None
    phase_name = None
    if row["phase_id"]:
        phase = await (
            await db.execute(
                "SELECT name FROM health_training_phases WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ? AND deleted_at IS NULL",
                (row["phase_id"], user["family_id"], user["id"]),
            )
        ).fetchone()
        phase_name = phase["name"] if phase else None
    data = decoded_row(row)
    try:
        data["measurement_snapshot_json"] = json.loads(
            data.get("measurement_snapshot_json") or "null"
        )
    except (TypeError, json.JSONDecodeError):
        data["measurement_snapshot_json"] = None
    data.update(
        {
            "phase_name": phase_name,
            "original_state": original["state"],
            "thumbnail_state": thumbnail["state"] if thumbnail else None,
            "metadata_acknowledged": True,
        }
    )
    return data


async def create_progress_photo(
    db,
    *,
    user: dict,
    body: ProgressPhotoPayload,
    commit: bool = True,
) -> dict:
    photo_id = new_id(body.id)
    original_id = str(body.original_asset_id)
    if body.phase_id:
        await validate_owned_reference(
            db,
            table="health_training_phases",
            record_id=str(body.phase_id),
            user=user,
        )
    existing = await (
        await db.execute(
            "SELECT * FROM health_progress_photos WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (photo_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None:
        if existing["deleted_at"] is not None or existing["original_asset_id"] != original_id:
            raise FitnessConflictError("Progress photo identifier is already in use")
        return await progress_photo_response(db, user=user, photo_id=photo_id)

    owns_transaction = not db.in_transaction
    if owns_transaction:
        await db.execute("BEGIN IMMEDIATE")
    try:
        original = await owned_row(
            db,
            table="health_file_assets",
            record_id=original_id,
            user=user,
        )
        if (
            original["asset_kind"] != "progress_photo"
            or original["storage_class"] != "private_required"
            or original["state"] != "staged"
            or not asset_path(original).is_file()
        ):
            raise FitnessConflictError("A staged private original is required")
        values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
        values["original_asset_id"] = original_id
        await insert_owned(
            db,
            table="health_progress_photos",
            record_id=photo_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
        await update_owned(
            db,
            table="health_file_assets",
            record_id=original_id,
            values={"state": "ready"},
            user=user,
            record_sync_change=False,
        )
        if commit and owns_transaction:
            await db.commit()
    except BaseException:
        if owns_transaction and db.in_transaction:
            await db.rollback()
        raise
    return await progress_photo_response(db, user=user, photo_id=photo_id)


async def list_progress_photos(
    db,
    *,
    user: dict,
    pose: str | None,
    from_date: date | None,
    to_date: date | None,
    phase_id: str | None,
) -> list[dict]:
    clauses = ["family_id = ?", "owner_user_id = ?", "deleted_at IS NULL"]
    parameters: list[object] = [user["family_id"], user["id"]]
    if pose:
        clauses.append("pose = ?")
        parameters.append(pose)
    if from_date:
        clauses.append("substr(captured_at, 1, 10) >= ?")
        parameters.append(from_date.isoformat())
    if to_date:
        clauses.append("substr(captured_at, 1, 10) <= ?")
        parameters.append(to_date.isoformat())
    if phase_id:
        clauses.append("phase_id = ?")
        parameters.append(phase_id)
    rows = await (
        await db.execute(
            f"SELECT id FROM health_progress_photos WHERE {' AND '.join(clauses)} "
            "ORDER BY captured_at DESC, id",
            parameters,
        )
    ).fetchall()
    return [
        await progress_photo_response(db, user=user, photo_id=row["id"])
        for row in rows
    ]


async def delete_staged_private_asset(db, *, user: dict, asset_id: str) -> None:
    row = await (
        await db.execute(
            "SELECT * FROM health_file_assets WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL",
            (asset_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        return
    progress_reference = await (
        await db.execute(
            "SELECT 1 FROM health_progress_photos WHERE family_id = ? AND owner_user_id = ? "
            "AND (original_asset_id = ? OR thumbnail_asset_id = ?) AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], asset_id, asset_id),
        )
    ).fetchone()
    label_reference = await (
        await db.execute(
            "SELECT 1 FROM health_food_versions WHERE family_id = ? "
            "AND owner_user_id = ? AND label_asset_id = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], asset_id),
        )
    ).fetchone()
    if (
        row["state"] != "staged"
        or row["storage_class"] != "private_required"
        or progress_reference
        or label_reference
    ):
        raise FitnessConflictError("Only an unreferenced staged private asset can be cancelled")
    await update_owned(
        db,
        table="health_file_assets",
        record_id=asset_id,
        values={"state": "deleted", "deleted_at": now_iso()},
        user=user,
        record_sync_change=False,
    )
    await db.commit()
    await remove_fitness_storage_key(row["storage_key"], row["storage_class"])


async def nutrition_label_asset(db, *, user: dict, asset_id: str):
    asset = await owned_row(
        db,
        table="health_file_assets",
        record_id=asset_id,
        user=user,
    )
    if (
        asset["asset_kind"] != "nutrition_label"
        or asset["storage_class"] != "private_required"
    ):
        raise FitnessNotFoundError("Private nutrition label not found")
    reference = await (
        await db.execute(
            "SELECT 1 FROM health_food_versions WHERE family_id = ? "
            "AND owner_user_id = ? AND label_asset_id = ? "
            "AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], asset_id),
        )
    ).fetchone()
    path = asset_path(asset)
    if asset["state"] != "ready" or reference is None or not path.is_file():
        raise FitnessNotFoundError("Private nutrition label not found")
    return asset, path


async def photo_asset(db, *, user: dict, photo_id: str, thumbnail: bool):
    photo = await _photo_row(db, user=user, photo_id=photo_id)
    asset_id = photo["thumbnail_asset_id"] if thumbnail else photo["original_asset_id"]
    if not asset_id:
        raise FitnessNotFoundError("Progress-photo thumbnail is not ready")
    asset = await owned_row(
        db,
        table="health_file_assets",
        record_id=asset_id,
        user=user,
    )
    path = asset_path(asset)
    if asset["state"] != "ready" or not path.is_file():
        raise FitnessNotFoundError("Progress-photo asset is not ready")
    return asset, path


async def delete_progress_photo(
    db, *, user: dict, photo_id: str, commit: bool = True
) -> list[tuple[str, str]]:
    row = await _photo_row(db, user=user, photo_id=photo_id, include_deleted=True)
    if row["deleted_at"] is not None:
        return []
    owns_transaction = not db.in_transaction
    if owns_transaction:
        await db.execute("BEGIN IMMEDIATE")
    assets = []
    try:
        for asset_id in (row["thumbnail_asset_id"], row["original_asset_id"]):
            if not asset_id:
                continue
            try:
                assets.append(
                    await owned_row(
                        db,
                        table="health_file_assets",
                        record_id=asset_id,
                        user=user,
                        include_deleted=True,
                    )
                )
            except FitnessNotFoundError:
                continue
        await soft_delete_owned(
            db,
            table="health_progress_photos",
            record_id=photo_id,
            user=user,
        )
        for asset in assets:
            if asset["deleted_at"] is not None:
                continue
            await update_owned(
                db,
                table="health_file_assets",
                record_id=asset["id"],
                values={"state": "deleted", "deleted_at": now_iso()},
                user=user,
                record_sync_change=False,
            )
        if commit and owns_transaction:
            await db.commit()
    except BaseException:
        if owns_transaction and db.in_transaction:
            await db.rollback()
        raise
    deletions = [
        (asset["storage_key"], asset["storage_class"])
        for asset in assets
        if asset["deleted_at"] is None
    ]
    if commit and owns_transaction:
        for storage_key, storage_class in deletions:
            await remove_fitness_storage_key(storage_key, storage_class)
    return deletions
