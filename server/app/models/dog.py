from datetime import date, datetime, timezone
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

DogActivityType = Literal[
    "walk",
    "feed",
    "feed_breakfast",
    "feed_dinner",
    "vet",
    "medication",
]
DogCareState = Literal["upcoming", "due", "overdue", "done"]
DogDocumentRole = Literal["insurance", "vet", "microchip", "medicine", "other"]


class DogActivityCreate(BaseModel):
    activity_type: DogActivityType
    started_at: str = Field(min_length=1, max_length=64)
    ended_at: str | None = Field(default=None, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    is_active: bool = False
    client_id: str | None = None
    client_timestamp: str | None = None

    @model_validator(mode="after")
    def times_are_valid_and_ordered(self):
        self.started_at = _normalise_activity_time(self.started_at, "Start time")
        if self.ended_at is not None:
            self.ended_at = _normalise_activity_time(self.ended_at, "End time")
            if datetime.fromisoformat(self.ended_at) < datetime.fromisoformat(self.started_at):
                raise ValueError("End time cannot be before start time")
        if self.is_active and self.activity_type != "walk":
            raise ValueError("Only a walk can be tracked live")
        if self.is_active and self.ended_at is not None:
            raise ValueError("A live walk cannot already have an end time")
        return self


class DogActivityUpdate(BaseModel):
    activity_type: DogActivityType | None = None
    started_at: str | None = Field(default=None, min_length=1, max_length=64)
    ended_at: str | None = Field(default=None, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    is_active: bool | None = None
    client_id: str | None = None
    client_timestamp: str | None = None

    @model_validator(mode="after")
    def times_are_valid_and_ordered(self):
        if self.started_at is not None:
            self.started_at = _normalise_activity_time(self.started_at, "Start time")
        if self.ended_at is not None:
            self.ended_at = _normalise_activity_time(self.ended_at, "End time")
        if self.started_at is not None and self.ended_at is not None:
            if datetime.fromisoformat(self.ended_at) < datetime.fromisoformat(self.started_at):
                raise ValueError("End time cannot be before start time")
        return self


def _normalise_activity_time(value: str, label: str) -> str:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"{label} must be a valid date and time") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat()


class DogActivityResponse(BaseModel):
    id: str
    activity_type: str
    started_at: str
    ended_at: str | None = None
    notes: str | None = None
    is_active: bool = False
    done_by: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class DogStatusResponse(BaseModel):
    walked_today: bool
    fed_breakfast_today: bool
    fed_dinner_today: bool
    last_walk: DogActivityResponse | None = None
    last_feed_breakfast: DogActivityResponse | None = None
    last_feed_dinner: DogActivityResponse | None = None
    active_walk: DogActivityResponse | None = None
    dog_name: str = "Dog"
    walk_state: DogCareState = "upcoming"
    breakfast_state: DogCareState = "upcoming"
    dinner_state: DogCareState = "upcoming"


class DogProfileUpdate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    name: str | None = Field(default=None, min_length=1, max_length=80)
    date_of_birth: str | None = Field(default=None, max_length=10)
    breed: str | None = Field(default=None, max_length=120)
    microchip_number: str | None = Field(default=None, max_length=80)
    insurance_provider: str | None = Field(default=None, max_length=160)
    insurance_policy_number: str | None = Field(default=None, max_length=120)
    vet_name: str | None = Field(default=None, max_length=160)
    vet_phone: str | None = Field(default=None, max_length=80)
    allergies: str | None = Field(default=None, max_length=2_000)
    medicine_notes: str | None = Field(default=None, max_length=2_000)
    breakfast_window_start: str | None = Field(default=None, max_length=5)
    breakfast_window_end: str | None = Field(default=None, max_length=5)
    walk_window_start: str | None = Field(default=None, max_length=5)
    walk_window_end: str | None = Field(default=None, max_length=5)
    dinner_window_start: str | None = Field(default=None, max_length=5)
    dinner_window_end: str | None = Field(default=None, max_length=5)
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator(
        "breed",
        "microchip_number",
        "insurance_provider",
        "insurance_policy_number",
        "vet_name",
        "vet_phone",
        "allergies",
        "medicine_notes",
        mode="before",
    )
    @classmethod
    def blank_strings_are_empty(cls, value):
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @field_validator("date_of_birth")
    @classmethod
    def valid_birth_date(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            parsed = date.fromisoformat(value)
        except ValueError as exc:
            raise ValueError("Date of birth must use YYYY-MM-DD") from exc
        if parsed.isoformat() != value or parsed > date.today():
            raise ValueError("Date of birth must be a valid past date")
        return value

    @field_validator(
        "breakfast_window_start",
        "breakfast_window_end",
        "walk_window_start",
        "walk_window_end",
        "dinner_window_start",
        "dinner_window_end",
    )
    @classmethod
    def valid_local_time(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            parsed = datetime.strptime(value, "%H:%M")
        except ValueError as exc:
            raise ValueError("Care times must use HH:MM") from exc
        return parsed.strftime("%H:%M")


class DogProfileResponse(BaseModel):
    id: str | None = None
    name: str = "Dog"
    date_of_birth: str | None = None
    breed: str | None = None
    microchip_number: str | None = None
    insurance_provider: str | None = None
    insurance_policy_number: str | None = None
    vet_name: str | None = None
    vet_phone: str | None = None
    allergies: str | None = None
    medicine_notes: str | None = None
    breakfast_window_start: str = "07:00"
    breakfast_window_end: str = "09:00"
    walk_window_start: str = "10:00"
    walk_window_end: str = "14:00"
    dinner_window_start: str = "17:00"
    dinner_window_end: str = "19:00"
    created_at: str | None = None
    updated_at: str | None = None


class DogWeightCreate(BaseModel):
    measured_on: str = Field(min_length=10, max_length=10)
    weight_kg: float = Field(gt=0, le=200)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("measured_on")
    @classmethod
    def valid_measurement_date(cls, value: str) -> str:
        try:
            parsed = date.fromisoformat(value)
        except ValueError as exc:
            raise ValueError("Measurement date must use YYYY-MM-DD") from exc
        if parsed.isoformat() != value or parsed > date.today():
            raise ValueError("Measurement date must be a valid past date")
        return value


class DogWeightUpdate(BaseModel):
    measured_on: str | None = Field(default=None, min_length=10, max_length=10)
    weight_kg: float | None = Field(default=None, gt=0, le=200)
    notes: str | None = Field(default=None, max_length=2_000)

    @field_validator("measured_on")
    @classmethod
    def valid_measurement_date(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return DogWeightCreate.valid_measurement_date(value)


class DogWeightResponse(BaseModel):
    id: str
    measured_on: str
    weight_kg: float
    notes: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None


class DogDocumentLinkCreate(BaseModel):
    document_id: str = Field(min_length=1, max_length=64)
    role: DogDocumentRole = "other"


class DogDocumentLinkResponse(BaseModel):
    id: str
    document_id: str
    role: DogDocumentRole
    title: str
    original_filename: str
    media_type: str
    file_size: int
    download_url: str


class DogVaccinationCreate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    vaccine_name: str = Field(min_length=1, max_length=120)
    given_on: str = Field(min_length=1, max_length=32)
    next_due_on: str | None = Field(default=None, min_length=1, max_length=32)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None

    @model_validator(mode="after")
    def dates_are_valid_and_ordered(self):
        try:
            given = date.fromisoformat(self.given_on)
            next_due = date.fromisoformat(self.next_due_on) if self.next_due_on else None
        except ValueError as exc:
            raise ValueError("Vaccination dates must use YYYY-MM-DD") from exc
        if given.isoformat() != self.given_on or (
            next_due is not None and next_due.isoformat() != self.next_due_on
        ):
            raise ValueError("Vaccination dates must use YYYY-MM-DD")
        if given > date.today():
            raise ValueError("Given date cannot be in the future")
        if next_due is not None and next_due < given:
            raise ValueError("Next due date cannot be before the given date")
        return self


class DogVaccinationUpdate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    vaccine_name: str | None = Field(default=None, min_length=1, max_length=120)
    given_on: str | None = Field(default=None, min_length=1, max_length=32)
    next_due_on: str | None = Field(default=None, max_length=32)
    notes: str | None = Field(default=None, max_length=2_000)


class DogVaccinationResponse(BaseModel):
    id: str
    vaccine_name: str
    given_on: str
    next_due_on: str | None = None
    notes: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None
