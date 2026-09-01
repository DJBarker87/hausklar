"""Email delivery helpers."""

from __future__ import annotations

from urllib.parse import quote

import httpx

from app.config import settings


def password_reset_link(reset_token: str) -> str:
    """Build a browser-only fragment link so the token never reaches HTTP request logs."""
    base_url = settings.web_app_url.strip().rstrip("/")
    return f"{base_url}/#reset-password={quote(reset_token, safe='')}"


async def send_password_reset_email(to_email: str, reset_token: str) -> dict:
    """Send a password reset email via Resend.

    Returns {"success": bool, "error": str | None}.
    """
    if not settings.resend_api_key:
        return {"success": False, "error": "Resend API key not configured"}

    subject = "HausKlar password reset"
    reset_link = password_reset_link(reset_token)
    text = (
        "You requested a HausKlar password reset.\n\n"
        f"Open this link to choose a new password:\n{reset_link}\n\n"
        "The link expires in 1 hour. If you did not request this, you can ignore this email."
    )
    html = (
        "<p>You requested a HausKlar password reset.</p>"
        f"<p><a href=\"{reset_link}\">Choose a new password</a></p>"
        "<p>The link expires in 1 hour. If you did not request this, you can ignore this email.</p>"
    )

    payload = {
        "from": settings.resend_from_email,
        "to": [to_email],
        "subject": subject,
        "text": text,
        "html": html,
    }
    headers = {
        "Authorization": f"Bearer {settings.resend_api_key}",
        "Content-Type": "application/json",
    }

    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.post(
                "https://api.resend.com/emails",
                json=payload,
                headers=headers,
            )
            response.raise_for_status()
            return {"success": True, "error": None}
    except (httpx.HTTPError, Exception) as exc:
        return {"success": False, "error": str(exc)}
