"""Typed contracts for owner-private Strava activity import."""

from datetime import datetime
from typing import Literal

from pydantic import Field

from app.models.fitness import FitnessModel


class StravaOAuthStartRequest(FitnessModel):
    return_surface: Literal["app", "web"] = "web"


class StravaOAuthStartResponse(FitnessModel):
    authorization_url: str
    expires_at: datetime


class StravaActivitySummary(FitnessModel):
    id: str
    title: str
    sport_key: str
    started_at_utc: datetime
    duration_s: float | None = None
    distance_m: float | None = None


class StravaConnectionStatusResponse(FitnessModel):
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
    athlete_name: str | None = None
    last_sync_at: datetime | None = None
    data_through_at: datetime | None = None
    imported_activity_count: int = Field(default=0, ge=0)
    last_error_code: str | None = None


class StravaSyncResponse(FitnessModel):
    imported_count: int = Field(ge=0)
    updated_count: int = Field(ge=0)
    unchanged_count: int = Field(ge=0)
    latest_activity: StravaActivitySummary | None = None
    status: StravaConnectionStatusResponse


class StravaDisconnectResponse(FitnessModel):
    status: Literal["disconnected"]
    retained_activity_count: int = Field(ge=0)
