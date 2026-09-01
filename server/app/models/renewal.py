"""Pydantic schemas for household renewals and expiries."""

from datetime import date
from typing import Literal
from urllib.parse import urlparse

from pydantic import BaseModel, Field, field_validator

from app.models.document import LinkedDocumentResponse

_CATEGORIES = {
    "document",
    "vehicle",
    "insurance",
    "subscription",
    "utility",
    "membership",
    "medical",
    "other",
}


def _optional_url(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    if not cleaned:
        return None
    parsed = urlparse(cleaned)
    if parsed.scheme not in {"https", "http", "mailto", "tel"}:
        raise ValueError("link must start with https://, http://, mailto: or tel:")
    if parsed.scheme in {"https", "http"} and not parsed.netloc:
        raise ValueError("link must be a complete web address")
    return cleaned


class RenewalChecklistItemResponse(BaseModel):
    id: str
    title: str
    checked_at: str | None = None
    position: int = 0


class RenewalHistoryItemResponse(BaseModel):
    id: str
    outcome: Literal["renewed", "not_renewing"]
    due_date: str
    decided_at: str
    cost_pence: int | None = None
    next_due_date: str | None = None
    notes: str | None = None


class RenewalChecklistItemCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class RenewalChecklistItemUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    checked: bool | None = None


class RenewalDecisionRequest(BaseModel):
    outcome: Literal["renewed", "not_renewing"] = "renewed"
    next_due_date: str | None = None
    cost_pence: int | None = Field(default=None, ge=0, le=100_000_000)
    notes: str | None = Field(default=None, max_length=2_000)

    @field_validator("next_due_date")
    @classmethod
    def _next_due(cls, value: str | None) -> str | None:
        return _valid_date(value) if value is not None else None


class RenewalDraftRequest(BaseModel):
    document_id: str | None = Field(default=None, max_length=100)
    text: str | None = Field(default=None, max_length=150_000)


class RenewalDraftResponse(BaseModel):
    title: str | None = None
    category: str = "other"
    due_date: str | None = None
    recurrence_months: int | None = None
    cost_pence: int | None = None
    provider: str | None = None
    reference: str | None = None
    action_url: str | None = None
    source_document_id: str | None = None
    uncertain_fields: list[str] = []


def _valid_date(value: str) -> str:
    try:
        date.fromisoformat(value[:10])
    except (TypeError, ValueError) as exc:
        raise ValueError("due_date must be an ISO date") from exc
    return value[:10]


class RenewalCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    category: str = "other"
    due_date: str
    recurrence_months: int | None = Field(default=None, ge=1, le=120)
    cost_pence: int | None = Field(default=None, ge=0, le=100_000_000)
    reminder_days_before: int = Field(default=21, ge=0, le=180)
    source_document_id: str | None = Field(default=None, max_length=100)
    provider: str | None = Field(default=None, max_length=200)
    reference: str | None = Field(default=None, max_length=200)
    action_url: str | None = Field(default=None, max_length=2_000)
    comparison_url: str | None = Field(default=None, max_length=2_000)
    contact_url: str | None = Field(default=None, max_length=2_000)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None
    include_in_household_finance: bool = False
    payment_handling: Literal["UNSPECIFIED", "AUTOMATIC", "MANUAL", "RENEWAL"] = "UNSPECIFIED"
    show_in_calendar: bool = False
    show_in_tasks: bool = False
    responsible_user_id: str | None = Field(default=None, max_length=100)
    reminders_enabled: bool = True
    escalate_after_days: int | None = Field(default=3, ge=0, le=60)
    checklist: list[str] = Field(default_factory=list, max_length=30)

    @field_validator("category")
    @classmethod
    def _category(cls, value: str) -> str:
        return value if value in _CATEGORIES else "other"

    @field_validator("due_date")
    @classmethod
    def _due(cls, value: str) -> str:
        return _valid_date(value)

    _action_url = field_validator("action_url")(_optional_url)
    _comparison_url = field_validator("comparison_url")(_optional_url)
    _contact_url = field_validator("contact_url")(_optional_url)


class RenewalUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    category: str | None = None
    due_date: str | None = None
    recurrence_months: int | None = Field(default=None, ge=1, le=120)
    cost_pence: int | None = Field(default=None, ge=0, le=100_000_000)
    reminder_days_before: int | None = Field(default=None, ge=0, le=180)
    source_document_id: str | None = Field(default=None, max_length=100)
    provider: str | None = Field(default=None, max_length=200)
    reference: str | None = Field(default=None, max_length=200)
    action_url: str | None = Field(default=None, max_length=2_000)
    comparison_url: str | None = Field(default=None, max_length=2_000)
    contact_url: str | None = Field(default=None, max_length=2_000)
    notes: str | None = Field(default=None, max_length=2_000)
    include_in_household_finance: bool | None = None
    payment_handling: Literal["UNSPECIFIED", "AUTOMATIC", "MANUAL", "RENEWAL"] | None = None
    show_in_calendar: bool | None = None
    show_in_tasks: bool | None = None
    responsible_user_id: str | None = Field(default=None, max_length=100)
    reminders_enabled: bool | None = None
    escalate_after_days: int | None = Field(default=None, ge=0, le=60)

    @field_validator("category")
    @classmethod
    def _category(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value if value in _CATEGORIES else "other"

    @field_validator("due_date")
    @classmethod
    def _due(cls, value: str | None) -> str | None:
        return _valid_date(value) if value is not None else None

    _action_url = field_validator("action_url")(_optional_url)
    _comparison_url = field_validator("comparison_url")(_optional_url)
    _contact_url = field_validator("contact_url")(_optional_url)


class RenewalResponse(BaseModel):
    id: str
    title: str
    category: str
    due_date: str
    days_until: int
    status: str
    recurrence_months: int | None
    cost_pence: int | None
    reminder_days_before: int
    source_document_id: str | None
    source_document: LinkedDocumentResponse | None = None
    provider: str | None = None
    reference: str | None = None
    action_url: str | None = None
    comparison_url: str | None = None
    contact_url: str | None = None
    finance_commitment_id: str | None = None
    payment_handling: Literal["UNSPECIFIED", "AUTOMATIC", "MANUAL", "RENEWAL"] = "UNSPECIFIED"
    show_in_calendar: bool = False
    show_in_tasks: bool = False
    responsible_user_id: str | None = None
    responsible_user_name: str | None = None
    reminders_enabled: bool = True
    escalate_after_days: int | None = 3
    checklist: list[RenewalChecklistItemResponse] = []
    history: list[RenewalHistoryItemResponse] = []
    previous_cost_pence: int | None = None
    cost_change_pence: int | None = None
    notes: str | None
    created_at: str
