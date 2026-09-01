from pydantic import BaseModel, Field


class GrowthRecordCreate(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    date: str = Field(min_length=1, max_length=64)
    height_cm: float | None = Field(default=None, ge=1, le=250)
    weight_kg: float | None = Field(default=None, ge=0.1, le=300)
    head_circumference_cm: float | None = Field(default=None, ge=1, le=100)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None


class GrowthRecordUpdate(BaseModel):
    child_id: str | None = Field(default=None, min_length=1, max_length=100)
    date: str | None = Field(default=None, min_length=1, max_length=64)
    height_cm: float | None = Field(default=None, ge=1, le=250)
    weight_kg: float | None = Field(default=None, ge=0.1, le=300)
    head_circumference_cm: float | None = Field(default=None, ge=1, le=100)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None


class GrowthRecordResponse(BaseModel):
    id: str
    child_id: str
    date: str
    height_cm: float | None = None
    weight_kg: float | None = None
    head_circumference_cm: float | None = None
    notes: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None


class GrowthChartData(BaseModel):
    records: list[GrowthRecordResponse]
    child_name: str
    child_dob: str
