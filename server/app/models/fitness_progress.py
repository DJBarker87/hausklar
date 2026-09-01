"""Bounded, owner-private chart contracts for everyday Fitness progress."""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class FitnessProgressModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class FitnessWeightProgressPoint(FitnessProgressModel):
    measurement_id: str = Field(min_length=1, max_length=160)
    measured_at_utc: datetime
    weight_kg: float = Field(gt=0, lt=1_000)


class FitnessRunningProgressPoint(FitnessProgressModel):
    activity_id: str = Field(min_length=1, max_length=160)
    started_at_utc: datetime
    duration_s: float = Field(gt=0)
    source: Literal["best_effort", "average_pace_estimate"]


class FitnessRunningProgressSeries(FitnessProgressModel):
    key: Literal["5k", "10k"]
    label: Literal["5K", "10K"]
    distance_m: Literal[5000, 10000]
    points: list[FitnessRunningProgressPoint] = Field(
        default_factory=list,
        max_length=12,
    )


class FitnessStrengthProgressPoint(FitnessProgressModel):
    activity_id: str = Field(min_length=1, max_length=160)
    performed_at_utc: datetime
    load_kg: float = Field(ge=0, lt=10_000)
    repetitions: int | None = Field(default=None, ge=1, le=10_000)
    working_set_count: int = Field(ge=1, le=1_000)


class FitnessStrengthProgressSeries(FitnessProgressModel):
    key: Literal["squat", "chest_press", "overhead_press"]
    label: Literal["Squat", "Chest press", "Overhead press"]
    exercise_id: str | None = Field(default=None, min_length=1, max_length=160)
    exercise_name: str | None = Field(default=None, min_length=1, max_length=200)
    setup_id: str | None = Field(default=None, min_length=1, max_length=160)
    setup_name: str | None = Field(default=None, min_length=1, max_length=200)
    points: list[FitnessStrengthProgressPoint] = Field(
        default_factory=list,
        max_length=12,
    )


class FitnessProgressChartsResponse(FitnessProgressModel):
    weight: list[FitnessWeightProgressPoint] = Field(
        default_factory=list,
        max_length=24,
    )
    running: list[FitnessRunningProgressSeries] = Field(
        default_factory=list,
        min_length=2,
        max_length=2,
    )
    strength: list[FitnessStrengthProgressSeries] = Field(
        default_factory=list,
        min_length=3,
        max_length=3,
    )
