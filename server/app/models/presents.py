"""Pydantic contracts for recipient-first gift planning."""

from datetime import date
from typing import Literal
from urllib.parse import urlparse

from pydantic import BaseModel, Field, field_validator


PresentStatus = Literal[
    "idea",
    "shortlist",
    "assigned",
    "bought",
    "arrived",
    "wrapped",
    "stashed",
    "given",
]


def _clean_required(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("must not be blank")
    return value


def _clean_optional(value: str | None) -> str | None:
    if value is None:
        return None
    return value.strip() or None


def _web_url(value: str | None) -> str | None:
    value = _clean_optional(value)
    if value is None:
        return None
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("must be a valid http or https link")
    return value


def _date_only(value: str | None) -> str | None:
    value = _clean_optional(value)
    if value is None:
        return None
    try:
        return date.fromisoformat(value).isoformat()
    except ValueError as exc:
        raise ValueError("must be a valid date in YYYY-MM-DD format") from exc


class PresentIdeaCreate(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    title: str = Field(min_length=1, max_length=300)
    occasion: str = Field(default="christmas", min_length=1, max_length=100)
    event_year: int | None = Field(default=None, ge=2000, le=2100)
    birthday_id: str | None = Field(default=None, max_length=100)
    status: PresentStatus = "idea"
    owner_id: str | None = Field(default=None, max_length=100)
    notes: str | None = Field(default=None, max_length=2_000)
    assigned_to: str | None = Field(default=None, max_length=200)
    url: str | None = Field(default=None, max_length=2_000)
    retailer: str | None = Field(default=None, max_length=200)
    budget_minor: int | None = Field(default=None, ge=0, le=100_000_000)
    price_minor: int | None = Field(default=None, ge=0, le=100_000_000)
    currency: str = Field(default="GBP", min_length=3, max_length=3)
    deadline: str | None = Field(default=None, max_length=64)
    hiding_location: str | None = Field(default=None, max_length=500)
    recipient_can_see: bool = False
    allow_duplicate: bool = False
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("child_id", "title", "occasion")
    @classmethod
    def clean_required(cls, value: str) -> str:
        return _clean_required(value)

    @field_validator(
        "birthday_id",
        "owner_id",
        "notes",
        "assigned_to",
        "retailer",
        "hiding_location",
    )
    @classmethod
    def clean_optional(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("url")
    @classmethod
    def valid_url(cls, value: str | None) -> str | None:
        return _web_url(value)

    @field_validator("deadline")
    @classmethod
    def valid_deadline(cls, value: str | None) -> str | None:
        return _date_only(value)

    @field_validator("currency")
    @classmethod
    def valid_currency(cls, value: str) -> str:
        if not value.isalpha():
            raise ValueError("must be a three-letter currency code")
        return value.upper()


class PresentIdeaUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=300)
    occasion: str | None = Field(default=None, min_length=1, max_length=100)
    event_year: int | None = Field(default=None, ge=2000, le=2100)
    birthday_id: str | None = Field(default=None, max_length=100)
    status: PresentStatus | None = None
    owner_id: str | None = Field(default=None, max_length=100)
    notes: str | None = Field(default=None, max_length=2_000)
    assigned_to: str | None = Field(default=None, max_length=200)
    url: str | None = Field(default=None, max_length=2_000)
    retailer: str | None = Field(default=None, max_length=200)
    budget_minor: int | None = Field(default=None, ge=0, le=100_000_000)
    price_minor: int | None = Field(default=None, ge=0, le=100_000_000)
    currency: str | None = Field(default=None, min_length=3, max_length=3)
    deadline: str | None = Field(default=None, max_length=64)
    hiding_location: str | None = Field(default=None, max_length=500)
    recipient_can_see: bool | None = None
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("title", "occasion")
    @classmethod
    def clean_required(cls, value: str | None) -> str | None:
        return _clean_required(value) if value is not None else None

    @field_validator(
        "birthday_id",
        "owner_id",
        "notes",
        "assigned_to",
        "retailer",
        "hiding_location",
    )
    @classmethod
    def clean_optional(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("url")
    @classmethod
    def valid_url(cls, value: str | None) -> str | None:
        return _web_url(value)

    @field_validator("deadline")
    @classmethod
    def valid_deadline(cls, value: str | None) -> str | None:
        return _date_only(value)

    @field_validator("currency")
    @classmethod
    def valid_currency(cls, value: str | None) -> str | None:
        if value is None:
            return None
        if not value.isalpha():
            raise ValueError("must be a three-letter currency code")
        return value.upper()


class PresentDuplicateCheck(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    title: str = Field(min_length=1, max_length=300)
    url: str | None = Field(default=None, max_length=2_000)
    exclude_id: str | None = Field(default=None, max_length=100)

    @field_validator("child_id", "title")
    @classmethod
    def clean_title(cls, value: str) -> str:
        return _clean_required(value)

    @field_validator("exclude_id")
    @classmethod
    def clean_exclude_id(cls, value: str | None) -> str | None:
        return _clean_optional(value)

    @field_validator("url")
    @classmethod
    def valid_url(cls, value: str | None) -> str | None:
        return _web_url(value)


class PresentDuplicateMatch(BaseModel):
    id: str
    title: str
    occasion: str
    event_year: int
    status: PresentStatus


class PresentDuplicateResponse(BaseModel):
    matches: list[PresentDuplicateMatch] = Field(default_factory=list)


class PresentStatusUpdate(BaseModel):
    status: PresentStatus


class PresentIdeaScoreUpsert(BaseModel):
    score: int
    client_id: str | None = None
    client_timestamp: str | None = None


class PresentScoreResponse(BaseModel):
    user_id: str
    user_name: str | None = None
    score: int
    created_at: str
    updated_at: str
    client_id: str | None = None
    client_timestamp: str | None = None


class PresentStatusHistoryResponse(BaseModel):
    id: str
    from_status: PresentStatus | None = None
    to_status: PresentStatus
    changed_at: str
    changed_by: str | None = None
    changed_by_name: str | None = None


class PresentIdeaResponse(BaseModel):
    id: str
    child_id: str
    recipient_name: str | None = None
    title: str
    occasion: str
    event_year: int
    birthday_id: str | None = None
    status: PresentStatus = "idea"
    status_updated_at: str | None = None
    owner_id: str | None = None
    owner_name: str | None = None
    notes: str | None = None
    assigned_to: str | None = None
    url: str | None = None
    retailer: str | None = None
    budget_minor: int | None = None
    price_minor: int | None = None
    currency: str = "GBP"
    deadline: str | None = None
    hiding_location: str | None = None
    recipient_can_see: bool = False
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None
    scores: list[PresentScoreResponse] = Field(default_factory=list)
    average_score: float | None = None
    status_history: list[PresentStatusHistoryResponse] = Field(default_factory=list)


class PresentOccasionBucket(BaseModel):
    occasion: str
    ideas: list[PresentIdeaResponse]


class ChildPresentsResponse(BaseModel):
    child_id: str
    year: int
    occasions: list[PresentOccasionBucket]


class PresentOccasionChildColumn(BaseModel):
    child_id: str
    child_name: str
    ideas: list[PresentIdeaResponse]


class PresentOccasionBoardResponse(BaseModel):
    occasion: str
    year: int
    children: list[PresentOccasionChildColumn]
