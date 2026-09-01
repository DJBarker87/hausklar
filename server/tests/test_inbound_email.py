import asyncio
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import AsyncMock

import aiosqlite
import pytest
from fastapi import HTTPException

from app.services import inbound_email as inbound_email_service
from app.config import settings
from app.services.documents import DocumentStorageError
from app.services.inbound_email import (
    InboundEmailLeaseLost,
    _validate_attachment_url,
    process_received_email,
)


@pytest.fixture(autouse=True)
def inbound_settings(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "document_storage_path", str(tmp_path / "documents"))
    monkeypatch.setattr(settings, "document_max_upload_bytes", 2 * 1024 * 1024)
    monkeypatch.setattr(settings, "document_family_quota_bytes", 20 * 1024 * 1024)
    monkeypatch.setattr(settings, "document_upload_rate_limit_requests", 30)
    monkeypatch.setattr(settings, "resend_api_key", "re_test")
    monkeypatch.setattr(settings, "resend_webhook_secret", "whsec_test-secret-+000000000051234567890")  # gitleaks:allow
    monkeypatch.setattr(settings, "resend_inbound_domain", "inbox.hausklar.example.invalid")
    monkeypatch.setattr(settings, "resend_inbound_address", "")
    monkeypatch.setattr(settings, "resend_inbound_use_hermes", False)


async def _inbox_address(client, headers) -> str:
    response = await client.get("/api/documents/email-address", headers=headers)
    assert response.status_code == 200, response.text
    return response.json()["address"]


async def test_family_email_address_is_private_and_stable(client, adult_a_headers, monkeypatch):
    monkeypatch.setattr(settings, "resend_inbound_domain", "")
    unavailable = await client.get("/api/documents/email-address", headers=adult_a_headers)
    assert unavailable.json() == {"configured": False, "address": None}

    monkeypatch.setattr(settings, "resend_inbound_domain", "inbox.hausklar.example.invalid")
    first = await client.get("/api/documents/email-address", headers=adult_a_headers)
    second = await client.get("/api/documents/email-address", headers=adult_a_headers)
    assert first.json()["configured"] is True
    assert first.json()["address"] == second.json()["address"]
    assert first.json()["address"].endswith("@inbox.hausklar.example.invalid")
    assert "dom" not in first.json()["address"]


async def test_configured_production_address_retires_previous_aliases(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    old_address = await _inbox_address(client, adult_a_headers)
    preferred = "family@inbox.hausklar.example.invalid"
    monkeypatch.setattr(settings, "production_family_id", adult_a_user["family_id"])
    monkeypatch.setattr(settings, "resend_inbound_address", preferred)

    response = await client.get("/api/documents/email-address", headers=adult_a_headers)

    assert response.json() == {"configured": True, "address": preferred}
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT address, enabled, deleted_at FROM document_inbox_addresses "
                "WHERE family_id = ? ORDER BY address",
                (adult_a_user["family_id"],),
            )
        ).fetchall()
    by_address = {row["address"]: row for row in rows}
    assert by_address[preferred]["enabled"] == 1
    assert by_address[preferred]["deleted_at"] is None
    assert by_address[old_address]["enabled"] == 0
    assert by_address[old_address]["deleted_at"] is not None


