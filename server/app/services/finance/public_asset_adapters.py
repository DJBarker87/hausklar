"""Fixed, read-only public-chain adapters for watch-only Finance sources.

These adapters accept only a validated public address.  Endpoint selection and
request shape are controlled here: there is no caller-supplied URL, credential,
signing material, transaction payload, payment, or trading operation.
"""

from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

import httpx

from app.models.finance_products_assets import FinanceAssetHoldingInput

SOLANA_PUBLIC_RPC = "https://api.mainnet-beta.solana.com"
HYPERLIQUID_PUBLIC_INFO = "https://api.hyperliquid.xyz/info"
_MAX_PUBLIC_POSITIONS = 1_000


class PublicAssetAdapterError(ValueError):
    """A fixed public data source could not provide a safe snapshot."""


@dataclass(frozen=True)
class PublicAssetSnapshot:
    as_of_at: datetime
    currency: str
    positions: tuple[FinanceAssetHoldingInput, ...]


def _decimal(value: object, *, field: str) -> Decimal:
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise PublicAssetAdapterError(f"Public {field} was not numeric") from exc
    if not parsed.is_finite():
        raise PublicAssetAdapterError(f"Public {field} was not finite")
    return parsed


def _usd_minor(value: object, *, field: str) -> int:
    return int(
        (_decimal(value, field=field) * Decimal(100)).to_integral_value(
            rounding=ROUND_HALF_UP
        )
    )


