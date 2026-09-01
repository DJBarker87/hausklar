"""Dated HL valuations and household net-worth history."""

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from unittest.mock import patch

import aiosqlite
import httpx
import pytest

from app.services.finance.market_prices import MarketPriceUnavailable, MarketQuote


class _QuoteProvider:
    async def fetch(self, symbol: str) -> MarketQuote:
        return MarketQuote(
            symbol=symbol,
            price=Decimal("120.00"),
            observed_at=datetime.now(timezone.utc) - timedelta(days=1),
            source_label="Test daily close",
        )


class _UnavailableProvider:
    async def fetch(self, symbol: str) -> MarketQuote:
        del symbol
        raise MarketPriceUnavailable("closed")


class _CountingGBXProvider:
    def __init__(self, db_path: str | None = None) -> None:
        self.calls: list[str] = []
        self.db_path = db_path

    async def fetch(self, symbol: str) -> MarketQuote:
        self.calls.append(symbol)
        if self.db_path:
            async with aiosqlite.connect(self.db_path, timeout=0.05) as probe:
                await probe.execute("BEGIN IMMEDIATE")
                await probe.rollback()
        return MarketQuote(
            symbol=symbol,
            price=Decimal("123.45"),
            observed_at=datetime.now(timezone.utc) - timedelta(days=1),
            source_label="Test London close",
        )


class _CountingUnavailableProvider:
    def __init__(self) -> None:
        self.calls: list[str] = []

    async def fetch(self, symbol: str) -> MarketQuote:
        self.calls.append(symbol)
        raise MarketPriceUnavailable("throttled")


def _day(days_ago: int) -> str:
    return (datetime.now(timezone.utc).date() - timedelta(days=days_ago)).isoformat()


def _holding(*, quantity: str, value_minor: int) -> dict:
    return {
        "asset_key": "isin:GB00TEST0001",
        "asset_name": "Family index fund",
        "asset_class": "BROKERAGE_INVESTMENT",
        "quantity": quantity,
        "quantity_unit": "unit",
        "value_minor": value_minor,
        "unit_price_minor": value_minor // int(quantity),
        "price_source": "Reviewed HL report",
        "instrument_id_kind": "ISIN",
        "instrument_id": "GB00TEST0001",
        "quote_symbol": "TEST.LON",
        "quote_currency": "GBP",
    }


