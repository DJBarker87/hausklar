"""Public, signed webhook endpoint for inbound document email."""

import json
import logging

from fastapi import APIRouter, HTTPException, Request

from app.config import settings
from app.services.inbound_email import process_received_email, verify_resend_webhook

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/resend")
async def resend_inbound_webhook(request: Request):
    if not (
        settings.resend_api_key.strip()
        and settings.resend_webhook_secret.strip()
        and settings.resend_inbound_domain.strip()
    ):
        raise HTTPException(status_code=503, detail="Inbound email is not configured")

    raw = await request.body()
    if len(raw) > 1_048_576:
        raise HTTPException(status_code=413, detail="Webhook payload is too large")
    try:
        payload_text = raw.decode("utf-8")
        await verify_resend_webhook(
            payload_text,
            {
                "id": request.headers.get("svix-id", ""),
                "timestamp": request.headers.get("svix-timestamp", ""),
                "signature": request.headers.get("svix-signature", ""),
            },
        )
        event = json.loads(payload_text)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise HTTPException(status_code=401, detail="Invalid webhook signature or payload") from exc

    if event.get("type") != "email.received":
        return {"status": "ignored"}
    email_id = str((event.get("data") or {}).get("email_id") or "").strip()
    try:
        result = await process_received_email(event.get("data") or {})
        logger.info(
            "Inbound email handled email_id=%s status=%s reason=%s documents=%d",
            email_id or "missing",
            result.get("status", "unknown"),
            result.get("reason", "none"),
            len(result.get("document_ids") or []),
        )
        return result
    except HTTPException:
        raise
    except Exception as exc:
        logger.error(
            "Inbound email processing failed email_id=%s error_type=%s",
            email_id or "missing",
            type(exc).__name__,
        )
        raise HTTPException(status_code=503, detail="Inbound email processing failed") from exc
