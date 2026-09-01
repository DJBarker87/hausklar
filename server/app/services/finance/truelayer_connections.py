"""TrueLayer v1 hosted consent, encrypted token rotation, and stored-account sync."""

from __future__ import annotations

import hashlib
import json
import secrets
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Awaitable, Callable, TypeVar

from app.models.finance import NormalisedSourceTransaction
from app.models.finance_connection import (
    FinanceConnectionResponse,
    FinanceConnectionSyncResponse,
    FinanceTrueLayerConnectionStartRequest,
)
from app.services.finance.enable_banking_connections import (
    FinanceConnectionError,
    FinanceConnectionNotFoundError,
    FinanceConnectionProviderUnavailableError,
    FinanceConnectionStateError,
    _after_material_bank_sync,
    _connection_response,
    _derived_refresh_responses,
    _normalise_provider_transaction,
    _record_provider_balance,
    _retire_omitted_provider_accounts,
    _safe_error_code,
    _upsert_accounts,
)
from app.services.finance.foundation import require_finance_space
from app.services.finance.ledger import import_source_transactions
from app.services.finance.providers.base import ProviderError, ProviderResponseError, ProviderTransportError, TransactionState
from app.services.finance.providers.truelayer import (
    TrueLayerAccessTokenExpired,
    TrueLayerAccounts,
    TrueLayerAdapter,
    TrueLayerCredentials,
    TrueLayerRateLimited,
    TrueLayerReauthorisationRequired,
)
from app.services.idempotency import serialized_create
from app.services.record_history import save_history
from app.utils.encryption import decrypt_finance_provider_value, encrypt_finance_provider_value

STATE_TTL = timedelta(minutes=10)
CONSENT_TTL = timedelta(days=90)
ACCESS_REFRESH_SKEW = timedelta(minutes=5)
SYNC_OVERLAP = timedelta(days=7)
MAX_TRANSACTION_WINDOW = timedelta(days=370)
_CAPABILITIES_JSON = '["accounts","balances","cards","transactions"]'
_CONNECTION_HISTORY_SECRET_FIELDS = {
    "encrypted_provider_secret_ref",
    "callback_state_hash",
}
_ALLOWED_SYNC_STATUSES = {"CONNECTED", "PARTIAL", "PROVIDER_DOWN"}

T = TypeVar("T")


@dataclass(frozen=True, slots=True)
class _StoredCredentials:
    credentials: TrueLayerCredentials
    provider_id: str | None = None
    credentials_id: str | None = None


@dataclass(frozen=True, slots=True)
class TrueLayerCallbackClaim:
    connection: dict
    pending: dict
    user: dict
    client: str
    observed_at: datetime


