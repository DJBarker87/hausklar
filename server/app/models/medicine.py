"""Pydantic models for the medicine tracking feature."""

from datetime import datetime, timezone
from uuid import uuid4

from pydantic import UUID4, BaseModel, Field, field_validator


# ---------------------------------------------------------------------------
# Medicine Types
# ---------------------------------------------------------------------------


class MedicineTypeCreate(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    name: str = Field(min_length=1, max_length=200)
    min_hours_between_doses: float = Field(default=4.0, ge=0.25, le=168)
    max_doses_24h: int = Field(default=4, ge=1, le=24)
    notes: str | None = Field(default=None, max_length=2_000)
    color: str | None = Field(default=None, max_length=50)
    default_dose_amount: str | None = Field(default=None, max_length=100)
    child_id: str = Field(min_length=1, max_length=100)
    client_id: str | None = None
    client_timestamp: str | None = None


class MedicineTypeUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    min_hours_between_doses: float | None = Field(default=None, ge=0.25, le=168)
    max_doses_24h: int | None = Field(default=None, ge=1, le=24)
    notes: str | None = Field(default=None, max_length=2_000)
    color: str | None = Field(default=None, max_length=50)
    default_dose_amount: str | None = Field(default=None, max_length=100)
    child_id: str | None = Field(default=None, min_length=1, max_length=100)
    client_id: str | None = None
    client_timestamp: str | None = None


class MedicineTypeResponse(BaseModel):
    id: str
    name: str
    min_hours_between_doses: float
    max_doses_24h: int
    notes: str | None = None
    color: str | None = None
    default_dose_amount: str | None = None
    child_id: str
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


# ---------------------------------------------------------------------------
# Medicine Doses
# ---------------------------------------------------------------------------


class MedicineDoseCreate(BaseModel):
    # This is both the client operation UUID and the eventual record ID. Keeping
    # it stable across an uncertain network retry prevents a dose being logged
    # twice when the first response is lost.
    id: UUID4 = Field(default_factory=uuid4)
    medicine_type_id: str | None = Field(default=None, max_length=100)
    child_id: str = Field(min_length=1, max_length=100)
    given_at: str = Field(min_length=1, max_length=64)
    dose_amount: str | None = Field(default=None, max_length=100)
    medicine_name: str | None = Field(default=None, min_length=1, max_length=200)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None

    @field_validator("given_at")
    @classmethod
    def normalise_given_at(cls, value: str) -> str:
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as exc:
            raise ValueError("Dose time must be a valid ISO-8601 timestamp") from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).isoformat()


class SafetyWarning(BaseModel):
    type: str  # "too_soon" or "max_reached"
    message: str
    next_safe_at: str | None = None


class MedicineDoseUpdate(BaseModel):
    given_at: str | None = Field(default=None, max_length=64)
    dose_amount: str | None = Field(default=None, max_length=100)
    clear_dose_amount: bool = False
    medicine_name: str | None = Field(default=None, min_length=1, max_length=200)
    notes: str | None = Field(default=None, max_length=2_000)
    clear_notes: bool = False

    @field_validator("given_at")
    @classmethod
    def normalise_given_at(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return MedicineDoseCreate.normalise_given_at(value)


class MedicineDoseResponse(BaseModel):
    id: str
    medicine_type_id: str | None = None
    child_id: str
    given_at: str
    given_by: str
    dose_amount: str | None = None
    medicine_name: str | None = None
    notes: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None
    warnings: list[SafetyWarning] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Safety Models
# ---------------------------------------------------------------------------


class DoseWithWarnings(BaseModel):
    dose: MedicineDoseResponse
    warnings: list[SafetyWarning]


class SafetyCheckResponse(BaseModel):
    safe: bool
    warnings: list[SafetyWarning]
    next_safe_at: str | None = None
