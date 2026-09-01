"""Typed contracts for owner-bound Withings import and measurement history."""

from datetime import datetime
from typing import Literal

from pydantic import Field

from app.models.fitness import FitnessModel


class WithingsConnectionStartRequest(FitnessModel):
    return_surface: Literal["app", "web"] = "app"


class WithingsConnectionStartResponse(FitnessModel):
    authorization_url: str
    expires_at: datetime


class WithingsConnectionStatusResponse(FitnessModel):
    configured: bool
    connected: bool
    status: Literal[
        "not_configured",
        "not_connected",
        "connected",
        "reauth_required",
        "provider_down",
        "disconnected",
    ]
    last_sync_at: datetime | None = None
    data_through_at: datetime | None = None
    last_error_code: str | None = None
    webhook_status: Literal["pending", "active", "error", "disabled"] | None = None
    subscribed_categories: list[int] = Field(default_factory=list)
    imported_measurement_count: int = 0


class WithingsSyncResponse(FitnessModel):
    status: Literal["synced"]
    imported: int
    updated: int
    unchanged: int
    ignored: int
    data_through_at: datetime | None = None


class WithingsDisconnectResponse(FitnessModel):
    status: Literal["disconnected"]
    retained_measurement_count: int


class MeasurementHistoryPoint(FitnessModel):
    id: str
    measured_at_utc: datetime
    raw_value: float
    trend_value: float
    source_label: str | None = None


class MeasurementHistorySeries(FitnessModel):
    key: str
    label: str
    unit: str
    points: list[MeasurementHistoryPoint]


class MeasurementHistoryResponse(FitnessModel):
    metric: Literal["weight", "body_fat", "blood_pressure"]
    title: str
    unit: str
    smoothing_method: Literal["time_weighted_exponential"]
    smoothing_half_life_days: float
    series: list[MeasurementHistorySeries]
    sample_count: int
    last_updated_at: datetime | None = None
