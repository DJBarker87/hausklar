"""Typed contracts for owner-bound Intervals.icu delivery and activity import."""

from datetime import datetime
from typing import Literal

from pydantic import Field, SecretStr

from app.models.fitness import FitnessModel


IntervalsConnectionState = Literal[
    "not_configured",
    "not_connected",
    "connected",
    "reauth_required",
    "provider_down",
    "disconnected",
]
IntervalsDeliveryState = Literal[
    "not_sent",
    "pending",
    "sent",
    "cancelled",
    "error",
]
IntervalsDeliveryOperation = Literal[
    "none",
    "created",
    "updated",
    "retried",
    "unchanged",
    "cancelled",
]


class IntervalsConnectionStatusResponse(FitnessModel):
    configured: bool
    oauth_available: bool
    personal_api_key_available: bool
    oauth_scopes: list[
        Literal["CALENDAR:WRITE", "SETTINGS:READ", "ACTIVITY:READ"]
    ] = Field(
        default_factory=lambda: [
            "CALENDAR:WRITE",
            "SETTINGS:READ",
            "ACTIVITY:READ",
        ]
    )
    connected: bool
    status: IntervalsConnectionState
    auth_method: Literal["oauth", "personal_api_key"] | None = None
    athlete_id: str | None = None
    athlete_name: str | None = None
    garmin_training_connected: bool | None = None
    last_tested_at: datetime | None = None
    last_error_code: str | None = None
    activity_read_authorized: bool = False
    activity_import_enabled: bool = False
    activity_import_since: datetime | None = None
    last_activity_import_at: datetime | None = None
    last_activity_import_error_code: str | None = None
    activity_imported_count: int = Field(default=0, ge=0)
    activity_import_pending_count: int = Field(default=0, ge=0)
    activity_import_error_count: int = Field(default=0, ge=0)


class IntervalsApiKeyConnectRequest(FitnessModel):
    api_key: SecretStr = Field(min_length=8, max_length=2_000)


class IntervalsOAuthStartRequest(FitnessModel):
    return_surface: Literal["app", "web"] = "app"


class IntervalsOAuthStartResponse(FitnessModel):
    authorization_url: str
    expires_at: datetime


class IntervalsDisconnectResponse(FitnessModel):
    status: Literal["disconnected"]
    retained_publication_count: int = Field(ge=0)


class IntervalsActivityImportSettingsRequest(FitnessModel):
    enabled: bool
    lookback_days: int = Field(default=30, ge=1, le=365)


class IntervalsActivityImportSyncResponse(FitnessModel):
    discovered_count: int = Field(ge=0)
    queued_count: int = Field(ge=0)
    existing_count: int = Field(ge=0)
    skipped_count: int = Field(ge=0)
    status: IntervalsConnectionStatusResponse


class IntervalsDeliveryResponse(FitnessModel):
    planned_session_id: str
    state: IntervalsDeliveryState
    operation: IntervalsDeliveryOperation = "none"
    external_id: str | None = None
    provider_event_id: str | None = None
    sent_at: datetime | None = None
    last_error_code: str | None = None
    push_errors: list[str] = Field(default_factory=list)
