from typing import Literal

from pydantic import BaseModel, Field, field_validator


CaptureKind = Literal["event", "task"]


class UniversalCaptureRequest(BaseModel):
    text: str = Field(min_length=1, max_length=10_000)
    use_hermes: bool = False
    client_now: str | None = Field(default=None, max_length=64)
    timezone: str | None = Field(default=None, max_length=64)

    @field_validator("text")
    @classmethod
    def strip_text(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("capture text must not be blank")
        return value


class UniversalCaptureProposal(BaseModel):
    id: str
    kind: CaptureKind
    title: str
    details: str | None = None
    start_time: str | None = None
    end_time: str | None = None
    due_date: str | None = None
    all_day: bool = True
    assigned_to: str | None = None
    assigned_to_name: str | None = None
    confidence: float = Field(default=0.5, ge=0, le=1)
    source_text: str | None = None


class UniversalCaptureResponse(BaseModel):
    proposals: list[UniversalCaptureProposal]
    processor: Literal["hermes", "fallback"]
    warning: str | None = None