class SolanaPublicAdapter:
    """Read native and SPL balances from Solana's fixed public RPC."""

    def __init__(self, client: httpx.AsyncClient | None = None) -> None:
        self._client = client

    async def fetch(self, public_address: str) -> PublicAssetSnapshot:
        owns_client = self._client is None
        client = self._client or httpx.AsyncClient(timeout=15.0)
        try:
            native_response = await client.post(
                SOLANA_PUBLIC_RPC,
                json={
                    "jsonrpc": "2.0",
                    "id": "hausklar-native-balance",
                    "method": "getBalance",
                    "params": [public_address, {"commitment": "confirmed"}],
                },
            )
            native_response.raise_for_status()
            native_payload = native_response.json()
            lamports = _decimal(
                native_payload["result"]["value"], field="Solana balance"
            )

            token_response = await client.post(
                SOLANA_PUBLIC_RPC,
                json={
                    "jsonrpc": "2.0",
                    "id": "hausklar-token-balances",
                    "method": "getTokenAccountsByOwner",
                    "params": [
                        public_address,
                        {"programId": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"},
                        {"encoding": "jsonParsed", "commitment": "confirmed"},
                    ],
                },
            )
            token_response.raise_for_status()
            token_rows = token_response.json()["result"]["value"]
            if not isinstance(token_rows, list) or len(token_rows) > _MAX_PUBLIC_POSITIONS:
                raise PublicAssetAdapterError("Public Solana position count is invalid")
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
            if isinstance(exc, PublicAssetAdapterError):
                raise
            raise PublicAssetAdapterError(
                "Solana public balances are temporarily unavailable"
            ) from exc
        finally:
            if owns_client:
                await client.aclose()

        positions = []
        if lamports != 0:
            positions.append(
                FinanceAssetHoldingInput(
                    asset_key="solana:SOL",
                    asset_name="Solana",
                    asset_class="VOLATILE_CRYPTO",
                    quantity=lamports / Decimal(1_000_000_000),
                    quantity_unit="SOL",
                    value_minor=None,
                )
            )
        for token_row in token_rows:
            try:
                info = token_row["account"]["data"]["parsed"]["info"]
                mint = str(info["mint"])
                token_amount = info["tokenAmount"]
                quantity = _decimal(token_amount["uiAmountString"], field="token balance")
            except (KeyError, TypeError, ValueError) as exc:
                raise PublicAssetAdapterError(
                    "Solana returned an unsupported token balance"
                ) from exc
            if quantity == 0:
                continue
            positions.append(
                FinanceAssetHoldingInput(
                    asset_key=f"solana:{mint}",
                    asset_name=f"Solana token {mint[:8]}",
                    asset_class="VOLATILE_CRYPTO",
                    quantity=quantity,
                    quantity_unit="token",
                    value_minor=None,
                )
            )
        return PublicAssetSnapshot(
            as_of_at=datetime.now(timezone.utc),
            currency="USD",
            positions=tuple(positions),
        )


class HyperliquidPublicAdapter:
    """Read public account equity and exposures from fixed info endpoints only."""

    def __init__(self, client: httpx.AsyncClient | None = None) -> None:
        self._client = client

    async def fetch(self, public_address: str) -> PublicAssetSnapshot:
        owns_client = self._client is None
        client = self._client or httpx.AsyncClient(timeout=15.0)
        try:
            clearing_response = await client.post(
                HYPERLIQUID_PUBLIC_INFO,
                json={"type": "clearinghouseState", "user": public_address},
            )
            clearing_response.raise_for_status()
            clearing = clearing_response.json()
            spot_response = await client.post(
                HYPERLIQUID_PUBLIC_INFO,
                json={"type": "spotClearinghouseState", "user": public_address},
            )
            spot_response.raise_for_status()
            spot = spot_response.json()
            asset_positions = clearing.get("assetPositions", [])
            spot_balances = spot.get("balances", [])
            if (
                not isinstance(asset_positions, list)
                or not isinstance(spot_balances, list)
                or len(asset_positions) + len(spot_balances) > _MAX_PUBLIC_POSITIONS
            ):
                raise PublicAssetAdapterError(
                    "Public Hyperliquid position count is invalid"
                )
            account_value = clearing["marginSummary"]["accountValue"]
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
            if isinstance(exc, PublicAssetAdapterError):
                raise
            raise PublicAssetAdapterError(
                "Hyperliquid public balances are temporarily unavailable"
            ) from exc
        finally:
            if owns_client:
                await client.aclose()

        account_quantity = _decimal(account_value, field="account equity")
        account_minor = _usd_minor(account_value, field="account equity")
        positions = [
            FinanceAssetHoldingInput(
                asset_key="hyperliquid:account-equity",
                asset_name="Hyperliquid account equity",
                asset_class=("LIABILITY" if account_minor < 0 else "VOLATILE_CRYPTO"),
                position_kind=("DEBT" if account_minor < 0 else "EQUITY"),
                include_in_net_worth=True,
                quantity=abs(account_quantity),
                quantity_unit="USD",
                value_minor=abs(account_minor),
                price_source="Hyperliquid public account state",
            )
        ]
        for row in asset_positions:
            try:
                position = row["position"]
                coin = str(position["coin"])
                size = _decimal(position["szi"], field="position size")
                exposure = _usd_minor(position["positionValue"], field="position value")
                pnl = _usd_minor(position["unrealizedPnl"], field="unrealised PnL")
            except (KeyError, TypeError, ValueError) as exc:
                raise PublicAssetAdapterError(
                    "Hyperliquid returned an unsupported public position"
                ) from exc
            positions.extend(
                (
                    FinanceAssetHoldingInput(
                        asset_key=f"hyperliquid:{coin}:exposure",
                        asset_name=f"{coin} exposure",
                        asset_class="VOLATILE_CRYPTO",
                        position_kind="EXPOSURE",
                        include_in_net_worth=False,
                        quantity=size,
                        quantity_unit=coin,
                        value_minor=exposure,
                        price_source="Hyperliquid public account state",
                    ),
                    FinanceAssetHoldingInput(
                        asset_key=f"hyperliquid:{coin}:pnl",
                        asset_name=f"{coin} unrealised PnL",
                        asset_class="VOLATILE_CRYPTO",
                        position_kind="UNREALISED_PNL",
                        include_in_net_worth=False,
                        quantity=Decimal(pnl),
                        quantity_unit="USD minor",
                        value_minor=pnl,
                        price_source="Hyperliquid public account state",
                    ),
                )
            )
        for row in spot_balances:
            try:
                coin = str(row["coin"])
                total = _decimal(row["total"], field="spot balance")
            except (KeyError, TypeError, ValueError) as exc:
                raise PublicAssetAdapterError(
                    "Hyperliquid returned an unsupported public spot balance"
                ) from exc
            if total == 0:
                continue
            positions.append(
                FinanceAssetHoldingInput(
                    asset_key=f"hyperliquid:spot:{coin}",
                    asset_name=f"Hyperliquid spot {coin}",
                    asset_class=(
                        "STABLE_CRYPTO"
                        if coin.upper() in {"USDC", "USDT", "USDH"}
                        else "VOLATILE_CRYPTO"
                    ),
                    include_in_net_worth=True,
                    quantity=total,
                    quantity_unit=coin,
                    value_minor=None,
                )
            )
        return PublicAssetSnapshot(
            as_of_at=datetime.now(timezone.utc),
            currency="USD",
            positions=tuple(positions),
        )


class PublicAssetAdapterRegistry:
    """Closed registry: supported source kind determines the fixed adapter."""

    def __init__(
        self,
        *,
        solana: SolanaPublicAdapter | None = None,
        hyperliquid: HyperliquidPublicAdapter | None = None,
    ) -> None:
        self._adapters = {
            "SOLANA_PUBLIC": solana or SolanaPublicAdapter(),
            "HYPERLIQUID_PUBLIC": hyperliquid or HyperliquidPublicAdapter(),
        }

    def for_source_kind(self, source_kind: str):
        try:
            return self._adapters[source_kind]
        except KeyError as exc:
            raise PublicAssetAdapterError("Asset source is not refreshable") from exc
