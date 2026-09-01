import asyncio
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse

import httpx

from app.auth import get_current_user
from app.config import settings as app_settings
from app.database import database_lease, get_db
from app.models.family import FamilyMemberResponse
from app.models.family_settings import (
    HASettingsResponse,
    HASettingsTestRequest,
    HASettingsUpdate,
    normalised_origin,
    validate_ha_origin,
)
from app.utils.encryption import decrypt_value, encrypt_value
from app.services.host_integrations import require_host_integration_admin
from app.middleware.rate_limit import reserve_persistent_attempts
from app.services.media import MediaProcessingError, avatar_file_path, prepare_avatar_image
from app.services.record_history import save_history

router = APIRouter()

_AVATAR_MEDIA_TYPES = {"image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"}
_AVATAR_TOKEN = re.compile(r"^[a-f0-9]{32}$")


def _avatar_token(member_id: str, avatar_url: str | None) -> str | None:
    if not avatar_url:
        return None
    parsed = urlparse(avatar_url)
    if parsed.path != f"/family/members/{member_id}/avatar":
        return None
    token = parse_qs(parsed.query).get("v", [None])[0]
    return token if token and _AVATAR_TOKEN.fullmatch(token) else None


async def _write_avatar(path: Path, data: bytes) -> None:
    def write() -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = path.with_suffix(f".{uuid.uuid4().hex}.uploading")
        try:
            temporary.write_bytes(data)
            temporary.chmod(0o600)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)

    await asyncio.to_thread(write)


async def _remove_avatar(path: Path | None) -> None:
    if path is not None:
        await asyncio.to_thread(path.unlink, missing_ok=True)


async def _member_row(db, family_id: str, member_id: str) -> tuple[str, dict]:
    for table_name, member_type in (("users", "user"), ("children", "child")):
        cursor = await db.execute(
            f"SELECT id, name, avatar_url, updated_at FROM {table_name} "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (member_id, family_id),
        )
        row = await cursor.fetchone()
        if row:
            return table_name, {**dict(row), "member_type": member_type}
    raise HTTPException(status_code=404, detail="Family member not found")


def _member_response(row: dict) -> FamilyMemberResponse:
    return FamilyMemberResponse(
        id=row["id"],
        name=row["name"],
        member_type=row["member_type"],
        avatar_url=row["avatar_url"],
    )


