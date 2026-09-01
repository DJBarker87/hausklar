"""Withings OAuth and data ingestion service."""

import json
import uuid
from datetime import datetime, timezone
from urllib.parse import urlencode

import httpx

from app.config import settings

WITHINGS_API_BASE = "https://wbsapi.withings.net"
WITHINGS_OAUTH_URL = "https://account.withings.com/oauth2_user/authorize2"
WITHINGS_TOKEN_URL = "https://wbsapi.withings.net/v2/oauth2"

# Module-level token storage (in production, store in DB)
_tokens: dict = {}

# Withings measure type mapping
MEASURE_TYPES = {
    1: ("weight", "kg"),
    4: ("height", "meters"),
    5: ("fat_free_mass", "kg"),
    6: ("fat_ratio", "percent"),
    8: ("fat_mass_weight", "kg"),
    9: ("diastolic_blood_pressure", "mmHg"),
    10: ("systolic_blood_pressure", "mmHg"),
    11: ("heart_pulse", "bpm"),
    76: ("muscle_mass", "kg"),
    77: ("hydration", "kg"),
    88: ("bone_mass", "kg"),
}


def get_authorize_url() -> str:
    """Return the Withings OAuth authorization URL."""
    if not settings.withings_client_id:
        return ""

    params = {
        "response_type": "code",
        "client_id": settings.withings_client_id,
        "redirect_uri": settings.withings_redirect_uri,
        "scope": "user.metrics",
        "state": "withings_auth",
    }
    return f"{WITHINGS_OAUTH_URL}?{urlencode(params)}"


async def exchange_code(code: str) -> dict:
    """Exchange an authorization code for access and refresh tokens."""
    if not settings.withings_client_id or not settings.withings_client_secret:
        return {"error": "Withings client credentials not configured"}

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            WITHINGS_TOKEN_URL,
            data={
                "action": "requesttoken",
                "grant_type": "authorization_code",
                "client_id": settings.withings_client_id,
                "client_secret": settings.withings_client_secret,
                "code": code,
                "redirect_uri": settings.withings_redirect_uri,
            },
        )

    if resp.status_code != 200:
        return {"error": f"Token exchange failed: {resp.text}"}

    data = resp.json()
    body = data.get("body", {})
    # Store tokens for later use
    _tokens["access_token"] = body.get("access_token")
    _tokens["refresh_token"] = body.get("refresh_token")
    _tokens["expires_in"] = body.get("expires_in")
    return data


async def _fetch_measurements(startdate: int, enddate: int) -> list:
    """Fetch measurements from the Withings API."""
    access_token = _tokens.get("access_token")
    if not access_token:
        return []

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{WITHINGS_API_BASE}/measure",
            headers={"Authorization": f"Bearer {access_token}"},
            data={
                "action": "getmeas",
                "startdate": startdate,
                "enddate": enddate,
            },
        )

    if resp.status_code != 200:
        return []

    data = resp.json()
    body = data.get("body", {})
    return body.get("measuregrps", [])


async def process_webhook(data: dict, db) -> dict:
    """Handle an incoming Withings webhook notification.

    Fetches measurement details and saves to health_data table.
    """
    startdate = data.get("startdate")
    enddate = data.get("enddate")

    if not startdate or not enddate:
        return {"status": "ignored", "reason": "missing date range"}

    measure_groups = await _fetch_measurements(startdate, enddate)
    saved = []

    for grp in measure_groups:
        grp_date = grp.get("date", "")
        recorded_at = (
            datetime.fromtimestamp(grp_date, tz=timezone.utc).isoformat()
            if isinstance(grp_date, (int, float))
            else str(grp_date)
        )

        for measure in grp.get("measures", []):
            measure_type = measure.get("type")
            type_info = MEASURE_TYPES.get(measure_type)
            if not type_info:
                continue

            data_type, unit = type_info
            # Withings stores values with a multiplier: real_value = value * 10^unit
            raw_value = measure.get("value", 0)
            power = measure.get("unit", 0)
            value = raw_value * (10 ** power)

            now = datetime.now(timezone.utc).isoformat()
            record_id = str(uuid.uuid4())

            metadata = json.dumps({
                "measure_type": measure_type,
                "grpid": grp.get("grpid"),
                "category": grp.get("category"),
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
                    "withings",
                    data_type,
                    value,
                    unit,
                    recorded_at,
                    metadata,
                    now,
                    now,
                ),
            )
            saved.append(record_id)

    await db.commit()
    return {"status": "saved", "count": len(saved), "ids": saved}
