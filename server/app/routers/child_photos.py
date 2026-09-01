"""Photos of the children, added explicitly in-app (no external photo service).

Supports batch upload with the real capture date from the camera roll (the
client sends taken_on per file; a best-effort JPEG EXIF read is the fallback),
and captions that can be edited later.
"""

import re
import uuid
from datetime import date, datetime, timezone

import asyncio
import logging

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Response, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, field_validator

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.services.documents import (
    DocumentStorageError,
    remove_new_upload,
    resolve_storage_key,
    store_bytes,
)
from app.middleware.rate_limit import reserve_persistent_attempts
from app.services.media import (
    MediaProcessingError,
    family_image_path,
    media_storage_used,
    prepare_family_image,
    remove_cached_images,
    store_cached_image,
)
from app.services.record_history import save_history

router = APIRouter()
logger = logging.getLogger(__name__)

_IMAGE_MEDIA_TYPES = {
    "image/jpeg",
    "image/png",
    "image/heic",
    "image/heif",
    "image/webp",
    "image/gif",
    "image/tiff",
}
_MAX_BATCH = 5


class ChildPhotoUpdate(BaseModel):
    caption: str | None = Field(None, max_length=2_000)
    taken_on: str | None = Field(None, max_length=10)
    child_id: str | None = Field(None, max_length=100)
    location: str | None = Field(None, max_length=300)
    story: str | None = Field(None, max_length=2_000)
    favourite: bool | None = None
    include_in_yearbook: bool | None = None
    yearbook_position: int | None = Field(None, ge=0, le=10_000)

    @field_validator("taken_on")
    @classmethod
    def _taken_on(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            return date.fromisoformat(value[:10]).isoformat()
        except (TypeError, ValueError) as exc:
            raise ValueError("taken_on must be an ISO date") from exc


def _valid_taken_on(value: str | None) -> str | None:
    if not value:
        return None
    try:
        return date.fromisoformat(value[:10]).isoformat()
    except (TypeError, ValueError):
        return None


def _exif_taken_on(data: bytes) -> str | None:
    """Best-effort capture date from a JPEG's EXIF header, or None.

    EXIF stores the timestamp as the distinctive "YYYY:MM:DD HH:MM:SS" text near
    the start of the file; scan the header region for it rather than walking the
    TIFF structure, which is fragile across encoders.
    """
    if data[:2] != b"\xff\xd8" or b"Exif" not in data[:64]:
        return None
    match = re.search(rb"(\d{4}):(\d{2}):(\d{2}) \d{2}:\d{2}:\d{2}", data[:65_536])
    if not match:
        return None
    year, month, day = (int(match.group(i)) for i in (1, 2, 3))
    try:
        return date(year, month, day).isoformat()
    except ValueError:
        return None


def _response(row: dict, child_name: str | None) -> dict:
    version = re.sub(r"[^0-9]", "", row["updated_at"] or "")
    return {
        "id": row["id"],
        "child_id": row["child_id"],
        "child_name": child_name,
        "caption": row["caption"],
        "taken_on": row["taken_on"],
        "location": row.get("location"),
        "story": row.get("story"),
        "favourite": bool(row.get("favourite")),
        "include_in_yearbook": bool(row.get("include_in_yearbook", 1)),
        "yearbook_position": row.get("yearbook_position"),
        "original_available": bool(row.get("original_storage_key")),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "image_url": f"/child-photos/{row['id']}/image?v={version}",
        "original_image_url": (
            f"/child-photos/{row['id']}/image?size=original"
            if row.get("original_storage_key")
            else None
        ),
    }


async def _child(db, family_id: str, child_id: str) -> dict:
    cursor = await db.execute(
        "SELECT id, name FROM children WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (child_id, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Child not found")
    return dict(row)


async def _photo_row(db, photo_id: str, family_id: str) -> dict:
    cursor = await db.execute(
        "SELECT * FROM child_photos WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (photo_id, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Photo not found")
    return dict(row)


async def _remove_new_uploads(storage_keys: list[str]) -> None:
    results = await asyncio.gather(
        *(remove_new_upload(storage_key) for storage_key in storage_keys),
        return_exceptions=True,
    )
    for result in results:
        if isinstance(result, BaseException):
            logger.warning("Could not remove unused child-photo upload: %s", type(result).__name__)


@router.post("/", status_code=201)
async def upload_photos(
    files: list[UploadFile] = File(...),
    child_id: str = Form(..., max_length=100),
    taken_on: list[str] = Form(default=[]),
    client_id: list[str] = Form(default=[]),
    caption: str | None = Form(None, max_length=2_000),
    location: str | None = Form(None, max_length=300),
    story: str | None = Form(None, max_length=2_000),
    favourite: bool = Form(False),
    include_in_yearbook: bool = Form(True),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Batch-upload photos for a child; each keeps its own camera-roll date."""
    if not files:
        raise HTTPException(status_code=422, detail="No photos supplied")
    if len(files) > _MAX_BATCH:
        raise HTTPException(status_code=422, detail=f"Upload at most {_MAX_BATCH} photos at once")
    child = await _child(db, current_user["family_id"], child_id)
    caption = caption.strip()[:2_000] if caption and caption.strip() else None
    location = location.strip()[:300] if location and location.strip() else None
    story = story.strip()[:2_000] if story and story.strip() else None
    today = date.today().isoformat()
    await reserve_persistent_attempts(
        db,
        [
            (
                f"media-upload:{current_user['family_id']}",
                settings.media_upload_rate_limit_requests,
                3_600,
            )
        ],
        detail_prefix="Too many photo uploads",
    )
    prepared: list[dict] = []
    stored_keys: list[str] = []
    prepared_bytes = 0
    try:
        for index, upload in enumerate(files):
            operation_id = client_id[index].strip()[:100] if index < len(client_id) else None
            if operation_id:
                cursor = await db.execute(
                    "SELECT id, child_id FROM child_photos "
                    "WHERE family_id = ? AND client_id = ? AND deleted_at IS NULL",
                    (current_user["family_id"], operation_id),
                )
                existing = await cursor.fetchone()
                if existing:
                    if existing["child_id"] != child_id:
                        raise HTTPException(
                            status_code=409, detail="Upload operation was already used"
                        )
                    prepared.append(
                        {
                            "operation_id": operation_id,
                            "existing_id": existing["id"],
                        }
                    )
                    continue
            media_type = (upload.content_type or "").lower()
            if media_type not in _IMAGE_MEDIA_TYPES:
                raise HTTPException(
                    status_code=422,
                    detail="Photos must be JPEG, PNG, HEIC, WebP, GIF, or TIFF",
                )
            data = await upload.read(settings.media_max_file_bytes + 1)
            if not data:
                raise HTTPException(status_code=422, detail="A photo file was empty")
            if len(data) > settings.media_max_file_bytes:
                raise HTTPException(status_code=413, detail="A photo is too large")

            client_date = taken_on[index] if index < len(taken_on) else None
            when = _valid_taken_on(client_date) or _exif_taken_on(data) or today
            try:
                display_data, thumbnail_data = await prepare_family_image(data)
            except MediaProcessingError as exc:
                raise HTTPException(status_code=422, detail=str(exc)) from exc
            if prepared_bytes + len(display_data) + len(data) > settings.media_family_quota_bytes:
                raise HTTPException(status_code=413, detail="Family photo storage quota exceeded")

            photo_id = str(uuid.uuid4())
            extension = {
                "image/jpeg": "jpg",
                "image/png": "png",
                "image/heic": "heic",
                "image/heif": "heif",
                "image/webp": "webp",
                "image/gif": "gif",
                "image/tiff": "tiff",
            }[media_type]
            original_storage_key, _original_filename, original_file_size, _original_sha = (
                await store_bytes(
                    data,
                    filename=f"original.{extension}",
                    media_type=media_type,
                    family_id=current_user["family_id"],
                    document_id=f"childphoto-original-{photo_id}",
                )
            )
            stored_keys.append(original_storage_key)
            storage_key, _filename, file_size, sha256 = await store_bytes(
                display_data,
                filename="photo.jpg",
                media_type="image/jpeg",
                family_id=current_user["family_id"],
                document_id=f"childphoto-{photo_id}",
            )
            stored_keys.append(storage_key)
            now = datetime.now(timezone.utc).isoformat()
            prepared.append(
                {
                    "operation_id": operation_id,
                    "photo_id": photo_id,
                    "taken_on": when,
                    "storage_key": storage_key,
                    "file_size": file_size,
                    "sha256": sha256,
                    "original_media_type": media_type,
                    "original_storage_key": original_storage_key,
                    "original_file_size": original_file_size,
                    "created_at": now,
                    "thumbnail": thumbnail_data,
                }
            )
            prepared_bytes += file_size + original_file_size

        # Image decoding and filesystem writes are intentionally outside the DB
        # reservation. Recheck idempotency and quota under one short transaction so
        # concurrent retries return the winner rather than hitting the unique index.
        await db.execute("BEGIN IMMEDIATE")
        storage_used = await media_storage_used(db, current_user["family_id"])
        resolved_ids: list[str] = []
        inserted_keys: set[str] = set()
        thumbnails: list[tuple[str, bytes]] = []
        for item in prepared:
            operation_id = item["operation_id"]
            existing = None
            if operation_id:
                existing = await (
                    await db.execute(
                        "SELECT id, child_id FROM child_photos "
                        "WHERE family_id = ? AND client_id = ? AND deleted_at IS NULL",
                        (current_user["family_id"], operation_id),
                    )
                ).fetchone()
            if existing is not None:
                if existing["child_id"] != child_id:
                    raise HTTPException(status_code=409, detail="Upload operation was already used")
                resolved_ids.append(existing["id"])
                continue

            storage_key = item.get("storage_key")
            if not storage_key:
                # The preflight replay was deleted before this transaction began.
                # Retrying lets the client upload its bytes as a fresh active row.
                raise HTTPException(
                    status_code=409,
                    detail="The saved photo changed while uploading. Please try again.",
                )
            file_size = item["file_size"]
            original_storage_key = item.get("original_storage_key")
            original_file_size = item.get("original_file_size", 0)
            if storage_used + file_size + original_file_size > settings.media_family_quota_bytes:
                raise HTTPException(status_code=413, detail="Family photo storage quota exceeded")
            await db.execute(
                """
                INSERT INTO child_photos
                    (id, child_id, caption, taken_on, location, story, favourite,
                     include_in_yearbook, media_type, storage_key, file_size, sha256,
                     original_media_type, original_storage_key, original_file_size,
                     family_id, created_at, updated_at, created_by, client_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    item["photo_id"],
                    child_id,
                    caption,
                    item["taken_on"],
                    location,
                    story,
                    int(favourite),
                    int(include_in_yearbook),
                    "image/jpeg",
                    storage_key,
                    file_size,
                    item["sha256"],
                    item["original_media_type"],
                    original_storage_key,
                    original_file_size,
                    current_user["family_id"],
                    item["created_at"],
                    item["created_at"],
                    current_user["id"],
                    operation_id,
                ),
            )
            resolved_ids.append(item["photo_id"])
            inserted_keys.add(storage_key)
            inserted_keys.add(original_storage_key)
            thumbnails.append((item["photo_id"], item["thumbnail"]))
            storage_used += file_size + original_file_size

        unique_ids = list(dict.fromkeys(resolved_ids))
        placeholders = ", ".join("?" for _ in unique_ids)
        rows = await (
            await db.execute(
                f"SELECT * FROM child_photos WHERE id IN ({placeholders}) "
                "AND family_id = ? AND deleted_at IS NULL",
                [*unique_ids, current_user["family_id"]],
            )
        ).fetchall()
        rows_by_id = {row["id"]: dict(row) for row in rows}
        if len(rows_by_id) != len(unique_ids):
            raise RuntimeError("A saved child photo could not be read back")
        response_photos = [_response(rows_by_id[photo_id], child["name"]) for photo_id in resolved_ids]
        await db.commit()
    except DocumentStorageError as exc:
        if db.in_transaction:
            await db.rollback()
        await _remove_new_uploads(stored_keys)
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        await _remove_new_uploads(stored_keys)
        raise

    await _remove_new_uploads([key for key in stored_keys if key not in inserted_keys])
    await asyncio.gather(
        *(
            store_cached_image(
                current_user["family_id"], "child-photos", photo_id, "thumb", thumbnail
            )
            for photo_id, thumbnail in thumbnails
        ),
        return_exceptions=True,
    )

    return {"photos": response_photos}


@router.get("/")
async def list_photos(
    child_id: str | None = Query(None, max_length=100),
    year: int | None = Query(None, ge=2000, le=2200),
    favourites_only: bool = Query(False),
    offset: int = Query(0, ge=0),
    limit: int = Query(60, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = """
        SELECT p.*, c.name AS child_name
        FROM child_photos p
        LEFT JOIN children c ON c.id = p.child_id AND c.deleted_at IS NULL
        WHERE p.family_id = ? AND p.deleted_at IS NULL
    """
    params: list = [current_user["family_id"]]
    if child_id:
        query += " AND p.child_id = ?"
        params.append(child_id)
    if year is not None:
        query += " AND SUBSTR(p.taken_on, 1, 4) = ?"
        params.append(str(year))
    if favourites_only:
        query += " AND p.favourite = 1"
    query += " ORDER BY p.favourite DESC, p.taken_on DESC, p.created_at DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])
    cursor = await db.execute(query, params)
    return [_response(dict(row), row["child_name"]) for row in await cursor.fetchall()]


@router.get("/{photo_id}")
async def get_photo(
    photo_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _photo_row(db, photo_id, current_user["family_id"])
    child = await _child(db, current_user["family_id"], row["child_id"])
    return _response(row, child["name"])


@router.get("/{photo_id}/image")
async def photo_image(
    photo_id: str,
    size: str = Query("display", max_length=20),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _photo_row(db, photo_id, current_user["family_id"])
    if size == "original":
        if not row.get("original_storage_key"):
            raise HTTPException(status_code=404, detail="The original photo is unavailable")
        try:
            original = resolve_storage_key(row["original_storage_key"])
        except DocumentStorageError:
            raise HTTPException(status_code=404, detail="The original photo is missing")
        if not original.is_file():
            raise HTTPException(status_code=404, detail="The original photo is missing")
        return FileResponse(
            original,
            media_type=row.get("original_media_type") or "application/octet-stream",
            headers={"Cache-Control": "private, max-age=86400"},
        )
    try:
        path, media_type = await family_image_path(
            original=resolve_storage_key(row["storage_key"]),
            media_type=row["media_type"],
            family_id=current_user["family_id"],
            kind="child-photos",
            item_id=photo_id,
            size=size,
        )
    except (DocumentStorageError, MediaProcessingError, OSError):
        raise HTTPException(status_code=404, detail="Photo image is missing")
    return FileResponse(
        path,
        media_type=media_type,
        headers={"Cache-Control": "private, max-age=86400"},
    )


@router.patch("/{photo_id}")
async def update_photo(
    photo_id: str,
    body: ChildPhotoUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Edit a photo's person, moment details, or keepsake curation."""
    await _photo_row(db, photo_id, current_user["family_id"])
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(status_code=422, detail="No photo changes supplied")
    if "child_id" in updates:
        await _child(db, current_user["family_id"], updates["child_id"])
    text_limits = {"caption": 2_000, "location": 300, "story": 2_000}
    for field, limit in text_limits.items():
        if field in updates and updates[field] is not None:
            updates[field] = updates[field].strip()[:limit] or None
    for field in ("favourite", "include_in_yearbook"):
        if field in updates and updates[field] is not None:
            updates[field] = int(updates[field])
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db, "child_photos", photo_id, current_user["id"], family_id=current_user["family_id"]
    )
    set_clause = ", ".join(f"{field} = ?" for field in updates)
    await db.execute(
        f"UPDATE child_photos SET {set_clause}, updated_at = ? WHERE id = ? AND family_id = ?",
        [*updates.values(), now, photo_id, current_user["family_id"]],
    )
    await db.commit()
    row = await _photo_row(db, photo_id, current_user["family_id"])
    child = await _child(db, current_user["family_id"], row["child_id"])
    return _response(row, child["name"])


@router.delete("/{photo_id}", status_code=204)
async def delete_photo(
    photo_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _photo_row(db, photo_id, current_user["family_id"])
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db, "child_photos", photo_id, current_user["id"], family_id=current_user["family_id"]
    )
    await db.execute(
        "UPDATE child_photos SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, photo_id, current_user["family_id"]),
    )
    await db.commit()
    await remove_cached_images(current_user["family_id"], "child-photos", photo_id)
    return Response(status_code=204)


@router.post("/{photo_id}/restore")
async def restore_photo(
    photo_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM child_photos WHERE id = ? AND family_id = ? AND deleted_at IS NOT NULL",
        (photo_id, current_user["family_id"]),
    )
    stored = await cursor.fetchone()
    if not stored:
        raise HTTPException(status_code=404, detail="Removed photo not found")
    row = dict(stored)
    try:
        display_exists = resolve_storage_key(row["storage_key"]).is_file()
        original_exists = (
            not row.get("original_storage_key")
            or resolve_storage_key(row["original_storage_key"]).is_file()
        )
    except DocumentStorageError:
        display_exists = False
        original_exists = False
    if not display_exists or not original_exists:
        raise HTTPException(status_code=409, detail="The photo file is no longer available")
    required = int(row.get("file_size") or 0) + int(row.get("original_file_size") or 0)
    if (
        await media_storage_used(db, current_user["family_id"]) + required
        > settings.media_family_quota_bytes
    ):
        raise HTTPException(status_code=413, detail="Family photo storage quota exceeded")
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db, "child_photos", photo_id, current_user["id"], family_id=current_user["family_id"]
    )
    await db.execute(
        "UPDATE child_photos SET deleted_at = NULL, updated_at = ? "
        "WHERE id = ? AND family_id = ?",
        (now, photo_id, current_user["family_id"]),
    )
    await db.commit()
    restored = await _photo_row(db, photo_id, current_user["family_id"])
    child = await _child(db, current_user["family_id"], restored["child_id"])
    return _response(restored, child["name"])
