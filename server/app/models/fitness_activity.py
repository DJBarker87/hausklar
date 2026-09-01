"""Typed API contracts for Fitness activities, gear, analysis and worker jobs."""

from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class ActivityModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid", str_strip_whitespace=True, allow_inf_nan=False
    )


class GearPayload(ActivityModel):
    id: UUID | None = None
    gear_type_key: str = Field(min_length=1, max_length=80)
    name: str = Field(min_length=1, max_length=160)
    brand: str | None = Field(default=None, max_length=120)
    model: str | None = Field(default=None, max_length=120)
    variant: str | None = Field(default=None, max_length=120)
    started_at: date | None = None
    retired_at: date | None = None
    initial_usage_distance_m: float | None = Field(default=None, ge=0)
    default_for_sport_key: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=4_000)
    active: bool = True
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def valid_dates(self):
        if self.started_at and self.retired_at and self.retired_at < self.started_at:
            raise ValueError("retired_at cannot be before started_at")
        return self


class GearPatch(ActivityModel):
    gear_type_key: str | None = Field(default=None, min_length=1, max_length=80)
    name: str | None = Field(default=None, min_length=1, max_length=160)
    brand: str | None = Field(default=None, max_length=120)
    model: str | None = Field(default=None, max_length=120)
    variant: str | None = Field(default=None, max_length=120)
    started_at: date | None = None
    retired_at: date | None = None
    initial_usage_distance_m: float | None = Field(default=None, ge=0)
    default_for_sport_key: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=4_000)
    active: bool | None = None


class GearDefaultPayload(ActivityModel):
    sport_key: str = Field(min_length=1, max_length=80)


class ActivityGearLinkPayload(ActivityModel):
    id: UUID | None = None
    activity_id: UUID
    gear_id: UUID
    role: Literal["primary", "secondary", "sensor", "other"] = "primary"
    start_offset_ms: int | None = Field(default=None, ge=0)
    end_offset_ms: int | None = Field(default=None, ge=0)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def valid_offsets(self):
        if (
            self.start_offset_ms is not None
            and self.end_offset_ms is not None
            and self.end_offset_ms < self.start_offset_ms
        ):
            raise ValueError("end_offset_ms cannot be before start_offset_ms")
        return self


class ActivityGoalLinkPayload(ActivityModel):
    id: UUID | None = None
    activity_id: UUID
    goal_id: UUID
    role: Literal["user_assigned", "inferred_reviewed"] = "user_assigned"
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class ActivityGoalLinkInput(ActivityModel):
    goal_id: UUID
    role: Literal["user_assigned", "inferred_reviewed"] = "user_assigned"


class ActivityGoalLinksReplacePayload(ActivityModel):
    links: list[ActivityGoalLinkInput] = Field(default_factory=list, max_length=50)

    @model_validator(mode="after")
    def unique_links(self):
        keys = [(item.goal_id, item.role) for item in self.links]
        if len(keys) != len(set(keys)):
            raise ValueError("Activity goal links must be unique")
        return self


class ActivityContextPatch(ActivityModel):
    # Offline clients include the entity identifier in every upsert payload.
    # The sync envelope remains authoritative; REST callers may omit this field.
    id: UUID | None = None
    title: str | None = Field(default=None, min_length=1, max_length=200)
    notes: str | None = Field(default=None, max_length=8_000)
    session_rpe: float | None = Field(default=None, ge=0, le=10)
    workout_classification: Literal[
        "recovery",
        "easy",
        "steady",
        "long",
        "tempo",
        "threshold",
        "interval",
        "hill",
        "race",
        "time_trial",
        "progression",
        "mixed",
        "unclassified",
    ] | None = None
    planned_session_id: UUID | None = None
    gear_ids: list[UUID] | None = Field(default=None, max_length=30)


class ManualActivityPayload(ActivityModel):
    """A completed activity entered by the user rather than imported from a device."""

    id: UUID | None = None
    sport_key: str = Field(min_length=1, max_length=80)
    title: str | None = Field(default=None, min_length=1, max_length=200)
    started_at_utc: datetime
    local_timezone: str = Field(min_length=1, max_length=100)
    duration_s: float = Field(gt=0, le=604_800)
    distance_m: float | None = Field(default=None, ge=0, le=2_000_000)
    session_rpe: float | None = Field(default=None, ge=0, le=10)
    workout_classification: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=8_000)
    estimate_energy: bool = True
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def valid_start(self):
        if (
            self.started_at_utc.tzinfo is None
            or self.started_at_utc.utcoffset() is None
        ):
            raise ValueError("Activity start must include a UTC offset")
        return self


