"""Strict API contracts for purchase understanding and saved-record analysis."""

from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.services.finance.money import normalise_currency

Plannedness = Literal[
    "planned", "routine", "replacement", "emergency", "impulse", "unknown"
]
Utility = Literal["essential", "useful", "optional", "unclear"]
DecisionQuality = Literal["sensible", "mixed", "questionable", "poor_value", "unknown"]
ValueForMoney = Literal["good", "fair", "poor", "unknown"]
OutcomeState = Literal["valued", "neutral", "regretted", "returned", "unused", "unknown"]


class FinancePurchaseLineAssessmentUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    normalized_item_name: str | None = Field(default=None, min_length=1, max_length=200)
    beneficiary: str | None = Field(default=None, min_length=1, max_length=120)
    purpose: str | None = Field(default=None, min_length=1, max_length=200)
    plannedness: Plannedness | None = None
    utility: Utility | None = None
    decision_quality: DecisionQuality | None = None
    value_for_money: ValueForMoney | None = None
    outcome_state: OutcomeState | None = None
    correction_reason: str | None = Field(default=None, min_length=1, max_length=500)

    @field_validator("normalized_item_name", "beneficiary", "purpose", "correction_reason")
    @classmethod
    def nonblank_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        if not value:
            raise ValueError("Assessment text cannot be blank")
        return value

    @model_validator(mode="after")
    def require_classification_change(self):
        changed = self.model_fields_set - {"correction_reason"}
        if not changed:
            raise ValueError("At least one assessment field is required")
        return self


