"""Broker-independent securities portfolio behavior."""

import asyncio
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from unittest.mock import patch

import aiosqlite
import httpx
import pytest

from app.services.finance.market_prices import (
    MarketExchangeRate,
    MarketPriceUnavailable,
    MarketQuote,
)
from app.services.finance.assets import _quote_minor


class _PortfolioQuoteProvider:
    def __init__(self, *, price: str = "100", usd_to_gbp: str = "0.8") -> None:
        self.price = Decimal(price)
        self.usd_to_gbp = Decimal(usd_to_gbp)
        self.symbols: list[str] = []
        self.exchange_pairs: list[tuple[str, str]] = []
        self.observed_at = datetime.now(timezone.utc) - timedelta(days=1)

    async def fetch(self, symbol: str) -> MarketQuote:
        self.symbols.append(symbol)
        return MarketQuote(
            symbol=symbol,
            price=self.price,
            observed_at=self.observed_at,
            source_label="Test daily close",
        )

    async def fetch_exchange_rate(
        self,
        from_currency: str,
        to_currency: str,
    ) -> MarketExchangeRate:
        self.exchange_pairs.append((from_currency, to_currency))
        return MarketExchangeRate(
            from_currency=from_currency,
            to_currency=to_currency,
            rate=self.usd_to_gbp,
            observed_at=self.observed_at,
            source_label="Test daily FX",
        )


class _UnavailableQuoteProvider:
    async def fetch(self, symbol: str) -> MarketQuote:
        del symbol
        raise MarketPriceUnavailable("market unavailable")


def _position(
    *,
    identifier: str = "holding-1",
    quantity: str = "2.5",
    symbol: str = "VWRP.LON",
    quote_currency: str = "GBP",
    cost_basis_minor: int | None = 20_000,
) -> dict:
    return {
        "id": identifier,
        "name": "Global index fund",
        "quote_symbol": symbol,
        "quote_currency": quote_currency,
        "quantity": quantity,
        "cost_basis_minor": cost_basis_minor,
    }


def test_gbx_quote_conversion_does_not_apply_major_unit_scaling_twice():
    assert _quote_minor(
        price=Decimal("100"),
        quote_currency="GBX",
        currency="USD",
        exchange_rate=Decimal("1.25"),
    ) == 125


