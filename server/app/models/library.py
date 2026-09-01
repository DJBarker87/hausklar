"""Schemas for the read-only Local authority library loan monitor."""

from pydantic import BaseModel, Field, SecretStr, field_validator


def _secret(value: SecretStr) -> str:
    return value.get_secret_value().strip()


class LibraryAccountCreate(BaseModel):
    label: str = Field(min_length=1, max_length=80)
    card_number: SecretStr
    pin: SecretStr
    reminder_days_before: int = Field(default=7, ge=0, le=30)

    @field_validator("label")
    @classmethod
    def _label(cls, value: str) -> str:
        cleaned = " ".join(value.split())
        if not cleaned:
            raise ValueError("Enter a name for this library card")
        return cleaned

    @field_validator("card_number")
    @classmethod
    def _card_number(cls, value: SecretStr) -> SecretStr:
        cleaned = _secret(value).replace(" ", "")
        if not 6 <= len(cleaned) <= 32 or not cleaned.isalnum():
            raise ValueError("Enter the letters and numbers from the library card")
        return SecretStr(cleaned.upper())

    @field_validator("pin")
    @classmethod
    def _pin(cls, value: SecretStr) -> SecretStr:
        cleaned = _secret(value)
        if len(cleaned) not in {4, 6} or not cleaned.isdigit():
            raise ValueError("The library PIN must be 4 or 6 digits")
        return SecretStr(cleaned)


class LibraryAccountUpdate(BaseModel):
    label: str | None = Field(default=None, min_length=1, max_length=80)
    reminder_days_before: int | None = Field(default=None, ge=0, le=30)
    sync_enabled: bool | None = None

    @field_validator("label")
    @classmethod
    def _label(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = " ".join(value.split())
        if not cleaned:
            raise ValueError("Enter a name for this library card")
        return cleaned


class LibraryAccountResponse(BaseModel):
    id: str
    provider: str
    label: str
    card_last_four: str
    sync_enabled: bool
    reminder_days_before: int
    status: str
    last_sync_at: str | None = None
    last_success_at: str | None = None
    next_sync_at: str | None = None
    error_message: str | None = None


class LibraryLoanResponse(BaseModel):
    id: str
    account_id: str
    account_label: str
    title: str
    author: str | None = None
    material_format: str | None = None
    due_date: str
    days_until: int
    status: str
    provider_status: str | None = None
    renewable: bool | None = None
    renewal_count: int | None = None
    renew_url: str | None = None


class LibraryOverviewResponse(BaseModel):
    accounts: list[LibraryAccountResponse]
    loans: list[LibraryLoanResponse]
