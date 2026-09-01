"""Durable rate and process-concurrency limits for costly Finance operations."""

from contextlib import contextmanager
from threading import Lock
from typing import Literal

from fastapi import HTTPException, status

from app.config import settings
from app.middleware.rate_limit import reserve_persistent_attempts

FinanceResourceKind = Literal["ai", "capture", "provider", "upload", "export"]

_process_lock = Lock()
_active_processes: dict[str, int] = {}


def _user_limit(kind: FinanceResourceKind) -> int:
    return {
        "ai": settings.finance_ai_rate_limit_requests,
        "capture": settings.finance_capture_rate_limit_requests,
        "provider": settings.finance_provider_rate_limit_requests,
        "upload": settings.finance_upload_rate_limit_requests,
        "export": settings.finance_export_rate_limit_requests,
    }[kind]


def _detail(kind: FinanceResourceKind) -> str:
    return {
        "ai": "Too many Finance coach requests",
        "capture": "Too many Finance capture requests",
        "provider": "Too many Finance bank requests",
        "upload": "Too many Finance imports or evidence uploads",
        "export": "Too many Finance export requests",
    }[kind]


async def reserve_finance_resource(
    db,
    *,
    user: dict,
    kind: FinanceResourceKind,
    manage_transaction: bool = True,
) -> None:
    """Reserve both an adult-specific bucket and a shared family budget."""
    window = settings.finance_rate_limit_window_seconds
    await reserve_persistent_attempts(
        db,
        [
            (
                f"finance:family:{user['family_id']}",
                settings.finance_family_rate_limit_requests,
                window,
            ),
            (
                f"finance:{kind}:user:{user['family_id']}:{user['id'] or 'household'}",
                _user_limit(kind),
                window,
            ),
        ],
        detail_prefix=_detail(kind),
        manage_transaction=manage_transaction,
    )


@contextmanager
def finance_process_slot(*, user: dict, kind: FinanceResourceKind):
    """Fail fast when costly work is already consuming this API process.

    The production deployment runs one uvicorn process. Durable rate counters
    bound longer windows; this deliberately small in-process guard closes the
    burst case where every request reserves budget before any request finishes.
    """
    family_key = f"family:{user['family_id']}"
    adult_kind_key = f"adult-kind:{user['family_id']}:{user['id']}:{kind}"
    with _process_lock:
        family_active = _active_processes.get(family_key, 0)
        adult_kind_active = _active_processes.get(adult_kind_key, 0)
        if (
            family_active >= settings.finance_family_concurrent_requests
            or adult_kind_active
            >= settings.finance_adult_concurrent_requests_per_kind
        ):
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=f"{_detail(kind)}. Another costly Finance request is still running.",
                headers={"Retry-After": "1"},
            )
        _active_processes[family_key] = family_active + 1
        _active_processes[adult_kind_key] = adult_kind_active + 1
    try:
        yield
    finally:
        with _process_lock:
            for key in (family_key, adult_kind_key):
                remaining = _active_processes.get(key, 0) - 1
                if remaining > 0:
                    _active_processes[key] = remaining
                else:
                    _active_processes.pop(key, None)


def reset_finance_process_slots() -> None:
    """Clear process-local slots for isolated tests."""
    with _process_lock:
        _active_processes.clear()
