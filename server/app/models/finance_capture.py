"""Typed, editable review cards for ephemeral Finance text capture."""

from __future__ import annotations

from datetime import date as Date
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator, model_validator

from app.services.finance.ai import FinanceAnswer
from app.services.finance.money import normalise_currency

class FinanceCaptureConversationTurn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role: Literal["user", "assistant"]
    text: str = Field(min_length=1, max_length=1_500)


class FinanceCaptureScreenContext(BaseModel):
    model_config = ConfigDict(extra="forbid")

    screen: Literal[
        "coach", "transactions", "purchase", "purchases", "explore", "plan", "habits"
    ] = "coach"
    selected_transaction_id: str | None = Field(default=None, max_length=100)
    selected_purchase_id: str | None = Field(default=None, max_length=100)
    selected_purchase_line_id: str | None = Field(default=None, max_length=100)
    selected_account_id: str | None = Field(default=None, max_length=100)


class FinanceCaptureInterpretRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    space_id: str = Field(min_length=1, max_length=100)
    text: str = Field(min_length=1, max_length=4_000)
    conversation: list[FinanceCaptureConversationTurn] = Field(
        default_factory=list, max_length=8
    )
    context: FinanceCaptureScreenContext = Field(default_factory=FinanceCaptureScreenContext)

    @field_validator("text")
    @classmethod
    def strip_text(cls, value: str) -> str:
        return value.strip()


class FinanceCaptureLine(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=300)
    amount_minor: StrictInt = Field(ge=0)
    category_name: str | None = Field(default=None, min_length=1, max_length=120)
    purpose: str | None = Field(default=None, min_length=1, max_length=200)
    beneficiary: str | None = Field(default=None, min_length=1, max_length=120)
    normalized_item: str | None = Field(default=None, min_length=1, max_length=200)
    utility: Literal["essential", "useful", "optional", "unclear"] | None = None
    outcome_state: Literal[
        "valued", "neutral", "regretted", "returned", "unused", "unknown"
    ] | None = None


class _CaptureContent(BaseModel):
    model_config = ConfigDict(extra="forbid")

    uncertainties: list[str] = Field(default_factory=list, max_length=20)


class FinanceFactCapture(_CaptureContent):
    kind: Literal["FACT"]
    statement: str = Field(min_length=1, max_length=2_000)


class FinancePreferenceCapture(_CaptureContent):
    kind: Literal["PREFERENCE"]
    statement: str = Field(min_length=1, max_length=2_000)
    value_kind: Literal["PROTECTED", "VALUED", "REGRETTED", "NEGOTIABLE", "NEUTRAL"]


class FinanceTransactionCorrectionCapture(_CaptureContent):
    kind: Literal["TRANSACTION_CORRECTION"]
    merchant_hint: str = Field(min_length=1, max_length=200)
    payment_amount_minor: StrictInt = Field(gt=0)
    transaction_date: Date | None = None
    currency: str = "GBP"
    splits: list[FinanceCaptureLine] = Field(min_length=1, max_length=100)
    unassigned_remainder_minor: StrictInt = Field(default=0, ge=0)

    @model_validator(mode="after")
    def reconcile(self):
        if sum(line.amount_minor for line in self.splits) + self.unassigned_remainder_minor != self.payment_amount_minor:
            raise ValueError("Split lines and unassigned remainder must equal the payment")
        self.currency = normalise_currency(self.currency)
        return self


class FinancePurchaseDetailsCapture(_CaptureContent):
    kind: Literal["PURCHASE_DETAILS"]
    merchant: str = Field(min_length=1, max_length=200)
    payment_amount_minor: StrictInt = Field(gt=0)
    purchased_on: Date | None = None
    currency: str = "GBP"
    lines: list[FinanceCaptureLine] = Field(min_length=1, max_length=100)
    unassigned_remainder_minor: StrictInt = Field(default=0, ge=0)

    @model_validator(mode="after")
    def reconcile(self):
        if sum(line.amount_minor for line in self.lines) + self.unassigned_remainder_minor != self.payment_amount_minor:
            raise ValueError("Purchase lines and unassigned remainder must equal the payment")
        self.currency = normalise_currency(self.currency)
        return self


class FinanceItemOutcomeCapture(_CaptureContent):
    kind: Literal["ITEM_OUTCOME"]
    item_hint: str = Field(min_length=1, max_length=300)
    merchant_hint: str | None = Field(default=None, min_length=1, max_length=200)
    purchased_on: Date | None = None
    outcome_state: Literal["valued", "neutral", "regretted", "returned", "unused"]
    correction_reason: str = Field(min_length=1, max_length=500)


class FinanceCashSpendCapture(_CaptureContent):
    kind: Literal["CASH_SPEND"]
    merchant: str = Field(min_length=1, max_length=200)
    spent_on: Date
    total_minor: StrictInt = Field(gt=0)
    currency: str = "GBP"
    account_hint: str | None = Field(default=None, min_length=1, max_length=120)
    lines: list[FinanceCaptureLine] = Field(min_length=1, max_length=100)
    unassigned_remainder_minor: StrictInt = Field(default=0, ge=0)

    @model_validator(mode="after")
    def reconcile(self):
        if sum(line.amount_minor for line in self.lines) + self.unassigned_remainder_minor != self.total_minor:
            raise ValueError("Cash-spend lines and unassigned remainder must equal the total")
        self.currency = normalise_currency(self.currency)
        return self


