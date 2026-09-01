"""Early request guards that run before FastAPI parses request bodies."""

from __future__ import annotations

from urllib.parse import urlsplit

from starlette.exceptions import HTTPException
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.config import settings
from app.services.finance.upload_limits import (
    MAX_STATEMENT_IMPORT_BYTES,
    MULTIPART_REQUEST_OVERHEAD_BYTES,
)

_UNSAFE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
_COOKIE_NAMES = (b"hausklar_access=", b"hausklar_refresh=")
_CSRF_EXEMPT_PATHS = {
    "/api/auth/login",
    "/api/auth/register",
    "/api/auth/forgot-password",
    "/api/auth/reset-password",
    "/api/auth/refresh",
    "/api/auth/web/login",
    "/api/inbound-email/resend",
}


class RequestBodyTooLarge(HTTPException):
    def __init__(self) -> None:
        super().__init__(status_code=413, detail="Request body is too large")


def _headers(scope: Scope) -> dict[bytes, bytes]:
    return {name.lower(): value for name, value in scope.get("headers", [])}


def _web_origin() -> bytes:
    parsed = urlsplit(settings.web_app_url.strip())
    return f"{parsed.scheme.lower()}://{parsed.netloc.lower()}".encode("ascii")


def _request_limit(path: str, method: str) -> int:
    if path == "/api/fitness/imports/fit" and method == "POST":
        return settings.fitness_fit_max_upload_bytes + 1_048_576
    if path == "/api/fitness/files/private" and method == "POST":
        return settings.fitness_photo_max_upload_bytes + 1_048_576
    if path == "/api/documents/" and method == "POST":
        return settings.document_max_upload_bytes + 1_048_576
    if path in {
        "/api/finance/imports/preview",
        "/api/finance/imports/confirm",
    } and method == "POST":
        return MAX_STATEMENT_IMPORT_BYTES + MULTIPART_REQUEST_OVERHEAD_BYTES
    if path == "/api/finance/purchases/evidence/upload" and method == "POST":
        return settings.document_max_upload_bytes + MULTIPART_REQUEST_OVERHEAD_BYTES
    if path in {"/api/artworks/", "/api/child-photos/"} and method == "POST":
        return settings.media_max_request_bytes
    if path.startswith("/api/family/members/") and path.endswith("/avatar") and method == "PUT":
        return settings.avatar_max_file_bytes + 65_536
    return settings.api_max_request_bytes


def _needs_origin_check(path: str, method: str, headers: dict[bytes, bytes]) -> bool:
    if method not in _UNSAFE_METHODS or not path.startswith("/api/"):
        return False
    if path in _CSRF_EXEMPT_PATHS:
        return False
    authorization = headers.get(b"authorization", b"").lstrip().lower()
    if authorization.startswith(b"bearer "):
        return False
    cookie = headers.get(b"cookie", b"")
    return any(name in cookie for name in _COOKIE_NAMES)


class RequestSecurityMiddleware:
    """Reject oversized bodies and cross-origin cookie mutations early."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "")
        method = scope.get("method", "GET").upper()
        headers = _headers(scope)

        if _needs_origin_check(path, method, headers):
            origin = headers.get(b"origin", b"").lower()
            if origin != _web_origin():
                await JSONResponse(
                    {"detail": "Cross-origin browser request rejected"},
                    status_code=403,
                )(scope, receive, send)
                return

        limit = _request_limit(path, method)
        raw_content_length = headers.get(b"content-length")
        if raw_content_length:
            try:
                content_length = int(raw_content_length)
            except ValueError:
                await JSONResponse(
                    {"detail": "Invalid Content-Length"},
                    status_code=400,
                )(scope, receive, send)
                return
            if content_length < 0:
                await JSONResponse(
                    {"detail": "Invalid Content-Length"},
                    status_code=400,
                )(scope, receive, send)
                return
            if content_length > limit:
                await JSONResponse(
                    {"detail": "Request body is too large"},
                    status_code=413,
                )(scope, receive, send)
                return

        received = 0

        async def limited_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > limit:
                    raise RequestBodyTooLarge()
            return message

        await self.app(scope, limited_receive, send)
