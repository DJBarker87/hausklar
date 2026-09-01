"""Pydantic models for the children's health-record features.

Nothing here is clinical advice — the app keeps records and reminders only.
"""

from datetime import date

from pydantic import BaseModel, ConfigDict, Field, model_validator

# ---------------------------------------------------------------------------
# Developmental milestones
# ---------------------------------------------------------------------------


class MilestoneAchieveRequest(BaseModel):
    milestone_key: str = Field(min_length=1, max_length=100)
    achieved_on: str = Field(min_length=1, max_length=32)
    note: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None


class MilestoneItem(BaseModel):
    key: str
    title: str
    category: str
    typical_age_min_months: int
    typical_age_max_months: int
    achieved: bool
    achieved_on: str | None = None
    note: str | None = None
    status: str  # achieved | overdue | due | upcoming


class MilestonesResponse(BaseModel):
    child_id: str
    child_name: str | None = None
    age_months: float | None = None
    milestones: list[MilestoneItem]
    disclaimer: str


# ---------------------------------------------------------------------------
# Vaccinations
# ---------------------------------------------------------------------------


class VaccinationRecordRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    vaccine_key: str | None = Field(default=None, min_length=1, max_length=100)
    vaccine_name: str | None = Field(default=None, min_length=1, max_length=120)
    given_on: str = Field(min_length=1, max_length=32)
    client_id: str | None = None
    client_timestamp: str | None = None

    @model_validator(mode="after")
    def standard_key_or_custom_name(self):
        if (self.vaccine_key is None) == (self.vaccine_name is None):
            raise ValueError("Provide exactly one of vaccine_key or vaccine_name")
        try:
            parsed = date.fromisoformat(self.given_on)
        except ValueError as exc:
            raise ValueError("given_on must be a valid YYYY-MM-DD date") from exc
        if parsed.isoformat() != self.given_on:
            raise ValueError("given_on must use YYYY-MM-DD")
        if parsed > date.today():
            raise ValueError("given_on cannot be in the future")
        return self


class VaccinationItem(BaseModel):
    key: str
    name: str
    due_age_label: str
    due_date: str | None = None
    status: str  # given | overdue | due | upcoming
    given_on: str | None = None
    is_standard: bool = True


class VaccinationsResponse(BaseModel):
    child_id: str
    child_name: str | None = None
    age_months: float | None = None
    vaccinations: list[VaccinationItem]
    disclaimer: str


# ---------------------------------------------------------------------------
# Growth centiles
# ---------------------------------------------------------------------------


class SexUpdateRequest(BaseModel):
    sex: str | None = Field(default=None, pattern="^(male|female)$")


class GrowthCentilePoint(BaseModel):
    date: str
    age_months: float | None = None
    height_cm: float | None = None
    weight_kg: float | None = None
    height_centile: float | None = None
    weight_centile: float | None = None


class ReferenceCurvePoint(BaseModel):
    age_months: int
    p2: float
    p9: float
    p25: float
    p50: float
    p75: float
    p91: float
    p98: float


class GrowthCentilesResponse(BaseModel):
    child_id: str
    child_name: str | None = None
    sex: str | None = None
    measurements: list[GrowthCentilePoint]
    weight_reference: list[ReferenceCurvePoint]
    height_reference: list[ReferenceCurvePoint]
    disclaimer: str
    note: str | None = None


# ---------------------------------------------------------------------------
# GP-ready illness summary
# ---------------------------------------------------------------------------


class SummaryIllness(BaseModel):
    id: str
    started_at: str
    ended_at: str | None = None
    notes: str | None = None


class SummaryTemperature(BaseModel):
    recorded_at: str
    value_celsius: float


class SummaryDose(BaseModel):
    given_at: str
    name: str
    dose_amount: str | None = None


class SummaryResponse(BaseModel):
    child_id: str
    child_name: str | None = None
    since: str
    until: str
    illnesses: list[SummaryIllness]
    temperatures: list[SummaryTemperature]
    medicine_doses: list[SummaryDose]
    report: str
    disclaimer: str
