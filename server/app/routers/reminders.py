import json
import uuid
from datetime import datetime, timezone
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, HTTPException

from app.auth import get_current_user
from app.config import settings
from app.database import database_lease, get_db
from app.models.reminder import (
    APNSDeviceRegistrationCreate,
    APNSDeviceStatus,
    PushStatus,
    PushSubscriptionCreate,
    ReminderPreferences,
    ReminderPreviewItem,
)
from app.services.apns import (
    APNSDeliveryError,
    apns_configured,
    device_token_hash,
    send_apns,
)
from app.services.record_history import save_history
from app.services.reminders import _send, endpoint_hash, reminder_preview
from app.services.calendar_sync import CalendarSyncError, validate_public_https_url
from app.utils.encryption import decrypt_value, encrypt_value

router = APIRouter()


async def _preferences(db, user: dict):
    cursor = await db.execute("SELECT * FROM reminder_preferences WHERE user_id=? AND family_id=? AND deleted_at IS NULL", (user["id"], user["family_id"]))
    row = await cursor.fetchone()
    if row:
        return dict(row)
    now = datetime.now(timezone.utc).isoformat()
    identifier = str(uuid.uuid4())
    # Preferences are lazily created and the Account screen intentionally loads
    # preferences and preview together. Make that first read idempotent across
    # concurrent SQLite connections instead of racing the partial unique index.
    await db.execute(
        """INSERT INTO reminder_preferences
           (id,user_id,family_id,created_at,updated_at,created_by)
           VALUES (?,?,?,?,?,?)
           ON CONFLICT(user_id) WHERE deleted_at IS NULL DO NOTHING""",
        (identifier, user["id"], user["family_id"], now, now, user["id"]),
    )
    await db.commit()
    cursor = await db.execute(
        "SELECT * FROM reminder_preferences WHERE user_id=? AND family_id=? AND deleted_at IS NULL",
        (user["id"], user["family_id"]),
    )
    return dict(await cursor.fetchone())


def _response(row: dict) -> ReminderPreferences:
    for key in ("event_reminders_enabled", "task_reminders_enabled", "morning_summary_enabled", "evening_summary_enabled", "privacy_mode"):
        row[key] = bool(row[key])
    return ReminderPreferences(**row)