class FinancePurchaseLineAssessmentConfirm(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reviewed: Literal[True]
    disposition: Literal["CORRECT", "NOT_RELEVANT"] = "CORRECT"


class FinancePurchaseLineAssessmentResponse(BaseModel):
    id: str
    line_id: str
    purchase_id: str
    space_id: str
    source_description: str
    normalized_item_id: str | None = None
    normalized_item_name: str | None = None
    beneficiary: str | None = None
    purpose: str | None = None
    plannedness: Plannedness | None = None
    utility: Utility | None = None
    decision_quality: DecisionQuality | None = None
    value_for_money: ValueForMoney | None = None
    outcome_state: OutcomeState | None = None
    classification_source: Literal["USER", "LEARNED", "RULE", "MODEL", "IMPORT"]
    confidence_bps: int
    review_status: Literal["UNREVIEWED", "NEEDS_REVIEW", "CONFIRMED"]
    feedback_recorded: int = 0
    updated_at: str


class FinancePurchaseReviewItemResponse(BaseModel):
    line_id: str
    purchase_id: str
    space_id: str
    purchased_on: date
    merchant: str
    source_description: str
    amount_minor: int
    currency: str
    confidence_bps: int
    uncertain_fields: list[str]
    evidence_handle: str
    deep_link: str
    source_id: str
    match_status: Literal["MATCHED", "PARTIAL", "UNMATCHED"]
    receipt_file_id: str | None = None


class FinanceAnalysisFilters(BaseModel):
    model_config = ConfigDict(extra="forbid")

    account_ids: list[str] = Field(default_factory=list, max_length=100)
    merchants: list[str] = Field(default_factory=list, max_length=100)
    categories: list[str] = Field(default_factory=list, max_length=100)
    transaction_types: list[str] = Field(default_factory=list, max_length=20)
    line_kinds: list[Literal["product", "service", "delivery", "fee", "tax", "unknown"]] = Field(default_factory=list)
    normalized_items: list[str] = Field(default_factory=list, max_length=100)
    purposes: list[str] = Field(default_factory=list, max_length=100)
    beneficiaries: list[str] = Field(default_factory=list, max_length=100)
    plannedness: list[Plannedness] = Field(default_factory=list)
    utilities: list[Utility] = Field(default_factory=list)
    decision_qualities: list[DecisionQuality] = Field(default_factory=list)
    value_for_money: list[ValueForMoney] = Field(default_factory=list)
    outcomes: list[OutcomeState] = Field(default_factory=list)
    itemisation: list[Literal["ITEMISED", "UNITEMISED"]] = Field(default_factory=list)


class FinanceAnalysisRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    space_id: str = Field(min_length=1, max_length=100)
    scope: Literal["mine", "household"] | None = None
    basis: Literal["TRANSACTIONS", "PURCHASE_LINES", "RECONCILED_PURCHASE_LINES"]
    start_date: date
    end_date: date
    currency: str
    grouping: Literal[
        "TOTAL", "DAY", "WEEK", "MONTH", "ACCOUNT", "MERCHANT", "CATEGORY",
        "LINE_KIND", "ITEM", "PURPOSE", "RECIPIENT", "PLANNEDNESS", "UTILITY",
        "VALUE_FOR_MONEY", "DECISION_QUALITY", "OUTCOME", "ITEMISATION",
    ] = "TOTAL"
    measure: Literal[
        "SPEND", "INCOME", "COUNT", "MEAN_SPEND", "MEDIAN_SPEND", "MIN_SPEND",
        "MAX_SPEND", "SHARE_OF_SPEND", "MEAN_UNIT_PRICE",
    ] = "SPEND"
    comparison: Literal["NONE", "PREVIOUS_PERIOD", "SAME_PERIOD_LAST_YEAR"] = "NONE"
    pending_policy: Literal["EXCLUDE", "INCLUDE"] = "EXCLUDE"
    refund_policy: Literal["NET", "EXCLUDE"] = "NET"
    transfer_policy: Literal["EXCLUDE", "INCLUDE"] = "EXCLUDE"
    filters: FinanceAnalysisFilters = Field(default_factory=FinanceAnalysisFilters)
    save_as: str | None = Field(default=None, min_length=1, max_length=120)

    @model_validator(mode="after")
    def validate_request(self):
        if self.end_date < self.start_date:
            raise ValueError("end_date must not precede start_date")
        if (self.end_date - self.start_date).days > 3_660:
            raise ValueError("Analysis date span cannot exceed ten years")
        self.currency = normalise_currency(self.currency)
        if self.basis != "TRANSACTIONS" and self.filters.account_ids:
            raise ValueError("account_ids can only filter transaction analysis")
        purchase_groupings = {
            "LINE_KIND", "ITEM", "PURPOSE", "RECIPIENT", "PLANNEDNESS", "UTILITY",
            "VALUE_FOR_MONEY", "DECISION_QUALITY", "OUTCOME", "ITEMISATION",
        }
        if self.basis == "TRANSACTIONS" and self.grouping in purchase_groupings:
            raise ValueError("This grouping requires a purchase-line basis")
        if self.basis != "TRANSACTIONS" and self.grouping == "ACCOUNT":
            raise ValueError("ACCOUNT grouping requires a transaction basis")
        if self.basis == "TRANSACTIONS" and any(
            (
                self.filters.line_kinds,
                self.filters.normalized_items,
                self.filters.purposes,
                self.filters.beneficiaries,
                self.filters.plannedness,
                self.filters.utilities,
                self.filters.decision_qualities,
                self.filters.value_for_money,
                self.filters.outcomes,
                self.filters.itemisation,
            )
        ):
            raise ValueError("purchase-line filters require a purchase-line basis")
        if self.measure == "MEAN_UNIT_PRICE" and self.basis == "TRANSACTIONS":
            raise ValueError("MEAN_UNIT_PRICE requires a purchase-line basis")
        if self.measure == "INCOME" and self.basis != "TRANSACTIONS":
            raise ValueError("INCOME requires a transaction basis")
        return self


class FinanceExactValue(BaseModel):
    numerator: int
    denominator: int


class FinanceAnalysisEvidenceResponse(BaseModel):
    handle: str
    kind: Literal["transaction", "purchase-line"]
    record_id: str
    deep_link: str


class FinanceAnalysisGroupResponse(BaseModel):
    key: str
    value: FinanceExactValue
    record_count: int
    evidence_handles: list[str]


class FinanceAnalysisCoverageResponse(BaseModel):
    eligible_minor: int
    itemised_minor: int
    coverage_bps: int


class FinanceSavedAnalysisViewResponse(BaseModel):
    id: str
    space_id: str
    name: str
    request: FinanceAnalysisRequest
    deep_link: str
    created_at: str
    updated_at: str


class FinanceAnalysisResponse(BaseModel):
    basis: Literal["TRANSACTIONS", "PURCHASE_LINES", "RECONCILED_PURCHASE_LINES"]
    currency: str
    total: FinanceExactValue
    groups: list[FinanceAnalysisGroupResponse]
    comparison_groups: list[FinanceAnalysisGroupResponse] = Field(default_factory=list)
    comparison_total: FinanceExactValue | None = None
    comparison_start_date: date | None = None
    comparison_end_date: date | None = None
    data_through: date | None = None
    itemisation_coverage: FinanceAnalysisCoverageResponse | None = None
    evidence: list[FinanceAnalysisEvidenceResponse]
    saved_view: FinanceSavedAnalysisViewResponse | None = None


class FinanceEvidenceHandleResponse(BaseModel):
    handle: str
    kind: Literal["transaction", "purchase-line"]
    record_id: str
    space_id: str
    deep_link: str
    source_evidence_id: str
    source_description: str
    amount_minor: int
    currency: str
    occurred_on: date
    source_kind: str | None = None
    line_kind: str | None = None
