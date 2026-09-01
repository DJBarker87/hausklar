from datetime import date, datetime
from typing import Annotated, Literal
from urllib.parse import urlparse

from pydantic import BaseModel, Field, field_validator, model_validator

from app.models.document import LinkedDocumentResponse

SpellingWord = Annotated[str, Field(min_length=1, max_length=100)]


def _validate_date_only(value: str) -> str:
    try:
        return date.fromisoformat(value).isoformat()
    except ValueError as exc:
        raise ValueError("must be a valid date in YYYY-MM-DD format") from exc


def _optional_web_link(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    if not value:
        return None
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("must be a valid http or https link")
    return value


# ---------------------------------------------------------------------------
# Reading logs
# ---------------------------------------------------------------------------


class ReadingLogCreate(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    book_title: str = Field(min_length=1, max_length=300)
    minutes: int = Field(ge=1, le=600)
    date: str = Field(min_length=1, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("book_title")
    @classmethod
    def clean_book_title(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("book title must not be blank")
        return value

    @field_validator("date")
    @classmethod
    def valid_date(cls, value: str) -> str:
        return _validate_date_only(value)


class ReadingLogUpdate(BaseModel):
    book_title: str | None = Field(default=None, min_length=1, max_length=300)
    minutes: int | None = Field(default=None, ge=1, le=600)
    date: str | None = Field(default=None, min_length=1, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("book_title")
    @classmethod
    def clean_book_title(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        if not value:
            raise ValueError("book title must not be blank")
        return value

    @field_validator("date")
    @classmethod
    def valid_date(cls, value: str | None) -> str | None:
        return _validate_date_only(value) if value is not None else None


class ReadingLogResponse(BaseModel):
    id: str
    child_id: str
    book_title: str
    minutes: int
    date: str
    notes: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


# ---------------------------------------------------------------------------
# Spellings
# ---------------------------------------------------------------------------


class SpellingsCreate(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    word_list: list[SpellingWord] = Field(min_length=1, max_length=100)
    test_date: str = Field(min_length=1, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    link_url: str | None = Field(default=None, max_length=2_000)
    source_document_id: str | None = Field(default=None, max_length=64)
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("word_list")
    @classmethod
    def clean_words(cls, value: list[str]) -> list[str]:
        cleaned = [word.strip() for word in value]
        if any(not word for word in cleaned):
            raise ValueError("spelling words must not be blank")
        if len({word.casefold() for word in cleaned}) != len(cleaned):
            raise ValueError("spelling words must not contain duplicates")
        return cleaned

    @field_validator("test_date")
    @classmethod
    def valid_test_date(cls, value: str) -> str:
        return _validate_date_only(value)

    @field_validator("link_url")
    @classmethod
    def valid_link(cls, value: str | None) -> str | None:
        return _optional_web_link(value)


class SpellingsUpdate(BaseModel):
    word_list: list[SpellingWord] | None = Field(default=None, min_length=1, max_length=100)
    test_date: str | None = Field(default=None, min_length=1, max_length=64)
    score: int | None = Field(default=None, ge=0)
    practice_count: int | None = Field(default=None, ge=0, le=10_000)
    notes: str | None = Field(default=None, max_length=2_000)
    link_url: str | None = Field(default=None, max_length=2_000)
    source_document_id: str | None = Field(default=None, max_length=64)
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("word_list")
    @classmethod
    def clean_words(cls, value: list[str] | None) -> list[str] | None:
        if value is None:
            return None
        cleaned = [word.strip() for word in value]
        if any(not word for word in cleaned):
            raise ValueError("spelling words must not be blank")
        if len({word.casefold() for word in cleaned}) != len(cleaned):
            raise ValueError("spelling words must not contain duplicates")
        return cleaned

    @field_validator("test_date")
    @classmethod
    def valid_test_date(cls, value: str | None) -> str | None:
        return _validate_date_only(value) if value is not None else None

    @field_validator("link_url")
    @classmethod
    def valid_link(cls, value: str | None) -> str | None:
        return _optional_web_link(value)


class SpellingAttempt(BaseModel):
    word: SpellingWord
    correct: bool

    @field_validator("word")
    @classmethod
    def clean_word(cls, value: str) -> str:
        return value.strip()


class SpellingPracticeCreate(BaseModel):
    attempts: list[SpellingAttempt] = Field(min_length=1, max_length=100)
    practised_at: str | None = Field(default=None, max_length=64)

    @model_validator(mode="after")
    def unique_words(self):
        words = [attempt.word.casefold() for attempt in self.attempts]
        if len(set(words)) != len(words):
            raise ValueError("a word can only be recorded once per practice")
        if self.practised_at:
            try:
                datetime_value = self.practised_at.replace("Z", "+00:00")
                datetime.fromisoformat(datetime_value)
            except ValueError as exc:
                raise ValueError("practised_at must be an ISO 8601 timestamp") from exc
        return self


class SpellingCompleteRequest(BaseModel):
    score: int | None = Field(default=None, ge=0)


class SpellingPracticeResponse(BaseModel):
    id: str
    practised_at: str
    attempts: list[SpellingAttempt]
    correct_count: int
    total_count: int


class SpellingWordMastery(BaseModel):
    word: str
    attempts: int
    correct_attempts: int
    mastered: bool
    needs_practice: bool


class SpellingsResponse(BaseModel):
    id: str
    child_id: str
    word_list: list[str]
    test_date: str
    score: int | None = None
    practice_count: int = 0
    completed_at: str | None = None
    notes: str | None = None
    link_url: str | None = None
    source_document_id: str | None = None
    source_document: LinkedDocumentResponse | None = None
    status: Literal["upcoming", "due", "overdue", "completed"]
    practice_sessions: list[SpellingPracticeResponse] = Field(default_factory=list)
    mastery: list[SpellingWordMastery] = Field(default_factory=list)
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None
