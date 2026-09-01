from typing import Literal

from pydantic import BaseModel, Field, field_validator


class EmailModel(BaseModel):
    email: str = Field(min_length=3, max_length=254)

    @field_validator("email")
    @classmethod
    def normalise_email(cls, value: str) -> str:
        value = value.strip().lower()
        if "@" not in value or value.startswith("@") or value.endswith("@"):
            raise ValueError("Enter a valid email address")
        return value


class LoginRequest(EmailModel):
    password: str = Field(min_length=1, max_length=128)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class LoginResponse(TokenResponse):
    user: "UserResponse"


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1, max_length=256)


class ForgotPasswordRequest(EmailModel):
    pass


class ForgotPasswordResponse(BaseModel):
    message: str


class ResetPasswordRequest(BaseModel):
    token: str = Field(min_length=1, max_length=2_048)
    new_password: str = Field(min_length=12, max_length=128)


class UserResponse(BaseModel):
    id: str
    name: str
    email: str
    role: str
    priority: int
    avatar_url: str | None = None
    family_id: str | None = None
    must_change_password: bool = False


class UserProfileUpdate(BaseModel):
    """Low-risk profile fields that may be changed without rotating credentials."""

    name: str = Field(min_length=1, max_length=100)

    @field_validator("name")
    @classmethod
    def normalise_name(cls, value: str) -> str:
        cleaned = " ".join(value.strip().split())
        if not cleaned:
            raise ValueError("Enter your name")
        return cleaned


OnboardingModule = Literal["children", "medicine_sleep", "dog", "home", "fitness", "finance"]


class OnboardingStatus(BaseModel):
    family_name: str
    people_count: int
    adult_count: int
    child_count: int
    calendar_commitment_count: int
    reminders_configured: bool
    selected_modules: list[OnboardingModule] = Field(default_factory=list)
    dismissed: bool = False
    completed: bool = False
    should_show: bool
    first_success: bool


class OnboardingUpdate(BaseModel):
    selected_modules: list[OnboardingModule] | None = None
    dismissed: bool | None = None
    completed: bool | None = None


class UserInDB(BaseModel):
    id: str
    name: str
    email: str
    password_hash: str
    role: str
    priority: int
    avatar_url: str | None = None
    family_id: str | None = None
    must_change_password: int = 0


class ChangePasswordRequest(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=12, max_length=128)


class AIConsentRequest(BaseModel):
    accepted: Literal[True]
    version: str = Field(min_length=1, max_length=50)


class AIConsentResponse(BaseModel):
    consented: bool
    version: str
    consented_at: str | None = None
    provider: str
    disclosure: str
    background_processing: bool = False


class RegisterFamilyRequest(EmailModel):
    family_name: str = Field(min_length=1, max_length=200)
    user_name: str = Field(min_length=1, max_length=100)
    password: str = Field(min_length=12, max_length=128)


class JoinFamilyRequest(EmailModel):
    invite_code: str = Field(min_length=8, max_length=32)
    user_name: str = Field(min_length=1, max_length=100)
    password: str = Field(min_length=12, max_length=128)

    @field_validator("invite_code")
    @classmethod
    def normalise_invite_code(cls, value: str) -> str:
        return value.strip().upper()
