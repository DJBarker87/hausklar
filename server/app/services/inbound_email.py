"""Signed inbound email capture for the family document inbox."""

import asyncio
import ipaddress
import json
import logging
import re
import socket
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parseaddr
from html.parser import HTMLParser
from io import BytesIO
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx
import resend
from pypdf import PdfReader

from app.config import settings
from app.database import standalone_db
from app.middleware.rate_limit import reserve_persistent_attempts
from app.models.document import CaptureSuggestionCreate
from app.services.documents import (
    ALLOWED_MEDIA_TYPES,
    DocumentStorageError,
    family_document_storage_bytes,
    remove_new_upload,
    safe_filename,
    store_bytes,
)
from app.services.hermes import extract_capture_suggestions
from app.services.ai_consent import user_has_current_ai_consent

logger = logging.getLogger(__name__)

MEDIA_BY_EXTENSION = {
    ".heic": "image/heic",
    ".heif": "image/heif",
    ".jpeg": "image/jpeg",
    ".jpg": "image/jpeg",
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".tif": "image/tiff",
    ".tiff": "image/tiff",
    ".txt": "text/plain",
}
RESEND_ATTACHMENT_HOSTS = {"inbound-cdn.resend.com"}
INBOUND_EMAIL_LEASE_SECONDS = 10 * 60
INLINE_IMAGE_MIN_CAPTURE_BYTES = 32 * 1024
CAMERA_IMAGE_FILENAME = re.compile(
    r"^(?:dsc|img|image|photo|pxl)[ _-]?\d+",
    re.IGNORECASE,
)


class InboundEmailLeaseLost(RuntimeError):
    """Raised when a newer retry owns the provider message."""


@dataclass(frozen=True)
class _PreparedDocument:
    document_id: str
    title: str
    filename: str
    media_type: str
    storage_key: str
    file_size: int
    sha256: str
    category: str
    category_confidence: float
    document_date: str
    document_date_confidence: float
    page_count: int
    extracted_text: str | None
    notes: str
    processor: str
    suggestions: list[CaptureSuggestionCreate]


