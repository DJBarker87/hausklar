"""Compact human-facing Fitness weekly review contracts."""

from datetime import date
from typing import Literal
from uuid import UUID

from pydantic import Field

from app.models.fitness import FitnessModel


class WeeklyReviewTotals(FitnessModel):
    completed_sessions: int = Field(ge=0)
    active_days: int = Field(ge=0, le=7)
    duration_minutes: int | None = Field(default=None, ge=0)
    distance_km: float | None = Field(default=None, ge=0)
    strength_volume_kg: float | None = Field(default=None, ge=0)


class WeeklyReviewGoalProgress(FitnessModel):
    goal_id: UUID
    goal_name: str
    progress_text: str
    progress_percent: int | None = Field(default=None, ge=0, le=100)


class WeeklyReviewHighlight(FitnessModel):
    title: str
    detail: str


WeeklyReviewDestination = Literal[
    "today",
    "plan",
    "activities",
    "strength",
    "goals",
    "measurements",
]
WeeklyReviewActionKind = Literal[
    "plan_session",
    "log_activity",
    "start_strength",
    "choose_goal",
    "log_weight",
    "review_goal",
]


class WeeklyReviewOpportunity(FitnessModel):
    title: str
    detail: str
    destination: WeeklyReviewDestination
    action: WeeklyReviewActionKind
    action_label: str


class WeeklyReviewResponse(FitnessModel):
    week_start: date
    week_end: date
    totals: WeeklyReviewTotals
    goal: WeeklyReviewGoalProgress | None = None
    highlight: WeeklyReviewHighlight
    opportunity: WeeklyReviewOpportunity