@router.get("/members", response_model=list[FamilyMemberResponse])
async def list_family_members(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return all users and children as a flat list of family members."""
    members: list[FamilyMemberResponse] = []

    cursor = await db.execute(
        "SELECT id, name, avatar_url FROM users WHERE deleted_at IS NULL AND family_id = ? ORDER BY name",
        (current_user["family_id"],),
    )
    for row in await cursor.fetchall():
        members.append(FamilyMemberResponse(id=row[0], name=row[1], member_type="user", avatar_url=row[2]))

    cursor = await db.execute(
        "SELECT id, name, avatar_url FROM children WHERE deleted_at IS NULL AND family_id = ? ORDER BY date_of_birth ASC",
        (current_user["family_id"],),
    )
    for row in await cursor.fetchall():
        members.append(FamilyMemberResponse(id=row[0], name=row[1], member_type="child", avatar_url=row[2]))

    return members


@router.put("/members/{member_id}/avatar", response_model=FamilyMemberResponse)
async def update_member_avatar(
    member_id: str,
    file: UploadFile = File(...),
    operation_id: str | None = Form(None, max_length=64),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Replace a family member's avatar with the explicitly reviewed crop."""
    table_name, member = await _member_row(db, current_user["family_id"], member_id)
    operation_token = None
    if operation_id is not None:
        try:
            operation_token = uuid.UUID(operation_id).hex
        except (ValueError, AttributeError) as exc:
            raise HTTPException(status_code=422, detail="operation_id must be a UUID") from exc
        if _avatar_token(member_id, member["avatar_url"]) == operation_token:
            return _member_response(member)
    media_type = (file.content_type or "").lower()
    if media_type not in _AVATAR_MEDIA_TYPES:
        raise HTTPException(status_code=422, detail="Profile photos must be JPEG, PNG, HEIC, or WebP")
    data = await file.read(app_settings.avatar_max_file_bytes + 1)
    if not data:
        raise HTTPException(status_code=422, detail="The profile photo is empty")
    if len(data) > app_settings.avatar_max_file_bytes:
        raise HTTPException(status_code=413, detail="The profile photo is too large")
    await reserve_persistent_attempts(
        db,
        [(f"avatar-upload:{current_user['family_id']}", 120, 3_600)],
        detail_prefix="Too many profile photo uploads",
    )
    try:
        avatar = await prepare_avatar_image(data)
    except MediaProcessingError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    old_token = _avatar_token(member_id, member["avatar_url"])
    old_path = avatar_file_path(current_user["family_id"], member_id, old_token) if old_token else None
    token = operation_token or uuid.uuid4().hex
    avatar_url = f"/family/members/{member_id}/avatar?v={token}"
    path = avatar_file_path(current_user["family_id"], member_id, token)
    await _write_avatar(path, avatar)
    try:
        await save_history(
            db,
            table_name,
            member_id,
            current_user["id"],
            family_id=current_user["family_id"],
            excluded_fields={"password_hash"} if table_name == "users" else None,
        )
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            f"UPDATE {table_name} SET avatar_url = ?, updated_at = ? "
            "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (avatar_url, now, member_id, current_user["family_id"]),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        await _remove_avatar(path)
        raise
    await _remove_avatar(old_path)
    member["avatar_url"] = avatar_url
    return _member_response(member)


@router.get("/members/{member_id}/avatar")
async def member_avatar(
    member_id: str,
    v: str | None = Query(None, max_length=32),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    _, member = await _member_row(db, current_user["family_id"], member_id)
    token = _avatar_token(member_id, member["avatar_url"])
    if not token or v != token:
        raise HTTPException(status_code=404, detail="Profile photo not found")
    path = avatar_file_path(current_user["family_id"], member_id, token)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Profile photo not found")
    return FileResponse(
        path,
        media_type="image/jpeg",
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )


@router.get("/settings/ha", response_model=HASettingsResponse)
async def get_ha_settings(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return Home Assistant settings for the current user's family."""
    cursor = await db.execute(
        "SELECT setting_key, setting_value FROM family_settings WHERE family_id = ? AND setting_key IN (?, ?, ?, ?)",
        (
            current_user["family_id"],
            "ha_dashboard_url",
            "ha_url",
            "ha_token",
            "ha_config_api_url",
        ),
    )
    rows = await cursor.fetchall()
    settings = {row[0]: row[1] for row in rows}

    ha_dashboard_url = settings.get("ha_dashboard_url")
    ha_url = settings.get("ha_url")
    ha_config_api_url = settings.get("ha_config_api_url")
    token_configured = bool(settings.get("ha_token"))

    configured = bool(ha_url and token_configured)
    if current_user.get("role") != "admin":
        ha_url = None
        ha_config_api_url = None

    return HASettingsResponse(
        dashboard_url=ha_dashboard_url,
        ha_url=ha_url,
        config_api_url=ha_config_api_url,
        token_configured=token_configured,
        configured=configured,
    )


@router.put("/settings/ha", response_model=HASettingsResponse)
async def update_ha_settings(
    body: HASettingsUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update Home Assistant settings. Admin only."""
    require_host_integration_admin(current_user)

    cursor = await db.execute(
        "SELECT setting_key, setting_value FROM family_settings "
        "WHERE family_id = ? AND setting_key IN ('ha_url', 'ha_token')",
        (current_user["family_id"],),
    )
    existing = {row[0]: row[1] for row in await cursor.fetchall()}
    if body.ha_url is not None:
        try:
            validated_url = validate_ha_origin(body.ha_url, app_settings.ha_allowed_origins)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        old_url = existing.get("ha_url")
        origin_changed = (
            old_url is not None
            and normalised_origin(old_url) != normalised_origin(validated_url)
        )
        if origin_changed and body.ha_token is None:
            raise HTTPException(
                status_code=422,
                detail="Replacing the Home Assistant URL also requires a new access token",
            )
        body = body.model_copy(update={"ha_url": validated_url})

    fields = {
        "ha_dashboard_url": body.dashboard_url,
        "ha_url": body.ha_url,
        "ha_token": body.ha_token,
        "ha_config_api_url": body.config_api_url,
    }

    for key, value in fields.items():
        if value is not None:
            store_value = encrypt_value(value) if key == "ha_token" else value
            await db.execute(
                "INSERT OR REPLACE INTO family_settings (family_id, setting_key, setting_value, updated_at, updated_by) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?)",
                (current_user["family_id"], key, store_value, current_user["id"]),
            )

    await db.commit()

    return await get_ha_settings(current_user=current_user, db=db)


@router.post("/settings/ha/test")
async def test_ha_connection(
    body: HASettingsTestRequest | None = None,
    current_user: dict = Depends(get_current_user),
):
    """Test candidate or stored Home Assistant credentials without saving candidates."""
    require_host_integration_admin(current_user)

    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT setting_key, setting_value FROM family_settings "
            "WHERE family_id = ? AND setting_key IN (?, ?)",
            (current_user["family_id"], "ha_url", "ha_token"),
        )
        rows = await cursor.fetchall()
    settings = {row[0]: row[1] for row in rows}

    ha_url = body.ha_url if body and body.ha_url else settings.get("ha_url")
    candidate_token = body.ha_token if body and body.ha_token else None
    stored_token = settings.get("ha_token")
    ha_token = candidate_token or stored_token

    if not ha_url or not ha_token:
        return {"success": False, "message": "HA URL or token not configured"}

    try:
        ha_url = validate_ha_origin(ha_url, app_settings.ha_allowed_origins)
    except ValueError:
        return {"success": False, "message": "The saved Home Assistant origin is not allowed"}

    if candidate_token is None:
        ha_token = decrypt_value(ha_token)

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{ha_url}/api/",
                headers={"Authorization": f"Bearer {ha_token}"},
            )
            resp.raise_for_status()
    except Exception:
        return {"success": False, "message": "Home Assistant could not be reached with the saved settings"}

    return {"success": True, "message": "Connected to Home Assistant"}