async def test_forwarded_email_enters_inbox_once(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    retrieve = AsyncMock(
        return_value={
            "id": "email-1",
            "from": adult_a_user["email"],
            "to": [address],
            "subject": "July nursery invoice",
            "created_at": "2026-07-10T10:00:00Z",
            "text": "The nursery invoice is due on 20 July. Please arrange payment.",
            "html": None,
            "attachments": [],
        }
    )
    monkeypatch.setattr("app.services.inbound_email._retrieve_email", retrieve)
    payload = {
        "email_id": "email-1",
        "message_id": "<nursery-1@example.invalid>",
        "from": f"Alex <{adult_a_user['email']}>",
        "to": [address],
        "subject": "July nursery invoice",
    }

    async with aiosqlite.connect(initialized_db) as db:
        first = await process_received_email(payload, db)
        second = await process_received_email(payload, db)
        cursor = await db.execute(
            "SELECT title, category, source, status, extracted_text, "
            "category_confidence, document_date_confidence FROM documents "
            "WHERE family_id = ? AND deleted_at IS NULL",
            (adult_a_user["family_id"],),
        )
        documents = await cursor.fetchall()

    assert first["status"] == "processed"
    assert second["status"] == "duplicate"
    assert len(documents) == 1
    assert documents[0][0:4] == (
        "July nursery invoice",
        "childcare",
        "share",
        "inbox",
    )
    assert "arrange payment" in documents[0][4]
    assert documents[0][5:] == (0.92, 0.35)
    retrieve.assert_awaited_once_with("email-1")


async def test_inbound_email_ai_is_disabled_after_sender_withdraws_permission(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    revoked = await client.delete("/api/auth/ai-consent", headers=adult_a_headers)
    assert revoked.status_code == 200
    monkeypatch.setattr(settings, "resend_inbound_use_hermes", True)
    mock_extract = AsyncMock()
    monkeypatch.setattr(inbound_email_service, "extract_capture_suggestions", mock_extract)
    monkeypatch.setattr(
        inbound_email_service,
        "_retrieve_email",
        AsyncMock(
            return_value={
                "id": "email-no-ai",
                "from": adult_a_user["email"],
                "to": [address],
                "subject": "School letter",
                "created_at": "2026-07-10T10:00:00Z",
                "text": "Sports day is next Friday.",
                "html": None,
                "attachments": [],
            }
        ),
    )
    payload = {
        "email_id": "email-no-ai",
        "message_id": "<no-ai@example.invalid>",
        "from": adult_a_user["email"],
        "to": [address],
        "subject": "School letter",
    }

    async with aiosqlite.connect(initialized_db) as db:
        result = await process_received_email(payload, db)
        processor = (
            await (
                await db.execute(
                    "SELECT processor FROM documents WHERE family_id = ?",
                    (adult_a_user["family_id"],),
                )
            ).fetchone()
        )[0]

    assert result["status"] == "processed"
    assert processor == "fallback"
    mock_extract.assert_not_awaited()


async def test_inline_camera_photo_is_stored_as_a_real_document(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    photo_bytes = b"a-real-photo"
    monkeypatch.setattr(
        inbound_email_service,
        "_retrieve_email",
        AsyncMock(
            return_value={
                "id": "email-inline-photo",
                "created_at": "2026-07-18T10:00:00Z",
                "text": "Sent from my iPhone",
                "html": None,
                "attachments": [
                    {
                        "id": "attachment-photo",
                        "filename": "IMG_1234.jpeg",
                        "content_type": "image/jpeg",
                        "content_disposition": "inline",
                        "size": 512_000,
                    }
                ],
            }
        ),
    )
    attachment_details = AsyncMock(
        return_value={"download_url": "https://inbound-cdn.resend.com/photo"}
    )
    download_attachment = AsyncMock(return_value=photo_bytes)
    monkeypatch.setattr(inbound_email_service, "_attachment_details", attachment_details)
    monkeypatch.setattr(inbound_email_service, "_download_attachment", download_attachment)

    result = await process_received_email(
        {
            "email_id": "email-inline-photo",
            "from": adult_a_user["email"],
            "to": [address],
            "subject": "Photo from today",
        }
    )

    async with aiosqlite.connect(initialized_db) as db:
        document = await (
            await db.execute(
                "SELECT original_filename, media_type, storage_key, extracted_text "
                "FROM documents WHERE id = ?",
                (result["document_ids"][0],),
            )
        ).fetchone()

    assert result["status"] == "processed"
    assert document[0:2] == ("IMG_1234.jpeg", "image/jpeg")
    assert document[3] == "Sent from my iPhone"
    assert (Path(settings.document_storage_path) / document[2]).read_bytes() == photo_bytes
    attachment_details.assert_awaited_once_with("email-inline-photo", "attachment-photo")
    download_attachment.assert_awaited_once()


async def test_tiny_inline_email_logo_is_not_stored_instead_of_message_body(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    attachment_details = AsyncMock()
    monkeypatch.setattr(
        inbound_email_service,
        "_retrieve_email",
        AsyncMock(
            return_value={
                "id": "email-inline-logo",
                "created_at": "2026-07-18T10:00:00Z",
                "text": "The school trip leaves at nine.",
                "html": None,
                "attachments": [
                    {
                        "id": "attachment-logo",
                        "filename": "school-logo.png",
                        "content_type": "image/png",
                        "content_disposition": "inline",
                        "size": 4_096,
                    }
                ],
            }
        ),
    )
    monkeypatch.setattr(inbound_email_service, "_attachment_details", attachment_details)

    result = await process_received_email(
        {
            "email_id": "email-inline-logo",
            "from": adult_a_user["email"],
            "to": [address],
            "subject": "Synthetic public demo record 18",
        }
    )

    async with aiosqlite.connect(initialized_db) as db:
        document = await (
            await db.execute(
                "SELECT original_filename, media_type, extracted_text FROM documents WHERE id = ?",
                (result["document_ids"][0],),
            )
        ).fetchone()

    assert document[0:2] == ("Synthetic public demo record 18.txt", "text/plain")
    assert document[2] == "The school trip leaves at nine."
    attachment_details.assert_not_awaited()


async def test_inline_image_only_message_keeps_largest_image(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    monkeypatch.setattr(
        inbound_email_service,
        "_retrieve_email",
        AsyncMock(
            return_value={
                "id": "email-small-inline-photo",
                "created_at": "2026-07-18T10:00:00Z",
                "text": None,
                "html": None,
                "attachments": [
                    {
                        "id": "small-logo",
                        "filename": "logo.png",
                        "content_type": "image/png",
                        "content_disposition": "inline",
                        "size": 1_024,
                    },
                    {
                        "id": "small-photo",
                        "filename": "holiday.jpeg",
                        "content_type": "image/jpeg",
                        "content_disposition": "inline",
                        "size": 12_000,
                    },
                ],
            }
        ),
    )
    attachment_details = AsyncMock(
        return_value={"download_url": "https://inbound-cdn.resend.com/photo"}
    )
    monkeypatch.setattr(inbound_email_service, "_attachment_details", attachment_details)
    monkeypatch.setattr(
        inbound_email_service,
        "_download_attachment",
        AsyncMock(return_value=b"small-photo"),
    )

    result = await process_received_email(
        {
            "email_id": "email-small-inline-photo",
            "from": adult_a_user["email"],
            "to": [address],
            "subject": "Holiday photo",
        }
    )

    async with aiosqlite.connect(initialized_db) as db:
        filename = (
            await (
                await db.execute(
                    "SELECT original_filename FROM documents WHERE id = ?",
                    (result["document_ids"][0],),
                )
            ).fetchone()
        )[0]

    assert filename == "holiday.jpeg"
    attachment_details.assert_awaited_once_with("email-small-inline-photo", "small-photo")


async def test_concurrent_provider_retries_create_one_document_set(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    retrieval_started = asyncio.Event()
    release_retrieval = asyncio.Event()

    async def retrieve(email_id: str) -> dict:
        retrieval_started.set()
        await release_retrieval.wait()
        return {
            "id": email_id,
            "created_at": "2026-07-10T10:00:00Z",
            "text": "One provider message, one document.",
            "attachments": [],
        }

    monkeypatch.setattr("app.services.inbound_email._retrieve_email", retrieve)
    payload = {
        "email_id": "email-concurrent",
        "message_id": "<concurrent@example.invalid>",
        "from": adult_a_user["email"],
        "to": [address],
        "subject": "Concurrent delivery",
    }

    first_task = asyncio.create_task(process_received_email(payload))
    await asyncio.wait_for(retrieval_started.wait(), timeout=2)
    try:
        duplicate = await asyncio.wait_for(process_received_email(payload), timeout=2)
    finally:
        release_retrieval.set()
    first = await asyncio.wait_for(first_task, timeout=2)

    async with aiosqlite.connect(initialized_db) as db:
        document_count = (
            await (await db.execute("SELECT COUNT(*) FROM documents")).fetchone()
        )[0]
        receipt_count = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM inbound_email_messages "
                    "WHERE provider_message_id = 'email-concurrent'"
                )
            ).fetchone()
        )[0]

    assert first["status"] == "processed"
    assert duplicate == {"status": "duplicate", "document_ids": []}
    assert document_count == 1
    assert receipt_count == 1


async def test_expired_processing_lease_is_recovered(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    expired_at = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO inbound_email_messages (
                id, provider_message_id, from_address, to_address, subject,
                status, lease_token, lease_expires_at, family_id, created_by
            ) VALUES (?, ?, ?, ?, ?, 'processing', ?, ?, ?, ?)
            """,
            (
                "stale-receipt",
                "email-stale",
                adult_a_user["email"],
                address,
                "Stale delivery",
                "abandoned-worker",
                expired_at,
                adult_a_user["family_id"],
                adult_a_user["id"],
            ),
        )
        await db.commit()

    retrieve = AsyncMock(
        return_value={
            "id": "email-stale",
            "created_at": "2026-07-10T10:00:00Z",
            "text": "Recovered after a worker stopped.",
            "attachments": [],
        }
    )
    monkeypatch.setattr("app.services.inbound_email._retrieve_email", retrieve)
    result = await process_received_email(
        {
            "email_id": "email-stale",
            "from": adult_a_user["email"],
            "to": [address],
            "subject": "Stale delivery",
        }
    )

    async with aiosqlite.connect(initialized_db) as db:
        receipt = await (
            await db.execute(
                "SELECT status, lease_token, lease_expires_at, document_ids "
                "FROM inbound_email_messages WHERE provider_message_id = 'email-stale'"
            )
        ).fetchone()

    assert result["status"] == "processed"
    assert receipt[0:3] == ("processed", None, None)
    assert json.loads(receipt[3]) == result["document_ids"]


async def test_expired_worker_cannot_commit_after_retry_takes_over(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    payload = {
        "email_id": "email-takeover",
        "from": adult_a_user["email"],
        "to": [address],
        "subject": "Takeover delivery",
    }
    monkeypatch.setattr(
        "app.services.inbound_email._retrieve_email",
        AsyncMock(
            return_value={
                "id": "email-takeover",
                "created_at": "2026-07-10T10:00:00Z",
                "text": "Only the current lease may commit.",
                "attachments": [],
            }
        ),
    )

    first_file_stored = asyncio.Event()
    release_first_worker = asyncio.Event()
    store_calls = 0
    original_store_bytes = inbound_email_service.store_bytes

    async def store_with_first_worker_paused(*args, **kwargs):
        nonlocal store_calls
        result = await original_store_bytes(*args, **kwargs)
        store_calls += 1
        if store_calls == 1:
            first_file_stored.set()
            await release_first_worker.wait()
        return result

    monkeypatch.setattr(inbound_email_service, "store_bytes", store_with_first_worker_paused)
    first_task = asyncio.create_task(process_received_email(payload))
    await asyncio.wait_for(first_file_stored.wait(), timeout=2)

    expired_at = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            "UPDATE inbound_email_messages SET lease_expires_at = ? "
            "WHERE provider_message_id = 'email-takeover'",
            (expired_at,),
        )
        await db.commit()

    try:
        replacement = await asyncio.wait_for(process_received_email(payload), timeout=2)
    finally:
        release_first_worker.set()
    with pytest.raises(InboundEmailLeaseLost):
        await asyncio.wait_for(first_task, timeout=2)

    async with aiosqlite.connect(initialized_db) as db:
        documents = await (
            await db.execute("SELECT id, storage_key FROM documents ORDER BY created_at")
        ).fetchall()
        receipt = await (
            await db.execute(
                "SELECT status, document_ids, lease_token FROM inbound_email_messages "
                "WHERE provider_message_id = 'email-takeover'"
            )
        ).fetchone()
    stored_files = [path for path in Path(settings.document_storage_path).rglob("*") if path.is_file()]

    assert replacement["status"] == "processed"
    assert len(documents) == 1
    assert json.loads(receipt[1]) == [documents[0][0]]
    assert receipt[0:3:2] == ("processed", None)
    assert len(stored_files) == 1


async def test_concurrent_emails_cannot_exceed_family_document_quota(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    monkeypatch.setattr(settings, "document_family_quota_bytes", 15)

    async def retrieve(email_id: str) -> dict:
        return {
            "id": email_id,
            "created_at": "2026-07-10T10:00:00Z",
            "text": "1234567890",
            "attachments": [],
        }

    monkeypatch.setattr("app.services.inbound_email._retrieve_email", retrieve)
    payloads = [
        {
            "email_id": f"email-quota-{index}",
            "from": adult_a_user["email"],
            "to": [address],
            "subject": f"Quota {index}",
        }
        for index in range(2)
    ]
    results = await asyncio.gather(
        *(process_received_email(payload) for payload in payloads),
        return_exceptions=True,
    )

    async with aiosqlite.connect(initialized_db) as db:
        document_summary = await (
            await db.execute("SELECT COUNT(*), COALESCE(SUM(file_size), 0) FROM documents")
        ).fetchone()
        receipt_statuses = [
            row[0]
            for row in await (
                await db.execute(
                    "SELECT status FROM inbound_email_messages "
                    "WHERE provider_message_id LIKE 'email-quota-%' ORDER BY status"
                )
            ).fetchall()
        ]

    assert sum(isinstance(result, DocumentStorageError) for result in results) == 1
    assert sum(isinstance(result, dict) and result["status"] == "processed" for result in results) == 1
    assert document_summary == (1, 10)
    assert receipt_statuses == ["failed", "processed"]


async def test_inbound_email_uses_shared_durable_family_upload_limit(
    client,
    adult_a_user,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    monkeypatch.setattr(settings, "document_upload_rate_limit_requests", 1)
    retrieve = AsyncMock(
        return_value={
            "created_at": "2026-07-10T10:00:00Z",
            "text": "A document",
            "attachments": [],
        }
    )
    monkeypatch.setattr("app.services.inbound_email._retrieve_email", retrieve)

    def payload(email_id: str) -> dict:
        return {
            "email_id": email_id,
            "from": adult_a_user["email"],
            "to": [address],
            "subject": email_id,
        }

    first = await process_received_email(payload("email-rate-1"))
    with pytest.raises(HTTPException) as exc_info:
        await process_received_email(payload("email-rate-2"))

    async with aiosqlite.connect(initialized_db) as db:
        second_receipt = await (
            await db.execute(
                "SELECT id FROM inbound_email_messages "
                "WHERE provider_message_id = 'email-rate-2'"
            )
        ).fetchone()
        rate_events = (
            await (
                await db.execute(
                    "SELECT COUNT(*) FROM security_rate_limit_events "
                    "WHERE rate_key = ?",
                    (f"document-upload:{adult_a_user['family_id']}",),
                )
            ).fetchone()
        )[0]

    assert first["status"] == "processed"
    assert exc_info.value.status_code == 429
    assert second_receipt is None
    assert rate_events == 1
    assert retrieve.await_count == 1


async def test_unknown_sender_cannot_upload_to_discovered_address(
    client,
    adult_a_headers,
    initialized_db,
    monkeypatch,
):
    address = await _inbox_address(client, adult_a_headers)
    retrieve = AsyncMock()
    monkeypatch.setattr("app.services.inbound_email._retrieve_email", retrieve)

    async with aiosqlite.connect(initialized_db) as db:
        result = await process_received_email(
            {
                "email_id": "spam-1",
                "from": "attacker@example.invalid",
                "to": [address],
                "subject": "Not a family letter",
            },
            db,
        )
        cursor = await db.execute("SELECT COUNT(*) FROM documents WHERE deleted_at IS NULL")
        count = (await cursor.fetchone())[0]

    assert result == {"status": "ignored", "reason": "sender_not_allowed"}
    assert count == 0
    retrieve.assert_not_awaited()


async def test_explicit_dmarc_failure_is_ignored(
    client, adult_a_user, adult_a_headers, initialized_db, monkeypatch
):
    address = await _inbox_address(client, adult_a_headers)
    monkeypatch.setattr(
        "app.services.inbound_email._retrieve_email",
        AsyncMock(
            return_value={
                "text": "Spoofed family message",
                "attachments": [],
                "headers": {
                    "Authentication-Results": "mx.example; dmarc=fail header.from=example.com"
                },
            }
        ),
    )
    payload = {
        "email_id": "email-dmarc-fail",
        "from": adult_a_user["email"],
        "to": [address],
        "subject": "Spoofed",
    }

    async with aiosqlite.connect(initialized_db) as db:
        result = await process_received_email(payload, db)
        row = await (
            await db.execute(
                "SELECT status, error FROM inbound_email_messages "
                "WHERE provider_message_id = ?",
                ("email-dmarc-fail",),
            )
        ).fetchone()

    assert result == {"status": "ignored", "reason": "sender_authentication_failed"}
    assert row == ("ignored", "sender_authentication_failed")


async def test_resend_webhook_verifies_raw_payload_before_processing(
    client,
    monkeypatch,
):
    verify = AsyncMock()
    process = AsyncMock(return_value={"status": "processed", "document_ids": ["doc-1"]})
    monkeypatch.setattr("app.routers.inbound_email.verify_resend_webhook", verify)
    monkeypatch.setattr("app.routers.inbound_email.process_received_email", process)
    event = {
        "type": "email.received",
        "data": {
            "email_id": "email-1",
            "from": "demo-person-51@example.invalid",
            "to": ["demo-person-2@example.invalid"],
            "subject": "Letter",
        },
    }
    raw = json.dumps(event)

    response = await client.post(
        "/api/inbound-email/resend",
        content=raw,
        headers={
            "content-type": "application/json",
            "svix-id": "msg_1",
            "svix-timestamp": "1700000000",
            "svix-signature": "v1,signature",
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["document_ids"] == ["doc-1"]
    verify.assert_awaited_once_with(
        raw,
        {"id": "msg_1", "timestamp": "1700000000", "signature": "v1,signature"},
    )
    process.assert_awaited_once()


async def test_resend_webhook_rejects_invalid_signature(client, monkeypatch):
    monkeypatch.setattr(
        "app.routers.inbound_email.verify_resend_webhook",
        AsyncMock(side_effect=ValueError("invalid")),
    )
    response = await client.post(
        "/api/inbound-email/resend",
        content=json.dumps({"type": "email.received", "data": {}}),
        headers={
            "svix-id": "bad",
            "svix-timestamp": "0",
            "svix-signature": "bad",
        },
    )
    assert response.status_code == 401


async def test_attachment_download_rejects_private_network_hosts(monkeypatch):
    monkeypatch.setattr(
        "app.services.inbound_email.socket.getaddrinfo",
        lambda *args, **kwargs: [(2, 1, 6, "", ("127.0.0.1", 443))],
    )

    with pytest.raises(DocumentStorageError, match="not public"):
        await _validate_attachment_url("https://inbound-cdn.resend.com/file.pdf")


async def test_attachment_download_rejects_unapproved_hosts():
    with pytest.raises(DocumentStorageError, match="not approved"):
        await _validate_attachment_url("https://example.com/file.pdf")
