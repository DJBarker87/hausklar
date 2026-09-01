"""Health tracking router — OAuth callbacks, webhooks, and data queries."""

import json
import secrets
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status

from app.auth import get_current_user
from app.config import settings
from app.database import get_db
from app.models.health import HealthDataCreate, HealthDataResponse
from app.services import apple_health, strava, withings

router = APIRouter()


def _row_to_response(row) -> HealthDataResponse:
    """Convert a database row into a HealthDataResponse."""
    d = dict(row)
    # Parse metadata JSON string back into dict
    if d.get("metadata") and isinstance(d["metadata"], str):
        try:
            d["metadata"] = json.loads(d["metadata"])
        except (json.JSONDecodeError, TypeError):
            pass
    return HealthDataResponse(**d)


def _assert_webhook_secret(secret_header: str | None) -> None:
    expected = settings.health_webhook_secret.strip()
    provided = (secret_header or "").strip()
    if not expected:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Webhook secret not configured",
        )
    if not secrets.compare_digest(provided, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid webhook secret",
        )


def _require_legacy_integrations() -> None:
    if not settings.legacy_health_integrations_enabled:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "Health provider integrations are disabled until secure "
                "per-family connections are configured"
            ),
        )


# ---------------------------------------------------------------------------
# Health data queries (requires auth)
# ---------------------------------------------------------------------------


@router.get("/data", response_model=list[HealthDataResponse])
async def list_health_data(
    source: str | None = Query(None),
    data_type: str | None = Query(None),
    start: str | None = Query(None),
    end: str | None = Query(None),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """List health data with optional filters."""
    query = "SELECT * FROM health_data WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]

    if source is not None:
        query += " AND source = ?"
        params.append(source)

    if data_type is not None:
        query += " AND data_type = ?"
        params.append(data_type)

    if start is not None:
        query += " AND recorded_at >= ?"
        params.append(start)

    if end is not None:
        query += " AND recorded_at <= ?"
        params.append(end)

    query += " ORDER BY recorded_at DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_row_to_response(row) for row in rows]


@router.post("/data", response_model=HealthDataResponse, status_code=status.HTTP_201_CREATED)
async def create_health_data(
    body: HealthDataCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a health data record directly (for testing/manual entry)."""
    record_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    metadata_str = json.dumps(body.metadata) if body.metadata else None

    await db.execute(
        """
        INSERT INTO health_data
            (id, source, data_type, value, unit, recorded_at, metadata,
             family_id, created_at, updated_at, created_by, client_id, client_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            record_id,
            body.source,
            body.data_type,
            body.value,
            body.unit,
            body.recorded_at,
            metadata_str,
            current_user["family_id"],
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
        ),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM health_data WHERE id = ?", (record_id,))
    row = await cursor.fetchone()
    return _row_to_response(row)


# ---------------------------------------------------------------------------
# Strava OAuth + Webhook
# ---------------------------------------------------------------------------


@router.get("/strava/authorize")
async def strava_authorize(current_user: dict = Depends(get_current_user)):
    """Return the Strava OAuth authorization URL."""
    _require_legacy_integrations()
    url = strava.get_authorize_url()
    if not url:
        return {"error": "Strava client credentials not configured", "url": ""}
    return {"url": url}


@router.get("/strava/callback")
async def strava_callback(
    code: str = Query(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Handle the Strava OAuth callback — exchange code for tokens."""
    _require_legacy_integrations()
    result = await strava.exchange_code(code)
    if "error" in result:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=result["error"])
    return {"status": "connected"}


@router.get("/strava/webhook")
async def strava_webhook_verify(request: Request):
    """Handle Strava webhook subscription verification (GET).

    Strava sends a GET request with hub.mode, hub.challenge, and hub.verify_token.
    We must return the hub.challenge value to confirm.
    """
    _require_legacy_integrations()
    expected_verify_token = settings.strava_webhook_verify_token.strip()
    provided_verify_token = request.query_params.get("hub.verify_token", "")
    if not expected_verify_token:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Strava webhook verify token not configured",
        )
    if not secrets.compare_digest(provided_verify_token, expected_verify_token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Strava webhook verify token",
        )

    challenge = request.query_params.get("hub.challenge")
    if challenge:
        return {"hub.challenge": challenge}
    return {"error": "missing hub.challenge"}


@router.post("/strava/webhook")
async def strava_webhook(
    request: Request,
    x_webhook_secret: str | None = Header(default=None),
    db=Depends(get_db),
):
    """Receive Strava webhook events (POST)."""
    _require_legacy_integrations()
    _assert_webhook_secret(x_webhook_secret)
    data = await request.json()
    result = await strava.process_webhook(data, db)
    return result


# ---------------------------------------------------------------------------
# Withings OAuth + Webhook
# ---------------------------------------------------------------------------


@router.get("/withings/authorize")
async def withings_authorize(current_user: dict = Depends(get_current_user)):
    """Return the Withings OAuth authorization URL."""
    _require_legacy_integrations()
    url = withings.get_authorize_url()
    if not url:
        return {"error": "Withings client credentials not configured", "url": ""}
    return {"url": url}


@router.get("/withings/callback")
async def withings_callback(
    code: str = Query(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Handle the Withings OAuth callback — exchange code for tokens."""
    _require_legacy_integrations()
    result = await withings.exchange_code(code)
    if "error" in result:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=result["error"])
    return {"status": "connected"}


@router.post("/withings/webhook")
async def withings_webhook(
    request: Request,
    x_webhook_secret: str | None = Header(default=None),
    db=Depends(get_db),
):
    """Receive Withings webhook notifications (POST)."""
    _require_legacy_integrations()
    _assert_webhook_secret(x_webhook_secret)
    data = await request.json()
    result = await withings.process_webhook(data, db)
    return result


# ---------------------------------------------------------------------------
# Apple Health (via Health Auto Export app)
# ---------------------------------------------------------------------------


@router.post("/apple")
async def apple_health_webhook(
    request: Request,
    x_webhook_secret: str | None = Header(default=None),
    db=Depends(get_db),
):
    """Receive Apple Health data from the Health Auto Export app."""
    _require_legacy_integrations()
    _assert_webhook_secret(x_webhook_secret)
    data = await request.json()
    # Webhook is unauthenticated — assign to the first family in the database.
    cursor = await db.execute("SELECT id FROM families ORDER BY created_at LIMIT 1")
    row = await cursor.fetchone()
    family_id = row["id"] if row else None
    result = await apple_health.process_webhook(data, db, family_id=family_id)
    return result
