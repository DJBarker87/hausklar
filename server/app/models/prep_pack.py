"""Typed contracts for event-linked preparation packs."""

from datetime import datetime

from pydantic import BaseModel, Field, field_validator


def _clean_list(values: list[str], *, maximum: int, label: str) -> list[str]:
    cleaned = [value.strip()[:maximum] for value in values if value.strip()]
    if not cleaned:
        raise ValueError(f"Add at least one {label}")
    if len(cleaned) != len({value.casefold() for value in cleaned}):
        raise ValueError(f"Duplicate {label}s are not allowed")
    return cleaned


class PrepPackTemplateCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    match_terms: list[str] = Field(min_length=1, max_length=10)
    items: list[str] = Field(min_length=1, max_length=12)
    lead_hours: int = Field(default=24, ge=0, le=168)
    assigned_to: str | None = Field(default=None, max_length=100)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Add an activity name")
        return cleaned

    @field_validator("match_terms")
    @classmethod
    def clean_terms(cls, value: list[str]) -> list[str]:
        return _clean_list(value, maximum=80, label="matching phrase")

    @field_validator("items")
    @classmethod
    def clean_items(cls, value: list[str]) -> list[str]:
        return _clean_list(value, maximum=300, label="checklist item")


class PrepPackTemplateUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    match_terms: list[str] | None = Field(default=None, min_length=1, max_length=10)
    items: list[str] | None = Field(default=None, min_length=1, max_length=12)
    lead_hours: int | None = Field(default=None, ge=0, le=168)
    assigned_to: str | None = Field(default=None, max_length=100)
    enabled: bool | None = None

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Add an activity name")
        return cleaned

    @field_validator("match_terms")
    @classmethod
    def clean_terms(cls, value: list[str] | None) -> list[str] | None:
        return None if value is None else _clean_list(value, maximum=80, label="matching phrase")

    @field_validator("items")
    @classmethod
    def clean_items(cls, value: list[str] | None) -> list[str] | None:
        return None if value is None else _clean_list(value, maximum=300, label="checklist item")


class PrepPackAction(BaseModel):
    template_id: str = Field(min_length=1, max_length=100)
    event_id: str = Field(min_length=1, max_length=200)
    occurrence_start: str = Field(min_length=1, max_length=100)
    timezone: str = Field(default="Europe/London", min_length=1, max_length=50)
    assigned_to: str | None = Field(default=None, max_length=100)

    @field_validator("occurrence_start")
    @classmethod
    def valid_occurrence(cls, value: str) -> str:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("Occurrence time must include a timezone")
        return value
