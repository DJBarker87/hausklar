from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator, model_validator

from app.services.finance.money import normalise_currency


class FinanceSpaceResponse(BaseModel):
    id: str
    kind: Literal["personal", "household"]
    name: str
    is_default: bool


class FinanceSettingsResponse(BaseModel):
    id: str
    household_timezone: str
    default_currency: str
    personal_space_id: str
    household_space_id: str
    created_at: str
    updated_at: str


class FinanceProjectionPreferenceUpdate(BaseModel):
    show_money: bool
    show_deliveries: bool


class FinanceProjectionPreferenceResponse(BaseModel):
    show_money: bool
    show_deliveries: bool


class FinanceAIConsentAccept(BaseModel):
    space_id: str = Field(min_length=1, max_length=100)
    accepted: Literal[True]
    consent_version: str = Field(min_length=1, max_length=300)


class FinanceAIConsentResponse(BaseModel):
    space_id: str
    space_kind: Literal["personal", "household"]
    consented: bool
    consent_version: str
    consented_at: str | None = None
    provider: Literal["off", "openai", "hermes"]
    model: str
    store: Literal[False] = False
    background_processing: Literal[False] = False
    disclosure: str


class FinanceCoachConversationTurn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role: Literal["user", "assistant"]
    text: str = Field(min_length=1, max_length=1_500)


class FinanceCoachAsk(BaseModel):
    model_config = ConfigDict(extra="forbid")

    question: str = Field(min_length=1, max_length=4_000)
    scope: Literal["mine", "household"]
    space_id: str = Field(min_length=1, max_length=100)
    conversation: list[FinanceCoachConversationTurn] = Field(
        default_factory=list, max_length=8
    )

    @field_validator("question")
    @classmethod
    def strip_question(cls, value: str) -> str:
        return value.strip()

    @model_validator(mode="after")
    def cap_temporary_conversation(self):
        if sum(len(turn.text) for turn in self.conversation) > 8_000:
            raise ValueError("Finance screen conversation is too long")
        return self


AccountType = Literal["CURRENT", "SAVINGS", "CREDIT_CARD", "CASH", "INVESTMENT", "CRYPTO"]
AccountPurpose = Literal[
    "OPERATING_CURRENT",
    "SAVINGS",
    "CREDIT_CARD",
    "GOAL",
    "IGNORED",
    "INVESTMENT_LIKE",
]
TransactionState = Literal["PENDING", "POSTED", "SUPERSEDED", "VOID"]
TransactionKind = Literal["CASEY", "FEE", "CASH_WITHDRAWAL"]
FinanceSpendingType = Literal[
    "FIXED",
    "FLEXIBLE",
    "DISCRETIONARY",
    "UNCATEGORISED",
]
RelationType = Literal[
    "INTERNAL_TRANSFER",
    "CREDIT_CARD_REPAYMENT",
    "REFUND",
    "REVERSAL",
    "REIMBURSEMENT",
    "CHARGEBACK",
    "FEE",
    "FX_LEG",
    "CASH_WITHDRAWAL",
]


class FinanceAccountCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str | None = None
    connection_id: str | None = None
    provider_account_id: str | None = Field(default=None, max_length=200)
    label: str = Field(min_length=1, max_length=120)
    institution: str | None = Field(default=None, max_length=120)
    account_type: AccountType
    currency: str
    last_four: str | None = Field(default=None, min_length=4, max_length=4)
    include_in_cashflow: bool = True
    include_in_net_worth: bool = True
    minimum_balance_minor: StrictInt = 0

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("label", "institution")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        return value.strip() if value else value

    @field_validator("last_four")
    @classmethod
    def validate_last_four(cls, value: str | None) -> str | None:
        if value is not None and not value.isdigit():
            raise ValueError("last_four must contain four digits")
        return value


