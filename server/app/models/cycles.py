from datetime import date
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class FitnessCycleModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid", str_strip_whitespace=True, allow_inf_nan=False
    )


class FitnessCycleSettingsPayload(FitnessCycleModel):
    id: UUID | None = None
    cycle_length_days: int = Field(default=28, ge=10, le=365)
    show_period_starts: bool = True
    show_predicted_period: bool = True
    show_estimated_ovulation: bool = True
    share_period_starts_with_adults: bool = False
    share_predicted_period_with_adults: bool = False
    share_estimated_ovulation_with_adults: bool = False
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class FitnessPeriodStartPayload(FitnessCycleModel):
    id: UUID | None = None
    started_on: date
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class FitnessPeriodStartResponse(FitnessCycleModel):
    id: str
    started_on: date
    revision: int
    created_at: str
    updated_at: str


class FitnessCycleProfileResponse(FitnessCycleModel):
    id: str
    owner_user_id: str
    owner_name: str
    is_owner: bool
    cycle_length_days: int
    show_period_starts: bool
    show_predicted_period: bool
    show_estimated_ovulation: bool
    share_period_starts_with_adults: bool
    share_predicted_period_with_adults: bool
    share_estimated_ovulation_with_adults: bool
    latest_period_start: date | None = None
    predicted_next_period: date | None = None
    estimated_ovulation: date | None = None
    period_starts: list[FitnessPeriodStartResponse] = Field(default_factory=list)
    revision: int
    created_at: str
    updated_at: str


class CycleSettingsUpdate(BaseModel):
    id: UUID | None = None
    cycle_length_days: int = Field(ge=10, le=365)
    share_with_adults: bool = False
    show_period_starts: bool = True
    show_predicted_period: bool = True
    show_estimated_ovulation: bool = True


class PeriodStartCreate(BaseModel):
    id: UUID | None = None
    started_on: date


class PeriodStartResponse(BaseModel):
    id: str
    started_on: date
    created_at: str
    updated_at: str


class CycleProfileResponse(BaseModel):
    id: str
    owner_user_id: str
    owner_name: str
    is_owner: bool
    cycle_length_days: int
    share_with_adults: bool
    show_period_starts: bool
    show_predicted_period: bool
    show_estimated_ovulation: bool
    latest_period_start: date | None = None
    predicted_next_period: date | None = None
    estimated_ovulation: date | None = None
    period_starts: list[PeriodStartResponse] = Field(default_factory=list)
    created_at: str
    updated_at: str


class CycleSettingsResponse(CycleProfileResponse):
    pass
