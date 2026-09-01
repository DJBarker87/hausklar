"""Strava OAuth and data ingestion service."""

import json
import uuid
from datetime import datetime, timezone
from urllib.parse import urlencode

import httpx

from app.config import settings

STRAVA_API_BASE = "https://www.strava.com/api/v3"
STRAVA_OAUTH_URL = "https://www.strava.com/oauth/authorize"
STRAVA_TOKEN_URL = "https://www.strava.com/oauth/token"

# Module-level token storage (in production, store in DB)
_tokens: dict = {}


def get_authorize_url() -> str:
    """Return the Strava OAuth authorization URL."""
    if not settings.strava_client_id:
        return ""

    params = {
        "client_id": settings.strava_client_id,
        "redirect_uri": settings.strava_redirect_uri,
        "response_type": "code",
        "scope": "read,activity:read_all",
    }
    return f"{STRAVA_OAUTH_URL}?{urlencode(params)}"


async def exchange_code(code: str) -> dict:
    """Exchange an authorization code for access and refresh tokens."""
    if not settings.strava_client_id or not settings.strava_client_secret:
        return {"error": "Strava client credentials not configured"}

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            STRAVA_TOKEN_URL,
            data={
                "client_id": settings.strava_client_id,
                "client_secret": settings.strava_client_secret,
                "code": code,
                "grant_type": "authorization_code",
            },
        )

    if resp.status_code != 200:
        return {"error": f"Token exchange failed: {resp.text}"}

    data = resp.json()
    # Store tokens for later use
    _tokens["access_token"] = data.get("access_token")
    _tokens["refresh_token"] = data.get("refresh_token")
    _tokens["expires_at"] = data.get("expires_at")
    return data


async def _fetch_activity(activity_id: int) -> dict | None:
    """Fetch a single activity from the Strava API."""
    access_token = _tokens.get("access_token")
    if not access_token:
        return None

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            f"{STRAVA_API_BASE}/activities/{activity_id}",
            headers={"Authorization": f"Bearer {access_token}"},
        )

    if resp.status_code != 200:
        return None

    return resp.json()


async def process_webhook(data: dict, db) -> dict:
    """Handle an incoming Strava webhook event.

    Fetches activity details and saves to health_data table.
    """
    object_type = data.get("object_type")
    aspect_type = data.get("aspect_type")
    object_id = data.get("object_id")

    if object_type != "activity" or aspect_type != "create":
        return {"status": "ignored", "reason": "not a new activity"}

    activity = await _fetch_activity(object_id)
    if not activity:
        return {"status": "error", "reason": "could not fetch activity"}

    now = datetime.now(timezone.utc).isoformat()
    record_id = str(uuid.uuid4())

    metadata = json.dumps({
        "activity_id": activity.get("id"),
        "name": activity.get("name"),
        "type": activity.get("type"),
        "distance": activity.get("distance"),
        "moving_time": activity.get("moving_time"),
        "elapsed_time": activity.get("elapsed_time"),
        "total_elevation_gain": activity.get("total_elevation_gain"),
    })

    await db.execute(
        """
        INSERT INTO health_data
            (id, source, data_type, value, unit, recorded_at, metadata,
             created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            record_id,
            "strava",
            activity.get("type", "activity"),
            activity.get("distance", 0.0),
            "meters",
            activity.get("start_date", now),
            metadata,
            now,
            now,
        ),
    )
    await db.commit()

    return {"status": "saved", "id": record_id}
