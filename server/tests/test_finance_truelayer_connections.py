import asyncio
import hashlib
import json
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from urllib.parse import parse_qs, urlparse

import aiosqlite
import pytest
from cryptography.fernet import Fernet

import app.routers.finance_connections as finance_connection_routes
import app.services.finance.truelayer_connections as truelayer_connection_service
from app.config import settings
from app.database import standalone_db
from app.main import app
from app.routers.finance_connections import truelayer_provider_dependency
from app.services.finance.providers.base import (
    ProviderAccount,
    ProviderBalance,
    ProviderResponseError,
    ProviderTransaction,
    TransactionPage,
    TransactionPages,
    TransactionState,
)
from app.services.finance.providers.truelayer import (
    TRUELAYER_SCOPES,
    TrueLayerAccessTokenExpired,
    TrueLayerAccounts,
    TrueLayerCredentials,
    TrueLayerReauthorisationRequired,
)
from app.services.finance.truelayer_connections import (
    FinanceConnectionStateError,
    complete_truelayer_callback,
)
from app.utils.encryption import decrypt_finance_provider_value


class FakeTrueLayerProvider:
    def __init__(self, db_path: str) -> None:
        self.db_path = db_path
        self.events: list[str] = []
        self.exchange_calls = 0
        self.accounts_calls = 0
        self.cards_calls = 0
        self.refresh_calls = 0
        self.balance_calls = 0
        self.empty_accounts = False
        self.include_card = False
        self.cards_response_error = False
        self.refresh_invalid = False
        self.balance_401_once = False
        self.balance_response_error = False
        self.always_401 = False
        self.assert_rotated_before_data = False
        self.rotated_refresh_token: str | None = None
        self.data_resource_types: list[str] = []
        self.exchange_started: asyncio.Event | None = None
        self.release_exchange: asyncio.Event | None = None
        self.accounts_started: asyncio.Event | None = None
        self.release_accounts: asyncio.Event | None = None
        self.balance_started: asyncio.Event | None = None
        self.release_balance: asyncio.Event | None = None
        self.transaction_windows: list[tuple[TransactionState, date | None, date | None]] = []
        self.end_user_ips: list[str | None] = []

    def for_end_user(self, end_user_ip: str | None):
        self.end_user_ips.append(end_user_ip)
        return self

    def build_authorisation_url(self, *, state: str) -> str:
        self.events.append("authorisation_url")
        return (
            "https://auth.truelayer.com/?response_type=code"
            "&scope=accounts%20cards%20balance%20transactions%20offline_access"
            "&providers=uk-ob-all%20uk-oauth-all"
            f"&state={state}"
        )

    async def exchange_code(self, code: str, *, now=None) -> TrueLayerCredentials:
        self.events.append("exchange")
        self.exchange_calls += 1
        if self.exchange_started is not None:
            self.exchange_started.set()
        if self.release_exchange is not None:
            await self.release_exchange.wait()
        observed_at = now or datetime.now(timezone.utc)
        return TrueLayerCredentials(
            access_token=f"initial-access-{self.exchange_calls}",
            refresh_token=f"initial-refresh-{self.exchange_calls}",
            access_expires_at=observed_at + timedelta(seconds=30),
            scopes=frozenset(TRUELAYER_SCOPES),
        )

    async def accounts(self, credentials: TrueLayerCredentials) -> TrueLayerAccounts:
        self.events.append("accounts")
        self.accounts_calls += 1
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            row = await (
                await db.execute(
                    "SELECT encrypted_provider_secret_ref, status FROM finance_connections "
                    "WHERE provider = 'TRUELAYER' AND status = 'PARTIAL' "
                    "ORDER BY created_at DESC, id DESC LIMIT 1"
                )
            ).fetchone()
        assert row is not None
        assert row["status"] == "PARTIAL"
        assert credentials.access_token not in row["encrypted_provider_secret_ref"]
        stored = json.loads(
            decrypt_finance_provider_value(row["encrypted_provider_secret_ref"])
        )
        assert stored["access_token"] == credentials.access_token
        assert stored["refresh_token"] == credentials.refresh_token
        if self.accounts_started is not None:
            self.accounts_started.set()
        if self.release_accounts is not None:
            await self.release_accounts.wait()
        accounts = () if self.empty_accounts else (
            ProviderAccount(
                provider_account_id="truelayer-account-1",
                currency="GBP",
                account_type="CACC",
                display_name="Family current account",
                product=None,
                usage="PRIV",
                masked_identifier="••••6819",
            ),
        )
        return TrueLayerAccounts(
            accounts=accounts,
            provider_id="ob-revolut" if accounts else None,
            institution_name="Revolut" if accounts else "Bank",
            credentials_id="credentials-1" if accounts else None,
        )

    async def cards(self, credentials: TrueLayerCredentials) -> TrueLayerAccounts:
        self.events.append("cards")
        self.cards_calls += 1
        if self.cards_response_error:
            raise ProviderResponseError("private provider detail")
        cards = (
            (
                ProviderAccount(
                    provider_account_id="truelayer-card-1",
                    currency="GBP",
                    account_type="CARD",
                    display_name="Family credit card",
                    product="MASTERCARD",
                    usage="PRIV",
                    masked_identifier="••••4421",
                    provider_resource_type="CARD",
                ),
            )
            if self.include_card
            else ()
        )
        return TrueLayerAccounts(
            accounts=cards,
            provider_id="ob-revolut" if cards else None,
            institution_name="Revolut" if cards else "Bank",
            credentials_id="credentials-1" if cards else None,
        )

    async def refresh_credentials(self, refresh_token: str, *, now=None):
        self.events.append("refresh")
        self.refresh_calls += 1
        if self.refresh_invalid:
            raise TrueLayerReauthorisationRequired("private provider detail")
        observed_at = now or datetime.now(timezone.utc)
        self.rotated_refresh_token = f"rotated-refresh-{self.refresh_calls}"
        return TrueLayerCredentials(
            access_token=f"rotated-access-{self.refresh_calls}",
            refresh_token=self.rotated_refresh_token,
            access_expires_at=observed_at + timedelta(hours=1),
            scopes=frozenset(TRUELAYER_SCOPES),
        )

    async def _assert_rotation_is_committed(self) -> None:
        if not self.assert_rotated_before_data:
            return
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            row = await (
                await db.execute(
                    "SELECT encrypted_provider_secret_ref FROM finance_connections "
                    "WHERE provider = 'TRUELAYER' ORDER BY created_at DESC LIMIT 1"
                )
            ).fetchone()
        stored = json.loads(
            decrypt_finance_provider_value(row["encrypted_provider_secret_ref"])
        )
        assert stored["refresh_token"] == self.rotated_refresh_token

    async def balances(
        self,
        credentials,
        provider_account_id,
        *,
        resource_type="ACCOUNT",
    ):
        self.events.append("balances")
        self.balance_calls += 1
        self.data_resource_types.append(resource_type)
        await self._assert_rotation_is_committed()
        if self.balance_started is not None:
            self.balance_started.set()
        if self.release_balance is not None:
            await self.release_balance.wait()
        if self.always_401 or self.balance_401_once:
            self.balance_401_once = False
            raise TrueLayerAccessTokenExpired("private provider detail")
        if self.balance_response_error:
            raise ProviderResponseError("private provider detail")
        assert (provider_account_id, resource_type) in {
            ("truelayer-account-1", "ACCOUNT"),
            ("truelayer-card-1", "CARD"),
        }
        booked = Decimal("-120.25") if resource_type == "CARD" else Decimal("1234.56")
        available = Decimal("1879.75") if resource_type == "CARD" else Decimal("1200.00")
        return (
            ProviderBalance(
                amount=booked,
                currency="GBP",
                balance_type="BOOKED",
                name="Current balance",
                reference_date=date(2026, 8, 3),
                changed_at=datetime(2026, 8, 3, 12, tzinfo=timezone.utc),
            ),
            ProviderBalance(
                amount=available,
                currency="GBP",
                balance_type="AVAILABLE",
                name="Available balance",
                reference_date=date(2026, 8, 3),
                changed_at=datetime(2026, 8, 3, 12, tzinfo=timezone.utc),
            ),
            *(
                (
                    ProviderBalance(
                        amount=Decimal("2000"),
                        currency="GBP",
                        balance_type="CREDIT_LIMIT",
                        name="Credit limit",
                        reference_date=date(2026, 8, 3),
                        changed_at=datetime(2026, 8, 3, 12, tzinfo=timezone.utc),
                    ),
                )
                if resource_type == "CARD"
                else ()
            ),
        )

    async def transaction_pages(
        self,
        credentials,
        provider_account_id,
        *,
        state,
        date_from=None,
        date_to=None,
        resource_type="ACCOUNT",
    ):
        self.events.append(f"transactions:{state.value}")
        self.data_resource_types.append(resource_type)
        self.transaction_windows.append((state, date_from, date_to))
        assert (provider_account_id, resource_type) in {
            ("truelayer-account-1", "ACCOUNT"),
            ("truelayer-card-1", "CARD"),
        }
        amount = Decimal("-24.50") if state is TransactionState.BOOKED else Decimal("-5.00")
        if resource_type == "CARD":
            amount = Decimal("-18.75") if state is TransactionState.BOOKED else Decimal("4.25")
        return TransactionPages(
            pages=(
                TransactionPage(
                    transactions=(
                        ProviderTransaction(
                            provider_reference=(
                                f"reference-{resource_type.lower()}-{state.value}"
                            ),
                            provider_detail_id=f"detail-{resource_type.lower()}-{state.value}",
                            amount=amount,
                            currency="GBP",
                            state=state,
                            booking_date=date(2026, 8, 2),
                            value_date=None,
                            transaction_date=date(2026, 8, 2),
                            counterparty_name="Family shop",
                            remittance=("Weekly groceries",),
                            merchant_category_code=None,
                            bank_code="PURCHASE",
                            bank_sub_code=None,
                        ),
                    ),
                    page_number=1,
                ),
            ),
            truncated=False,
        )


