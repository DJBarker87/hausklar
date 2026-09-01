import hashlib
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from urllib.parse import parse_qs, urlencode, urlparse

import aiosqlite
import pytest
from cryptography.fernet import Fernet

import app.routers.finance_connections as finance_connection_routes
from app.config import settings
from app.database import standalone_db
from app.main import app
from app.routers.finance_connections import enable_banking_provider_dependency
from app.services.finance.enable_banking_connections import (
    FinanceConnectionStateError,
    cancel_enable_banking_callback,
    complete_enable_banking_callback,
)
from app.services.finance.providers.base import (
    AuthorisationRequest,
    AuthorisationStart,
    ProviderAccount,
    ProviderBalance,
    ProviderInstitution,
    ProviderRenewalMetadata,
    ProviderSession,
    ProviderTransaction,
    ReadCapability,
    TransactionPage,
    TransactionPages,
    TransactionState,
)

SESSION_ID = "497f6eca-6276-4993-bfeb-53cbbbba6f08"
ACCOUNT_ID = "07cc67f4-45d6-494b-adac-09b5cbc7e2b5"
APPLICATION_ID = "73100c65-c54d-46a1-87d1-aa3effde435a"


class FakeReadOnlyProvider:
    def __init__(self) -> None:
        self.start_calls = 0
        self.exchange_calls = 0
        self.unsafe_grant = False
        self.states: list[str] = []
        self.read_calls: list[str] = []
        self.account = ProviderAccount(
            provider_account_id=ACCOUNT_ID,
            currency="GBP",
            account_type="CACC",
            display_name="Main current account",
            product="Select Account",
            usage="PRIV",
            masked_identifier="••••6819",
        )

    async def institutions(
        self,
        *,
        country: str,
        psu_type: str = "personal",
    ) -> tuple[ProviderInstitution, ...]:
        assert country == "GB"
        assert psu_type == "personal"
        return (
            ProviderInstitution(
                name="NatWest",
                country="GB",
                maximum_consent_validity_seconds=7_776_000,
            ),
            ProviderInstitution(
                name="Revolut",
                country="GB",
                maximum_consent_validity_seconds=7_776_000,
            ),
        )

    async def start_authorisation(self, request: AuthorisationRequest) -> AuthorisationStart:
        self.start_calls += 1
        self.states.append(request.state)
        assert request.redirect_url.endswith("/api/finance/connections/enable-banking/callback")
        assert request.requested_capabilities == frozenset(
            {
                ReadCapability.ACCOUNTS,
                ReadCapability.BALANCES,
                ReadCapability.TRANSACTIONS,
            }
        )
        redirect = "https://auth.enablebanking.com/start?" + urlencode({"state": request.state})
        return AuthorisationStart(
            redirect_url=redirect,
            authorisation_id=f"authorisation-{self.start_calls}",
        )

    async def exchange_code(self, code: str) -> ProviderSession:
        self.exchange_calls += 1
        assert code == "single-use-code"
        capabilities = (
            frozenset({ReadCapability.ACCOUNTS, "payments"})
            if self.unsafe_grant
            else frozenset(
                {
                    ReadCapability.ACCOUNTS,
                    ReadCapability.BALANCES,
                    ReadCapability.TRANSACTIONS,
                }
            )
        )
        return ProviderSession(
            provider_session_id=SESSION_ID,
            institution_name="NatWest",
            institution_country="GB",
            status=None,
            granted_capabilities=capabilities,
            valid_until=datetime(2026, 12, 1, 12, tzinfo=timezone.utc),
            accounts=(self.account,),
        )

    async def accounts(self, provider_session_id: str) -> tuple[ProviderAccount, ...]:
        assert provider_session_id == SESSION_ID
        self.read_calls.append("accounts")
        return (self.account,)

    async def balances(self, provider_account_id: str) -> tuple[ProviderBalance, ...]:
        assert provider_account_id == ACCOUNT_ID
        self.read_calls.append("balances")
        return (
            ProviderBalance(
                amount=Decimal("1234.56"),
                currency="GBP",
                balance_type="CLBD",
                name="Booked balance",
                reference_date=date(2026, 8, 1),
                changed_at=datetime(2026, 8, 1, 8, 30, tzinfo=timezone.utc),
            ),
        )

    async def transaction_pages(
        self,
        provider_account_id: str,
        *,
        state: TransactionState,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> TransactionPages:
        assert provider_account_id == ACCOUNT_ID
        assert date_to is not None
        self.read_calls.append(f"transactions:{state.value}")
        if state is TransactionState.BOOKED:
            transaction = ProviderTransaction(
                provider_reference="booked-1",
                provider_detail_id="booked-detail-1",
                amount=Decimal("-42.10"),
                currency="GBP",
                state=state,
                booking_date=date(2026, 7, 31),
                value_date=date(2026, 7, 31),
                transaction_date=date(2026, 7, 31),
                counterparty_name="Example Shop",
                remittance=("School shoes",),
                merchant_category_code="5661",
                bank_code="PMNT",
                bank_sub_code="CDPT",
            )
        else:
            transaction = ProviderTransaction(
                provider_reference="pending-1",
                provider_detail_id=None,
                amount=Decimal("-15.00"),
                currency="GBP",
                state=state,
                booking_date=date(2026, 8, 1),
                value_date=None,
                transaction_date=date(2026, 8, 1),
                counterparty_name="Pending retailer",
                remittance=(),
                merchant_category_code=None,
                bank_code=None,
                bank_sub_code=None,
            )
        return TransactionPages(
            pages=(TransactionPage(transactions=(transaction,), page_number=1),),
            truncated=False,
        )

    async def renewal_metadata(self, provider_session_id: str) -> ProviderRenewalMetadata:
        assert provider_session_id == SESSION_ID
        self.read_calls.append("renewal")
        return ProviderRenewalMetadata(
            status="AUTHORIZED",
            valid_until=datetime(2026, 12, 1, 12, tzinfo=timezone.utc),
            authorised_at=datetime(2026, 8, 1, 8, tzinfo=timezone.utc),
            automatic_renewal_supported=None,
        )



async def _spaces(client, headers: dict) -> dict[str, str]:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200
    return {item["kind"]: item["id"] for item in response.json()}


def _state_from(response) -> str:
    redirect_url = response.json()["redirect_url"]
    return parse_qs(urlparse(redirect_url).query)["state"][0]


@pytest.mark.asyncio
async def test_cross_site_callback_needs_no_session_cookie_and_stays_owner_bound(
    client,
    initialized_db,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
    tmp_path,
):
    adult_a_space = (await _spaces(client, adult_a_headers))["personal"]
    await _spaces(client, adult_b_headers)
    fake = FakeReadOnlyProvider()

    @asynccontextmanager
    async def provider_context():
        yield fake

    app.dependency_overrides[enable_banking_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_enable_banking_provider",
        provider_context,
    )
    key_path = tmp_path / "enable-banking.pem"
    key_path.write_text("provider dependency is overridden in this test")
    monkeypatch.setattr(settings, "enable_banking_application_id", APPLICATION_ID)
    monkeypatch.setattr(settings, "enable_banking_private_key_path", str(key_path))
    monkeypatch.setattr(
        settings,
        "enable_banking_callback_url",
        "https://hausklar.example/api/finance/connections/enable-banking/callback",
    )
    monkeypatch.setattr(
        settings, "finance_provider_encryption_key", Fernet.generate_key().decode()
    )

    try:
        started = await client.post(
            "/api/finance/connections/enable-banking/start",
            json={
                "space_id": adult_a_space,
                "institution_name": "NatWest",
                "institution_country": "GB",
            },
            headers=adult_a_headers,
        )
        state = _state_from(started)

        # Represent a browser returning from the bank with either no HausKlar
        # cookie or a different signed-in adult's cookie. The callback state,
        # not ambient browser identity, selects Alex's pre-created connection.
        login_as_kat = await client.post(
            "/api/auth/web/login",
            json={"email": "demo-person-52@example.invalid", "password": "password123"},
        )
        assert login_as_kat.status_code == 200
        callback = await client.get(
            "/api/finance/connections/enable-banking/callback",
            params={"state": state, "code": "single-use-code"},
        )

        assert callback.status_code == 303
        callback_query = parse_qs(urlparse(callback.headers["location"]).query)
        assert callback_query["bank"] == ["connected"]
        assert "connection" not in callback_query
        adult_a_connections = await client.get(
            "/api/finance/connections",
            params={"space_id": adult_a_space},
            headers=adult_a_headers,
        )
        adult_b_attempt = await client.get(
            "/api/finance/connections",
            params={"space_id": adult_a_space},
            headers=adult_b_headers,
        )
        assert adult_a_connections.status_code == 200
        assert adult_a_connections.json()[0]["status"] == "CONNECTED"
        assert adult_b_attempt.status_code == 404

        replay = await client.get(
            "/api/finance/connections/enable-banking/callback",
            params={"state": state, "code": "single-use-code"},
        )
        assert parse_qs(urlparse(replay.headers["location"]).query)["bank"] == [
            "failed"
        ]
        assert fake.exchange_calls == 1

        expired_start = await client.post(
            "/api/finance/connections/enable-banking/start",
            json={
                "space_id": adult_a_space,
                "institution_name": "NatWest",
                "institution_country": "GB",
            },
            headers=adult_a_headers,
        )
        expired_state = _state_from(expired_start)
        async with standalone_db(initialized_db) as db:
            with pytest.raises(FinanceConnectionStateError, match="expired"):
                await complete_enable_banking_callback(
                    db,
                    state=expired_state,
                    code="single-use-code",
                    provider=fake,
                    now=datetime.now(timezone.utc) + timedelta(minutes=11),
                )
            expired_row = await (
                await db.execute(
                    "SELECT status, callback_state_hash FROM finance_connections "
                    "WHERE callback_state_hash IS NULL AND status = 'EXPIRED'"
                )
            ).fetchone()
        assert expired_row is not None
        assert fake.exchange_calls == 1

        expired_cancel_start = await client.post(
            "/api/finance/connections/enable-banking/start",
            json={
                "space_id": adult_a_space,
                "institution_name": "NatWest",
                "institution_country": "GB",
            },
            headers=adult_a_headers,
        )
        expired_cancel_state = _state_from(expired_cancel_start)
        async with standalone_db(initialized_db) as db:
            with pytest.raises(FinanceConnectionStateError, match="expired"):
                await cancel_enable_banking_callback(
                    db,
                    state=expired_cancel_state,
                    now=datetime.now(timezone.utc) + timedelta(minutes=11),
                )

        legacy_start = await client.post(
            "/api/finance/connections/enable-banking/start",
            json={
                "space_id": adult_a_space,
                "institution_name": "NatWest",
                "institution_country": "GB",
            },
            headers=adult_a_headers,
        )
        legacy_state = _state_from(legacy_start)
        callback_time = datetime.now(timezone.utc)
        async with standalone_db(initialized_db) as db:
            await db.execute(
                """
                UPDATE finance_connections
                SET callback_state_hash = NULL, created_at = ?
                WHERE callback_state_hash = ?
                """,
                (
                    (callback_time - timedelta(minutes=11)).isoformat(),
                    hashlib.sha256(legacy_state.encode()).hexdigest(),
                ),
            )
            await db.commit()
            with pytest.raises(FinanceConnectionStateError, match="invalid"):
                await complete_enable_banking_callback(
                    db,
                    state=legacy_state,
                    code="single-use-code",
                    provider=fake,
                    now=callback_time,
                )
        assert fake.exchange_calls == 1
    finally:
        app.dependency_overrides.pop(enable_banking_provider_dependency, None)


@pytest.mark.asyncio
async def test_derived_refresh_failures_are_bounded_persisted_and_do_not_stop_other_hooks(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    from app.services.finance.enable_banking_connections import (
        _after_material_bank_sync,
    )

    space_id = (await _spaces(client, adult_a_headers))["personal"]
    connection_id = "derived-refresh-test-connection"
    now = "2026-08-03T09:00:00+00:00"
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO finance_connections
                (id, space_id, provider, institution_id, status,
                 granted_capabilities, family_id, created_at, updated_at, created_by)
            VALUES (?, ?, 'ENABLE_BANKING', 'GB:Example Bank', 'CONNECTED',
                    '["accounts","balances","transactions"]', ?, ?, ?, ?)
            """,
            (
                connection_id,
                space_id,
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.execute(
            """
            INSERT INTO finance_accounts
                (id, space_id, connection_id, label, account_type, currency,
                 family_id, created_at, updated_at, created_by)
            VALUES ('derived-refresh-test-account', ?, ?, 'Example current account',
                    'CURRENT', 'GBP', ?, ?, ?, ?)
            """,
            (
                space_id,
                connection_id,
                adult_a_user["family_id"],
                now,
                now,
                adult_a_user["id"],
            ),
        )
        await db.commit()

    calls: list[str] = []
    failures = {"rematch": True, "coach": False}

    async def rematch(*args, **kwargs):
        calls.append("rematch")
        if failures["rematch"]:
            raise RuntimeError("School shoes cost £25; this text must never be stored")

    async def forecast(*args, **kwargs):
        calls.append("forecast")

    async def payday(*args, **kwargs):
        calls.append("payday")

    async def coach(*args, **kwargs):
        calls.append("coach")
        if failures["coach"]:
            raise RuntimeError("Private transaction description must never be stored")

    monkeypatch.setattr(
        "app.services.finance.purchase_evidence.rematch_unmatched_purchases", rematch
    )
    monkeypatch.setattr("app.services.finance.planning.generate_forecast", forecast)
    monkeypatch.setattr("app.services.finance.coaching.match_payday_actions", payday)
    monkeypatch.setattr("app.services.finance.coaching.refresh_coaching_report", coach)

    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await _after_material_bank_sync(
            db,
            user=adult_a_user,
            space_id=space_id,
            connection_id=connection_id,
            now=datetime(2026, 8, 3, 9, tzinfo=timezone.utc),
        )
    assert calls == ["rematch", "forecast", "payday", "coach"]

    failures.update(rematch=False, coach=True)
    calls.clear()
    async with aiosqlite.connect(initialized_db) as db:
        db.row_factory = aiosqlite.Row
        await _after_material_bank_sync(
            db,
            user=adult_a_user,
            space_id=space_id,
            connection_id=connection_id,
            now=datetime(2026, 8, 3, 10, tzinfo=timezone.utc),
        )
    assert calls == ["rematch", "forecast", "payday", "coach"]

    visible = await client.get(
        "/api/finance/connections",
        params={"space_id": space_id},
        headers=adult_a_headers,
    )
    assert visible.status_code == 200, visible.text
    connection = next(item for item in visible.json() if item["id"] == connection_id)
    statuses = {item["hook"]: item for item in connection["derived_refreshes"]}
    assert set(statuses) == {
        "PURCHASE_REMATCH",
        "FORECAST",
        "PAYDAY_MATCH",
        "COACH_REPORT",
    }
    assert statuses["PURCHASE_REMATCH"] == {
        "hook": "PURCHASE_REMATCH",
        "status": "SUCCEEDED",
        "last_attempt_at": "2026-08-03T10:00:00+00:00",
        "last_success_at": "2026-08-03T10:00:00+00:00",
        "last_error_code": None,
    }
    assert statuses["COACH_REPORT"] == {
        "hook": "COACH_REPORT",
        "status": "FAILED",
        "last_attempt_at": "2026-08-03T10:00:00+00:00",
        "last_success_at": "2026-08-03T09:00:00+00:00",
        "last_error_code": "COACH_REPORT_REFRESH_FAILED",
    }
    async with aiosqlite.connect(initialized_db) as db:
        stored = " ".join(
            str(value or "")
            for row in await (
                await db.execute(
                    "SELECT last_error_code FROM finance_connection_derived_refreshes "
                    "WHERE connection_id = ? UNION ALL "
                    "SELECT previous_values FROM record_history "
                    "WHERE table_name = 'finance_connection_derived_refreshes'",
                    (connection_id,),
                )
            ).fetchall()
            for value in row
        )
    assert "School shoes" not in stored
    assert "Private transaction" not in stored


@pytest.mark.asyncio
async def test_enable_banking_read_only_lifecycle_privacy_and_capability_failure(
    client,
    initialized_db,
    adult_a_user,
    adult_b_user,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
    tmp_path,
):
    adult_a_space = (await _spaces(client, adult_a_headers))["personal"]
    await _spaces(client, adult_b_headers)
    fake = FakeReadOnlyProvider()

    @asynccontextmanager
    async def provider_context():
        yield fake

    app.dependency_overrides[enable_banking_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_enable_banking_provider",
        provider_context,
    )
    key_path = tmp_path / "enable-banking.pem"
    key_path.write_text("provider dependency is overridden in this test")
    monkeypatch.setattr(settings, "enable_banking_application_id", APPLICATION_ID)
    monkeypatch.setattr(settings, "enable_banking_private_key_path", str(key_path))
    monkeypatch.setattr(
        settings,
        "enable_banking_callback_url",
        "https://hausklar.example/api/finance/connections/enable-banking/callback",
    )
    monkeypatch.setattr(
        settings, "finance_provider_encryption_key", Fernet.generate_key().decode()
    )

    try:
        institutions = await client.get(
            "/api/finance/connections/enable-banking/institutions",
            headers=adult_a_headers,
        )
        assert institutions.status_code == 200
        assert [item["name"] for item in institutions.json()] == ["NatWest", "Revolut"]

        rejected_credentials = await client.post(
            "/api/finance/connections/enable-banking/start",
            json={
                "space_id": adult_a_space,
                "institution_name": "NatWest",
                "institution_country": "GB",
                "password": "must-never-be-accepted",
            },
            headers=adult_a_headers,
        )
        assert rejected_credentials.status_code == 422
        assert fake.start_calls == 0

        started = await client.post(
            "/api/finance/connections/enable-banking/start",
            json={
                "space_id": adult_a_space,
                "institution_name": "NatWest",
                "institution_country": "GB",
            },
            headers=adult_a_headers,
        )
        assert started.status_code == 200, started.text
        assert set(started.json()) == {"redirect_url"}
        callback_state = _state_from(started)

        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            pending = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE created_by = ?",
                    (adult_a_user["id"],),
                )
            ).fetchone()
        assert pending["status"] == "REAUTH_REQUIRED"
        assert callback_state not in pending["encrypted_provider_secret_ref"]
        assert pending["callback_state_hash"] == hashlib.sha256(
            callback_state.encode()
        ).hexdigest()
        connection_id = pending["id"]

        private_list = await client.get(
            "/api/finance/connections",
            params={"space_id": adult_a_space},
            headers=adult_b_headers,
        )
        assert private_list.status_code == 404
        assert connection_id not in private_list.text

        callback = await client.get(
            "/api/finance/connections/enable-banking/callback",
            params={"state": callback_state, "code": "single-use-code"},
        )
        assert callback.status_code == 303, callback.text
        callback_location = urlparse(callback.headers["location"])
        callback_query = parse_qs(callback_location.query)
        assert callback_location.netloc == "test"
        assert callback_query == {
            "view": ["finance"],
            "section": ["setup"],
            "bank": ["connected"],
        }
        assert SESSION_ID not in callback.headers["location"]
        assert callback_state not in callback.headers["location"]

        connected_list = await client.get(
            "/api/finance/connections",
            params={"space_id": adult_a_space},
            headers=adult_a_headers,
        )
        assert connected_list.status_code == 200
        assert connected_list.json()[0]["status"] == "CONNECTED"
        assert connected_list.json()[0]["accounts"][0]["last_four"] == "6819"
        assert SESSION_ID not in connected_list.text
        assert ACCOUNT_ID not in connected_list.text

        duplicate_callback = await client.get(
            "/api/finance/connections/enable-banking/callback",
            params={"state": callback_state, "code": "single-use-code"},
        )
        assert duplicate_callback.status_code == 303
        assert parse_qs(urlparse(duplicate_callback.headers["location"]).query)["bank"] == [
            "failed"
        ]
        assert fake.exchange_calls == 1

        first_sync = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_a_headers,
        )
        assert first_sync.status_code == 200, first_sync.text
        first_sync_body = first_sync.json()
        derived_refreshes = first_sync_body.pop("derived_refreshes")
        assert first_sync_body == {
            "connection_id": connection_id,
            "status": "CONNECTED",
            "accounts_seen": 1,
            "balances_created": 1,
            "source_created": 2,
            "canonical_created": 2,
            "duplicates": 0,
            "pending_superseded": 0,
            "partial_issue_codes": [],
        }
        assert [item["hook"] for item in derived_refreshes] == [
            "PURCHASE_REMATCH",
            "FORECAST",
            "PAYDAY_MATCH",
            "COACH_REPORT",
        ]
        assert {item["status"] for item in derived_refreshes} == {"SUCCEEDED"}
        assert all(item["last_success_at"] for item in derived_refreshes)
        assert all(item["last_error_code"] is None for item in derived_refreshes)

        retry_sync = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_a_headers,
        )
        assert retry_sync.status_code == 200, retry_sync.text
        assert retry_sync.json()["balances_created"] == 0
        assert retry_sync.json()["source_created"] == 0
        assert retry_sync.json()["canonical_created"] == 0
        assert retry_sync.json()["duplicates"] == 2

        fake.account = ProviderAccount(
            provider_account_id=ACCOUNT_ID,
            currency="EUR",
            account_type="CACC",
            display_name="Main current account",
            product="Select Account",
            usage="PRIV",
            masked_identifier="••••6819",
        )
        changed_currency = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_a_headers,
        )
        assert changed_currency.status_code == 200
        assert changed_currency.json()["status"] == "PARTIAL"
        assert "ACCOUNT_CURRENCY_CHANGED" in changed_currency.json()["partial_issue_codes"]
        fake.account = ProviderAccount(
            provider_account_id=ACCOUNT_ID,
            currency="GBP",
            account_type="CACC",
            display_name="Main current account",
            product="Select Account",
            usage="PRIV",
            masked_identifier="••••6819",
        )

        private_sync = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_b_headers,
        )
        assert private_sync.status_code == 404
        assert connection_id not in private_sync.text

        disconnected = await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        assert disconnected.status_code == 200
        assert disconnected.json() == {"id": connection_id, "status": "DISCONNECTED"}

        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            stored = await (
                await db.execute("SELECT * FROM finance_connections WHERE id = ?", (connection_id,))
            ).fetchone()
            account = await (
                await db.execute(
                    "SELECT * FROM finance_accounts WHERE connection_id = ?",
                    (connection_id,),
                )
            ).fetchone()
            balance_count = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_balance_snapshots WHERE account_id = ?",
                        (account["id"],),
                    )
                ).fetchone()
            )[0]
            transaction_count = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_transactions WHERE account_id = ?",
                        (account["id"],),
                    )
                ).fetchone()
            )[0]
            history_text = " ".join(
                row[0]
                for row in await (
                    await db.execute(
                        "SELECT previous_values FROM record_history WHERE record_id = ?",
                        (connection_id,),
                    )
                ).fetchall()
            )
        assert stored["status"] == "DISCONNECTED"
        assert stored["deleted_at"] is None
        assert stored["encrypted_provider_secret_ref"] is None
        assert account["deleted_at"] is None
        assert account["currency"] == "GBP"
        assert balance_count == 1
        assert transaction_count == 2
        assert SESSION_ID not in history_text
        assert "callback_state_hash" not in history_text
        assert hashlib.sha256(callback_state.encode()).hexdigest() not in history_text

        retained_accounts = await client.get(
            "/api/finance/accounts",
            params={"space_id": adult_a_space},
            headers=adult_a_headers,
        )
        retained_transactions = await client.get(
            "/api/finance/transactions",
            params={"space_id": adult_a_space, "account_id": account["id"]},
            headers=adult_a_headers,
        )
        assert retained_accounts.status_code == 200
        assert any(item["id"] == account["id"] for item in retained_accounts.json())
        assert retained_transactions.status_code == 200
        assert len(retained_transactions.json()) == 2

        cancelled_start = await client.post(
            "/api/finance/connections/enable-banking/start",
            json={
                "space_id": adult_a_space,
                "institution_name": "NatWest",
                "institution_country": "GB",
            },
            headers=adult_a_headers,
        )
        cancelled = await client.get(
            "/api/finance/connections/enable-banking/callback",
            params={"state": _state_from(cancelled_start), "error": "provider-private-text"},
        )
        assert cancelled.status_code == 303
        cancelled_query = parse_qs(urlparse(cancelled.headers["location"]).query)
        assert cancelled_query["bank"] == ["cancelled"]
        assert "provider-private-text" not in cancelled.headers["location"]
        assert fake.exchange_calls == 1

        fake.unsafe_grant = True
        unsafe_start = await client.post(
            "/api/finance/connections/enable-banking/start",
            json={
                "space_id": adult_a_space,
                "institution_name": "NatWest",
                "institution_country": "GB",
            },
            headers=adult_a_headers,
        )
        unsafe_callback = await client.get(
            "/api/finance/connections/enable-banking/callback",
            params={"state": _state_from(unsafe_start), "code": "single-use-code"},
        )
        assert unsafe_callback.status_code == 303
        unsafe_query = parse_qs(urlparse(unsafe_callback.headers["location"]).query)
        assert unsafe_query["bank"] == ["failed"]
        assert "state" not in unsafe_query
        assert "code" not in unsafe_query

        visible_after_disconnect = await client.get(
            "/api/finance/connections",
            params={"space_id": adult_a_space},
            headers=adult_a_headers,
        )
        assert visible_after_disconnect.status_code == 200
        assert len(visible_after_disconnect.json()) == 3
        assert {item["status"] for item in visible_after_disconnect.json()} == {
            "DISCONNECTED",
            "REAUTH_REQUIRED",
        }
        assert any(
            item["last_error_code"] == "CAPABILITY_MISMATCH"
            for item in visible_after_disconnect.json()
        )
        assert any(
            item["last_error_code"] == "AUTHORISATION_CANCELLED"
            for item in visible_after_disconnect.json()
        )
        assert SESSION_ID not in visible_after_disconnect.text
    finally:
        app.dependency_overrides.pop(enable_banking_provider_dependency, None)
