"""Human goal choices for Plan surfaces; internal measures stay server-side."""

from datetime import date
from typing import Literal
from uuid import UUID

from pydantic import Field, model_validator

from app.models.fitness import FitnessModel


GoalTemplateId = Literal[
    "run-faster-5k",
    "run-consistently",
    "move-consistently",
    "run-weekly-distance",
    "strength-consistency",
    "energy-and-wellbeing",
    "body-weight-support",
]
GoalInputKind = Literal[
    "duration_minutes_seconds",
    "sessions_per_week",
    "kilometres_per_week",
    "active_days_per_week",
    "target_weight_kg",
]

GOAL_TEMPLATE_LIMITS: dict[str, tuple[float, float, bool]] = {
    "run-faster-5k": (12 * 60, 120 * 60, True),
    "run-consistently": (1, 7, True),
    "move-consistently": (1, 14, True),
    "run-weekly-distance": (0.5, 300, False),
    "strength-consistency": (1, 7, True),
    "energy-and-wellbeing": (1, 7, True),
    "body-weight-support": (30, 300, False),
}


class GoalTemplateResponse(FitnessModel):
    id: GoalTemplateId
    title: str
    description: str
    target_prompt: str
    input_kind: GoalInputKind
    unit_label: str
    minimum_value: float
    maximum_value: float
    step: float
    suggested_value: float
    supports_target_date: bool = True


class GoalFromTemplateRequest(FitnessModel):
    id: UUID
    template_id: GoalTemplateId
    target_value: float = Field(gt=0, le=10_000)
    starts_on: date
    target_date: date | None = None
    title: str | None = Field(default=None, min_length=1, max_length=160)
    priority: int = Field(default=50, ge=0, le=100)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def valid_template_value(self):
        minimum, maximum, whole_number = GOAL_TEMPLATE_LIMITS[self.template_id]
        if self.target_value < minimum or self.target_value > maximum:
            raise ValueError(
                f"target_value must be between {minimum:g} and {maximum:g} for this goal"
            )
        if whole_number and not float(self.target_value).is_integer():
            raise ValueError("target_value must be a whole number for this goal")
        if self.target_date is not None and self.target_date < self.starts_on:
            raise ValueError("target_date cannot be before starts_on")
        return self


class GoalFromTemplateResponse(FitnessModel):
    goal_id: UUID
    template_id: GoalTemplateId
    title: str
    target_text: str
    starts_on: date
    target_date: date | None = None
    priority: int
    status: Literal["active"] = "active"
