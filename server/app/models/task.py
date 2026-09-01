from typing import Literal
from uuid import uuid4

from pydantic import UUID4, BaseModel, Field

from app.models.document import LinkedDocumentResponse
from app.models.managed_projection import ManagedSource


class AssigneeInput(BaseModel):
    assignee_id: str = Field(min_length=1, max_length=100)
    assignee_type: Literal["user", "child"]


class TaskAssignee(BaseModel):
    id: str
    assignee_id: str
    assignee_type: str
    assignee_name: str | None = None
    completed_at: str | None = None
    completed_by: str | None = None


class TaskCreate(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    title: str = Field(min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    assigned_to: str | None = Field(default=None, max_length=100)
    assignees: list[AssigneeInput] | None = Field(default=None, max_length=20)
    due_date: str | None = Field(default=None, max_length=100)
    category: Literal["bins", "household", "shopping", "admin", "other"] = "other"
    recurrence_rule: str | None = Field(default=None, max_length=100)
    priority: int = Field(default=2, ge=1, le=3)
    actionable_from: str | None = Field(default=None, max_length=100)
    source_document_id: str | None = Field(default=None, max_length=64)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class TaskUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    assigned_to: str | None = Field(default=None, max_length=100)
    assignees: list[AssigneeInput] | None = Field(default=None, max_length=20)
    due_date: str | None = Field(default=None, max_length=100)
    category: Literal["bins", "household", "shopping", "admin", "other"] | None = None
    recurrence_rule: str | None = Field(default=None, max_length=100)
    priority: int | None = Field(default=None, ge=1, le=3)
    actionable_from: str | None = Field(default=None, max_length=100)
    source_document_id: str | None = Field(default=None, max_length=64)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class TaskResponse(BaseModel):
    id: str
    title: str
    description: str | None = None
    assigned_to: str | None = None
    due_date: str | None = None
    completed_at: str | None = None
    category: str = "other"
    recurrence_rule: str | None = None
    priority: int = 2
    actionable_from: str | None = None
    source_document_id: str | None = None
    source_document: LinkedDocumentResponse | None = None
    source_event_id: str | None = None
    prep_occurrence_id: str | None = None
    prep_occurrence_start: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None
    assignees: list[TaskAssignee] = []
    read_only: bool = False
    managed_source: ManagedSource | None = None


class TaskOverviewPerson(BaseModel):
    person_id: str
    person_name: str
    person_type: str  # 'user' or 'child'
    total_pending: int
    total_completed_today: int
    overdue: int
