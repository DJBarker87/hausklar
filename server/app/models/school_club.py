from __future__ import annotations

from datetime import date, time
from uuid import uuid4

from pydantic import UUID4, BaseModel, Field, field_validator, model_validator


def _iso_date(value: str | None) -> str | None:
    if value is None:
        return None
    try:
        parsed = date.fromisoformat(value)
    except ValueError as exc:
        raise ValueError("Date must use YYYY-MM-DD format") from exc
    if parsed.isoformat() != value:
        raise ValueError("Date must use YYYY-MM-DD format")
    return value


def _local_time(value: str) -> str:
    try:
        parsed = time.fromisoformat(value)
    except ValueError as exc:
        raise ValueError("Club time must use HH:MM") from exc
    return parsed.strftime("%H:%M")


class SchoolClubCreate(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    name: str = Field(min_length=1, max_length=120)
    child_id: str = Field(min_length=1, max_length=100)
    weekday: int = Field(ge=0, le=6)
    start_time: str
    end_time: str
    active_from: str | None = None
    active_until: str | None = None
    location: str | None = Field(default=None, max_length=300)
    client_id: str | None = Field(default=None, max_length=200)
    client_timestamp: str | None = Field(default=None, max_length=64)

    _validate_time = field_validator("start_time", "end_time")(_local_time)
    _validate_date = field_validator("active_from", "active_until")(_iso_date)

    @model_validator(mode="after")
    def validate_range(self):
        if self.end_time <= self.start_time:
            raise ValueError("Club end time must be later than its start time")
        if self.active_from and self.active_until and self.active_until < self.active_from:
            raise ValueError("Club end date must not be before its start date")
        return self


class SchoolClubUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    child_id: str | None = Field(default=None, min_length=1, max_length=100)
    weekday: int | None = Field(default=None, ge=0, le=6)
    start_time: str | None = None
    end_time: str | None = None
    active_from: str | None = None
    active_until: str | None = None
    location: str | None = Field(default=None, max_length=300)
    client_id: str | None = Field(default=None, max_length=200)
    client_timestamp: str | None = Field(default=None, max_length=64)

    _validate_time = field_validator("start_time", "end_time")(
        lambda value: None if value is None else _local_time(value)
    )
    _validate_date = field_validator("active_from", "active_until")(_iso_date)


class SchoolClubResponse(BaseModel):
    id: str
    name: str
    child_id: str
    child_name: str
    weekday: int
    start_time: str
    end_time: str
    active_from: str
    active_until: str | None = None
    location: str | None = None
    color: str
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class SchoolClubCancellation(BaseModel):
    client_id: str | None = Field(default=None, max_length=200)
    client_timestamp: str | None = Field(default=None, max_length=64)


class SchoolClubCancellationResponse(BaseModel):
    club_id: str
    occurrence_date: str
    cancelled: bool
