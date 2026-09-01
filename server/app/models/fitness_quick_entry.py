"""Contracts for the low-friction Fitness actions shown on Today."""

from datetime import date, time
from typing import Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class QuickEntryModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        str_strip_whitespace=True,
        allow_inf_nan=False,
    )


class MealTimes(QuickEntryModel):
    breakfast: str = Field(default="08:00", pattern=r"^\d{2}:\d{2}$")
    lunch: str = Field(default="12:30", pattern=r"^\d{2}:\d{2}$")
    dinner: str = Field(default="18:30", pattern=r"^\d{2}:\d{2}$")

    @field_validator("breakfast", "lunch", "dinner")
    @classmethod
    def valid_local_time(cls, value: str) -> str:
        try:
            time.fromisoformat(value)
        except ValueError as exc:
            raise ValueError("Meal times must use 24-hour HH:MM format") from exc
        return value

    @model_validator(mode="after")
    def chronological(self):
        values = [
            time.fromisoformat(self.breakfast),
            time.fromisoformat(self.lunch),
            time.fromisoformat(self.dinner),
        ]
        if values != sorted(values) or len(set(values)) != len(values):
            raise ValueError("Breakfast, lunch and dinner must be in time order")
        return self


class QuickEntryPreferencesResponse(QuickEntryModel):
    meal_times: MealTimes = Field(default_factory=MealTimes)


class QuickEntryPreferencesUpdate(QuickEntryModel):
    meal_times: MealTimes


class StrengthAvailabilityWindow(QuickEntryModel):
    start: str = Field(pattern=r"^\d{2}:\d{2}$")
    end: str = Field(pattern=r"^\d{2}:\d{2}$")
    label: str | None = Field(default=None, max_length=200)
    booking_url: str | None = Field(default=None, max_length=2_000)

    @model_validator(mode="after")
    def valid_time_range(self):
        try:
            start_value = time.fromisoformat(self.start)
            end_value = time.fromisoformat(self.end)
        except ValueError as exc:
            raise ValueError("Strength times must use 24-hour HH:MM format") from exc
        if end_value <= start_value:
            raise ValueError("Strength availability must end after it starts")
        return self


class StrengthAvailabilityDay(QuickEntryModel):
    date: date
    covered: bool
    windows: list[StrengthAvailabilityWindow] = Field(default_factory=list, max_length=40)


class StrengthAvailabilityResponse(QuickEntryModel):
    provider: Literal["school_weights_room", "vi_training"]
    source_title: str = Field(min_length=1, max_length=300)
    source_url: str | None = Field(default=None, max_length=2_000)
    unavailable_reason: str | None = Field(default=None, max_length=500)
    days: list[StrengthAvailabilityDay] = Field(default_factory=list, max_length=120)


ViClassClassification = Literal["strength", "run", "conditioning", "mobility", "other"]


class ViClassWindow(QuickEntryModel):
    start: str = Field(pattern=r"^\d{2}:\d{2}$")
    end: str = Field(pattern=r"^\d{2}:\d{2}$")
    label: str = Field(min_length=1, max_length=160)
    classification: ViClassClassification
    booking_url: str | None = Field(default=None, max_length=2_000)

    @model_validator(mode="after")
    def valid_time_range(self):
        try:
            start_value = time.fromisoformat(self.start)
            end_value = time.fromisoformat(self.end)
        except ValueError as exc:
            raise ValueError("Vi class times must use 24-hour HH:MM format") from exc
        if end_value <= start_value:
            raise ValueError("Vi class availability must end after it starts")
        return self


class ViScheduleDay(QuickEntryModel):
    date: date
    covered: bool
    classes: list[ViClassWindow] = Field(default_factory=list, max_length=40)


class ViScheduleResponse(QuickEntryModel):
    relevant: bool
    provider: Literal["vi_training"] = "vi_training"
    source_title: str = Field(min_length=1, max_length=300)
    source_url: str | None = Field(default=None, max_length=2_000)
    unavailable_reason: str | None = Field(default=None, max_length=500)
    days: list[ViScheduleDay] = Field(default_factory=list, max_length=31)


class ViBookingCreate(QuickEntryModel):
    id: UUID = Field(default_factory=uuid4)
    provider: Literal["vi_training"]
    date: date
    start: str = Field(pattern=r"^\d{2}:\d{2}$")
    end: str = Field(pattern=r"^\d{2}:\d{2}$")
    label: str = Field(min_length=1, max_length=160)
    classification: ViClassClassification
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def valid_time_range(self):
        try:
            start_value = time.fromisoformat(self.start)
            end_value = time.fromisoformat(self.end)
        except ValueError as exc:
            raise ValueError("Booked Vi times must use 24-hour HH:MM format") from exc
        if end_value <= start_value:
            raise ValueError("Booked Vi time must end after it starts")
        return self


class ViBookingResponse(QuickEntryModel):
    status: Literal["booked"] = "booked"
    event_id: str
    title: str
    start_time: str
    end_time: str
    location: str
    classification: ViClassClassification


class StrengthBookingCreate(QuickEntryModel):
    id: UUID = Field(default_factory=uuid4)
    provider: Literal["vi_training"]
    date: date
    start: str = Field(pattern=r"^\d{2}:\d{2}$")
    end: str = Field(pattern=r"^\d{2}:\d{2}$")
    label: str = Field(default="Strength training", min_length=1, max_length=200)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def valid_time_range(self):
        try:
            start_value = time.fromisoformat(self.start)
            end_value = time.fromisoformat(self.end)
        except ValueError as exc:
            raise ValueError("Booked strength times must use 24-hour HH:MM format") from exc
        if end_value <= start_value:
            raise ValueError("Booked strength time must end after it starts")
        return self


class StrengthBookingResponse(QuickEntryModel):
    status: Literal["booked"] = "booked"
    event_id: str
    title: str
    start_time: str
    end_time: str
    location: str
