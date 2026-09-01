"""Authenticated, family-scoped library loan monitoring."""

import uuid
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Response, status

from app.auth import get_current_user
from app.database import database_lease
from app.middleware.rate_limit import RateLimiter
from app.models.library import (
    LibraryAccountCreate,
    LibraryAccountResponse,
    LibraryAccountUpdate,
    LibraryLoanResponse,
    LibraryOverviewResponse,
)
from app.services.library import (
    LibraryConnectionError,
    LIBRARY_PROVIDER_ACCOUNT_URL,
    ConfiguredLibraryClient,
    mark_library_sync_failure,
    persist_library_sync,
)
from app.utils.encryption import decrypt_value, encrypt_value

router = APIRouter()
library_rate_limiter = RateLimiter(max_attempts=10, window_seconds=3_600)

_ERROR_MESSAGES = {
    "login_rejected": "The library did not accept the saved card number and PIN.",
    "catalogue_changed": "The library changed its account page. Reconnect the card or try again later.",
    "catalogue_unavailable": "The library is unavailable just now. Try again later.",
    "response_too_large": "The library returned more data than HausKlar will accept.",
    "unsafe_catalogue_response": "The library returned an unexpected link, so HausKlar stopped safely.",
    "too_many_redirects": "The library redirected too many times. Try again later.",
    "sync_failed": "The library card could not be refreshed. Try again later.",
}


def _account_response(row: dict) -> LibraryAccountResponse:
    error_code = row.get("last_error_code")
    if error_code:
        connection_status = "needs_attention" if error_code == "login_rejected" else "temporarily_unavailable"
    elif row.get("last_success_at"):
        connection_status = "connected"
    else:
        connection_status = "pending"
    return LibraryAccountResponse(
        id=row["id"],
        provider=row["provider"],
        label=row["label"],
        card_last_four=row["card_last_four"],
        sync_enabled=bool(row["sync_enabled"]),
        reminder_days_before=int(row["reminder_days_before"]),
        status=connection_status,
        last_sync_at=row.get("last_sync_at"),
        last_success_at=row.get("last_success_at"),
        next_sync_at=row.get("next_sync_at"),
        error_message=_ERROR_MESSAGES.get(error_code) if error_code else None,
    )


async def _overview(db, *, family_id: str) -> LibraryOverviewResponse:
    account_rows = [
        dict(row)
        for row in await (
            await db.execute(
                """SELECT id,provider,label,card_last_four,sync_enabled,
                          reminder_days_before,last_sync_at,last_success_at,
                          last_error_code,next_sync_at
                   FROM library_accounts
                   WHERE family_id=? AND deleted_at IS NULL
                   ORDER BY created_at,label""",
                (family_id,),
            )
        ).fetchall()
    ]
    loan_rows = await (
        await db.execute(
            """SELECT loan.*,account.label AS account_label
               FROM library_loans loan
               JOIN library_accounts account
                 ON account.id=loan.account_id AND account.deleted_at IS NULL
               WHERE loan.family_id=? AND loan.deleted_at IS NULL
               ORDER BY loan.due_date,loan.title LIMIT 200""",
            (family_id,),
        )
    ).fetchall()
    today = datetime.now(ZoneInfo("Europe/London")).date()
    loans: list[LibraryLoanResponse] = []
    for row in loan_rows:
        due = date.fromisoformat(row["due_date"][:10])
        days_until = (due - today).days
        loans.append(
            LibraryLoanResponse(
                id=row["id"],
                account_id=row["account_id"],
                account_label=row["account_label"],
                title=row["title"],
                author=row["author"],
                material_format=row["material_format"],
                due_date=due.isoformat(),
                days_until=days_until,
                status="overdue" if days_until < 0 else "due_soon" if days_until <= 7 else "current",
                provider_status=row["provider_status"],
                renewable=None if row["renewable"] is None else bool(row["renewable"]),
                renewal_count=row["renewal_count"],
                renew_url=LIBRARY_PROVIDER_ACCOUNT_URL if days_until <= 7 else None,
            )
        )
    return LibraryOverviewResponse(
        accounts=[_account_response(row) for row in account_rows], loans=loans
    )


