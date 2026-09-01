"""Read-only Enable Banking consent, sync, and disconnect lifecycle."""

import hashlib
import json
import re
import secrets
import uuid
from collections.abc import Awaitable, Callable
from datetime import date, datetime, timedelta, timezone

from app.models.finance import NormalisedSourceTransaction
from app.models.finance_connection import (
    FinanceConnectedAccountResponse,
    FinanceConnectionDisconnectResponse,
    FinanceConnectionResponse,
    FinanceConnectionStartRequest,
    FinanceConnectionSyncResponse,
    FinanceDerivedRefreshResponse,
)
from app.services.finance.foundation import require_finance_space
from app.services.finance.ledger import import_source_transactions, record_balance_snapshot
from app.services.finance.money import Money
from app.services.finance.providers.base import (
    AuthorisationRequest,
    ProviderAccount,
    ProviderBalance,
    ProviderError,
    ProviderResponseError,
    ProviderTransaction,
    ProviderTransportError,
    ReadCapability,
    ReadOnlyBankProvider,
    TransactionState,
    UnsafeCapabilityError,
    require_read_capabilities,
)
from app.services.idempotency import serialized_create
from app.services.record_history import save_history
from app.utils.encryption import (
    decrypt_finance_provider_value,
    encrypt_finance_provider_value,
)

STATE_TTL = timedelta(minutes=10)
CONSENT_TTL = timedelta(days=90)
SYNC_OVERLAP = timedelta(days=7)
MAX_LEGACY_PENDING_STATES = 100
_REQUIRED_CAPABILITIES = frozenset(
    {ReadCapability.ACCOUNTS, ReadCapability.BALANCES, ReadCapability.TRANSACTIONS}
)
_CONNECTION_HISTORY_SECRET_FIELDS = {
    "encrypted_provider_secret_ref",
    "callback_state_hash",
}
_DERIVED_HOOK_ERRORS = {
    "PURCHASE_REMATCH": "PURCHASE_REMATCH_FAILED",
    "FORECAST": "FORECAST_REFRESH_FAILED",
    "PAYDAY_MATCH": "PAYDAY_MATCH_FAILED",
    "COACH_REPORT": "COACH_REPORT_REFRESH_FAILED",
}


class _DerivedRefreshFailed(RuntimeError):
    """Internal marker; exception details are never persisted or returned."""


class FinanceConnectionError(ValueError):
    """A bank connection action cannot safely proceed."""


class FinanceConnectionNotFoundError(FinanceConnectionError):
    """The caller cannot access the requested connection."""


class FinanceConnectionStateError(FinanceConnectionError):
    """A callback state is absent, expired, changed, or already consumed."""


class FinanceConnectionCapabilityError(FinanceConnectionError):
    """The provider did not grant exactly the required read capabilities."""


class FinanceConnectionProviderUnavailableError(FinanceConnectionError):
    """The read-only provider could not complete the request."""


async def start_enable_banking_connection(
    db,
    *,
    user: dict,
    body: FinanceConnectionStartRequest,
    provider: ReadOnlyBankProvider,
    callback_url: str,
    now: datetime | None = None,
) -> str:
    """Start an expiring, caller-bound read-only authorisation."""
    await require_finance_space(db, user=user, space_id=body.space_id)
    observed_at = _utc_now(now)
    state = secrets.token_urlsafe(32)
    connection_id = str(uuid.uuid4())
    started = await provider.start_authorisation(
        AuthorisationRequest(
            institution_name=body.institution_name,
            institution_country=body.institution_country,
            redirect_url=callback_url,
            state=state,
            valid_until=observed_at + CONSENT_TTL,
            requested_capabilities=frozenset(item.value for item in _REQUIRED_CAPABILITIES),
        )
    )
    encrypted_state = _encrypt_payload(
        {
            "kind": "AUTHORISATION_STATE",
            "state": state,
            "authorisation_id": started.authorisation_id,
            "user_id": user["id"],
            "space_id": body.space_id,
            "expires_at": _utc_text(observed_at + STATE_TTL),
        }
    )
    now_text = _utc_text(observed_at)
    async with serialized_create(db):
        await db.execute(
            """
            INSERT INTO finance_connections
                (id, space_id, provider, institution_id, status,
                 granted_capabilities, last_error_code,
                 encrypted_provider_secret_ref, callback_state_hash, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, 'ENABLE_BANKING', ?, 'REAUTH_REQUIRED', ?,
                    'AUTHORISATION_PENDING', ?, ?, ?, ?, ?, ?)
            """,
            (
                connection_id,
                body.space_id,
                _institution_key(body.institution_name, body.institution_country),
                _capabilities_json(_REQUIRED_CAPABILITIES),
                encrypted_state,
                _state_digest(state),
                user["family_id"],
                now_text,
                now_text,
                user["id"],
            ),
        )
    return started.redirect_url


