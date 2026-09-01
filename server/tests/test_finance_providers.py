from datetime import date, datetime, timezone
from decimal import Decimal

import httpx
import pytest

from app.services.finance.providers import (
    AuthorisationRequest,
    EnableBankingAdapter,
    ReadOnlyBankProvider,
    TransactionState,
)
from app.services.finance.providers.base import (
    ProviderResponseError,
    ProviderTransportError,
    ReadCapability,
    UnsafeCapabilityError,
)

SESSION_ID = "497f6eca-6276-4993-bfeb-53cbbbba6f08"
ACCOUNT_ID = "07cc67f4-45d6-494b-adac-09b5cbc7e2b5"
AUTHORISATION_ID = "73100c65-c54d-46a1-87d1-aa3effde435a"
VALID_UNTIL = "2026-12-01T12:00:00Z"


def response(request: httpx.Request, payload: object, status: int = 200) -> httpx.Response:
    return httpx.Response(status, request=request, json=payload)


def account_payload() -> dict:
    return {
        "uid": ACCOUNT_ID,
        "account_id": {"iban": "GB29NWBK60161331926819"},
        "all_account_ids": [
            {"identification": "31926819", "scheme_name": "BBAN"},
        ],
        "name": "Alex Example",
        "details": "Main current account",
        "usage": "PRIV",
        "cash_account_type": "CACC",
        "product": "Select Account",
        "currency": "gbp",
        "postal_address": {"address_line": ["private address"]},
    }


def authorisation_request(**overrides) -> AuthorisationRequest:
    values = {
        "institution_name": "NatWest",
        "institution_country": "GB",
        "redirect_url": "https://hausklar.example/finance/callback",
        "state": "opaque-state",
        "valid_until": datetime(2026, 12, 1, 12, tzinfo=timezone.utc),
    }
    values.update(overrides)
    return AuthorisationRequest(**values)


