from datetime import date, datetime, timezone
from decimal import Decimal
from urllib.parse import parse_qs, urlparse
from uuid import UUID

import httpx
import pytest

from app.services.finance.providers import (
    TRUELAYER_PROVIDERS,
    TRUELAYER_SCOPES,
    TransactionState,
    TrueLayerAccessTokenExpired,
    TrueLayerAdapter,
    TrueLayerCredentials,
    TrueLayerRateLimited,
    TrueLayerReauthorisationRequired,
)
from app.services.finance.providers.base import ProviderResponseError, ProviderTransportError

CALLBACK = "https://hausklar.example/api/finance/connections/truelayer/callback"
NOW = datetime(2026, 8, 3, 12, tzinfo=timezone.utc)


def _response(
    request: httpx.Request,
    payload: object,
    *,
    status: int = 200,
    headers: dict[str, str] | None = None,
) -> httpx.Response:
    return httpx.Response(status, request=request, json=payload, headers=headers)


def _adapter(client: httpx.AsyncClient) -> TrueLayerAdapter:
    return TrueLayerAdapter(
        client=client,
        client_id="hausklar-client",
        client_secret="server-only-secret",
        redirect_uri=CALLBACK,
    )


def _credentials() -> TrueLayerCredentials:
    return TrueLayerCredentials(
        access_token="access-token",
        refresh_token="refresh-token",
        access_expires_at=datetime(2026, 8, 3, 13, tzinfo=timezone.utc),
        scopes=frozenset(TRUELAYER_SCOPES),
    )


def test_hosted_auth_url_is_fixed_to_read_only_data_scopes_and_provider_groups():
    async def unused(_: httpx.Request) -> httpx.Response:
        raise AssertionError("Building the hosted URL must not make a request")

    client = httpx.AsyncClient(transport=httpx.MockTransport(unused))
    try:
        adapter = _adapter(client)
        url = adapter.build_authorisation_url(state="opaque-state-value-that-is-long-enough")
    finally:
        __import__("asyncio").run(client.aclose())

    parsed = urlparse(url)
    query = parse_qs(parsed.query)
    assert parsed.scheme == "https"
    assert parsed.netloc == "auth.truelayer.com"
    assert parsed.path == "/"
    assert query == {
        "response_type": ["code"],
        "client_id": ["hausklar-client"],
        "redirect_uri": [CALLBACK],
        "scope": [" ".join(TRUELAYER_SCOPES)],
        "providers": [" ".join(TRUELAYER_PROVIDERS)],
        "state": ["opaque-state-value-that-is-long-enough"],
    }
    assert "payments" not in url
    assert "server-only-secret" not in url


