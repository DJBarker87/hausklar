"""Strict contracts for product research, saving comparisons and read-only assets."""

import re
from datetime import date, datetime
from decimal import Decimal
from typing import Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StrictInt,
    field_validator,
    model_validator,
)

from app.services.finance.money import normalise_currency

_URL = re.compile(r"(?:https?://|www\.)", re.IGNORECASE)
_PRIVATE_CONTEXT = re.compile(
    r"\b(?:salary|income|bank|account|balance|mortgage|debt|family|wife|husband|child|"
    r"address|postcode|email|phone|provider|transaction|goal|budget|price|cost|spend|"
    r"saving|evidence|record|user|space)\b",
    re.IGNORECASE,
)
_SOLANA_PUBLIC = re.compile(r"^[1-9A-HJ-NP-Za-km-z]{32,44}$")
_HYPERLIQUID_PUBLIC = re.compile(r"^0x[0-9a-fA-F]{40}$")
_UUID_LIKE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b",
    re.IGNORECASE,
)
_DATE_LIKE = re.compile(
    r"(?:\b\d{1,4}[-/.]\d{1,2}(?:[-/.]\d{1,4})?\b|"
    r"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|"
    r"jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|"
    r"dec(?:ember)?)\s+\d{1,4}\b)",
    re.IGNORECASE,
)
_SECRET_MATERIAL = re.compile(
    r"\b(?:seed phrase|recovery phrase|mnemonic|private key|secret key)\b",
    re.IGNORECASE,
)
_BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def _solana_public_key_bytes(value: str) -> int:
    number = 0
    try:
        for character in value:
            number = number * 58 + _BASE58_ALPHABET.index(character)
    except ValueError:
        return 0
    decoded_length = (number.bit_length() + 7) // 8 if number else 0
    leading_zeroes = len(value) - len(value.lstrip("1"))
    return leading_zeroes + decoded_length


