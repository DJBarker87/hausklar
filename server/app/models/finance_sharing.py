from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictInt, UUID4, field_validator, model_validator

from app.services.finance.money import normalise_currency


FinanceShareKind = Literal[
    "ACCOUNT",
    "TRANSACTION",
    "PURCHASE",
    "PURCHASE_LINES",
    "COMMITMENT",
    "GOAL",
    "CONTRIBUTION",
    "RULE",
]


class FinancePurchaseShareCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    mode: Literal["FULL", "SELECTED_LINES"]
    line_ids: list[str] = Field(default_factory=list, max_length=100)

    @model_validator(mode="after")
    def validate_selection(self):
        if self.mode == "FULL" and self.line_ids:
            raise ValueError("Full purchase sharing cannot include line_ids")
        if self.mode == "SELECTED_LINES" and not self.line_ids:
            raise ValueError("Selected-line sharing requires at least one line_id")
        if len(self.line_ids) != len(set(self.line_ids)):
            raise ValueError("line_ids cannot contain duplicates")
        return self


class FinanceSharePreviewRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["ACCOUNT", "TRANSACTION", "PURCHASE", "COMMITMENT", "GOAL"]
    source_record_id: str = Field(min_length=1, max_length=100)
    purchase: FinancePurchaseShareCreate | None = None

    @model_validator(mode="after")
    def validate_purchase_options(self):
        if (self.kind == "PURCHASE") != (self.purchase is not None):
            raise ValueError("Purchase preview options are required only for purchases")
        return self


class FinanceShareRuleCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    target: Literal["TRANSACTION", "PURCHASE"]
    merchant: str = Field(min_length=1, max_length=200)

    @field_validator("merchant")
    @classmethod
    def strip_merchant(cls, value: str) -> str:
        return " ".join(value.split())


class FinanceContributionCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: UUID4
    amount_minor: StrictInt = Field(gt=0)
    currency: str = "GBP"
    contribution_date: date

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, value: str) -> str:
        return normalise_currency(value)


class FinanceShareResponse(BaseModel):
    id: str
    kind: FinanceShareKind
    status: Literal["ACTIVE", "COMPLETED", "STOPPED"]
    applies_to_future: bool
    shared_record_type: str | None = None
    shared_record_id: str | None = None
    rule_target: Literal["TRANSACTION", "PURCHASE"] | None = None
    rule_match_kind: Literal["MERCHANT"] | None = None
    rule_match_value: str | None = None
    created_at: str
    stopped_at: str | None = None
    label: str
    included: list[str] = Field(default_factory=list)
    sharing_mode: Literal["ONCE", "AUTOMATIC"]
    source_updated_at: str | None = None
    shared_copy_updated_at: str | None = None
    stale: bool = False
    version_state: Literal["CURRENT", "PAST"]


class FinanceSharePreviewResponse(BaseModel):
    kind: FinanceShareKind
    label: str
    included: list[str] = Field(default_factory=list)
    sharing_mode: Literal["ONCE", "AUTOMATIC"]
    applies_to_future: bool
    source_updated_at: str | None = None
    existing_share: FinanceShareResponse | None = None


class FinanceContributionResponse(BaseModel):
    id: str
    space_id: str
    amount_minor: int
    currency: str
    contribution_date: date
    label: Literal["Contribution from a personal space"]
    status: Literal["ACTIVE", "CANCELLED"]
    created_at: str
