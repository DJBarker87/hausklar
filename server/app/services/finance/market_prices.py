"""Fixed, read-only market-price providers for reviewed investment holdings."""

from dataclasses import dataclass
from datetime import datetime, time, timezone
from decimal import Decimal, InvalidOperation
from typing import Protocol

import httpx

from app.config import settings

ALPHA_VANTAGE_URL = "https://www.alphavantage.co/query"
ALPHA_VANTAGE_FREE_DAILY_REQUEST_LIMIT = 25


class MarketPriceUnavailable(ValueError):
    """A public quote was not available; callers should keep the last value."""


@dataclass(frozen=True)
class MarketQuote:
    symbol: str
    price: Decimal
    observed_at: datetime
    source_label: str


@dataclass(frozen=True)
class MarketExchangeRate:
    from_currency: str
    to_currency: str
    rate: Decimal
    observed_at: datetime
    source_label: str


class MarketQuoteProvider(Protocol):
    async def fetch(self, symbol: str) -> MarketQuote: ...

    async def fetch_exchange_rate(
        self,
        from_currency: str,
        to_currency: str,
    ) -> MarketExchangeRate: ...


class ManualMarketQuoteProvider:
    """Deterministic fallback when no external price service is configured."""

    async def fetch(self, symbol: str) -> MarketQuote:
        del symbol
        raise MarketPriceUnavailable("No public price service is configured")

    async def fetch_exchange_rate(
        self,
        from_currency: str,
        to_currency: str,
    ) -> MarketExchangeRate:
        del from_currency, to_currency
        raise MarketPriceUnavailable("No public exchange-rate service is configured")

    async def aclose(self) -> None:
        """Match the network provider lifecycle without allocating resources."""


