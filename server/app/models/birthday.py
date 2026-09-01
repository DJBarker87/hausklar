from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.services.birthdays import family_today


class BirthdayFields(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    date_of_birth: str | None = Field(default=None, min_length=10, max_length=10)
    birth_month: int | None = Field(default=None, ge=1, le=12)
    birth_day: int | None = Field(default=None, ge=1, le=31)

    @field_validator("date_of_birth", check_fields=False)
    @classmethod
    def valid_date_of_birth(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            parsed = date.fromisoformat(value)
        except ValueError as exc:
            raise ValueError("Date of birth must use YYYY-MM-DD") from exc
        if parsed.isoformat() != value:
            raise ValueError("Date of birth must use YYYY-MM-DD")
        if parsed > family_today():
            raise ValueError("Date of birth cannot be in the future")
        return value

    @model_validator(mode="after")
    def valid_month_and_day(self):
        if (self.birth_month is None) != (self.birth_day is None):
            raise ValueError("Birth month and day must be supplied together")
        if self.birth_month is not None and self.birth_day is not None:
            try:
                date(2000, self.birth_month, self.birth_day)
            except ValueError as exc:
                raise ValueError("That birthday date does not exist") from exc
        if self.date_of_birth and self.birth_month is not None:
            parsed = date.fromisoformat(self.date_of_birth)
            if (parsed.month, parsed.day) != (self.birth_month, self.birth_day):
                raise ValueError("Date of birth and month/day do not match")
        return self


class BirthdayCreate(BirthdayFields):
    person_name: str = Field(min_length=1, max_length=200)
    relationship: str = Field(default="friend", min_length=1, max_length=100)
    reminder_days_before: int = Field(default=7, ge=0, le=365)
    allow_duplicate: bool = False
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)

    @model_validator(mode="after")
    def has_a_birthday(self):
        if self.date_of_birth is None and self.birth_month is None:
            raise ValueError("Add the birthday's month and day")
        return self


class BirthdayUpdate(BirthdayFields):
    person_name: str | None = Field(default=None, min_length=1, max_length=200)
    relationship: str | None = Field(default=None, min_length=1, max_length=100)
    reminder_days_before: int | None = Field(default=None, ge=0, le=365)
    allow_duplicate: bool = False
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=64)


class BirthdayResponse(BaseModel):
    id: str
    person_name: str
    date_of_birth: str | None
    birth_month: int
    birth_day: int
    year_known: bool
    relationship: str
    reminder_days_before: int
    age: int | None
    turning_age: int | None
    next_birthday: str
    days_until: int
    preparation_due: bool
    client_id: str | None = None
    client_timestamp: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None


class BirthdayImportPreviewRequest(BaseModel):
    text: str = Field(min_length=1, max_length=20_000)


class BirthdayImportDraft(BaseModel):
    line_number: int
    source_line: str
    person_name: str | None = None
    date_of_birth: str | None = None
    birth_month: int | None = None
    birth_day: int | None = None
    duplicate_id: str | None = None
    issue: str | None = None


class BirthdayImportPreviewResponse(BaseModel):
    drafts: list[BirthdayImportDraft]


class BirthdayPreparationUpdate(BaseModel):
    card_status: Literal["not_started", "to_buy", "bought", "written", "sent"] | None = None
    card_message: str | None = Field(default=None, max_length=2_000)
    celebration_status: Literal["not_started", "planning", "planned"] | None = None
    notes: str | None = Field(default=None, max_length=4_000)


class BirthdayPreparationTaskCreate(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    assigned_to: str | None = Field(default=None, max_length=100)
    due_days_before: int = Field(default=7, ge=0, le=365)


class BirthdayPreparationEventCreate(BaseModel):
    title: str | None = Field(default=None, max_length=300)
    location: str | None = Field(default=None, max_length=500)


class BirthdayPreparationLinkedItem(BaseModel):
    id: str
    title: str
    completed: bool = False


class BirthdayPreparationResponse(BaseModel):
    birthday: BirthdayResponse
    occurrence_year: int
    card_status: str = "not_started"
    card_message: str | None = None
    celebration_status: str = "not_started"
    notes: str | None = None
    tasks: list[BirthdayPreparationLinkedItem] = []
    calendar_event: BirthdayPreparationLinkedItem | None = None
    gifts_total: int = 0
    gifts_remaining: int = 0
