"""Typed contracts for adult-owned, booking-scoped caregiver handovers."""

from datetime import datetime, timedelta, timezone
from enum import Enum

from pydantic import BaseModel, Field, field_validator, model_validator


class CaregiverPackStatus(str, Enum):
    CONFIGURED = "configured"
    INCOMPLETE = "incomplete"


class CaregiverPackMissingSection(str, Enum):
    DAILY_ROUTINE = "daily_routine"
    EMERGENCY_CONTACTS = "emergency_contacts"
    WIFI_PASSWORD = "wifi_password"
    HOUSE_RULES = "house_rules"
    ALLERGIES = "allergies"


class BabysitterRoutineResponse(BaseModel):
    breakfast: str
    lunch: str
    dinner: str
    nap_time: str
    bath: str
    stories: str
    bedtime: str


class BabysitterContactResponse(BaseModel):
    name: str
    phone: str


class BabysitterImportantInfoResponse(BaseModel):
    wifi_password: str
    house_rules: str
    allergies: str


class CaregiverPackResponse(BaseModel):
    status: CaregiverPackStatus
    missing_sections: list[CaregiverPackMissingSection] = Field(default_factory=list)
    daily_routine: BabysitterRoutineResponse | None = None
    emergency_contacts: list[BabysitterContactResponse] = Field(default_factory=list)
    important_info: BabysitterImportantInfoResponse | None = None


class BabysitterChildResponse(BaseModel):
    name: str
    age: int
    date_of_birth: str
    notes: str | None = None


class BabysitterMedicineResponse(BaseModel):
    child_name: str
    medicine_name: str
    dosage_notes: str | None = None
    last_given_at: str | None = None
    last_given_by: str | None = None
    next_dose_allowed_at: str | None = None
    min_hours_between: float


class BabysitterNapResponse(BaseModel):
    child_name: str
    started_at: str
    location: str | None = None


class BabysitterEventResponse(BaseModel):
    title: str
    start_time: str
    end_time: str
    location: str | None = None


class BabysitterResponse(BaseModel):
    caregiver_pack: CaregiverPackResponse
    children: list[BabysitterChildResponse]
    medicine_schedule: list[BabysitterMedicineResponse]
    active_naps: list[BabysitterNapResponse]
    todays_events: list[BabysitterEventResponse]


# --- Authoritative parent-entered handover ---------------------------------


class CaregiverHouseInput(BaseModel):
    address: str | None = Field(default=None, max_length=1_000)
    wifi_name: str | None = Field(default=None, max_length=200)
    wifi_password: str | None = Field(default=None, max_length=500)
    emergency_instructions: str | None = Field(default=None, max_length=5_000)
    house_instructions: str | None = Field(default=None, max_length=5_000)
    dog_instructions: str | None = Field(default=None, max_length=5_000)