async def complete_enable_banking_callback(
    db,
    *,
    state: str,
    code: str,
    provider: ReadOnlyBankProvider,
    now: datetime | None = None,
) -> FinanceConnectionResponse:
    """Consume one matching state and retain only an encrypted read session."""
    observed_at = _utc_now(now)
    connection, pending, user = await _connection_for_state(
        db,
        state=state,
        observed_at=observed_at,
    )
    expires_at = _parse_utc(pending.get("expires_at"), label="state expiry")
    if expires_at <= observed_at:
        await _set_connection_failure(
            db,
            connection=connection,
            status="EXPIRED",
            error_code="AUTHORISATION_STATE_EXPIRED",
            clear_secret=True,
            now=observed_at,
        )
        raise FinanceConnectionStateError("Bank authorisation state has expired")

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
              AND status = 'REAUTH_REQUIRED'
              AND last_error_code = 'AUTHORISATION_PENDING' AND deleted_at IS NULL
            """,
            (
                _utc_text(observed_at),
                connection["id"],
                user["family_id"],
                user["id"],
            ),
        )
        if claimed.rowcount != 1:
            raise FinanceConnectionStateError("Bank authorisation state was already used")

    try:
        session = await provider.exchange_code(code)
        granted_values = frozenset(
            item.value if isinstance(item, ReadCapability) else str(item)
            for item in session.granted_capabilities
        )
        granted = require_read_capabilities(granted_values)
        if granted != _REQUIRED_CAPABILITIES:
            raise UnsafeCapabilityError(
                "Accounts, balances, and transactions must all be read-only"
            )
        if (
            _institution_key(
                session.institution_name,
                session.institution_country,
            )
            != connection["institution_id"]
        ):
            raise ProviderResponseError("Provider returned a different institution")
    except UnsafeCapabilityError as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="REAUTH_REQUIRED",
            error_code="CAPABILITY_MISMATCH",
            clear_secret=True,
            now=observed_at,
        )
        raise FinanceConnectionCapabilityError(
            "Provider consent was not restricted to the required read access"
        ) from exc
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
            "Enable Banking could not complete authorisation"
        ) from exc

    encrypted_session = _encrypt_payload(
        {
            "kind": "PROVIDER_SESSION",
            "provider": "ENABLE_BANKING",
            "provider_session_id": session.provider_session_id,
        }
    )
    now_text = _utc_text(observed_at)
    async with serialized_create(db):
        account_issues = await _upsert_accounts(
            db,
            connection=connection,
            accounts=session.accounts,
            user=user,
            institution=session.institution_name,
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
            SET status = ?, granted_capabilities = ?, consent_created_at = ?,
                consent_expires_at = ?, last_error_code = ?,
                encrypted_provider_secret_ref = ?, updated_at = ?
            WHERE id = ? AND family_id = ? AND created_by = ? AND deleted_at IS NULL
            """,
            (
                "PARTIAL" if account_issues else "CONNECTED",
                _capabilities_json(granted),
                now_text,
                _utc_text(session.valid_until),
                _safe_error_code(sorted(account_issues)[0] if account_issues else None),
                encrypted_session,
                now_text,
                connection["id"],
                user["family_id"],
                user["id"],
            ),
        )
    return await read_enable_banking_connection(
        db,
        user=user,
        connection_id=connection["id"],
    )


async def cancel_enable_banking_callback(
    db,
    *,
    state: str,
    now: datetime | None = None,
) -> None:
    """Consume a declined/cancelled state without retaining provider material."""
    observed_at = _utc_now(now)
    connection, pending, _ = await _connection_for_state(
        db,
        state=state,
        observed_at=observed_at,
    )
    expires_at = _parse_utc(pending.get("expires_at"), label="state expiry")
    if expires_at <= observed_at:
        await _set_connection_failure(
            db,
            connection=connection,
            status="EXPIRED",
            error_code="AUTHORISATION_STATE_EXPIRED",
            clear_secret=True,
            now=observed_at,
        )
        raise FinanceConnectionStateError("Bank authorisation state has expired")
    await _set_connection_failure(
        db,
        connection=connection,
        status="REAUTH_REQUIRED",
        error_code="AUTHORISATION_CANCELLED",
        clear_secret=True,
        now=observed_at,
    )


async def list_enable_banking_connections(
    db,
    *,
    user: dict,
    space_id: str,
) -> list[FinanceConnectionResponse]:
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_connections
            WHERE space_id = ? AND family_id = ? AND provider = 'ENABLE_BANKING'
              AND deleted_at IS NULL
            ORDER BY created_at DESC, id DESC
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [
        await _connection_response(db, dict(row), viewer_user_id=user["id"])
        for row in rows
    ]


