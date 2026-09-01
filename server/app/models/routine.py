from datetime import date, time
from enum import Enum

from pydantic import BaseModel, Field, field_validator, model_validator


# --- Routine Items ---


class RoutineItemCreate(BaseModel):
    person_id: str
    name: str
    color: str
    days_of_week: list[int]
    sort_order: int = 0
    time_of_day: str | None = None
    location: str | None = Field(default=None, max_length=300)
    preparation_note: str | None = Field(default=None, max_length=1_000)
    prep_template_id: str | None = Field(default=None, max_length=100)
    reminder_minutes: int | None = Field(default=None, ge=0, le=10_080)
    calendar_projection: bool = True
    term_only: bool = True
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("time_of_day")
    @classmethod
    def validate_time_of_day(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        try:
            parsed = time.fromisoformat(value)
        except ValueError as exc:
            raise ValueError("Routine time must use HH:MM") from exc
        return parsed.strftime("%H:%M")


class RoutineItemUpdate(BaseModel):
    name: str | None = None
    color: str | None = None
    days_of_week: list[int] | None = None
    sort_order: int | None = None
    time_of_day: str | None = None
    location: str | None = Field(default=None, max_length=300)
    preparation_note: str | None = Field(default=None, max_length=1_000)
    prep_template_id: str | None = Field(default=None, max_length=100)
    reminder_minutes: int | None = Field(default=None, ge=0, le=10_080)
    calendar_projection: bool | None = None
    term_only: bool | None = None
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("time_of_day")
    @classmethod
    def validate_time_of_day(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        try:
            parsed = time.fromisoformat(value)
        except ValueError as exc:
            raise ValueError("Routine time must use HH:MM") from exc
        return parsed.strftime("%H:%M")


class RoutineItemResponse(BaseModel):
    id: str
    person_id: str
    name: str
    color: str
    days_of_week: list[int]
    sort_order: int
    time_of_day: str | None = None
    location: str | None = None
    preparation_note: str | None = None
    prep_template_id: str | None = None
    reminder_minutes: int | None = None
    calendar_projection: bool = True
    term_only: bool = True
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


# --- Term Dates ---


def _canonical_iso_date(value: str) -> str:
    try:
        parsed = date.fromisoformat(value)
    except ValueError as exc:
        raise ValueError("Date must use YYYY-MM-DD format") from exc
    if parsed.isoformat() != value:
        raise ValueError("Date must use YYYY-MM-DD format")
    return value


class TermDateCreate(BaseModel):
    person_id: str
    label: str | None = None
    start_date: str
    end_date: str
    client_id: str | None = None
    client_timestamp: str | None = None

    _validate_dates = field_validator("start_date", "end_date")(_canonical_iso_date)

    @model_validator(mode="after")
    def validate_range(self):
        if self.end_date < self.start_date:
            raise ValueError("Term end date must be on or after its start date")
        return self


class TermDateUpdate(BaseModel):
    label: str | None = None
    start_date: str | None = None
    end_date: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None

    _validate_dates = field_validator("start_date", "end_date")(_canonical_iso_date)

    @model_validator(mode="after")
    def validate_range(self):
        if (
            self.start_date is not None
            and self.end_date is not None
            and self.end_date < self.start_date
        ):
            raise ValueError("Term end date must be on or after its start date")
        return self


class TermDateResponse(BaseModel):
    id: str
    person_id: str
    label: str | None = None
    start_date: str
    end_date: str
    created_at: str
    updated_at: str
    created_by: str | None = None
    is_imported: bool = False
    is_overridden: bool = False
    client_id: str | None = None
    client_timestamp: str | None = None


# --- Term Override ---


class TermOverrideSet(BaseModel):
    is_active: bool
    expires_on: str | None = None

    @field_validator("expires_on")
    @classmethod
    def validate_expiry(cls, value: str | None) -> str | None:
        return None if value is None else _canonical_iso_date(value)


class TermOverrideResponse(BaseModel):
    person_id: str
    mode: str  # "auto", "force_on", "force_off"
    expires_on: str | None = None


# --- Active Routines ---


class ActiveRoutineResponse(BaseModel):
    routine_item_id: str
    person_id: str
    person_name: str
    name: str
    color: str
    date: str
    time_of_day: str | None = None
    location: str | None = None
    preparation_note: str | None = None
    prep_template_id: str | None = None
    reminder_minutes: int | None = None


class RoutineItemDuplicate(BaseModel):
    target_person_id: str = Field(min_length=1, max_length=100)


# --- Holiday Dates ---


class HolidayDateCreate(BaseModel):
    person_id: str
    date: str  # YYYY-MM-DD
    label: str | None = None


class HolidayDateResponse(BaseModel):
    id: str
    person_id: str
    date: str
    label: str | None = None
    created_at: str
    updated_at: str


# --- Term Status ---


class TermStatusEntry(BaseModel):
    person_id: str
    in_term: bool


class TermStatusResponse(BaseModel):
    statuses: list[TermStatusEntry]
    all_same: bool


# --- Term-time handoffs ---


class HandoffKind(str, Enum):
    pickup = "pickup"
    work_departure = "work_departure"


def _canonical_time(value: str) -> str:
    try:
        parsed = time.fromisoformat(value)
    except ValueError as exc:
        raise ValueError("Time must use HH:MM") from exc
    return parsed.strftime("%H:%M")


class HandoffScheduleItem(BaseModel):
    kind: HandoffKind
    weekday: int = Field(ge=0, le=6)
    time_of_day: str
    term_person_id: str = Field(min_length=1, max_length=100)
    # Work departures are tied to their adult. Pickup responsibility is
    # deliberately not assigned; older clients may still send this field and
    # the service safely ignores it for pickups.
    owner_user_id: str | None = Field(default=None, min_length=1, max_length=100)

    _validate_time = field_validator("time_of_day")(_canonical_time)


class HandoffScheduleUpdate(BaseModel):
    items: list[HandoffScheduleItem] = Field(default_factory=list, max_length=70)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def unique_person_kind_and_weekday(self):
        identities = [
            (item.kind, item.weekday, item.term_person_id) for item in self.items
        ]
        if len(identities) != len(set(identities)):
            raise ValueError("Each person can have only one handoff of each kind per weekday")
        return self


class HandoffScheduleItemResponse(BaseModel):
    id: str
    kind: HandoffKind
    weekday: int
    time_of_day: str
    term_person_id: str
    # Compatibility display identity for older clients. For pickups this is
    # the child, never an adult responsibility stored against the row.
    owner_user_id: str
    created_at: str
    updated_at: str


class HandoffScheduleResponse(BaseModel):
    items: list[HandoffScheduleItemResponse] = Field(default_factory=list)


class HandoffOccurrenceResponse(BaseModel):
    id: str
    handoff_id: str
    kind: HandoffKind
    date: str
    time_of_day: str
    term_person_id: str
    term_person_name: str
    # Compatibility display identity. Pickup occurrences expose their child
    # here so older clients render a child lane without assigning an adult.
    owner_user_id: str
    owner_name: str
    label: str
    is_override: bool = False


class HandoffOccurrenceUpdate(BaseModel):
    time_of_day: str
    owner_user_id: str | None = Field(default=None, min_length=1, max_length=100)
    is_cancelled: bool = False
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    _validate_time = field_validator("time_of_day")(_canonical_time)
