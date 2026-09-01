"""Strict contracts for deterministic Finance plans and coaching loops."""

from datetime import date, time
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator, model_validator

from app.services.finance.money import normalise_currency


PlanStrategy = Literal["MINIMAL_DISRUPTION", "TARGET_DATE", "AGGRESSIVE", "RESILIENT"]
PlanEffortLevel = Literal["EASY", "MEDIUM", "HARD"]
PlanAnswerBasis = Literal["EXACT", "ESTIMATED", "BOUNDED"]


class FinancePlanGenerate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    goal_id: str = Field(min_length=1, max_length=100)
    source_plan_id: str | None = Field(default=None, max_length=100)
    recovery_mode: Literal[
        "CURRENT_CYCLE",
        "SPREAD_CYCLES",
        "USE_UNDERSPEND",
        "DEFER_PURCHASE",
        "ACCEPT_NEW_DATE",
    ] | None = None

    @model_validator(mode="after")
    def validate_recovery(self):
        if self.recovery_mode is not None and self.source_plan_id is None:
            raise ValueError("Recovery generation requires source_plan_id")
        return self


class FinancePlanCategoryResponse(BaseModel):
    category_id: str
    name: str
    baseline_minor: int
    floor_minor: int
    protected: bool
    weight: int
    reduction_minor: int
    budget_minor: int


class FinancePlanResponse(BaseModel):
    id: str
    proposal_group_id: str
    space_id: str
    version: int
    strategy: PlanStrategy
    effort_level: PlanEffortLevel
    answer_basis: PlanAnswerBasis
    confidence_bps: int = Field(ge=0, le=10_000)
    currency: str
    goal_id: str
    source_plan_id: str | None = None
    recovery_mode: str | None = None
    target_date: date
    supported_goal_date: date | None = None
    forecast_coverage_end: date | None = None
    required_monthly_minor: int = Field(ge=0)
    planned_monthly_saving_minor: int = Field(ge=0)
    projected_amount_at_target_minor: int = Field(ge=0)
    goal_shortfall_at_target_minor: int = Field(ge=0)
    monthly_change_minor: int
    household_buffer_minor: int
    required_reduction_minor: int
    achieved_reduction_minor: int
    shortfall_minor: int
    feasible: bool
    protected_category_count: int
    status: Literal["PROPOSED", "ACTIVE", "SUPERSEDED", "REJECTED"]
    rationale: str
    assumptions: list[str]
    categories: list[FinancePlanCategoryResponse]
    activated_at: str | None = None
    created_at: str


class FinancePlanSetResponse(BaseModel):
    proposal_group_id: str
    version: int
    recommendation_strategy: PlanStrategy
    recommendation_effort_level: PlanEffortLevel = "MEDIUM"
    plans: list[FinancePlanResponse]


class FinancePaydayActionCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    plan_id: str = Field(min_length=1, max_length=100)
    source_account_id: str = Field(min_length=1, max_length=100)
    destination_account_id: str = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def different_accounts(self):
        if self.source_account_id == self.destination_account_id:
            raise ValueError("Payday transfer accounts must differ")
        return self