class ManualActivityDefaults(ActivityModel):
    latest_weight_kg: float | None = None
    latest_weight_measured_at_utc: str | None = None
    energy_estimation_method: str = "adult_compendium_2024_met"


class ActivityLinkPayload(ActivityModel):
    activity_id: UUID
    explanation: str | None = Field(default=None, max_length=1_000)


class HealthKitWorkoutImport(ActivityModel):
    source_bundle_identifier: str = Field(min_length=1, max_length=300)
    workout_uuid: UUID
    origin_provider_key: str = Field(min_length=1, max_length=80)
    external_uuid: str | None = Field(default=None, max_length=500)
    source_name: str | None = Field(default=None, max_length=200)
    source_device_identifier: str | None = Field(default=None, max_length=300)
    product_type: str | None = Field(default=None, max_length=200)
    sport_key: str | None = Field(default=None, max_length=80)
    sub_sport_key: str | None = Field(default=None, max_length=80)
    title: str | None = Field(default=None, max_length=200)
    started_at_utc: datetime | None = None
    ended_at_utc: datetime | None = None
    duration_s: float | None = Field(default=None, gt=0, le=604_800)
    distance_m: float | None = Field(default=None, ge=0, le=2_000_000)
    energy_kcal: float | None = Field(default=None, ge=0, le=100_000)
    local_timezone: str | None = Field(default=None, max_length=100)
    deleted: bool = False

    @model_validator(mode="after")
    def complete_workout(self):
        if self.deleted:
            return self
        required = (
            self.sport_key,
            self.started_at_utc,
            self.ended_at_utc,
            self.duration_s,
            self.local_timezone,
        )
        if any(value is None for value in required):
            raise ValueError(
                "A workout import needs sport, start, end, duration and local timezone"
            )
        assert self.started_at_utc is not None and self.ended_at_utc is not None
        assert self.duration_s is not None
        if (
            self.started_at_utc.tzinfo is None
            or self.started_at_utc.utcoffset() is None
            or self.ended_at_utc.tzinfo is None
            or self.ended_at_utc.utcoffset() is None
        ):
            raise ValueError("Workout timestamps must include a UTC offset")
        if self.ended_at_utc <= self.started_at_utc:
            raise ValueError("Workout end must follow its start")
        elapsed = (self.ended_at_utc - self.started_at_utc).total_seconds()
        if self.duration_s > elapsed + 2:
            raise ValueError("Workout duration cannot exceed its time window")
        return self


class HealthKitWorkoutImportResponse(ActivityModel):
    status: Literal["created", "updated", "unchanged", "deleted", "already_deleted"]
    source_record_id: str
    activity_id: str | None = None
    deleted: bool


class HealthKitWorkoutSourceMetadata(ActivityModel):
    source_record_id: str
    source_bundle_identifier: str
    workout_uuid: UUID
    origin_provider_key: str
    external_uuid: str | None = None
    activity_id: str | None = None


class AnalysisQueryFilters(ActivityModel):
    date_from: date | None = None
    date_to: date | None = None
    sport_key: str | None = Field(default=None, max_length=80)
    workout_classification: str | None = Field(default=None, max_length=80)
    phase_id: UUID | None = None
    gear_id: UUID | None = None


class AnalysisQueryPayload(ActivityModel):
    dimension: str = Field(min_length=1, max_length=120)
    measure: str = Field(min_length=1, max_length=120)
    chart_type: Literal["line", "bar", "scatter", "table"]
    filters: AnalysisQueryFilters = Field(default_factory=AnalysisQueryFilters)


class WorkerCompletePayload(ActivityModel):
    lease_token: str = Field(min_length=16, max_length=200)


class WorkerLeasePayload(ActivityModel):
    lease_token: str = Field(min_length=16, max_length=200)


class WorkerFailPayload(WorkerLeasePayload):
    error_code: str = Field(min_length=1, max_length=100)
    error: str = Field(min_length=1, max_length=2_000)
    retryable: bool = True
