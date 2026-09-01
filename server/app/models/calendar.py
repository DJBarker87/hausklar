from enum import Enum
from typing import Literal
from uuid import uuid4

from pydantic import UUID4, BaseModel, Field, field_validator

from app.models.document import LinkedDocumentResponse
from app.models.managed_projection import ManagedSource


def _validate_recurrence_rule(value: str | None) -> str | None:
    if value is None:
        return None
    rule = value.strip().upper()
    if not rule:
        return None
    if len(rule) > 500:
        raise ValueError("Recurrence rule is too long")
    parts = {}
    for component in rule.split(";"):
        key, separator, item = component.partition("=")
        if not separator or not key or not item:
            raise ValueError("Recurrence rule is invalid")
        parts[key] = item
    if parts.get("FREQ") not in {"DAILY", "WEEKLY", "MONTHLY", "YEARLY"}:
        raise ValueError("Recurrence frequency must be daily, weekly, monthly or yearly")
    if "INTERVAL" in parts:
        try:
            interval = int(parts["INTERVAL"])
        except ValueError as exc:
            raise ValueError("Recurrence interval is invalid") from exc
        if interval < 1 or interval > 365:
            raise ValueError("Recurrence interval must be between 1 and 365")
    if "COUNT" in parts:
        try:
            count = int(parts["COUNT"])
        except ValueError as exc:
            raise ValueError("Recurrence count is invalid") from exc
        if count < 1 or count > 10_000:
            raise ValueError("Recurrence count must be between 1 and 10000")
    return rule


class CalendarEventAttachmentRole(str, Enum):
    ticket = "ticket"
    booking = "booking"
    school_letter = "school_letter"
    insurance = "insurance"
    other = "other"


class CalendarEventAttachmentInput(BaseModel):
    document_id: str = Field(min_length=1, max_length=64)
    role: CalendarEventAttachmentRole = CalendarEventAttachmentRole.other


class CalendarEventAttachmentResponse(LinkedDocumentResponse):
    relation_id: str
    role: CalendarEventAttachmentRole
    position: int = Field(ge=0)