class FinancePaydayActionResolve(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["DONE", "SKIPPED", "CHANGED"]
    changed_amount_minor: StrictInt | None = Field(default=None, gt=0)
    note: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def validate_change(self):
        if (self.status == "CHANGED") != (self.changed_amount_minor is not None):
            raise ValueError("Changed actions require changed_amount_minor only")
        if self.note:
            self.note = self.note.strip()
        return self


class FinancePaydayActionResponse(BaseModel):
    id: str
    space_id: str
    plan_id: str
    due_date: date
    source_account_id: str
    destination_account_id: str
    amount_minor: int
    safe_after_transfer_minor: int
    answer_mode: Literal["CURRENT_EXACT", "DATED_EXACT"]
    data_through_at: str | None = None
    currency: str
    date_tolerance_days: int
    grace_days: int
    status: Literal[
        "PENDING", "MATCHED", "DONE", "SKIPPED", "CHANGED", "RECALCULATED", "EXPIRED"
    ]
    matched_relation_id: str | None = None
    matched_at: str | None = None
    changed_amount_minor: int | None = None
    recalculated_action_id: str | None = None
    resolution_note: str | None = None
    updated_at: str


class FinanceHabitCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    finding_id: str | None = Field(default=None, max_length=100)
    slot: Literal["PRIMARY", "SECONDARY"]
    name: str = Field(min_length=1, max_length=200)
    trigger: str = Field(min_length=1, max_length=500)
    normalized_items: list[str] = Field(default_factory=list, max_length=50)
    purposes: list[str] = Field(default_factory=list, max_length=50)
    beneficiaries: list[str] = Field(default_factory=list, max_length=50)
    plannedness: list[
        Literal["planned", "routine", "replacement", "emergency", "impulse", "unknown"]
    ] = Field(default_factory=list, max_length=6)
    utilities: list[Literal["essential", "useful", "optional", "unclear"]] = Field(
        default_factory=list,
        max_length=4,
    )
    outcomes: list[
        Literal["valued", "neutral", "regretted", "returned", "unused", "unknown"]
    ] = Field(default_factory=list, max_length=6)
    minimum_line_minor: StrictInt = Field(default=0, ge=0)
    start_date: date
    review_date: date
    fallback: str = Field(min_length=1, max_length=1_000)

    @model_validator(mode="after")
    def validate_periods(self):
        if self.review_date < self.start_date:
            raise ValueError("Habit review date cannot precede its start")
        self.name = self.name.strip()
        self.trigger = self.trigger.strip()
        self.fallback = self.fallback.strip()
        return self


class FinanceHabitReview(BaseModel):
    model_config = ConfigDict(extra="forbid")

    decision: Literal["KEEP", "ADJUST", "STOP"]
    friction_rating: StrictInt = Field(ge=1, le=5)
    note: str | None = Field(default=None, max_length=1_000)


class FinanceHabitResponse(BaseModel):
    id: str
    space_id: str
    finding_id: str | None = None
    slot: Literal["PRIMARY", "SECONDARY"]
    name: str
    trigger: str
    filters: dict[str, object]
    baseline_start: date
    baseline_end: date
    baseline_minor: int
    start_date: date
    review_date: date
    expected_saving_low_minor: int
    expected_saving_high_minor: int
    actual_spend_minor: int
    realised_saving_minor: int
    displacement_minor: int
    friction_rating: int | None = None
    fallback: str
    currency: str
    status: Literal["PROPOSED", "ACTIVE", "PAUSED", "COMPLETED", "ABANDONED"]
    review_decision: Literal["KEEP", "ADJUST", "STOP"] | None = None
    evidence_refs: list[str]
    updated_at: str


class FinanceProposalLine(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=300)
    amount_minor: StrictInt = Field(ge=0)
    normalized_item: str | None = Field(default=None, max_length=200)
    purpose: str | None = Field(default=None, max_length=200)
    beneficiary: str | None = Field(default=None, max_length=120)
    replacement_for: str | None = Field(default=None, max_length=300)


class FinancePurchaseProposalCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reviewed: Literal[True]
    source_kind: Literal["TEXT", "URL_METADATA", "SCREENSHOT_METADATA", "QUOTE", "BASKET", "LINES"]
    source_text: str | None = Field(default=None, max_length=4_000)
    source_url: str | None = Field(default=None, max_length=2_000)
    source_metadata: dict[str, str | int | bool | None] = Field(default_factory=dict)
    name: str = Field(min_length=1, max_length=300)
    amount_low_minor: StrictInt = Field(ge=0)
    amount_high_minor: StrictInt = Field(ge=0)
    desired_date: date
    recurrence: Literal["ONE_OFF", "MONTHLY", "ANNUAL"] = "ONE_OFF"
    payment_account_id: str = Field(min_length=1, max_length=100)
    purpose: str | None = Field(default=None, max_length=200)
    beneficiary: str | None = Field(default=None, max_length=120)
    lines: list[FinanceProposalLine] = Field(default_factory=list, max_length=100)
    unitemised_remainder_minor: StrictInt = Field(default=0, ge=0)
    cheaper_alternative_minor: StrictInt | None = Field(default=None, ge=0)
    later_date: date | None = None
    uncertainties: list[str] = Field(default_factory=list, max_length=50)
    currency: str = "GBP"

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, value: str) -> str:
        return normalise_currency(value)

    @model_validator(mode="after")
    def validate_proposal(self):
        if self.amount_high_minor < self.amount_low_minor:
            raise ValueError("Proposal amount range is invalid")
        if self.cheaper_alternative_minor is not None and (
            self.cheaper_alternative_minor >= self.amount_high_minor
        ):
            raise ValueError("A cheaper alternative must actually cost less")
        if self.later_date is not None and self.later_date <= self.desired_date:
            raise ValueError("later_date must follow desired_date")
        if self.source_kind == "URL_METADATA" and not self.source_url:
            raise ValueError("URL metadata proposals require source_url")
        if self.source_url:
            parsed = urlsplit(self.source_url)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise ValueError("Proposal source_url must be an HTTP(S) reference")
        if self.source_kind == "TEXT" and not self.source_text:
            raise ValueError("Text proposals require source_text")
        if self.source_kind == "SCREENSHOT_METADATA" and not self.source_metadata:
            raise ValueError("Screenshot proposals require reviewed metadata")
        if self.source_kind == "QUOTE" and not (self.source_text or self.source_metadata):
            raise ValueError("Quote proposals require reviewed text or metadata")
        if len(self.source_metadata) > 30:
            raise ValueError("Proposal metadata is limited to 30 fields")
        for key, value in self.source_metadata.items():
            if not isinstance(key, str) or not key.strip() or len(key) > 80:
                raise ValueError("Proposal metadata keys must be 1 to 80 characters")
            if isinstance(value, str) and len(value) > 500:
                raise ValueError("Proposal metadata text is limited to 500 characters")
            if type(value) is int and abs(value) > 1_000_000_000_000_000:
                raise ValueError("Proposal metadata numbers are outside the supported range")
        evidenced_total = sum(line.amount_minor for line in self.lines)
        evidenced_total += self.unitemised_remainder_minor
        if self.source_kind in {"BASKET", "LINES"} and not self.lines:
            raise ValueError("Basket and line proposals require at least one line")
        if self.lines and not self.amount_low_minor <= evidenced_total <= self.amount_high_minor:
            raise ValueError(
                "Proposal lines and explicit remainder must reconcile to the amount range"
            )
        if (
            self.lines
            and self.amount_low_minor == self.amount_high_minor
            and evidenced_total != self.amount_high_minor
        ):
            raise ValueError("Proposal lines must reconcile exactly to an exact amount")
        self.name = self.name.strip()
        return self


