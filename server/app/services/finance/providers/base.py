"""Provider-neutral types for account-information-only bank adapters."""

from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
from typing import Protocol, runtime_checkable


class ProviderError(RuntimeError):
    """A provider operation failed without exposing provider response content."""


class ProviderTransportError(ProviderError):
    """The provider could not be reached within the configured network bounds."""


class ProviderResponseError(ProviderError):
    """The provider returned an error or a malformed response."""


class UnsafeCapabilityError(ValueError):
    """A request or grant contains a capability outside account information."""


class PaginationError(ProviderResponseError):
    """Provider pagination failed a boundedness or progress check."""


class ReadCapability(StrEnum):
    ACCOUNTS = "accounts"
    CARDS = "cards"
    BALANCES = "balances"
    TRANSACTIONS = "transactions"


class TransactionState(StrEnum):
    BOOKED = "booked"
    PENDING = "pending"


_READ_CAPABILITIES = frozenset(item.value for item in ReadCapability)
_DEFAULT_ACCOUNT_CAPABILITIES = frozenset(
    {
        ReadCapability.ACCOUNTS.value,
        ReadCapability.BALANCES.value,
        ReadCapability.TRANSACTIONS.value,
    }
)


def require_read_capabilities(values: frozenset[str]) -> frozenset[ReadCapability]:
    """Fail closed for payment, transfer, trading, signing, or unknown capabilities."""
    invalid = values - _READ_CAPABILITIES
    if invalid:
        raise UnsafeCapabilityError(
            "Only account, card, balance, and transaction read access is permitted"
        )
    if ReadCapability.ACCOUNTS.value not in values:
        raise UnsafeCapabilityError("Account-information access must include accounts")
    return frozenset(ReadCapability(value) for value in values)


@dataclass(frozen=True, slots=True)
class AuthorisationRequest:
    institution_name: str
    institution_country: str
    redirect_url: str
    state: str
    valid_until: datetime
    requested_capabilities: frozenset[str] = _DEFAULT_ACCOUNT_CAPABILITIES
    psu_type: str = "personal"
    language: str = "en"

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "requested_capabilities",
            require_read_capabilities(self.requested_capabilities),
        )


@dataclass(frozen=True, slots=True)
class AuthorisationStart:
    redirect_url: str
    authorisation_id: str


@dataclass(frozen=True, slots=True)
class ProviderAccount:
    provider_account_id: str | None
    currency: str
    account_type: str
    display_name: str | None
    product: str | None
    usage: str | None
    masked_identifier: str | None
    provider_resource_type: str = "ACCOUNT"


@dataclass(frozen=True, slots=True)
class ProviderBalance:
    amount: Decimal
    currency: str
    balance_type: str
    name: str
    reference_date: date | None
    changed_at: datetime | None


@dataclass(frozen=True, slots=True)
class ProviderTransaction:
    provider_reference: str | None
    provider_detail_id: str | None
    amount: Decimal
    currency: str
    state: TransactionState
    booking_date: date | None
    value_date: date | None
    transaction_date: date | None
    counterparty_name: str | None
    remittance: tuple[str, ...]
    merchant_category_code: str | None
    bank_code: str | None
    bank_sub_code: str | None


@dataclass(frozen=True, slots=True)
class TransactionPage:
    transactions: tuple[ProviderTransaction, ...]
    page_number: int


@dataclass(frozen=True, slots=True)
class TransactionPages:
    pages: tuple[TransactionPage, ...]
    truncated: bool


@dataclass(frozen=True, slots=True)
class ProviderRenewalMetadata:
    status: str
    valid_until: datetime
    authorised_at: datetime | None
    automatic_renewal_supported: bool | None


@dataclass(frozen=True, slots=True)
class ProviderSession:
    provider_session_id: str
    institution_name: str
    institution_country: str
    status: str | None
    granted_capabilities: frozenset[ReadCapability]
    valid_until: datetime
    accounts: tuple[ProviderAccount, ...]


@dataclass(frozen=True, slots=True)
class ProviderInstitution:
    name: str
    country: str
    maximum_consent_validity_seconds: int


TokenFactory = Callable[[], str]


@runtime_checkable
class ReadOnlyBankProvider(Protocol):
    async def institutions(
        self,
        *,
        country: str,
        psu_type: str = "personal",
    ) -> tuple[ProviderInstitution, ...]: ...

    async def start_authorisation(self, request: AuthorisationRequest) -> AuthorisationStart: ...

    async def exchange_code(self, code: str) -> ProviderSession: ...

    async def accounts(self, provider_session_id: str) -> tuple[ProviderAccount, ...]: ...

    async def balances(self, provider_account_id: str) -> tuple[ProviderBalance, ...]: ...

    async def transaction_pages(
        self,
        provider_account_id: str,
        *,
        state: TransactionState,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> TransactionPages: ...

    async def renewal_metadata(
        self,
        provider_session_id: str,
    ) -> ProviderRenewalMetadata: ...
