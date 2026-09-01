"""Idempotent replay for authenticated client JSON mutations."""

from __future__ import annotations

import asyncio
import hashlib
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse, Response
from fastapi.security import HTTPAuthorizationCredentials
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint

from app.auth import get_authenticated_user
from app.database import database_lease


OPERATION_HEADER = "X-HausKlar-Operation-ID"
MAX_CAPTURE_BYTES = 2 * 1024 * 1024
RETENTION_DAYS = 120
MUTATION_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


def _request_path(request: Request) -> str:
    query = request.url.query
    return request.url.path + (f"?{query}" if query else "")


def _request_hash(method: str, path: str, body: bytes) -> str:
    digest = hashlib.sha256()
    digest.update(method.encode("ascii"))
    digest.update(b"\0")
    digest.update(path.encode("utf-8"))
    digest.update(b"\0")
    digest.update(body)
    return digest.hexdigest()


def _credentials(request: Request) -> HTTPAuthorizationCredentials | None:
    value = request.headers.get("Authorization", "")
    scheme, separator, token = value.partition(" ")
    if separator and scheme.lower() == "bearer" and token:
        return HTTPAuthorizationCredentials(scheme=scheme, credentials=token)
    return None


def _http_error(exc: HTTPException) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
        headers=exc.headers,
    )


class IdempotencyMiddleware(BaseHTTPMiddleware):
    """Return a stored response when the same authenticated operation is retried."""

    def __init__(self, app) -> None:
        super().__init__(app)
        self._locks: dict[str, asyncio.Lock] = {}
        self._locks_guard = asyncio.Lock()

    async def _lock_for(self, key: str) -> asyncio.Lock:
        async with self._locks_guard:
            return self._locks.setdefault(key, asyncio.Lock())

    async def _release_lock(self, key: str, lock: asyncio.Lock) -> None:
        async with self._locks_guard:
            if not lock.locked() and self._locks.get(key) is lock:
                self._locks.pop(key, None)

    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        operation_id = request.headers.get(OPERATION_HEADER)
        if (
            request.method not in MUTATION_METHODS
            or not request.url.path.startswith("/api/")
            or not operation_id
        ):
            return await call_next(request)

        try:
            parsed_operation_id = str(uuid.UUID(operation_id))
        except (ValueError, AttributeError):
            return JSONResponse(status_code=400, content={"detail": "Invalid operation ID"})

        content_type = request.headers.get("content-type", "")
        if request.method != "DELETE" and "application/json" not in content_type.lower():
            return await call_next(request)

        body = await request.body()
        if len(body) > MAX_CAPTURE_BYTES:
            return await call_next(request)

        try:
            user = await get_authenticated_user(request, _credentials(request))
        except HTTPException as exc:
            return _http_error(exc)
        if bool(user.get("must_change_password")):
            return JSONResponse(status_code=403, content={"detail": "Password change required"})

        user_id = str(user["id"])
        path = _request_path(request)
        fingerprint = _request_hash(request.method, path, body)
        lock_key = f"{user_id}\0{parsed_operation_id}"
        lock = await self._lock_for(lock_key)
        try:
            async with lock:
                now = datetime.now(timezone.utc)
                now_string = now.isoformat()
                async with database_lease() as db:
                    cursor = await db.execute(
                        """
                        SELECT method, request_path, request_hash, status_code,
                               response_body, response_content_type
                        FROM idempotency_records
                        WHERE owner_user_id = ? AND operation_id = ? AND expires_at > ?
                        """,
                        (user_id, parsed_operation_id, now_string),
                    )
                    existing = await cursor.fetchone()

                if existing is not None:
                    if (
                        existing["method"] != request.method
                        or existing["request_path"] != path
                        or existing["request_hash"] != fingerprint
                    ):
                        return JSONResponse(
                            status_code=409,
                            content={"detail": "Operation ID was already used for a different request"},
                        )
                    headers = {"X-HausKlar-Idempotent-Replay": "true"}
                    if existing["response_content_type"]:
                        headers["Content-Type"] = existing["response_content_type"]
                    return Response(
                        content=bytes(existing["response_body"]),
                        status_code=existing["status_code"],
                        headers=headers,
                    )

                response = await call_next(request)
                response_body = b"".join([chunk async for chunk in response.body_iterator])
                response_headers = dict(response.headers)
                rebuilt = Response(
                    content=response_body,
                    status_code=response.status_code,
                    headers=response_headers,
                    background=response.background,
                )

                if 200 <= response.status_code < 400 and len(response_body) <= MAX_CAPTURE_BYTES:
                    expires_at = (now + timedelta(days=RETENTION_DAYS)).isoformat()
                    record_id = hashlib.sha256(lock_key.encode("utf-8")).hexdigest()
                    async with database_lease() as db:
                        await db.execute(
                            """
                            INSERT OR REPLACE INTO idempotency_records (
                                id, operation_id, owner_user_id, family_id, method,
                                request_path, request_hash, status_code, response_body,
                                response_content_type, created_at, expires_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            (
                                record_id,
                                parsed_operation_id,
                                user_id,
                                user.get("family_id"),
                                request.method,
                                path,
                                fingerprint,
                                response.status_code,
                                response_body,
                                response.headers.get("content-type"),
                                now_string,
                                expires_at,
                            ),
                        )
                        await db.commit()
                return rebuilt
        finally:
            await self._release_lock(lock_key, lock)


async def cleanup_expired_idempotency_records(db, *, now: datetime | None = None) -> int:
    """Delete expired replay-cache rows outside the user mutation path."""
    cutoff = (now or datetime.now(timezone.utc)).isoformat()
    cursor = await db.execute(
        "DELETE FROM idempotency_records WHERE expires_at <= ?",
        (cutoff,),
    )
    return max(0, cursor.rowcount)
