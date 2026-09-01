"""Typed contracts for turning incoming information into confirmed family plans."""

from __future__ import annotations

import ipaddress
import re
from datetime import date, datetime
from enum import Enum
from typing import Literal
from urllib.parse import urlsplit
from uuid import uuid4

from pydantic import UUID4, BaseModel, Field, field_validator, model_validator


class CommitmentKind(str, Enum):
    school = "school"
    invitation = "invitation"
    outing = "outing"
    childcare = "childcare"
    appointment = "appointment"
    travel = "travel"


class CommitmentVisibility(str, Enum):
    family = "family"
    owner = "owner"


class CommitmentStatus(str, Enum):
    draft = "draft"
    action_required = "action_required"
    ready = "ready"
    confirmed = "confirmed"
    declined = "declined"


def _strip_required(value: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        raise ValueError("Value must not be blank")
    return cleaned


def _parse_temporal(value: str, *, label: str) -> date | datetime:
    try:
        if len(value) == 10:
            return date.fromisoformat(value)
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be an ISO-8601 date or time") from exc
    if parsed.tzinfo is None:
        raise ValueError(f"{label} must include a timezone")
    return parsed


def validate_safe_https_url(value: str | None) -> str | None:
    """Accept only public HTTPS destinations suitable for a reviewed hand-off."""
    if value is None:
        return None
    cleaned = value.strip()
    if not cleaned:
        return None
    parsed = urlsplit(cleaned)
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise ValueError("External links must use HTTPS")
    if parsed.username or parsed.password:
        raise ValueError("External links cannot contain credentials")
    hostname = parsed.hostname.rstrip(".").casefold()
    if hostname in {"localhost", "localhost.localdomain"} or hostname.endswith(
        (".local", ".internal", ".localhost")
    ):
        raise ValueError("External links must use a public host")
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        address = None
    if address is not None and not address.is_global:
        raise ValueError("External links must use a public host")
    if any(character in cleaned for character in ("\r", "\n", "\x00")):
        raise ValueError("External link is invalid")
    return cleaned


class CommitmentSourceInput(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    kind: Literal["document", "email", "share", "manual", "provider"]
    document_id: str | None = Field(default=None, min_length=1, max_length=64)
    label: str | None = Field(default=None, max_length=300)
    provider_reference: str | None = Field(default=None, max_length=300)
    source_url: str | None = Field(default=None, max_length=2_000)
    observed_at: str | None = Field(default=None, max_length=64)

    _safe_source_url = field_validator("source_url")(validate_safe_https_url)

    @field_validator("label", "provider_reference")
    @classmethod
    def clean_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        return cleaned or None

    @field_validator("observed_at")
    @classmethod
    def valid_observed_at(cls, value: str | None) -> str | None:
        if value is not None:
            _parse_temporal(value, label="Source observation time")
        return value

    @model_validator(mode="after")
    def source_has_provenance(self):
        if self.kind == "document" and not self.document_id:
            raise ValueError("Document sources require document_id")
        if self.kind != "document" and not (
            self.label or self.provider_reference or self.source_url
        ):
            raise ValueError("Source needs a label, provider reference or URL")
        return self


class CommitmentEventDraft(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    title: str = Field(min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    start_time: str = Field(min_length=1, max_length=64)
    end_time: str | None = Field(default=None, max_length=64)
    all_day: bool = False
    location: str | None = Field(default=None, max_length=500)
    person_ids: list[str] = Field(default_factory=list, max_length=20)
    affected_adult_ids: list[str] = Field(default_factory=list, max_length=10)
    assigned_to: str | None = Field(default=None, max_length=100)
    event_type: str = Field(default="other", min_length=1, max_length=50)
    document_ids: list[str] = Field(default_factory=list, max_length=20)

    _clean_title = field_validator("title")(_strip_required)

    @model_validator(mode="after")
    def valid_time_and_lists(self):
        start = _parse_temporal(self.start_time, label="Event start")
        start_is_datetime = isinstance(start, datetime)
        if self.all_day and start_is_datetime:
            raise ValueError("All-day event start must be a date without a time")
        if not self.all_day and not start_is_datetime:
            raise ValueError("Timed event start must include a time and timezone")
        if self.end_time:
            end = _parse_temporal(self.end_time, label="Event end")
            end_is_datetime = isinstance(end, datetime)
            if start_is_datetime != end_is_datetime:
                raise ValueError("Event start and end must use the same precision")
            if end <= start:
                raise ValueError("Event end must be after its start")
        for values, label in (
            (self.person_ids, "event people"),
            (self.affected_adult_ids, "affected adults"),
            (self.document_ids, "event documents"),
        ):
            if len(values) != len(set(values)):
                raise ValueError(f"Duplicate {label} are not allowed")
        if set(self.person_ids) & set(self.affected_adult_ids):
            raise ValueError("An attendee cannot also be an affected adult")
        return self


class CommitmentTaskDraft(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    title: str = Field(min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    due_date: str | None = Field(default=None, max_length=64)
    actionable_from: str | None = Field(default=None, max_length=64)
    assigned_to: str | None = Field(default=None, max_length=100)
    priority: int = Field(default=2, ge=1, le=3)
    document_id: str | None = Field(default=None, min_length=1, max_length=64)

    _clean_title = field_validator("title")(_strip_required)

    @model_validator(mode="after")
    def valid_task_times(self):
        due = _parse_temporal(self.due_date, label="Task due date") if self.due_date else None
        actionable = (
            _parse_temporal(self.actionable_from, label="Task actionable time")
            if self.actionable_from
            else None
        )
        if isinstance(due, datetime) or isinstance(actionable, datetime):
            raise ValueError("Task actionable and due dates must be date-only")
        if due is not None and actionable is not None:
            if actionable > due:
                raise ValueError("Task actionable time must not be after its due date")
        return self


class CommitmentPreparationDraft(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    event_id: UUID4
    name: str = Field(min_length=1, max_length=100)
    items: list[str] = Field(min_length=1, max_length=20)
    lead_hours: int = Field(default=24, ge=0, le=336)
    assigned_to: str | None = Field(default=None, max_length=100)

    _clean_name = field_validator("name")(_strip_required)

    @field_validator("items")
    @classmethod
    def clean_items(cls, values: list[str]) -> list[str]:
        cleaned = [value.strip() for value in values if value.strip()]
        if not cleaned:
            raise ValueError("Preparation needs at least one item")
        if any(len(value) > 300 for value in cleaned):
            raise ValueError("Preparation item is too long")
        if len(cleaned) != len({value.casefold() for value in cleaned}):
            raise ValueError("Duplicate preparation items are not allowed")
        return cleaned


class CommitmentExternalAction(BaseModel):
    kind: Literal["rsvp", "book", "register", "contact", "pay", "other"]
    label: str = Field(min_length=1, max_length=200)
    target_type: Literal["https", "email", "phone", "manual"]
    target: str = Field(min_length=1, max_length=2_000)
    due_at: str | None = Field(default=None, max_length=64)
    requires_completion_before_confirm: bool = True

    _clean_label = field_validator("label")(_strip_required)

    @model_validator(mode="after")
    def valid_target(self):
        target = self.target.strip()
        if self.target_type == "https":
            self.target = validate_safe_https_url(target) or ""
        elif self.target_type == "email":
            if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", target) or any(
                value in target for value in ("\r", "\n", "\x00")
            ):
                raise ValueError("Contact email is invalid")
            self.target = target
        elif self.target_type == "phone":
            if not re.fullmatch(r"\+?[0-9 ()-]{5,30}", target):
                raise ValueError("Contact phone number is invalid")
            self.target = target
        else:
            if not target:
                raise ValueError("Manual action instructions are required")
            self.target = target
        if self.due_at:
            _parse_temporal(self.due_at, label="External action deadline")
        return self


class CommitmentPlan(BaseModel):
    events: list[CommitmentEventDraft] = Field(default_factory=list, max_length=30)
    tasks: list[CommitmentTaskDraft] = Field(default_factory=list, max_length=50)
    preparations: list[CommitmentPreparationDraft] = Field(default_factory=list, max_length=20)
    external_action: CommitmentExternalAction | None = None

    @model_validator(mode="after")
    def valid_plan_links(self):
        event_ids = [str(item.id) for item in self.events]
        task_ids = [str(item.id) for item in self.tasks]
        prep_ids = [str(item.id) for item in self.preparations]
        for values, label in (
            (event_ids, "event draft IDs"),
            (task_ids, "task draft IDs"),
            (prep_ids, "preparation draft IDs"),
        ):
            if len(values) != len(set(values)):
                raise ValueError(f"Duplicate {label} are not allowed")
        missing = [
            str(item.event_id)
            for item in self.preparations
            if str(item.event_id) not in set(event_ids)
        ]
        if missing:
            raise ValueError("Preparation must refer to an event in the same plan")
        return self


def _validate_kind_plan(kind: CommitmentKind, plan: CommitmentPlan) -> None:
    issues = commitment_review_issues(kind, plan)
    if issues:
        raise ValueError(issues[0])


def commitment_review_issues(kind: CommitmentKind, plan: CommitmentPlan) -> list[str]:
    """Describe what a human must resolve before the plan can be confirmed."""
    issues: list[str] = []
    if kind == CommitmentKind.school and not (plan.events or plan.tasks or plan.preparations):
        issues.append("Add an event, action or preparation from the school message")
    if kind == CommitmentKind.invitation:
        if len(plan.events) != 1:
            issues.append("Add the invitation's date and time")
        if plan.external_action is None or plan.external_action.kind != "rsvp":
            issues.append("Add the RSVP instructions")
    if kind == CommitmentKind.outing and len(plan.events) != 1:
        issues.append("Choose one outing time")
    if kind == CommitmentKind.childcare and len(plan.events) != 1:
        issues.append("Add one childcare coverage event")
    if kind == CommitmentKind.appointment and len(plan.events) != 1:
        issues.append("Add the booked appointment time")
    if kind == CommitmentKind.travel and not plan.events:
        issues.append("Add at least one journey or stay")
    return issues


class CommitmentCreate(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    kind: CommitmentKind
    visibility: CommitmentVisibility = CommitmentVisibility.family
    title: str = Field(min_length=1, max_length=300)
    summary: str | None = Field(default=None, max_length=10_000)
    sources: list[CommitmentSourceInput] = Field(min_length=1, max_length=30)
    plan: CommitmentPlan
    group_key: str | None = Field(default=None, max_length=200)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)

    _clean_title = field_validator("title")(_strip_required)

    @model_validator(mode="after")
    def valid_kind_plan(self):
        source_ids = [str(source.id) for source in self.sources]
        if len(source_ids) != len(set(source_ids)):
            raise ValueError("Duplicate source IDs are not allowed")
        return self


class CommitmentUpdate(BaseModel):
    expected_revision: int = Field(ge=1)
    visibility: CommitmentVisibility | None = None
    title: str | None = Field(default=None, min_length=1, max_length=300)
    summary: str | None = Field(default=None, max_length=10_000)
    sources: list[CommitmentSourceInput] | None = Field(default=None, min_length=1, max_length=30)
    plan: CommitmentPlan | None = None
    group_key: str | None = Field(default=None, max_length=200)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)

    @field_validator("title")
    @classmethod
    def clean_title(cls, value: str | None) -> str | None:
        return _strip_required(value) if value is not None else None


class CommitmentConfirmRequest(BaseModel):
    expected_revision: int = Field(ge=1)
    confirmed: Literal[True]
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)


class CommitmentActionCompleteRequest(BaseModel):
    expected_revision: int = Field(ge=1)
    completed: Literal[True]
    outcome: Literal["accepted", "booked", "replied", "completed", "other"]
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)


class CommitmentDeclineRequest(BaseModel):
    expected_revision: int = Field(ge=1)
    reason: str | None = Field(default=None, max_length=1_000)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)


class CommitmentResultResponse(BaseModel):
    source_item_id: str
    result_type: Literal["calendar_event", "task", "preparation_task"]
    result_id: str


class CommitmentResponse(BaseModel):
    id: str
    kind: CommitmentKind
    visibility: CommitmentVisibility
    owner_user_id: str
    title: str
    summary: str | None = None
    status: CommitmentStatus
    revision: int
    sources: list[CommitmentSourceInput]
    plan: CommitmentPlan
    review_issues: list[str] = Field(default_factory=list)
    external_action_status: Literal["not_required", "pending", "completed", "declined"]
    external_action_outcome: str | None = None
    external_action_completed_at: str | None = None
    group_key: str | None = None
    interpretation_processor: Literal["typed", "fallback", "hermes"] | None = None
    supersedes_id: str | None = None
    change_summary: list[str] = Field(default_factory=list)
    confirmed_at: str | None = None
    declined_at: str | None = None
    results: list[CommitmentResultResponse] = Field(default_factory=list)
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class FreeWindowCandidate(BaseModel):
    id: str = Field(min_length=1, max_length=100)
    title: str = Field(min_length=1, max_length=300)
    available_start: str = Field(min_length=1, max_length=64)
    available_end: str = Field(min_length=1, max_length=64)
    duration_minutes: int = Field(ge=15, le=720)
    location: str | None = Field(default=None, max_length=500)
    booking_url: str | None = Field(default=None, max_length=2_000)

    _safe_booking_url = field_validator("booking_url")(validate_safe_https_url)
    _clean_title = field_validator("title")(_strip_required)

    @model_validator(mode="after")
    def valid_availability(self):
        start = _parse_temporal(self.available_start, label="Candidate start")
        end = _parse_temporal(self.available_end, label="Candidate end")
        if not isinstance(start, datetime) or not isinstance(end, datetime):
            raise ValueError("Candidate availability must include a time and timezone")
        if end <= start:
            raise ValueError("Candidate availability end must be after start")
        return self


class FreeWindowQuery(BaseModel):
    start_time: str = Field(min_length=1, max_length=64)
    end_time: str = Field(min_length=1, max_length=64)
    person_ids: list[str] = Field(min_length=1, max_length=10)
    minimum_minutes: int = Field(default=60, ge=15, le=720)
    candidates: list[FreeWindowCandidate] = Field(default_factory=list, max_length=50)
    timezone: str = Field(default="Europe/London", min_length=1, max_length=64)

    @model_validator(mode="after")
    def valid_window(self):
        start = _parse_temporal(self.start_time, label="Window start")
        end = _parse_temporal(self.end_time, label="Window end")
        if not isinstance(start, datetime) or not isinstance(end, datetime):
            raise ValueError("Window bounds must include a time and timezone")
        if end <= start:
            raise ValueError("Window end must be after start")
        if len(self.person_ids) != len(set(self.person_ids)):
            raise ValueError("Duplicate people are not allowed")
        return self


class FreeWindowResponse(BaseModel):
    start_time: str
    end_time: str
    duration_minutes: int


class ViableOutingResponse(BaseModel):
    candidate_id: str
    title: str
    proposed_start: str
    proposed_end: str
    location: str | None = None
    booking_url: str | None = None


class FreeWindowQueryResponse(BaseModel):
    windows: list[FreeWindowResponse]
    viable_outings: list[ViableOutingResponse]


class ChildcareGapResponse(BaseModel):
    date: str
    label: str
    source: Literal["explicit_holiday", "outside_term"]


class CommitmentFromSourceRequest(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    kind: CommitmentKind
    visibility: CommitmentVisibility = CommitmentVisibility.family
    text: str | None = Field(default=None, max_length=100_000)
    source_document_id: str | None = Field(default=None, min_length=1, max_length=64)
    source_label: str | None = Field(default=None, max_length=300)
    provider_reference: str | None = Field(default=None, max_length=300)
    title: str | None = Field(default=None, max_length=300)
    use_hermes: bool = False
    client_now: str | None = Field(default=None, max_length=64)
    timezone: str = Field(default="Europe/London", min_length=1, max_length=64)
    supersedes_id: UUID4 | None = None
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)

    @field_validator("text", "source_label", "provider_reference", "title")
    @classmethod
    def clean_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        return cleaned or None

    @model_validator(mode="after")
    def source_present(self):
        if not self.text and not self.source_document_id:
            raise ValueError("Add reviewed text or a source document")
        return self


class CommitmentFromSourceResponse(BaseModel):
    commitment: CommitmentResponse
    processor: Literal["fallback", "hermes"]
    warning: str | None = None
    deduplicated: bool = False
    material_changes: list[str] = Field(default_factory=list)
