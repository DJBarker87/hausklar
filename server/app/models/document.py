from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator


DocumentSource = Literal["scan", "photo", "file", "text", "share"]
DocumentCategory = Literal[
    "school",
    "medical",
    "childcare",
    "identity",
    "finance",
    "activities",
    "household",
    "other",
]
DocumentStatus = Literal["inbox", "filed", "archived", "failed"]
SuggestionKind = Literal["event", "task"]
SuggestionStatus = Literal["pending", "accepted", "dismissed"]
SuggestionResultStatus = Literal[
    "pending",
    "dismissed",
    "open",
    "completed",
    "scheduled",
    "unavailable",
]


class DocumentPersonResponse(BaseModel):
    id: str
    person_id: str
    person_name: str
    person_type: Literal["user", "child"]


class LinkedDocumentResponse(BaseModel):
    """Small, safe document projection embedded in linked records."""

    id: str
    title: str
    original_filename: str
    media_type: str
    file_size: int
    download_url: str


class LinkedEventResponse(BaseModel):
    id: str
    title: str
    start_time: str
    end_time: str | None = None
    all_day: bool = False


class LinkedTaskResponse(BaseModel):
    id: str
    title: str
    due_date: str | None = None
    completed_at: str | None = None


class CaptureSuggestionCreate(BaseModel):
    id: str | None = None
    kind: SuggestionKind
    title: str = Field(min_length=1, max_length=300)
    details: str | None = Field(default=None, max_length=10_000)
    start_time: str | None = None
    end_time: str | None = None
    due_date: str | None = None
    all_day: bool = True
    assigned_to: str | None = None
    confidence: float = Field(default=0.5, ge=0, le=1)
    source_text: str | None = Field(default=None, max_length=2_000)

    @field_validator("title")
    @classmethod
    def strip_title(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("title must not be blank")
        return value

    @model_validator(mode="after")
    def validate_kind_date(self):
        if self.kind == "event" and not self.start_time:
            raise ValueError("event suggestions require start_time")
        return self


class CaptureSuggestionUpdate(BaseModel):
    kind: SuggestionKind | None = None
    title: str | None = Field(default=None, min_length=1, max_length=300)
    details: str | None = Field(default=None, max_length=10_000)
    start_time: str | None = None
    end_time: str | None = None
    due_date: str | None = None
    all_day: bool | None = None
    assigned_to: str | None = None


class CaptureSuggestionResponse(BaseModel):
    id: str
    document_id: str
    kind: SuggestionKind
    title: str
    details: str | None = None
    start_time: str | None = None
    end_time: str | None = None
    due_date: str | None = None
    all_day: bool
    assigned_to: str | None = None
    assigned_to_name: str | None = None
    confidence: float
    source_text: str | None = None
    status: SuggestionStatus
    result_id: str | None = None
    result_status: SuggestionResultStatus
    result_completed_at: str | None = None
    created_at: str
    updated_at: str


class DocumentResponse(BaseModel):
    id: str
    title: str
    original_filename: str
    media_type: str
    file_size: int
    sha256: str
    source: DocumentSource
    category: DocumentCategory
    category_confidence: float | None = Field(default=None, ge=0, le=1)
    status: DocumentStatus
    document_date: str | None = None
    document_date_confidence: float | None = Field(default=None, ge=0, le=1)
    page_count: int
    extracted_text: str | None = None
    notes: str | None = None
    processor: Literal["device", "hermes", "fallback"]
    people: list[DocumentPersonResponse] = Field(default_factory=list)
    suggestions: list[CaptureSuggestionResponse] = Field(default_factory=list)
    linked_events: list[LinkedEventResponse] = Field(default_factory=list)
    linked_tasks: list[LinkedTaskResponse] = Field(default_factory=list)
    pending_suggestion_count: int = 0
    ready_for_batch_filing: bool = False
    download_url: str
    created_at: str
    updated_at: str
    created_by: str | None = None


class DocumentUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=300)
    category: DocumentCategory | None = None
    status: DocumentStatus | None = None
    document_date: str | None = None
    notes: str | None = Field(default=None, max_length=10_000)
    person_ids: list[str] | None = None


class DocumentBatchFileRequest(BaseModel):
    document_ids: list[str] = Field(min_length=1, max_length=100)

    @field_validator("document_ids")
    @classmethod
    def unique_document_ids(cls, value: list[str]) -> list[str]:
        unique = list(dict.fromkeys(value))
        if len(unique) != len(value):
            raise ValueError("document_ids must not contain duplicates")
        return unique


class DocumentBatchFileResponse(BaseModel):
    filed_ids: list[str] = Field(default_factory=list)
    skipped_ids: list[str] = Field(default_factory=list)


class SuggestionResolutionResponse(BaseModel):
    suggestion_id: str
    status: SuggestionStatus
    result_type: SuggestionKind | None = None
    result_id: str | None = None


class DocumentStatsResponse(BaseModel):
    total_documents: int
    inbox_documents: int
    pending_suggestions: int
    storage_bytes: int
    storage_quota_bytes: int
    by_person: dict[str, int]


class DocumentInboxAddressResponse(BaseModel):
    configured: bool
    address: str | None = None
