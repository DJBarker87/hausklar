"""Typed Fitness provenance, sleep, recovery and progress-photo contracts."""

from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import Field, model_validator

from app.models.fitness import ClientRecord, FitnessModel


class SourceRecordPayload(ClientRecord):
    record_kind: Literal[
        "activity",
        "body_measurement",
        "sleep_session",
        "recovery_metric",
        "recovery_observation",
        "other",
    ]
    sample_type: str | None = Field(default=None, max_length=200)
    transport_key: str = Field(min_length=1, max_length=80)
    origin_provider_key: str = Field(min_length=1, max_length=80)
    source_namespace: str = Field(max_length=300)
    source_object_id: str = Field(min_length=1, max_length=500)
    external_object_id: str | None = Field(default=None, max_length=500)
    source_device_identifier: str | None = Field(default=None, max_length=300)
    source_name: str | None = Field(default=None, max_length=200)
    product_type: str | None = Field(default=None, max_length=200)
    device_json: dict[str, str] = Field(default_factory=dict)
    metadata_json: dict[str, Any] = Field(default_factory=dict)
    domain_entity_type: Literal[
        "activity", "body_measurement", "sleep_session", "recovery_observation", "other"
    ] | None = None
    domain_entity_id: UUID | None = None
    state: Literal["active", "deleted", "superseded"] = "active"

    @model_validator(mode="after")
    def bounded_metadata(self):
        if len(self.device_json) > 30 or len(self.metadata_json) > 30:
            raise ValueError("Source metadata contains too many fields")
        for key, value in self.metadata_json.items():
            if len(key) > 100 or isinstance(value, (dict, list)):
                raise ValueError("Source metadata must contain bounded scalar values")
        return self


class ExternalSourcePayload(FitnessModel):
    transport_key: str = Field(min_length=1, max_length=80)
    origin_provider_key: str = Field(min_length=1, max_length=80)
    source_namespace: str = Field(max_length=300)
    source_device_identifier: str | None = Field(default=None, max_length=300)
    state: str | None = Field(default=None, max_length=40)


class SleepStagePayload(FitnessModel):
    id: UUID | None = None
    stage: str = Field(min_length=1, max_length=50)
    start_at_utc: datetime
    end_at_utc: datetime
    duration_s: float = Field(ge=0)
    source_record_id: UUID | None = None

    @model_validator(mode="after")
    def valid_interval(self):
        if self.end_at_utc <= self.start_at_utc:
            raise ValueError("Sleep stage end must follow its start")
        actual = (self.end_at_utc - self.start_at_utc).total_seconds()
        if abs(actual - self.duration_s) > 2:
            raise ValueError("Sleep stage duration does not match its timestamps")
        return self


class SleepSessionPayload(ClientRecord):
    sleep_start_utc: datetime
    sleep_end_utc: datetime
    duration_s: float = Field(ge=0)
    awake_duration_s: float | None = Field(default=None, ge=0)
    source_quality: str | None = Field(default=None, max_length=50)
    source_record_id: UUID | None = None
    source_stages: list[SleepStagePayload] = Field(default_factory=list, max_length=500)
    source: ExternalSourcePayload | None = None
    notes: str | None = Field(default=None, max_length=4_000)

    @model_validator(mode="after")
    def valid_session(self):
        if self.sleep_end_utc <= self.sleep_start_utc:
            raise ValueError("Sleep end must follow sleep start")
        elapsed = (self.sleep_end_utc - self.sleep_start_utc).total_seconds()
        if self.duration_s > elapsed + 2:
            raise ValueError("Sleep duration cannot exceed its time window")
        if self.awake_duration_s is not None and self.awake_duration_s > elapsed + 2:
            raise ValueError("Awake duration cannot exceed the sleep window")
        for stage in self.source_stages:
            if (
                stage.start_at_utc < self.sleep_start_utc
                or stage.end_at_utc > self.sleep_end_utc
            ):
                raise ValueError("Sleep stages must lie inside the session")
            if stage.source_record_id is None:
                raise ValueError("Every normalized sleep stage requires exact provenance")
        if self.source is not None and self.source_record_id is None:
            raise ValueError("Imported source details require source_record_id")
        return self


class RecoveryObservationPayload(ClientRecord):
    metric_key: str = Field(min_length=1, max_length=120)
    observed_at_utc: datetime
    value_number: float | None = None
    value_text: str | None = Field(default=None, max_length=500)
    unit_key: str | None = Field(default=None, max_length=40)
    source_quality: str | None = Field(default=None, max_length=50)
    source_record_id: UUID | None = None
    source: ExternalSourcePayload | None = None
    notes: str | None = Field(default=None, max_length=4_000)

    @model_validator(mode="after")
    def one_value(self):
        if (self.value_number is None) == (self.value_text is None):
            raise ValueError("Provide exactly one recovery value")
        if self.source is not None and self.source_record_id is None:
            raise ValueError("Imported source details require source_record_id")
        return self


class SourcePriorityPayload(ClientRecord):
    metric_key: str = Field(min_length=1, max_length=120)
    origin_provider_key: str = Field(min_length=1, max_length=80)
    transport_key: str = Field(default="", max_length=80)
    source_namespace: str = Field(default="", max_length=300)
    priority: int = Field(ge=-1_000, le=1_000)


class BodyMeasurementCanonicalOverrideResponse(FitnessModel):
    canonical_measurement_id: UUID
    group_member_ids: list[UUID]
    manual_override: bool


class ProgressPhotoPayload(ClientRecord):
    captured_at: datetime
    pose: Literal["front", "side_left", "side_right", "back", "custom"]
    body_weight_kg: float | None = Field(default=None, gt=0, le=1_000)
    measurement_snapshot_json: dict[str, float | str | None] | None = None
    phase_id: UUID | None = None
    original_asset_id: UUID
    notes: str | None = Field(default=None, max_length=4_000)

    @model_validator(mode="after")
    def bounded_snapshot(self):
        snapshot = self.measurement_snapshot_json or {}
        if len(snapshot) > 100 or any(len(key) > 120 for key in snapshot):
            raise ValueError("Measurement snapshot is too large")
        return self