class FinanceManualAccountCreate(BaseModel):
    """Browser-safe account metadata with no provider or caller-chosen IDs."""

    model_config = ConfigDict(extra="forbid")

    label: str = Field(min_length=1, max_length=120)
    institution: str | None = Field(default=None, max_length=120)
    account_type: AccountType
    currency: str
    last_four: str | None = Field(default=None, min_length=4, max_length=4)
    include_in_cashflow: bool = True
    include_in_net_worth: bool = True
    minimum_balance_minor: StrictInt = 0
    current_balance_minor: StrictInt
    balance_observed_at: datetime

    @field_validator("currency")
    @classmethod
    def validate_manual_currency(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("label", "institution")
    @classmethod
    def strip_manual_text(cls, value: str | None) -> str | None:
        return value.strip() if value else value

    @field_validator("last_four")
    @classmethod
    def validate_manual_last_four(cls, value: str | None) -> str | None:
        if value is not None and not value.isdigit():
            raise ValueError("last_four must contain four digits")
        return value

    @field_validator("balance_observed_at")
    @classmethod
    def validate_manual_balance_time(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("balance_observed_at must include a timezone")
        return value


class FinanceBalanceResponse(BaseModel):
    booked_minor: int
    available_minor: int | None = None
    credit_limit_minor: int | None = None
    provider_at: str | None = None
    observed_at: str


class FinanceAccountResponse(BaseModel):
    id: str
    space_id: str
    label: str
    institution: str | None = None
    account_type: AccountType
    purpose: AccountPurpose
    currency: str
    last_four: str | None = None
    include_in_cashflow: bool
    include_in_net_worth: bool
    primary_spending_account: bool
    minimum_balance_minor: int
    card_paid_in_full: bool
    card_settlement_account_id: str | None = None
    card_statement_close_day: int | None = None
    card_repayment_day: int | None = None
    fresh_through_date: date | None = None
    data_through_at: str | None = None
    provider_presence_status: Literal["ACTIVE", "OMITTED"] = "ACTIVE"
    balance: FinanceBalanceResponse | None = None


class NormalisedSourceTransaction(BaseModel):
    source_kind: Literal["PROVIDER", "CSV", "OFX", "MANUAL"]
    source_batch_id: str = Field(min_length=1, max_length=200)
    source_transaction_id: str | None = Field(default=None, max_length=300)
    source_statement_id: str | None = Field(default=None, max_length=300)
    replaces_source_transaction_id: str | None = Field(default=None, max_length=300)
    source_group_id: str | None = Field(default=None, max_length=300)
    booking_date: date
    value_date: date | None = None
    pending_status: Literal["PENDING", "POSTED"]
    transaction_kind: TransactionKind = "CASEY"
    amount_minor: StrictInt
    currency: str
    description: str = Field(min_length=1, max_length=500)
    merchant_text: str | None = Field(default=None, max_length=200)
    merchant_category_code: str | None = Field(default=None, max_length=40)
    bank_code: str | None = Field(default=None, max_length=100)
    bank_sub_code: str | None = Field(default=None, max_length=200)
    observed_at: datetime

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator(
        "description",
        "merchant_text",
        "merchant_category_code",
        "bank_code",
        "bank_sub_code",
    )
    @classmethod
    def strip_source_text(cls, value: str | None) -> str | None:
        return value.strip() if value else value

    @field_validator("observed_at")
    @classmethod
    def require_aware_observed_at(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("observed_at must include a timezone")
        return value


class FinanceRelationResponse(BaseModel):
    id: str
    from_transaction_id: str
    to_transaction_id: str
    relation_type: RelationType
    status: Literal["SUGGESTED", "CONFIRMED", "REJECTED"]
    method: str
    confidence_bps: int


class FinanceSplitInput(BaseModel):
    amount_minor: StrictInt
    category_id: str | None = None
    label: str | None = Field(default=None, max_length=200)


class FinanceSplitReplace(BaseModel):
    splits: list[FinanceSplitInput] = Field(min_length=1, max_length=100)


class FinanceSplitResponse(BaseModel):
    id: str
    transaction_id: str
    amount_minor: int
    category_id: str | None = None
    category_name: str
    spending_type: FinanceSpendingType
    label: str | None = None
    created_at: str


class FinanceTransactionResponse(BaseModel):
    id: str
    space_id: str
    account_id: str
    canonical_date: date
    amount_minor: int
    currency: str
    state: TransactionState
    transaction_kind: TransactionKind
    source_kind: str
    description: str
    merchant_text: str | None = None
    merchant_id: str | None = None
    primary_category_id: str | None = None
    primary_category_name: str
    primary_spending_type: FinanceSpendingType
    superseded_by_id: str | None = None
    data_through_at: str
    relations: list[FinanceRelationResponse] = Field(default_factory=list)
    splits: list[FinanceSplitResponse] = Field(default_factory=list)


class FinanceImportResult(BaseModel):
    source_created: int
    canonical_created: int
    duplicates: int
    pending_superseded: int
    transaction_ids: list[str]
    relation_suggestion_ids: list[str]


class FinanceRelationReview(BaseModel):
    status: Literal["CONFIRMED", "REJECTED"]


class FinanceCurrencySummary(BaseModel):
    currency: str
    account_movement_minor: int
    income_minor: int
    gross_spending_minor: int
    refunds_minor: int
    reimbursements_minor: int
    fees_minor: int
    net_household_cost_minor: int


class FinanceLedgerSummaryResponse(BaseModel):
    space_id: str
    scope: Literal["space", "mine", "household"] = "space"
    space_ids: list[str] = Field(default_factory=list)
    data_through_at: str | None
    currencies: list[FinanceCurrencySummary]


class FinanceOverviewSpendingCategory(BaseModel):
    category_key: str
    name: str
    spending_type: FinanceSpendingType
    spent_minor: int
    share_bps: int = Field(ge=0, le=10_000)


class FinanceOverviewBudgetBucket(BaseModel):
    category_key: str
    name: str
    budget_minor: int
    spent_minor: int
    remaining_minor: int


class FinanceOverviewCommitment(BaseModel):
    name: str
    due_date: date
    amount_minor: int


class FinanceOverviewSavingsPoint(BaseModel):
    date: date
    balance_minor: int


class FinanceOverviewResponse(BaseModel):
    scope: Literal["mine", "household"]
    month_start: date
    through_date: date
    currency: str
    account_count: int = Field(ge=0)
    income_minor: int
    spending_minor: int
    spending_by_category: list[FinanceOverviewSpendingCategory]
    budget_buckets: list[FinanceOverviewBudgetBucket]
    current_available_minor: int | None = None
    next_paycheck_date: date | None = None
    next_paycheck_minor: int | None = None
    left_until_payday_minor: int | None = None
    commitments_before_payday_minor: int
    commitments_before_payday_count: int = Field(ge=0)
    upcoming_commitments: list[FinanceOverviewCommitment]
    savings_balance_minor: int | None = None
    savings_change_minor: int | None = None
    savings_series: list[FinanceOverviewSavingsPoint]


KnowledgeStatus = Literal["PROPOSED", "CONFIRMED", "REJECTED", "EXPIRED"]


class FinanceFactCreate(BaseModel):
    fact_key: str = Field(min_length=1, max_length=100, pattern=r"^[a-z0-9][a-z0-9_.-]*$")
    statement: str = Field(min_length=1, max_length=2_000)
    evidence_refs: list[str] = Field(default_factory=list, max_length=100)

    @field_validator("statement")
    @classmethod
    def strip_statement(cls, value: str) -> str:
        return value.strip()


class FinanceFactUpdate(BaseModel):
    statement: str = Field(min_length=1, max_length=2_000)
    evidence_refs: list[str] = Field(default_factory=list, max_length=100)

    @field_validator("statement")
    @classmethod
    def strip_statement(cls, value: str) -> str:
        return value.strip()


class FinanceFactResponse(BaseModel):
    id: str
    space_id: str
    fact_key: str
    version: int
    statement: str
    evidence_refs: list[str]
    status: KnowledgeStatus
    supersedes_id: str | None = None
    confirmed_at: str | None = None
    expired_at: str | None = None
    created_at: str
    updated_at: str


class FinancePreferenceCreate(BaseModel):
    preference_key: str = Field(
        min_length=1,
        max_length=100,
        pattern=r"^[a-z0-9][a-z0-9_.-]*$",
    )
    statement: str = Field(min_length=1, max_length=2_000)
    value_kind: Literal["PROTECTED", "VALUED", "REGRETTED", "NEGOTIABLE", "NEUTRAL"] = "NEUTRAL"
    evidence_refs: list[str] = Field(default_factory=list, max_length=100)

    @field_validator("statement")
    @classmethod
    def strip_statement(cls, value: str) -> str:
        return value.strip()


class FinancePreferenceUpdate(BaseModel):
    statement: str = Field(min_length=1, max_length=2_000)
    value_kind: Literal["PROTECTED", "VALUED", "REGRETTED", "NEGOTIABLE", "NEUTRAL"]
    evidence_refs: list[str] = Field(default_factory=list, max_length=100)

    @field_validator("statement")
    @classmethod
    def strip_statement(cls, value: str) -> str:
        return value.strip()


class FinancePreferenceResponse(BaseModel):
    id: str
    space_id: str
    preference_key: str
    version: int
    statement: str
    value_kind: Literal["PROTECTED", "VALUED", "REGRETTED", "NEGOTIABLE", "NEUTRAL"]
    evidence_refs: list[str]
    status: KnowledgeStatus
    supersedes_id: str | None = None
    confirmed_at: str | None = None
    expired_at: str | None = None
    created_at: str
    updated_at: str


AmountMode = Literal["EXACT", "RANGE", "FORECAST"]
CommitmentRecurrence = Literal["ONE_OFF", "MONTHLY", "ANNUAL", "TERMLY", "CUSTOM"]
PlanningPriority = Literal["PROTECTED", "IMPORTANT", "OPTIONAL"]
PlanningStatus = Literal["ACTIVE", "PAUSED", "COMPLETED", "CANCELLED"]
PaymentHandling = Literal["UNSPECIFIED", "AUTOMATIC", "MANUAL", "RENEWAL"]


class FinanceCommitmentCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    amount_mode: AmountMode
    exact_minor: StrictInt | None = None
    expected_minor: StrictInt | None = None
    low_minor: StrictInt | None = None
    high_minor: StrictInt | None = None
    currency: str = "GBP"
    recurrence: CommitmentRecurrence
    reviewed_dates: list[date] = Field(min_length=1, max_length=120)
    priority: PlanningPriority = "IMPORTANT"
    funding_account_id: str | None = None
    already_reserved_minor: StrictInt = 0
    status: PlanningStatus = "ACTIVE"
    payment_handling: PaymentHandling = "UNSPECIFIED"
    show_in_calendar: bool = False
    show_in_tasks: bool = False
    responsible_user_id: str | None = Field(default=None, max_length=100)
    notes: str | None = Field(default=None, max_length=2_000)

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("name", "notes")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        return value.strip() if value else value

    @field_validator("reviewed_dates")
    @classmethod
    def unique_dates(cls, value: list[date]) -> list[date]:
        if len(set(value)) != len(value):
            raise ValueError("reviewed_dates cannot contain duplicates")
        return sorted(value)

    @model_validator(mode="after")
    def validate_amount(self):
        amounts = [self.exact_minor, self.expected_minor, self.low_minor, self.high_minor]
        if any(value is not None and value < 0 for value in amounts):
            raise ValueError("Commitment amounts cannot be negative")
        if self.already_reserved_minor < 0:
            raise ValueError("already_reserved_minor cannot be negative")
        if self.amount_mode == "EXACT" and self.exact_minor is None:
            raise ValueError("Exact commitments require exact_minor")
        if self.amount_mode == "RANGE":
            if self.low_minor is None or self.high_minor is None:
                raise ValueError("Range commitments require low_minor and high_minor")
            if self.low_minor > self.high_minor:
                raise ValueError("low_minor cannot exceed high_minor")
            if self.expected_minor is not None and not (
                self.low_minor <= self.expected_minor <= self.high_minor
            ):
                raise ValueError("expected_minor must fall inside the range")
        if self.amount_mode == "FORECAST" and self.expected_minor is None:
            raise ValueError("Forecast commitments require expected_minor")
        if self.recurrence == "ONE_OFF" and len(self.reviewed_dates) != 1:
            raise ValueError("One-off commitments require exactly one reviewed date")
        if (self.show_in_calendar or self.show_in_tasks) and self.payment_handling == "UNSPECIFIED":
            raise ValueError("Choose how the commitment is handled before showing it outside Finance")
        if self.show_in_tasks and self.responsible_user_id is None:
            raise ValueError("Choose one responsible adult before creating a task")
        return self


class FinanceCommitmentUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    amount_mode: AmountMode | None = None
    exact_minor: StrictInt | None = None
    expected_minor: StrictInt | None = None
    low_minor: StrictInt | None = None
    high_minor: StrictInt | None = None
    currency: str | None = None
    recurrence: CommitmentRecurrence | None = None
    reviewed_dates: list[date] | None = Field(default=None, min_length=1, max_length=120)
    priority: PlanningPriority | None = None
    funding_account_id: str | None = None
    already_reserved_minor: StrictInt | None = None
    status: PlanningStatus | None = None
    payment_handling: PaymentHandling | None = None
    show_in_calendar: bool | None = None
    show_in_tasks: bool | None = None
    responsible_user_id: str | None = Field(default=None, max_length=100)
    notes: str | None = Field(default=None, max_length=2_000)


class FinanceCommitmentResponse(BaseModel):
    id: str
    space_id: str
    name: str
    amount_mode: AmountMode
    exact_minor: int | None = None
    expected_minor: int | None = None
    low_minor: int | None = None
    high_minor: int | None = None
    currency: str
    recurrence: CommitmentRecurrence
    reviewed_dates: list[date]
    next_due_date: date | None = None
    priority: PlanningPriority
    funding_account_id: str | None = None
    already_reserved_minor: int
    required_minor: int
    remaining_minor: int
    funding_status: Literal["FUNDED", "PARTLY_FUNDED", "UNFUNDED", "UNDERFUNDED"]
    status: PlanningStatus
    payment_handling: PaymentHandling
    show_in_calendar: bool
    show_in_tasks: bool
    responsible_user_id: str | None = None
    notes: str | None = None
    created_at: str
    updated_at: str


class FinanceCalendarItemCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reviewed: Literal[True]
    space_id: str = Field(min_length=1, max_length=100)
    item_kind: Literal["GROCERY_DELIVERY", "PARCEL_DELIVERY"]
    source_id: str = Field(min_length=1, max_length=100)
    starts_at: str = Field(min_length=10, max_length=64)
    ends_at: str | None = Field(default=None, max_length=64)
    all_day: bool = False

    @field_validator("starts_at", "ends_at")
    @classmethod
    def validate_calendar_time(cls, value: str | None) -> str | None:
        if value is None:
            return None
        if len(value) == 10:
            date.fromisoformat(value)
            return value
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("Delivery date-times must include a timezone")
        return value

    @model_validator(mode="after")
    def validate_window(self):
        if self.all_day and (
            len(self.starts_at) != 10 or (self.ends_at and len(self.ends_at) != 10)
        ):
            raise ValueError("All-day deliveries use date-only values")
        if not self.all_day and len(self.starts_at) == 10:
            raise ValueError("Timed deliveries require a date and time")
        if self.ends_at:
            if (len(self.starts_at) == 10) != (len(self.ends_at) == 10):
                raise ValueError("Delivery start and end must both be dates or date-times")
            start = datetime.fromisoformat(self.starts_at.replace("Z", "+00:00"))
            end = datetime.fromisoformat(self.ends_at.replace("Z", "+00:00"))
            if end <= start:
                raise ValueError("Delivery end must be after its start")
        return self


class FinanceCalendarItemResponse(BaseModel):
    id: str
    space_id: str
    item_kind: Literal["GROCERY_DELIVERY", "PARCEL_DELIVERY"]
    source_id: str
    starts_at: str
    ends_at: str | None = None
    all_day: bool
    status: Literal["ACTIVE", "CANCELLED"]
    created_at: str
    updated_at: str


class FinanceCalendarItemPrefillResponse(BaseModel):
    item_kind: Literal["GROCERY_DELIVERY", "PARCEL_DELIVERY"]
    starts_at: str
    ends_at: str | None = None
    all_day: bool


class FinanceReserveCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    allocated_minor: StrictInt = Field(default=0, ge=0)
    target_minor: StrictInt | None = Field(default=None, ge=0)
    currency: str = "GBP"
    linked_account_id: str | None = None
    status: PlanningStatus = "ACTIVE"

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("name")
    @classmethod
    def strip_name(cls, value: str) -> str:
        return value.strip()


class FinanceReserveUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    allocated_minor: StrictInt | None = Field(default=None, ge=0)
    target_minor: StrictInt | None = Field(default=None, ge=0)
    currency: str | None = None
    linked_account_id: str | None = None
    status: PlanningStatus | None = None


class FinanceReserveResponse(BaseModel):
    id: str
    space_id: str
    name: str
    allocated_minor: int
    target_minor: int | None = None
    remaining_minor: int | None = None
    funding_status: Literal["UNTARGETED", "UNFUNDED", "PARTLY_FUNDED", "FUNDED", "OVERFUNDED"]
    currency: str
    linked_account_id: str | None = None
    status: PlanningStatus
    created_at: str
    updated_at: str


class FinanceGoalCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    target_minor: StrictInt = Field(gt=0)
    deadline: date
    currently_allocated_minor: StrictInt = Field(default=0, ge=0)
    currency: str = "GBP"
    priority: PlanningPriority = "IMPORTANT"
    allowed_funding_sources: list[str] = Field(default_factory=list, max_length=100)
    emergency_buffer_minor: StrictInt = Field(default=0, ge=0)
    status: Literal["ACTIVE", "PAUSED", "ACHIEVED", "CANCELLED"] = "ACTIVE"
    notes: str | None = Field(default=None, max_length=2_000)

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, value: str) -> str:
        return normalise_currency(value)

    @field_validator("name", "notes")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        return value.strip() if value else value

    @field_validator("allowed_funding_sources")
    @classmethod
    def unique_sources(cls, value: list[str]) -> list[str]:
        if len(set(value)) != len(value):
            raise ValueError("allowed_funding_sources cannot contain duplicates")
        return value


class FinanceGoalUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    target_minor: StrictInt | None = Field(default=None, gt=0)
    deadline: date | None = None
    currently_allocated_minor: StrictInt | None = Field(default=None, ge=0)
    currency: str | None = None
    priority: PlanningPriority | None = None
    allowed_funding_sources: list[str] | None = Field(default=None, max_length=100)
    emergency_buffer_minor: StrictInt | None = Field(default=None, ge=0)
    status: Literal["ACTIVE", "PAUSED", "ACHIEVED", "CANCELLED"] | None = None
    notes: str | None = Field(default=None, max_length=2_000)


class FinanceGoalResponse(BaseModel):
    id: str
    space_id: str
    name: str
    target_minor: int
    deadline: date
    currently_allocated_minor: int
    remaining_minor: int
    currency: str
    priority: PlanningPriority
    allowed_funding_sources: list[str]
    emergency_buffer_minor: int
    feasibility: Literal["ACHIEVED", "INFEASIBLE", "UNASSESSED"]
    shortfall_minor: int | None = None
    status: Literal["ACTIVE", "PAUSED", "ACHIEVED", "CANCELLED"]
    notes: str | None = None
    created_at: str
    updated_at: str


ForecastEventKind = Literal[
    "income",
    "expense",
    "commitment",
    "reserve",
    "goal",
    "planned",
    "transfer",
    "card_purchase",
    "refund",
]


class FinanceForecastGenerate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    end_date: date
    currency: str = "GBP"
    household_buffer_minor: StrictInt = Field(default=0, ge=0)

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, value: str) -> str:
        return normalise_currency(value)


class FinanceForecastAccountDayResponse(BaseModel):
    account_id: str
    balance_minor: int
    floor_minor: int
    headroom_minor: int


class FinanceForecastDayResponse(BaseModel):
    day: date
    accounts: list[FinanceForecastAccountDayResponse]
    household_liquid_minor: int
    household_free_minor: int
    constraints_passed_through_day: bool


class FinanceForecastEventResponse(BaseModel):
    event_id: str
    day: date
    account_id: str
    amount_minor: int
    currency: str
    kind: ForecastEventKind
    destination_account_id: str | None = None
    sequence: int
    provenance: str | None = None


class FinanceForecastResponse(BaseModel):
    id: str
    space_id: str
    input_snapshot_digest: str
    engine_version: str
    household_timezone: str
    currency: str
    start_date: date
    end_date: date
    household_buffer_minor: int
    passed: bool
    limiting_event: dict | None = None
    minimum_household_free_minor: int
    minimum_household_free_date: date
    data_through_at: str | None = None
    source: Literal["SAVED", "LEGACY_EXPLICIT"]
    data_status: Literal["CURRENT", "STALE", "PARTIAL"]
    input_notes: list[str]
    events: list[FinanceForecastEventResponse]
    days: list[FinanceForecastDayResponse]
    created_at: str


class FinanceForecastOverviewDayResponse(BaseModel):
    day: date
    household_liquid_minor: int
    household_free_minor: int
    constraints_passed_through_day: bool


class FinanceForecastOverviewResponse(BaseModel):
    """Exact forecast headline and chart data without repeated account-day rows."""

    id: str
    space_id: str
    input_snapshot_digest: str
    engine_version: str
    household_timezone: str
    currency: str
    start_date: date
    end_date: date
    household_buffer_minor: int
    passed: bool
    limiting_event: dict | None = None
    minimum_household_free_minor: int
    minimum_household_free_date: date
    data_through_at: str | None = None
    source: Literal["SAVED", "LEGACY_EXPLICIT"]
    data_status: Literal["CURRENT", "STALE", "PARTIAL"]
    input_notes: list[str]
    events: list[FinanceForecastEventResponse]
    opening_accounts: list[FinanceForecastAccountDayResponse]
    days: list[FinanceForecastOverviewDayResponse]
    created_at: str


class FinanceSafeToSpendRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    forecast_id: str = Field(min_length=1, max_length=100)
    route: Literal["direct", "full_repayment_card"]
    spend_date: date
    account_id: str | None = Field(default=None, max_length=100)
    card_account_id: str | None = Field(default=None, max_length=100)
    unobserved_spend_low_minor: StrictInt = Field(default=0, ge=0)
    unobserved_spend_high_minor: StrictInt = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_route(self):
        if self.unobserved_spend_high_minor < self.unobserved_spend_low_minor:
            raise ValueError("unobserved_spend_high_minor must not be below the low estimate")
        if self.route == "direct":
            if not self.account_id:
                raise ValueError("Direct spending requires account_id")
            if self.card_account_id is not None:
                raise ValueError("Direct spending cannot include card route fields")
        else:
            if self.account_id is not None:
                raise ValueError("Card spending cannot include account_id")
            if self.card_account_id is None:
                raise ValueError("Card spending requires card_account_id")
        return self


class FinanceSafeToSpendResponse(BaseModel):
    forecast_id: str
    input_snapshot_digest: str
    status: str
    answer_mode: str
    currency: str
    amount_minor: int | None = None
    low_minor: int | None = None
    high_minor: int | None = None
    data_through: date | None = None
    evaluated_through: date
    limiting_event: dict | None = None
    refusal_reasons: list[str]


FinanceEvidenceAdapter = Literal[
    "tesco_batch",
    "amazon_email",
    "e_receipt",
    "service_invoice",
    "pdf",
    "image",
    "html",
    "natural_language",
]


class FinancePurchaseEvidenceIngest(BaseModel):
    external_source_id: str = Field(min_length=1, max_length=300)
    adapter: FinanceEvidenceAdapter
    reviewed: Literal[True]
    payload: dict[str, object]
    received_at: datetime | None = None
    corrects_source_id: str | None = Field(default=None, max_length=100)

    @field_validator("external_source_id")
    @classmethod
    def strip_external_source_id(cls, value: str) -> str:
        return value.strip()

    @field_validator("received_at")
    @classmethod
    def require_aware_received_at(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("received_at must include a timezone")
        return value


class FinanceEvidenceIssueResponse(BaseModel):
    code: str
    message: str


class FinanceEvidenceFileResponse(BaseModel):
    id: str
    file_role: Literal["MESSAGE", "ATTACHMENT"]
    filename: str
    media_type: str
    byte_size: int
    storage_status: Literal[
        "STORED",
        "REJECTED_TYPE",
        "REJECTED_SIZE",
        "REJECTED_UNSAFE",
    ]


class FinancePurchaseEvidenceResponse(BaseModel):
    id: str
    space_id: str
    external_source_id: str
    source_kind: FinanceEvidenceAdapter
    corrects_source_id: str | None = None
    parser_version: str | None = None
    extraction_status: Literal["PARSED", "QUARANTINED", "UNSUPPORTED"]
    confidence_bps: int | None = None
    raw_payload: dict[str, object]
    issues: list[FinanceEvidenceIssueResponse]
    storage_area: Literal["finance-evidence"]
    storage_key: str | None = None
    provider_message_id: str | None = None
    visible_sender: str | None = None
    email_subject: str | None = None
    files: list[FinanceEvidenceFileResponse] = Field(default_factory=list)
    received_at: str
    parsed_at: str | None = None
    created_at: str


class FinancePurchaseLineResponse(BaseModel):
    id: str
    line_ref: str
    position: int
    line_kind: Literal["product", "service", "delivery", "fee", "tax", "unknown"]
    raw_description: str
    quantity_decimal: str
    unit_description: str | None = None
    unit_price_minor: int | None = None
    line_gross_minor: int | None = None
    line_discount_minor: int | None = None
    line_net_minor: int | None = None
    evidence_status: Literal[
        "observed_structured",
        "observed_document",
        "user_confirmed",
        "inferred",
        "unitemised",
    ]
    source_refs: list[dict[str, str]]
    seller: str | None = None
    product_reference: str | None = None
    replaces_description: str | None = None
    shipment_reference: str | None = None


class FinancePurchaseTenderResponse(BaseModel):
    id: str
    tender_ref: str
    tender_kind: Literal["bank", "card", "cash", "gift_card", "credit", "unknown"]
    amount_minor: int
    provider_transaction_id: str | None = None
    card_suffix: str | None = None
    source_refs: list[dict[str, str]]


class FinanceLineRefundResponse(BaseModel):
    id: str
    refund_ref: str
    line_id: str
    line_ref: str
    amount_minor: int
    quantity_decimal: str | None = None
    source_refs: list[dict[str, str]]


class FinancePurchasePaymentResponse(BaseModel):
    id: str
    allocation_ref: str
    transaction_id: str | None = None
    line_id: str | None = None
    tender_kind: Literal["bank", "card", "cash", "gift_card", "credit", "unknown"]
    allocated_minor: int
    transaction_amount_minor: int | None = None
    transaction_date: date | None = None
    match_method: Literal["AUTO_EXACT", "REVIEWED", "EVIDENCED_NON_BANK"]
    status: Literal["PROPOSED", "CONFIRMED", "REJECTED"]


class FinancePurchaseMatchAllocation(BaseModel):
    transaction_id: str = Field(min_length=1, max_length=100)
    allocated_minor: StrictInt
    line_id: str | None = Field(default=None, min_length=1, max_length=100)

    @field_validator("allocated_minor")
    @classmethod
    def require_nonzero_allocation(cls, value: int) -> int:
        if value == 0:
            raise ValueError("allocated_minor must be non-zero")
        return value


class FinancePurchaseMatchReview(BaseModel):
    reviewed: Literal[True]
    allocations: list[FinancePurchaseMatchAllocation] = Field(
        min_length=1,
        max_length=100,
    )

    @field_validator("allocations")
    @classmethod
    def require_unique_transactions(
        cls,
        value: list[FinancePurchaseMatchAllocation],
    ) -> list[FinancePurchaseMatchAllocation]:
        transaction_ids = [allocation.transaction_id for allocation in value]
        if len(transaction_ids) != len(set(transaction_ids)):
            raise ValueError("Each canonical transaction may appear only once per review")
        return value


class FinancePurchaseSummaryResponse(BaseModel):
    id: str
    space_id: str
    merchant: str
    item_descriptions: list[str] = Field(default_factory=list)
    order_reference: str | None = None
    purchased_on: date
    currency: str
    lines_subtotal_minor: int
    shipping_minor: int
    vat_included_minor: int
    order_discount_minor: int
    final_total_minor: int
    refunded_minor: int
    behavioural_net_minor: int
    status: Literal[
        "pending",
        "partly_fulfilled",
        "fulfilled",
        "partly_refunded",
        "refunded",
        "cancelled",
    ]
    source_kind: FinanceEvidenceAdapter
    match_status: Literal["MATCHED", "PARTIAL", "UNMATCHED"]
    unmatched_purchase_minor: int
    unmatched_refund_minor: int
    cashflow_source: Literal["canonical_transactions"] = "canonical_transactions"
    purchase_total_added_to_cashflow: Literal[False] = False
    supersedes_purchase_id: str | None = None
    superseded_by_id: str | None = None
    created_at: str


class FinancePurchaseDetailResponse(FinancePurchaseSummaryResponse):
    evidence: FinancePurchaseEvidenceResponse
    lines: list[FinancePurchaseLineResponse]
    tenders: list[FinancePurchaseTenderResponse]
    refunds: list[FinanceLineRefundResponse]
    payment_allocations: list[FinancePurchasePaymentResponse]


class FinancePurchaseExceptionResponse(BaseModel):
    id: str
    space_id: str
    source_id: str
    purchase_id: str | None = None
    exception_kind: Literal[
        "QUARANTINED_EVIDENCE",
        "UNSUPPORTED_SOURCE",
        "AMBIGUOUS_MATCH",
        "UNMATCHED_PURCHASE",
        "PARTIAL_ITEMISATION",
    ]
    title: str
    detail: str
    amount_minor: int | None = None
    currency: str | None = None
    status: Literal["OPEN", "RESOLVED", "DISMISSED"]
    priority: int
    created_at: str


class FinancePurchaseEvidenceIngestResponse(BaseModel):
    source: FinancePurchaseEvidenceResponse
    purchase: FinancePurchaseDetailResponse | None = None
    exception: FinancePurchaseExceptionResponse | None = None
    duplicate: bool


class FinanceEmailAddressResponse(BaseModel):
    id: str
    space_id: str
    alias_kind: Literal["PERSONAL", "HOUSEHOLD"]
    address: str
    enabled: bool
    last_received_at: str | None = None
    last_parsed_at: str | None = None
    last_test_sent_at: str | None = None
    created_at: str


class FinanceEmailAddressesResponse(BaseModel):
    configured: bool
    addresses: list[FinanceEmailAddressResponse] = Field(default_factory=list)
    gmail_instructions: str
    outlook_instructions: str


class FinanceEmailEnrollmentCreate(BaseModel):
    expected_forwarder_address: str = Field(min_length=3, max_length=320)
    retailer_domain: str = Field(min_length=3, max_length=253)
    transport_marker: str | None = Field(default=None, min_length=3, max_length=500)

    @field_validator("expected_forwarder_address")
    @classmethod
    def normalise_forwarder(cls, value: str) -> str:
        value = value.strip().lower()
        if value.count("@") != 1:
            raise ValueError("expected_forwarder_address must be an email address")
        return value

    @field_validator("retailer_domain")
    @classmethod
    def normalise_retailer_domain(cls, value: str) -> str:
        value = value.strip().lower().lstrip("@")
        if (
            "." not in value
            or value.startswith(".")
            or value.endswith(".")
            or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-." for character in value)
        ):
            raise ValueError("retailer_domain must be a DNS domain")
        return value

    @field_validator("transport_marker")
    @classmethod
    def strip_transport_marker(cls, value: str | None) -> str | None:
        return value.strip() if value else value


class FinanceEmailEnrollmentResponse(BaseModel):
    id: str
    alias_id: str
    space_id: str
    expected_forwarder_address: str
    retailer_domain: str
    transport_marker: str
    status: Literal["PENDING", "ACTIVE", "DISABLED"]
    verified_at: str | None = None
    last_received_at: str | None = None
    last_success_at: str | None = None


class FinanceEmailSourceHealthResponse(BaseModel):
    alias: FinanceEmailAddressResponse
    health: list[dict[str, object]] = Field(default_factory=list)
    enrollments: list[FinanceEmailEnrollmentResponse] = Field(default_factory=list)
    open_exception_count: int


class FinanceEmailSendTestResponse(BaseModel):
    queued: bool
    destination: str


class FinanceRecurringSeriesResponse(BaseModel):
    id: str
    space_id: str
    detection_key: str | None = None
    name: str
    series_type: Literal["SALARY", "BILL", "SUBSCRIPTION", "RECURRING_COST"]
    interval_kind: Literal["MONTHLY", "FOUR_WEEKLY", "ANNUAL", "IRREGULAR"]
    expected_minor: int
    low_minor: int | None = None
    high_minor: int | None = None
    currency: str
    next_expected_date: date | None = None
    working_day_adjustment: Literal["PREVIOUS", "NEXT"] | None = None
    evidence_refs: list[str]
    confidence_bps: int
    status: Literal["CANDIDATE", "CONFIRMED", "REJECTED", "EXPIRED"]
    confirmed_at: str | None = None
    updated_at: str


class FinanceRecurringCorrection(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    series_type: Literal["SALARY", "BILL", "SUBSCRIPTION", "RECURRING_COST"]
    interval_kind: Literal["MONTHLY", "FOUR_WEEKLY", "ANNUAL", "IRREGULAR"]
    expected_minor: StrictInt = Field(ge=0)
    low_minor: StrictInt = Field(ge=0)
    high_minor: StrictInt = Field(ge=0)
    currency: str = "GBP"
    next_expected_date: date
    working_day_adjustment: Literal["PREVIOUS", "NEXT"] | None = None

    @model_validator(mode="after")
    def validate_amount_range(self):
        if not self.low_minor <= self.expected_minor <= self.high_minor:
            raise ValueError("Recurring amount range must contain the expected amount")
        self.currency = normalise_currency(self.currency)
        self.name = self.name.strip()
        return self


class FinanceFindingResponse(BaseModel):
    id: str
    space_id: str
    finding_type: Literal[
        "TREND_CHANGE",
        "SEASONAL",
        "REPEATED_ONE_OFF",
        "PRICE_DRIFT",
        "DUPLICATE_REPLACEMENT",
        "REPEATED_RETURN",
        "ANNUALISED_SMALL_COST",
    ]
    title: str
    observation: str
    evidence_refs: list[str]
    baseline: dict[str, object]
    saving_low_minor: int
    saving_high_minor: int
    currency: str
    confidence_bps: int
    effort: int
    overlap_group: str | None = None
    status: Literal["OPEN", "ACCEPTED", "DISMISSED", "SNOOZED", "EXPIRED"]
    data_through_date: date
    updated_at: str


class FinanceFindingDisposition(BaseModel):
    status: Literal["ACCEPTED", "DISMISSED", "SNOOZED"]


class FinanceMaterialQuestionResponse(BaseModel):
    id: str
    space_id: str
    question_kind: Literal[
        "SALARY",
        "NURSERY",
        "MISSING_CARD",
        "LARGE_UNITEMISED_PURCHASE",
    ]
    prompt: str
    evidence_refs: list[str]
    action_kind: Literal[
        "CONFIRM_RECURRING",
        "IDENTIFY_SALARY",
        "SAVE_NURSERY_PLAN",
        "ADD_CREDIT_CARD",
        "ITEMISE_PURCHASE",
    ]
    action_target_id: str | None = None
    next_action_method: Literal["GET", "POST", "PUT"]
    next_action_route: str
    priority_minor: int
    currency: str
    status: Literal["OPEN", "CONFIRMED", "CORRECTED", "DISMISSED", "EXPIRED"]
    answer_text: str | None = None
    resolved_at: str | None = None
    updated_at: str


class FinanceMaterialQuestionAnswer(BaseModel):
    answer_text: str | None = Field(default=None, max_length=2_000)

    @field_validator("answer_text")
    @classmethod
    def strip_answer(cls, value: str | None) -> str | None:
        return value.strip() if value else value


class FinanceMaterialQuestionCorrection(BaseModel):
    answer_text: str | None = Field(default=None, min_length=1, max_length=2_000)
    recurring: FinanceRecurringCorrection | None = None
    nursery_expected_minor: StrictInt | None = Field(default=None, ge=0)
    nursery_due_dates: list[date] | None = Field(default=None, min_length=1, max_length=24)

    @field_validator("answer_text")
    @classmethod
    def strip_answer(cls, value: str | None) -> str | None:
        return value.strip() if value else value

    @model_validator(mode="after")
    def require_typed_correction(self):
        nursery_fields = (self.nursery_expected_minor, self.nursery_due_dates)
        if any(value is not None for value in nursery_fields) and not all(
            value is not None for value in nursery_fields
        ):
            raise ValueError("Nursery correction needs an amount and due dates")
        if self.recurring is None and not all(value is not None for value in nursery_fields):
            raise ValueError("A typed recurring or nursery correction is required")
        return self


class FinancePatternScanResponse(BaseModel):
    space_id: str
    data_through_date: date | None
    recurring_series: list[FinanceRecurringSeriesResponse]
    findings: list[FinanceFindingResponse]
    questions: list[FinanceMaterialQuestionResponse]
    selected_finding_ids: list[str]
    suppressed_finding_ids: list[str]
    combined_saving_low_minor: int
    combined_saving_high_minor: int
