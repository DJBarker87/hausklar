"""Public models for read-only Open Banking connections."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


ConnectionStatus = Literal[
    "CONNECTED",
    "REAUTH_REQUIRED",
    "EXPIRED",
    "PROVIDER_DOWN",
    "PARTIAL",
    "DISCONNECTED",
]


class FinanceConnectionStartRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    space_id: str = Field(min_length=1, max_length=100)
    institution_name: str = Field(min_length=1, max_length=120)
    institution_country: str = Field(min_length=2, max_length=2)

    @field_validator("institution_name")
    @classmethod
    def strip_institution(cls, value: str) -> str:
        return value.strip()

    @field_validator("institution_country")
    @classmethod
    def validate_country(cls, value: str) -> str:
        country = value.strip().upper()
        if len(country) != 2 or not country.isalpha():
            raise ValueError("institution_country must be a two-letter code")
        return country


class FinanceTrueLayerConnectionStartRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    space_id: str = Field(min_length=1, max_length=100)
    client: Literal["web", "ios"] = "web"
    connection_id: str | None = Field(default=None, min_length=1, max_length=100)


class FinanceConnectionStartResponse(BaseModel):
    redirect_url: str


class FinanceBankInstitutionResponse(BaseModel):
    name: str
    country: str
    maximum_consent_validity_seconds: int = Field(gt=0)


class FinanceConnectedAccountResponse(BaseModel):
    id: str
    label: str
    institution: str | None
    account_type: str
    purpose: str
    currency: str
    last_four: str | None
    include_in_cashflow: bool
    include_in_net_worth: bool
    primary_spending_account: bool
    minimum_balance_minor: int
    card_paid_in_full: bool
    card_settlement_account_id: str | None
    card_statement_close_day: int | None
    card_repayment_day: int | None
    fresh_through_date: str | None
    data_through_at: str | None
    provider_presence_status: Literal["ACTIVE", "OMITTED"] = "ACTIVE"


class FinanceDerivedRefreshResponse(BaseModel):
    hook: Literal["PURCHASE_REMATCH", "FORECAST", "PAYDAY_MATCH", "COACH_REPORT"]
    status: Literal["SUCCEEDED", "FAILED"]
    last_attempt_at: str
    last_success_at: str | None = None
    last_error_code: Literal[
        "PURCHASE_REMATCH_FAILED",
        "FORECAST_REFRESH_FAILED",
        "PAYDAY_MATCH_FAILED",
        "COACH_REPORT_REFRESH_FAILED",
    ] | None = None


class FinanceConnectionResponse(BaseModel):
    id: str
    space_id: str
    can_manage: bool
    provider: Literal["ENABLE_BANKING", "TRUELAYER"]
    institution: str
    status: ConnectionStatus
    granted_capabilities: list[Literal["accounts", "balances", "cards", "transactions"]]
    consent_created_at: str | None
    consent_expires_at: str | None
    last_success_at: str | None
    last_error_code: str | None
    data_through_at: str | None
    derived_refreshes: list[FinanceDerivedRefreshResponse] = Field(default_factory=list)
    accounts: list[FinanceConnectedAccountResponse] = Field(default_factory=list)


class FinanceConnectionSyncResponse(BaseModel):
    connection_id: str
    status: ConnectionStatus
    accounts_seen: int
    balances_created: int
    source_created: int
    canonical_created: int
    duplicates: int
    pending_superseded: int
    partial_issue_codes: list[str]
    derived_refreshes: list[FinanceDerivedRefreshResponse] = Field(default_factory=list)


class FinanceConnectionDisconnectResponse(BaseModel):
    id: str
    status: Literal["DISCONNECTED"]