@pytest.mark.asyncio
async def test_household_net_worth_history_keeps_flows_apart_from_growth(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
    adult_b_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    household_id = next(space["id"] for space in spaces if space["kind"] == "household")

    async with aiosqlite.connect(initialized_db) as db:
        for account_id, label, account_type, purpose, amount in (
            ("nw-current", "Household current", "CURRENT", "OPERATING_CURRENT", 100_000),
            ("nw-savings", "Accessible savings", "SAVINGS", "SAVINGS", 200_000),
            ("nw-goal", "House deposit", "SAVINGS", "GOAL", 300_000),
        ):
            await db.execute(
                """
                INSERT INTO finance_accounts
                    (id, space_id, label, account_type, purpose, currency,
                     family_id, created_by)
                VALUES (?, ?, ?, ?, ?, 'GBP', ?, ?)
                """,
                (
                    account_id,
                    household_id,
                    label,
                    account_type,
                    purpose,
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            )
            await db.execute(
                """
                INSERT INTO finance_balance_snapshots
                    (id, space_id, account_id, booked_minor, currency,
                     observed_at, family_id, created_by)
                VALUES (?, ?, ?, ?, 'GBP', ?, ?, ?)
                """,
                (
                    f"{account_id}-balance",
                    household_id,
                    account_id,
                    amount,
                    f"{_day(20)}T08:00:00+00:00",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            )
        await db.execute(
            """
            INSERT INTO finance_reserves
                (id, space_id, name, allocated_minor, currency, status,
                 family_id, updated_at, created_by)
            VALUES ('nw-reserve', ?, 'Bills buffer', 50000, 'GBP', 'ACTIVE',
                    ?, ?, ?)
            """,
            (
                household_id,
                adult_a_user["family_id"],
                f"{_day(20)}T08:00:00+00:00",
                adult_a_user["id"],
            ),
        )
        await db.commit()

    first = await client.post(
        "/api/finance/assets/hl/import-preview",
        params={"space_id": household_id},
        headers=adult_a_headers,
        json={
            "label": "HL household ISA",
            "account_wrapper": "ISA",
            "as_of_date": _day(30),
            "currency": "GBP",
            "cash_value_minor": 0,
            "reported_total_minor": 100_000,
            "holdings": [_holding(quantity="10", value_minor=100_000)],
            "activities": [
                {
                    "activity_type": "CONTRIBUTION",
                    "occurred_on": _day(35),
                    "amount_minor": 100_000,
                    "currency": "GBP",
                    "description": "Opening contribution",
                }
            ],
        },
    )
    assert first.status_code == 201, first.text
    first_confirmed = await client.post(
        f"/api/finance/assets/hl/previews/{first.json()['id']}/confirm",
        headers=adult_a_headers,
        json={"reviewed": True},
    )
    assert first_confirmed.status_code == 200, first_confirmed.text

    second = await client.post(
        "/api/finance/assets/hl/import-preview",
        params={"space_id": household_id},
        headers=adult_a_headers,
        json={
            "label": "HL household ISA",
            "account_wrapper": "ISA",
            "as_of_date": _day(10),
            "currency": "GBP",
            "cash_value_minor": 0,
            "reported_total_minor": 132_000,
            "holdings": [_holding(quantity="12", value_minor=132_000)],
            "activities": [
                {
                    "activity_type": "CONTRIBUTION",
                    "occurred_on": _day(35),
                    "amount_minor": 100_000,
                    "currency": "GBP",
                    "description": "Opening contribution",
                },
                {
                    "activity_type": "CONTRIBUTION",
                    "occurred_on": _day(15),
                    "amount_minor": 20_000,
                    "currency": "GBP",
                    "description": "Monthly contribution",
                },
            ],
        },
    )
    assert second.status_code == 201, second.text
    second_confirmed = await client.post(
        f"/api/finance/assets/hl/previews/{second.json()['id']}/confirm",
        headers=adult_a_headers,
        json={"reviewed": True},
    )
    assert second_confirmed.status_code == 200, second_confirmed.text
    source_id = second_confirmed.json()["source"]["id"]

    with patch(
        "app.services.finance.assets.configured_market_quote_provider",
        return_value=_QuoteProvider(),
    ):
        refreshed = await client.post(
            f"/api/finance/assets/hl/sources/{source_id}/refresh-prices",
            headers=adult_a_headers,
        )
    assert refreshed.status_code == 200, refreshed.text
    assert refreshed.json()["priced_holding_count"] == 1
    assert refreshed.json()["price_sources"] == ["Test daily close"]

    with patch(
        "app.services.finance.assets.configured_market_quote_provider",
        return_value=_UnavailableProvider(),
    ):
        retained = await client.post(
            f"/api/finance/assets/hl/sources/{source_id}/refresh-prices",
            headers=adult_a_headers,
        )
    assert retained.status_code == 200, retained.text
    assert retained.json()["priced_holding_count"] == 0
    assert retained.json()["retained_holding_count"] == 1
    assert retained.json()["price_sources"] == ["Test daily close"]

    manual_items = (
        ("Family home", "PROPERTY", 50_000_000),
        ("Car and other assets", "OTHER_ASSET", 1_000_000),
        ("Work pension", "PENSION_LOCKED", 5_000_000),
        ("Mortgage", "LIABILITY", 30_000_000),
    )
    for name, asset_class, value_minor in manual_items:
        saved = await client.post(
            "/api/finance/assets/manual-values",
            params={"space_id": household_id},
            headers=adult_a_headers,
            json={
                "reviewed": True,
                "name": name,
                "asset_class": asset_class,
                "as_of_at": f"{_day(5)}T12:00:00+00:00",
                "value_minor": value_minor,
                "currency": "GBP",
                "source_label": "Reviewed household value",
            },
        )
        assert saved.status_code == 201, saved.text

    history = await client.get(
        "/api/finance/assets/net-worth-history",
        params={"space_id": household_id, "currency": "GBP", "days": 60},
        headers=adult_b_headers,
    )
    assert history.status_code == 200, history.text
    body = history.json()
    assert body["current_total_minor"] == 26_744_000
    assert body["points"][0]["as_of_date"] == _day(30)
    assert body["points"][0]["total_minor"] == 100_000
    assert body["period_contributions_minor"] == 120_000
    assert body["period_withdrawals_minor"] == 0
    assert body["period_market_movement_minor"] == 24_000
    assert body["price_sources"] == [
        "Reviewed household value",
        "Test daily close",
    ]
    fund = next(item for item in body["holdings"] if item["name"] == "Family index fund")
    assert fund["value_minor"] == 144_000
    assert fund["instrument_id_kind"] == "ISIN"
    assert fund["instrument_id"] == "GB00TEST0001"
    assert fund["quote_symbol"] == "TEST.LON"
    latest_layers = {item["layer"]: item["amount_minor"] for item in body["points"][-1]["layers"]}
    assert latest_layers == {
        "OPERATING_CASH": 100_000,
        "PROTECTED_RESERVE": 50_000,
        "GOAL_CASH": 300_000,
        "ACCESSIBLE_SAVINGS": 200_000,
        "BROKERAGE_INVESTMENT": 144_000,
        "PENSION_LOCKED": 5_000_000,
        "STABLE_CRYPTO": 0,
        "VOLATILE_CRYPTO": 0,
        "PROPERTY": 50_000_000,
        "OTHER_ASSET": 1_000_000,
        "LIABILITY": -30_000_000,
    }
    assert sum(latest_layers.values()) == 26_794_000
    assert body["current_total_minor"] == (
        sum(latest_layers.values()) - latest_layers["PROTECTED_RESERVE"]
    )


@pytest.mark.asyncio
async def test_london_pence_quotes_are_converted_once_per_symbol(
    client,
    initialized_db,
    adult_a_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    household_id = next(space["id"] for space in spaces if space["kind"] == "household")
    preview = await client.post(
        "/api/finance/assets/hl/import-preview",
        params={"space_id": household_id},
        headers=adult_a_headers,
        json={
            "label": "HL family fund account",
            "account_wrapper": "ISA",
            "as_of_date": _day(5),
            "currency": "GBP",
            "cash_value_minor": 0,
            "reported_total_minor": 1_800,
            "holdings": [
                {
                    "asset_key": f"isin:GB00PENCE00{index}",
                    "asset_name": f"London fund {index}",
                    "asset_class": "BROKERAGE_INVESTMENT",
                    "quantity": quantity,
                    "quantity_unit": "unit",
                    "value_minor": value_minor,
                    "unit_price_minor": 150,
                    "price_source": "Reviewed HL report",
                    "instrument_id_kind": "ISIN",
                    "instrument_id": f"GB00PENCE00{index}",
                    "quote_symbol": "PENCE.LON",
                    "quote_currency": "GBX",
                }
                for index, quantity, value_minor in (
                    (1, "10", 1_500),
                    (2, "2", 300),
                )
            ],
            "activities": [],
        },
    )
    assert preview.status_code == 201, preview.text
    confirmed = await client.post(
        f"/api/finance/assets/hl/previews/{preview.json()['id']}/confirm",
        headers=adult_a_headers,
        json={"reviewed": True},
    )
    assert confirmed.status_code == 200, confirmed.text
    source_id = confirmed.json()["source"]["id"]

    provider = _CountingGBXProvider(initialized_db)
    with patch(
        "app.services.finance.assets.configured_market_quote_provider",
        return_value=provider,
    ):
        refreshed = await client.post(
            f"/api/finance/assets/hl/sources/{source_id}/refresh-prices",
            headers=adult_a_headers,
        )
    assert refreshed.status_code == 200, refreshed.text
    assert refreshed.json()["priced_holding_count"] == 2
    assert provider.calls == ["PENCE.LON"]

    async with aiosqlite.connect(initialized_db) as db:
        rows = await (
            await db.execute(
                "SELECT unit_price_minor FROM finance_market_price_observations "
                "WHERE source_id = ? ORDER BY asset_key",
                (source_id,),
            )
        ).fetchall()
    assert [row[0] for row in rows] == [123, 123]

    unavailable = _CountingUnavailableProvider()
    with patch(
        "app.services.finance.assets.configured_market_quote_provider",
        return_value=unavailable,
    ):
        retained = await client.post(
            f"/api/finance/assets/hl/sources/{source_id}/refresh-prices",
            headers=adult_a_headers,
        )
    assert retained.status_code == 200, retained.text
    assert retained.json()["retained_holding_count"] == 2
    assert unavailable.calls == ["PENCE.LON"]


@pytest.mark.asyncio
async def test_portfolio_refresh_shares_one_quote_cache_across_hl_accounts(
    client,
    initialized_db,
    adult_a_headers,
):
    from app.services.finance.market_prices import AlphaVantageMarketQuoteProvider

    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    household_id = next(space["id"] for space in spaces if space["kind"] == "household")
    source_ids = []
    for label in ("HL household ISA", "HL household general account"):
        preview = await client.post(
            "/api/finance/assets/hl/import-preview",
            params={"space_id": household_id},
            headers=adult_a_headers,
            json={
                "label": label,
                "account_wrapper": "ISA",
                "as_of_date": _day(5),
                "currency": "GBP",
                "cash_value_minor": 0,
                "reported_total_minor": 100_000,
                "holdings": [_holding(quantity="10", value_minor=100_000)],
                "activities": [],
            },
        )
        assert preview.status_code == 201, preview.text
        confirmed = await client.post(
            f"/api/finance/assets/hl/previews/{preview.json()['id']}/confirm",
            headers=adult_a_headers,
            json={"reviewed": True},
        )
        assert confirmed.status_code == 200, confirmed.text
        source_ids.append(confirmed.json()["source"]["id"])

    requested_symbols: list[str] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requested_symbols.append(request.url.params["symbol"])
        return httpx.Response(
            200,
            json={
                "Global Quote": {
                    "05. price": "120.00",
                    "07. latest trading day": _day(1),
                }
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        provider = AlphaVantageMarketQuoteProvider(
            api_key="server-only-key",
            client=http,
            request_limit=25,
        )
        with patch(
            "app.services.finance.assets.configured_market_quote_provider",
            return_value=provider,
        ):
            refreshed = await client.post(
                "/api/finance/assets/hl/refresh-prices",
                params={"space_id": household_id},
                headers=adult_a_headers,
            )

    assert refreshed.status_code == 200, refreshed.text
    assert {item["source_id"] for item in refreshed.json()} == set(source_ids)
    assert [item["priced_holding_count"] for item in refreshed.json()] == [1, 1]
    assert requested_symbols == ["TEST.LON"]


@pytest.mark.asyncio
async def test_history_uses_the_exact_pre_range_balance_as_its_baseline(
    client,
    initialized_db,
    adult_a_user,
    adult_a_headers,
):
    spaces = (await client.get("/api/finance/spaces", headers=adult_a_headers)).json()
    household_id = next(space["id"] for space in spaces if space["kind"] == "household")
    async with aiosqlite.connect(initialized_db) as db:
        await db.execute(
            """
            INSERT INTO finance_accounts
                (id, space_id, label, account_type, purpose, currency,
                 family_id, created_by)
            VALUES ('baseline-savings', ?, 'House savings', 'SAVINGS', 'GOAL',
                    'GBP', ?, ?)
            """,
            (household_id, adult_a_user["family_id"], adult_a_user["id"]),
        )
        await db.executemany(
            """
            INSERT INTO finance_balance_snapshots
                (id, space_id, account_id, booked_minor, currency,
                 observed_at, family_id, created_by)
            VALUES (?, ?, 'baseline-savings', ?, 'GBP', ?, ?, ?)
            """,
            [
                (
                    "baseline-ancient",
                    household_id,
                    25_000,
                    f"{_day(1_000)}T08:00:00+00:00",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
                (
                    "baseline-before-range",
                    household_id,
                    100_000,
                    f"{_day(40)}T08:00:00+00:00",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
                (
                    "baseline-in-range",
                    household_id,
                    150_000,
                    f"{_day(10)}T08:00:00+00:00",
                    adult_a_user["family_id"],
                    adult_a_user["id"],
                ),
            ],
        )
        await db.commit()

    response = await client.get(
        "/api/finance/assets/net-worth-history",
        params={"space_id": household_id, "currency": "GBP", "days": 30},
        headers=adult_a_headers,
    )

    assert response.status_code == 200, response.text
    history = response.json()
    assert [point["as_of_date"] for point in history["points"]] == [
        _day(29),
        _day(10),
        _day(0),
    ]
    assert [point["total_minor"] for point in history["points"]] == [
        100_000,
        150_000,
        150_000,
    ]
    assert history["change_minor"] == 50_000


@pytest.mark.asyncio
async def test_alphavantage_key_never_comes_from_the_browser():
    from app.services.finance.market_prices import AlphaVantageMarketQuoteProvider

    with pytest.raises(ValueError):
        AlphaVantageMarketQuoteProvider(api_key="")


@pytest.mark.asyncio
async def test_alphavantage_daily_quote_uses_the_provider_date():
    from app.services.finance.market_prices import AlphaVantageMarketQuoteProvider

    requested_symbols: list[str] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.params["function"] == "GLOBAL_QUOTE"
        assert request.url.params["apikey"] == "server-only-key"
        requested_symbols.append(request.url.params["symbol"])
        return httpx.Response(
            200,
            json={
                "Global Quote": {
                    "01. symbol": "TEST.LON",
                    "05. price": "123.45",
                    "07. latest trading day": "2026-08-01",
                }
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        provider = AlphaVantageMarketQuoteProvider(
            api_key="server-only-key", client=http, request_limit=1
        )
        quote = await provider.fetch("TEST.LON")
        duplicate = await provider.fetch("TEST.LON")
        with pytest.raises(MarketPriceUnavailable):
            await provider.fetch("SECOND.LON")
    assert quote.price == Decimal("123.45")
    assert duplicate == quote
    assert requested_symbols == ["TEST.LON"]
    assert quote.observed_at.isoformat().startswith("2026-08-01T23:59:59")
    assert quote.source_label == "Alpha Vantage daily close"