async def _space_id(client, headers: dict) -> str:
    response = await client.get("/api/finance/spaces", headers=headers)
    assert response.status_code == 200
    return next(item["id"] for item in response.json() if item["kind"] == "personal")


def _state(response) -> str:
    return parse_qs(urlparse(response.json()["redirect_url"]).query)["state"][0]


@asynccontextmanager
async def _installed_fake_provider(monkeypatch, fake: FakeTrueLayerProvider):
    @asynccontextmanager
    async def provider_context():
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        yield
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_callback_only_calls_access_denied_a_cancellation(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)
    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        provider_error_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        provider_error = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(provider_error_start), "error": "server_error"},
        )
        assert provider_error.status_code == 303
        assert parse_qs(urlparse(provider_error.headers["location"]).query)["bank"] == [
            "failed"
        ]

        missing_code_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        missing_code = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(missing_code_start)},
        )
        assert missing_code.status_code == 303
        assert parse_qs(urlparse(missing_code.headers["location"]).query)["bank"] == [
            "failed"
        ]

        missing_state = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"code": "unused-code"},
        )
        assert missing_state.status_code == 303
        assert parse_qs(urlparse(missing_state.headers["location"]).query)["bank"] == [
            "failed"
        ]

        invalid_code_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        invalid_code = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(invalid_code_start), "code": "x" * 2_001},
        )
        assert invalid_code.status_code == 303
        assert parse_qs(urlparse(invalid_code.headers["location"]).query)["bank"] == [
            "failed"
        ]

        cancelled_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        cancelled = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(cancelled_start), "error": "access_denied"},
        )
        assert cancelled.status_code == 303
        assert parse_qs(urlparse(cancelled.headers["location"]).query)["bank"] == [
            "cancelled"
        ]
        assert fake.exchange_calls == 0

        async with aiosqlite.connect(initialized_db) as db:
            error_codes = {
                row[0]
                for row in await (
                    await db.execute(
                        "SELECT last_error_code FROM finance_connections "
                        "WHERE provider = 'TRUELAYER'"
                    )
                ).fetchall()
            }
        assert "AUTHORISATION_PROVIDER_FAILED" in error_codes
        assert "AUTHORISATION_CANCELLED" in error_codes
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_truelayer_lifecycle_targets_encryption_rotation_and_stored_account_sync(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    adult_b_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    await _space_id(client, adult_b_headers)
    fake = FakeTrueLayerProvider(initialized_db)
    provider_entries: list[str] = []

    @asynccontextmanager
    async def provider_context():
        provider_entries.append("entered")
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        rejected = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "institution_name": "Revolut"},
            headers=adult_a_headers,
        )
        assert rejected.status_code == 422

        started = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "client": "ios"},
            headers=adult_a_headers,
        )
        assert started.status_code == 200, started.text
        state = _state(started)
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            pending = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE provider = 'TRUELAYER'"
                )
            ).fetchone()
        connection_id = pending["id"]
        assert pending["callback_state_hash"] == hashlib.sha256(state.encode()).hexdigest()
        assert state not in pending["encrypted_provider_secret_ref"]
        assert pending["status"] == "REAUTH_REQUIRED"

        wrong = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": "x" * 43, "code": "one-use-code"},
        )
        assert wrong.status_code == 303
        assert wrong.headers["location"].startswith("https://test/")
        assert fake.exchange_calls == 0
        assert provider_entries == []

        fake.assert_rotated_before_data = True
        callback = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": state, "code": "one-use-code"},
        )
        assert callback.status_code == 303
        assert callback.headers["location"] == "hausklar://finance-bank?bank=connected"
        assert fake.events[:4] == ["authorisation_url", "exchange", "accounts", "cards"]
        assert fake.accounts_calls == 1
        assert fake.cards_calls == 1
        assert fake.refresh_calls == 1
        observed_on = datetime.now(timezone.utc).date()
        assert fake.transaction_windows == [
            (TransactionState.BOOKED, observed_on - timedelta(days=370), observed_on),
            (TransactionState.PENDING, observed_on - timedelta(days=370), observed_on),
        ]
        async with aiosqlite.connect(initialized_db) as db:
            imported_count = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_source_transactions "
                        "WHERE account_id IN (SELECT id FROM finance_accounts "
                        "WHERE connection_id = ?)",
                        (connection_id,),
                    )
                ).fetchone()
            )[0]
            history_dates = {
                row[0]
                for row in await (
                    await db.execute(
                        "SELECT history_synced_from_date FROM finance_accounts "
                        "WHERE connection_id = ?",
                        (connection_id,),
                    )
                ).fetchall()
            }
        assert imported_count == 2
        assert history_dates == {(observed_on - timedelta(days=370)).isoformat()}

        replay = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": state, "code": "one-use-code"},
        )
        assert replay.status_code == 303
        assert replay.headers["location"].startswith("https://test/")
        assert fake.exchange_calls == 1

        private = await client.get(
            "/api/finance/connections",
            params={"space_id": space_id},
            headers=adult_b_headers,
        )
        assert private.status_code == 404

        # Add a dormant legacy row to prove the generic response can list both.
        async with aiosqlite.connect(initialized_db) as db:
            await db.execute(
                """
                INSERT INTO finance_connections
                    (id, space_id, provider, institution_id, status,
                     granted_capabilities, family_id, created_at, updated_at, created_by)
                VALUES ('dormant-enable-banking', ?, 'ENABLE_BANKING', 'GB:NatWest',
                        'DISCONNECTED', '["accounts","balances","transactions"]', ?,
                        '2026-08-03T10:00:00+00:00', '2026-08-03T10:00:00+00:00', ?)
                """,
                (space_id, adult_a_user["family_id"], adult_a_user["id"]),
            )
            await db.commit()
        listed = await client.get(
            "/api/finance/connections",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
        assert listed.status_code == 200, listed.text
        assert {item["provider"] for item in listed.json()} == {
            "ENABLE_BANKING",
            "TRUELAYER",
        }

        async def unexpected_retirement(*args, **kwargs):
            raise AssertionError("Later sync must not retire stored bank accounts")

        monkeypatch.setattr(
            truelayer_connection_service,
            "_retire_omitted_provider_accounts",
            unexpected_retirement,
        )
        synced = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers={**adult_a_headers, "CF-Connecting-IP": "89.30.121.171"},
        )
        assert synced.status_code == 200, synced.text
        assert synced.json()["accounts_seen"] == 1
        assert synced.json()["source_created"] == 0
        assert synced.json()["duplicates"] == 2
        assert fake.refresh_calls == 1
        assert fake.accounts_calls == 1
        assert fake.cards_calls == 1
        assert fake.events.index("refresh") < fake.events.index("balances")
        assert fake.end_user_ips[-1] == "89.30.121.171"

        # A surprise 401 gets one rotation and one retry, never a loop.
        fake.balance_401_once = True
        refresh_before = fake.refresh_calls
        synced_after_401 = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_a_headers,
        )
        assert synced_after_401.status_code == 200, synced_after_401.text
        assert fake.refresh_calls == refresh_before + 1
        assert fake.accounts_calls == 1
        assert fake.cards_calls == 1

        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            stored = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE id = ?",
                    (connection_id,),
                )
            ).fetchone()
            account_rows = await (
                await db.execute(
                    "SELECT * FROM finance_accounts WHERE connection_id = ?",
                    (connection_id,),
                )
            ).fetchall()
            history = " ".join(
                row[0]
                for row in await (
                    await db.execute(
                        "SELECT previous_values FROM record_history WHERE record_id = ?",
                        (connection_id,),
                    )
                ).fetchall()
            )
        encrypted = stored["encrypted_provider_secret_ref"]
        assert "rotated-access" not in encrypted
        assert "rotated-refresh" not in encrypted
        assert "initial-access" not in history
        assert "initial-refresh" not in history
        assert len(account_rows) == 1
        assert account_rows[0]["provider_account_id"] == "truelayer-account-1"
        assert account_rows[0]["provider_presence_status"] == "ACTIVE"

        provider_entries_before_private = len(provider_entries)
        private_sync = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_b_headers,
        )
        assert private_sync.status_code == 404
        assert len(provider_entries) == provider_entries_before_private

        disconnected = await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        assert disconnected.status_code == 200
        assert disconnected.json() == {"id": connection_id, "status": "DISCONNECTED"}
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("account_present", "expected_types"),
    [
        (True, {"ACCOUNT", "CARD"}),
        (False, {"CARD"}),
    ],
)
async def test_callback_imports_account_and_card_or_card_only_without_relisting(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
    account_present,
    expected_types,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)
    fake.empty_accounts = not account_present
    fake.include_card = True

    @asynccontextmanager
    async def provider_context():
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        started = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        callback = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(started), "code": "one-use-code"},
        )
        assert callback.status_code == 303
        assert parse_qs(urlparse(callback.headers["location"]).query)["bank"] == [
            "connected"
        ]

        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            connection = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE provider = 'TRUELAYER'"
                )
            ).fetchone()
            account_rows = await (
                await db.execute(
                    "SELECT * FROM finance_accounts WHERE connection_id = ? ORDER BY id",
                    (connection["id"],),
                )
            ).fetchall()
            card_balance = await (
                await db.execute(
                    "SELECT balance.* FROM finance_balance_snapshots balance "
                    "JOIN finance_accounts account ON account.id = balance.account_id "
                    "WHERE account.connection_id = ? AND account.account_type = 'CREDIT_CARD'",
                    (connection["id"],),
                )
            ).fetchone()
            card_transactions = await (
                await db.execute(
                    "SELECT source.pending_status, source.amount_minor "
                    "FROM finance_source_transactions source "
                    "JOIN finance_accounts account ON account.id = source.account_id "
                    "WHERE account.connection_id = ? AND account.account_type = 'CREDIT_CARD' "
                    "ORDER BY source.pending_status",
                    (connection["id"],),
                )
            ).fetchall()

        assert connection["granted_capabilities"] == (
            '["accounts","balances","cards","transactions"]'
        )
        assert {row["provider_resource_type"] for row in account_rows} == expected_types
        card = next(row for row in account_rows if row["provider_resource_type"] == "CARD")
        assert card["account_type"] == "CREDIT_CARD"
        assert card["last_four"] == "4421"
        assert (card_balance["booked_minor"], card_balance["available_minor"]) == (
            -12_025,
            187_975,
        )
        assert card_balance["credit_limit_minor"] == 200_000
        assert {
            (row["pending_status"], row["amount_minor"])
            for row in card_transactions
        } == {("PENDING", 425), ("POSTED", -1_875)}
        assert fake.accounts_calls == 1
        assert fake.cards_calls == 1

        synced = await client.post(
            f"/api/finance/connections/{connection['id']}/sync",
            headers=adult_a_headers,
        )
        assert synced.status_code == 200, synced.text
        assert synced.json()["accounts_seen"] == len(expected_types)
        assert fake.accounts_calls == 1
        assert fake.cards_calls == 1
        assert expected_types <= set(fake.data_resource_types)
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_reauthorisation_reuses_row_preserves_settings_and_rejects_wrong_owner(
    client,
    initialized_db,
    adult_a_headers,
    other_family_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    other_space_id = await _space_id(client, other_family_headers)
    fake = FakeTrueLayerProvider(initialized_db)

    @asynccontextmanager
    async def provider_context():
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        original_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        original_state = _state(original_start)
        await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": original_state, "code": "one-use-code"},
        )
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            connection = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE provider = 'TRUELAYER'"
                )
            ).fetchone()
            account = await (
                await db.execute(
                    "SELECT * FROM finance_accounts WHERE connection_id = ?",
                    (connection["id"],),
                )
            ).fetchone()
            await db.execute(
                "UPDATE finance_accounts SET label = 'Household spending', "
                "include_in_net_worth = 0, minimum_balance_minor = 25000 WHERE id = ?",
                (account["id"],),
            )
            await db.commit()
        connection_id = connection["id"]
        account_id = account["id"]

        active_restart = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "connection_id": connection_id},
            headers=adult_a_headers,
        )
        assert active_restart.status_code == 409

        disconnected = await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        assert disconnected.status_code == 200
        wrong_family = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": other_space_id, "connection_id": connection_id},
            headers=other_family_headers,
        )
        assert wrong_family.status_code == 404

        first_restart = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "connection_id": connection_id},
            headers=adult_a_headers,
        )
        first_restart_state = _state(first_restart)
        second_restart = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "connection_id": connection_id},
            headers=adult_a_headers,
        )
        second_restart_state = _state(second_restart)
        assert first_restart_state != second_restart_state

        exchange_before_replay = fake.exchange_calls
        stale_callback = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": first_restart_state, "code": "stale-code"},
        )
        assert parse_qs(urlparse(stale_callback.headers["location"]).query)["bank"] == [
            "failed"
        ]
        assert fake.exchange_calls == exchange_before_replay

        callback = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": second_restart_state, "code": "fresh-code"},
        )
        assert parse_qs(urlparse(callback.headers["location"]).query)["bank"] == [
            "connected"
        ]
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            connection_rows = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE provider = 'TRUELAYER'"
                )
            ).fetchall()
            saved_account = await (
                await db.execute("SELECT * FROM finance_accounts WHERE id = ?", (account_id,))
            ).fetchone()
        assert len(connection_rows) == 1
        assert connection_rows[0]["id"] == connection_id
        assert connection_rows[0]["status"] == "CONNECTED"
        assert saved_account["label"] == "Household spending"
        assert saved_account["include_in_net_worth"] == 0
        assert saved_account["minimum_balance_minor"] == 25_000
        assert fake.accounts_calls == 2
        assert fake.cards_calls == 2
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_abandoned_or_cancelled_new_start_is_hidden_and_reused(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)
    provider_entries: list[str] = []

    @asynccontextmanager
    async def provider_context():
        provider_entries.append("entered")
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        abandoned = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        abandoned_state = _state(abandoned)
        listed = await client.get(
            "/api/finance/connections",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
        assert listed.json() == []

        restarted = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        restarted_state = _state(restarted)
        async with aiosqlite.connect(initialized_db) as db:
            rows = await (
                await db.execute(
                    "SELECT id FROM finance_connections WHERE provider = 'TRUELAYER'"
                )
            ).fetchall()
        assert len(rows) == 1
        connection_id = rows[0][0]

        old_callback = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": abandoned_state, "code": "stale-code"},
        )
        assert parse_qs(urlparse(old_callback.headers["location"]).query)["bank"] == [
            "failed"
        ]
        assert provider_entries == []

        cancelled = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": restarted_state, "error": "access_denied"},
        )
        assert parse_qs(urlparse(cancelled.headers["location"]).query)["bank"] == [
            "cancelled"
        ]
        hidden_after_cancel = await client.get(
            "/api/finance/connections",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
        assert hidden_after_cancel.json() == []

        final_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(final_start), "code": "fresh-code"},
        )
        await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        reconnect = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "connection_id": connection_id},
            headers=adult_a_headers,
        )
        visible_pending_reconnect = await client.get(
            "/api/finance/connections",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
        assert [item["id"] for item in visible_pending_reconnect.json()] == [connection_id]
        await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(reconnect), "error": "access_denied"},
        )
        visible_cancelled_reconnect = await client.get(
            "/api/finance/connections",
            params={"space_id": space_id},
            headers=adult_a_headers,
        )
        assert [item["id"] for item in visible_cancelled_reconnect.json()] == [
            connection_id
        ]
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_callback_state_expiry_cancellation_atomic_claim_and_empty_discovery(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)
    provider_entries: list[str] = []

    @asynccontextmanager
    async def provider_context():
        provider_entries.append("entered")
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        provider_failed_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        provider_failed = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={
                "state": _state(provider_failed_start),
                "error": "private-provider-description",
            },
        )
        assert provider_failed.status_code == 303
        assert parse_qs(urlparse(provider_failed.headers["location"]).query)["bank"] == [
            "failed"
        ]
        assert "private-provider-description" not in provider_failed.headers["location"]
        assert provider_entries == []

        expired_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        async with standalone_db(initialized_db) as db:
            with pytest.raises(FinanceConnectionStateError, match="expired"):
                await complete_truelayer_callback(
                    db,
                    state=_state(expired_start),
                    code="one-use-code",
                    provider=fake,
                    now=datetime.now(timezone.utc) + timedelta(minutes=11),
                )

        concurrent_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        concurrent_state = _state(concurrent_start)

        async def complete_once():
            async with standalone_db(initialized_db) as db:
                try:
                    await complete_truelayer_callback(
                        db,
                        state=concurrent_state,
                        code="one-use-code",
                        provider=fake,
                    )
                except FinanceConnectionStateError:
                    return "rejected"
                return "completed"

        before_exchange = fake.exchange_calls
        outcomes = await asyncio.gather(complete_once(), complete_once())
        assert sorted(outcomes) == ["completed", "rejected"]
        assert fake.exchange_calls == before_exchange + 1

        fake.empty_accounts = True
        empty_start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        empty_callback = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(empty_start), "code": "one-use-code"},
        )
        assert empty_callback.status_code == 303
        assert parse_qs(urlparse(empty_callback.headers["location"]).query)["bank"] == [
            "failed"
        ]
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            empty_row = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE provider = 'TRUELAYER' "
                    "ORDER BY created_at DESC, id DESC LIMIT 1"
                )
            ).fetchone()
            count = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_accounts WHERE connection_id = ?",
                        (empty_row["id"],),
                    )
                ).fetchone()
            )[0]
        assert empty_row["status"] == "REAUTH_REQUIRED"
        assert empty_row["encrypted_provider_secret_ref"] is None
        assert count == 0
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_invalid_refresh_grant_and_second_401_require_reauthorisation(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)

    @asynccontextmanager
    async def provider_context():
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        start = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(start), "code": "one-use-code"},
        )
        async with aiosqlite.connect(initialized_db) as db:
            row = await (
                await db.execute(
                    "SELECT id FROM finance_connections WHERE provider = 'TRUELAYER'"
                )
            ).fetchone()
        connection_id = row[0]
        fake.refresh_invalid = True
        fake.balance_401_once = True
        failed = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_a_headers,
        )
        assert failed.status_code == 422
        assert "private provider detail" not in failed.text
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            stored = await (
                await db.execute(
                    "SELECT status, encrypted_provider_secret_ref FROM finance_connections "
                    "WHERE id = ?",
                    (connection_id,),
                )
            ).fetchone()
        assert stored["status"] == "REAUTH_REQUIRED"
        assert stored["encrypted_provider_secret_ref"] is None

        # A fresh connection whose data endpoint rejects both attempts refreshes once.
        fake.refresh_invalid = False
        second = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(second), "code": "one-use-code"},
        )
        async with aiosqlite.connect(initialized_db) as db:
            second_id = (
                await (
                    await db.execute(
                        "SELECT id FROM finance_connections WHERE provider = 'TRUELAYER' "
                        "ORDER BY created_at DESC, id DESC LIMIT 1"
                    )
                ).fetchone()
            )[0]
        fake.always_401 = True
        refresh_before = fake.refresh_calls
        rejected = await client.post(
            f"/api/finance/connections/{second_id}/sync",
            headers=adult_a_headers,
        )
        assert rejected.status_code == 422
        assert fake.refresh_calls == refresh_before + 1
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_resource_response_error_keeps_tokens_and_returns_partial_data(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)
    fake.balance_response_error = True

    @asynccontextmanager
    async def provider_context():
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        started = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        callback = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(started), "code": "one-use-code"},
        )
        assert parse_qs(urlparse(callback.headers["location"]).query)["bank"] == [
            "connected"
        ]
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            connection = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE provider = 'TRUELAYER'"
                )
            ).fetchone()
            transaction_count = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_source_transactions "
                        "WHERE account_id IN (SELECT id FROM finance_accounts "
                        "WHERE connection_id = ?)",
                        (connection["id"],),
                    )
                ).fetchone()
            )[0]
        assert connection["status"] == "PARTIAL"
        assert connection["last_error_code"] == "BALANCE_FETCH_FAILED"
        assert connection["encrypted_provider_secret_ref"] is not None
        assert transaction_count == 2

        synced = await client.post(
            f"/api/finance/connections/{connection['id']}/sync",
            headers=adult_a_headers,
        )
        assert synced.status_code == 200
        assert synced.json()["status"] == "PARTIAL"
        assert synced.json()["partial_issue_codes"] == ["BALANCE_FETCH_FAILED"]
        async with aiosqlite.connect(initialized_db) as db:
            retained = await (
                await db.execute(
                    "SELECT encrypted_provider_secret_ref FROM finance_connections "
                    "WHERE id = ?",
                    (connection["id"],),
                )
            ).fetchone()
        assert retained[0] is not None
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_reconnect_discovery_response_error_keeps_existing_account_usable(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)

    @asynccontextmanager
    async def provider_context():
        yield fake

    app.dependency_overrides[truelayer_provider_dependency] = lambda: fake
    monkeypatch.setattr(
        finance_connection_routes,
        "configured_truelayer_provider",
        provider_context,
    )
    monkeypatch.setattr(
        settings,
        "finance_provider_encryption_key",
        Fernet.generate_key().decode(),
    )
    try:
        started = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(started), "code": "one-use-code"},
        )
        async with aiosqlite.connect(initialized_db) as db:
            connection_id = (
                await (
                    await db.execute(
                        "SELECT id FROM finance_connections WHERE provider = 'TRUELAYER'"
                    )
                ).fetchone()
            )[0]
        await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        reconnect = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "connection_id": connection_id},
            headers=adult_a_headers,
        )
        fake.cards_response_error = True
        failed_callback = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(reconnect), "code": "fresh-code"},
        )
        assert parse_qs(urlparse(failed_callback.headers["location"]).query)["bank"] == [
            "failed"
        ]
        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            retained = await (
                await db.execute(
                    "SELECT status, encrypted_provider_secret_ref FROM finance_connections "
                    "WHERE id = ?",
                    (connection_id,),
                )
            ).fetchone()
            account_count = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_accounts WHERE connection_id = ? "
                        "AND provider_presence_status = 'ACTIVE'",
                        (connection_id,),
                    )
                ).fetchone()
            )[0]
        assert retained["status"] == "PARTIAL"
        assert retained["encrypted_provider_secret_ref"] is not None
        assert account_count == 1

        fake.cards_response_error = False
        synced = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_a_headers,
        )
        assert synced.status_code == 200, synced.text
        assert synced.json()["accounts_seen"] == 1
    finally:
        app.dependency_overrides.pop(truelayer_provider_dependency, None)


