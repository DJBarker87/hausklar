"""Pydantic models for the children endpoint."""

from datetime import date
from uuid import uuid4

from pydantic import UUID4, BaseModel, Field, field_validator


class ChildCreate(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    name: str = Field(min_length=1, max_length=100)
    date_of_birth: date
    notes: str | None = Field(default=None, max_length=5_000)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)

    @field_validator("name")
    @classmethod
    def normalise_name(cls, value: str) -> str:
        cleaned = " ".join(value.strip().split())
        if not cleaned:
            raise ValueError("Enter the child's name")
        return cleaned

    @field_validator("date_of_birth")
    @classmethod
    def date_is_not_in_future(cls, value: date) -> date:
        if value > date.today():
            raise ValueError("Date of birth cannot be in the future")
        return value


class ChildResponse(BaseModel):
    id: str
    name: str
    date_of_birth: str