@router.get("/preferences", response_model=ReminderPreferences)
async def get_preferences(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    return _response(await _preferences(db, current_user))


@router.put("/preferences", response_model=ReminderPreferences)
async def update_preferences(body: ReminderPreferences, current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    existing = await _preferences(db, current_user)
    await save_history(db, "reminder_preferences", existing["id"], current_user["id"], family_id=current_user["family_id"])
    data = body.model_dump()
    for key in ("event_reminders_enabled", "task_reminders_enabled", "morning_summary_enabled", "evening_summary_enabled", "privacy_mode"):
        data[key] = int(data[key])
    data["updated_at"] = datetime.now(timezone.utc).isoformat()
    await db.execute(f"UPDATE reminder_preferences SET {', '.join(f'{key}=?' for key in data)} WHERE id=?", (*data.values(), existing["id"]))
    await db.commit()
    return body


@router.get("/preview", response_model=list[ReminderPreviewItem])
async def preview(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    preferences = await _preferences(db, current_user)
    return await reminder_preview(db, current_user, preferences)


@router.get("/push", response_model=PushStatus)
async def push_status(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    cursor = await db.execute("SELECT 1 FROM web_push_subscriptions WHERE user_id=? AND deleted_at IS NULL LIMIT 1", (current_user["id"],))
    configured = bool(settings.web_push_vapid_public_key and settings.web_push_vapid_private_key)
    return PushStatus(configured=configured, subscribed=bool(await cursor.fetchone()), public_key=settings.web_push_vapid_public_key if configured else None)


@router.post("/push/subscriptions", response_model=PushStatus)
async def subscribe(body: PushSubscriptionCreate, current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    parsed = urlparse(body.endpoint)
    if parsed.scheme != "https" or not parsed.hostname:
        raise HTTPException(status_code=422, detail="Push endpoint must use HTTPS")
    try:
        await validate_public_https_url(body.endpoint)
    except CalendarSyncError as exc:
        raise HTTPException(status_code=422, detail="Push endpoint is not public") from exc
    now = datetime.now(timezone.utc).isoformat()
    hashed = endpoint_hash(body.endpoint)
    encrypted = encrypt_value(json.dumps({"endpoint": body.endpoint, "keys": {"p256dh": body.p256dh, "auth": body.auth}}, separators=(",", ":")))
    cursor = await db.execute("SELECT id FROM web_push_subscriptions WHERE endpoint_hash=? AND deleted_at IS NULL", (hashed,))
    existing = await cursor.fetchone()
    if existing:
        await db.execute("UPDATE web_push_subscriptions SET user_id=?,family_id=?,encrypted_subscription=?,updated_at=? WHERE id=?", (current_user["id"], current_user["family_id"], encrypted, now, existing["id"]))
    else:
        await db.execute("""INSERT INTO web_push_subscriptions (id,user_id,family_id,endpoint_hash,encrypted_subscription,created_at,updated_at,created_by) VALUES (?,?,?,?,?,?,?,?)""", (str(uuid.uuid4()), current_user["id"], current_user["family_id"], hashed, encrypted, now, now, current_user["id"]))
    await db.commit()
    return PushStatus(configured=True, subscribed=True, public_key=settings.web_push_vapid_public_key)


@router.delete("/push/subscriptions/{endpoint_digest}", status_code=204)
async def unsubscribe(endpoint_digest: str, current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("UPDATE web_push_subscriptions SET deleted_at=?,updated_at=? WHERE endpoint_hash=? AND user_id=?", (now, now, endpoint_digest, current_user["id"]))
    await db.commit()


@router.delete("/push/subscriptions", status_code=204)
async def unsubscribe_all(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("UPDATE web_push_subscriptions SET deleted_at=?,updated_at=? WHERE user_id=? AND deleted_at IS NULL", (now, now, current_user["id"]))
    await db.commit()


@router.get("/apns", response_model=APNSDeviceStatus)
async def apns_status(
    current_user: dict = Depends(get_current_user), db=Depends(get_db)
):
    row = await (
        await db.execute(
            "SELECT token_hash FROM apns_device_registrations "
            "WHERE user_id=? AND deleted_at IS NULL ORDER BY last_registered_at DESC LIMIT 1",
            (current_user["id"],),
        )
    ).fetchone()
    return APNSDeviceStatus(
        configured=apns_configured(),
        registered=row is not None,
        token_digest=row["token_hash"] if row is not None else None,
    )


@router.post("/apns/devices", response_model=APNSDeviceStatus)
async def register_apns_device(
    body: APNSDeviceRegistrationCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    now = datetime.now(timezone.utc).isoformat()
    bundle_id = settings.apns_bundle_id.strip() or "com.example.hausklar"
    token_digest = device_token_hash(body.device_token, body.environment, bundle_id)
    encrypted_token = encrypt_value(body.device_token)
    await db.execute(
        """INSERT INTO apns_device_registrations
           (id,user_id,family_id,token_hash,encrypted_device_token,environment,
            bundle_id,app_version,last_registered_at,created_at,updated_at,created_by)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(token_hash) WHERE deleted_at IS NULL DO UPDATE SET
             user_id=excluded.user_id,
             family_id=excluded.family_id,
             encrypted_device_token=excluded.encrypted_device_token,
             environment=excluded.environment,
             bundle_id=excluded.bundle_id,
             app_version=excluded.app_version,
             last_registered_at=excluded.last_registered_at,
             last_error_code=NULL,
             last_error_at=NULL,
             updated_at=excluded.updated_at,
             created_by=excluded.created_by""",
        (
            str(uuid.uuid4()),
            current_user["id"],
            current_user["family_id"],
            token_digest,
            encrypted_token,
            body.environment,
            bundle_id,
            body.app_version,
            now,
            now,
            now,
            current_user["id"],
        ),
    )
    await db.commit()
    return APNSDeviceStatus(
        configured=apns_configured(), registered=True, token_digest=token_digest
    )


@router.delete("/apns/devices/{token_digest}", status_code=204)
async def unregister_apns_device(
    token_digest: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if len(token_digest) != 64 or any(character not in "0123456789abcdef" for character in token_digest):
        raise HTTPException(status_code=422, detail="Device token digest is invalid")
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE apns_device_registrations SET deleted_at=?,updated_at=? "
        "WHERE token_hash=? AND user_id=? AND deleted_at IS NULL",
        (now, now, token_digest, current_user["id"]),
    )
    await db.commit()


@router.delete("/apns/devices", status_code=204)
async def unregister_all_apns_devices(
    current_user: dict = Depends(get_current_user), db=Depends(get_db)
):
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE apns_device_registrations SET deleted_at=?,updated_at=? "
        "WHERE user_id=? AND deleted_at IS NULL",
        (now, now, current_user["id"]),
    )
    await db.commit()


@router.post("/apns/test")
async def send_test_apns_reminder(current_user: dict = Depends(get_current_user)):
    if not apns_configured():
        raise HTTPException(status_code=409, detail="iPhone push is not configured")
    async with database_lease() as db:
        rows = await (
            await db.execute(
                "SELECT id,encrypted_device_token,environment FROM apns_device_registrations "
                "WHERE user_id=? AND deleted_at IS NULL",
                (current_user["id"],),
            )
        ).fetchall()
    if not rows:
        raise HTTPException(status_code=409, detail="Enable iPhone notifications first")
    payload = {
        "title": "HausKlar reminders are ready",
        "body": "You’ll get useful nudges based on your settings.",
        "url": "/?view=today",
        "tag": "hausklar-test",
    }
    delivered = 0
    for row in rows:
        try:
            await send_apns(
                device_token=decrypt_value(row["encrypted_device_token"]),
                environment=row["environment"],
                payload=payload,
                collapse_key=f"test:{current_user['id']}",
            )
            delivered += 1
        except APNSDeliveryError as exc:
            if exc.invalidates_device:
                now = datetime.now(timezone.utc).isoformat()
                async with database_lease() as db:
                    await db.execute(
                        "UPDATE apns_device_registrations SET deleted_at=?,updated_at=?,"
                        "last_error_code=?,last_error_at=? WHERE id=?",
                        (now, now, exc.reason, now, row["id"]),
                    )
                    await db.commit()
        except Exception:
            continue
    if not delivered:
        raise HTTPException(status_code=502, detail="Test reminder could not be delivered")
    return {"delivered": delivered}


@router.post("/test")
async def send_test_reminder(current_user: dict = Depends(get_current_user)):
    async with database_lease() as db:
        cursor = await db.execute(
            "SELECT encrypted_subscription FROM web_push_subscriptions WHERE user_id=? AND deleted_at IS NULL",
            (current_user["id"],),
        )
        subscriptions = [json.loads(decrypt_value(row["encrypted_subscription"])) for row in await cursor.fetchall()]
    if not subscriptions:
        raise HTTPException(status_code=409, detail="Enable browser reminders first")
    payload = {"title": "HausKlar reminders are ready", "body": "You’ll get useful nudges based on your settings.", "url": "/?view=today", "tag": "hausklar-test"}
    delivered = 0
    for subscription in subscriptions:
        try:
            await _send(subscription, payload)
            delivered += 1
        except Exception:
            continue
    if not delivered:
        raise HTTPException(status_code=502, detail="Test reminder could not be delivered")
    return {"delivered": delivered}
