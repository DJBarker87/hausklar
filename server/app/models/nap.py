from typing import Literal

from pydantic import BaseModel, Field


class NapStartRequest(BaseModel):
    id: str | None = Field(default=None, min_length=1, max_length=100)
    child_id: str = Field(min_length=1, max_length=100)
    started_at: str | None = Field(default=None, max_length=64)
    location: str | None = Field(default=None, max_length=200)
    notes: str | None = Field(default=None, max_length=2_000)
    sleep_type: Literal["nap", "bedtime"] = "nap"
    client_id: str | None = None
    client_timestamp: str | None = None


class NapEndRequest(BaseModel):
    ended_at: str | None = Field(default=None, max_length=64)


class NapUpdateRequest(BaseModel):
    started_at: str | None = Field(default=None, max_length=64)
    ended_at: str | None = Field(default=None, max_length=64)
    clear_ended_at: bool = False
    location: str | None = Field(default=None, max_length=200)
    clear_location: bool = False
    notes: str | None = Field(default=None, max_length=2_000)
    clear_notes: bool = False


class NapResponse(BaseModel):
    id: str
    child_id: str
    started_at: str
    ended_at: str | None = None
    location: str | None = None
    notes: str | None = None
    sleep_type: str = "nap"
    duration_minutes: float | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
