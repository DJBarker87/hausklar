"""Account-information-only adapter for the Enable Banking API."""

from collections.abc import Mapping
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from typing import Any
from urllib.parse import urlparse
from uuid import UUID

import httpx

from app.services.finance.money import normalise_currency
from app.services.finance.providers.base import (
    AuthorisationRequest,
    AuthorisationStart,
    PaginationError,
    ProviderAccount,
    ProviderBalance,
    ProviderInstitution,
    ProviderRenewalMetadata,
    ProviderResponseError,
    ProviderSession,
    ProviderTransaction,
    ProviderTransportError,
    ReadCapability,
    TokenFactory,
    TransactionPage,
    TransactionPages,
    TransactionState,
    UnsafeCapabilityError,
)

ENABLE_BANKING_API_URL = "https://api.enablebanking.com"
DEFAULT_TIMEOUT = httpx.Timeout(15.0, connect=5.0, read=10.0, write=10.0, pool=5.0)
_MAX_RESPONSE_BYTES = 2_000_000
_MAX_ACCOUNTS = 100
_MAX_INSTITUTIONS = 1_000
_MAX_PAGES_LIMIT = 100
_ACCESS_FIELDS = frozenset({"accounts", "balances", "transactions", "valid_until"})
_TRANSACTION_STATUS = {
    TransactionState.BOOKED: "BOOK",
    TransactionState.PENDING: "PDNG",
}