@pytest.mark.asyncio
async def test_code_exchange_and_refresh_return_explicit_replacement_credentials():
    requests: list[dict[str, list[str]]] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url == httpx.URL("https://auth.truelayer.com/connect/token")
        assert request.method == "POST"
        UUID(request.headers["X-Client-Correlation-Id"])
        assert "X-PSU-IP" not in request.headers
        assert request.headers["Content-Type"].startswith(
            "application/x-www-form-urlencoded"
        )
        assert request.extensions["timeout"]["connect"] == 5.0
        form = parse_qs(request.content.decode())
        requests.append(form)
        replacement = form["grant_type"] == ["refresh_token"]
        return _response(
            request,
            {
                "access_token": "new-access" if replacement else "initial-access",
                "refresh_token": "rotated-refresh" if replacement else "initial-refresh",
                "expires_in": 3600,
                "token_type": "Bearer",
                "scope": "accounts cards balance transactions offline_access",
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = _adapter(client)
        initial = await adapter.exchange_code("one-use-code", now=NOW)
        replacement = await adapter.refresh_credentials("initial-refresh", now=NOW)

    assert requests[0] == {
        "grant_type": ["authorization_code"],
        "client_id": ["hausklar-client"],
        "client_secret": ["server-only-secret"],
        "redirect_uri": [CALLBACK],
        "code": ["one-use-code"],
    }
    assert requests[1] == {
        "grant_type": ["refresh_token"],
        "client_id": ["hausklar-client"],
        "client_secret": ["server-only-secret"],
        "refresh_token": ["initial-refresh"],
    }
    assert initial.access_token == "initial-access"
    assert initial.refresh_token == "initial-refresh"
    assert replacement.access_token == "new-access"
    assert replacement.refresh_token == "rotated-refresh"
    assert replacement.access_expires_at == datetime(
        2026, 8, 3, 13, tzinfo=timezone.utc
    )
    assert "initial-access" not in repr(initial)
    assert "initial-refresh" not in repr(initial)


@pytest.mark.asyncio
async def test_account_and_card_data_use_exact_paths_and_normalise_money_signs():
    paths: list[str] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        assert request.headers["Authorization"] == "Bearer access-token"
        assert request.extensions["timeout"]["read"] == 10.0
        if request.url.path == "/data/v1/accounts":
            return _response(
                request,
                {
                    "results": [
                        {
                            "account_id": "account-123",
                            "account_type": "TRANSACTION",
                            "display_name": "House account",
                            "currency": "gbp",
                            "account_number": {
                                "number": "31926819",
                                "sort_code": "60-16-13",
                                "iban": "GB29NWBK60161331926819",
                            },
                            "provider": {
                                "provider_id": "ob-natwest",
                                "display_name": "NatWest",
                            },
                        },
                        {
                            "account_id": "account-eur",
                            "account_type": "SAVINGS",
                            "display_name": "Euro pocket",
                            "currency": "eur",
                            "account_number": {"iban": "GB00REVOLUT0000009876"},
                            "provider": {
                                "provider_id": "ob-natwest",
                                "display_name": "NatWest",
                            },
                        },
                    ]
                },
                headers={"X-Credentials-Id": "credential-set-1"},
            )
        if request.url.path == "/data/v1/cards":
            return _response(
                request,
                {
                    "results": [
                        {
                            "account_id": "card-456",
                            "card_network": "MASTERCARD",
                            "card_type": "CREDIT",
                            "display_name": "Family credit card",
                            "currency": "GBP",
                            "partial_card_number": "4421",
                            "provider": {
                                "provider_id": "ob-natwest",
                                "display_name": "NatWest",
                            },
                        }
                    ]
                },
                headers={"X-Credentials-Id": "credential-set-1"},
            )
        if request.url.path == "/data/v1/accounts/account-123/balance":
            return _response(
                request,
                {
                    "results": [
                        {
                            "currency": "GBP",
                            "current": 1161.20,
                            "available": 2150.80,
                            "overdraft": 1000,
                            "update_timestamp": "2026-08-03T12:30:00Z",
                        }
                    ]
                },
            )
        if request.url.path in {
            "/data/v1/accounts/account-123/transactions",
            "/data/v1/accounts/account-123/transactions/pending",
        }:
            expected_state = (
                "PENDING" if request.url.path.endswith("/pending") else "BOOKED"
            )
            assert dict(request.url.params) == (
                {"from": "2026-07-01", "to": "2026-08-03"}
                if expected_state == "BOOKED"
                else {}
            )
            return _response(
                request,
                {
                    "results": [
                        {
                            "transaction_id": f"detail-{expected_state.lower()}",
                            "normalised_provider_transaction_id": "stable-reference",
                            "timestamp": "2026-08-02T09:15:00Z",
                            "description": "FAMILY GROCERIES",
                            "amount": -42.75,
                            "currency": "GBP",
                            "transaction_category": "PURCHASE",
                            "transaction_classification": ["Quinn", "Supermarkets"],
                            "merchant_name": "Tesco",
                        }
                    ]
                },
            )
        if request.url.path == "/data/v1/cards/card-456/balance":
            return _response(
                request,
                {
                    "results": [
                        {
                            "currency": "GBP",
                            "current": 120.25,
                            "available": 1879.75,
                            "credit_limit": 2000,
                            "update_timestamp": "2026-08-03T12:30:00Z",
                        }
                    ]
                },
            )
        if request.url.path in {
            "/data/v1/cards/card-456/transactions",
            "/data/v1/cards/card-456/transactions/pending",
        }:
            pending = request.url.path.endswith("/pending")
            assert dict(request.url.params) == (
                {} if pending else {"from": "2026-07-01", "to": "2026-08-03"}
            )
            return _response(
                request,
                {
                    "results": [
                        {
                            "transaction_id": "card-refund" if pending else "card-purchase",
                            "timestamp": "2026-08-02T09:15:00Z",
                            "description": "CARD ITEM",
                            "amount": -7.5 if pending else 24.25,
                            "currency": "GBP",
                            "transaction_category": "PURCHASE",
                            "merchant_name": "Family shop",
                        }
                    ]
                },
            )
        raise AssertionError(f"Unexpected TrueLayer path: {request.url.path}")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = _adapter(client)
        accounts = await adapter.accounts(_credentials())
        cards = await adapter.cards(_credentials())
        balances = await adapter.balances(_credentials(), "account-123")
        booked = await adapter.transaction_pages(
            _credentials(),
            "account-123",
            state=TransactionState.BOOKED,
            date_from=date(2026, 7, 1),
            date_to=date(2026, 8, 3),
        )
        pending = await adapter.transaction_pages(
            _credentials(),
            "account-123",
            state=TransactionState.PENDING,
            date_from=date(2026, 7, 1),
            date_to=date(2026, 8, 3),
        )
        card_balances = await adapter.balances(
            _credentials(),
            "card-456",
            resource_type="CARD",
        )
        card_booked = await adapter.transaction_pages(
            _credentials(),
            "card-456",
            state=TransactionState.BOOKED,
            date_from=date(2026, 7, 1),
            date_to=date(2026, 8, 3),
            resource_type="CARD",
        )
        card_pending = await adapter.transaction_pages(
            _credentials(),
            "card-456",
            state=TransactionState.PENDING,
            date_from=date(2026, 7, 1),
            date_to=date(2026, 8, 3),
            resource_type="CARD",
        )

    assert paths == [
        "/data/v1/accounts",
        "/data/v1/cards",
        "/data/v1/accounts/account-123/balance",
        "/data/v1/accounts/account-123/transactions",
        "/data/v1/accounts/account-123/transactions/pending",
        "/data/v1/cards/card-456/balance",
        "/data/v1/cards/card-456/transactions",
        "/data/v1/cards/card-456/transactions/pending",
    ]
    assert accounts.provider_id == "ob-natwest"
    assert accounts.institution_name == "NatWest"
    assert accounts.credentials_id == "credential-set-1"
    assert accounts.accounts[0].provider_account_id == "account-123"
    assert accounts.accounts[0].account_type == "CACC"
    assert accounts.accounts[0].currency == "GBP"
    assert accounts.accounts[0].masked_identifier == "••••6819"
    assert accounts.accounts[1].account_type == "SVGS"
    assert accounts.accounts[1].currency == "EUR"
    assert accounts.accounts[1].masked_identifier == "••••9876"
    assert cards.provider_id == "ob-natwest"
    assert cards.credentials_id == "credential-set-1"
    assert cards.accounts[0].account_type == "CARD"
    assert cards.accounts[0].provider_resource_type == "CARD"
    assert cards.accounts[0].masked_identifier == "••••4421"
    assert "31926819" not in repr(accounts)
    assert "GB29NWBK" not in repr(accounts)
    assert [(item.balance_type, item.amount) for item in balances] == [
        ("BOOKED", Decimal("1161.2")),
        ("AVAILABLE", Decimal("2150.8")),
    ]
    assert booked.pages[0].transactions[0].amount == Decimal("-42.75")
    assert booked.pages[0].transactions[0].state is TransactionState.BOOKED
    assert booked.pages[0].transactions[0].bank_code == "PURCHASE"
    assert booked.pages[0].transactions[0].bank_sub_code == "Quinn/Supermarkets"
    assert pending.pages[0].transactions[0].state is TransactionState.PENDING
    assert booked.pages[0].transactions[0].provider_reference == "stable-reference"
    assert booked.truncated is False
    assert [(item.balance_type, item.amount) for item in card_balances] == [
        ("BOOKED", Decimal("-120.25")),
        ("AVAILABLE", Decimal("1879.75")),
        ("CREDIT_LIMIT", Decimal("2000")),
    ]
    assert card_booked.pages[0].transactions[0].amount == Decimal("-24.25")
    assert card_pending.pages[0].transactions[0].amount == Decimal("7.5")


@pytest.mark.asyncio
async def test_card_overpayment_becomes_a_positive_booked_asset():
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/data/v1/cards/card-456/balance"
        return _response(
            request,
            {
                "results": [
                    {
                        "currency": "GBP",
                        "current": -35.5,
                        "available": 2035.5,
                        "credit_limit": 2000,
                        "update_timestamp": "2026-08-03T12:30:00Z",
                    }
                ]
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        balances = await _adapter(client).balances(
            _credentials(),
            "card-456",
            resource_type="CARD",
        )

    assert [(item.balance_type, item.amount) for item in balances] == [
        ("BOOKED", Decimal("35.5")),
        ("AVAILABLE", Decimal("2035.5")),
        ("CREDIT_LIMIT", Decimal("2000")),
    ]


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("status", "payload", "expected"),
    [
        (401, {"error": "invalid_token", "error_description": "private"}, TrueLayerAccessTokenExpired),
        (403, {"error": "access_denied", "error_description": "private"}, TrueLayerReauthorisationRequired),
        (403, {"error": "sca_exceeded", "error_description": "private"}, ProviderResponseError),
        (403, {"error": "forbidden", "error_description": "private"}, ProviderResponseError),
        (429, {"error": "rate_limit_exceeded", "error_description": "private"}, TrueLayerRateLimited),
    ],
)
async def test_data_errors_are_typed_and_never_expose_provider_bodies(
    status: int,
    payload: dict,
    expected: type[Exception],
):
    async def handler(request: httpx.Request) -> httpx.Response:
        return _response(request, payload, status=status)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(expected) as raised:
            await _adapter(client).accounts(_credentials())

    assert "private" not in str(raised.value)
    assert "access-token" not in str(raised.value)


@pytest.mark.asyncio
async def test_end_user_ip_is_sent_only_by_an_attended_data_adapter():
    seen_headers: list[httpx.Headers] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        seen_headers.append(request.headers)
        UUID(request.headers["X-Client-Correlation-Id"])
        return _response(request, {"results": []})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = _adapter(client)
        await adapter.accounts(_credentials())
        await adapter.for_end_user("89.30.121.171").accounts(_credentials())
        await adapter.for_end_user("127.0.0.1").accounts(_credentials())

    assert "X-PSU-IP" not in seen_headers[0]
    assert seen_headers[1]["X-PSU-IP"] == "89.30.121.171"
    assert "X-PSU-IP" not in seen_headers[2]


@pytest.mark.asyncio
async def test_provider_5xx_is_temporary_and_logs_only_safe_correlation_ids(caplog):
    sent_client_correlation_id: str | None = None

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal sent_client_correlation_id
        sent_client_correlation_id = request.headers["X-Client-Correlation-Id"]
        return httpx.Response(
            503,
            request=request,
            content=b"<html>private provider failure</html>",
            headers={"X-TL-Correlation-Id": "tl-correlation-123"},
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with caplog.at_level(
            "WARNING",
            logger="app.services.finance.providers.truelayer",
        ):
            with pytest.raises(ProviderTransportError, match="temporarily unavailable"):
                await _adapter(client).accounts(_credentials())

    assert sent_client_correlation_id is not None
    UUID(sent_client_correlation_id)
    assert sent_client_correlation_id in caplog.text
    assert "tl-correlation-123" in caplog.text
    assert "private provider failure" not in caplog.text
    assert "access-token" not in caplog.text


@pytest.mark.asyncio
async def test_oversized_5xx_body_is_not_buffered_and_success_must_still_be_json():
    class UnreadProviderFailure(httpx.AsyncByteStream):
        def __init__(self) -> None:
            self.chunks_read = 0

        async def __aiter__(self):
            for _ in range(10):
                self.chunks_read += 1
                yield b"x" * (64 * 1024)

    failed_body = UnreadProviderFailure()
    call = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal call
        call += 1
        if call == 1:
            return httpx.Response(503, request=request, stream=failed_body)
        return httpx.Response(200, request=request, content=b"not-json")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = _adapter(client)
        with pytest.raises(ProviderTransportError, match="authentication is unavailable"):
            await adapter.exchange_code("secret-code", now=NOW)
        with pytest.raises(ProviderResponseError, match="invalid JSON"):
            await adapter.accounts(_credentials())

    assert failed_body.chunks_read == 0


@pytest.mark.asyncio
async def test_token_and_data_bounds_fail_closed_without_secret_leakage():
    call = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal call
        call += 1
        if call == 1:
            return httpx.Response(
                200,
                request=request,
                content=b"{}",
                headers={"Content-Type": "application/json", "Content-Length": "999999"},
            )
        return _response(
            request,
            {"results": [{} for _ in range(101)]},
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        adapter = _adapter(client)
        with pytest.raises(ProviderResponseError, match="size limit") as oversized:
            await adapter.exchange_code("secret-code", now=NOW)
        with pytest.raises(ProviderResponseError, match="too many accounts"):
            await adapter.accounts(_credentials())

    assert "secret-code" not in str(oversized.value)


@pytest.mark.asyncio
async def test_token_body_is_stopped_while_streaming_without_content_length():
    class OversizedBody(httpx.AsyncByteStream):
        def __init__(self) -> None:
            self.chunks_read = 0

        async def __aiter__(self):
            for _ in range(10):
                self.chunks_read += 1
                yield b"x" * (64 * 1024)

    body = OversizedBody()

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            request=request,
            headers={"Content-Type": "application/json"},
            stream=body,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(ProviderResponseError, match="size limit"):
            await _adapter(client).exchange_code("secret-code", now=NOW)

    assert body.chunks_read == 3


def test_transaction_window_and_account_path_are_bounded_before_network_use():
    async def unused(_: httpx.Request) -> httpx.Response:
        raise AssertionError("Invalid requests must fail before network use")

    async def run() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(unused)) as client:
            adapter = _adapter(client)
            with pytest.raises(ValueError, match="window"):
                await adapter.transaction_pages(
                    _credentials(),
                    "account-123",
                    state=TransactionState.BOOKED,
                    date_from=date(2024, 1, 1),
                    date_to=date(2026, 8, 3),
                )
            with pytest.raises(ProviderResponseError, match="identifier"):
                await adapter.balances(_credentials(), "../token")

    __import__("asyncio").run(run())
