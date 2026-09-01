"""Editable user settings for an imported or manual Finance account."""

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, model_validator

from app.models.finance import AccountPurpose


class FinanceAccountSettingsUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: str | None = Field(default=None, min_length=1, max_length=120)
    purpose: AccountPurpose | None = None
    include_in_cashflow: StrictBool | None = None
    include_in_net_worth: StrictBool | None = None
    primary_spending_account: StrictBool | None = None
    minimum_balance_minor: StrictInt | None = Field(
        default=None,
        ge=0,
        le=1_000_000_000_000_000,
    )
    card_paid_in_full: StrictBool | None = None
    card_settlement_account_id: str | None = Field(default=None, min_length=1, max_length=100)
    card_statement_close_day: StrictInt | None = Field(default=None, ge=1, le=31)
    card_repayment_day: StrictInt | None = Field(default=None, ge=1, le=31)

    @model_validator(mode="after")
    def require_change(self) -> "FinanceAccountSettingsUpdate":
        if not self.model_fields_set:
            raise ValueError("At least one account setting is required")
        if self.label is not None:
            stripped = self.label.strip()
            if not stripped:
                raise ValueError("Account label must not be blank")
            self.label = stripped
        return self