async def list_bank_connections(
    db,
    *,
    user: dict,
    space_id: str,
) -> list[FinanceConnectionResponse]:
    """List supported bank connections without configuring either provider."""
    await require_finance_space(db, user=user, space_id=space_id)
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_connections
            WHERE space_id = ? AND family_id = ?
              AND provider IN ('ENABLE_BANKING', 'TRUELAYER')
              AND NOT (
                  provider = 'TRUELAYER'
                  AND last_error_code IN (
                      'AUTHORISATION_PENDING', 'AUTHORISATION_CANCELLED'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM finance_accounts account
                      WHERE account.connection_id = finance_connections.id
                        AND account.deleted_at IS NULL
                  )
              )
              AND deleted_at IS NULL
            ORDER BY created_at DESC, id DESC
            """,
            (space_id, user["family_id"]),
        )
    ).fetchall()
    return [
        await _connection_response(db, dict(row), viewer_user_id=user["id"])
        for row in rows
    ]


async def read_enable_banking_connection(
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
    return await _connection_response(db, connection, viewer_user_id=user["id"])


async def sync_enable_banking_connection(
    db,
    *,
    user: dict,
    connection_id: str,
    provider: ReadOnlyBankProvider,
    now: datetime | None = None,
    automated: bool = False,
) -> FinanceConnectionSyncResponse:
    """Run one mutually-exclusive sync with a bounded retry delay."""
    observed_at = _utc_now(now)
    connection = await _authorised_connection(
        db, user=user, connection_id=connection_id
    )
    lease_token = secrets.token_urlsafe(24)
    lease_until = observed_at + timedelta(minutes=30)
    async with serialized_create(db):
        claimed = await db.execute(
            "UPDATE finance_connections SET sync_lease_token = ?, "
            "sync_lease_expires_at = ?, updated_at = ? WHERE id = ? AND family_id = ? "
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
        result = await _perform_enable_banking_sync(
            db,
            user=user,
            connection_id=connection_id,
            provider=provider,
            now=observed_at,
        )
    except Exception:
        current = await (
            await db.execute(
                "SELECT consecutive_sync_failures FROM finance_connections "
                "WHERE id = ? AND family_id = ?",
                (connection_id, user["family_id"]),
            )
        ).fetchone()
        failures = min(20, int(current[0] if current else 0) + 1)
        retry_minutes = min(360, 5 * (2 ** min(failures - 1, 6)))
        async with serialized_create(db):
            await db.execute(
                "UPDATE finance_connections SET sync_lease_token = NULL, "
                "sync_lease_expires_at = NULL, consecutive_sync_failures = ?, "
                "next_retry_at = ?, updated_at = ? WHERE id = ? AND family_id = ? "
                "AND sync_lease_token = ? AND deleted_at IS NULL",
                (
                    failures,
                    _utc_text(observed_at + timedelta(minutes=retry_minutes)),
                    _utc_text(observed_at),
                    connection_id,
                    user["family_id"],
                    lease_token,
                ),
            )
        raise
    async with serialized_create(db):
        await db.execute(
            "UPDATE finance_connections SET sync_lease_token = NULL, "
            "sync_lease_expires_at = NULL, next_retry_at = NULL, "
            "consecutive_sync_failures = 0 WHERE id = ? AND family_id = ? "
            "AND sync_lease_token = ? AND deleted_at IS NULL",
            (connection_id, user["family_id"], lease_token),
        )
    if any(
        (
            result.balances_created,
            result.canonical_created,
            result.pending_superseded,
        )
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


async def _after_material_bank_sync(
    db,
    *,
    user: dict,
    space_id: str,
    connection_id: str,
    now: datetime,
) -> None:
    """Refresh saved results and persist a bounded outcome for every hook."""
    from app.models.finance import FinanceForecastGenerate
    from app.services.finance.coaching import match_payday_actions, refresh_coaching_report
    from app.services.finance.planning import generate_forecast
    from app.services.finance.purchase_evidence import rematch_unmatched_purchases

    async def rematch() -> None:
        await rematch_unmatched_purchases(db, user=user, space_id=space_id)

    async def forecasts() -> None:
        currencies = await (
            await db.execute(
                "SELECT DISTINCT currency FROM finance_accounts WHERE space_id = ? "
                "AND family_id = ? AND provider_presence_status = 'ACTIVE' "
                "AND include_in_cashflow = 1 AND deleted_at IS NULL ORDER BY currency",
                (space_id, user["family_id"]),
            )
        ).fetchall()
        failed = False
        for currency_row in currencies:
            currency = currency_row["currency"]
            latest = await (
                await db.execute(
                    "SELECT end_date, household_buffer_minor FROM finance_forecast_snapshots "
                    "WHERE space_id = ? AND family_id = ? AND currency = ? "
                    "AND deleted_at IS NULL ORDER BY created_at DESC, id DESC LIMIT 1",
                    (space_id, user["family_id"], currency),
                )
            ).fetchone()
            end_date = now.date() + timedelta(days=90)
            buffer_minor = 0
            if latest is not None:
                end_date = max(end_date, date.fromisoformat(latest["end_date"]))
                buffer_minor = latest["household_buffer_minor"]
            try:
                await generate_forecast(
                    db,
                    user=user,
                    space_id=space_id,
                    body=FinanceForecastGenerate(
                        end_date=end_date,
                        currency=currency,
                        household_buffer_minor=buffer_minor,
                    ),
                )
            except Exception:
                failed = True
        if failed:
            raise _DerivedRefreshFailed

    async def payday() -> None:
        await match_payday_actions(db, user=user, space_id=space_id, as_of=now.date())

    async def coach() -> None:
        await refresh_coaching_report(
            db,
            user=user,
            space_id=space_id,
            report_kind="DRIFT",
            as_of=now.date(),
        )

    hooks: tuple[tuple[str, Callable[[], Awaitable[None]]], ...] = (
        ("PURCHASE_REMATCH", rematch),
        ("FORECAST", forecasts),
        ("PAYDAY_MATCH", payday),
        ("COACH_REPORT", coach),
    )
    for hook_kind, operation in hooks:
        succeeded = True
        try:
            await operation()
        except Exception:
            succeeded = False
        await _record_derived_refresh(
            db,
            user=user,
            connection_id=connection_id,
            space_id=space_id,
            hook_kind=hook_kind,
            succeeded=succeeded,
            attempted_at=now,
        )


async def _record_derived_refresh(
    db,
    *,
    user: dict,
    connection_id: str,
    space_id: str,
    hook_kind: str,
    succeeded: bool,
    attempted_at: datetime,
) -> None:
    """Upsert one operational outcome without storing exception or Finance data."""
    error_code = None if succeeded else _DERIVED_HOOK_ERRORS[hook_kind]
    attempted_text = _utc_text(attempted_at)
    async with serialized_create(db):
        existing = await (
            await db.execute(
                "SELECT * FROM finance_connection_derived_refreshes "
                "WHERE connection_id = ? AND hook_kind = ? AND space_id = ? "
                "AND family_id = ? AND deleted_at IS NULL",
                (connection_id, hook_kind, space_id, user["family_id"]),
            )
        ).fetchone()
        if existing is None:
            await db.execute(
                """
                INSERT INTO finance_connection_derived_refreshes
                    (id, space_id, connection_id, hook_kind, status,
                     last_attempt_at, last_success_at, last_error_code,
                     family_id, created_at, updated_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    space_id,
                    connection_id,
                    hook_kind,
                    "SUCCEEDED" if succeeded else "FAILED",
                    attempted_text,
                    attempted_text if succeeded else None,
                    error_code,
                    user["family_id"],
                    attempted_text,
                    attempted_text,
                    user["id"],
                ),
            )
            return
        await save_history(
            db,
            "finance_connection_derived_refreshes",
            existing["id"],
            user["id"],
            family_id=user["family_id"],
        )
        await db.execute(
            """
            UPDATE finance_connection_derived_refreshes
            SET status = ?, last_attempt_at = ?,
                last_success_at = CASE WHEN ? = 1 THEN ? ELSE last_success_at END,
                last_error_code = ?, updated_at = ?
            WHERE id = ? AND connection_id = ? AND space_id = ?
              AND family_id = ? AND deleted_at IS NULL
            """,
            (
                "SUCCEEDED" if succeeded else "FAILED",
                attempted_text,
                int(succeeded),
                attempted_text,
                error_code,
                attempted_text,
                existing["id"],
                connection_id,
                space_id,
                user["family_id"],
            ),
        )


async def _derived_refresh_responses(
    db,
    *,
    connection_id: str,
    space_id: str,
    family_id: str,
) -> list[FinanceDerivedRefreshResponse]:
    rows = await (
        await db.execute(
            """
            SELECT hook_kind, status, last_attempt_at, last_success_at, last_error_code
            FROM finance_connection_derived_refreshes
            WHERE connection_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY CASE hook_kind
                WHEN 'PURCHASE_REMATCH' THEN 1 WHEN 'FORECAST' THEN 2
                WHEN 'PAYDAY_MATCH' THEN 3 WHEN 'COACH_REPORT' THEN 4 ELSE 5 END
            """,
            (connection_id, space_id, family_id),
        )
    ).fetchall()
    return [
        FinanceDerivedRefreshResponse(
            hook=row["hook_kind"],
            status=row["status"],
            last_attempt_at=row["last_attempt_at"],
            last_success_at=row["last_success_at"],
            last_error_code=row["last_error_code"],
        )
        for row in rows
    ]


