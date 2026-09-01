import re
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator


def _time(value: str) -> str:
    parts = value.split(":")
    if len(parts) != 2:
        raise ValueError("Time must use HH:MM")
    try:
        hour, minute = map(int, parts)
    except ValueError as exc:
        raise ValueError("Time must use HH:MM") from exc
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise ValueError("Time must use HH:MM")
    return f"{hour:02d}:{minute:02d}"


class ReminderPreferences(BaseModel):
    event_reminders_enabled: bool = True
    event_minutes_before: int = Field(default=30, ge=0, le=1440)
    task_reminders_enabled: bool = True
    morning_summary_enabled: bool = True
    morning_summary_time: str = "07:00"
    evening_summary_enabled: bool = True
    evening_summary_time: str = "19:00"
    quiet_start: str = "21:00"
    quiet_end: str = "07:00"
    privacy_mode: bool = True

    _times = field_validator(
        "morning_summary_time", "evening_summary_time", "quiet_start", "quiet_end"
    )(_time)

    @model_validator(mode="after")
    def summary_outside_quiet_hours(self):
        if self.quiet_start == self.quiet_end:
            return self
        for enabled, value, label in (
            (self.morning_summary_enabled, self.morning_summary_time, "Morning"),
            (self.evening_summary_enabled, self.evening_summary_time, "Evening"),
        ):
            quiet = (
                value >= self.quiet_start or value < self.quiet_end
                if self.quiet_start > self.quiet_end
                else self.quiet_start <= value < self.quiet_end
            )
            if enabled and quiet:
                raise ValueError(f"{label} summary must be outside quiet hours")
        return self


class PushSubscriptionCreate(BaseModel):
    endpoint: str = Field(min_length=20, max_length=4096)
    p256dh: str = Field(min_length=20, max_length=512)
    auth: str = Field(min_length=8, max_length=512)


class PushStatus(BaseModel):
    configured: bool
    subscribed: bool
    public_key: str | None = None


class APNSDeviceRegistrationCreate(BaseModel):
    device_token: str = Field(min_length=32, max_length=512)
    environment: Literal["sandbox", "production"]
    app_version: str | None = Field(default=None, max_length=40)

    @field_validator("device_token")
    @classmethod
    def valid_device_token(cls, value: str) -> str:
        normalized = value.strip().lower()
        if len(normalized) % 2 or not re.fullmatch(r"[0-9a-f]+", normalized):
            raise ValueError("Device token must be hexadecimal")
        return normalized


class APNSDeviceStatus(BaseModel):
    configured: bool
    registered: bool
    token_digest: str | None = None


class ReminderPreviewItem(BaseModel):
    id: str
    kind: str
    title: str
    detail: str
    scheduled_for: str
    url: str
