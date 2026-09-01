"""Bounded, read-only account and card TrueLayer Data API v1 adapter."""

from __future__ import annotations

import ipaddress
import json
import logging
import uuid
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from typing import Any
from urllib.parse import quote, urlencode, urlparse

import httpx

from app.services.finance.money import normalise_currency
from app.services.finance.providers.base import (
    ProviderAccount,
    ProviderBalance,
    ProviderResponseError,
    ProviderTransaction,
    ProviderTransportError,
    TransactionPage,
    TransactionPages,
    TransactionState,
)

logger = logging.getLogger(__name__)

TRUELAYER_AUTH_ORIGIN = "https://auth.truelayer.com"
TRUELAYER_DATA_ORIGIN = "https://api.truelayer.com"
TRUELAYER_SCOPES = (
    "accounts",
    "cards",
    "balance",
    "transactions",
    "offline_access",
)
TRUELAYER_PROVIDERS = ("uk-ob-all", "uk-oauth-all")

DEFAULT_TIMEOUT = httpx.Timeout(15.0, connect=5.0, read=10.0, write=10.0, pool=5.0)
_MAX_TOKEN_RESPONSE_BYTES = 128 * 1024
_MAX_DATA_RESPONSE_BYTES = 2 * 1024 * 1024
_MAX_TOKEN_LENGTH = 64 * 1024
_MAX_ACCOUNTS = 100
_MAX_TRANSACTIONS = 10_000
_MAX_TRANSACTION_DAYS = 370
_MAX_TEXT_LENGTH = 500
_SAFE_ACCOUNT_ID = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
)


class TrueLayerReauthorisationRequired(ProviderResponseError):
    """The bank consent or refresh credential can no longer be used."""


class TrueLayerAccessTokenExpired(ProviderResponseError):
    """The short-lived access token needs one server-side refresh."""


class TrueLayerRateLimited(ProviderTransportError):
    """The provider's bounded unattended-call allowance has been reached."""


@dataclass(frozen=True, slots=True)
class TrueLayerCredentials:
    """Secret connection material returned for encrypted server-side storage."""

    access_token: str = field(repr=False)
    refresh_token: str = field(repr=False)
    access_expires_at: datetime
    scopes: frozenset[str]
    token_type: str = "Bearer"

    def __post_init__(self) -> None:
        if not self.access_token or len(self.access_token) > _MAX_TOKEN_LENGTH:
            raise ValueError("TrueLayer access credential is invalid")
        if not self.refresh_token or len(self.refresh_token) > _MAX_TOKEN_LENGTH:
            raise ValueError("TrueLayer refresh credential is invalid")
        if self.token_type.casefold() != "bearer":
            raise ValueError("TrueLayer token type is invalid")
        if self.access_expires_at.tzinfo is None or self.access_expires_at.utcoffset() is None:
            raise ValueError("TrueLayer access expiry must include a timezone")
        if self.scopes != frozenset(TRUELAYER_SCOPES):
            raise ValueError("TrueLayer credential scopes are invalid")


@dataclass(frozen=True, slots=True)
class TrueLayerAccounts:
    accounts: tuple[ProviderAccount, ...]
    provider_id: str | None
    institution_name: str
    credentials_id: str | None


