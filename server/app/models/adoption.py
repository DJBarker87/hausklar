"""Public contracts for the private, content-free usage-history controls."""

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


class UsageHistoryPreferenceUpdate(BaseModel):
    enabled: bool


class UsageHistoryPreferenceResponse(BaseModel):
    enabled: bool
    retention_days: int = 28


class UsageModuleSummary(BaseModel):
    module: str
    actions: int = Field(ge=0)
    active_days: int = Field(ge=0)


class UsageScreenSummary(BaseModel):
    module: str
    surface: str
    views: int = Field(ge=0)
    active_days: int = Field(ge=0)


class UsageControlSummary(BaseModel):
    module: str
    action: str
    surface: str
    presses: int = Field(ge=0)
    active_days: int = Field(ge=0)


class UsageWorkflowSummary(BaseModel):
    module: str
    workflow: str
    action: str
    starts: int = Field(ge=0)
    completions: int = Field(ge=0)
    failures: int = Field(ge=0)
    abandonments: int = Field(ge=0)
    queued_completions: int = Field(ge=0)
    average_interactions: float | None = Field(default=None, ge=0, le=100)


class UsageHistorySummary(BaseModel):
    enabled: bool
    period_days: int = 28
    meaningful_actions: int = Field(ge=0)
    failed_actions: int = Field(ge=0)
    active_days: int = Field(ge=0)
    use_signal: Literal["not_started", "started", "returning"]
    repeat_modules: list[UsageModuleSummary]
    both_adults_contributed: bool
    shared_family_actions: int = Field(ge=0)
    screen_views: list[UsageScreenSummary] = Field(default_factory=list)
    control_uses: list[UsageControlSummary] = Field(default_factory=list)
    workflows: list[UsageWorkflowSummary] = Field(default_factory=list)
    last_action_at: str | None = None


class UsageInteractionEvent(BaseModel):
    id: UUID
    event_kind: Literal["screen_view", "control", "workflow"]
    module: str = Field(pattern=r"^[a-z][a-z0-9_]{0,39}$")
    action: str = Field(pattern=r"^[a-z][a-z0-9_]{0,63}$")
    outcome: Literal[
        "viewed", "tapped", "started", "completed", "failed", "abandoned", "cancelled"
    ]
    surface: str = Field(pattern=r"^[a-z][a-z0-9_]{0,63}$")
    workflow: str | None = Field(default=None, pattern=r"^[a-z][a-z0-9_]{0,63}$")
    workflow_run_id: UUID | None = None
    duration_bucket: Literal[
        "under_10s", "under_1m", "under_5m", "over_5m", "unknown"
    ] = "unknown"
    interaction_count: int | None = Field(default=None, ge=0, le=100)
    connectivity: Literal["online", "offline", "queued", "unknown"] = "unknown"
    failure_class: Literal[
        "validation",
        "network",
        "authorization",
        "conflict",
        "provider",
        "server",
        "cancelled",
        "unknown",
    ] | None = None
    occurred_at: datetime


class UsageInteractionBatch(BaseModel):
    events: list[UsageInteractionEvent] = Field(min_length=1, max_length=50)


class UsageHistoryEventExport(BaseModel):
    module: str
    action: str
    outcome: str
    entry_source: str
    effort: str
    app_version: str
    event_kind: str
    surface: str
    workflow: str | None = None
    workflow_run_id: str | None = None
    duration_bucket: str
    interaction_count: int | None = None
    connectivity: str
    failure_class: str | None = None
    recorded_at: str


class UsageHistoryExport(BaseModel):
    generated_at: str
    retention_days: int = 28
    events: list[UsageHistoryEventExport]


class UsageHistoryClearResponse(BaseModel):
    cleared: int = Field(ge=0)