class AlphaVantageMarketQuoteProvider:
    """Read the provider's end-of-day global quote endpoint using a server key."""

    def __init__(
        self,
        *,
        api_key: str,
        client: httpx.AsyncClient | None = None,
        request_limit: int | None = ALPHA_VANTAGE_FREE_DAILY_REQUEST_LIMIT,
    ) -> None:
        if not api_key.strip():
            raise ValueError("An Alpha Vantage API key is required")
        self._api_key = api_key.strip()
        self._client = client
        self._owns_client = client is None
        self._request_limit = request_limit
        self._request_count = 0
        self._quotes: dict[str, MarketQuote | MarketPriceUnavailable] = {}
        self._exchange_rates: dict[
            tuple[str, str], MarketExchangeRate | MarketPriceUnavailable
        ] = {}

    def _claim_request(self) -> None:
        if self._request_limit is not None and self._request_count >= self._request_limit:
            raise MarketPriceUnavailable("The public price request budget has been used")
        self._request_count += 1

    async def _http_client(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=settings.finance_market_price_timeout_seconds)
        return self._client

    async def fetch(self, symbol: str) -> MarketQuote:
        symbol = symbol.strip()
        cached = self._quotes.get(symbol)
        if isinstance(cached, MarketQuote):
            return cached
        if isinstance(cached, MarketPriceUnavailable):
            raise MarketPriceUnavailable(str(cached))
        try:
            self._claim_request()
            client = await self._http_client()
            response = await client.get(
                ALPHA_VANTAGE_URL,
                params={
                    "function": "GLOBAL_QUOTE",
                    "symbol": symbol,
                    "apikey": self._api_key,
                },
            )
            response.raise_for_status()
            payload = response.json()
            quote = payload.get("Global Quote")
            if not isinstance(quote, dict):
                raise MarketPriceUnavailable("The public price service returned no quote")
            raw_price = quote.get("05. price")
            raw_day = quote.get("07. latest trading day")
            try:
                price = Decimal(str(raw_price))
                observed_day = datetime.strptime(str(raw_day), "%Y-%m-%d").date()
            except (InvalidOperation, TypeError, ValueError) as exc:
                raise MarketPriceUnavailable(
                    "The public price service returned an invalid quote"
                ) from exc
            if not price.is_finite() or price < 0:
                raise MarketPriceUnavailable("The public price service returned an invalid quote")
            result = MarketQuote(
                symbol=symbol,
                price=price,
                observed_at=datetime.combine(observed_day, time.max, tzinfo=timezone.utc),
                source_label="Alpha Vantage daily close",
            )
            self._quotes[symbol] = result
            return result
        except MarketPriceUnavailable as exc:
            self._quotes[symbol] = exc
            raise
        except (httpx.HTTPError, ValueError) as exc:
            error = MarketPriceUnavailable("The public price service is temporarily unavailable")
            self._quotes[symbol] = error
            raise error from exc

    async def fetch_exchange_rate(
        self,
        from_currency: str,
        to_currency: str,
    ) -> MarketExchangeRate:
        from_currency = from_currency.strip().upper()
        to_currency = to_currency.strip().upper()
        key = (from_currency, to_currency)
        if from_currency == to_currency:
            return MarketExchangeRate(
                from_currency=from_currency,
                to_currency=to_currency,
                rate=Decimal(1),
                observed_at=datetime.now(timezone.utc),
                source_label="No currency conversion",
            )
        cached = self._exchange_rates.get(key)
        if isinstance(cached, MarketExchangeRate):
            return cached
        if isinstance(cached, MarketPriceUnavailable):
            raise MarketPriceUnavailable(str(cached))
        try:
            self._claim_request()
            client = await self._http_client()
            response = await client.get(
                ALPHA_VANTAGE_URL,
                params={
                    "function": "CURRENCY_EXCHANGE_RATE",
                    "from_currency": from_currency,
                    "to_currency": to_currency,
                    "apikey": self._api_key,
                },
            )
            response.raise_for_status()
            payload = response.json()
            exchange = payload.get("Realtime Currency Exchange Rate")
            if not isinstance(exchange, dict):
                raise MarketPriceUnavailable(
                    "The public price service returned no exchange rate"
                )
            try:
                rate = Decimal(str(exchange.get("5. Exchange Rate")))
                observed_at = datetime.strptime(
                    str(exchange.get("6. Last Refreshed")),
                    "%Y-%m-%d %H:%M:%S",
                ).replace(tzinfo=timezone.utc)
            except (InvalidOperation, TypeError, ValueError) as exc:
                raise MarketPriceUnavailable(
                    "The public price service returned an invalid exchange rate"
                ) from exc
            if not rate.is_finite() or rate <= 0:
                raise MarketPriceUnavailable(
                    "The public price service returned an invalid exchange rate"
                )
            result = MarketExchangeRate(
                from_currency=from_currency,
                to_currency=to_currency,
                rate=rate,
                observed_at=observed_at,
                source_label="Alpha Vantage exchange rate",
            )
            self._exchange_rates[key] = result
            return result
        except MarketPriceUnavailable as exc:
            self._exchange_rates[key] = exc
            raise
        except (httpx.HTTPError, ValueError) as exc:
            error = MarketPriceUnavailable(
                "The public exchange-rate service is temporarily unavailable"
            )
            self._exchange_rates[key] = error
            raise error from exc

    async def aclose(self) -> None:
        """Close a lazily-created shared client after a refresh batch."""
        if self._owns_client and self._client is not None:
            await self._client.aclose()
            self._client = None


async def close_market_quote_provider(provider: MarketQuoteProvider) -> None:
    """Close providers that own resources while accepting simple test adapters."""
    close = getattr(provider, "aclose", None)
    if close is not None:
        await close()


def configured_market_quote_provider() -> MarketQuoteProvider:
    if (
        settings.finance_market_price_provider == "alphavantage"
        and settings.finance_alphavantage_api_key.strip()
    ):
        return AlphaVantageMarketQuoteProvider(api_key=settings.finance_alphavantage_api_key)
    return ManualMarketQuoteProvider()