async def _owned_account(*, account_id: str, family_id: str) -> dict:
    async with database_lease() as db:
        row = await (
            await db.execute(
                "SELECT * FROM library_accounts WHERE id=? AND family_id=? AND deleted_at IS NULL",
                (account_id, family_id),
            )
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Library card not found")
    return dict(row)


async def _sync_account(*, account: dict, current_user: dict) -> None:
    try:
        card_number = decrypt_value(account["encrypted_card_number"])
        pin = decrypt_value(account["encrypted_pin"])
        async with ConfiguredLibraryClient() as client:
            loans = await client.current_loans(card_number=card_number, pin=pin)
    except LibraryConnectionError as exc:
        await mark_library_sync_failure(
            account_id=account["id"],
            family_id=current_user["family_id"],
            code=exc.code,
        )
        raise HTTPException(status_code=422, detail=exc.message) from exc
    except (TypeError, ValueError, RuntimeError) as exc:
        raise HTTPException(
            status_code=503,
            detail="The saved library login could not be read. Reconnect this card.",
        ) from exc
    async with database_lease() as db:
        await persist_library_sync(
            db,
            account_id=account["id"],
            family_id=current_user["family_id"],
            actor_id=current_user["id"],
            loans=loans,
        )
        await db.commit()


@router.get("/", response_model=LibraryOverviewResponse)
async def library_overview(current_user: dict = Depends(get_current_user)):
    async with database_lease() as db:
        return await _overview(db, family_id=current_user["family_id"])


@router.post("/accounts", response_model=LibraryOverviewResponse, status_code=201)
async def connect_library_account(
    body: LibraryAccountCreate,
    current_user: dict = Depends(get_current_user),
):
    library_rate_limiter.ensure_allowed(
        f"library:{current_user['id']}", detail_prefix="Too many library login attempts"
    )
    library_rate_limiter.record_failure(f"library:{current_user['id']}")
    card_number = body.card_number.get_secret_value()
    pin = body.pin.get_secret_value()
    try:
        async with ConfiguredLibraryClient() as client:
            loans = await client.current_loans(card_number=card_number, pin=pin)
    except LibraryConnectionError as exc:
        raise HTTPException(status_code=422, detail=exc.message) from exc
    account_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        await db.execute(
            """INSERT INTO library_accounts
               (id,provider,label,card_last_four,encrypted_card_number,encrypted_pin,
                sync_enabled,reminder_days_before,family_id,created_at,updated_at,created_by)
               VALUES (?,'local_authority_spydus',?,?,?,?,1,?,?,?,?,?)""",
            (
                account_id,
                body.label,
                card_number[-4:],
                encrypt_value(card_number),
                encrypt_value(pin),
                body.reminder_days_before,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
            ),
        )
        await persist_library_sync(
            db,
            account_id=account_id,
            family_id=current_user["family_id"],
            actor_id=current_user["id"],
            loans=loans,
        )
        await db.commit()
        result = await _overview(db, family_id=current_user["family_id"])
    library_rate_limiter.record_success(f"library:{current_user['id']}")
    return result


@router.post("/accounts/{account_id}/sync", response_model=LibraryOverviewResponse)
async def sync_library_account(
    account_id: str,
    current_user: dict = Depends(get_current_user),
):
    account = await _owned_account(account_id=account_id, family_id=current_user["family_id"])
    await _sync_account(account=account, current_user=current_user)
    async with database_lease() as db:
        return await _overview(db, family_id=current_user["family_id"])


@router.patch("/accounts/{account_id}", response_model=LibraryOverviewResponse)
async def update_library_account(
    account_id: str,
    body: LibraryAccountUpdate,
    current_user: dict = Depends(get_current_user),
):
    await _owned_account(account_id=account_id, family_id=current_user["family_id"])
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(status_code=422, detail="Choose something to update")
    now = datetime.now(timezone.utc).isoformat()
    assignments = [f"{key}=?" for key in updates]
    values = [int(value) if isinstance(value, bool) else value for value in updates.values()]
    async with database_lease() as db:
        await db.execute(
            f"UPDATE library_accounts SET {','.join(assignments)},updated_at=? "
            "WHERE id=? AND family_id=? AND deleted_at IS NULL",
            (*values, now, account_id, current_user["family_id"]),
        )
        await db.commit()
        return await _overview(db, family_id=current_user["family_id"])


@router.delete("/accounts/{account_id}", status_code=204)
async def disconnect_library_account(
    account_id: str,
    current_user: dict = Depends(get_current_user),
):
    await _owned_account(account_id=account_id, family_id=current_user["family_id"])
    now = datetime.now(timezone.utc).isoformat()
    async with database_lease() as db:
        await db.execute(
            "UPDATE library_accounts SET deleted_at=?,updated_at=? WHERE id=? AND family_id=?",
            (now, now, account_id, current_user["family_id"]),
        )
        await db.execute(
            """UPDATE library_loans SET deleted_at=?,updated_at=?
               WHERE account_id=? AND family_id=? AND deleted_at IS NULL""",
            (now, now, account_id, current_user["family_id"]),
        )
        await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