class _HTMLTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self.ignored_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in {"script", "style"}:
            self.ignored_depth += 1
        elif tag in {"br", "p", "div", "li", "tr"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style"} and self.ignored_depth:
            self.ignored_depth -= 1
        elif tag in {"p", "div", "li", "tr"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self.ignored_depth:
            self.parts.append(data)


def _plain_html(value: str | None) -> str:
    if not value:
        return ""
    parser = _HTMLTextExtractor()
    parser.feed(value)
    return "\n".join(line.strip() for line in "".join(parser.parts).splitlines() if line.strip())


def _normalise_address(value: str) -> str:
    parsed = parseaddr(value)[1] or value
    return parsed.strip().lower()


def _email_authentication_failed(email: dict) -> bool:
    """Reject an explicitly failed DMARC result from the receiving provider."""
    headers = email.get("headers") or {}
    values: list[str] = []
    if isinstance(headers, dict):
        values = [
            str(value)
            for key, value in headers.items()
            if str(key).lower() in {"authentication-results", "arc-authentication-results"}
        ]
    elif isinstance(headers, list):
        for item in headers:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or item.get("key") or "").lower()
            if name in {"authentication-results", "arc-authentication-results"}:
                values.append(str(item.get("value") or ""))
    result = " ".join(values).lower()
    return bool(re.search(r"\bdmarc\s*=\s*(?:fail|temperror|permerror)\b", result))


def _media_type(filename: str, content_type: str | None) -> str | None:
    supplied = (content_type or "").split(";", 1)[0].strip().lower()
    if supplied in ALLOWED_MEDIA_TYPES:
        return supplied
    return MEDIA_BY_EXTENSION.get(Path(filename).suffix.lower())


def _attachment_size(attachment: dict) -> int:
    try:
        return max(int(attachment.get("size") or 0), 0)
    except (TypeError, ValueError):
        return 0


def _supported_attachments(email: dict, *, body_text: str) -> list[tuple[dict, str, str]]:
    """Keep real attachments, including photos that mail clients mark as inline.

    HTML mail commonly includes tiny inline logos and tracking pixels, while Apple Mail
    also labels user-attached photos as ``inline``. Retain substantial or recognisably
    camera-named inline images, but keep decorative assets out of the document inbox.
    If an inline image is the message's only content, preserve the largest one rather
    than dropping the email entirely.
    """
    supported: list[tuple[dict, str, str]] = []
    inline_images: list[tuple[dict, str, str]] = []
    for attachment in (email.get("attachments") or [])[:10]:
        if not isinstance(attachment, dict):
            continue
        filename = safe_filename(attachment.get("filename"))
        media_type = _media_type(filename, attachment.get("content_type"))
        if media_type is None:
            continue
        disposition = str(attachment.get("content_disposition") or "").lower()
        if disposition != "inline" or not media_type.startswith("image/"):
            supported.append((attachment, filename, media_type))
            continue

        candidate = (attachment, filename, media_type)
        inline_images.append(candidate)
        if (
            _attachment_size(attachment) >= INLINE_IMAGE_MIN_CAPTURE_BYTES
            or media_type in {"image/heic", "image/heif"}
            or CAMERA_IMAGE_FILENAME.match(filename)
        ):
            supported.append(candidate)

    if not supported and not body_text and inline_images:
        supported.append(max(inline_images, key=lambda item: _attachment_size(item[0])))
    return supported


def _extract_text(data: bytes, media_type: str) -> tuple[str, int]:
    if media_type == "text/plain":
        return data.decode("utf-8", errors="replace")[:150_000], 1
    if media_type != "application/pdf":
        return "", 1
    try:
        reader = PdfReader(BytesIO(data))
        pages = [page.extract_text() or "" for page in reader.pages[:100]]
        return "\n\n".join(pages)[:150_000], max(len(reader.pages), 1)
    except Exception as exc:
        logger.info("Inbound PDF text extraction unavailable: %s", type(exc).__name__)
        return "", 1


def _category(subject: str, text: str) -> str:
    value = f"{subject} {text[:10_000]}".lower()
    if any(word in value for word in ("nursery", "preschool", "childcare")):
        return "childcare"
    if any(word in value for word in ("school", "teacher", "class", "pupil")):
        return "school"
    if any(word in value for word in ("nhs", "hospital", "doctor", "medical", "clinic")):
        return "medical"
    if any(word in value for word in ("invoice", "bill", "payment", "receipt")):
        return "finance"
    return "other"


async def verify_resend_webhook(payload: str, headers: dict[str, str]) -> None:
    await asyncio.to_thread(
        resend.Webhooks.verify,
        {
            "payload": payload,
            "headers": headers,
            "webhook_secret": settings.resend_webhook_secret,
        },
    )


async def _retrieve_email(email_id: str) -> dict:
    resend.api_key = settings.resend_api_key
    return await asyncio.to_thread(resend.EmailsReceiving.get, email_id)


async def _attachment_details(email_id: str, attachment_id: str) -> dict:
    resend.api_key = settings.resend_api_key
    return await asyncio.to_thread(
        resend.EmailsReceiving.Attachments.get,
        email_id,
        attachment_id,
    )


async def _validate_attachment_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise DocumentStorageError("Email attachment URL is not secure")
    if parsed.hostname.lower() not in RESEND_ATTACHMENT_HOSTS:
        raise DocumentStorageError("Email attachment host is not approved")
    try:
        addresses = await asyncio.to_thread(
            socket.getaddrinfo,
            parsed.hostname,
            parsed.port or 443,
            type=socket.SOCK_STREAM,
        )
    except socket.gaierror as exc:
        raise DocumentStorageError("Email attachment host could not be resolved") from exc
    if not addresses:
        raise DocumentStorageError("Email attachment host could not be resolved")
    for address in addresses:
        candidate = ipaddress.ip_address(address[4][0])
        if not candidate.is_global:
            raise DocumentStorageError("Email attachment URL is not public")


async def _download_attachment(url: str) -> bytes:
    maximum = settings.document_max_upload_bytes
    data = bytearray()
    current_url = url
    async with httpx.AsyncClient(timeout=30, follow_redirects=False) as client:
        for redirect_count in range(4):
            await _validate_attachment_url(current_url)
            async with client.stream("GET", current_url) as response:
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location or redirect_count == 3:
                        raise DocumentStorageError("Email attachment redirected too many times")
                    current_url = urljoin(current_url, location)
                    continue
                response.raise_for_status()
                for_header = response.headers.get("content-length")
                try:
                    declared_size = int(for_header) if for_header else None
                except ValueError as exc:
                    raise DocumentStorageError("Email attachment size is invalid") from exc
                if declared_size is not None and declared_size > maximum:
                    raise DocumentStorageError("Email attachment exceeds the upload limit")
                async for chunk in response.aiter_bytes():
                    data.extend(chunk)
                    if len(data) > maximum:
                        raise DocumentStorageError("Email attachment exceeds the upload limit")
                break
    return bytes(data)


async def _matching_inbox(db, recipients: list[str]):
    if not recipients:
        return None
    placeholders = ", ".join("?" for _ in recipients)
    cursor = await db.execute(
        f"""
        SELECT family_id, address
        FROM document_inbox_addresses
        WHERE LOWER(address) IN ({placeholders})
          AND enabled = 1 AND deleted_at IS NULL
        LIMIT 1
        """,
        recipients,
    )
    return await cursor.fetchone()


async def _insert_suggestions(db, suggestions, *, document_id: str, family_id: str, now: str):
    if not suggestions:
        return
    await db.executemany(
        """
        INSERT INTO capture_suggestions (
            id, document_id, kind, title, details, start_time, end_time,
            due_date, all_day, assigned_to, confidence, source_text, status,
            family_id, created_at, updated_at, created_by
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, 'pending', ?, ?, ?, ?)
        """,
        [
            (
                suggestion.id or str(uuid.uuid4()),
                document_id,
                suggestion.kind,
                suggestion.title,
                suggestion.details,
                suggestion.start_time,
                suggestion.end_time,
                suggestion.due_date,
                int(suggestion.all_day),
                suggestion.confidence,
                suggestion.source_text,
                family_id,
                now,
                now,
                None,
            )
            for suggestion in suggestions[:50]
        ],
    )


def _lease_expiry(now: datetime) -> str:
    return (now + timedelta(seconds=INBOUND_EMAIL_LEASE_SECONDS)).isoformat()


def _lease_is_current(value: str | None, now: datetime) -> bool:
    if not value:
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return False
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed > now


def _stored_document_ids(value: str | None) -> list[str]:
    try:
        decoded = json.loads(value or "[]")
    except (TypeError, json.JSONDecodeError):
        return []
    if not isinstance(decoded, list):
        return []
    return [item for item in decoded if isinstance(item, str)]


async def _claim_receipt(
    db,
    *,
    email_id: str,
    internet_message_id: object,
    sender: str,
    inbox_address: str,
    subject: str,
    family_id: str,
    sender_user_id: str,
) -> tuple[str | None, dict[str, object] | None]:
    """Claim new, failed, or expired work and fence every previous worker."""
    now_value = datetime.now(timezone.utc)
    now = now_value.isoformat()
    lease_token = uuid.uuid4().hex
    lease_expires_at = _lease_expiry(now_value)

    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT id, status, document_ids, lease_token, lease_expires_at, family_id "
            "FROM inbound_email_messages "
            "WHERE provider_message_id = ? AND deleted_at IS NULL",
            (email_id,),
        )
        existing = await cursor.fetchone()
        if existing:
            (
                _,
                status,
                document_ids,
                current_lease_token,
                current_expiry,
                existing_family_id,
            ) = existing
            if existing_family_id != family_id:
                await db.rollback()
                return None, {"status": "duplicate", "document_ids": []}
            if status in {"processed", "ignored"} or (
                status == "processing"
                and current_lease_token
                and _lease_is_current(current_expiry, now_value)
            ):
                await db.rollback()
                return None, {
                    "status": "duplicate",
                    "document_ids": _stored_document_ids(document_ids),
                }
            await db.execute(
                """
                UPDATE inbound_email_messages
                SET internet_message_id = ?, from_address = ?, to_address = ?,
                    subject = ?, status = 'processing', document_ids = NULL,
                    error = NULL, lease_token = ?, lease_expires_at = ?,
                    updated_at = ?, created_by = ?
                WHERE id = ?
                """,
                (
                    internet_message_id,
                    sender,
                    inbox_address,
                    subject,
                    lease_token,
                    lease_expires_at,
                    now,
                    sender_user_id,
                    existing[0],
                ),
            )
        else:
            await db.execute(
                """
                INSERT INTO inbound_email_messages (
                    id, provider_message_id, internet_message_id, from_address,
                    to_address, subject, status, lease_token, lease_expires_at,
                    family_id, created_at, updated_at, created_by
                ) VALUES (?, ?, ?, ?, ?, ?, 'processing', ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    email_id,
                    internet_message_id,
                    sender,
                    inbox_address,
                    subject,
                    lease_token,
                    lease_expires_at,
                    family_id,
                    now,
                    now,
                    sender_user_id,
                ),
            )

        await reserve_persistent_attempts(
            db,
            [
                (
                    f"document-upload:{family_id}",
                    settings.document_upload_rate_limit_requests,
                    3_600,
                )
            ],
            detail_prefix="Too many document uploads",
            manage_transaction=False,
        )
        await db.commit()
        return lease_token, None
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


async def _renew_lease(db, *, email_id: str, lease_token: str) -> None:
    now_value = datetime.now(timezone.utc)
    now = now_value.isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            """
            UPDATE inbound_email_messages
            SET lease_expires_at = ?, updated_at = ?
            WHERE provider_message_id = ? AND status = 'processing'
              AND lease_token = ? AND lease_expires_at > ? AND deleted_at IS NULL
            """,
            (_lease_expiry(now_value), now, email_id, lease_token, now),
        )
        if cursor.rowcount != 1:
            raise InboundEmailLeaseLost("Inbound email processing lease was lost")
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


async def _finish_ignored(db, *, email_id: str, lease_token: str, reason: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            """
            UPDATE inbound_email_messages
            SET status = 'ignored', error = ?, lease_token = NULL,
                lease_expires_at = NULL, updated_at = ?
            WHERE provider_message_id = ? AND status = 'processing'
              AND lease_token = ? AND lease_expires_at > ? AND deleted_at IS NULL
            """,
            (reason, now, email_id, lease_token, now),
        )
        if cursor.rowcount != 1:
            raise InboundEmailLeaseLost("Inbound email processing lease was lost")
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


async def _commit_documents(
    db,
    *,
    email_id: str,
    lease_token: str,
    family_id: str,
    sender_user_id: str,
    documents: list[_PreparedDocument],
) -> list[str]:
    """Apply the family quota and insert every document in one fenced transaction."""
    now_value = datetime.now(timezone.utc)
    now = now_value.isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        cursor = await db.execute(
            "SELECT lease_expires_at FROM inbound_email_messages "
            "WHERE provider_message_id = ? AND status = 'processing' "
            "AND lease_token = ? AND deleted_at IS NULL",
            (email_id, lease_token),
        )
        lease = await cursor.fetchone()
        if lease is None or not _lease_is_current(lease[0], now_value):
            raise InboundEmailLeaseLost("Inbound email processing lease was lost")

        existing_storage = await family_document_storage_bytes(
            db,
            family_id=family_id,
        )
        incoming_storage = sum(document.file_size for document in documents)
        if existing_storage + incoming_storage > settings.document_family_quota_bytes:
            raise DocumentStorageError("Family document storage quota exceeded")

        for document in documents:
            await db.execute(
                """
                INSERT INTO documents (
                    id, title, original_filename, media_type, storage_key, file_size,
                    sha256, source, category, category_confidence, status,
                    document_date, document_date_confidence, page_count,
                    extracted_text, notes, processor, family_id, created_at, updated_at,
                    created_by
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'share', ?, ?, 'inbox', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    document.document_id,
                    document.title,
                    document.filename,
                    document.media_type,
                    document.storage_key,
                    document.file_size,
                    document.sha256,
                    document.category,
                    document.category_confidence,
                    document.document_date,
                    document.document_date_confidence,
                    document.page_count,
                    document.extracted_text,
                    document.notes,
                    document.processor,
                    family_id,
                    now,
                    now,
                    sender_user_id,
                ),
            )
            await _insert_suggestions(
                db,
                document.suggestions,
                document_id=document.document_id,
                family_id=family_id,
                now=now,
            )

        document_ids = [document.document_id for document in documents]
        cursor = await db.execute(
            """
            UPDATE inbound_email_messages
            SET status = 'processed', document_ids = ?, error = NULL,
                lease_token = NULL, lease_expires_at = NULL, updated_at = ?
            WHERE provider_message_id = ? AND status = 'processing'
              AND lease_token = ? AND lease_expires_at > ? AND deleted_at IS NULL
            """,
            (json.dumps(document_ids), now, email_id, lease_token, now),
        )
        if cursor.rowcount != 1:
            raise InboundEmailLeaseLost("Inbound email processing lease was lost")
        await db.commit()
        return document_ids
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


