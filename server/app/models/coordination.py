from pydantic import BaseModel, Field


class TomorrowEvent(BaseModel):
    id: str
    title: str
    start_time: str
    all_day: bool
    location: str | None = None
    assigned_to: str | None = None
    event_type: str | None = None


class TomorrowTask(BaseModel):
    id: str
    title: str
    due_date: str | None = None
    priority: int
    assignee_names: list[str] = Field(default_factory=list)


class LoadPrompt(BaseModel):
    task_id: str
    title: str
    due_date: str | None = None
    priority: int


class TomorrowCard(BaseModel):
    target_date: str
    visible: bool
    acknowledged: bool
    events: list[TomorrowEvent]
    tasks: list[TomorrowTask]
    load_prompt: LoadPrompt | None = None


class TomorrowAcknowledgement(BaseModel):
    target_date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")


class LoadAssignmentRequest(BaseModel):
    assignee_id: str = Field(min_length=1, max_length=100)


class ShareDraftCreate(BaseModel):
    text: str = Field(min_length=1, max_length=10_000)
    title: str | None = Field(default=None, max_length=500)
    url: str | None = Field(default=None, max_length=2_000)


class ShareDraftResponse(BaseModel):
    id: str
    text: str


class ShareDraftCreated(BaseModel):
    id: str
