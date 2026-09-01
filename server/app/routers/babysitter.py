"""Babysitter Mode — read-only aggregate endpoint.

Returns current family data plus the readiness of the parent-entered caregiver
pack. An incomplete pack contains no inferred or placeholder handover details.
"""

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Cookie, Depends, HTTPException, Request, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.middleware.rate_limit import RateLimiter, extract_client_ip
from app.models.babysitter import (
    BabysitterResponse,
    CaregiverBookingCreate,
    CaregiverBookingCreatedResponse,
    CaregiverBookingResponse,
    CaregiverBookingRevokeResponse,
    CaregiverPackMissingSection,
    CaregiverPackResponse,
    CaregiverPackStatus,
    CaregiverHandoverResponse,
    CaregiverHandoverUpdate,
    CaregiverSessionExchange,
    CaregiverSessionExchangeResponse,
    CaregiverSessionView,
)
from app.config import settings
from app.services.babysitter import (
    booking_for_session,
    create_booking,
    exchange_booking_code,
    handover_for_family,
    list_bookings,
    revoke_booking,
    session_view,
    update_handover,
)

router = APIRouter()
CAREGIVER_SESSION_COOKIE = "hausklar_caregiver_session"
_exchange_limiter = RateLimiter(max_attempts=20, window_seconds=60)