@pytest.mark.asyncio
async def test_enable_banking_starts_only_account_information_authorisation():
    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/aspsps":
            assert request.method == "GET"
            assert dict(request.url.params) == {
                "country": "GB",
                "psu_type": "personal",
                "service": "AIS",
            }
            return response(
                request,
                {
                    "aspsps": [
                        {
                            "name": "Broken unrelated entry",
                            "country": "GB",
                            "maximum_consent_validity": None,
                        },
                        {
                            "name": "NatWest",
                            "country": "GB",
                            "maximum_consent_validity": 31_536_000,
                        }
                    ]
                },
            )
        assert request.url.path == "/auth"
        assert request.method == "POST"
        assert request.headers["Authorization"] == "Bearer " + "signed-application-jwt"
        assert request.extensions["timeout"]["connect"] == 5.0
        payload = __import__("json").loads(request.content)
        assert payload["access"] == {
            "valid_until": VALID_UNTIL,
            "balances": True,
            "transactions": True,
        }
        assert payload["aspsp"] == {"name": "NatWest", "country": "GB"}
        assert "credentials" not in payload
        assert "payments" not in payload["access"]
        return response(
            request,
            {
                "url": "https://auth.enablebanking.com/ais/start?sessionid=opaque",
                "authorization_id": AUTHORISATION_ID,
                "psu_id_hash": "not-retained",
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = EnableBankingAdapter(
            client=client,
            token_factory=lambda: "signed-application-jwt",
        )
        assert isinstance(adapter, ReadOnlyBankProvider)
        started = await adapter.start_authorisation(authorisation_request())

    assert started.authorisation_id == AUTHORISATION_ID
    assert started.redirect_url.startswith("https://auth.enablebanking.com/")
    assert "psu_id_hash" not in repr(started)


def test_read_only_contract_rejects_payment_and_unknown_capabilities():
    with pytest.raises(UnsafeCapabilityError, match="Only account"):
        authorisation_request(
            requested_capabilities=frozenset({"accounts", "balances", "payments"})
        )
    with pytest.raises(UnsafeCapabilityError, match="Only account"):
        authorisation_request(
            requested_capabilities=frozenset({"accounts", "beneficiaries"})
        )


@pytest.mark.asyncio
async def test_session_exchange_normalises_accounts_and_rejects_write_grants():
    grant_write_capability = False

    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/sessions"
        payload = __import__("json").loads(request.content)
        assert payload == {"code": "one-use-code"}
        access = {
            "valid_until": VALID_UNTIL,
            "balances": True,
            "transactions": True,
        }
        if grant_write_capability:
            access["payment_initiation"] = True
        return response(
            request,
            {
                "session_id": SESSION_ID,
                "accounts": [account_payload()],
                "aspsp": {"name": "NatWest", "country": "GB"},
                "psu_type": "personal",
                "access": access,
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = EnableBankingAdapter(client=client, token_factory=lambda: "jwt")
        session = await adapter.exchange_code("one-use-code")
        grant_write_capability = True
        with pytest.raises(UnsafeCapabilityError, match="outside account information"):
            await adapter.exchange_code("one-use-code")

    assert session.provider_session_id == SESSION_ID
    assert session.status is None
    assert session.valid_until == datetime(2026, 12, 1, 12, tzinfo=timezone.utc)
    assert session.granted_capabilities == frozenset(
        {ReadCapability.ACCOUNTS, ReadCapability.BALANCES, ReadCapability.TRANSACTIONS}
    )
    account = session.accounts[0]
    assert account.currency == "GBP"
    assert account.masked_identifier == "••••6819"
    assert account.display_name == "Main current account"
    assert "GB29NWBK60161331926819" not in repr(session)
    assert "private address" not in repr(session)


@pytest.mark.asyncio
async def test_accounts_balances_and_expiry_metadata_use_documented_read_endpoints():
    paths: list[str] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        if request.url.path == f"/sessions/{SESSION_ID}":
            return response(
                request,
                {
                    "status": "AUTHORIZED",
                    "accounts": [ACCOUNT_ID],
                    "accounts_data": [
                        {
                            "uid": ACCOUNT_ID,
                            "identification_hash": "not-retained",
                            "identification_hashes": ["not-retained"],
                        }
                    ],
                    "aspsp": {"name": "NatWest", "country": "GB"},
                    "psu_type": "personal",
                    "access": {
                        "valid_until": VALID_UNTIL,
                        "balances": True,
                        "transactions": True,
                    },
                    "created": "2026-01-01T10:00:00Z",
                    "authorized": "2026-01-01T10:01:00Z",
                    "psu_id_hash": "not-retained",
                },
            )
        if request.url.path == f"/accounts/{ACCOUNT_ID}/details":
            return response(request, account_payload())
        if request.url.path == f"/accounts/{ACCOUNT_ID}/balances":
            return response(
                request,
                {
                    "balances": [
                        {
                            "name": "Booked balance",
                            "balance_amount": {"currency": "GBP", "amount": "1234.56"},
                            "balance_type": "CLBD",
                            "last_change_date_time": "2026-08-01T09:30:00+01:00",
                            "reference_date": "2026-08-01",
                        }
                    ]
                },
            )
        raise AssertionError(f"Unexpected path: {request.url.path}")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = EnableBankingAdapter(client=client, token_factory=lambda: "jwt")
        accounts = await adapter.accounts(SESSION_ID)
        balances = await adapter.balances(ACCOUNT_ID)
        renewal = await adapter.renewal_metadata(SESSION_ID)

    assert accounts[0].masked_identifier == "••••6819"
    assert balances[0].amount == Decimal("1234.56")
    assert balances[0].currency == "GBP"
    assert balances[0].reference_date == date(2026, 8, 1)
    assert balances[0].changed_at == datetime(2026, 8, 1, 8, 30, tzinfo=timezone.utc)
    assert renewal.status == "AUTHORIZED"
    assert renewal.valid_until == datetime(2026, 12, 1, 12, tzinfo=timezone.utc)
    assert renewal.authorised_at == datetime(2026, 1, 1, 10, 1, tzinfo=timezone.utc)
    assert renewal.automatic_renewal_supported is None
    assert paths == [
        f"/sessions/{SESSION_ID}",
        f"/accounts/{ACCOUNT_ID}/details",
        f"/accounts/{ACCOUNT_ID}/balances",
        f"/sessions/{SESSION_ID}",
    ]


@pytest.mark.asyncio
async def test_booked_and_pending_transactions_are_paged_and_sign_normalised():
    booked_calls = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal booked_calls
        assert request.url.path == f"/accounts/{ACCOUNT_ID}/transactions"
        status = request.url.params["transaction_status"]
        assert request.url.params["strategy"] == "default"
        assert request.url.params["date_from"] == "2026-07-01"
        assert request.url.params["date_to"] == "2026-07-31"
        if status == "BOOK":
            booked_calls += 1
            if booked_calls == 1:
                assert "continuation_key" not in request.url.params
                return response(
                    request,
                    {
                        "transactions": [
                            {
                                "entry_reference": "stable-booked-reference",
                                "transaction_id": "detail-id",
                                "transaction_amount": {"currency": "GBP", "amount": "42.10"},
                                "credit_debit_indicator": "DBIT",
                                "status": "BOOK",
                                "booking_date": "2026-07-12",
                                "value_date": "2026-07-13",
                                "transaction_date": "2026-07-11",
                                "creditor": {"name": "Example Shop"},
                                "creditor_account": {"iban": "SECRET-CREDITOR-ACCOUNT"},
                                "remittance_information": ["School shoes"],
                                "merchant_category_code": "5661",
                                "bank_transaction_code": {"code": "PMNT", "sub_code": "CDPT"},
                            }
                        ],
                        "continuation_key": "opaque-next-page",
                    },
                )
            assert request.url.params["continuation_key"] == "opaque-next-page"
            return response(request, {"transactions": [], "continuation_key": None})
        assert status == "PDNG"
        return response(
            request,
            {
                "transactions": [
                    {
                        "transaction_amount": {"currency": "GBP", "amount": "15.00"},
                        "credit_debit_indicator": "CRDT",
                        "status": "PDNG",
                        "debtor": {"name": "Refund sender"},
                    }
                ]
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = EnableBankingAdapter(
            client=client,
            token_factory=lambda: "jwt",
            max_transaction_pages=2,
        )
        booked = await adapter.transaction_pages(
            ACCOUNT_ID,
            state=TransactionState.BOOKED,
            date_from=date(2026, 7, 1),
            date_to=date(2026, 7, 31),
        )
        pending = await adapter.transaction_pages(
            ACCOUNT_ID,
            state=TransactionState.PENDING,
            date_from=date(2026, 7, 1),
            date_to=date(2026, 7, 31),
        )

    transaction = booked.pages[0].transactions[0]
    assert transaction.amount == Decimal("-42.10")
    assert transaction.booking_date == date(2026, 7, 12)
    assert transaction.counterparty_name == "Example Shop"
    assert transaction.remittance == ("School shoes",)
    assert booked.truncated is False
    assert len(booked.pages) == 2
    assert pending.pages[0].transactions[0].amount == Decimal("15.00")
    assert pending.pages[0].transactions[0].state is TransactionState.PENDING
    assert "SECRET-CREDITOR-ACCOUNT" not in repr(booked)
    assert "opaque-next-page" not in repr(booked)


@pytest.mark.asyncio
async def test_pagination_is_bounded_and_reports_truncation():
    calls = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return response(
            request,
            {"transactions": [], "continuation_key": f"cursor-{calls}"},
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = EnableBankingAdapter(
            client=client,
            token_factory=lambda: "jwt",
            max_transaction_pages=2,
        )
        result = await adapter.transaction_pages(ACCOUNT_ID, state=TransactionState.BOOKED)

    assert calls == 2
    assert len(result.pages) == 2
    assert result.truncated is True


@pytest.mark.asyncio
async def test_provider_errors_never_include_response_bodies_tokens_or_key_failures():
    secret = "do-not-leak-bank-or-token-secret"

    async def handler(request: httpx.Request) -> httpx.Response:
        return response(request, {"detail": secret}, status=400)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = EnableBankingAdapter(client=client, token_factory=lambda: secret)
        with pytest.raises(ProviderResponseError) as response_error:
            await adapter.exchange_code("one-use-code")
        failing_auth = EnableBankingAdapter(
            client=client,
            token_factory=lambda: (_ for _ in ()).throw(RuntimeError(secret)),
        )
        with pytest.raises(ProviderTransportError) as auth_error:
            await failing_auth.exchange_code("one-use-code")

    assert secret not in str(response_error.value)
    assert secret not in repr(response_error.value)
    assert secret not in str(auth_error.value)
    assert secret not in repr(auth_error.value)
