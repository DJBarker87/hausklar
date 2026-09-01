"""Kids' artwork archive — photographed drawings with rough dates."""

import asyncio
import re
import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Response, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.services.documents import (
    DocumentStorageError,
    remove_new_upload,
    remove_stored_document,
    resolve_storage_key,
    store_bytes,
)
from app.services.family_people import family_child_exists
from app.services.media import (
    MediaProcessingError,
    family_image_path,
    media_storage_used,
    prepare_artwork_appearance,
    prepare_family_image,
    remove_cached_images,
    store_cached_image,
)
from app.middleware.rate_limit import reserve_persistent_attempts
from app.services.record_history import save_history

router = APIRouter()

_APPROX_DATE = re.compile(r"^\d{4}(-\d{2})?(-\d{2})?$")
_IMAGE_MEDIA_TYPES = {"image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"}


class ArtworkUpdate(BaseModel):
    title: str | None = Field(None, max_length=200)
    notes: str | None = Field(None, max_length=2_000)
    approx_date: str | None = Field(None, max_length=10)
    child_id: str | None = Field(None, max_length=100)
    medium: str | None = Field(None, max_length=120)
    story: str | None = Field(None, max_length=2_000)
    child_quote: str | None = Field(None, max_length=500)
    school_year: str | None = Field(None, max_length=40)
    favourite: bool | None = None
    include_in_yearbook: bool | None = None
    yearbook_position: int | None = Field(None, ge=0, le=10_000)


class ArtworkAppearanceUpdate(BaseModel):
    rotation_degrees: int = Field(default=0, ge=0, le=270, multiple_of=90)
    enhanced: bool = False


def _precision(approx_date: str) -> str:
    return {4: "year", 7: "month", 10: "day"}[len(approx_date)]


def _validate_approx_date(value: str) -> str:
    value = value.strip()
    if not _APPROX_DATE.fullmatch(value):
        raise HTTPException(
            status_code=422,
            detail="Use a year, year-month, or full date (e.g. 2026, 2026-07, 2026-07-12)",
        )
    probe = {4: f"{value}-06-15", 7: f"{value}-15", 10: value}[len(value)]
    try:
        parsed = date.fromisoformat(probe)
    except ValueError:
        raise HTTPException(status_code=422, detail="That date does not exist")
    if not 2000 <= parsed.year <= date.today().year + 1:
        raise HTTPException(status_code=422, detail="The year looks wrong")
    return value


def _midpoint(approx_date: str) -> date:
    probe = {4: f"{approx_date}-06-15", 7: f"{approx_date}-15", 10: approx_date}[
        len(approx_date)
    ]
    return date.fromisoformat(probe)


