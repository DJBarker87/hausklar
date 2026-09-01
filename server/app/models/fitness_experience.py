"""Compact consumer contracts for the owner-private Fitness experience."""

from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


FitnessDestination = Literal["overview", "log", "plan", "progress", "coach"]
FitnessOutcome = Literal[
    "Feel fitter",
    "Build strength",
    "Run further",
    "Improve energy",
    "Support my weight",
    "Move consistently",
]
FitnessExperienceActionKind = Literal[
    "resume_activity",
    "start_strength",
    "start_session",
    "open_session",
    "move_session",
    "log_food",
    "record_readiness",
    "open_recovery",
    "open_body_issue",
    "open_coach",
    "open_overview",
    "create_session",
]


class FitnessExperienceModel(BaseModel):
    """Strict base so internal analysis cannot leak into everyday payloads."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class FitnessExperienceAction(FitnessExperienceModel):
    kind: FitnessExperienceActionKind
    label: str = Field(min_length=1, max_length=80)
    destination: FitnessDestination
    target_id: str | None = Field(default=None, min_length=1, max_length=160)


class FitnessExperienceSession(FitnessExperienceModel):
    id: str = Field(min_length=1, max_length=160)
    kind: Literal["planned_session", "active_activity"]
    title: str = Field(min_length=1, max_length=200)
    sport_key: str = Field(min_length=1, max_length=80)
    status: Literal["accepted", "scheduled", "in_progress"]
    starts_at: datetime | None = None
    scheduled_date: date | None = None
    duration_minutes: int | None = Field(default=None, ge=0)
    movable: bool = False


class FitnessCoachNudge(FitnessExperienceModel):
    title: str = Field(min_length=1, max_length=200)
    message: str = Field(min_length=1, max_length=600)
    action: FitnessExperienceAction


class FitnessSafetyAdjustment(FitnessExperienceModel):
    title: str = Field(min_length=1, max_length=200)
    message: str = Field(min_length=1, max_length=600)
    action: FitnessExperienceAction


class FitnessOverviewFact(FitnessExperienceModel):
    """One quiet fact selected for the adult's stated outcome."""

    outcome: FitnessOutcome
    label: str = Field(min_length=1, max_length=80)
    value: str = Field(min_length=1, max_length=120)
    detail: str | None = Field(default=None, min_length=1, max_length=180)
    destination: FitnessDestination


class FitnessOverviewResponse(FitnessExperienceModel):
    date: date
    focus: FitnessOverviewFact
    session: FitnessExperienceSession | None = None
    primary_action: FitnessExperienceAction | None = None
    secondary_action: FitnessExperienceAction | None = None
    quick_actions: list[FitnessExperienceAction] = Field(
        default_factory=list,
        max_length=3,
    )
    coach_nudge: FitnessCoachNudge | None = None
    safety_adjustment: FitnessSafetyAdjustment | None = None


class FitnessTodayNutrition(FitnessExperienceModel):
    """A deliberately small running total, shown only after an adult opts in."""

    calories_kcal: float = Field(ge=0)
    calorie_target_kcal: float | None = Field(default=None, ge=0)
    protein_g: float = Field(ge=0)
    protein_target_g: float | None = Field(default=None, ge=0)
    entry_count: int = Field(ge=0)
    calories_complete: bool
    protein_complete: bool


class FitnessTodayCardResponse(FitnessExperienceModel):
    """Minimal, owner-private Fitness contribution to HausKlar Today."""

    date: date
    has_completed_activity_today: bool = False
    session: FitnessExperienceSession | None = None
    primary_action: FitnessExperienceAction | None = None
    secondary_action: FitnessExperienceAction | None = None
    nutrition: FitnessTodayNutrition | None = None