@pytest.mark.asyncio
async def test_disconnect_supersedes_callback_waiting_for_token_exchange(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)
    fake.exchange_started = asyncio.Event()
    fake.release_exchange = asyncio.Event()

    async with _installed_fake_provider(monkeypatch, fake):
        started = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        state = _state(started)
        async with aiosqlite.connect(initialized_db) as db:
            connection_id = (
                await (
                    await db.execute(
                        "SELECT id FROM finance_connections WHERE provider = 'TRUELAYER'"
                    )
                ).fetchone()
            )[0]

        callback_task = asyncio.create_task(
            client.get(
                "/api/finance/connections/truelayer/callback",
                params={"state": state, "code": "old-code"},
            )
        )
        await asyncio.wait_for(fake.exchange_started.wait(), timeout=2)
        disconnected = await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        assert disconnected.status_code == 200
        fake.release_exchange.set()
        callback = await asyncio.wait_for(callback_task, timeout=2)
        assert parse_qs(urlparse(callback.headers["location"]).query)["bank"] == [
            "failed"
        ]

        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            connection = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE id = ?",
                    (connection_id,),
                )
            ).fetchone()
            account_count = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_accounts WHERE connection_id = ?",
                        (connection_id,),
                    )
                ).fetchone()
            )[0]
        assert connection["status"] == "DISCONNECTED"
        assert connection["operation_generation"] == 2
        assert connection["encrypted_provider_secret_ref"] is None
        assert connection["callback_state_hash"] is None
        assert account_count == 0