def _age_label(date_of_birth: str | None, approx_date: str) -> str | None:
    if not date_of_birth:
        return None
    try:
        born = date.fromisoformat(date_of_birth[:10])
    except ValueError:
        return None
    moment = _midpoint(approx_date)
    years = (moment - born).days // 365
    if years < 0:
        return None
    if years == 0:
        months = max(0, (moment - born).days // 30)
        return f"{months} months" if months != 1 else "1 month"
    return f"Age {years}"


def _response(row: dict, child_name: str | None, date_of_birth: str | None) -> dict:
    version = re.sub(r"[^0-9]", "", row["updated_at"] or "")
    return {
        "id": row["id"],
        "child_id": row["child_id"],
        "child_name": child_name,
        "title": row["title"],
        "approx_date": row["approx_date"],
        "date_precision": _precision(row["approx_date"]),
        "age_label": _age_label(date_of_birth, row["approx_date"]),
        "notes": row["notes"],
        "medium": row.get("medium"),
        "story": row.get("story"),
        "child_quote": row.get("child_quote"),
        "school_year": row.get("school_year"),
        "favourite": bool(row.get("favourite")),
        "include_in_yearbook": bool(row.get("include_in_yearbook", 1)),
        "yearbook_position": row.get("yearbook_position"),
        "original_available": bool(row.get("original_storage_key")),
        "rotation_degrees": int(row.get("rotation_degrees") or 0),
        "enhanced": bool(row.get("enhanced")),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "image_url": f"/artworks/{row['id']}/image?v={version}",
        "original_image_url": (
            f"/artworks/{row['id']}/image?size=original" if row.get("original_storage_key") else None
        ),
    }


async def _child(db, family_id: str, child_id: str) -> dict:
    cursor = await db.execute(
        "SELECT id, name, date_of_birth FROM children "
        "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (child_id, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Child not found")
    return dict(row)


async def _artwork_row(db, artwork_id: str, family_id: str) -> dict:
    cursor = await db.execute(
        "SELECT * FROM artworks WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (artwork_id, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Artwork not found")
    return dict(row)


@router.post("/", status_code=201)
async def create_artwork(
    file: UploadFile = File(...),
    child_id: str = Form(..., max_length=100),
    approx_date: str = Form(..., max_length=10),
    title: str | None = Form(None, max_length=200),
    notes: str | None = Form(None, max_length=2_000),
    medium: str | None = Form(None, max_length=120),
    story: str | None = Form(None, max_length=2_000),
    child_quote: str | None = Form(None, max_length=500),
    school_year: str | None = Form(None, max_length=40),
    favourite: bool = Form(False),
    include_in_yearbook: bool = Form(True),
    client_id: str | None = Form(None, max_length=100),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    approx_date = _validate_approx_date(approx_date)
    child = await _child(db, current_user["family_id"], child_id)
    if client_id:
        cursor = await db.execute(
            "SELECT * FROM artworks WHERE family_id = ? AND client_id = ? AND deleted_at IS NULL",
            (current_user["family_id"], client_id),
        )
        existing = await cursor.fetchone()
        if existing:
            if existing["child_id"] != child_id:
                raise HTTPException(status_code=409, detail="Upload operation was already used")
            return _response(dict(existing), child["name"], child["date_of_birth"])
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
    media_type = (file.content_type or "").lower()
    if media_type not in _IMAGE_MEDIA_TYPES:
        raise HTTPException(status_code=422, detail="Artwork must be a JPEG, PNG, HEIC, or WebP image")
    data = await file.read(settings.media_max_file_bytes + 1)
    if not data:
        raise HTTPException(status_code=422, detail="The image file is empty")
    if len(data) > settings.media_max_file_bytes:
        raise HTTPException(status_code=413, detail="The image is too large")

    artwork_id = str(uuid.uuid4())
    try:
        display_data, thumbnail_data = await prepare_family_image(data)
    except MediaProcessingError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if (
        await media_storage_used(db, current_user["family_id"])
        + len(display_data)
        + len(data)
        > settings.media_family_quota_bytes
    ):
        raise HTTPException(status_code=413, detail="Family photo storage quota exceeded")

    original_storage_key: str | None = None
    display_storage_key: str | None = None
    try:
        extension = {
            "image/jpeg": "jpg",
            "image/png": "png",
            "image/heic": "heic",
            "image/heif": "heif",
            "image/webp": "webp",
        }[media_type]
        original_storage_key, _original_filename, original_file_size, _original_sha = (
            await store_bytes(
                data,
                filename=f"original.{extension}",
                media_type=media_type,
                family_id=current_user["family_id"],
                document_id=f"artwork-original-{artwork_id}",
            )
        )
        display_storage_key, _stored_filename, file_size, sha256 = await store_bytes(
            display_data,
            filename="artwork.jpg",
            media_type="image/jpeg",
            family_id=current_user["family_id"],
            document_id=f"artwork-{artwork_id}",
        )
    except DocumentStorageError as exc:
        if original_storage_key:
            await remove_new_upload(original_storage_key)
        if display_storage_key:
            await remove_new_upload(display_storage_key)
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    now = datetime.now(timezone.utc).isoformat()
    try:
        await db.execute(
            """
            INSERT INTO artworks
                (id, child_id, title, notes, medium, story, child_quote, school_year,
                 approx_date, favourite, include_in_yearbook, media_type, storage_key,
                 file_size, sha256, original_media_type, original_storage_key,
                 original_file_size, family_id, created_at, updated_at, created_by, client_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                artwork_id,
                child_id,
                title.strip()[:200] if title and title.strip() else None,
                notes.strip()[:2_000] if notes and notes.strip() else None,
                medium.strip()[:120] if medium and medium.strip() else None,
                story.strip()[:2_000] if story and story.strip() else None,
                child_quote.strip()[:500] if child_quote and child_quote.strip() else None,
                school_year.strip()[:40] if school_year and school_year.strip() else None,
                approx_date,
                int(favourite),
                int(include_in_yearbook),
                "image/jpeg",
                display_storage_key,
                file_size,
                sha256,
                media_type,
                original_storage_key,
                original_file_size,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
                client_id,
            ),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        if display_storage_key:
            await remove_new_upload(display_storage_key)
        if original_storage_key:
            await remove_new_upload(original_storage_key)
        raise
    try:
        await store_cached_image(
            current_user["family_id"], "artworks", artwork_id, "thumb", thumbnail_data
        )
    except OSError:
        pass  # Regenerable cache must never turn a committed upload into a failed retry.
    row = await _artwork_row(db, artwork_id, current_user["family_id"])
    return _response(row, child["name"], child["date_of_birth"])


@router.get("/")
async def list_artworks(
    child_id: str | None = Query(None, max_length=100),
    favourites_only: bool = Query(False),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = """
        SELECT a.*, c.name AS child_name, c.date_of_birth
        FROM artworks a
        LEFT JOIN children c ON c.id = a.child_id AND c.deleted_at IS NULL
        WHERE a.family_id = ? AND a.deleted_at IS NULL
    """
    params: list = [current_user["family_id"]]
    if child_id:
        query += " AND a.child_id = ?"
        params.append(child_id)
    if favourites_only:
        query += " AND a.favourite = 1"
    query += " ORDER BY a.favourite DESC, a.approx_date DESC, a.created_at DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])
    cursor = await db.execute(query, params)
    return [
        _response(dict(row), row["child_name"], row["date_of_birth"])
        for row in await cursor.fetchall()
    ]


@router.get("/{artwork_id}")
async def get_artwork(
    artwork_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _artwork_row(db, artwork_id, current_user["family_id"])
    child = await _child(db, current_user["family_id"], row["child_id"])
    return _response(row, child["name"], child["date_of_birth"])


@router.get("/{artwork_id}/image")
async def artwork_image(
    artwork_id: str,
    size: str = Query("full", max_length=20),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _artwork_row(db, artwork_id, current_user["family_id"])
    if size == "original":
        if not row.get("original_storage_key"):
            raise HTTPException(status_code=404, detail="The original artwork photo is unavailable")
        try:
            original = resolve_storage_key(row["original_storage_key"])
        except DocumentStorageError:
            raise HTTPException(status_code=404, detail="The original artwork photo is missing")
        if not original.is_file():
            raise HTTPException(status_code=404, detail="The original artwork photo is missing")
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
            kind="artworks",
            item_id=artwork_id,
            size=size,
        )
    except (DocumentStorageError, MediaProcessingError, OSError):
        raise HTTPException(status_code=404, detail="Artwork image is missing")
    return FileResponse(
        path,
        media_type=media_type,
        headers={"Cache-Control": "private, max-age=86400"},
    )


@router.patch("/{artwork_id}")
async def update_artwork(
    artwork_id: str,
    body: ArtworkUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _artwork_row(db, artwork_id, current_user["family_id"])
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(status_code=422, detail="No artwork changes supplied")
    if "approx_date" in updates:
        updates["approx_date"] = _validate_approx_date(updates["approx_date"] or "")
    if "child_id" in updates:
        if not await family_child_exists(db, current_user["family_id"], updates["child_id"] or ""):
            raise HTTPException(status_code=404, detail="Child not found")
    text_limits = {
        "title": 200,
        "notes": 2_000,
        "medium": 120,
        "story": 2_000,
        "child_quote": 500,
        "school_year": 40,
    }
    for field, limit in text_limits.items():
        if field in updates and updates[field] is not None:
            updates[field] = updates[field].strip()[:limit] or None
    for field in ("favourite", "include_in_yearbook"):
        if field in updates and updates[field] is not None:
            updates[field] = int(updates[field])

    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db, "artworks", artwork_id, current_user["id"], family_id=current_user["family_id"]
    )
    set_clause = ", ".join(f"{field} = ?" for field in updates)
    await db.execute(
        f"UPDATE artworks SET {set_clause}, updated_at = ? WHERE id = ? AND family_id = ?",
        [*updates.values(), now, artwork_id, current_user["family_id"]],
    )
    await db.commit()
    updated = await _artwork_row(db, artwork_id, current_user["family_id"])
    child = await _child(db, current_user["family_id"], updated["child_id"])
    return _response(updated, child["name"], child["date_of_birth"])


@router.put("/{artwork_id}/appearance")
async def update_artwork_appearance(
    artwork_id: str,
    body: ArtworkAppearanceUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    row = await _artwork_row(db, artwork_id, current_user["family_id"])
    source_key = row.get("original_storage_key") or row["storage_key"]
    try:
        source_data = await asyncio.to_thread(resolve_storage_key(source_key).read_bytes)
        display_data, thumbnail_data = await prepare_artwork_appearance(
            source_data,
            rotation_degrees=body.rotation_degrees,
            enhanced=body.enhanced,
        )
    except (DocumentStorageError, MediaProcessingError, OSError) as exc:
        raise HTTPException(status_code=422, detail="The artwork photo could not be adjusted") from exc

    used = await media_storage_used(db, current_user["family_id"])
    if used - int(row["file_size"] or 0) + len(display_data) > settings.media_family_quota_bytes:
        raise HTTPException(status_code=413, detail="Family photo storage quota exceeded")

    new_key: str | None = None
    try:
        new_key, _filename, file_size, sha256 = await store_bytes(
            display_data,
            filename="artwork.jpg",
            media_type="image/jpeg",
            family_id=current_user["family_id"],
            document_id=f"artwork-display-{artwork_id}-{uuid.uuid4()}",
        )
        now = datetime.now(timezone.utc).isoformat()
        await save_history(
            db, "artworks", artwork_id, current_user["id"], family_id=current_user["family_id"]
        )
        await db.execute(
            """
            UPDATE artworks
            SET storage_key = ?, media_type = 'image/jpeg', file_size = ?, sha256 = ?,
                original_storage_key = COALESCE(original_storage_key, ?),
                original_media_type = COALESCE(original_media_type, ?),
                original_file_size = COALESCE(original_file_size, ?),
                rotation_degrees = ?, enhanced = ?, updated_at = ?
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                new_key,
                file_size,
                sha256,
                row["storage_key"],
                row["media_type"],
                row["file_size"],
                body.rotation_degrees,
                int(body.enhanced),
                now,
                artwork_id,
                current_user["family_id"],
            ),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        if new_key:
            await remove_new_upload(new_key)
        raise

    if row.get("original_storage_key"):
        await remove_stored_document(row["storage_key"])
    await remove_cached_images(current_user["family_id"], "artworks", artwork_id)
    try:
        await store_cached_image(
            current_user["family_id"], "artworks", artwork_id, "thumb", thumbnail_data
        )
    except OSError:
        pass
    updated = await _artwork_row(db, artwork_id, current_user["family_id"])
    child = await _child(db, current_user["family_id"], updated["child_id"])
    return _response(updated, child["name"], child["date_of_birth"])


@router.delete("/{artwork_id}", status_code=204)
async def delete_artwork(
    artwork_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _artwork_row(db, artwork_id, current_user["family_id"])
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db, "artworks", artwork_id, current_user["id"], family_id=current_user["family_id"]
    )
    await db.execute(
        "UPDATE artworks SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, artwork_id, current_user["family_id"]),
    )
    await db.commit()
    await remove_cached_images(current_user["family_id"], "artworks", artwork_id)
    return Response(status_code=204)


@router.post("/{artwork_id}/restore")
async def restore_artwork(
    artwork_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM artworks WHERE id = ? AND family_id = ? AND deleted_at IS NOT NULL",
        (artwork_id, current_user["family_id"]),
    )
    row = await cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Removed artwork not found")
    if not resolve_storage_key(row["storage_key"]).is_file():
        raise HTTPException(status_code=409, detail="The artwork image is no longer available")
    now = datetime.now(timezone.utc).isoformat()
    await save_history(
        db, "artworks", artwork_id, current_user["id"], family_id=current_user["family_id"]
    )
    await db.execute(
        "UPDATE artworks SET deleted_at = NULL, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, artwork_id, current_user["family_id"]),
    )
    await db.commit()
    restored = await _artwork_row(db, artwork_id, current_user["family_id"])
    child = await _child(db, current_user["family_id"], restored["child_id"])
    return _response(restored, child["name"], child["date_of_birth"])