async def _mark_failed_if_owned(
    db,
    *,
    email_id: str,
    lease_token: str,
    error: BaseException,
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    await db.execute("BEGIN IMMEDIATE")
    try:
        await db.execute(
            """
            UPDATE inbound_email_messages
            SET status = 'failed', error = ?, lease_token = NULL,
                lease_expires_at = NULL, updated_at = ?
            WHERE provider_message_id = ? AND status = 'processing'
              AND lease_token = ? AND deleted_at IS NULL
            """,
            (f"{type(error).__name__}: {str(error)[:400]}", now, email_id, lease_token),
        )
        await db.commit()
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise


async def process_received_email(payload: dict, db=None) -> dict[str, object]:
    """Validate routing and turn one Resend email into one or more inbox documents."""
    if db is None:
        # Keep slow provider/OCR/model work outside the four request-pool leases.
        async with standalone_db() as connection:
            return await process_received_email(payload, connection)

    email_id = str(payload.get("email_id") or "").strip()
    if not email_id:
        raise ValueError("Inbound email is missing email_id")

    recipients = [_normalise_address(value) for value in payload.get("to", []) if value]
    from app.services.finance.email_intake import (
        match_finance_recipient,
        process_finance_received_email,
    )

    finance_route, finance_alias = await match_finance_recipient(db, recipients)
    if finance_route == "active" and finance_alias is not None:
        return await process_finance_received_email(payload, alias=finance_alias, db=db)
    if finance_route != "none":
        return {
            "status": "ignored",
            "reason": f"{finance_route}_finance_recipient",
        }
    inbox = await _matching_inbox(db, recipients)
    if inbox is None:
        return {"status": "ignored", "reason": "unknown_recipient"}
    family_id, inbox_address = inbox[0], inbox[1]

    sender = _normalise_address(str(payload.get("from") or ""))
    cursor = await db.execute(
        "SELECT id FROM users WHERE family_id = ? AND LOWER(email) = ? AND deleted_at IS NULL",
        (family_id, sender),
    )
    sender_user = await cursor.fetchone()
    if sender_user is None:
        return {"status": "ignored", "reason": "sender_not_allowed"}

    subject = str(payload.get("subject") or "Forwarded email").strip()[:300]
    lease_token, duplicate = await _claim_receipt(
        db,
        email_id=email_id,
        internet_message_id=payload.get("message_id"),
        sender=sender,
        inbox_address=inbox_address,
        subject=subject,
        family_id=family_id,
        sender_user_id=sender_user[0],
    )
    if duplicate is not None:
        return duplicate
    if lease_token is None:  # pragma: no cover - protected by _claim_receipt's contract
        raise RuntimeError("Inbound email claim returned no lease")

    storage_keys: list[str] = []
    try:
        email = await _retrieve_email(email_id)
        await _renew_lease(db, email_id=email_id, lease_token=lease_token)
        if _email_authentication_failed(email):
            await _finish_ignored(
                db,
                email_id=email_id,
                lease_token=lease_token,
                reason="sender_authentication_failed",
            )
            return {"status": "ignored", "reason": "sender_authentication_failed"}
        body_text = str(email.get("text") or "").strip() or _plain_html(email.get("html"))
        candidates: list[tuple[str, str, bytes]] = []
        total_attachment_bytes = 0
        for attachment, filename, media_type in _supported_attachments(
            email,
            body_text=body_text,
        ):
            await _renew_lease(db, email_id=email_id, lease_token=lease_token)
            attachment_id = str(attachment.get("id") or "").strip()
            if not attachment_id:
                continue
            details = await _attachment_details(email_id, attachment_id)
            data = await _download_attachment(details["download_url"])
            await _renew_lease(db, email_id=email_id, lease_token=lease_token)
            total_attachment_bytes += len(data)
            if total_attachment_bytes > settings.document_max_upload_bytes * 2:
                raise DocumentStorageError("Combined email attachments exceed the upload limit")
            candidates.append((filename, media_type, data))

        if not candidates and body_text:
            filename = safe_filename(f"{subject}.txt")
            candidates.append((filename, "text/plain", body_text.encode("utf-8")))
        if not candidates:
            await _finish_ignored(
                db,
                email_id=email_id,
                lease_token=lease_token,
                reason="No supported content",
            )
            return {"status": "ignored", "reason": "no_supported_content"}

        documents: list[_PreparedDocument] = []
        for filename, media_type, data in candidates:
            await _renew_lease(db, email_id=email_id, lease_token=lease_token)
            document_id = str(uuid.uuid4())
            storage_key, stored_filename, file_size, sha256 = await store_bytes(
                data,
                filename=filename,
                media_type=media_type,
                family_id=family_id,
                document_id=document_id,
            )
            storage_keys.append(storage_key)
            await _renew_lease(db, email_id=email_id, lease_token=lease_token)
            extracted_text, page_count = await asyncio.to_thread(
                _extract_text,
                data,
                media_type,
            )
            context = "\n\n".join(value for value in (body_text, extracted_text) if value)
            suggestions: list[CaptureSuggestionCreate] = []
            processor = "fallback"
            if (
                settings.resend_inbound_use_hermes
                and context
                and await user_has_current_ai_consent(db, sender_user[0])
            ):
                hermes_result = await extract_capture_suggestions(
                    title=subject,
                    text=context,
                    people=[],
                )
                if hermes_result is not None:
                    suggestions = hermes_result
                    processor = "hermes"
                await _renew_lease(db, email_id=email_id, lease_token=lease_token)

            title = subject if len(candidates) == 1 else f"{subject} - {stored_filename}"
            notes = f"Forwarded by {sender}"
            if body_text and media_type != "text/plain":
                notes += f"\n\n{body_text[:9_900]}"
            inferred_category = _category(subject, context)
            documents.append(
                _PreparedDocument(
                    document_id=document_id,
                    title=title,
                    filename=stored_filename,
                    media_type=media_type,
                    storage_key=storage_key,
                    file_size=file_size,
                    sha256=sha256,
                    category=inferred_category,
                    category_confidence=0.92 if inferred_category != "other" else 0.25,
                    document_date=str(
                        email.get("created_at") or datetime.now(timezone.utc).isoformat()
                    )[:10],
                    # The received date is a useful fallback, not necessarily the
                    # date printed on the document, so it always needs review.
                    document_date_confidence=0.35,
                    page_count=page_count,
                    extracted_text=extracted_text or body_text or None,
                    notes=notes,
                    processor=processor,
                    suggestions=suggestions,
                )
            )

        document_ids = await _commit_documents(
            db,
            email_id=email_id,
            lease_token=lease_token,
            family_id=family_id,
            sender_user_id=sender_user[0],
            documents=documents,
        )
        return {"status": "processed", "document_ids": document_ids}
    except BaseException as exc:
        if db.in_transaction:
            await db.rollback()
        cleanup_results = await asyncio.gather(
            *(remove_new_upload(storage_key) for storage_key in storage_keys),
            return_exceptions=True,
        )
        for cleanup_error in cleanup_results:
            if isinstance(cleanup_error, BaseException):
                logger.warning(
                    "Could not remove failed inbound upload: %s",
                    type(cleanup_error).__name__,
                )
        if not isinstance(exc, InboundEmailLeaseLost):
            await _mark_failed_if_owned(
                db,
                email_id=email_id,
                lease_token=lease_token,
                error=exc,
            )
        raise