class FinanceCommitmentCapture(_CaptureContent):
    kind: Literal["COMMITMENT"]
    name: str = Field(min_length=1, max_length=200)
    amount_mode: Literal["EXACT", "FORECAST"]
    exact_minor: StrictInt | None = Field(default=None, ge=0)
    expected_minor: StrictInt | None = Field(default=None, ge=0)
    currency: str = "GBP"
    recurrence: Literal["ONE_OFF", "MONTHLY", "ANNUAL", "TERMLY", "CUSTOM"]
    reviewed_date: Date
    priority: Literal["PROTECTED", "IMPORTANT", "OPTIONAL"] = "IMPORTANT"
    payment_handling: Literal["UNSPECIFIED", "AUTOMATIC", "MANUAL", "RENEWAL"] = "MANUAL"
    show_in_calendar: bool = False
    show_in_tasks: bool = False
    responsible_user_id: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def validate_amount(self):
        if self.amount_mode == "EXACT" and self.exact_minor is None:
            raise ValueError("An exact commitment needs an exact amount")
        if self.amount_mode == "FORECAST" and self.expected_minor is None:
            raise ValueError("A forecast commitment needs an expected amount")
        if (self.show_in_calendar or self.show_in_tasks) and self.payment_handling == "UNSPECIFIED":
            raise ValueError("Choose how this bill is paid before adding a reminder")
        if self.show_in_tasks and self.responsible_user_id is None:
            raise ValueError("Choose a responsible adult before creating a task")
        self.currency = normalise_currency(self.currency)
        return self


class FinanceGoalCapture(_CaptureContent):
    kind: Literal["GOAL"]
    name: str = Field(min_length=1, max_length=200)
    target_minor: StrictInt = Field(gt=0)
    deadline: Date
    currency: str = "GBP"
    priority: Literal["PROTECTED", "IMPORTANT", "OPTIONAL"] = "IMPORTANT"

    @field_validator("currency")
    @classmethod
    def currency_code(cls, value: str) -> str:
        return normalise_currency(value)


class FinanceHabitCapture(_CaptureContent):
    kind: Literal["HABIT"]
    slot: Literal["PRIMARY", "SECONDARY"] = "PRIMARY"
    name: str = Field(min_length=1, max_length=200)
    trigger: str = Field(min_length=1, max_length=500)
    minimum_line_minor: StrictInt = Field(default=0, ge=0)
    purposes: list[str] = Field(default_factory=list, max_length=50)
    utilities: list[Literal["essential", "useful", "optional", "unclear"]] = Field(
        default_factory=list, max_length=4
    )
    start_date: Date
    review_date: Date
    fallback: str = Field(min_length=1, max_length=1_000)


class FinancePurchasePlanCapture(_CaptureContent):
    kind: Literal["PURCHASE_PLAN"]
    name: str = Field(min_length=1, max_length=300)
    amount_low_minor: StrictInt = Field(ge=0)
    amount_high_minor: StrictInt = Field(ge=0)
    desired_date: Date
    currency: str = "GBP"
    recurrence: Literal["ONE_OFF", "MONTHLY", "ANNUAL"] = "ONE_OFF"
    purpose: str | None = Field(default=None, max_length=200)
    beneficiary: str | None = Field(default=None, max_length=120)
    payment_account_hint: str | None = Field(default=None, max_length=120)

    @model_validator(mode="after")
    def validate_range(self):
        if self.amount_high_minor < self.amount_low_minor:
            raise ValueError("Purchase-plan amount range is invalid")
        self.currency = normalise_currency(self.currency)
        return self


FinanceCaptureContent = Annotated[
    FinanceFactCapture
    | FinancePreferenceCapture
    | FinanceTransactionCorrectionCapture
    | FinancePurchaseDetailsCapture
    | FinanceItemOutcomeCapture
    | FinanceCashSpendCapture
    | FinanceCommitmentCapture
    | FinanceGoalCapture
    | FinanceHabitCapture
    | FinancePurchasePlanCapture,
    Field(discriminator="kind"),
]


class FinanceCaptureTargetOption(BaseModel):
    id: str
    kind: Literal[
        "TRANSACTION", "PURCHASE", "PURCHASE_LINE", "ACCOUNT", "PURCHASE_ONLY", "ADULT"
    ]
    label: str
    date: Date | None = None
    amount_minor: int | None = None
    currency: str | None = None


class FinanceCaptureDraftResponse(BaseModel):
    id: str
    space_id: str
    content: FinanceCaptureContent
    title: str
    target_options: list[FinanceCaptureTargetOption] = Field(default_factory=list)
    category_options: list[str] = Field(default_factory=list)
    expires_at: str


class FinanceCaptureInterpretResponse(BaseModel):
    mode: Literal["REVIEW", "ANSWER", "CLARIFY"]
    drafts: list[FinanceCaptureDraftResponse] = Field(default_factory=list)
    answer: FinanceAnswer | None = None
    message: str | None = None
    conversation_persisted: Literal[False] = False


class FinanceCaptureConfirmRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    content: FinanceCaptureContent
    selected_target_id: str | None = Field(default=None, max_length=100)
    selected_account_id: str | None = Field(default=None, max_length=100)


class FinanceCaptureConfirmResponse(BaseModel):
    draft_id: str
    status: Literal["CONFIRMED"]
    action_kind: str
    action_id: str
    result: dict[str, object]