@pytest.mark.asyncio
async def test_new_reconnect_supersedes_callback_waiting_in_account_discovery(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)

    async with _installed_fake_provider(monkeypatch, fake):
        started = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        connected = await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(started), "code": "initial-code"},
        )
        assert parse_qs(urlparse(connected.headers["location"]).query)["bank"] == [
            "connected"
        ]
        async with aiosqlite.connect(initialized_db) as db:
            connection_id = (
                await (
                    await db.execute(
                        "SELECT id FROM finance_connections WHERE provider = 'TRUELAYER'"
                    )
                ).fetchone()
            )[0]
        await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        old_reconnect = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "connection_id": connection_id},
            headers=adult_a_headers,
        )

        fake.include_card = True
        fake.accounts_started = asyncio.Event()
        fake.release_accounts = asyncio.Event()
        old_callback_task = asyncio.create_task(
            client.get(
                "/api/finance/connections/truelayer/callback",
                params={"state": _state(old_reconnect), "code": "old-code"},
            )
        )
        await asyncio.wait_for(fake.accounts_started.wait(), timeout=2)
        await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        new_reconnect = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id, "connection_id": connection_id},
            headers=adult_a_headers,
        )
        new_state = _state(new_reconnect)
        fake.release_accounts.set()
        old_callback = await asyncio.wait_for(old_callback_task, timeout=2)
        assert parse_qs(urlparse(old_callback.headers["location"]).query)["bank"] == [
            "failed"
        ]

        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            connection = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE id = ?",
                    (connection_id,),
                )
            ).fetchone()
            card_count = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_accounts WHERE connection_id = ? "
                        "AND provider_resource_type = 'CARD'",
                        (connection_id,),
                    )
                ).fetchone()
            )[0]
        assert connection["status"] == "REAUTH_REQUIRED"
        assert connection["last_error_code"] == "AUTHORISATION_PENDING"
        assert connection["operation_generation"] == 5
        assert connection["callback_state_hash"] == hashlib.sha256(
            new_state.encode()
        ).hexdigest()
        assert card_count == 0