class EnableBankingAdapter:
    """Translate Enable Banking AIS responses into the provider-neutral contract."""

    def __init__(
        self,
        *,
        client: httpx.AsyncClient,
        token_factory: TokenFactory,
        timeout: httpx.Timeout = DEFAULT_TIMEOUT,
        max_transaction_pages: int = 20,
        base_url: str = ENABLE_BANKING_API_URL,
    ) -> None:
        parsed = urlparse(base_url)
        if parsed.scheme != "https" or parsed.hostname != "api.enablebanking.com":
            raise ValueError("Enable Banking API URL must use the official HTTPS host")
        if not 1 <= max_transaction_pages <= _MAX_PAGES_LIMIT:
            raise ValueError("max_transaction_pages must be between 1 and 100")
        self._client = client
        self._token_factory = token_factory
        self._timeout = timeout
        self._max_transaction_pages = max_transaction_pages
        self._base_url = base_url.rstrip("/")

    async def institutions(
        self,
        *,
        country: str,
        psu_type: str = "personal",
    ) -> tuple[ProviderInstitution, ...]:
        country_code = country.strip().upper()
        if len(country_code) != 2 or not country_code.isalpha():
            raise ValueError("country must be a two-letter country code")
        if psu_type not in {"personal", "business"}:
            raise ValueError("psu_type must be personal or business")
        response = await self._request_json(
            "GET",
            "/aspsps",
            params={"country": country_code, "psu_type": psu_type, "service": "AIS"},
        )
        items = self._required_list(response, "aspsps")
        if len(items) > _MAX_INSTITUTIONS:
            raise ProviderResponseError("Enable Banking returned too many institutions")
        institutions: dict[tuple[str, str], ProviderInstitution] = {}
        for item in items:
            try:
                institution = self._as_mapping(item, "aspsps item")
                name = self._required_string(institution, "name")
                item_country = self._required_string(institution, "country").upper()
                validity = institution.get("maximum_consent_validity")
            except ProviderResponseError:
                continue
            if (
                item_country != country_code
                or isinstance(validity, bool)
                or not isinstance(validity, int)
                or validity <= 0
            ):
                continue
            key = (item_country, name.casefold())
            institutions[key] = ProviderInstitution(
                name=name,
                country=item_country,
                maximum_consent_validity_seconds=validity,
            )
        return tuple(
            sorted(institutions.values(), key=lambda item: (item.name.casefold(), item.name))
        )

    async def start_authorisation(
        self,
        request: AuthorisationRequest,
    ) -> AuthorisationStart:
        if request.valid_until.tzinfo is None or request.valid_until.utcoffset() is None:
            raise ValueError("valid_until must include a timezone")
        if request.valid_until <= datetime.now(timezone.utc):
            raise ValueError("valid_until must be in the future")
        if request.psu_type not in {"personal", "business"}:
            raise ValueError("psu_type must be personal or business")
        if len(request.institution_country) != 2 or not request.institution_country.isalpha():
            raise ValueError("institution_country must be a two-letter country code")
        self._require_https_url(request.redirect_url, label="redirect_url")

        available = await self.institutions(
            country=request.institution_country,
            psu_type=request.psu_type,
        )
        selected = next(
            (
                institution
                for institution in available
                if institution.name.casefold() == request.institution_name.strip().casefold()
            ),
            None,
        )
        if selected is None:
            raise ProviderResponseError("Selected bank is not currently available")
        maximum_valid_until = datetime.now(timezone.utc) + timedelta(
            seconds=selected.maximum_consent_validity_seconds
        )
        valid_until = min(request.valid_until, maximum_valid_until)

        access: dict[str, object] = {
            "valid_until": self._format_datetime(valid_until),
        }
        if ReadCapability.BALANCES in request.requested_capabilities:
            access["balances"] = True
        if ReadCapability.TRANSACTIONS in request.requested_capabilities:
            access["transactions"] = True
        payload = {
            "access": access,
            "aspsp": {
                "name": selected.name,
                "country": selected.country,
            },
            "state": self._required_nonempty(request.state, "state"),
            "redirect_url": request.redirect_url,
            "psu_type": request.psu_type,
            "language": request.language.lower(),
        }
        response = await self._request_json("POST", "/auth", json=payload)
        redirect_url = self._required_string(response, "url")
        self._require_enable_banking_auth_url(redirect_url)
        return AuthorisationStart(
            redirect_url=redirect_url,
            authorisation_id=self._required_string(response, "authorization_id"),
        )

    async def exchange_code(self, code: str) -> ProviderSession:
        response = await self._request_json(
            "POST",
            "/sessions",
            json={"code": self._required_nonempty(code, "authorisation code")},
        )
        access = self._required_mapping(response, "access")
        capabilities = self._parse_granted_access(access)
        institution = self._required_mapping(response, "aspsp")
        accounts_data = self._required_list(response, "accounts")
        if len(accounts_data) > _MAX_ACCOUNTS:
            raise ProviderResponseError("Enable Banking returned too many accounts")
        return ProviderSession(
            provider_session_id=self._required_string(response, "session_id"),
            institution_name=self._required_string(institution, "name"),
            institution_country=self._required_string(institution, "country").upper(),
            # AuthorizeSessionResponse does not contain a status field. Callers can
            # obtain the documented status through renewal_metadata()/GET session.
            status=None,
            granted_capabilities=capabilities,
            valid_until=self._parse_datetime(access.get("valid_until"), "access.valid_until"),
            accounts=tuple(self._parse_account(item) for item in accounts_data),
        )

    async def accounts(self, provider_session_id: str) -> tuple[ProviderAccount, ...]:
        session_id = self._uuid(provider_session_id, "provider_session_id")
        session = await self._request_json("GET", f"/sessions/{session_id}")
        self._parse_granted_access(self._required_mapping(session, "access"))
        accounts_data = self._required_list(session, "accounts_data")
        if len(accounts_data) > _MAX_ACCOUNTS:
            raise ProviderResponseError("Enable Banking returned too many accounts")

        accounts: list[ProviderAccount] = []
        for item in accounts_data:
            account = self._as_mapping(item, "accounts_data item")
            account_id = self._uuid(
                self._required_string(account, "uid"),
                "provider_account_id",
            )
            details = await self._request_json("GET", f"/accounts/{account_id}/details")
            accounts.append(self._parse_account(details, fallback_uid=account_id))
        return tuple(accounts)

    async def balances(self, provider_account_id: str) -> tuple[ProviderBalance, ...]:
        account_id = self._uuid(provider_account_id, "provider_account_id")
        response = await self._request_json("GET", f"/accounts/{account_id}/balances")
        balances = self._required_list(response, "balances")
        return tuple(self._parse_balance(item) for item in balances)

    async def transaction_pages(
        self,
        provider_account_id: str,
        *,
        state: TransactionState,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> TransactionPages:
        if date_from and date_to and date_from > date_to:
            raise ValueError("date_from cannot be after date_to")
        try:
            provider_status = _TRANSACTION_STATUS[state]
        except (KeyError, TypeError) as exc:
            raise ValueError("state must be booked or pending") from exc

        account_id = self._uuid(provider_account_id, "provider_account_id")
        params: dict[str, str] = {
            "transaction_status": provider_status,
            "strategy": "default",
        }
        if date_from:
            params["date_from"] = date_from.isoformat()
        if date_to:
            params["date_to"] = date_to.isoformat()

        pages: list[TransactionPage] = []
        seen_continuations: set[str] = set()
        continuation: str | None = None
        truncated = False
        for page_number in range(1, self._max_transaction_pages + 1):
            if continuation:
                params["continuation_key"] = continuation
            response = await self._request_json(
                "GET",
                f"/accounts/{account_id}/transactions",
                params=params,
            )
            transactions = self._required_list(response, "transactions")
            pages.append(
                TransactionPage(
                    transactions=tuple(
                        self._parse_transaction(item, expected_state=state)
                        for item in transactions
                    ),
                    page_number=page_number,
                )
            )
            next_value = response.get("continuation_key")
            if next_value is None:
                break
            if not isinstance(next_value, str) or not next_value:
                raise PaginationError("Enable Banking returned an invalid continuation key")
            if next_value in seen_continuations:
                raise PaginationError("Enable Banking pagination did not make progress")
            seen_continuations.add(next_value)
            continuation = next_value
            if page_number == self._max_transaction_pages:
                truncated = True
        return TransactionPages(pages=tuple(pages), truncated=truncated)

    async def renewal_metadata(
        self,
        provider_session_id: str,
    ) -> ProviderRenewalMetadata:
        session_id = self._uuid(provider_session_id, "provider_session_id")
        session = await self._request_json("GET", f"/sessions/{session_id}")
        access = self._required_mapping(session, "access")
        self._parse_granted_access(access)
        authorised = session.get("authorized")
        return ProviderRenewalMetadata(
            status=self._required_string(session, "status"),
            valid_until=self._parse_datetime(access.get("valid_until"), "access.valid_until"),
            authorised_at=(
                self._parse_datetime(authorised, "authorized") if authorised is not None else None
            ),
            # The current API reference exposes expiry/status, but no renewal or refresh field.
            automatic_renewal_supported=None,
        )

    async def _request_json(
        self,
        method: str,
        path: str,
        *,
        json: Mapping[str, object] | None = None,
        params: Mapping[str, str] | None = None,
    ) -> dict[str, Any]:
        try:
            token = self._token_factory()
        except Exception:
            raise ProviderTransportError("Enable Banking authentication is unavailable") from None
        if not isinstance(token, str) or not token:
            raise ProviderTransportError("Enable Banking authentication is unavailable")
        try:
            response = await self._client.request(
                method,
                f"{self._base_url}{path}",
                headers={
                    "Accept": "application/json",
                    "Authorization": f"Bearer {token}",
                },
                json=json,
                params=params,
                timeout=self._timeout,
                follow_redirects=False,
            )
        except httpx.HTTPError:
            raise ProviderTransportError("Enable Banking request failed") from None
        if response.status_code < 200 or response.status_code >= 300:
            raise ProviderResponseError(
                f"Enable Banking request failed with status {response.status_code}"
            )
        if len(response.content) > _MAX_RESPONSE_BYTES:
            raise ProviderResponseError("Enable Banking response exceeded the size limit")
        try:
            payload = response.json()
        except ValueError:
            raise ProviderResponseError("Enable Banking returned invalid JSON") from None
        if not isinstance(payload, dict):
            raise ProviderResponseError("Enable Banking returned an invalid response shape")
        return payload

    def _parse_granted_access(
        self,
        access: Mapping[str, Any],
    ) -> frozenset[ReadCapability]:
        unknown = set(access) - _ACCESS_FIELDS
        if unknown:
            raise UnsafeCapabilityError(
                "Enable Banking returned a capability outside account information"
            )
        granted = {ReadCapability.ACCOUNTS}
        for field, capability in (
            ("balances", ReadCapability.BALANCES),
            ("transactions", ReadCapability.TRANSACTIONS),
        ):
            value = access.get(field)
            if value is True:
                granted.add(capability)
            elif value is not None and value is not False:
                raise ProviderResponseError(f"Enable Banking returned invalid {field} access")
        self._parse_datetime(access.get("valid_until"), "access.valid_until")
        return frozenset(granted)

    def _parse_account(
        self,
        value: object,
        *,
        fallback_uid: str | None = None,
    ) -> ProviderAccount:
        account = self._as_mapping(value, "account")
        provider_id = self._optional_string(account, "uid") or fallback_uid
        if provider_id is not None:
            provider_id = self._uuid(provider_id, "provider_account_id")
        account_identifier = account.get("account_id")
        return ProviderAccount(
            provider_account_id=provider_id,
            currency=self._currency(account.get("currency")),
            account_type=self._required_string(account, "cash_account_type"),
            display_name=(
                self._optional_string(account, "details")
                or self._optional_string(account, "name")
            ),
            product=self._optional_string(account, "product"),
            usage=self._optional_string(account, "usage"),
            masked_identifier=self._masked_identifier(account_identifier),
        )

    def _parse_balance(self, value: object) -> ProviderBalance:
        balance = self._as_mapping(value, "balance")
        amount = self._required_mapping(balance, "balance_amount")
        return ProviderBalance(
            amount=self._decimal(amount.get("amount"), "balance amount"),
            currency=self._currency(amount.get("currency")),
            balance_type=self._required_string(balance, "balance_type"),
            name=self._required_string(balance, "name"),
            reference_date=self._optional_date(balance.get("reference_date"), "reference_date"),
            changed_at=self._optional_datetime(
                balance.get("last_change_date_time"),
                "last_change_date_time",
            ),
        )

    def _parse_transaction(
        self,
        value: object,
        *,
        expected_state: TransactionState,
    ) -> ProviderTransaction:
        transaction = self._as_mapping(value, "transaction")
        provider_status = self._required_string(transaction, "status")
        if provider_status != _TRANSACTION_STATUS[expected_state]:
            raise ProviderResponseError("Enable Banking ignored the requested transaction status")
        indicator = self._required_string(transaction, "credit_debit_indicator")
        if indicator not in {"CRDT", "DBIT"}:
            raise ProviderResponseError("Enable Banking returned an invalid credit/debit indicator")
        amount_data = self._required_mapping(transaction, "transaction_amount")
        unsigned_amount = abs(self._decimal(amount_data.get("amount"), "transaction amount"))
        amount = unsigned_amount if indicator == "CRDT" else -unsigned_amount
        counterparty_field = "debtor" if indicator == "CRDT" else "creditor"
        counterparty = transaction.get(counterparty_field)
        counterparty_name = None
        if counterparty is not None:
            counterparty_name = self._optional_string(
                self._as_mapping(counterparty, counterparty_field),
                "name",
            )
        remittance_value = transaction.get("remittance_information")
        if remittance_value is None:
            remittance: tuple[str, ...] = ()
        elif isinstance(remittance_value, list) and all(
            isinstance(item, str) for item in remittance_value
        ):
            remittance = tuple(remittance_value[:50])
        else:
            raise ProviderResponseError("Enable Banking returned invalid remittance information")
        bank_code_data = transaction.get("bank_transaction_code")
        bank_code: Mapping[str, Any] = {}
        if bank_code_data is not None:
            bank_code = self._as_mapping(bank_code_data, "bank_transaction_code")
        return ProviderTransaction(
            provider_reference=self._optional_string(transaction, "entry_reference"),
            provider_detail_id=self._optional_string(transaction, "transaction_id"),
            amount=amount,
            currency=self._currency(amount_data.get("currency")),
            state=expected_state,
            booking_date=self._optional_date(transaction.get("booking_date"), "booking_date"),
            value_date=self._optional_date(transaction.get("value_date"), "value_date"),
            transaction_date=self._optional_date(
                transaction.get("transaction_date"),
                "transaction_date",
            ),
            counterparty_name=counterparty_name,
            remittance=remittance,
            merchant_category_code=self._optional_string(
                transaction,
                "merchant_category_code",
            ),
            bank_code=self._optional_string(bank_code, "code"),
            bank_sub_code=self._optional_string(bank_code, "sub_code"),
        )

    @staticmethod
    def _required_nonempty(value: str, label: str) -> str:
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"{label} must not be empty")
        return value

    @staticmethod
    def _as_mapping(value: object, label: str) -> Mapping[str, Any]:
        if not isinstance(value, Mapping):
            raise ProviderResponseError(f"Enable Banking returned invalid {label}")
        return value

    def _required_mapping(self, value: Mapping[str, Any], field: str) -> Mapping[str, Any]:
        return self._as_mapping(value.get(field), field)

    @staticmethod
    def _required_list(value: Mapping[str, Any], field: str) -> list[Any]:
        result = value.get(field)
        if not isinstance(result, list):
            raise ProviderResponseError(f"Enable Banking returned invalid {field}")
        return result

    @staticmethod
    def _required_string(value: Mapping[str, Any], field: str) -> str:
        result = value.get(field)
        if not isinstance(result, str) or not result:
            raise ProviderResponseError(f"Enable Banking returned invalid {field}")
        return result

    @staticmethod
    def _optional_string(value: Mapping[str, Any], field: str) -> str | None:
        result = value.get(field)
        if result is None:
            return None
        if not isinstance(result, str):
            raise ProviderResponseError(f"Enable Banking returned invalid {field}")
        return result

    @staticmethod
    def _decimal(value: object, label: str) -> Decimal:
        if not isinstance(value, str):
            raise ProviderResponseError(f"Enable Banking returned invalid {label}")
        try:
            amount = Decimal(value)
        except InvalidOperation:
            raise ProviderResponseError(f"Enable Banking returned invalid {label}") from None
        if not amount.is_finite():
            raise ProviderResponseError(f"Enable Banking returned invalid {label}")
        return amount

    @staticmethod
    def _currency(value: object) -> str:
        try:
            return normalise_currency(value)  # type: ignore[arg-type]
        except (TypeError, ValueError):
            raise ProviderResponseError("Enable Banking returned an invalid currency") from None

    @staticmethod
    def _parse_datetime(value: object, label: str) -> datetime:
        if not isinstance(value, str):
            raise ProviderResponseError(f"Enable Banking returned invalid {label}")
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            raise ProviderResponseError(f"Enable Banking returned invalid {label}") from None
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ProviderResponseError(f"Enable Banking returned timezone-free {label}")
        return parsed.astimezone(timezone.utc)

    @classmethod
    def _optional_datetime(cls, value: object, label: str) -> datetime | None:
        return None if value is None else cls._parse_datetime(value, label)

    @staticmethod
    def _optional_date(value: object, label: str) -> date | None:
        if value is None:
            return None
        if not isinstance(value, str):
            raise ProviderResponseError(f"Enable Banking returned invalid {label}")
        try:
            return date.fromisoformat(value)
        except ValueError:
            raise ProviderResponseError(f"Enable Banking returned invalid {label}") from None

    @staticmethod
    def _format_datetime(value: datetime) -> str:
        return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

    @staticmethod
    def _uuid(value: str, label: str) -> str:
        try:
            return str(UUID(value))
        except (ValueError, TypeError, AttributeError):
            raise ValueError(f"{label} must be a UUID") from None

    @staticmethod
    def _masked_identifier(value: object) -> str | None:
        if not isinstance(value, Mapping):
            return None
        identifier = value.get("iban")
        if not isinstance(identifier, str):
            other = value.get("other")
            if isinstance(other, Mapping):
                identifier = other.get("identification")
        if not isinstance(identifier, str) or not identifier:
            return None
        compact = "".join(character for character in identifier if character.isalnum())
        return f"••••{compact[-4:]}" if compact else None

    @staticmethod
    def _require_https_url(value: str, *, label: str) -> None:
        parsed = urlparse(value)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ValueError(f"{label} must be an HTTPS URL")

    @staticmethod
    def _require_enable_banking_auth_url(value: str) -> None:
        parsed = urlparse(value)
        host = parsed.hostname or ""
        if parsed.scheme != "https" or not (
            host == "enablebanking.com" or host.endswith(".enablebanking.com")
        ):
            raise ProviderResponseError("Enable Banking returned an invalid authorisation URL")
