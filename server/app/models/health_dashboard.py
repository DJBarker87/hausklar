"""Pydantic models for the health dashboard endpoints."""

from pydantic import BaseModel


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------


class HealthSummary(BaseModel):
    latest_weight: float | None = None
    latest_weight_date: str | None = None
    weight_trend_kg: float | None = None  # change over last 30 days (positive = gained)
    exercise_count_this_week: int = 0
    average_sleep_hours_this_week: float | None = None
    total_active_minutes_this_week: float = 0


# ---------------------------------------------------------------------------
# Weight
# ---------------------------------------------------------------------------


class WeightPoint(BaseModel):
    date: str
    value: float
    unit: str = "kg"


class WeightHistory(BaseModel):
    data: list[WeightPoint]
    current: float | None = None
    min: float | None = None
    max: float | None = None
    average: float | None = None
    trend: str | None = None  # "up", "down", "stable", or None


# ---------------------------------------------------------------------------
# Exercise
# ---------------------------------------------------------------------------


class ExercisePoint(BaseModel):
    date: str
    data_type: str
    value: float
    unit: str
    metadata: dict | None = None


class WeeklyExerciseAggregate(BaseModel):
    week_start: str
    total_distance_km: float = 0
    total_duration_seconds: float = 0
    count: int = 0


class ExerciseHistory(BaseModel):
    data: list[ExercisePoint]
    weekly: list[WeeklyExerciseAggregate]


# ---------------------------------------------------------------------------
# Sleep
# ---------------------------------------------------------------------------


class SleepPoint(BaseModel):
    date: str
    value: float
    unit: str = "hours"


class SleepHistory(BaseModel):
    data: list[SleepPoint]
    average: float | None = None
    min: float | None = None
    max: float | None = None


# ---------------------------------------------------------------------------
# Personal records
# ---------------------------------------------------------------------------


class PersonalRecord(BaseModel):
    label: str
    value: float | None = None
    unit: str | None = None
    date: str | None = None
    metadata: dict | None = None


class PersonalRecords(BaseModel):
    fastest_5k: PersonalRecord | None = None
    longest_run: PersonalRecord | None = None
    heaviest_weight: PersonalRecord | None = None
    most_active_week: PersonalRecord | None = None
