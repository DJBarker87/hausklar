from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class AssistantHistoryMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=5_000)

    @field_validator("content")
    @classmethod
    def strip_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Message content cannot be blank")
        return value


class AssistantMessageRequest(BaseModel):
    message: str = Field(min_length=1, max_length=5_000)
    history: list[AssistantHistoryMessage] = Field(default_factory=list, max_length=12)
    client_now: str | None = None
    timezone: str = Field(default="Europe/London", min_length=1, max_length=100)
    dry_run: bool = False

    @field_validator("message")
    @classmethod
    def strip_message(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Message cannot be blank")
        return value


class HermesActionEvidence(BaseModel):
    """Exact conversation excerpts supporting a model-proposed action."""

    subject: str | None = Field(default=None, min_length=1, max_length=300)
    date_or_day: str | None = Field(default=None, min_length=1, max_length=300)
    time: str | None = Field(default=None, min_length=1, max_length=300)
    recurrence: str | None = Field(default=None, min_length=1, max_length=300)
    person: str | None = Field(default=None, min_length=1, max_length=300)
    term_time: str | None = Field(default=None, min_length=1, max_length=300)


class HermesCalendarAction(BaseModel):
    kind: Literal["create_calendar_event"]
    title: str = Field(min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    start_time: str
    end_time: str | None = None
    all_day: bool = False
    recurrence_rule: str | None = Field(default=None, max_length=100)
    assigned_to: str | None = Field(default=None, max_length=100)
    term_time_only: bool = False
    evidence: HermesActionEvidence | None = None


class HermesLightsAction(BaseModel):
    kind: Literal["set_all_lights"]
    state: Literal["on", "off"]


class HermesCreateTaskAction(BaseModel):
    kind: Literal["create_task"]
    title: str = Field(min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    due_date: str | None = None
    recurrence_rule: str | None = Field(default=None, max_length=100)
    assigned_to: str | None = Field(default=None, max_length=100)
    category: Literal["bins", "household", "shopping", "admin", "other"] = "other"
    priority: int = Field(default=2, ge=1, le=3)
    evidence: HermesActionEvidence | None = None


class HermesCompleteTaskAction(BaseModel):
    kind: Literal["complete_task"]
    task_id: str = Field(min_length=1, max_length=100)


class HermesShoppingAction(BaseModel):
    kind: Literal["add_shopping_item"]
    name: str = Field(min_length=1, max_length=300)
    quantity: str | None = Field(default=None, max_length=100)
    category: str | None = Field(default=None, max_length=100)


HermesAssistantAction = (
    HermesCalendarAction
    | HermesLightsAction
    | HermesCreateTaskAction
    | HermesCompleteTaskAction
    | HermesShoppingAction
)


class HermesAssistantResponse(BaseModel):
    answer: str = Field(min_length=1, max_length=10_000)
    actions: list[HermesAssistantAction] = Field(default_factory=list, max_length=3)
    language: Literal["en", "de"] = "en"


class AssistantCalendarPreview(BaseModel):
    kind: Literal["calendar_event"] = "calendar_event"
    title: str
    description: str | None = None
    start_time: str
    end_time: str | None = None
    all_day: bool = False
    recurrence_rule: str | None = None
    assigned_to: str | None = None
    term_time_only: bool = False


class AssistantTaskPreview(BaseModel):
    kind: Literal["create_task"] = "create_task"
    title: str
    description: str | None = None
    due_date: str | None = None
    recurrence_rule: str | None = None
    assigned_to: str | None = None
    category: Literal["bins", "household", "shopping", "admin", "other"] = "other"
    priority: int = 2


class AssistantShoppingPreview(BaseModel):
    kind: Literal["shopping_item"] = "shopping_item"
    name: str
    quantity: str | None = None
    category: str | None = None


AssistantActionPreview = Annotated[
    AssistantCalendarPreview | AssistantTaskPreview | AssistantShoppingPreview,
    Field(discriminator="kind"),
]


class AssistantActionResponse(BaseModel):
    id: str
    kind: Literal["calendar_event", "home_lights", "create_task", "complete_task", "shopping_item"]
    summary: str
    status: Literal["pending", "executing", "executed", "declined", "failed", "expired"]
    expires_at: str
    editable: bool = False
    preview: AssistantActionPreview | None = None


class _StrictActionUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class AssistantCalendarActionUpdate(_StrictActionUpdate):
    kind: Literal["calendar_event"]
    title: str | None = Field(default=None, min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    start_time: str | None = Field(default=None, min_length=1, max_length=100)
    end_time: str | None = Field(default=None, min_length=1, max_length=100)
    all_day: bool | None = None
    recurrence_rule: str | None = Field(default=None, min_length=1, max_length=100)
    assigned_to: str | None = Field(default=None, min_length=1, max_length=100)
    term_time_only: bool | None = None


class AssistantTaskActionUpdate(_StrictActionUpdate):
    kind: Literal["create_task"]
    title: str | None = Field(default=None, min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    due_date: str | None = Field(default=None, min_length=1, max_length=100)
    recurrence_rule: str | None = Field(default=None, min_length=1, max_length=100)
    assigned_to: str | None = Field(default=None, min_length=1, max_length=100)
    category: Literal["bins", "household", "shopping", "admin", "other"] | None = None
    priority: int | None = Field(default=None, ge=1, le=3)


class AssistantShoppingActionUpdate(_StrictActionUpdate):
    kind: Literal["shopping_item"]
    name: str | None = Field(default=None, min_length=1, max_length=300)
    quantity: str | None = Field(default=None, max_length=100)
    category: str | None = Field(default=None, max_length=100)


AssistantActionUpdate = Annotated[
    AssistantCalendarActionUpdate | AssistantTaskActionUpdate | AssistantShoppingActionUpdate,
    Field(discriminator="kind"),
]


class AssistantMessageResponse(BaseModel):
    answer: str
    actions: list[AssistantActionResponse]
    processor: Literal["bismarck"] = "bismarck"


class AssistantActionResult(BaseModel):
    id: str
    kind: Literal["calendar_event", "home_lights", "create_task", "complete_task", "shopping_item"]
    summary: str
    status: Literal["executed", "declined", "failed", "expired"]
    message: str
    result_id: str | None = None