@pytest.mark.asyncio
async def test_manual_portfolio_position_lifecycle_keeps_daily_price_history(
    client,
    adult_a_headers,
    adult_b_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    personal_id = next(space["id"] for space in spaces if space["kind"] == "personal")

    empty = await client.get(
        "/api/finance/assets/portfolio",
        params={"space_id": personal_id},
        headers=adult_a_headers,
    )
    assert empty.status_code == 200, empty.text
    assert empty.json()["source_id"] is None
    assert empty.json()["positions"] == []

    created = await client.post(
        "/api/finance/assets/portfolio/positions",
        params={"space_id": personal_id},
        headers=adult_a_headers,
        json=_position(),
    )
    assert created.status_code == 201, created.text
    assert created.json()["positions"][0]["value_minor"] is None

    replayed = await client.post(
        "/api/finance/assets/portfolio/positions",
        params={"space_id": personal_id},
        headers=adult_a_headers,
        json=_position(),
    )
    assert replayed.status_code == 201, replayed.text
    assert len(replayed.json()["positions"]) == 1
    conflicting_replay = await client.post(
        "/api/finance/assets/portfolio/positions",
        params={"space_id": personal_id},
        headers=adult_a_headers,
        json=_position(quantity="3"),
    )
    assert conflicting_replay.status_code == 409, conflicting_replay.text

    provider = _PortfolioQuoteProvider()
    with patch(
        "app.services.finance.assets.configured_market_quote_provider",
        return_value=provider,
    ):
        refreshed = await client.post(
            "/api/finance/assets/portfolio/refresh",
            params={"space_id": personal_id},
            headers=adult_a_headers,
        )
    assert refreshed.status_code == 200, refreshed.text
    assert refreshed.json()["priced_holding_count"] == 1
    assert provider.symbols == ["VWRP.LON"]

    valued = await client.get(
        "/api/finance/assets/portfolio",
        params={"space_id": personal_id},
        headers=adult_a_headers,
    )
    assert valued.status_code == 200, valued.text
    assert valued.json()["total_value_minor"] == 25_000
    assert valued.json()["total_cost_basis_minor"] == 20_000
    assert valued.json()["total_gain_minor"] == 5_000
    assert valued.json()["positions"][0]["unit_price_minor"] == 10_000
    assert valued.json()["using_last_known_prices"] is True

    with patch(
        "app.services.finance.assets.configured_market_quote_provider",
        return_value=_UnavailableQuoteProvider(),
    ):
        retained = await client.post(
            "/api/finance/assets/portfolio/refresh",
            params={"space_id": personal_id},
            headers=adult_a_headers,
        )
    assert retained.status_code == 200, retained.text
    assert retained.json()["retained_holding_count"] == 1
    assert retained.json()["price_sources"] == ["Test daily close"]

    updated = await client.put(
        "/api/finance/assets/portfolio/positions/holding-1",
        params={"space_id": personal_id},
        headers=adult_a_headers,
        json=_position(quantity="3", cost_basis_minor=22_000),
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["total_value_minor"] == 30_000
    assert updated.json()["total_gain_minor"] == 8_000

    hidden = await client.get(
        "/api/finance/assets/portfolio",
        params={"space_id": personal_id},
        headers=adult_b_headers,
    )
    assert hidden.status_code == 404

    removed = await client.delete(
        "/api/finance/assets/portfolio/positions/holding-1",
        params={"space_id": personal_id},
        headers=adult_a_headers,
    )
    assert removed.status_code == 200, removed.text
    assert removed.json()["positions"] == []
    assert removed.json()["total_value_minor"] == 0
    assert removed.json()["history"][-1]["value_minor"] == 0

    net_worth = await client.get(
        "/api/finance/assets/net-worth-history",
        params={"space_id": personal_id, "currency": "GBP", "days": 7},
        headers=adult_a_headers,
    )
    assert net_worth.status_code == 200, net_worth.text
    latest_layers = {
        layer["layer"]: layer["amount_minor"] for layer in net_worth.json()["points"][-1]["layers"]
    }
    assert latest_layers["BROKERAGE_INVESTMENT"] == 0


@pytest.mark.asyncio
async def test_concurrent_position_additions_do_not_lose_a_holding(
    client,
    adult_a_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    personal_id = next(space["id"] for space in spaces if space["kind"] == "personal")

    first, second = await asyncio.gather(
        client.post(
            "/api/finance/assets/portfolio/positions",
            params={"space_id": personal_id},
            headers=adult_a_headers,
            json=_position(identifier="holding-a", symbol="VWRP.LON"),
        ),
        client.post(
            "/api/finance/assets/portfolio/positions",
            params={"space_id": personal_id},
            headers=adult_a_headers,
            json=_position(identifier="holding-b", symbol="VT", quote_currency="USD"),
        ),
    )

    assert first.status_code == 201, first.text
    assert second.status_code == 201, second.text
    portfolio = await client.get(
        "/api/finance/assets/portfolio",
        params={"space_id": personal_id},
        headers=adult_a_headers,
    )
    assert portfolio.status_code == 200, portfolio.text
    assert {position["id"] for position in portfolio.json()["positions"]} == {
        "holding-a",
        "holding-b",
    }


@pytest.mark.asyncio
async def test_manual_portfolio_converts_public_usd_quote_to_gbp(
    client,
    adult_a_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    household_id = next(space["id"] for space in spaces if space["kind"] == "household")
    created = await client.post(
        "/api/finance/assets/portfolio/positions",
        params={"space_id": household_id},
        headers=adult_a_headers,
        json=_position(
            identifier="us-holding",
            quantity="2",
            symbol="VT",
            quote_currency="USD",
            cost_basis_minor=None,
        ),
    )
    assert created.status_code == 201, created.text

    provider = _PortfolioQuoteProvider(price="100", usd_to_gbp="0.8")
    with patch(
        "app.services.finance.assets.configured_market_quote_provider",
        return_value=provider,
    ):
        refreshed = await client.post(
            "/api/finance/assets/portfolio/refresh",
            params={"space_id": household_id},
            headers=adult_a_headers,
        )
    assert refreshed.status_code == 200, refreshed.text
    assert provider.exchange_pairs == [("USD", "GBP")]
    assert refreshed.json()["price_sources"] == ["Test daily close; Test daily FX"]

    portfolio = await client.get(
        "/api/finance/assets/portfolio",
        params={"space_id": household_id},
        headers=adult_a_headers,
    )
    assert portfolio.status_code == 200, portfolio.text
    assert portfolio.json()["positions"][0]["unit_price_minor"] == 8_000
    assert portfolio.json()["total_value_minor"] == 16_000
    assert portfolio.json()["total_gain_minor"] is None
    assert portfolio.json()["missing_cost_basis_count"] == 1


@pytest.mark.asyncio
async def test_manual_portfolio_rejects_an_unsupported_display_currency(
    client,
    adult_a_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    personal_id = next(space["id"] for space in spaces if space["kind"] == "personal")

    response = await client.get(
        "/api/finance/assets/portfolio",
        params={"space_id": personal_id, "currency": "USD"},
        headers=adult_a_headers,
    )

    assert response.status_code == 422, response.text
    assert response.json()["detail"] == (
        "Savings portfolio values are currently reported in GBP"
    )


@pytest.mark.asyncio
async def test_daily_finance_refresh_updates_user_entered_portfolio(
    client,
    adult_a_headers,
):
    from app import scheduler as scheduler_module

    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    personal_id = next(space["id"] for space in spaces if space["kind"] == "personal")
    created = await client.post(
        "/api/finance/assets/portfolio/positions",
        params={"space_id": personal_id},
        headers=adult_a_headers,
        json=_position(identifier="daily-position", quantity="1.5"),
    )
    assert created.status_code == 201, created.text

    provider = _PortfolioQuoteProvider(price="120")
    with patch(
        "app.services.finance.market_prices.configured_market_quote_provider",
        return_value=provider,
    ):
        await scheduler_module.run_finance_watch_refresh()

    assert provider.symbols == ["VWRP.LON"]
    portfolio = await client.get(
        "/api/finance/assets/portfolio",
        params={"space_id": personal_id},
        headers=adult_a_headers,
    )
    assert portfolio.status_code == 200, portfolio.text
    assert portfolio.json()["total_value_minor"] == 18_000


@pytest.mark.asyncio
async def test_asset_source_migration_preserves_existing_rows_and_is_idempotent(
    initialized_db,
):
    from app.database import _run_migrations

    async with aiosqlite.connect(initialized_db) as db:
        await db.execute("DROP INDEX IF EXISTS idx_finance_manual_portfolio_space")
        await db.execute("DROP INDEX IF EXISTS idx_finance_asset_public_address")
        await db.execute("DROP INDEX IF EXISTS idx_finance_asset_sources_space")
        await db.execute("DROP TABLE finance_asset_sources")
        await db.execute(
            """
            CREATE TABLE finance_asset_sources (
                id TEXT PRIMARY KEY,
                space_id TEXT NOT NULL,
                source_kind TEXT NOT NULL CHECK (source_kind IN (
                    'HL_REPORT', 'SOLANA_PUBLIC', 'HYPERLIQUID_PUBLIC'
                )),
                label TEXT NOT NULL,
                public_address TEXT,
                status TEXT NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'PAUSED')),
                family_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                created_by TEXT,
                client_id TEXT,
                client_timestamp TEXT,
                deleted_at TEXT,
                CHECK (
                    (source_kind = 'HL_REPORT' AND public_address IS NULL)
                    OR (source_kind IN ('SOLANA_PUBLIC', 'HYPERLIQUID_PUBLIC')
                        AND public_address IS NOT NULL)
                )
            )
            """
        )
        await db.execute(
            """
            INSERT INTO finance_asset_sources
                (id, space_id, source_kind, label, status, family_id,
                 created_at, updated_at)
            VALUES ('legacy-hl', 'legacy-space', 'HL_REPORT', 'Existing ISA',
                    'ACTIVE', 'legacy-family', '2026-01-01T00:00:00Z',
                    '2026-01-01T00:00:00Z')
            """
        )
        await db.commit()

        await _run_migrations(db)
        await _run_migrations(db)

        schema = (
            await (
                await db.execute(
                    "SELECT sql FROM sqlite_master "
                    "WHERE type = 'table' AND name = 'finance_asset_sources'"
                )
            ).fetchone()
        )[0]
        assert "MANUAL_PORTFOLIO" in schema
        legacy = await (
            await db.execute(
                "SELECT label FROM finance_asset_sources WHERE id = 'legacy-hl'"
            )
        ).fetchone()
        assert legacy[0] == "Existing ISA"
        await db.execute(
            """
            INSERT INTO finance_asset_sources
                (id, space_id, source_kind, label, status, family_id,
                 created_at, updated_at)
            VALUES ('manual-one', 'legacy-space', 'MANUAL_PORTFOLIO',
                    'Savings portfolio', 'ACTIVE', 'legacy-family',
                    '2026-08-10T00:00:00Z', '2026-08-10T00:00:00Z')
            """
        )
        with pytest.raises(aiosqlite.IntegrityError):
            await db.execute(
                """
                INSERT INTO finance_asset_sources
                    (id, space_id, source_kind, label, status, family_id,
                     created_at, updated_at)
                VALUES ('manual-two', 'legacy-space', 'MANUAL_PORTFOLIO',
                        'Duplicate portfolio', 'ACTIVE', 'legacy-family',
                        '2026-08-10T00:00:00Z', '2026-08-10T00:00:00Z')
                """
            )


@pytest.mark.asyncio
async def test_alphavantage_exchange_rate_is_server_side_and_cached():
    from app.services.finance.market_prices import AlphaVantageMarketQuoteProvider

    requests: list[tuple[str, str, str]] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requests.append(
            (
                request.url.params["function"],
                request.url.params["from_currency"],
                request.url.params["to_currency"],
            )
        )
        assert request.url.params["apikey"] == "server-only-key"
        return httpx.Response(
            200,
            json={
                "Realtime Currency Exchange Rate": {
                    "5. Exchange Rate": "0.8125",
                    "6. Last Refreshed": "2026-08-09 20:00:00",
                }
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        provider = AlphaVantageMarketQuoteProvider(
            api_key="server-only-key",
            client=http,
            request_limit=1,
        )
        first = await provider.fetch_exchange_rate("usd", "gbp")
        second = await provider.fetch_exchange_rate("USD", "GBP")

    assert first == second
    assert first.rate == Decimal("0.8125")
    assert first.observed_at.isoformat() == "2026-08-09T20:00:00+00:00"
    assert requests == [("CURRENCY_EXCHANGE_RATE", "USD", "GBP")]
