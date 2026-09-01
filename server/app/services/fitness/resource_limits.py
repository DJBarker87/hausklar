"""Durable Fitness upload limits and atomic private-storage quotas."""

from __future__ import annotations

from contextlib import contextmanager
from threading import Lock

from fastapi import HTTPException, status

from app.config import settings
from app.middleware.rate_limit import reserve_persistent_attempts


_process_lock = Lock()
_active_uploads: dict[str, int] = {}


async def reserve_fitness_upload(db, *, user: dict) -> None:
    """Reserve durable per-owner and per-family upload budget."""
    window = settings.fitness_upload_rate_limit_window_seconds
    await reserve_persistent_attempts(
        db,
        [
            (
                f"fitness:upload:family:{user['family_id']}",
                settings.fitness_family_upload_rate_limit_requests,
                window,
            ),
            (
                f"fitness:upload:owner:{user['family_id']}:{user['id']}",
                settings.fitness_upload_rate_limit_requests,
                window,
            ),
        ],
        detail_prefix="Too many Fitness uploads",
    )


@contextmanager
def fitness_upload_slot(*, user: dict):
    """Bound simultaneous file reads before they reach SQLite quota checks."""
    family_key = f"family:{user['family_id']}"
    owner_key = f"owner:{user['family_id']}:{user['id']}"
    with _process_lock:
        family_active = _active_uploads.get(family_key, 0)
        owner_active = _active_uploads.get(owner_key, 0)
        if (
            family_active >= settings.fitness_family_concurrent_uploads
            or owner_active >= settings.fitness_owner_concurrent_uploads
        ):
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Another Fitness upload is still finishing. Try again in a moment.",
                headers={"Retry-After": "1"},
            )
        _active_uploads[family_key] = family_active + 1
        _active_uploads[owner_key] = owner_active + 1
    try:
        yield
    finally:
        with _process_lock:
            for key in (family_key, owner_key):
                remaining = _active_uploads.get(key, 0) - 1
                if remaining > 0:
                    _active_uploads[key] = remaining
                else:
                    _active_uploads.pop(key, None)


async def ensure_fitness_storage_capacity(
    db,
    *,
    user: dict,
    incoming_bytes: int,
) -> None:
    """Check both quotas while the caller owns an IMMEDIATE transaction."""
    if not db.in_transaction:
        raise RuntimeError("Fitness storage quota checks require a write transaction")
    if incoming_bytes < 0:
        raise ValueError("Incoming Fitness storage must be non-negative")
    durable_filter = (
        "deleted_at IS NULL AND storage_class IN ('source_required','private_required') "
        "AND state IN ('staged','ready')"
    )
    owner_row = await (
        await db.execute(
            "SELECT COALESCE(SUM(byte_size), 0) FROM health_file_assets "
            f"WHERE family_id = ? AND owner_user_id = ? AND {durable_filter}",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    family_row = await (
        await db.execute(
            "SELECT COALESCE(SUM(byte_size), 0) FROM health_file_assets "
            f"WHERE family_id = ? AND {durable_filter}",
            (user["family_id"],),
        )
    ).fetchone()
    if int(owner_row[0] or 0) + incoming_bytes > settings.fitness_owner_storage_quota_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail="Your Fitness storage is full",
        )
    if int(family_row[0] or 0) + incoming_bytes > settings.fitness_family_storage_quota_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail="Family Fitness storage is full",
        )


def reset_fitness_upload_slots() -> None:
    """Clear process-local counters for isolated tests."""
    with _process_lock:
        _active_uploads.clear()