def _sanitised_text(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("Retailer research text cannot be blank")
    if (
        _URL.search(value)
        or _PRIVATE_CONTEXT.search(value)
        or _DATE_LIKE.search(value)
        or _UUID_LIKE.search(value)
        or any(marker in value for marker in ("£", "$", "€", "@"))
    ):
        raise ValueError("Retailer research text must contain only sanitised item context")
    return value


class FinanceRetailerResearchRequest(BaseModel):
    """The complete payload allowed to leave HausKlar for retailer research."""

    model_config = ConfigDict(extra="forbid")

    normalized_need: str = Field(min_length=1, max_length=200)
    brand_variant: str | None = Field(default=None, min_length=1, max_length=160)
    quantity: Decimal = Field(gt=0, max_digits=20, decimal_places=6)
    pack_quantity: Decimal = Field(gt=0, max_digits=20, decimal_places=6)
    pack_unit: str = Field(min_length=1, max_length=40)
    unit_basis: Literal["g", "ml", "each"]
    quality_constraints: list[str] = Field(default_factory=list, max_length=20)
    substitution_constraints: list[str] = Field(default_factory=list, max_length=20)
    fulfilment_assumption: Literal["DELIVERY", "COLLECTION", "IN_STORE", "NONE"]
    approximate_travel_minutes: StrictInt | None = Field(default=None, ge=0, le=240)

    @field_validator("normalized_need", "brand_variant", "pack_unit")
    @classmethod
    def sanitise_text(cls, value: str | None):
        return _sanitised_text(value) if value is not None else None

    @field_validator("quality_constraints", "substitution_constraints")
    @classmethod
    def sanitise_constraints(cls, values: list[str]) -> list[str]:
        return [_sanitised_text(value) for value in values]


class FinanceRetailerResearchRequestResponse(BaseModel):
    request_id: str
    review_payload: FinanceRetailerResearchRequest
    status: Literal["REQUESTED", "RESULT_READY", "CANCELLED"]
    fulfilment_mode: Literal["MANUAL_REVIEW"] = "MANUAL_REVIEW"
    message: str
    created_at: str


class FinanceRetailerResearchResultCreate(BaseModel):
    """Dated, reviewed retailer facts; source URLs and hosted tools are not accepted."""

    model_config = ConfigDict(extra="forbid")

    reviewed: Literal[True]
    match_kind: Literal["EXACT", "REALISTIC_SUBSTITUTE", "BEHAVIOURAL_ALTERNATIVE"]
    retailer_name: str = Field(min_length=1, max_length=160)
    product_name: str = Field(min_length=1, max_length=240)
    brand_variant: str | None = Field(default=None, min_length=1, max_length=160)
    pack_quantity: Decimal = Field(gt=0, max_digits=20, decimal_places=6)
    pack_unit: str = Field(min_length=1, max_length=40)
    comparable_quantity: Decimal = Field(gt=0, max_digits=20, decimal_places=6)
    unit_basis: Literal["g", "ml", "each"]
    price_minor: StrictInt = Field(ge=0, le=1_000_000_000_000)
    currency: str
    observed_on: date
    delivery_low_minor: StrictInt = Field(default=0, ge=0, le=1_000_000_000)
    delivery_high_minor: StrictInt = Field(default=0, ge=0, le=1_000_000_000)
    travel_low_minor: StrictInt = Field(default=0, ge=0, le=1_000_000_000)
    travel_high_minor: StrictInt = Field(default=0, ge=0, le=1_000_000_000)
    likely_waste_low_bps: StrictInt = Field(default=0, ge=0, le=10_000)
    likely_waste_high_bps: StrictInt = Field(default=0, ge=0, le=10_000)
    inconvenience_note: str = Field(min_length=1, max_length=500)
    confidence_bps: StrictInt = Field(ge=0, le=10_000)
    source_label: str = Field(min_length=1, max_length=200)

    @field_validator(
        "retailer_name",
        "product_name",
        "brand_variant",
        "pack_unit",
        "inconvenience_note",
        "source_label",
    )
    @classmethod
    def reject_urls(cls, value: str | None):
        if value is None:
            return None
        value = value.strip()
        if not value or _URL.search(value):
            raise ValueError("Retailer result text cannot contain a URL")
        return value

    @field_validator("currency")
    @classmethod
    def currency_code(cls, value: str) -> str:
        return normalise_currency(value)

    @model_validator(mode="after")
    def validate_ranges(self):
        if self.observed_on > date.today():
            raise ValueError("retailer evidence date cannot be in the future")
        if self.delivery_high_minor < self.delivery_low_minor:
            raise ValueError("delivery range is invalid")
        if self.travel_high_minor < self.travel_low_minor:
            raise ValueError("travel range is invalid")
        if self.likely_waste_high_bps < self.likely_waste_low_bps:
            raise ValueError("waste range is invalid")
        return self


class FinanceRetailerResearchResultResponse(BaseModel):
    id: str
    request_id: str
    match_kind: Literal["EXACT", "REALISTIC_SUBSTITUTE", "BEHAVIOURAL_ALTERNATIVE"]
    retailer_name: str
    product_name: str
    brand_variant: str | None = None
    pack_quantity: str
    pack_unit: str
    comparable_quantity: str
    unit_basis: str
    price_minor: int
    currency: str
    observed_on: date
    delivery_low_minor: int
    delivery_high_minor: int
    travel_low_minor: int
    travel_high_minor: int
    likely_waste_low_bps: int
    likely_waste_high_bps: int
    inconvenience_note: str
    confidence_bps: int
    source_label: str


class FinanceProductPriceObservationResponse(BaseModel):
    id: str
    normalized_item_id: str
    normalized_item_name: str
    source_kind: Literal["PURCHASE_LINE", "RETAILER_RESEARCH"]
    source_line_id: str | None = None
    retailer_name: str
    product_name: str
    pack_quantity: str
    pack_unit: str
    comparable_quantity: str
    unit_basis: str
    price_minor: int
    currency: str
    observed_on: date
    confidence_bps: int
    evidence_refs: list[str]


class FinanceProductHistoryResponse(BaseModel):
    normalized_item_id: str
    normalized_item_name: str
    data_through: date | None = None
    observations: list[FinanceProductPriceObservationResponse]


class FinanceProductComparisonCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    normalized_item_id: str = Field(min_length=1, max_length=100)
    research_result_id: str = Field(min_length=1, max_length=100)
    period_start: date
    period_end: date

    @model_validator(mode="after")
    def validate_period(self):
        if self.period_end < self.period_start:
            raise ValueError("comparison period is invalid")
        if (self.period_end - self.period_start).days > 730:
            raise ValueError("comparison period cannot exceed two years")
        return self


class FinanceProductComparisonResponse(BaseModel):
    id: str
    normalized_item_id: str
    normalized_item_name: str
    research_result_id: str
    period_start: date
    period_end: date
    actual_quantity: str
    actual_spend_minor: int
    currency: str
    comparison_mode: Literal["EXACT", "RANGE"]
    candidate_low_minor: int
    candidate_high_minor: int
    saving_low_minor: int
    saving_high_minor: int
    unmatched_observation_count: int
    confidence_bps: int
    overlap_group: str
    evidence_refs: list[str]
    data_through: date
    price_observed_on: date
    inconvenience_note: str
    status: Literal["OPEN", "ACCEPTED", "DISMISSED", "SUPERSEDED"]


class FinanceProductOpportunityAccept(BaseModel):
    model_config = ConfigDict(extra="forbid")

    action_kind: Literal["PREFERENCE", "HABIT_EXPERIMENT"]
    review_date: date | None = None
    trigger: str | None = Field(default=None, min_length=1, max_length=300)
    target: str | None = Field(default=None, min_length=1, max_length=300)

    @model_validator(mode="after")
    def require_habit_shape(self):
        if self.action_kind == "HABIT_EXPERIMENT" and (
            self.review_date is None or self.trigger is None or self.target is None
        ):
            raise ValueError("Habit experiments require trigger, target and review_date")
        if self.action_kind == "PREFERENCE" and any(
            value is not None for value in (self.review_date, self.trigger, self.target)
        ):
            raise ValueError("Preference acceptance does not use habit fields")
        return self


class FinanceOpportunityActionResponse(BaseModel):
    id: str
    comparison_id: str
    overlap_group: str
    action_kind: Literal["PREFERENCE", "HABIT_EXPERIMENT"]
    status: Literal["CREATED", "READY_FOR_CONFIRMATION"]
    action_payload: dict[str, object]
    target_preference_id: str | None = None


AssetClass = Literal[
    "OPERATING_CASH",
    "PROTECTED_RESERVE",
    "GOAL_CASH",
    "ACCESSIBLE_SAVINGS",
    "BROKERAGE_INVESTMENT",
    "PENSION_LOCKED",
    "STABLE_CRYPTO",
    "VOLATILE_CRYPTO",
    "PROPERTY",
    "OTHER_ASSET",
    "LIABILITY",
]
PositionKind = Literal["HOLDING", "DEBT", "EQUITY", "EXPOSURE", "UNREALISED_PNL"]
InstrumentIdentifierKind = Literal["ISIN", "SEDOL", "TICKER", "OTHER"]


class FinanceAssetHoldingInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    asset_key: str = Field(min_length=1, max_length=120, pattern=r"^[A-Za-z0-9_.:-]+$")
    asset_name: str = Field(min_length=1, max_length=240)
    asset_class: AssetClass
    position_kind: PositionKind = "HOLDING"
    include_in_net_worth: bool = True
    quantity: Decimal = Field(max_digits=30, decimal_places=12)
    quantity_unit: str = Field(min_length=1, max_length=40)
    value_minor: StrictInt | None = Field(
        default=None, ge=-1_000_000_000_000_000, le=1_000_000_000_000_000
    )
    unit_price_minor: StrictInt | None = Field(default=None, ge=0, le=1_000_000_000_000_000)
    price_source: str | None = Field(default=None, min_length=1, max_length=160)
    instrument_id_kind: InstrumentIdentifierKind | None = None
    instrument_id: str | None = Field(
        default=None, min_length=1, max_length=80, pattern=r"^[A-Za-z0-9._:-]+$"
    )
    quote_symbol: str | None = Field(
        default=None, min_length=1, max_length=40, pattern=r"^[A-Za-z0-9._:-]+$"
    )
    quote_currency: str | None = None
    cost_basis_minor: StrictInt | None = Field(
        default=None, ge=0, le=1_000_000_000_000_000
    )
    cost_basis_currency: str | None = None

    @field_validator("asset_name", "quantity_unit", "price_source")
    @classmethod
    def reject_urls(cls, value: str | None):
        if value is not None and _URL.search(value):
            raise ValueError("Asset snapshot text cannot contain a URL")
        return value.strip() if value is not None else None

    @field_validator("quote_currency", "cost_basis_currency")
    @classmethod
    def quote_currency_code(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip().upper()
        if value == "GBX":
            return value
        return normalise_currency(value)

    @model_validator(mode="after")
    def unknown_is_explicit(self):
        if self.position_kind in {"HOLDING", "DEBT", "EQUITY"} and self.quantity < 0:
            raise ValueError("Holdings, debts and equity quantities cannot be negative")
        if (
            self.value_minor is not None
            and self.value_minor < 0
            and self.asset_class != "LIABILITY"
            and self.position_kind in {"HOLDING", "EQUITY"}
        ):
            raise ValueError("Holding and equity values cannot be negative")
        if self.value_minor is None and (
            self.unit_price_minor is not None or self.price_source is not None
        ):
            raise ValueError("Unknown values cannot claim a price")
        if self.value_minor is not None and not self.price_source:
            raise ValueError("Known values require a price/report source")
        if (self.instrument_id_kind is None) != (self.instrument_id is None):
            raise ValueError("An instrument identifier needs both its type and value")
        if (self.quote_symbol is None) != (self.quote_currency is None):
            raise ValueError("A public quote needs both a symbol and its quote currency")
        if (self.cost_basis_minor is None) != (self.cost_basis_currency is None):
            raise ValueError("A cost basis needs both an amount and currency")
        return self


class FinanceHLReportActivityInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    activity_type: Literal["CONTRIBUTION", "WITHDRAWAL", "BUY", "SELL", "INCOME", "FEE"]
    occurred_on: date
    amount_minor: StrictInt = Field(ge=-1_000_000_000_000_000, le=1_000_000_000_000_000)
    currency: str
    description: str = Field(min_length=1, max_length=300)

    @field_validator("currency")
    @classmethod
    def currency_code(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("description")
    @classmethod
    def description_without_url(cls, value: str) -> str:
        value = value.strip()
        if not value or _URL.search(value):
            raise ValueError("HL activity descriptions cannot contain URLs")
        return value


class FinanceHLImportPreviewCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: str = Field(min_length=1, max_length=160)
    account_wrapper: Literal["ISA", "SIPP", "GENERAL", "JUNIOR_ISA", "OTHER"]
    as_of_date: date
    currency: str
    cash_value_minor: StrictInt = Field(ge=0, le=1_000_000_000_000_000)
    reported_total_minor: StrictInt | None = Field(default=None, ge=0, le=1_000_000_000_000_000)
    holdings: list[FinanceAssetHoldingInput] = Field(default_factory=list, max_length=1_000)
    activities: list[FinanceHLReportActivityInput] = Field(default_factory=list, max_length=2_000)

    @field_validator("currency")
    @classmethod
    def currency_code(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("label")
    @classmethod
    def safe_report_label(cls, value: str) -> str:
        value = value.strip()
        if not value or _SECRET_MATERIAL.search(value):
            raise ValueError("Report labels cannot contain secret or recovery material")
        return value

    @field_validator("holdings")
    @classmethod
    def restrict_hl_classes(cls, holdings: list[FinanceAssetHoldingInput]):
        allowed = {"BROKERAGE_INVESTMENT", "PENSION_LOCKED"}
        if any(holding.asset_class not in allowed for holding in holdings):
            raise ValueError("HL reports may contain brokerage or locked pension holdings only")
        return holdings

    @model_validator(mode="after")
    def require_cash_or_holding(self):
        if self.cash_value_minor == 0 and not self.holdings:
            raise ValueError("An HL report must contain cash or at least one holding")
        return self


class FinanceHLImportPreviewResponse(BaseModel):
    id: str
    label: str
    account_wrapper: Literal["ISA", "SIPP", "GENERAL", "JUNIOR_ISA", "OTHER"]
    as_of_date: date
    currency: str
    cash_value_minor: int
    reported_total_minor: int | None = None
    calculated_known_total_minor: int
    unknown_value_count: int
    reconciliation_difference_minor: int | None = None
    can_confirm: bool
    holdings: list[FinanceAssetHoldingInput]
    activities: list[FinanceHLReportActivityInput]
    expires_at: str


class FinanceHLImportConfirm(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reviewed: Literal[True]


class FinanceWatchAddressCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source_kind: Literal["SOLANA_PUBLIC", "HYPERLIQUID_PUBLIC"]
    label: str = Field(min_length=1, max_length=160)
    public_address: str = Field(min_length=32, max_length=44)

    @field_validator("label")
    @classmethod
    def safe_watch_label(cls, value: str) -> str:
        value = value.strip()
        if not value or _SECRET_MATERIAL.search(value):
            raise ValueError("Watch labels cannot contain secret or recovery material")
        return value

    @model_validator(mode="after")
    def public_address_only(self):
        address = self.public_address.strip()
        valid = (
            bool(_SOLANA_PUBLIC.fullmatch(address)) and _solana_public_key_bytes(address) == 32
            if self.source_kind == "SOLANA_PUBLIC"
            else bool(_HYPERLIQUID_PUBLIC.fullmatch(address))
        )
        if not valid:
            raise ValueError(
                "Only a correctly formatted public address is accepted; seed phrases and private keys are forbidden"
            )
        self.public_address = address
        return self


class FinanceAssetSourceResponse(BaseModel):
    id: str
    space_id: str
    source_kind: Literal[
        "HL_REPORT", "MANUAL_PORTFOLIO", "SOLANA_PUBLIC", "HYPERLIQUID_PUBLIC"
    ]
    label: str
    public_address: str | None = None
    status: Literal["ACTIVE", "PAUSED"]


class FinanceWatchSnapshotCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reviewed: Literal[True]
    as_of_at: datetime
    currency: str
    positions: list[FinanceAssetHoldingInput] = Field(default_factory=list, max_length=1_000)

    @field_validator("currency")
    @classmethod
    def currency_code(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("as_of_at")
    @classmethod
    def aware_timestamp(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("as_of_at must include a timezone")
        return value


class FinanceAssetSnapshotResponse(BaseModel):
    id: str
    source: FinanceAssetSourceResponse
    as_of_at: str
    snapshot_kind: Literal["REVIEWED_REPORT", "WATCH_ONLY"]
    data_status: Literal["COMPLETE", "PARTIAL"]
    position_count: int


class FinanceNetWorthLayerResponse(BaseModel):
    layer: AssetClass
    amount_minor: int | None = None
    known_components_minor: int
    unknown_component_count: int
    included_in_total: bool
    data_through: str | None = None
    note: str | None = None


class FinanceNetWorthResponse(BaseModel):
    space_id: str
    currency: str
    total_net_worth_minor: int | None = None
    known_net_worth_minor: int
    data_through: str | None = None
    layers: list[FinanceNetWorthLayerResponse]


class FinanceAssetPriceRefreshResponse(BaseModel):
    source_id: str
    source_label: str
    priced_holding_count: int
    retained_holding_count: int
    price_observed_at: str | None = None
    price_sources: list[str] = Field(default_factory=list)


class FinancePortfolioPositionSave(BaseModel):
    """A user-entered holding; no broker credentials or trading controls."""

    model_config = ConfigDict(extra="forbid")

    id: str | None = Field(
        default=None,
        min_length=1,
        max_length=80,
        pattern=r"^[A-Za-z0-9_-]+$",
    )
    name: str = Field(min_length=1, max_length=160)
    quote_symbol: str = Field(
        min_length=1,
        max_length=40,
        pattern=r"^[A-Za-z0-9._:-]+$",
    )
    quote_currency: str
    quantity: Decimal = Field(gt=0, max_digits=30, decimal_places=12)
    cost_basis_minor: StrictInt | None = Field(
        default=None,
        ge=0,
        le=1_000_000_000_000_000,
    )

    @field_validator("name")
    @classmethod
    def safe_name(cls, value: str) -> str:
        value = value.strip()
        if not value or _URL.search(value) or _SECRET_MATERIAL.search(value):
            raise ValueError("Position names must be plain text without links or secrets")
        return value

    @field_validator("quote_symbol")
    @classmethod
    def normalise_quote_symbol(cls, value: str) -> str:
        return value.strip().upper()

    @field_validator("quote_currency")
    @classmethod
    def portfolio_quote_currency(cls, value: str) -> str:
        value = value.strip().upper()
        if value == "GBX":
            return value
        return normalise_currency(value)


class FinancePortfolioPositionResponse(BaseModel):
    id: str
    name: str
    quote_symbol: str
    quote_currency: str
    quantity: str
    cost_basis_minor: int | None = None
    unit_price_minor: int | None = None
    value_minor: int | None = None
    gain_minor: int | None = None
    currency: str
    price_observed_at: str | None = None
    price_source: str | None = None
    using_last_known_price: bool = False


class FinancePortfolioHistoryPointResponse(BaseModel):
    date: date
    value_minor: int
    known_position_count: int
    unknown_position_count: int


class FinancePortfolioResponse(BaseModel):
    space_id: str
    source_id: str | None = None
    label: str = "Savings portfolio"
    currency: str
    total_value_minor: int
    total_cost_basis_minor: int | None = None
    total_gain_minor: int | None = None
    missing_cost_basis_count: int = 0
    unknown_position_count: int = 0
    price_observed_at: str | None = None
    price_sources: list[str] = Field(default_factory=list)
    using_last_known_prices: bool = False
    positions: list[FinancePortfolioPositionResponse] = Field(default_factory=list)
    history: list[FinancePortfolioHistoryPointResponse] = Field(default_factory=list)


class FinanceManualAssetValueCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reviewed: Literal[True]
    item_id: str | None = Field(default=None, min_length=1, max_length=100)
    name: str = Field(min_length=1, max_length=160)
    asset_class: Literal["PENSION_LOCKED", "PROPERTY", "OTHER_ASSET", "LIABILITY"]
    as_of_at: datetime
    value_minor: StrictInt = Field(ge=0, le=1_000_000_000_000_000)
    currency: str
    source_label: str = Field(min_length=1, max_length=160)

    @field_validator("currency")
    @classmethod
    def manual_currency_code(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("name", "source_label")
    @classmethod
    def manual_text(cls, value: str) -> str:
        value = value.strip()
        if not value or _URL.search(value) or _SECRET_MATERIAL.search(value):
            raise ValueError("Asset labels must be plain text without links or secrets")
        return value

    @field_validator("as_of_at")
    @classmethod
    def manual_timestamp(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("as_of_at must include a timezone")
        return value


class FinanceManualAssetValueResponse(BaseModel):
    id: str
    item_id: str
    space_id: str
    name: str
    asset_class: Literal["PENSION_LOCKED", "PROPERTY", "OTHER_ASSET", "LIABILITY"]
    as_of_at: str
    value_minor: int
    currency: str
    source_label: str


class FinanceNetWorthPointLayerResponse(BaseModel):
    layer: AssetClass
    amount_minor: int


class FinanceNetWorthPointResponse(BaseModel):
    as_of_date: date
    total_minor: int
    unknown_component_count: int
    layers: list[FinanceNetWorthPointLayerResponse]
    contributions_minor: int = 0
    withdrawals_minor: int = 0
    market_movement_minor: int | None = None


class FinanceNetWorthHoldingResponse(BaseModel):
    key: str
    source_id: str | None = None
    source_label: str
    name: str
    layer: AssetClass
    value_minor: int
    currency: str
    as_of_at: str
    quantity: str | None = None
    quantity_unit: str | None = None
    instrument_id_kind: InstrumentIdentifierKind | None = None
    instrument_id: str | None = None
    quote_symbol: str | None = None
    unit_price_minor: int | None = None
    price_source: str
    using_last_known_price: bool = False


class FinanceNetWorthHistoryResponse(BaseModel):
    space_id: str
    currency: str
    points: list[FinanceNetWorthPointResponse]
    current_total_minor: int
    change_minor: int
    period_contributions_minor: int
    period_withdrawals_minor: int
    period_market_movement_minor: int
    holdings: list[FinanceNetWorthHoldingResponse]
    price_observed_at: str | None = None
    price_sources: list[str] = Field(default_factory=list)
    using_last_known_prices: bool = False