@pytest.mark.asyncio
async def test_disconnect_supersedes_inflight_sync_before_any_import(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)

    async with _installed_fake_provider(monkeypatch, fake):
        started = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(started), "code": "initial-code"},
        )
        async with aiosqlite.connect(initialized_db) as db:
            connection_id = (
                await (
                    await db.execute(
                        "SELECT id FROM finance_connections WHERE provider = 'TRUELAYER'"
                    )
                ).fetchone()
            )[0]
            before_balances = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_balance_snapshots WHERE account_id IN "
                        "(SELECT id FROM finance_accounts WHERE connection_id = ?)",
                        (connection_id,),
                    )
                ).fetchone()
            )[0]
            before_sources = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_source_transactions WHERE account_id IN "
                        "(SELECT id FROM finance_accounts WHERE connection_id = ?)",
                        (connection_id,),
                    )
                ).fetchone()
            )[0]

        fake.balance_started = asyncio.Event()
        fake.release_balance = asyncio.Event()
        sync_task = asyncio.create_task(
            client.post(
                f"/api/finance/connections/{connection_id}/sync",
                headers=adult_a_headers,
            )
        )
        await asyncio.wait_for(fake.balance_started.wait(), timeout=2)
        disconnected = await client.delete(
            f"/api/finance/connections/{connection_id}",
            headers=adult_a_headers,
        )
        assert disconnected.status_code == 200
        fake.release_balance.set()
        synced = await asyncio.wait_for(sync_task, timeout=2)
        assert synced.status_code == 422

        async with aiosqlite.connect(initialized_db) as db:
            db.row_factory = aiosqlite.Row
            connection = await (
                await db.execute(
                    "SELECT * FROM finance_connections WHERE id = ?",
                    (connection_id,),
                )
            ).fetchone()
            after_balances = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_balance_snapshots WHERE account_id IN "
                        "(SELECT id FROM finance_accounts WHERE connection_id = ?)",
                        (connection_id,),
                    )
                ).fetchone()
            )[0]
            after_sources = (
                await (
                    await db.execute(
                        "SELECT COUNT(*) FROM finance_source_transactions WHERE account_id IN "
                        "(SELECT id FROM finance_accounts WHERE connection_id = ?)",
                        (connection_id,),
                    )
                ).fetchone()
            )[0]
        assert connection["status"] == "DISCONNECTED"
        assert connection["encrypted_provider_secret_ref"] is None
        assert connection["sync_lease_token"] is None
        assert after_balances == before_balances
        assert after_sources == before_sources