class CalendarEventCreate(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    title: str = Field(min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    start_time: str = Field(min_length=1, max_length=64)
    end_time: str | None = Field(default=None, max_length=64)
    all_day: bool = False
    recurrence_rule: str | None = Field(default=None, max_length=500)
    location: str | None = Field(default=None, max_length=500)
    family_member_ids: list[str] | None = Field(default=None, max_length=20)
    affected_member_ids: list[str] | None = Field(default=None, max_length=10)
    assigned_to: str | None = Field(default=None, max_length=100)
    event_type: str | None = Field(default="other", max_length=50)
    exertion: int = Field(default=0, ge=0, le=3)
    source_document_id: str | None = Field(default=None, max_length=64)
    attachments: list[CalendarEventAttachmentInput] | None = Field(
        default=None,
        max_length=20,
    )
    client_id: str | None = None
    client_timestamp: str | None = None

    _normalise_recurrence = field_validator("recurrence_rule")(_validate_recurrence_rule)


class CalendarEventUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    start_time: str | None = Field(default=None, max_length=64)
    end_time: str | None = Field(default=None, max_length=64)
    all_day: bool | None = None
    recurrence_rule: str | None = Field(default=None, max_length=500)
    location: str | None = Field(default=None, max_length=500)
    family_member_ids: list[str] | None = Field(default=None, max_length=20)
    affected_member_ids: list[str] | None = Field(default=None, max_length=10)
    assigned_to: str | None = Field(default=None, max_length=100)
    event_type: str | None = Field(default=None, max_length=50)
    exertion: int | None = Field(default=None, ge=0, le=3)
    source_document_id: str | None = Field(default=None, max_length=64)
    attachments: list[CalendarEventAttachmentInput] | None = Field(
        default=None,
        max_length=20,
    )
    client_id: str | None = None
    client_timestamp: str | None = None

    _normalise_recurrence = field_validator("recurrence_rule")(_validate_recurrence_rule)


class CalendarRecurrenceMutationScope(str, Enum):
    only_this = "only_this"
    this_and_later = "this_and_later"
    entire_series = "entire_series"


class CalendarOccurrenceUpdate(BaseModel):
    scope: CalendarRecurrenceMutationScope
    occurrence_start: str = Field(min_length=1, max_length=64)
    updates: CalendarEventUpdate


class CalendarOccurrenceDelete(BaseModel):
    scope: CalendarRecurrenceMutationScope
    occurrence_start: str = Field(min_length=1, max_length=64)
    client_id: str | None = None
    client_timestamp: str | None = None


class CalendarEventResponse(BaseModel):
    id: str
    title: str
    description: str | None = None
    start_time: str
    end_time: str | None = None
    all_day: bool = False
    recurrence_rule: str | None = None
    location: str | None = None
    family_member_ids: list[str] | None = None
    affected_member_ids: list[str] | None = None
    assigned_to: str | None = None
    event_type: str | None = "other"
    exertion: int = Field(default=0, ge=0, le=3)
    client_id: str | None = None
    client_timestamp: str | None = None
    series_id: str | None = None
    is_generated_occurrence: bool = False
    calendar_source_id: str | None = None
    source_name: str | None = None
    source_color: str | None = None
    rugby_venue: Literal["home", "away"] | None = None
    rugby_venue_overridden: bool = False
    read_only: bool = False
    overridden_event_id: str | None = None
    source_document_id: str | None = None
    source_document: LinkedDocumentResponse | None = None
    attachments: list[CalendarEventAttachmentResponse] = Field(default_factory=list)
    created_at: str
    updated_at: str
    created_by: str | None = None
    managed_source: ManagedSource | None = None


class CalendarSourceCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    url: str = Field(min_length=12, max_length=4_096)
    assigned_to: str | None = Field(default=None, max_length=100)
    color: str = Field(default="#2563EB", pattern=r"^#[0-9A-Fa-f]{6}$")


class CalendarSourceValidationResponse(BaseModel):
    valid: bool = True
    hostname: str
    event_count: int


class CalendarSourceUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    url: str | None = Field(default=None, min_length=12, max_length=4_096)
    assigned_to: str | None = Field(default=None, max_length=100)
    color: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")
    enabled: bool | None = None


class CalendarSourceResponse(BaseModel):
    id: str
    name: str
    hostname: str
    assigned_to: str | None = None
    color: str
    enabled: bool
    last_synced_at: str | None = None
    last_success_at: str | None = None
    last_error: str | None = None
    created_at: str
    updated_at: str


class CalendarSourceSyncResponse(BaseModel):
    source_id: str
    events: int
    changed: int
    removed: int
    unchanged: bool = False


class SchoolRugbyTeamOption(BaseModel):
    id: str = Field(pattern=r"^\d{1,20}$")
    name: str = Field(min_length=1, max_length=100)


class SchoolRugbyTeamListResponse(BaseModel):
    season: str = Field(pattern=r"^\d{4}/\d{2}$")
    teams: list[SchoolRugbyTeamOption]


class SchoolRugbySettingsUpdate(BaseModel):
    team_id: str = Field(pattern=r"^\d{1,20}$")


class SchoolRugbySettingsResponse(BaseModel):
    configured: bool = False
    source_id: str | None = None
    team_id: str | None = None
    team_name: str | None = None
    season: str | None = None
    owner_user_id: str | None = None
    owner_name: str | None = None
    affected_user_ids: list[str] = Field(default_factory=list)
    affected_names: list[str] = Field(default_factory=list)
    fixture_count: int = 0
    last_synced_at: str | None = None
    last_success_at: str | None = None
    last_error: str | None = None


class SchoolRugbyVenueUpdate(BaseModel):
    venue: Literal["home", "away"]
    client_id: str | None = Field(default=None, max_length=200)
    client_timestamp: str | None = Field(default=None, max_length=64)


class CalendarFeedStatus(BaseModel):
    configured: bool
    token_prefix: str | None = None
    feed_url: str | None = None


class CalendarFeedCreated(CalendarFeedStatus):
    token: str