class CaregiverChildInput(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    care_notes: str | None = Field(default=None, max_length=5_000)
    allergies: str | None = Field(default=None, max_length=2_000)
    food: str | None = Field(default=None, max_length=3_000)
    comfort: str | None = Field(default=None, max_length=3_000)
    toileting: str | None = Field(default=None, max_length=3_000)
    bedtime: str | None = Field(default=None, max_length=3_000)


class CaregiverContactInput(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    phone: str = Field(min_length=3, max_length=100)
    relationship: str | None = Field(default=None, max_length=200)
    priority: int = Field(default=0, ge=0, le=100)

    @field_validator("name", "phone")
    @classmethod
    def clean_required_text(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Contact name and phone are required")
        return cleaned


class CaregiverHandoverUpdate(BaseModel):
    house: CaregiverHouseInput = Field(default_factory=CaregiverHouseInput)
    children: list[CaregiverChildInput] = Field(default_factory=list, max_length=20)
    contacts: list[CaregiverContactInput] = Field(default_factory=list, max_length=10)

    @model_validator(mode="after")
    def unique_children(self):
        child_ids = [child.child_id for child in self.children]
        if len(child_ids) != len(set(child_ids)):
            raise ValueError("Each child can appear only once")
        return self


class CaregiverHouseResponse(CaregiverHouseInput):
    id: str | None = None


class CaregiverChildResponse(CaregiverChildInput):
    id: str | None = None
    child_name: str


class CaregiverContactResponse(CaregiverContactInput):
    id: str


class CaregiverReadinessItem(BaseModel):
    key: str
    label: str
    ready: bool
    child_id: str | None = None


class CaregiverReadinessResponse(BaseModel):
    ready: bool
    complete_count: int
    total_count: int
    items: list[CaregiverReadinessItem]


class CaregiverHandoverResponse(BaseModel):
    id: str | None = None
    house: CaregiverHouseResponse
    children: list[CaregiverChildResponse]
    contacts: list[CaregiverContactResponse]
    readiness: CaregiverReadinessResponse
    updated_at: str | None = None


# --- Time-boxed caregiver bookings -----------------------------------------


class CaregiverBookingCreate(BaseModel):
    label: str = Field(min_length=1, max_length=200)
    starts_at: datetime
    expires_at: datetime
    child_ids: list[str] = Field(min_length=1, max_length=20)

    @field_validator("label")
    @classmethod
    def clean_label(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Add a booking name")
        return cleaned

    @field_validator("starts_at", "expires_at")
    @classmethod
    def timezone_required(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("Booking times must include a timezone")
        return value.astimezone(timezone.utc)

    @model_validator(mode="after")
    def valid_window(self):
        if self.expires_at <= self.starts_at:
            raise ValueError("Booking must end after it starts")
        if self.expires_at - self.starts_at > timedelta(days=7):
            raise ValueError("Caregiver access cannot last longer than 7 days")
        if len(self.child_ids) != len(set(self.child_ids)):
            raise ValueError("Choose each child once")
        return self


class CaregiverBookingResponse(BaseModel):
    id: str
    label: str
    starts_at: str
    expires_at: str
    child_ids: list[str]
    child_names: list[str]
    status: str
    created_at: str
    revoked_at: str | None = None
    last_accessed_at: str | None = None


class CaregiverBookingCreatedResponse(CaregiverBookingResponse):
    share_url: str


class CaregiverBookingRevokeResponse(BaseModel):
    status: str = "revoked"
    booking_id: str


class CaregiverSessionExchange(BaseModel):
    code: str = Field(min_length=32, max_length=500)


class CaregiverSessionExchangeResponse(BaseModel):
    status: str = "ready"
    expires_at: str


class CaregiverSessionBooking(BaseModel):
    label: str
    starts_at: str
    expires_at: str


class CaregiverSessionChild(BaseModel):
    child_id: str
    name: str
    age: int
    care_notes: str
    allergies: str
    food: str
    comfort: str
    toileting: str
    bedtime: str


class CaregiverSessionAllergy(BaseModel):
    child_name: str
    details: str


class CaregiverSessionHouse(BaseModel):
    wifi_name: str | None = None
    wifi_password: str
    house_instructions: str
    dog_instructions: str | None = None


class CaregiverSessionEmergency(BaseModel):
    address: str
    instructions: str
    contacts: list[CaregiverContactResponse]
    allergies: list[CaregiverSessionAllergy]


class CaregiverSessionNow(BaseModel):
    children: list[CaregiverSessionChild]
    active_naps: list[BabysitterNapResponse]
    medicine_schedule: list[BabysitterMedicineResponse]


class CaregiverSessionNext(BaseModel):
    events: list[BabysitterEventResponse]


class CaregiverSessionView(BaseModel):
    booking: CaregiverSessionBooking
    now: CaregiverSessionNow
    next: CaregiverSessionNext
    emergency: CaregiverSessionEmergency
    house: CaregiverSessionHouse
    read_only: bool = True
    medicine_disclaimer: str = (
        "Recorded information only. Follow the medicine label and the parent's instructions; "
        "HausKlar cannot record a dose from caregiver access."
    )