@pytest.mark.asyncio
async def test_sync_clamps_a_more_than_one_year_resume_window(
    client,
    initialized_db,
    adult_a_headers,
    monkeypatch,
):
    space_id = await _space_id(client, adult_a_headers)
    fake = FakeTrueLayerProvider(initialized_db)

    async with _installed_fake_provider(monkeypatch, fake):
        started = await client.post(
            "/api/finance/connections/truelayer/start",
            json={"space_id": space_id},
            headers=adult_a_headers,
        )
        await client.get(
            "/api/finance/connections/truelayer/callback",
            params={"state": _state(started), "code": "initial-code"},
        )
        async with aiosqlite.connect(initialized_db) as db:
            connection_id = (
                await (
                    await db.execute(
                        "SELECT id FROM finance_connections WHERE provider = 'TRUELAYER'"
                    )
                ).fetchone()
            )[0]
            await db.execute(
                "UPDATE finance_accounts SET fresh_through_date = '2024-01-01' "
                "WHERE connection_id = ?",
                (connection_id,),
            )
            await db.commit()

        fake.transaction_windows.clear()
        synced = await client.post(
            f"/api/finance/connections/{connection_id}/sync",
            headers=adult_a_headers,
        )
        assert synced.status_code == 200, synced.text
        observed_on = datetime.now(timezone.utc).date()
        assert fake.transaction_windows == [
            (
                TransactionState.BOOKED,
                observed_on - timedelta(days=370),
                observed_on,
            ),
            (
                TransactionState.PENDING,
                observed_on - timedelta(days=370),
                observed_on,
            ),
        ]


