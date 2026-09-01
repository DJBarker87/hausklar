"""Typed contract for the deterministic owner-private Fitness next action."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


NextActionUrgency = Literal["routine", "attention", "urgent"]
NextActionKind = Literal[
    "open_body_issue",
    "record_readiness",
    "open_recovery",
    "open_coach",
    "open_planned_session",
    "open_today",
]


class NextActionModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class FitnessNextActionEvidence(NextActionModel):
    id: str = Field(min_length=1, max_length=160)
    kind: str = Field(min_length=1, max_length=80)
    label: str = Field(min_length=1, max_length=200)
    summary: str = Field(min_length=1, max_length=1_000)


class FitnessNextActionCommand(NextActionModel):
    kind: NextActionKind
    target: str = Field(min_length=1, max_length=500)
    label: str = Field(min_length=1, max_length=160)


class FitnessNextAction(NextActionModel):
    title: str = Field(min_length=1, max_length=200)
    body: str = Field(min_length=1, max_length=2_000)
    urgency: NextActionUrgency
    evidence: list[FitnessNextActionEvidence] = Field(default_factory=list, max_length=8)
    action: FitnessNextActionCommand
    secondary_action: FitnessNextActionCommand | None = None
    expires_at: datetime
    source: str = Field(min_length=1, max_length=500)