class FinancePurchaseProposalResponse(BaseModel):
    id: str
    space_id: str
    source_kind: str
    name: str
    amount_low_minor: int
    amount_high_minor: int
    desired_date: date
    recurrence: str
    payment_account_id: str
    purpose: str | None = None
    beneficiary: str | None = None
    lines: list[dict[str, object]]
    cheaper_alternative_minor: int | None = None
    later_date: date | None = None
    uncertainties: list[str]
    currency: str
    status: Literal["CONFIRMED", "EVALUATED", "APPROVED", "DISMISSED"]
    approved_scenario: str | None = None
    created_at: str
    updated_at: str


class FinancePurchaseEvaluationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    forecast_id: str = Field(min_length=1, max_length=100)


class FinancePurchaseEvaluationResponse(BaseModel):
    id: str
    proposal_id: str
    forecast_id: str
    verdict: Literal["YES", "YES_IF", "NOT_YET", "NO_UNDER_CURRENT_PLAN"]
    rationale: str
    scenarios: list[dict[str, object]]
    historical_context: dict[str, object]
    evidence_refs: list[str]
    data_through_at: str | None = None
    created_at: str


class FinancePurchaseApprove(BaseModel):
    model_config = ConfigDict(extra="forbid")

    evaluation_id: str = Field(min_length=1, max_length=100)
    scenario: Literal["BUY_NOW", "BUY_LATER", "CHEAPER", "DO_NOTHING"]


class FinanceReportPreferenceUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    locale: Literal["en", "de"] = "en"
    daily_time: time = time(7, 0)
    enabled: bool = True
    notification_channel: Literal["IN_APP", "BROWSER"] = "IN_APP"
    notification_mode: Literal["ACTION_ONLY", "DAILY", "NEVER"] = "ACTION_ONLY"
    show_more_by_default: bool = False
    quiet_hours_start: time | None = None
    quiet_hours_end: time | None = None
    underfunded_commitment_threshold_minor: StrictInt = Field(default=5_000, ge=0)
    goal_movement_threshold_minor: StrictInt = Field(default=5_000, ge=0)
    missed_payday_alerts: bool = True
    selected_return_deadline_alerts: bool = True
    tone: Literal["GENTLE", "BALANCED", "BLUNT"] = "BALANCED"
    default_spend_account_id: str | None = Field(default=None, max_length=100)
    extra_cash_buffer_minor: StrictInt = Field(default=0, ge=0)
    writing_mode: Literal["LOCAL", "CLOUD_WITH_CONSENT"] = "LOCAL"
    allow_dated_estimates: bool = True

    @model_validator(mode="after")
    def validate_quiet_hours(self):
        if (self.quiet_hours_start is None) != (self.quiet_hours_end is None):
            raise ValueError("Quiet hours require both a start and end time")
        return self


class FinanceReportPreferenceResponse(BaseModel):
    id: str
    space_id: str
    member_user_id: str
    locale: Literal["en", "de"]
    daily_time: time
    enabled: bool
    notification_channel: Literal["IN_APP", "BROWSER"]
    notification_mode: Literal["ACTION_ONLY", "DAILY", "NEVER"]
    show_more_by_default: bool
    quiet_hours_start: time | None = None
    quiet_hours_end: time | None = None
    underfunded_commitment_threshold_minor: int
    goal_movement_threshold_minor: int
    missed_payday_alerts: bool
    selected_return_deadline_alerts: bool
    tone: Literal["GENTLE", "BALANCED", "BLUNT"]
    default_spend_account_id: str | None = None
    extra_cash_buffer_minor: int
    writing_mode: Literal["LOCAL", "CLOUD_WITH_CONSENT"]
    allow_dated_estimates: bool
    ordinary_purchase_alerts: Literal[False] = False
    group_related_alerts: Literal[True] = True
    updated_at: str


class FinanceCoachingReportResponse(BaseModel):
    id: str
    space_id: str
    member_user_id: str
    report_kind: Literal["DAILY", "DRIFT", "WEEKLY", "MONTHLY"]
    local_date: date
    household_timezone: str
    locale: Literal["en", "de"]
    currency: str
    input_digest: str
    data_through_at: str | None = None
    itemised_coverage_bps: int | None = None
    trajectory_status: Literal["ON_PLAN", "WATCH", "OFF_PLAN", "UNKNOWN"]
    expected_durable_saving_minor: int
    primary_action: dict[str, object] | None = None
    optional_observation: dict[str, object] | None = None
    summary: dict[str, object]
    explanation: str
    created_at: str