@pytest.mark.asyncio
async def test_scheduled_selector_skips_recent_success_but_keeps_due_retries(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    monkeypatch,
):
    from app.services.finance.truelayer_connections import sync_due_truelayer_connections

    now = datetime(2026, 8, 3, 12, tzinfo=timezone.utc)
    space_id = await _space_id(client, adult_a_headers)
    async with standalone_db(initialized_db) as db:
        rows = (
            ("recent", "CONNECTED", now - timedelta(hours=1), None),
            ("backfill", "CONNECTED", now - timedelta(hours=1), None),
            ("due", "CONNECTED", now - timedelta(hours=7), None),
            ("never", "PARTIAL", None, None),
            (
                "retry-due",
                "PROVIDER_DOWN",
                now - timedelta(hours=1),
                now - timedelta(minutes=1),
            ),
            (
                "retry-later",
                "PROVIDER_DOWN",
                now - timedelta(hours=8),
                now + timedelta(minutes=1),
            ),
        )
        for connection_id, status_value, last_success, next_retry in rows:
            await db.execute(
                "INSERT INTO finance_connections "
                "(id, space_id, provider, status, granted_capabilities, "
                "last_success_at, next_retry_at, family_id, created_at, updated_at, created_by) "
                "VALUES (?, ?, 'TRUELAYER', ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    connection_id,
                    space_id,
                    status_value,
                    '["accounts","balances","cards","transactions"]',
                    last_success.isoformat() if last_success else None,
                    next_retry.isoformat() if next_retry else None,
                    adult_a_user["family_id"],
                    now.isoformat(),
                    now.isoformat(),
                    adult_a_user["id"],
                ),
            )
        await db.execute(
            "INSERT INTO finance_accounts "
            "(id, space_id, connection_id, provider_account_id, label, institution, "
            "account_type, purpose, currency, family_id, created_at, updated_at, created_by) "
            "VALUES ('backfill-account', ?, 'backfill', 'provider-backfill', "
            "'Current account', 'NATWEST', 'CURRENT', 'OPERATING_CURRENT', 'GBP', ?, ?, ?, ?)",
            (
                space_id,
                adult_a_user["family_id"],
                now.isoformat(),
                now.isoformat(),
                adult_a_user["id"],
            ),
        )
        await db.commit()
        called: list[str] = []

        async def record_sync(
            db,
            *,
            user,
            connection_id,
            provider,
            now,
            automated,
        ):
            called.append(connection_id)

        monkeypatch.setattr(
            truelayer_connection_service,
            "sync_truelayer_connection",
            record_sync,
        )
        completed = await sync_due_truelayer_connections(
            db,
            provider=object(),
            now=now,
        )

    assert completed == 4
    assert set(called) == {"backfill", "due", "never", "retry-due"}