@router.get("/handover", response_model=CaregiverHandoverResponse)
async def get_caregiver_handover(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await handover_for_family(db, current_user["family_id"])


@router.put("/handover", response_model=CaregiverHandoverResponse)
async def put_caregiver_handover(
    body: CaregiverHandoverUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await update_handover(
            db,
            family_id=current_user["family_id"],
            user_id=current_user["id"],
            body=body,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.get("/bookings", response_model=list[CaregiverBookingResponse])
async def get_caregiver_bookings(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await list_bookings(db, current_user["family_id"])


@router.post(
    "/bookings",
    response_model=CaregiverBookingCreatedResponse,
    status_code=status.HTTP_201_CREATED,
)
async def post_caregiver_booking(
    body: CaregiverBookingCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await create_booking(
            db,
            family_id=current_user["family_id"],
            user_id=current_user["id"],
            body=body,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.delete("/bookings/{booking_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_caregiver_booking(
    booking_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if not await revoke_booking(
        db,
        family_id=current_user["family_id"],
        user_id=current_user["id"],
        booking_id=booking_id,
    ):
        raise HTTPException(status_code=404, detail="Caregiver booking not found")
    return Response(status_code=204)


@router.post(
    "/bookings/{booking_id}/revoke",
    response_model=CaregiverBookingRevokeResponse,
)
async def post_revoke_caregiver_booking(
    booking_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Online-only-friendly revoke contract for the native client."""
    if not await revoke_booking(
        db,
        family_id=current_user["family_id"],
        user_id=current_user["id"],
        booking_id=booking_id,
    ):
        raise HTTPException(status_code=404, detail="Caregiver booking not found")
    return CaregiverBookingRevokeResponse(booking_id=booking_id)


@router.post("/sessions/exchange", response_model=CaregiverSessionExchangeResponse)
async def exchange_caregiver_session(
    body: CaregiverSessionExchange,
    request: Request,
    response: Response,
    db=Depends(get_db),
):
    """Exchange a one-time URL-fragment bootstrap for an HttpOnly session."""
    rate_key = f"caregiver-exchange:{extract_client_ip(request)}"
    _exchange_limiter.ensure_allowed(
        rate_key,
        detail_prefix="Too many invalid caregiver links",  # gitleaks:allow
    )
    try:
        session, booking = await exchange_booking_code(db, body.code)
    except ValueError as exc:
        _exchange_limiter.record_failure(rate_key)
        raise HTTPException(status_code=401, detail=str(exc)) from exc
    _exchange_limiter.record_success(rate_key)
    expires_at = datetime.fromisoformat(booking["expires_at"])
    max_age = max(1, int((expires_at - datetime.now(timezone.utc)).total_seconds()))
    response.set_cookie(
        CAREGIVER_SESSION_COOKIE,
        session,
        max_age=max_age,
        expires=expires_at,
        path="/api/babysitter/sessions",
        secure=settings.app_env.strip().lower() == "production",
        httponly=True,
        samesite="strict",
    )
    response.headers["Cache-Control"] = "no-store"
    return CaregiverSessionExchangeResponse(expires_at=booking["expires_at"])


@router.get("/sessions/view", response_model=CaregiverSessionView)
async def get_caregiver_session_view(
    response: Response,
    caregiver_session: str | None = Cookie(None, alias=CAREGIVER_SESSION_COOKIE),
    db=Depends(get_db),
):
    try:
        booking = await booking_for_session(db, caregiver_session)
    except ValueError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc
    response.headers["Cache-Control"] = "no-store"
    try:
        return await session_view(db, booking)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


def _calculate_age(date_of_birth: str) -> int:
    """Calculate age in years from a date-of-birth string (YYYY-MM-DD)."""
    dob = datetime.strptime(date_of_birth, "%Y-%m-%d")
    today = datetime.now(timezone.utc).date()
    age = today.year - dob.year
    if (today.month, today.day) < (dob.month, dob.day):
        age -= 1
    return age


@router.get("/", response_model=BabysitterResponse)
async def get_babysitter_view(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Return a truthful read-only babysitter view.

    Aggregates data from: children, medicine_types, medicine_doses,
    naps, calendar_events, and users tables.
    """

    # ------------------------------------------------------------------
    # Children
    # ------------------------------------------------------------------
    cursor = await db.execute(
        "SELECT * FROM children WHERE deleted_at IS NULL AND family_id = ? ORDER BY date_of_birth",
        (current_user["family_id"],),
    )
    children_rows = await cursor.fetchall()

    children = []
    for row in children_rows:
        child = dict(row)
        children.append(
            {
                "name": child["name"],
                "age": _calculate_age(child["date_of_birth"]),
                "date_of_birth": child["date_of_birth"],
                "notes": child.get("notes"),
            }
        )

    # ------------------------------------------------------------------
    # Medicine schedule
    # ------------------------------------------------------------------
    cursor = await db.execute(
        """
        SELECT mt.id AS type_id,
               mt.name AS medicine_name,
               mt.min_hours_between_doses,
               mt.notes AS dosage_notes,
               c.name AS child_name
        FROM medicine_types mt
        JOIN children c ON mt.child_id = c.id
        WHERE mt.deleted_at IS NULL AND c.deleted_at IS NULL AND mt.family_id = ?
        """,
        (current_user["family_id"],),
    )
    medicine_type_rows = await cursor.fetchall()

    medicine_schedule = []
    for mt_row in medicine_type_rows:
        mt = dict(mt_row)

        # Most recent dose for this medicine type
        cursor = await db.execute(
            """
            SELECT md.given_at, md.given_by, md.dose_amount
            FROM medicine_doses md
            WHERE md.medicine_type_id = ? AND md.deleted_at IS NULL
            ORDER BY md.given_at DESC
            LIMIT 1
            """,
            (mt["type_id"],),
        )
        last_dose_row = await cursor.fetchone()

        last_given_at = None
        last_given_by = None
        next_dose_allowed_at = None

        if last_dose_row:
            dose = dict(last_dose_row)
            last_given_at = dose["given_at"]

            # Resolve the user name for given_by
            cursor = await db.execute(
                "SELECT name FROM users WHERE id = ?",
                (dose["given_by"],),
            )
            user_row = await cursor.fetchone()
            last_given_by = dict(user_row)["name"] if user_row else dose["given_by"]

            # Calculate next_dose_allowed_at
            given_dt = datetime.fromisoformat(last_given_at)
            next_dt = given_dt + timedelta(hours=mt["min_hours_between_doses"])
            next_dose_allowed_at = next_dt.isoformat()

        medicine_schedule.append(
            {
                "child_name": mt["child_name"],
                "medicine_name": mt["medicine_name"],
                "dosage_notes": mt["dosage_notes"],
                "last_given_at": last_given_at,
                "last_given_by": last_given_by,
                "next_dose_allowed_at": next_dose_allowed_at,
                "min_hours_between": mt["min_hours_between_doses"],
            }
        )

    # ------------------------------------------------------------------
    # Active naps (ended_at IS NULL)
    # ------------------------------------------------------------------
    cursor = await db.execute(
        """
        SELECT n.started_at, n.location, c.name AS child_name
        FROM naps n
        JOIN children c ON n.child_id = c.id
        WHERE n.ended_at IS NULL AND n.deleted_at IS NULL AND n.family_id = ?
        ORDER BY n.started_at DESC
        """,
        (current_user["family_id"],),
    )
    nap_rows = await cursor.fetchall()

    active_naps = []
    for row in nap_rows:
        nap = dict(row)
        active_naps.append(
            {
                "child_name": nap["child_name"],
                "started_at": nap["started_at"],
                "location": nap.get("location"),
            }
        )

    # ------------------------------------------------------------------
    # Today's calendar events
    # ------------------------------------------------------------------
    today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    cursor = await db.execute(
        """
        SELECT title, start_time, end_time
        FROM calendar_events
        WHERE date(start_time) = ? AND deleted_at IS NULL AND family_id = ?
        ORDER BY start_time
        """,
        (today_str, current_user["family_id"]),
    )
    event_rows = await cursor.fetchall()

    todays_events = []
    for row in event_rows:
        event = dict(row)
        todays_events.append(
            {
                "title": event["title"],
                "start_time": event["start_time"],
                "end_time": event["end_time"],
            }
        )

    return {
        # These fields do not yet have authoritative storage. Refuse to
        # manufacture a plausible handover until a caregiver pack is real.
        "caregiver_pack": CaregiverPackResponse(
            status=CaregiverPackStatus.INCOMPLETE,
            missing_sections=list(CaregiverPackMissingSection),
        ),
        "children": children,
        "medicine_schedule": medicine_schedule,
        "active_naps": active_naps,
        "todays_events": todays_events,
    }