async def start_truelayer_connection(
    db,
    *,
    user: dict,
    body: FinanceTrueLayerConnectionStartRequest,
    provider: TrueLayerAdapter,
    now: datetime | None = None,
) -> str:
    """Create one owner-bound state and return TrueLayer's fixed hosted journey."""
    await require_finance_space(db, user=user, space_id=body.space_id)
    observed_at = _utc_now(now)
    state = secrets.token_urlsafe(32)

    def encrypted_state(operation_generation: int) -> str:
        return _encrypt_payload(
            {
                "kind": "TRUELAYER_AUTHORISATION_STATE",
                "state": state,
                "user_id": user["id"],
                "space_id": body.space_id,
                "client": body.client,
                "operation_generation": operation_generation,
                "expires_at": _utc_text(observed_at + STATE_TTL),
            }
        )

    redirect_url = provider.build_authorisation_url(state=state)
    now_text = _utc_text(observed_at)
    if body.connection_id is not None:
        connection = await _authorised_connection(
            db,
            user=user,
            connection_id=body.connection_id,
        )
        if connection["space_id"] != body.space_id or connection["created_by"] != user["id"]:
            raise FinanceConnectionNotFoundError("Finance connection not found")
        if connection["status"] not in {"DISCONNECTED", "EXPIRED", "REAUTH_REQUIRED"}:
            raise FinanceConnectionStateError("Bank connection is already active")
        current_generation = int(connection.get("operation_generation") or 0)
        next_generation = current_generation + 1
        async with serialized_create(db):
            await save_history(
                db,
                "finance_connections",
                connection["id"],
                user["id"],
                family_id=user["family_id"],
                excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
            )
            updated = await db.execute(
                """
                UPDATE finance_connections
                SET status = 'REAUTH_REQUIRED', granted_capabilities = ?,
                    consent_created_at = NULL, consent_expires_at = NULL,
                    last_success_at = NULL, last_error_code = 'AUTHORISATION_PENDING',
                    encrypted_provider_secret_ref = ?, callback_state_hash = ?,
                    sync_lease_token = NULL, sync_lease_expires_at = NULL,
                    next_retry_at = NULL, consecutive_sync_failures = 0,
                    operation_generation = ?, updated_at = ?
                WHERE id = ? AND family_id = ? AND created_by = ?
                  AND provider = 'TRUELAYER'
                  AND operation_generation = ?
                  AND status IN ('DISCONNECTED', 'EXPIRED', 'REAUTH_REQUIRED')
                  AND deleted_at IS NULL
                """,
                (
                    _CAPABILITIES_JSON,
                    encrypted_state(next_generation),
                    _state_digest(state),
                    next_generation,
                    now_text,
                    connection["id"],
                    user["family_id"],
                    user["id"],
                    current_generation,
                ),
            )
            if updated.rowcount != 1:
                raise FinanceConnectionStateError("Bank connection cannot be reconnected")
        return redirect_url
    async with serialized_create(db):
        reusable = await (
            await db.execute(
                "SELECT connection.* FROM finance_connections connection "
                "WHERE connection.space_id = ? AND connection.family_id = ? "
                "AND connection.created_by = ? AND connection.provider = 'TRUELAYER' "
                "AND connection.status = 'REAUTH_REQUIRED' "
                "AND connection.last_error_code IN "
                "('AUTHORISATION_PENDING', 'AUTHORISATION_CANCELLED') "
                "AND connection.deleted_at IS NULL "
                "AND NOT EXISTS (SELECT 1 FROM finance_accounts account "
                "WHERE account.connection_id = connection.id "
                "AND account.deleted_at IS NULL) "
                "ORDER BY connection.updated_at DESC, connection.id DESC LIMIT 1",
                (body.space_id, user["family_id"], user["id"]),
            )
        ).fetchone()
        if reusable is not None:
            current_generation = int(reusable["operation_generation"] or 0)
            next_generation = current_generation + 1
            await save_history(
                db,
                "finance_connections",
                reusable["id"],
                user["id"],
                family_id=user["family_id"],
                excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
            )
            updated = await db.execute(
                "UPDATE finance_connections SET status = 'REAUTH_REQUIRED', "
                "granted_capabilities = ?, last_error_code = 'AUTHORISATION_PENDING', "
                "encrypted_provider_secret_ref = ?, callback_state_hash = ?, "
                "operation_generation = ?, updated_at = ? "
                "WHERE id = ? AND family_id = ? AND created_by = ? "
                "AND provider = 'TRUELAYER' AND operation_generation = ? "
                "AND deleted_at IS NULL",
                (
                    _CAPABILITIES_JSON,
                    encrypted_state(next_generation),
                    _state_digest(state),
                    next_generation,
                    now_text,
                    reusable["id"],
                    user["family_id"],
                    user["id"],
                    current_generation,
                ),
            )
            if updated.rowcount != 1:
                raise FinanceConnectionStateError("Bank authorisation could not be restarted")
            return redirect_url
        await db.execute(
            """
            INSERT INTO finance_connections
                (id, space_id, provider, status, granted_capabilities,
                 last_error_code, encrypted_provider_secret_ref,
                 callback_state_hash, operation_generation, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, 'TRUELAYER', 'REAUTH_REQUIRED', ?,
                    'AUTHORISATION_PENDING', ?, ?, 1, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                body.space_id,
                _CAPABILITIES_JSON,
                encrypted_state(1),
                _state_digest(state),
                user["family_id"],
                now_text,
                now_text,
                user["id"],
            ),
        )
    return redirect_url


async def complete_truelayer_callback(
    db,
    *,
    state: str | None = None,
    claim: TrueLayerCallbackClaim | None = None,
    code: str,
    provider: TrueLayerAdapter,
    now: datetime | None = None,
) -> tuple[FinanceConnectionResponse, str]:
    """Persist tokens, discover accounts, then run the first stored-account sync."""
    if claim is None:
        if state is None:
            raise FinanceConnectionStateError("Bank authorisation state is invalid")
        claim = await claim_truelayer_callback(db, state=state, now=now)
    connection = claim.connection
    user = claim.user
    client = claim.client
    observed_at = claim.observed_at

    try:
        credentials = await provider.exchange_code(code, now=observed_at)
    except TrueLayerReauthorisationRequired as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="REAUTH_REQUIRED",
            error_code="AUTHORISATION_EXCHANGE_FAILED",
            clear_secret=True,
            now=observed_at,
        )
        raise FinanceConnectionError("Bank authorisation needs to be restarted") from exc
    except (ProviderError, ValueError) as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="PROVIDER_DOWN",
            error_code="AUTHORISATION_EXCHANGE_FAILED",
            clear_secret=True,
            now=observed_at,
        )
        raise FinanceConnectionProviderUnavailableError(
            "Bank authorisation could not be completed"
        ) from exc

    stored = _StoredCredentials(credentials=credentials)
    await _persist_callback_credentials(
        db,
        connection=connection,
        user=user,
        stored=stored,
        now=observed_at,
    )

    # Account/card collections are captured once immediately after consent.
    # Later syncs use the stored resource IDs and never relist either collection.
    try:
        discovered_accounts = await provider.accounts(credentials)
        discovered_cards = await provider.cards(credentials)
    except TrueLayerReauthorisationRequired as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="REAUTH_REQUIRED",
            error_code="ACCOUNT_DISCOVERY_REAUTH_REQUIRED",
            clear_secret=True,
            now=observed_at,
        )
        raise FinanceConnectionError("Bank authorisation needs to be restarted") from exc
    except (ProviderError, ValueError) as exc:
        has_saved_accounts = await _has_active_accounts(
            db,
            connection=connection,
        )
        await _set_connection_failure(
            db,
            connection=connection,
            status="PARTIAL" if has_saved_accounts else "REAUTH_REQUIRED",
            error_code="ACCOUNT_DISCOVERY_FAILED",
            clear_secret=False,
            now=observed_at,
        )
        raise FinanceConnectionProviderUnavailableError(
            "Bank accounts could not be connected; please try again"
        ) from exc
    try:
        discovered = _combine_discovery(discovered_accounts, discovered_cards)
    except (ProviderError, ValueError) as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="REAUTH_REQUIRED",
            error_code="ACCOUNT_DISCOVERY_FAILED",
            clear_secret=True,
            now=observed_at,
        )
        raise FinanceConnectionProviderUnavailableError(
            "Bank accounts could not be connected; please try again"
        ) from exc

    stored = _StoredCredentials(
        credentials=credentials,
        provider_id=discovered.provider_id,
        credentials_id=discovered.credentials_id,
    )
    now_text = _utc_text(observed_at)
    institution = discovered.institution_name.strip()[:120] or "Bank"
    connection_for_accounts = {**connection, "institution_id": f"GB:{institution}"}
    async with serialized_create(db):
        await _require_current_operation(
            db,
            connection=connection,
            expected_error_code="ACCOUNT_DISCOVERY_PENDING",
            callback=True,
        )
        account_issues = await _upsert_accounts(
            db,
            connection=connection_for_accounts,
            accounts=discovered.accounts,
            user=user,
            institution=institution,
            now_text=now_text,
        )
        if not account_issues:
            await _retire_omitted_provider_accounts(
                db,
                connection=connection_for_accounts,
                provider_account_ids={
                    account.provider_account_id
                    for account in discovered.accounts
                    if account.provider_account_id is not None
                },
                user=user,
                now_text=now_text,
            )
        await save_history(
            db,
            "finance_connections",
            connection["id"],
            user["id"],
            family_id=user["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        await db.execute(
            """
            UPDATE finance_connections
            SET institution_id = ?, status = ?, granted_capabilities = ?,
                consent_created_at = ?, consent_expires_at = ?,
                encrypted_provider_secret_ref = ?, last_error_code = ?, updated_at = ?
            WHERE id = ? AND family_id = ? AND created_by = ?
              AND provider = 'TRUELAYER' AND operation_generation = ?
              AND last_error_code = 'ACCOUNT_DISCOVERY_PENDING'
              AND deleted_at IS NULL
            """,
            (
                f"GB:{institution}",
                "PARTIAL" if account_issues else "CONNECTED",
                _CAPABILITIES_JSON,
                now_text,
                _utc_text(observed_at + CONSENT_TTL),
                _encrypt_stored_credentials(stored),
                _safe_error_code(sorted(account_issues)[0] if account_issues else None),
                now_text,
                connection["id"],
                user["family_id"],
                user["id"],
                _operation_generation(connection),
            ),
        )
    try:
        await sync_truelayer_connection(
            db,
            user=user,
            connection_id=connection["id"],
            provider=provider,
            now=observed_at,
        )
    except FinanceConnectionProviderUnavailableError:
        # The account IDs and credentials are useful. Keep the connection and
        # let the bounded retry schedule fill balances/transactions later.
        pass
    return await _read_connection_response(
        db,
        user=user,
        connection_id=connection["id"],
    ), client


async def cancel_truelayer_callback(
    db,
    *,
    state: str,
    now: datetime | None = None,
) -> str:
    """Consume a cancelled callback and return only its verified client kind."""
    claim = await claim_truelayer_callback(db, state=state, now=now)
    await _set_connection_failure(
        db,
        connection=claim.connection,
        status="REAUTH_REQUIRED",
        error_code="AUTHORISATION_CANCELLED",
        clear_secret=True,
        now=claim.observed_at,
    )
    return claim.client


async def claim_truelayer_callback(
    db,
    *,
    state: str,
    now: datetime | None = None,
) -> TrueLayerCallbackClaim:
    """Validate and atomically consume one callback before provider construction."""
    observed_at = _utc_now(now)
    connection, pending, user = await _connection_for_state(
        db,
        state=state,
        observed_at=observed_at,
    )
    if _state_expiry(pending) <= observed_at:
        await _set_connection_failure(
            db,
            connection=connection,
            status="EXPIRED",
            error_code="AUTHORISATION_STATE_EXPIRED",
            clear_secret=True,
            now=observed_at,
        )
        raise FinanceConnectionStateError("Bank authorisation state has expired")
    await _claim_callback_state(db, connection=connection, user=user, now=observed_at)
    return TrueLayerCallbackClaim(
        connection=connection,
        pending=pending,
        user=user,
        client=_pending_client(pending),
        observed_at=observed_at,
    )


async def fail_truelayer_callback_claim(
    db,
    *,
    claim: TrueLayerCallbackClaim,
    error_code: str = "AUTHORISATION_EXCHANGE_FAILED",
) -> None:
    await _set_connection_failure(
        db,
        connection=claim.connection,
        status="REAUTH_REQUIRED",
        error_code=error_code,
        clear_secret=True,
        now=claim.observed_at,
    )


async def sync_truelayer_connection(
    db,
    *,
    user: dict,
    connection_id: str,
    provider: TrueLayerAdapter,
    now: datetime | None = None,
    automated: bool = False,
) -> FinanceConnectionSyncResponse:
    """Refresh one connection with a committed lease and bounded retry delay."""
    observed_at = _utc_now(now)
    connection = await _authorised_connection(db, user=user, connection_id=connection_id)
    operation_generation = _operation_generation(connection)
    lease_token = secrets.token_urlsafe(24)
    lease_until = observed_at + timedelta(minutes=30)
    async with serialized_create(db):
        claimed = await db.execute(
            "UPDATE finance_connections SET sync_lease_token = ?, "
            "sync_lease_expires_at = ?, updated_at = ? WHERE id = ? AND family_id = ? "
            "AND provider = 'TRUELAYER' "
            "AND operation_generation = ? "
            "AND status IN ('CONNECTED', 'PARTIAL', 'PROVIDER_DOWN') "
            "AND (sync_lease_expires_at IS NULL OR sync_lease_expires_at <= ?) "
            "AND (? = 0 OR next_retry_at IS NULL OR next_retry_at <= ?) "
            "AND deleted_at IS NULL",
            (
                lease_token,
                _utc_text(lease_until),
                _utc_text(observed_at),
                connection_id,
                user["family_id"],
                operation_generation,
                _utc_text(observed_at),
                int(automated),
                _utc_text(observed_at),
            ),
        )
        if claimed.rowcount != 1:
            raise FinanceConnectionError(
                "Bank sync is already running or waiting for its retry window"
            )
    try:
        result = await _perform_sync(
            db,
            user=user,
            connection=connection,
            provider=provider,
            lease_token=lease_token,
            now=observed_at,
        )
    except Exception:
        current = await (
            await db.execute(
                "SELECT consecutive_sync_failures FROM finance_connections "
                "WHERE id = ? AND family_id = ? AND operation_generation = ? "
                "AND sync_lease_token = ?",
                (
                    connection_id,
                    user["family_id"],
                    operation_generation,
                    lease_token,
                ),
            )
        ).fetchone()
        failures = min(20, int(current[0] if current else 0) + 1)
        retry_minutes = min(360, 5 * (2 ** min(failures - 1, 6)))
        async with serialized_create(db):
            await db.execute(
                "UPDATE finance_connections SET sync_lease_token = NULL, "
                "sync_lease_expires_at = NULL, consecutive_sync_failures = ?, "
                "next_retry_at = ?, updated_at = ? WHERE id = ? AND family_id = ? "
                "AND operation_generation = ? AND sync_lease_token = ? "
                "AND deleted_at IS NULL",
                (
                    failures,
                    _utc_text(observed_at + timedelta(minutes=retry_minutes)),
                    _utc_text(observed_at),
                    connection_id,
                    user["family_id"],
                    operation_generation,
                    lease_token,
                ),
            )
        raise
    async with serialized_create(db):
        await db.execute(
            "UPDATE finance_connections SET sync_lease_token = NULL, "
            "sync_lease_expires_at = NULL, next_retry_at = NULL, "
            "consecutive_sync_failures = 0 WHERE id = ? AND family_id = ? "
            "AND operation_generation = ? AND sync_lease_token = ? "
            "AND deleted_at IS NULL",
            (
                connection_id,
                user["family_id"],
                operation_generation,
                lease_token,
            ),
        )
    if any((result.balances_created, result.canonical_created, result.pending_superseded)) and await _operation_is_current(
        db,
        connection=connection,
    ):
        await _after_material_bank_sync(
            db,
            user=user,
            space_id=connection["space_id"],
            connection_id=connection_id,
            now=observed_at,
        )
    return result.model_copy(
        update={
            "derived_refreshes": await _derived_refresh_responses(
                db,
                connection_id=connection_id,
                space_id=connection["space_id"],
                family_id=user["family_id"],
            )
        }
    )


async def sync_due_truelayer_connections(
    db,
    *,
    provider: TrueLayerAdapter,
    now: datetime | None = None,
) -> int:
    """Refresh due TrueLayer rows independently, retaining useful stale data."""
    observed_at = _utc_now(now)
    regular_due_before = observed_at - timedelta(hours=6)
    rows = await (
        await db.execute(
            "SELECT connection.*, user.id AS owner_id "
            "FROM finance_connections connection JOIN users user "
            "ON user.id = connection.created_by AND user.family_id = connection.family_id "
            "AND user.deleted_at IS NULL WHERE connection.provider = 'TRUELAYER' "
            "AND connection.status IN ('CONNECTED', 'PARTIAL', 'PROVIDER_DOWN') "
            "AND (connection.next_retry_at IS NULL OR connection.next_retry_at <= ?) "
            "AND (connection.status = 'PROVIDER_DOWN' "
            "OR connection.last_success_at IS NULL "
            "OR connection.last_success_at <= ? "
            "OR EXISTS (SELECT 1 FROM finance_accounts account "
            "WHERE account.connection_id = connection.id "
            "AND account.history_synced_from_date IS NULL "
            "AND account.provider_presence_status = 'ACTIVE' "
            "AND account.deleted_at IS NULL)) "
            "AND (connection.sync_lease_expires_at IS NULL "
            "OR connection.sync_lease_expires_at <= ?) AND connection.deleted_at IS NULL "
            "ORDER BY connection.last_success_at, connection.id",
            (
                _utc_text(observed_at),
                _utc_text(regular_due_before),
                _utc_text(observed_at),
            ),
        )
    ).fetchall()
    completed = 0
    for row in rows:
        owner = await (
            await db.execute(
                "SELECT * FROM users WHERE id = ? AND family_id = ? "
                "AND deleted_at IS NULL",
                (row["owner_id"], row["family_id"]),
            )
        ).fetchone()
        if owner is None:
            continue
        try:
            await sync_truelayer_connection(
                db,
                user=dict(owner),
                connection_id=row["id"],
                provider=provider,
                now=observed_at,
                automated=True,
            )
        except Exception:
            continue
        completed += 1
    return completed


async def _perform_sync(
    db,
    *,
    user: dict,
    connection: dict,
    provider: TrueLayerAdapter,
    lease_token: str,
    now: datetime,
) -> FinanceConnectionSyncResponse:
    if connection["status"] not in _ALLOWED_SYNC_STATUSES:
        raise FinanceConnectionError("Bank connection needs authorisation before sync")
    consent_expires_at = _parse_utc(connection.get("consent_expires_at"), "consent expiry")
    if consent_expires_at <= now:
        await _set_connection_failure(
            db,
            connection=connection,
            status="EXPIRED",
            error_code="CONSENT_EXPIRED",
            clear_secret=True,
            now=now,
            lease_token=lease_token,
        )
        raise FinanceConnectionError("Bank consent has expired")

    stored = _decrypt_stored_credentials(connection.get("encrypted_provider_secret_ref"))
    try:
        if stored.credentials.access_expires_at <= now + ACCESS_REFRESH_SKEW:
            stored = await _refresh_and_persist(
                db,
                connection=connection,
                user=user,
                provider=provider,
                stored=stored,
                lease_token=lease_token,
                now=now,
            )
    except TrueLayerReauthorisationRequired as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="REAUTH_REQUIRED",
            error_code="CONSENT_REAUTH_REQUIRED",
            clear_secret=True,
            now=now,
            lease_token=lease_token,
        )
        raise FinanceConnectionError("Bank connection needs authorisation") from exc
    except (ProviderTransportError, TrueLayerRateLimited) as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="PROVIDER_DOWN",
            error_code="PROVIDER_UNAVAILABLE",
            clear_secret=False,
            now=now,
            lease_token=lease_token,
        )
        raise FinanceConnectionProviderUnavailableError(
            "Bank data is temporarily unavailable"
        ) from exc

    refreshed_after_401 = False

    async def data_call(operation: Callable[[TrueLayerCredentials], Awaitable[T]]) -> T:
        nonlocal stored, refreshed_after_401
        try:
            return await operation(stored.credentials)
        except TrueLayerAccessTokenExpired:
            if refreshed_after_401:
                raise TrueLayerReauthorisationRequired(
                    "Bank connection needs authorisation"
                ) from None
            refreshed_after_401 = True
            stored = await _refresh_and_persist(
                db,
                connection=connection,
                user=user,
                provider=provider,
                stored=stored,
                lease_token=lease_token,
                now=now,
            )
            return await operation(stored.credentials)

    account_rows = await (
        await db.execute(
            "SELECT * FROM finance_accounts WHERE connection_id = ? AND space_id = ? "
            "AND family_id = ? AND provider_account_id IS NOT NULL "
            "AND provider_presence_status = 'ACTIVE' AND deleted_at IS NULL "
            "ORDER BY id",
            (connection["id"], connection["space_id"], user["family_id"]),
        )
    ).fetchall()
    if not account_rows:
        await _set_connection_failure(
            db,
            connection=connection,
            status="REAUTH_REQUIRED",
            error_code="NO_ACTIVE_ACCOUNTS",
            clear_secret=True,
            now=now,
            lease_token=lease_token,
        )
        raise FinanceConnectionError("Bank connection has no active accounts")
    issues: set[str] = set()
    balances_created = 0
    source_created = 0
    canonical_created = 0
    duplicates = 0
    pending_superseded = 0
    latest_booking: date | None = None

    try:
        for source in account_rows:
            local_account = dict(source)
            provider_account_id = local_account["provider_account_id"]
            try:
                balances = await data_call(
                    lambda credentials,
                    account_id=provider_account_id,
                    resource_type=local_account["provider_resource_type"]: provider.balances(
                        credentials,
                        account_id,
                        resource_type=resource_type,
                    )
                )
            except (TrueLayerReauthorisationRequired, TrueLayerAccessTokenExpired, ProviderTransportError):
                raise
            except ProviderError:
                issues.add("BALANCE_FETCH_FAILED")
            else:
                async with serialized_create(db):
                    await _require_current_operation(
                        db,
                        connection=connection,
                        lease_token=lease_token,
                    )
                    created, balance_issues = await _record_provider_balance(
                        db,
                        user=user,
                        connection=connection,
                        local_account=local_account,
                        balances=balances,
                        observed_at=now,
                    )
                balances_created += int(created)
                issues.update(balance_issues)

            date_from = _transaction_resume_date(
                local_account.get("fresh_through_date"),
                history_synced_from_date=local_account.get("history_synced_from_date"),
                observed_on=now.date(),
            )
            observations: list[NormalisedSourceTransaction] = []
            booked_history_complete = False
            for transaction_state in (TransactionState.BOOKED, TransactionState.PENDING):
                try:
                    pages = await data_call(
                        lambda credentials,
                        account_id=provider_account_id,
                        resource_type=local_account["provider_resource_type"],
                        requested_state=transaction_state: provider.transaction_pages(
                            credentials,
                            account_id,
                            state=requested_state,
                            date_from=date_from,
                            date_to=now.date(),
                            resource_type=resource_type,
                        )
                    )
                except (
                    TrueLayerReauthorisationRequired,
                    TrueLayerAccessTokenExpired,
                    ProviderTransportError,
                ):
                    raise
                except ProviderError:
                    issues.add(f"{transaction_state.value.upper()}_FETCH_FAILED")
                    continue
                if pages.truncated:
                    issues.add(f"{transaction_state.value.upper()}_PAGINATION_TRUNCATED")
                elif transaction_state is TransactionState.BOOKED:
                    booked_history_complete = True
                for page in pages.pages:
                    for transaction in page.transactions:
                        observation, issue = _normalise_provider_transaction(
                            transaction,
                            connection_id=connection["id"],
                            account_currency=local_account["currency"],
                            observed_at=now,
                        )
                        if issue:
                            issues.add(issue)
                        elif observation:
                            observations.append(observation)
                            latest_booking = max(
                                latest_booking or observation.booking_date,
                                observation.booking_date,
                            )
            async with serialized_create(db):
                await _require_current_operation(
                    db,
                    connection=connection,
                    lease_token=lease_token,
                )
                imported = await import_source_transactions(
                    db,
                    user=user,
                    space_id=connection["space_id"],
                    account_id=local_account["id"],
                    observations=observations,
                )
                if booked_history_complete and date_from is not None:
                    await _record_history_window(
                        db,
                        user=user,
                        connection=connection,
                        local_account=local_account,
                        date_from=date_from,
                        lease_token=lease_token,
                        now=now,
                    )
            source_created += imported.source_created
            canonical_created += imported.canonical_created
            duplicates += imported.duplicates
            pending_superseded += imported.pending_superseded
    except (TrueLayerReauthorisationRequired, TrueLayerAccessTokenExpired) as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="REAUTH_REQUIRED",
            error_code="CONSENT_REAUTH_REQUIRED",
            clear_secret=True,
            now=now,
            lease_token=lease_token,
        )
        raise FinanceConnectionError("Bank connection needs authorisation") from exc
    except (ProviderTransportError, TrueLayerRateLimited) as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="PROVIDER_DOWN",
            error_code="PROVIDER_UNAVAILABLE",
            clear_secret=False,
            now=now,
            lease_token=lease_token,
        )
        raise FinanceConnectionProviderUnavailableError(
            "Bank data is temporarily unavailable"
        ) from exc

    status = "PARTIAL" if issues else "CONNECTED"
    now_text = _utc_text(now)
    async with serialized_create(db):
        await _require_current_operation(
            db,
            connection=connection,
            lease_token=lease_token,
        )
        await save_history(
            db,
            "finance_connections",
            connection["id"],
            user["id"],
            family_id=user["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        await db.execute(
            """
            UPDATE finance_connections
            SET status = ?, last_success_at = ?, last_error_code = ?,
                data_through_at = CASE
                    WHEN ? IS NULL THEN data_through_at
                    WHEN data_through_at IS NULL OR data_through_at < ? THEN ?
                    ELSE data_through_at END,
                updated_at = ?
            WHERE id = ? AND family_id = ? AND provider = 'TRUELAYER'
              AND operation_generation = ? AND sync_lease_token = ?
              AND deleted_at IS NULL
            """,
            (
                status,
                now_text,
                _safe_error_code(sorted(issues)[0] if issues else None),
                latest_booking.isoformat() if latest_booking else None,
                latest_booking.isoformat() if latest_booking else None,
                latest_booking.isoformat() if latest_booking else None,
                now_text,
                connection["id"],
                user["family_id"],
                _operation_generation(connection),
                lease_token,
            ),
        )
    return FinanceConnectionSyncResponse(
        connection_id=connection["id"],
        status=status,
        accounts_seen=len(account_rows),
        balances_created=balances_created,
        source_created=source_created,
        canonical_created=canonical_created,
        duplicates=duplicates,
        pending_superseded=pending_superseded,
        partial_issue_codes=sorted(issues),
    )


async def _refresh_and_persist(
    db,
    *,
    connection: dict,
    user: dict,
    provider: TrueLayerAdapter,
    stored: _StoredCredentials,
    lease_token: str,
    now: datetime,
) -> _StoredCredentials:
    replacement = await provider.refresh_credentials(
        stored.credentials.refresh_token,
        now=now,
    )
    rotated = _StoredCredentials(
        credentials=replacement,
        provider_id=stored.provider_id,
        credentials_id=stored.credentials_id,
    )
    async with serialized_create(db):
        await _require_current_operation(
            db,
            connection=connection,
            lease_token=lease_token,
        )
        await save_history(
            db,
            "finance_connections",
            connection["id"],
            user["id"],
            family_id=user["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        updated = await db.execute(
            """
            UPDATE finance_connections
            SET encrypted_provider_secret_ref = ?, updated_at = ?
            WHERE id = ? AND family_id = ? AND provider = 'TRUELAYER'
              AND operation_generation = ? AND sync_lease_token = ?
              AND deleted_at IS NULL
            """,
            (
                _encrypt_stored_credentials(rotated),
                _utc_text(now),
                connection["id"],
                user["family_id"],
                _operation_generation(connection),
                lease_token,
            ),
        )
        if updated.rowcount != 1:
            raise FinanceConnectionError("Bank sync lease was lost")
    return rotated


async def _persist_callback_credentials(
    db,
    *,
    connection: dict,
    user: dict,
    stored: _StoredCredentials,
    now: datetime,
) -> None:
    async with serialized_create(db):
        await _require_current_operation(
            db,
            connection=connection,
            expected_error_code="AUTHORISATION_EXCHANGING",
            callback=True,
        )
        await save_history(
            db,
            "finance_connections",
            connection["id"],
            user["id"],
            family_id=user["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        await db.execute(
            """
            UPDATE finance_connections
            SET status = 'PARTIAL', granted_capabilities = ?,
                consent_created_at = ?, consent_expires_at = ?,
                last_error_code = 'ACCOUNT_DISCOVERY_PENDING',
                encrypted_provider_secret_ref = ?, updated_at = ?
            WHERE id = ? AND family_id = ? AND created_by = ?
              AND provider = 'TRUELAYER' AND operation_generation = ?
              AND last_error_code = 'AUTHORISATION_EXCHANGING'
              AND deleted_at IS NULL
            """,
            (
                _CAPABILITIES_JSON,
                _utc_text(now),
                _utc_text(now + CONSENT_TTL),
                _encrypt_stored_credentials(stored),
                _utc_text(now),
                connection["id"],
                user["family_id"],
                user["id"],
                _operation_generation(connection),
            ),
        )


async def _claim_callback_state(db, *, connection: dict, user: dict, now: datetime) -> None:
    async with serialized_create(db):
        await save_history(
            db,
            "finance_connections",
            connection["id"],
            user["id"],
            family_id=user["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        claimed = await db.execute(
            """
            UPDATE finance_connections
            SET last_error_code = 'AUTHORISATION_EXCHANGING',
                callback_state_hash = NULL, updated_at = ?
            WHERE id = ? AND family_id = ? AND created_by = ?
              AND provider = 'TRUELAYER' AND status = 'REAUTH_REQUIRED'
              AND last_error_code = 'AUTHORISATION_PENDING'
              AND operation_generation = ? AND deleted_at IS NULL
            """,
            (
                _utc_text(now),
                connection["id"],
                user["family_id"],
                user["id"],
                _operation_generation(connection),
            ),
        )
        if claimed.rowcount != 1:
            raise FinanceConnectionStateError("Bank authorisation state was already used")


async def _connection_for_state(
    db,
    *,
    state: str,
    observed_at: datetime,
) -> tuple[dict, dict, dict]:
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_connections
            WHERE callback_state_hash = ? AND provider = 'TRUELAYER'
              AND status = 'REAUTH_REQUIRED'
              AND last_error_code = 'AUTHORISATION_PENDING'
              AND deleted_at IS NULL
            LIMIT 1
            """,
            (_state_digest(state),),
        )
    ).fetchone()
    if row is None:
        raise FinanceConnectionStateError("Bank authorisation state is invalid or already used")
    connection = dict(row)
    try:
        pending = _decrypt_payload(connection.get("encrypted_provider_secret_ref"))
    except FinanceConnectionStateError:
        raise FinanceConnectionStateError(
            "Bank authorisation state is invalid or already used"
        ) from None
    if not (
        pending.get("kind") == "TRUELAYER_AUTHORISATION_STATE"
        and pending.get("user_id") == connection["created_by"]
        and pending.get("space_id") == connection["space_id"]
        and int(pending.get("operation_generation", 0))
        == _operation_generation(connection)
        and isinstance(pending.get("state"), str)
        and secrets.compare_digest(pending["state"], state)
        and pending.get("client") in {"web", "ios"}
    ):
        raise FinanceConnectionStateError("Bank authorisation state is invalid or already used")
    owner = await (
        await db.execute(
            "SELECT * FROM users WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (connection["created_by"], connection["family_id"]),
        )
    ).fetchone()
    if owner is None:
        raise FinanceConnectionStateError("Bank authorisation state is invalid or already used")
    user = dict(owner)
    await require_finance_space(db, user=user, space_id=connection["space_id"])
    # Parse before exchange so malformed or expired state never reaches TrueLayer.
    _state_expiry(pending)
    return connection, pending, user