def test_finance_return_url_accepts_only_clean_https_origin(monkeypatch):
    monkeypatch.setattr(settings, "web_app_url", "https://hausklar.example/")
    assert finance_connection_routes._finance_return_url("failed").startswith(
        "https://hausklar.example/?"
    )
    for unsafe in (
        "http://hausklar.example",
        "https://demo-person-24@example.invalid",
        "https://hausklar.example:443",
        "https://hausklar.example/app",
        "https://hausklar.example/?next=https://evil.example",
        "https://hausklar.example/#fragment",
        "https://hausklar.example:broken",
    ):
        monkeypatch.setattr(settings, "web_app_url", unsafe)
        target = finance_connection_routes._finance_return_url("failed")
        assert target.startswith("/?")
        assert "hausklar.example" not in target


@pytest.mark.asyncio
async def test_scheduler_runs_true_layer_when_legacy_provider_fails(monkeypatch):
    import app.services.finance.enable_banking_connections as enable_connections
    import app.services.finance.providers.enable_banking_config as enable_config
    import app.services.finance.providers.truelayer_config as truelayer_config
    import app.services.finance.truelayer_connections as truelayer_connections
    from app import scheduler as scheduler_module

    calls: list[str] = []
    for name, value in {
        "enable_banking_application_id": "configured",
        "enable_banking_private_key_path": "/configured",
        "enable_banking_callback_url": "https://configured",
        "truelayer_client_id": "configured",
        "truelayer_client_secret": "configured",
        "truelayer_callback_url": "https://configured",
    }.items():
        monkeypatch.setattr(settings, name, value)

    @asynccontextmanager
    async def provider_context():
        yield object()

    @asynccontextmanager
    async def db_context():
        yield object()

    async def failed_legacy(db, *, provider):
        calls.append("legacy")
        raise RuntimeError("private legacy failure")

    async def successful_truelayer(db, *, provider):
        calls.append("truelayer")
        return 1

    monkeypatch.setattr(enable_config, "configured_enable_banking_provider", provider_context)
    monkeypatch.setattr(truelayer_config, "configured_truelayer_provider", provider_context)
    monkeypatch.setattr(enable_connections, "sync_due_enable_banking_connections", failed_legacy)
    monkeypatch.setattr(truelayer_connections, "sync_due_truelayer_connections", successful_truelayer)
    monkeypatch.setattr(scheduler_module, "standalone_db", db_context)

    await scheduler_module.run_finance_bank_sync()

    assert calls == ["legacy", "truelayer"]


@pytest.mark.asyncio
async def test_retry_poll_runs_only_the_truelayer_due_selector(monkeypatch):
    import app.services.finance.providers.truelayer_config as truelayer_config
    import app.services.finance.truelayer_connections as truelayer_connections
    from app import scheduler as scheduler_module

    for name in (
        "truelayer_client_id",
        "truelayer_client_secret",
        "truelayer_callback_url",
    ):
        monkeypatch.setattr(settings, name, "configured")
    calls: list[str] = []

    @asynccontextmanager
    async def provider_context():
        yield object()

    @asynccontextmanager
    async def db_context():
        yield object()

    async def select_due(db, *, provider):
        calls.append("truelayer-due")
        return 0

    monkeypatch.setattr(truelayer_config, "configured_truelayer_provider", provider_context)
    monkeypatch.setattr(truelayer_connections, "sync_due_truelayer_connections", select_due)
    monkeypatch.setattr(scheduler_module, "standalone_db", db_context)

    await scheduler_module.run_finance_bank_retry_poll()

    assert calls == ["truelayer-due"]
