"""Strict contracts for imported Example School facility availability."""

from datetime import date, time
from typing import Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, StrictBool, model_validator


class FacilityModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class FacilityTimeWindow(FacilityModel):
    start: str = Field(pattern=r"^\d{2}:\d{2}$")
    end: str = Field(pattern=r"^\d{2}:\d{2}$")


class FacilityDaySummary(FacilityModel):
    date: date
    covered: bool
    family_swimming: list[FacilityTimeWindow] = Field(default_factory=list, max_length=12)
    lane_swimming: list[FacilityTimeWindow] = Field(default_factory=list, max_length=12)
    weights_room: list[FacilityTimeWindow] = Field(default_factory=list, max_length=12)
    pool_closed: bool = False
    weights_room_status: Literal["open", "closed", "unknown", "not_relevant"] = "unknown"
    weights_relevant: bool = False


class FacilityQuickFact(FacilityModel):
    provider: Literal["Example School College"] = "Example School College"
    source_title: str | None = None
    source_document_id: str | None = None
    current_from: date | None = None
    current_to: date | None = None
    update_due: bool = False
    today: FacilityDaySummary
    tomorrow: FacilityDaySummary


class FacilityCalendarPreferenceResponse(FacilityModel):
    show_family_swimming: bool = False
    show_personal_facilities: bool = False


class FacilityCalendarPreferenceUpdate(FacilityModel):
    show_family_swimming: StrictBool | None = None
    show_personal_facilities: StrictBool | None = None

    @model_validator(mode="after")
    def includes_a_change(self):
        if not self.model_fields_set or all(
            getattr(self, field) is None for field in self.model_fields_set
        ):
            raise ValueError("At least one calendar visibility change is required")
        return self


class FacilityCalendarLayerItem(FacilityModel):
    id: str
    layer_kind: Literal["family_swimming", "lane_swimming", "weights_room"]
    display_title: str
    start_time: str
    end_time: str
    owner_user_id: str | None = None
    source_document_id: str | None = None
    source_title: str
    location: str = "Example School College"
    read_only: Literal[True] = True


class FacilitySwimmingBookingCreate(FacilityModel):
    id: UUID = Field(default_factory=uuid4)
    date: date
    start: str = Field(pattern=r"^\d{2}:\d{2}$")
    end: str = Field(pattern=r"^\d{2}:\d{2}$")
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)

    @model_validator(mode="after")
    def has_valid_time_range(self):
        try:
            start = time.fromisoformat(self.start)
            end = time.fromisoformat(self.end)
        except ValueError as exc:
            raise ValueError("Swimming booking times must use 24-hour HH:MM format") from exc
        if end <= start:
            raise ValueError("Swimming booking end time must be after the start time")
        return self


class FacilitySwimmingBookingResponse(FacilityModel):
    status: Literal["booked"] = "booked"
    event_id: str
    title: str = "Swimming"
    start_time: str
    end_time: str
    location: str = "Example School College"


class FacilityWeightsBookingCreate(FacilityModel):
    id: UUID = Field(default_factory=uuid4)
    date: date
    start: str = Field(pattern=r"^\d{2}:\d{2}$")
    end: str = Field(pattern=r"^\d{2}:\d{2}$")
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)

    @model_validator(mode="after")
    def has_valid_time_range(self):
        try:
            start = time.fromisoformat(self.start)
            end = time.fromisoformat(self.end)
        except ValueError as exc:
            raise ValueError("Strength times must use 24-hour HH:MM format") from exc
        if end <= start:
            raise ValueError("Strength end time must be after the start time")
        return self


class FacilityWeightsBookingResponse(FacilityModel):
    status: Literal["planned"] = "planned"
    planned_session_id: str
    title: str = "Strength"
    start_time: str
    end_time: str
    location: str = "Example School College"


class FacilityImportCounts(FacilityModel):
    days: int = Field(ge=1)
    family_swimming_sessions: int = Field(ge=0)
    lane_swimming_sessions: int = Field(ge=0)
    weights_room_open_days: int = Field(ge=0)
    pool_closed_days: int = Field(ge=0)
    weights_room_closed_days: int = Field(ge=0)


class FacilityImportChanges(FacilityModel):
    added_days: int = Field(ge=0)
    changed_days: int = Field(ge=0)
    removed_days: int = Field(ge=0)


class FacilityImportPreview(FacilityModel):
    filename: str
    title: str
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    valid_from: date
    valid_to: date
    counts: FacilityImportCounts
    changes: FacilityImportChanges
    sample_days: list[FacilityDaySummary] = Field(default_factory=list, max_length=7)
    issues: list[str] = Field(default_factory=list, max_length=50)
    already_imported: bool = False
    can_confirm: bool


class FacilityImportResult(FacilityModel):
    version_id: str
    document_id: str | None
    imported: bool
    preview: FacilityImportPreview


class WeightsRoomAvailability(FacilityModel):
    relevant: bool
    source_title: str | None = None
    source_document_id: str | None = None
    current_to: date | None = None
    days: list[FacilityDaySummary] = Field(default_factory=list, max_length=120)
