"""Pydantic models for illness tracking."""

from datetime import datetime, timezone

from pydantic import BaseModel, Field, model_validator


def parse_illness_datetime(value: str) -> datetime:
    """Parse an ISO date/datetime into a comparable UTC datetime."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


# ---------------------------------------------------------------------------
# Illnesses
# ---------------------------------------------------------------------------


class IllnessCreate(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    started_at: str = Field(min_length=1, max_length=64)
    ended_at: str | None = Field(default=None, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None

    @model_validator(mode="after")
    def end_is_not_before_start(self):
        try:
            start = parse_illness_datetime(self.started_at)
            end = (
                parse_illness_datetime(self.ended_at)
                if self.ended_at is not None
                else None
            )
        except (TypeError, ValueError) as exc:
            raise ValueError("Illness dates must be valid ISO dates") from exc
        today = datetime.now(timezone.utc).date()
        if start.date() > today or (end is not None and end.date() > today):
            raise ValueError("Illness dates cannot be in the future")
        if end is not None and end < start:
            raise ValueError("End date cannot be before start date")
        return self


class IllnessUpdate(BaseModel):
    started_at: str | None = Field(default=None, max_length=64)
    ended_at: str | None = Field(default=None, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None

    @model_validator(mode="after")
    def dates_are_valid_when_present(self):
        if "started_at" in self.model_fields_set and self.started_at is None:
            raise ValueError("Illness start date cannot be empty")
        try:
            start = (
                parse_illness_datetime(self.started_at)
                if self.started_at is not None
                else None
            )
            end = (
                parse_illness_datetime(self.ended_at)
                if self.ended_at is not None
                else None
            )
        except (TypeError, ValueError) as exc:
            raise ValueError("Illness dates must be valid ISO dates") from exc
        today = datetime.now(timezone.utc).date()
        if (start is not None and start.date() > today) or (
            end is not None and end.date() > today
        ):
            raise ValueError("Illness dates cannot be in the future")
        return self


class IllnessResponse(BaseModel):
    id: str
    child_id: str
    started_at: str
    ended_at: str | None = None
    notes: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


# ---------------------------------------------------------------------------
# Temperature Readings
# ---------------------------------------------------------------------------


class TemperatureReadingCreate(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    illness_id: str | None = Field(default=None, max_length=100)
    value_celsius: float = Field(ge=-100, le=100, allow_inf_nan=False)
    recorded_at: str = Field(min_length=1, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None


class TemperatureReadingUpdate(BaseModel):
    value_celsius: float | None = Field(default=None, ge=-100, le=100, allow_inf_nan=False)
    recorded_at: str | None = Field(default=None, min_length=1, max_length=64)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None

    @model_validator(mode="after")
    def corrected_values_cannot_be_empty(self):
        if "value_celsius" in self.model_fields_set and self.value_celsius is None:
            raise ValueError("Temperature cannot be empty")
        if "recorded_at" in self.model_fields_set and self.recorded_at is None:
            raise ValueError("Temperature time cannot be empty")
        return self


class TemperatureReadingResponse(BaseModel):
    id: str
    child_id: str
    illness_id: str | None = None
    value_celsius: float
    recorded_at: str
    notes: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


# ---------------------------------------------------------------------------
# Illness Detail (graph data)
# ---------------------------------------------------------------------------


class NextDoseTime(BaseModel):
    medicine_type_id: str
    medicine_name: str
    next_safe_at: str | None = None
    is_safe_now: bool
    default_dose_amount: str | None = None
    color: str | None = None
    last_given_at: str | None = None


class IllnessDetailResponse(BaseModel):
    illness: IllnessResponse
    temperature_readings: list[TemperatureReadingResponse]
    medicine_doses: list[dict]
    next_dose_times: list[NextDoseTime]