async def _authorised_connection(db, *, user: dict, connection_id: str) -> dict:
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_connections
            WHERE id = ? AND family_id = ? AND provider = 'TRUELAYER'
              AND deleted_at IS NULL
            """,
            (connection_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceConnectionNotFoundError("Finance connection not found")
    connection = dict(row)
    await require_finance_space(db, user=user, space_id=connection["space_id"])
    return connection


async def _read_connection_response(
    db,
    *,
    user: dict,
    connection_id: str,
) -> FinanceConnectionResponse:
    connection = await _authorised_connection(
        db,
        user=user,
        connection_id=connection_id,
    )
    return await _connection_response(db, connection)


async def _has_active_accounts(db, *, connection: dict) -> bool:
    row = await (
        await db.execute(
            "SELECT 1 FROM finance_accounts WHERE connection_id = ? AND space_id = ? "
            "AND family_id = ? AND deleted_at IS NULL LIMIT 1",
            (connection["id"], connection["space_id"], connection["family_id"]),
        )
    ).fetchone()
    return row is not None


def _operation_generation(connection: dict) -> int:
    return int(connection.get("operation_generation") or 0)


async def _operation_is_current(
    db,
    *,
    connection: dict,
    lease_token: str | None = None,
    expected_error_code: str | None = None,
) -> bool:
    clauses = [
        "id = ?",
        "family_id = ?",
        "provider = 'TRUELAYER'",
        "operation_generation = ?",
        "deleted_at IS NULL",
    ]
    parameters: list[object] = [
        connection["id"],
        connection["family_id"],
        _operation_generation(connection),
    ]
    if lease_token is not None:
        clauses.append("sync_lease_token = ?")
        parameters.append(lease_token)
    if expected_error_code is not None:
        clauses.append("last_error_code = ?")
        parameters.append(expected_error_code)
    row = await (
        await db.execute(
            f"SELECT 1 FROM finance_connections WHERE {' AND '.join(clauses)}",
            parameters,
        )
    ).fetchone()
    return row is not None


async def _require_current_operation(
    db,
    *,
    connection: dict,
    lease_token: str | None = None,
    expected_error_code: str | None = None,
    callback: bool = False,
) -> None:
    if await _operation_is_current(
        db,
        connection=connection,
        lease_token=lease_token,
        expected_error_code=expected_error_code,
    ):
        return
    if callback:
        raise FinanceConnectionStateError("Bank authorisation was superseded")
    raise FinanceConnectionError("Bank sync was superseded")


async def _set_connection_failure(
    db,
    *,
    connection: dict,
    status: str,
    error_code: str,
    clear_secret: bool,
    now: datetime,
    lease_token: str | None = None,
) -> None:
    async with serialized_create(db):
        await _require_current_operation(
            db,
            connection=connection,
            lease_token=lease_token,
            callback=lease_token is None,
        )
        await save_history(
            db,
            "finance_connections",
            connection["id"],
            connection["created_by"],
            family_id=connection["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        await db.execute(
            """
            UPDATE finance_connections
            SET status = ?, last_error_code = ?, callback_state_hash = NULL,
                encrypted_provider_secret_ref = CASE WHEN ? THEN NULL
                    ELSE encrypted_provider_secret_ref END,
                updated_at = ?
            WHERE id = ? AND family_id = ? AND provider = 'TRUELAYER'
              AND operation_generation = ?
              AND (? IS NULL OR sync_lease_token = ?)
              AND deleted_at IS NULL
            """,
            (
                status,
                _safe_error_code(error_code) or "PROVIDER_RESPONSE_INVALID",
                int(clear_secret),
                _utc_text(now),
                connection["id"],
                connection["family_id"],
                _operation_generation(connection),
                lease_token,
                lease_token,
            ),
        )


def _combine_discovery(
    accounts: TrueLayerAccounts,
    cards: TrueLayerAccounts,
) -> TrueLayerAccounts:
    resources = (*accounts.accounts, *cards.accounts)
    populated = [result for result in (accounts, cards) if result.accounts]
    if not resources or any(not result.provider_id for result in populated):
        raise ProviderResponseError("TrueLayer account discovery was incomplete")
    provider_ids = {result.provider_id for result in populated}
    if len(provider_ids) != 1:
        raise ProviderResponseError("TrueLayer returned resources from mixed providers")
    credentials_ids = {
        result.credentials_id
        for result in populated
        if result.credentials_id is not None
    }
    if len(credentials_ids) > 1:
        raise ProviderResponseError("TrueLayer returned mismatched credentials")
    institution_names = [
        result.institution_name
        for result in populated
        if result.institution_name.strip() and result.institution_name != "Bank"
    ]
    return TrueLayerAccounts(
        accounts=resources,
        provider_id=next(iter(provider_ids)),
        institution_name=institution_names[0] if institution_names else "Bank",
        credentials_id=next(iter(credentials_ids), None),
    )


def _encrypt_stored_credentials(stored: _StoredCredentials) -> str:
    credentials = stored.credentials
    return _encrypt_payload(
        {
            "kind": "TRUELAYER_CREDENTIALS",
            "provider": "TRUELAYER",
            "access_token": credentials.access_token,
            "refresh_token": credentials.refresh_token,
            "access_expires_at": _utc_text(credentials.access_expires_at),
            "scopes": sorted(credentials.scopes),
            "token_type": credentials.token_type,
            "provider_id": stored.provider_id,
            "credentials_id": stored.credentials_id,
        }
    )


def _decrypt_stored_credentials(value: object) -> _StoredCredentials:
    payload = _decrypt_payload(value)
    if payload.get("kind") != "TRUELAYER_CREDENTIALS" or payload.get("provider") != "TRUELAYER":
        raise FinanceConnectionError("Bank connection needs authorisation")
    scopes = payload.get("scopes")
    if not isinstance(scopes, list) or not all(isinstance(item, str) for item in scopes):
        raise FinanceConnectionError("Bank connection needs authorisation")
    try:
        credentials = TrueLayerCredentials(
            access_token=payload.get("access_token"),
            refresh_token=payload.get("refresh_token"),
            access_expires_at=_parse_utc(payload.get("access_expires_at"), "access expiry"),
            scopes=frozenset(scopes),
            token_type=payload.get("token_type"),
        )
    except (TypeError, ValueError, FinanceConnectionStateError):
        raise FinanceConnectionError("Bank connection needs authorisation") from None
    provider_id = payload.get("provider_id")
    credentials_id = payload.get("credentials_id")
    if provider_id is not None and not isinstance(provider_id, str):
        raise FinanceConnectionError("Bank connection needs authorisation")
    if credentials_id is not None and not isinstance(credentials_id, str):
        raise FinanceConnectionError("Bank connection needs authorisation")
    return _StoredCredentials(
        credentials=credentials,
        provider_id=provider_id,
        credentials_id=credentials_id,
    )


def _state_digest(state: str) -> str:
    return hashlib.sha256(state.encode()).hexdigest()


def _encrypt_payload(payload: dict) -> str:
    return encrypt_finance_provider_value(
        json.dumps(payload, sort_keys=True, separators=(",", ":"))
    )


def _decrypt_payload(value: object) -> dict:
    if not isinstance(value, str) or not value:
        raise FinanceConnectionStateError("Encrypted bank state is unavailable")
    try:
        payload = json.loads(decrypt_finance_provider_value(value))
    except Exception:
        raise FinanceConnectionStateError("Encrypted bank state is unavailable") from None
    if not isinstance(payload, dict):
        raise FinanceConnectionStateError("Encrypted bank state is unavailable")
    return payload


def _pending_client(pending: dict) -> str:
    client = pending.get("client")
    if client not in {"web", "ios"}:
        raise FinanceConnectionStateError("Bank authorisation state is invalid")
    return client


def _state_expiry(pending: dict) -> datetime:
    return _parse_utc(pending.get("expires_at"), "state expiry")


async def _record_history_window(
    db,
    *,
    user: dict,
    connection: dict,
    local_account: dict,
    date_from: date,
    lease_token: str,
    now: datetime,
) -> None:
    if local_account.get("history_synced_from_date"):
        return
    await _require_current_operation(
        db,
        connection=connection,
        lease_token=lease_token,
    )
    await save_history(
        db,
        "finance_accounts",
        local_account["id"],
        user["id"],
        family_id=user["family_id"],
    )
    await db.execute(
        "UPDATE finance_accounts SET history_synced_from_date = ?, updated_at = ? "
        "WHERE id = ? AND connection_id = ? AND space_id = ? AND family_id = ? "
        "AND history_synced_from_date IS NULL AND deleted_at IS NULL",
        (
            date_from.isoformat(),
            _utc_text(now),
            local_account["id"],
            connection["id"],
            connection["space_id"],
            user["family_id"],
        ),
    )


def _transaction_resume_date(
    value: object,
    *,
    history_synced_from_date: object,
    observed_on: date,
) -> date:
    earliest = observed_on - MAX_TRANSACTION_WINDOW
    if not history_synced_from_date:
        return earliest
    if not isinstance(history_synced_from_date, str):
        raise ValueError("Invalid transaction history date")
    date.fromisoformat(history_synced_from_date)
    if not value:
        return earliest
    if not isinstance(value, str):
        raise ValueError("Invalid transaction resume date")
    requested = date.fromisoformat(value) - SYNC_OVERLAP
    return min(observed_on, max(earliest, requested))


def _parse_utc(value: object, label: str) -> datetime:
    if not isinstance(value, str):
        raise FinanceConnectionStateError(f"Invalid {label}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise FinanceConnectionStateError(f"Invalid {label}") from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise FinanceConnectionStateError(f"Invalid {label}")
    return parsed.astimezone(timezone.utc)


def _utc_now(value: datetime | None) -> datetime:
    result = value or datetime.now(timezone.utc)
    if result.tzinfo is None or result.utcoffset() is None:
        raise ValueError("Connection clock must include a timezone")
    return result.astimezone(timezone.utc)


def _utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()