class TrueLayerAdapter:
    """Translate TrueLayer v1 responses without hiding OAuth token rotation."""

    def __init__(
        self,
        *,
        client: httpx.AsyncClient,
        client_id: str,
        client_secret: str,
        redirect_uri: str,
        timeout: httpx.Timeout = DEFAULT_TIMEOUT,
        end_user_ip: str | None = None,
    ) -> None:
        self._client = client
        self._client_id = self._bounded_secret(client_id, "client ID", maximum=500)
        self._client_secret = self._bounded_secret(
            client_secret,
            "client secret",
            maximum=2_000,
        )
        self._redirect_uri = self._https_url(redirect_uri, "redirect URI")
        self._timeout = timeout
        self._end_user_ip = self._public_ip(end_user_ip)

    def for_end_user(self, end_user_ip: str | None) -> TrueLayerAdapter:
        """Return a request-scoped adapter that may mark Data API calls as attended."""
        return TrueLayerAdapter(
            client=self._client,
            client_id=self._client_id,
            client_secret=self._client_secret,
            redirect_uri=self._redirect_uri,
            timeout=self._timeout,
            end_user_ip=end_user_ip,
        )

    def build_authorisation_url(self, *, state: str) -> str:
        """Build one hosted TrueLayer journey with a fixed read-only grant."""
        state_value = self._bounded_secret(state, "state", maximum=500)
        if len(state_value) < 20:
            raise ValueError("TrueLayer state is too short")
        query = urlencode(
            {
                "response_type": "code",
                "client_id": self._client_id,
                "redirect_uri": self._redirect_uri,
                "scope": " ".join(TRUELAYER_SCOPES),
                "providers": " ".join(TRUELAYER_PROVIDERS),
                "state": state_value,
            },
            quote_via=quote,
        )
        return f"{TRUELAYER_AUTH_ORIGIN}/?{query}"

    async def exchange_code(
        self,
        code: str,
        *,
        now: datetime | None = None,
    ) -> TrueLayerCredentials:
        """Exchange one callback code; raw credentials never enter an error."""
        payload = await self._token_request(
            {
                "grant_type": "authorization_code",
                "client_id": self._client_id,
                "client_secret": self._client_secret,
                "redirect_uri": self._redirect_uri,
                "code": self._bounded_secret(code, "authorisation code", maximum=2_000),
            }
        )
        return self._parse_credentials(payload, now=now)

    async def refresh_credentials(
        self,
        refresh_token: str,
        *,
        now: datetime | None = None,
    ) -> TrueLayerCredentials:
        """Return the full replacement bundle so callers can persist rotation first."""
        payload = await self._token_request(
            {
                "grant_type": "refresh_token",
                "client_id": self._client_id,
                "client_secret": self._client_secret,
                "refresh_token": self._bounded_secret(
                    refresh_token,
                    "refresh credential",
                    maximum=_MAX_TOKEN_LENGTH,
                ),
            }
        )
        return self._parse_credentials(payload, now=now)

    async def accounts(self, credentials: TrueLayerCredentials) -> TrueLayerAccounts:
        response, headers = await self._data_request(credentials, "/data/v1/accounts")
        items = self._results(response, maximum=_MAX_ACCOUNTS, label="accounts")
        accounts = tuple(self._parse_account(item) for item in items)
        provider_ids = {
            provider_id
            for item in items
            if (provider_id := self._resource_provider_id(item)) is not None
        }
        if len(provider_ids) > 1:
            raise ProviderResponseError("TrueLayer returned accounts from mixed providers")
        provider_id = next(iter(provider_ids), None)
        provider_name = self._provider_name(items, provider_id)
        credentials_id = self._optional_header(headers, "X-Credentials-Id", maximum=500)
        return TrueLayerAccounts(
            accounts=accounts,
            provider_id=provider_id,
            institution_name=provider_name,
            credentials_id=credentials_id,
        )

    async def cards(self, credentials: TrueLayerCredentials) -> TrueLayerAccounts:
        response, headers = await self._data_request(credentials, "/data/v1/cards")
        items = self._results(response, maximum=_MAX_ACCOUNTS, label="cards")
        cards = tuple(self._parse_card(item) for item in items)
        provider_ids = {
            provider_id
            for item in items
            if (provider_id := self._resource_provider_id(item)) is not None
        }
        if len(provider_ids) > 1:
            raise ProviderResponseError("TrueLayer returned cards from mixed providers")
        provider_id = next(iter(provider_ids), None)
        provider_name = self._provider_name(items, provider_id)
        credentials_id = self._optional_header(headers, "X-Credentials-Id", maximum=500)
        return TrueLayerAccounts(
            accounts=cards,
            provider_id=provider_id,
            institution_name=provider_name,
            credentials_id=credentials_id,
        )

    async def balances(
        self,
        credentials: TrueLayerCredentials,
        provider_account_id: str,
        *,
        resource_type: str = "ACCOUNT",
    ) -> tuple[ProviderBalance, ...]:
        account_id = self._account_id(provider_account_id)
        resource_path = self._resource_path(resource_type)
        response, _ = await self._data_request(
            credentials,
            f"/data/v1/{resource_path}/{account_id}/balance",
        )
        items = self._results(response, maximum=10, label="balances")
        balances: list[ProviderBalance] = []
        for source in items:
            item = self._mapping(source, "balance")
            currency = normalise_currency(self._required_string(item, "currency", maximum=3))
            changed_at = self._optional_datetime(item.get("update_timestamp"), "balance timestamp")
            current = self._decimal(item.get("current"), "current balance")
            if resource_path == "cards":
                current = -current
            balances.append(
                ProviderBalance(
                    amount=current,
                    currency=currency,
                    balance_type="BOOKED",
                    name="Current balance",
                    reference_date=changed_at.date() if changed_at else None,
                    changed_at=changed_at,
                )
            )
            if item.get("available") is not None:
                balances.append(
                    ProviderBalance(
                        amount=self._decimal(item.get("available"), "available balance"),
                        currency=currency,
                        balance_type="AVAILABLE",
                        name="Available balance",
                        reference_date=changed_at.date() if changed_at else None,
                        changed_at=changed_at,
                    )
                )
            if resource_path == "cards" and item.get("credit_limit") is not None:
                balances.append(
                    ProviderBalance(
                        amount=self._decimal(item.get("credit_limit"), "credit limit"),
                        currency=currency,
                        balance_type="CREDIT_LIMIT",
                        name="Credit limit",
                        reference_date=changed_at.date() if changed_at else None,
                        changed_at=changed_at,
                    )
                )
        return tuple(balances)

    async def transaction_pages(
        self,
        credentials: TrueLayerCredentials,
        provider_account_id: str,
        *,
        state: TransactionState,
        date_from: date | None = None,
        date_to: date | None = None,
        resource_type: str = "ACCOUNT",
    ) -> TransactionPages:
        account_id = self._account_id(provider_account_id)
        resource_path = self._resource_path(resource_type)
        if not isinstance(state, TransactionState):
            raise ValueError("state must be booked or pending")
        end = date_to or datetime.now(timezone.utc).date()
        start = date_from or (end - timedelta(days=90))
        if start > end:
            raise ValueError("date_from cannot be after date_to")
        if (end - start).days > _MAX_TRANSACTION_DAYS:
            raise ValueError("TrueLayer transaction window is too large")
        suffix = "transactions" if state is TransactionState.BOOKED else "transactions/pending"
        response, _ = await self._data_request(
            credentials,
            f"/data/v1/{resource_path}/{account_id}/{suffix}",
            params=(
                {"from": start.isoformat(), "to": end.isoformat()}
                if state is TransactionState.BOOKED
                else None
            ),
        )
        items = self._results(response, maximum=_MAX_TRANSACTIONS, label="transactions")
        transactions = tuple(
            self._parse_transaction(
                item,
                state=state,
                reverse_card_sign=resource_path == "cards",
            )
            for item in items
        )
        return TransactionPages(
            pages=(TransactionPage(transactions=transactions, page_number=1),),
            truncated=False,
        )

    async def _token_request(self, form: Mapping[str, str]) -> dict[str, Any]:
        client_correlation_id = str(uuid.uuid4())
        try:
            async with self._client.stream(
                "POST",
                f"{TRUELAYER_AUTH_ORIGIN}/connect/token",
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "X-Client-Correlation-Id": client_correlation_id,
                },
                data=form,
                timeout=self._timeout,
                follow_redirects=False,
            ) as response:
                status_code = response.status_code
                provider_correlation_id = self._provider_correlation_id(response.headers)
                if status_code >= 500:
                    self._log_provider_failure(
                        operation="authentication",
                        status_code=status_code,
                        client_correlation_id=client_correlation_id,
                        provider_correlation_id=provider_correlation_id,
                    )
                    raise ProviderTransportError(
                        "TrueLayer authentication is unavailable"
                    )
                try:
                    payload = await self._bounded_json(
                        response,
                        maximum=_MAX_TOKEN_RESPONSE_BYTES,
                    )
                except ProviderResponseError:
                    self._log_provider_failure(
                        operation="authentication",
                        status_code=status_code,
                        client_correlation_id=client_correlation_id,
                        provider_correlation_id=provider_correlation_id,
                    )
                    raise
        except httpx.HTTPError:
            self._log_provider_failure(
                operation="authentication",
                status_code=None,
                client_correlation_id=client_correlation_id,
                provider_correlation_id=None,
            )
            raise ProviderTransportError("TrueLayer authentication is unavailable") from None
        if status_code < 200 or status_code >= 300:
            self._log_provider_failure(
                operation="authentication",
                status_code=status_code,
                client_correlation_id=client_correlation_id,
                provider_correlation_id=provider_correlation_id,
            )
            code = payload.get("error") if isinstance(payload.get("error"), str) else ""
            if code in {"invalid_grant", "invalid_authorization_code"}:
                raise TrueLayerReauthorisationRequired(
                    "TrueLayer bank authorisation needs to be renewed"
                )
            raise ProviderResponseError("TrueLayer authentication failed")
        return payload

    async def _data_request(
        self,
        credentials: TrueLayerCredentials,
        path: str,
        *,
        params: Mapping[str, str] | None = None,
    ) -> tuple[dict[str, Any], httpx.Headers]:
        if not path.startswith("/data/v1/"):
            raise ValueError("TrueLayer data path is invalid")
        client_correlation_id = str(uuid.uuid4())
        request_headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {credentials.access_token}",
            "X-Client-Correlation-Id": client_correlation_id,
        }
        if self._end_user_ip is not None:
            request_headers["X-PSU-IP"] = self._end_user_ip
        try:
            async with self._client.stream(
                "GET",
                f"{TRUELAYER_DATA_ORIGIN}{path}",
                headers=request_headers,
                params=params,
                timeout=self._timeout,
                follow_redirects=False,
            ) as response:
                status_code = response.status_code
                response_headers = httpx.Headers(response.headers)
                provider_correlation_id = self._provider_correlation_id(response_headers)
                if status_code >= 500:
                    self._log_provider_failure(
                        operation="data",
                        status_code=status_code,
                        client_correlation_id=client_correlation_id,
                        provider_correlation_id=provider_correlation_id,
                    )
                    raise ProviderTransportError(
                        "TrueLayer data is temporarily unavailable"
                    )
                try:
                    payload = await self._bounded_json(
                        response,
                        maximum=_MAX_DATA_RESPONSE_BYTES,
                    )
                except ProviderResponseError:
                    self._log_provider_failure(
                        operation="data",
                        status_code=status_code,
                        client_correlation_id=client_correlation_id,
                        provider_correlation_id=provider_correlation_id,
                    )
                    raise
        except httpx.HTTPError:
            self._log_provider_failure(
                operation="data",
                status_code=None,
                client_correlation_id=client_correlation_id,
                provider_correlation_id=None,
            )
            raise ProviderTransportError("TrueLayer data is temporarily unavailable") from None
        if status_code < 200 or status_code >= 300:
            self._log_provider_failure(
                operation="data",
                status_code=status_code,
                client_correlation_id=client_correlation_id,
                provider_correlation_id=provider_correlation_id,
            )
            code = payload.get("error") if isinstance(payload.get("error"), str) else ""
            if status_code == 401 or code in {"invalid_token", "unauthorized"}:
                raise TrueLayerAccessTokenExpired("TrueLayer access credential has expired")
            if code in {"access_denied", "invalid_grant"}:
                raise TrueLayerReauthorisationRequired(
                    "TrueLayer bank authorisation needs to be renewed"
                )
            if status_code == 429:
                raise TrueLayerRateLimited("TrueLayer refresh allowance has been reached")
            if status_code >= 500:
                raise ProviderTransportError("TrueLayer data is temporarily unavailable")
            raise ProviderResponseError("TrueLayer returned an unusable data response")
        return payload, response_headers

    @staticmethod
    def _log_provider_failure(
        *,
        operation: str,
        status_code: int | None,
        client_correlation_id: str,
        provider_correlation_id: str | None,
    ) -> None:
        logger.warning(
            "TrueLayer %s request failed status=%s client_correlation_id=%s "
            "provider_correlation_id=%s",
            operation,
            status_code if status_code is not None else "transport",
            client_correlation_id,
            provider_correlation_id or "unavailable",
        )

    @staticmethod
    def _provider_correlation_id(headers: Mapping[str, str]) -> str | None:
        value = headers.get("X-TL-Correlation-Id")
        if value is None:
            return None
        candidate = value.strip()
        if not 1 <= len(candidate) <= 128:
            return None
        if not all(
            character.isascii()
            and (character.isalnum() or character in "-._:")
            for character in candidate
        ):
            return None
        return candidate

    @staticmethod
    def _public_ip(value: str | None) -> str | None:
        if value is None or "%" in value:
            return None
        try:
            parsed = ipaddress.ip_address(value.strip())
        except ValueError:
            return None
        return parsed.compressed if parsed.is_global else None

    def _parse_credentials(
        self,
        payload: Mapping[str, Any],
        *,
        now: datetime | None,
    ) -> TrueLayerCredentials:
        observed_at = now or datetime.now(timezone.utc)
        if observed_at.tzinfo is None or observed_at.utcoffset() is None:
            raise ValueError("TrueLayer token clock must include a timezone")
        expires_in = payload.get("expires_in")
        if isinstance(expires_in, bool):
            raise ProviderResponseError("TrueLayer token lifetime is invalid")
        try:
            seconds = int(expires_in)
        except (TypeError, ValueError):
            raise ProviderResponseError("TrueLayer token lifetime is invalid") from None
        if not 1 <= seconds <= 7_200:
            raise ProviderResponseError("TrueLayer token lifetime is invalid")
        token_type = self._required_string(payload, "token_type", maximum=20)
        if token_type.casefold() != "bearer":
            raise ProviderResponseError("TrueLayer token type is invalid")
        raw_scope = payload.get("scope")
        if raw_scope is None:
            scopes = frozenset(TRUELAYER_SCOPES)
        elif isinstance(raw_scope, str):
            scopes = frozenset(raw_scope.split())
        elif isinstance(raw_scope, list) and all(isinstance(item, str) for item in raw_scope):
            scopes = frozenset(raw_scope)
        else:
            raise ProviderResponseError("TrueLayer token scopes are invalid")
        if scopes != frozenset(TRUELAYER_SCOPES):
            raise ProviderResponseError("TrueLayer token scopes are invalid")
        try:
            return TrueLayerCredentials(
                access_token=self._required_string(
                    payload,
                    "access_token",
                    maximum=_MAX_TOKEN_LENGTH,
                ),
                refresh_token=self._required_string(
                    payload,
                    "refresh_token",
                    maximum=_MAX_TOKEN_LENGTH,
                ),
                access_expires_at=observed_at.astimezone(timezone.utc)
                + timedelta(seconds=seconds),
                scopes=scopes,
                token_type="Bearer",
            )
        except ValueError as exc:
            raise ProviderResponseError("TrueLayer returned invalid credentials") from exc

    def _parse_account(self, source: object) -> ProviderAccount:
        item = self._mapping(source, "account")
        account_id = self._account_id(self._required_string(item, "account_id", maximum=200))
        account_type = self._required_string(item, "account_type", maximum=40).upper()
        type_map = {
            "TRANSACTION": "CACC",
            "BUSINESS_TRANSACTION": "CACC",
            "SAVINGS": "SVGS",
            "BUSINESS_SAVINGS": "SVGS",
        }
        try:
            normalised_type = type_map[account_type]
        except KeyError:
            raise ProviderResponseError("TrueLayer account type is unsupported") from None
        display_name = self._optional_string(item.get("display_name"), maximum=120)
        masked_identifier = self._masked_account_identifier(item.get("account_number"))
        return ProviderAccount(
            provider_account_id=account_id,
            currency=normalise_currency(self._required_string(item, "currency", maximum=3)),
            account_type=normalised_type,
            display_name=display_name,
            product=None,
            usage="PRIV",
            masked_identifier=masked_identifier,
            provider_resource_type="ACCOUNT",
        )

    def _parse_card(self, source: object) -> ProviderAccount:
        item = self._mapping(source, "card")
        account_id = self._account_id(
            self._required_string(item, "account_id", maximum=200)
        )
        card_type = self._required_string(item, "card_type", maximum=40).upper()
        if card_type not in {"CREDIT", "CHARGE"}:
            raise ProviderResponseError("TrueLayer card type is unsupported")
        partial_number = self._required_string(
            item,
            "partial_card_number",
            maximum=20,
        )
        digits = "".join(character for character in partial_number if character.isdigit())
        if len(digits) < 4:
            raise ProviderResponseError("TrueLayer partial card number is invalid")
        return ProviderAccount(
            provider_account_id=account_id,
            currency=normalise_currency(
                self._required_string(item, "currency", maximum=3)
            ),
            account_type="CARD",
            display_name=self._optional_string(item.get("display_name"), maximum=120),
            product=self._optional_string(item.get("card_network"), maximum=40),
            usage="PRIV",
            masked_identifier=f"••••{digits[-4:]}",
            provider_resource_type="CARD",
        )

    def _parse_transaction(
        self,
        source: object,
        *,
        state: TransactionState,
        reverse_card_sign: bool = False,
    ) -> ProviderTransaction:
        item = self._mapping(source, "transaction")
        timestamp = self._required_datetime(item.get("timestamp"), "transaction timestamp")
        transaction_id = self._optional_string(item.get("transaction_id"), maximum=500)
        stable_id = self._optional_string(
            item.get("normalised_provider_transaction_id"),
            maximum=500,
        ) or self._optional_string(item.get("provider_transaction_id"), maximum=500)
        description = self._optional_string(item.get("description"), maximum=_MAX_TEXT_LENGTH)
        merchant = self._optional_string(item.get("merchant_name"), maximum=200)
        remittance = tuple(value for value in (description,) if value)
        category = self._optional_string(item.get("transaction_category"), maximum=100)
        classification = item.get("transaction_classification")
        sub_category = None
        if isinstance(classification, list):
            values = [
                value.strip()
                for value in classification[:10]
                if isinstance(value, str) and value.strip()
            ]
            sub_category = "/".join(values)[:200] or None
        amount = self._decimal(item.get("amount"), "transaction amount")
        return ProviderTransaction(
            provider_reference=stable_id or transaction_id,
            provider_detail_id=(transaction_id if transaction_id != stable_id else None),
            amount=-amount if reverse_card_sign else amount,
            currency=normalise_currency(self._required_string(item, "currency", maximum=3)),
            state=state,
            booking_date=timestamp.date(),
            value_date=None,
            transaction_date=timestamp.date(),
            counterparty_name=merchant,
            remittance=remittance,
            merchant_category_code=None,
            bank_code=category,
            bank_sub_code=sub_category,
        )

    @classmethod
    async def _bounded_json(
        cls,
        response: httpx.Response,
        *,
        maximum: int,
    ) -> dict[str, Any]:
        content_length = response.headers.get("Content-Length")
        if content_length:
            try:
                if int(content_length) > maximum:
                    raise ProviderResponseError("TrueLayer response exceeded its size limit")
            except ValueError:
                raise ProviderResponseError("TrueLayer response length is invalid") from None
        content = bytearray()
        async for chunk in response.aiter_bytes(chunk_size=64 * 1024):
            if len(content) + len(chunk) > maximum:
                raise ProviderResponseError("TrueLayer response exceeded its size limit")
            content.extend(chunk)
        try:
            payload = json.loads(content)
        except (UnicodeDecodeError, ValueError):
            raise ProviderResponseError("TrueLayer returned invalid JSON") from None
        if not isinstance(payload, dict):
            raise ProviderResponseError("TrueLayer returned an invalid response")
        return payload

    @classmethod
    def _results(cls, payload: Mapping[str, Any], *, maximum: int, label: str) -> list[Any]:
        items = payload.get("results")
        if not isinstance(items, list):
            raise ProviderResponseError(f"TrueLayer {label} response is invalid")
        if len(items) > maximum:
            raise ProviderResponseError(f"TrueLayer returned too many {label}")
        return items

    @classmethod
    def _mapping(cls, value: object, label: str) -> Mapping[str, Any]:
        if not isinstance(value, Mapping):
            raise ProviderResponseError(f"TrueLayer {label} is invalid")
        return value

    @classmethod
    def _required_string(
        cls,
        payload: Mapping[str, Any],
        key: str,
        *,
        maximum: int,
    ) -> str:
        value = payload.get(key)
        if not isinstance(value, str) or not value.strip() or len(value) > maximum:
            raise ProviderResponseError(f"TrueLayer {key} is invalid")
        return value.strip()

    @classmethod
    def _optional_string(cls, value: object, *, maximum: int) -> str | None:
        if value is None:
            return None
        if not isinstance(value, str) or len(value) > maximum:
            raise ProviderResponseError("TrueLayer text field is invalid")
        return value.strip() or None

    @classmethod
    def _bounded_secret(cls, value: str, label: str, *, maximum: int) -> str:
        if not isinstance(value, str) or not value.strip() or len(value) > maximum:
            raise ValueError(f"TrueLayer {label} is invalid")
        return value.strip()

    @classmethod
    def _https_url(cls, value: str, label: str) -> str:
        parsed = urlparse(value.strip())
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.fragment
        ):
            raise ValueError(f"TrueLayer {label} must be HTTPS")
        return value.strip()

    @classmethod
    def _account_id(cls, value: str) -> str:
        if not 1 <= len(value) <= 200 or any(character not in _SAFE_ACCOUNT_ID for character in value):
            raise ProviderResponseError("TrueLayer account identifier is invalid")
        return value

    @classmethod
    def _resource_path(cls, value: str) -> str:
        if value == "ACCOUNT":
            return "accounts"
        if value == "CARD":
            return "cards"
        raise ValueError("TrueLayer resource type is invalid")

    @classmethod
    def _decimal(cls, value: object, label: str) -> Decimal:
        if isinstance(value, bool):
            raise ProviderResponseError(f"TrueLayer {label} is invalid")
        try:
            result = Decimal(str(value))
        except (InvalidOperation, TypeError, ValueError):
            raise ProviderResponseError(f"TrueLayer {label} is invalid") from None
        if not result.is_finite():
            raise ProviderResponseError(f"TrueLayer {label} is invalid")
        return result

    @classmethod
    def _required_datetime(cls, value: object, label: str) -> datetime:
        result = cls._optional_datetime(value, label)
        if result is None:
            raise ProviderResponseError(f"TrueLayer {label} is invalid")
        return result

    @classmethod
    def _optional_datetime(cls, value: object, label: str) -> datetime | None:
        if value is None:
            return None
        if not isinstance(value, str) or len(value) > 100:
            raise ProviderResponseError(f"TrueLayer {label} is invalid")
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            raise ProviderResponseError(f"TrueLayer {label} is invalid") from None
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)

    @classmethod
    def _masked_account_identifier(cls, value: object) -> str | None:
        if value is None:
            return None
        item = cls._mapping(value, "account number")
        for key in ("number", "iban"):
            candidate = item.get(key)
            if isinstance(candidate, str):
                alphanumeric = "".join(character for character in candidate if character.isalnum())
                if len(alphanumeric) >= 4:
                    return f"••••{alphanumeric[-4:]}"
        return None

    @classmethod
    def _resource_provider_id(cls, value: object) -> str | None:
        resource = cls._mapping(value, "resource")
        provider = resource.get("provider")
        if provider is None:
            return None
        provider_map = cls._mapping(provider, "provider")
        return cls._optional_string(provider_map.get("provider_id"), maximum=200)

    @classmethod
    def _provider_name(cls, items: list[Any], provider_id: str | None) -> str:
        for source in items:
            resource = cls._mapping(source, "resource")
            provider = resource.get("provider")
            if isinstance(provider, Mapping):
                display = cls._optional_string(provider.get("display_name"), maximum=120)
                if display:
                    return display
        known = {"ob-natwest": "NatWest", "ob-revolut": "Revolut"}
        return known.get(provider_id or "", "Bank")

    @classmethod
    def _optional_header(
        cls,
        headers: httpx.Headers,
        name: str,
        *,
        maximum: int,
    ) -> str | None:
        value = headers.get(name)
        if value is None:
            return None
        if not value.strip() or len(value) > maximum:
            raise ProviderResponseError("TrueLayer response header is invalid")
        return value.strip()