async def sync_due_enable_banking_connections(
    db,
    *,
    provider: ReadOnlyBankProvider,
    now: datetime | None = None,
) -> int:
    """Sync each due owner-bound connection without one failure stopping another."""
    observed_at = _utc_now(now)
    rows = await (
        await db.execute(
            "SELECT connection.*, user.id AS owner_id "
            "FROM finance_connections connection JOIN users user "
            "ON user.id = connection.created_by AND user.family_id = connection.family_id "
            "AND user.deleted_at IS NULL WHERE connection.provider = 'ENABLE_BANKING' "
            "AND connection.status IN ('CONNECTED', 'PARTIAL', 'PROVIDER_DOWN') "
            "AND (connection.next_retry_at IS NULL OR connection.next_retry_at <= ?) "
            "AND (connection.sync_lease_expires_at IS NULL "
            "OR connection.sync_lease_expires_at <= ?) AND connection.deleted_at IS NULL "
            "ORDER BY connection.last_success_at, connection.id",
            (_utc_text(observed_at), _utc_text(observed_at)),
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
            await sync_enable_banking_connection(
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


async def _perform_enable_banking_sync(
    db,
    *,
    user: dict,
    connection_id: str,
    provider: ReadOnlyBankProvider,
    now: datetime | None = None,
) -> FinanceConnectionSyncResponse:
    """Fetch read-only metadata and pages, then import valid dated rows once."""
    observed_at = _utc_now(now)
    connection = await _authorised_connection(
        db,
        user=user,
        connection_id=connection_id,
    )
    if connection["status"] not in {"CONNECTED", "PARTIAL", "PROVIDER_DOWN"}:
        raise FinanceConnectionError("Bank connection needs authorisation before sync")
    provider_session_id = _provider_session_id(connection)
    capabilities = _read_capabilities(connection["granted_capabilities"])
    if capabilities != _REQUIRED_CAPABILITIES:
        raise FinanceConnectionCapabilityError(
            "Bank connection does not have the required read capabilities"
        )

    try:
        renewal = await provider.renewal_metadata(provider_session_id)
        if renewal.valid_until <= observed_at:
            await _set_connection_failure(
                db,
                connection=connection,
                status="EXPIRED",
                error_code="CONSENT_EXPIRED",
                clear_secret=False,
                now=observed_at,
            )
            raise FinanceConnectionError("Bank consent has expired")
        if renewal.status.upper() not in {"AUTHORIZED", "VALID", "CONNECTED"}:
            await _set_connection_failure(
                db,
                connection=connection,
                status="REAUTH_REQUIRED",
                error_code="CONSENT_REAUTH_REQUIRED",
                clear_secret=False,
                now=observed_at,
            )
            raise FinanceConnectionError("Bank consent needs authorisation")
        provider_accounts = await provider.accounts(provider_session_id)
    except ProviderTransportError as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="PROVIDER_DOWN",
            error_code="PROVIDER_UNAVAILABLE",
            clear_secret=False,
            now=observed_at,
        )
        raise FinanceConnectionProviderUnavailableError(
            "Enable Banking is temporarily unavailable"
        ) from exc
    except FinanceConnectionError:
        raise
    except (ProviderError, ValueError) as exc:
        await _set_connection_failure(
            db,
            connection=connection,
            status="PARTIAL",
            error_code="PROVIDER_RESPONSE_INVALID",
            clear_secret=False,
            now=observed_at,
        )
        raise FinanceConnectionProviderUnavailableError(
            "Enable Banking returned an unusable response"
        ) from exc

    now_text = _utc_text(observed_at)
    async with serialized_create(db):
        account_issues = await _upsert_accounts(
            db,
            connection=connection,
            accounts=provider_accounts,
            user=user,
            institution=_institution_name(connection["institution_id"]),
            now_text=now_text,
        )
        if not account_issues:
            await _retire_omitted_provider_accounts(
                db,
                connection=connection,
                provider_account_ids={
                    account.provider_account_id
                    for account in provider_accounts
                    if account.provider_account_id is not None
                },
                user=user,
                now_text=now_text,
            )
    local_accounts = await _provider_account_rows(db, connection=connection)
    issues = set(account_issues)
    balances_created = 0
    source_created = 0
    canonical_created = 0
    duplicates = 0
    pending_superseded = 0
    latest_booking: date | None = None

    for provider_account in provider_accounts:
        provider_account_id = provider_account.provider_account_id
        local_account = local_accounts.get(provider_account_id or "")
        if provider_account_id is None or local_account is None:
            continue
        if provider_account.currency != local_account["currency"]:
            issues.add("ACCOUNT_CURRENCY_MISMATCH")
            continue
        try:
            balances = await provider.balances(provider_account_id)
        except ProviderTransportError as exc:
            await _set_connection_failure(
                db,
                connection=connection,
                status="PROVIDER_DOWN",
                error_code="PROVIDER_UNAVAILABLE",
                clear_secret=False,
                now=observed_at,
            )
            raise FinanceConnectionProviderUnavailableError(
                "Enable Banking is temporarily unavailable"
            ) from exc
        except ProviderError:
            issues.add("BALANCE_FETCH_FAILED")
        else:
            created, balance_issues = await _record_provider_balance(
                db,
                user=user,
                connection=connection,
                local_account=local_account,
                balances=balances,
                observed_at=observed_at,
            )
            balances_created += int(created)
            issues.update(balance_issues)

        date_from = (
            date.fromisoformat(local_account["fresh_through_date"]) - SYNC_OVERLAP
            if local_account["fresh_through_date"]
            else None
        )
        observations: list[NormalisedSourceTransaction] = []
        for transaction_state in (TransactionState.BOOKED, TransactionState.PENDING):
            try:
                pages = await provider.transaction_pages(
                    provider_account_id,
                    state=transaction_state,
                    date_from=date_from,
                    date_to=observed_at.date(),
                )
            except ProviderTransportError as exc:
                await _set_connection_failure(
                    db,
                    connection=connection,
                    status="PROVIDER_DOWN",
                    error_code="PROVIDER_UNAVAILABLE",
                    clear_secret=False,
                    now=observed_at,
                )
                raise FinanceConnectionProviderUnavailableError(
                    "Enable Banking is temporarily unavailable"
                ) from exc
            except ProviderError:
                issues.add(f"{transaction_state.value.upper()}_FETCH_FAILED")
                continue
            if pages.truncated:
                issues.add(f"{transaction_state.value.upper()}_PAGINATION_TRUNCATED")
            for page in pages.pages:
                for provider_transaction in page.transactions:
                    observation, issue = _normalise_provider_transaction(
                        provider_transaction,
                        connection_id=connection_id,
                        account_currency=local_account["currency"],
                        observed_at=observed_at,
                    )
                    if issue:
                        issues.add(issue)
                    elif observation:
                        observations.append(observation)
                        latest_booking = max(
                            latest_booking or observation.booking_date,
                            observation.booking_date,
                        )
        imported = await import_source_transactions(
            db,
            user=user,
            space_id=connection["space_id"],
            account_id=local_account["id"],
            observations=observations,
        )
        source_created += imported.source_created
        canonical_created += imported.canonical_created
        duplicates += imported.duplicates
        pending_superseded += imported.pending_superseded

    status = "PARTIAL" if issues else "CONNECTED"
    async with serialized_create(db):
        await save_history(
            db,
            "finance_connections",
            connection_id,
            user["id"],
            family_id=user["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        await db.execute(
            """
            UPDATE finance_connections
            SET status = ?, consent_expires_at = ?, last_success_at = ?,
                last_error_code = ?,
                data_through_at = CASE
                    WHEN ? IS NULL THEN data_through_at
                    WHEN data_through_at IS NULL OR data_through_at < ? THEN ?
                    ELSE data_through_at END,
                updated_at = ?
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                status,
                _utc_text(renewal.valid_until),
                now_text,
                _safe_error_code(sorted(issues)[0] if issues else None),
                latest_booking.isoformat() if latest_booking else None,
                latest_booking.isoformat() if latest_booking else None,
                latest_booking.isoformat() if latest_booking else None,
                now_text,
                connection_id,
                user["family_id"],
            ),
        )
    return FinanceConnectionSyncResponse(
        connection_id=connection_id,
        status=status,
        accounts_seen=len(provider_accounts),
        balances_created=balances_created,
        source_created=source_created,
        canonical_created=canonical_created,
        duplicates=duplicates,
        pending_superseded=pending_superseded,
        partial_issue_codes=sorted(issues),
    )


async def disconnect_enable_banking_connection(
    db,
    *,
    user: dict,
    connection_id: str,
    now: datetime | None = None,
) -> FinanceConnectionDisconnectResponse:
    """Forget session material while keeping imported history readable."""
    observed_at = _utc_now(now)
    await _authorised_connection(
        db,
        user=user,
        connection_id=connection_id,
    )
    now_text = _utc_text(observed_at)
    async with serialized_create(db):
        await save_history(
            db,
            "finance_connections",
            connection_id,
            user["id"],
            family_id=user["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        await db.execute(
            """
            UPDATE finance_connections
            SET status = 'DISCONNECTED', encrypted_provider_secret_ref = NULL,
                callback_state_hash = NULL, sync_lease_token = NULL,
                sync_lease_expires_at = NULL, next_retry_at = NULL,
                consecutive_sync_failures = 0,
                operation_generation = operation_generation + 1,
                last_error_code = NULL, updated_at = ?
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (now_text, connection_id, user["family_id"]),
        )
    return FinanceConnectionDisconnectResponse(id=connection_id, status="DISCONNECTED")


async def bank_connection_provider(
    db,
    *,
    user: dict,
    connection_id: str,
) -> str:
    """Return an authorised row's provider without constructing a provider client."""
    connection = await _authorised_bank_connection(
        db,
        user=user,
        connection_id=connection_id,
    )
    if connection["status"] not in {"CONNECTED", "PARTIAL", "PROVIDER_DOWN"}:
        raise FinanceConnectionError("Bank connection needs authorisation before sync")
    return connection["provider"]


async def disconnect_bank_connection(
    db,
    *,
    user: dict,
    connection_id: str,
    now: datetime | None = None,
) -> FinanceConnectionDisconnectResponse:
    """Forget either provider's encrypted material while retaining imported history."""
    observed_at = _utc_now(now)
    await _authorised_bank_connection(
        db,
        user=user,
        connection_id=connection_id,
    )
    async with serialized_create(db):
        await save_history(
            db,
            "finance_connections",
            connection_id,
            user["id"],
            family_id=user["family_id"],
            excluded_fields=_CONNECTION_HISTORY_SECRET_FIELDS,
        )
        await db.execute(
            """
            UPDATE finance_connections
            SET status = 'DISCONNECTED', encrypted_provider_secret_ref = NULL,
                callback_state_hash = NULL, sync_lease_token = NULL,
                sync_lease_expires_at = NULL, next_retry_at = NULL,
                consecutive_sync_failures = 0,
                operation_generation = operation_generation + 1,
                last_error_code = NULL, updated_at = ?
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (_utc_text(observed_at), connection_id, user["family_id"]),
        )
    return FinanceConnectionDisconnectResponse(id=connection_id, status="DISCONNECTED")


async def _connection_for_state(
    db,
    *,
    state: str,
    observed_at: datetime,
) -> tuple[dict, dict, dict]:
    digest = _state_digest(state)
    rows = list(
        await (
            await db.execute(
                """
                SELECT * FROM finance_connections
                WHERE callback_state_hash = ? AND provider = 'ENABLE_BANKING'
                  AND status = 'REAUTH_REQUIRED'
                  AND last_error_code = 'AUTHORISATION_PENDING'
                  AND deleted_at IS NULL
                LIMIT 1
                """,
                (digest,),
            )
        ).fetchall()
    )
    # A state started just before this migration has no digest. Keep those
    # short-lived rows usable during rollout, then all new callbacks use the index.
    rows.extend(
        await (
            await db.execute(
                """
                SELECT * FROM finance_connections
                WHERE callback_state_hash IS NULL AND provider = 'ENABLE_BANKING'
                  AND status = 'REAUTH_REQUIRED'
                  AND last_error_code = 'AUTHORISATION_PENDING'
                  AND created_at >= ?
                  AND deleted_at IS NULL
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (
                    _utc_text(observed_at - STATE_TTL),
                    MAX_LEGACY_PENDING_STATES,
                ),
            )
        ).fetchall()
    )
    for source in rows:
        connection = dict(source)
        try:
            pending = _decrypt_payload(connection["encrypted_provider_secret_ref"])
        except FinanceConnectionStateError:
            continue
        if not (
            pending.get("kind") == "AUTHORISATION_STATE"
            and pending.get("user_id") == connection["created_by"]
            and pending.get("space_id") == connection["space_id"]
            and isinstance(pending.get("state"), str)
            and secrets.compare_digest(pending["state"], state)
        ):
            continue
        owner = await (
            await db.execute(
                "SELECT * FROM users WHERE id = ? AND family_id = ? "
                "AND deleted_at IS NULL",
                (connection["created_by"], connection["family_id"]),
            )
        ).fetchone()
        if owner is None:
            continue
        user = dict(owner)
        await require_finance_space(db, user=user, space_id=connection["space_id"])
        return connection, pending, user
    raise FinanceConnectionStateError("Bank authorisation state is invalid or already used")


async def _authorised_connection(db, *, user: dict, connection_id: str) -> dict:
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_connections
            WHERE id = ? AND family_id = ? AND provider = 'ENABLE_BANKING'
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


async def _authorised_bank_connection(db, *, user: dict, connection_id: str) -> dict:
    row = await (
        await db.execute(
            """
            SELECT * FROM finance_connections
            WHERE id = ? AND family_id = ?
              AND created_by = ?
              AND provider IN ('ENABLE_BANKING', 'TRUELAYER')
              AND deleted_at IS NULL
            """,
            (connection_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FinanceConnectionNotFoundError("Finance connection not found")
    connection = dict(row)
    await require_finance_space(db, user=user, space_id=connection["space_id"])
    return connection


async def _set_connection_failure(
    db,
    *,
    connection: dict,
    status: str,
    error_code: str,
    clear_secret: bool,
    now: datetime,
) -> None:
    error_code = _safe_error_code(error_code) or "PROVIDER_RESPONSE_INVALID"
    async with serialized_create(db):
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
            SET status = ?, last_error_code = ?,
                callback_state_hash = NULL,
                encrypted_provider_secret_ref = CASE WHEN ? THEN NULL
                    ELSE encrypted_provider_secret_ref END,
                updated_at = ?
            WHERE id = ? AND family_id = ? AND deleted_at IS NULL
            """,
            (
                status,
                error_code,
                int(clear_secret),
                _utc_text(now),
                connection["id"],
                connection["family_id"],
            ),
        )


async def _upsert_accounts(
    db,
    *,
    connection: dict,
    accounts: tuple[ProviderAccount, ...],
    user: dict,
    institution: str,
    now_text: str,
) -> set[str]:
    issues: set[str] = set()
    for provider_account in accounts:
        provider_id = provider_account.provider_account_id
        resource_type = provider_account.provider_resource_type
        account_type = _account_type(provider_account.account_type)
        if (
            provider_id is None
            or account_type is None
            or resource_type not in {"ACCOUNT", "CARD"}
        ):
            issues.add("UNSUPPORTED_ACCOUNT_METADATA")
            continue
        existing = await (
            await db.execute(
                """
                SELECT * FROM finance_accounts
                WHERE connection_id = ? AND provider_account_id = ?
                  AND space_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (
                    connection["id"],
                    provider_id,
                    connection["space_id"],
                    user["family_id"],
                ),
            )
        ).fetchone()
        label = (
            provider_account.display_name or provider_account.product or f"{institution} account"
        ).strip()[:120]
        last_four = _last_four(provider_account.masked_identifier)
        if existing:
            if existing["currency"] != provider_account.currency:
                issues.add("ACCOUNT_CURRENCY_CHANGED")
                continue
            if existing["provider_resource_type"] != resource_type:
                issues.add("ACCOUNT_RESOURCE_TYPE_CHANGED")
                continue
            await save_history(
                db,
                "finance_accounts",
                existing["id"],
                user["id"],
                family_id=user["family_id"],
            )
            restored = None
            if existing["provider_presence_status"] == "OMITTED":
                try:
                    candidate = json.loads(existing["provider_previous_settings_json"] or "{}")
                except (TypeError, json.JSONDecodeError):
                    candidate = {}
                restored = {
                    "purpose": candidate.get("purpose", _default_purpose(account_type)),
                    "include_in_cashflow": int(bool(candidate.get("include_in_cashflow", True))),
                    "include_in_net_worth": int(bool(candidate.get("include_in_net_worth", True))),
                    "primary_spending_account": int(bool(candidate.get("primary_spending_account", False))),
                }
                if restored["purpose"] not in {
                    "OPERATING_CURRENT", "SAVINGS", "CREDIT_CARD", "GOAL",
                    "IGNORED", "INVESTMENT_LIKE",
                }:
                    restored["purpose"] = _default_purpose(account_type)
                if restored["primary_spending_account"]:
                    other_default = await (
                        await db.execute(
                            "SELECT 1 FROM finance_accounts WHERE space_id = ? "
                            "AND family_id = ? AND currency = ? AND id <> ? "
                            "AND primary_spending_account = 1 AND deleted_at IS NULL LIMIT 1",
                            (
                                connection["space_id"], user["family_id"],
                                provider_account.currency, existing["id"],
                            ),
                        )
                    ).fetchone()
                    if other_default is not None:
                        restored["primary_spending_account"] = 0
            await db.execute(
                """
                UPDATE finance_accounts
                SET institution = ?, account_type = ?, provider_resource_type = ?,
                    last_four = ?,
                    purpose = COALESCE(?, purpose),
                    include_in_cashflow = COALESCE(?, include_in_cashflow),
                    include_in_net_worth = COALESCE(?, include_in_net_worth),
                    primary_spending_account = COALESCE(?, primary_spending_account),
                    provider_presence_status = 'ACTIVE', provider_omitted_at = NULL,
                    provider_previous_settings_json = NULL, updated_at = ?
                WHERE id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
                """,
                (
                    institution[:120],
                    account_type,
                    resource_type,
                    last_four,
                    restored["purpose"] if restored else None,
                    restored["include_in_cashflow"] if restored else None,
                    restored["include_in_net_worth"] if restored else None,
                    restored["primary_spending_account"] if restored else None,
                    now_text,
                    existing["id"],
                    connection["space_id"],
                    user["family_id"],
                ),
            )
            continue
        await db.execute(
            """
            INSERT INTO finance_accounts
                (id, space_id, connection_id, provider_account_id,
                 provider_resource_type, label,
                 institution, account_type, purpose, currency, last_four, family_id,
                 created_at, updated_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                connection["space_id"],
                connection["id"],
                provider_id,
                resource_type,
                label,
                institution[:120],
                account_type,
                _default_purpose(account_type),
                provider_account.currency,
                last_four,
                user["family_id"],
                now_text,
                now_text,
                user["id"],
            ),
        )
    return issues


async def _retire_omitted_provider_accounts(
    db,
    *,
    connection: dict,
    provider_account_ids: set[str],
    user: dict,
    now_text: str,
) -> int:
    """Exclude only accounts absent from a complete, validated provider list."""
    rows = await (
        await db.execute(
            "SELECT * FROM finance_accounts WHERE connection_id = ? AND space_id = ? "
            "AND family_id = ? AND provider_account_id IS NOT NULL "
            "AND provider_presence_status = 'ACTIVE' AND deleted_at IS NULL",
            (connection["id"], connection["space_id"], user["family_id"]),
        )
    ).fetchall()
    omitted = [row for row in rows if row["provider_account_id"] not in provider_account_ids]
    for row in omitted:
        await save_history(
            db,
            "finance_accounts",
            row["id"],
            user["id"],
            family_id=user["family_id"],
        )
        previous = json.dumps(
            {
                "purpose": row["purpose"],
                "include_in_cashflow": bool(row["include_in_cashflow"]),
                "include_in_net_worth": bool(row["include_in_net_worth"]),
                "primary_spending_account": bool(row["primary_spending_account"]),
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        await db.execute(
            "UPDATE finance_accounts SET purpose = 'IGNORED', include_in_cashflow = 0, "
            "include_in_net_worth = 0, primary_spending_account = 0, "
            "provider_presence_status = 'OMITTED', provider_omitted_at = ?, "
            "provider_previous_settings_json = ?, updated_at = ? "
            "WHERE id = ? AND connection_id = ? AND family_id = ? "
            "AND provider_presence_status = 'ACTIVE' AND deleted_at IS NULL",
            (
                now_text, previous, now_text, row["id"], connection["id"],
                user["family_id"],
            ),
        )
    return len(omitted)


async def _provider_account_rows(db, *, connection: dict) -> dict[str, dict]:
    rows = await (
        await db.execute(
            """
            SELECT * FROM finance_accounts
            WHERE connection_id = ? AND space_id = ? AND family_id = ?
              AND provider_account_id IS NOT NULL AND deleted_at IS NULL
            """,
            (connection["id"], connection["space_id"], connection["family_id"]),
        )
    ).fetchall()
    return {row["provider_account_id"]: dict(row) for row in rows}


async def _record_provider_balance(
    db,
    *,
    user: dict,
    connection: dict,
    local_account: dict,
    balances: tuple[ProviderBalance, ...],
    observed_at: datetime,
) -> tuple[bool, set[str]]:
    issues: set[str] = set()
    matching = [balance for balance in balances if balance.currency == local_account["currency"]]
    if len(matching) != len(balances):
        issues.add("BALANCE_CURRENCY_MISMATCH")
    booked = _balance_with_type(matching, {"CLBD", "ITBD", "BOOKED", "CLOSINGBOOKED"})
    available = _balance_with_type(matching, {"CLAV", "ITAV", "AVAILABLE"})
    credit = _balance_with_type(matching, {"CRDL", "CREDITLIMIT"})
    if booked is None:
        issues.add("MISSING_BOOKED_BALANCE")
        return False, issues
    try:
        booked_minor = Money.from_major(booked.amount, booked.currency).minor_units
        available_minor = (
            Money.from_major(available.amount, available.currency).minor_units
            if available
            else None
        )
        credit_minor = (
            Money.from_major(credit.amount, credit.currency).minor_units if credit else None
        )
    except ValueError:
        issues.add("INEXACT_BALANCE_AMOUNT")
        return False, issues
    provider_at = booked.changed_at
    latest = await (
        await db.execute(
            """
            SELECT booked_minor, available_minor, credit_limit_minor, currency, provider_at
            FROM finance_balance_snapshots
            WHERE account_id = ? AND space_id = ? AND family_id = ? AND deleted_at IS NULL
            ORDER BY observed_at DESC, id DESC LIMIT 1
            """,
            (local_account["id"], connection["space_id"], user["family_id"]),
        )
    ).fetchone()
    provider_at_text = _utc_text(provider_at) if provider_at else None
    if latest and (
        latest["booked_minor"],
        latest["available_minor"],
        latest["credit_limit_minor"],
        latest["currency"],
        latest["provider_at"],
    ) == (
        booked_minor,
        available_minor,
        credit_minor,
        booked.currency,
        provider_at_text,
    ):
        return False, issues
    await record_balance_snapshot(
        db,
        user=user,
        space_id=connection["space_id"],
        account_id=local_account["id"],
        booked_minor=booked_minor,
        available_minor=available_minor,
        credit_limit_minor=credit_minor,
        currency=booked.currency,
        observed_at=observed_at,
        provider_at=provider_at,
    )
    return True, issues


def _normalise_provider_transaction(
    transaction: ProviderTransaction,
    *,
    connection_id: str,
    account_currency: str,
    observed_at: datetime,
) -> tuple[NormalisedSourceTransaction | None, str | None]:
    if transaction.booking_date is None:
        return None, "MISSING_PROVIDER_BOOKING_DATE"
    if transaction.currency != account_currency:
        return None, "TRANSACTION_CURRENCY_MISMATCH"
    try:
        amount_minor = Money.from_major(transaction.amount, transaction.currency).minor_units
    except ValueError:
        return None, "INEXACT_TRANSACTION_AMOUNT"
    if amount_minor == 0:
        return None, "ZERO_TRANSACTION_AMOUNT"
    description_parts = [
        value.strip()
        for value in (transaction.counterparty_name, *transaction.remittance)
        if value and value.strip()
    ]
    description = " — ".join(dict.fromkeys(description_parts)) or "Bank transaction"
    description = description[:500].strip()
    provider_reference = transaction.provider_reference
    detail_id = transaction.provider_detail_id
    try:
        observation = NormalisedSourceTransaction(
            source_kind="PROVIDER",
            source_batch_id=f"connection-{connection_id}",
            source_transaction_id=provider_reference or detail_id,
            source_statement_id=(detail_id if detail_id != provider_reference else None),
            booking_date=transaction.booking_date,
            value_date=transaction.value_date,
            pending_status=(
                "POSTED" if transaction.state is TransactionState.BOOKED else "PENDING"
            ),
            amount_minor=amount_minor,
            currency=transaction.currency,
            description=description,
            merchant_text=(transaction.counterparty_name or "")[:200] or None,
            merchant_category_code=transaction.merchant_category_code,
            bank_code=transaction.bank_code,
            bank_sub_code=transaction.bank_sub_code,
            observed_at=observed_at,
        )
    except ValueError:
        return None, "INVALID_TRANSACTION_METADATA"
    return observation, None


async def _connection_response(
    db,
    connection: dict,
    *,
    viewer_user_id: str | None = None,
) -> FinanceConnectionResponse:
    rows = await (
        await db.execute(
            """
            SELECT id, label, institution, account_type, purpose, currency, last_four,
                   include_in_cashflow, include_in_net_worth,
                   primary_spending_account, minimum_balance_minor,
                   card_paid_in_full, card_settlement_account_id,
                   card_statement_close_day, card_repayment_day,
                   fresh_through_date, data_through_at, provider_presence_status
            FROM finance_accounts
            WHERE connection_id = ? AND space_id = ? AND family_id = ?
              AND deleted_at IS NULL
            ORDER BY label, id
            """,
            (connection["id"], connection["space_id"], connection["family_id"]),
        )
    ).fetchall()
    return FinanceConnectionResponse(
        id=connection["id"],
        space_id=connection["space_id"],
        can_manage=(
            viewer_user_id is None or connection.get("created_by") == viewer_user_id
        ),
        provider=connection["provider"],
        institution=_institution_name(connection["institution_id"]),
        status=connection["status"],
        granted_capabilities=sorted(
            item.value for item in _read_capabilities(connection["granted_capabilities"])
        ),
        consent_created_at=connection["consent_created_at"],
        consent_expires_at=connection["consent_expires_at"],
        last_success_at=connection["last_success_at"],
        last_error_code=connection["last_error_code"],
        data_through_at=connection["data_through_at"],
        derived_refreshes=await _derived_refresh_responses(
            db,
            connection_id=connection["id"],
            space_id=connection["space_id"],
            family_id=connection["family_id"],
        ),
        accounts=[
            FinanceConnectedAccountResponse(
                **{
                    **dict(row),
                    "include_in_cashflow": bool(row["include_in_cashflow"]),
                    "include_in_net_worth": bool(row["include_in_net_worth"]),
                    "primary_spending_account": bool(row["primary_spending_account"]),
                    "card_paid_in_full": bool(row["card_paid_in_full"]),
                }
            )
            for row in rows
        ],
    )


def _provider_session_id(connection: dict) -> str:
    payload = _decrypt_payload(connection["encrypted_provider_secret_ref"])
    if payload.get("kind") != "PROVIDER_SESSION" or payload.get("provider") != "ENABLE_BANKING":
        raise FinanceConnectionError("Bank session needs authorisation")
    provider_session_id = payload.get("provider_session_id")
    if not isinstance(provider_session_id, str) or not provider_session_id:
        raise FinanceConnectionError("Bank session needs authorisation")
    return provider_session_id


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


def _read_capabilities(value: object) -> frozenset[ReadCapability]:
    try:
        raw = json.loads(value) if isinstance(value, str) else None
        if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
            raise ValueError
        return require_read_capabilities(frozenset(raw))
    except (ValueError, UnsafeCapabilityError):
        raise FinanceConnectionCapabilityError("Stored bank capabilities are invalid") from None


def _capabilities_json(values: frozenset[ReadCapability]) -> str:
    return json.dumps(sorted(item.value for item in values), separators=(",", ":"))


def _account_type(value: str) -> str | None:
    normalised = value.strip().upper().replace(" ", "_")
    if normalised in {"CACC", "CURRENT", "CHECKING", "CURRENT_ACCOUNT"}:
        return "CURRENT"
    if normalised in {"SVGS", "SAVINGS", "SAVINGS_ACCOUNT"}:
        return "SAVINGS"
    if normalised in {"CARD", "CREDIT_CARD", "CREDITCARD"}:
        return "CREDIT_CARD"
    return None


def _default_purpose(account_type: str) -> str:
    if account_type == "SAVINGS":
        return "SAVINGS"
    if account_type == "CREDIT_CARD":
        return "CREDIT_CARD"
    return "OPERATING_CURRENT"


def _last_four(masked_identifier: str | None) -> str | None:
    if not masked_identifier:
        return None
    digits = "".join(character for character in masked_identifier if character.isdigit())
    return digits[-4:] if len(digits) >= 4 else None


def _balance_with_type(
    balances: list[ProviderBalance],
    accepted_types: set[str],
) -> ProviderBalance | None:
    return next(
        (
            balance
            for balance in balances
            if balance.balance_type.upper().replace("_", "") in accepted_types
        ),
        None,
    )


def _institution_key(name: str, country: str) -> str:
    return f"{country.strip().upper()}:{name.strip()}"[:240]


def _institution_name(value: str | None) -> str:
    if not value:
        return "Bank"
    _, separator, name = value.partition(":")
    return name if separator and name else value


def _parse_utc(value: object, *, label: str) -> datetime:
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


def _safe_error_code(value: str | None) -> str | None:
    if value is None:
        return None
    return value if re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", value) else "PROVIDER_RESPONSE_INVALID"
