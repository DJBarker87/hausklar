from pydantic import BaseModel


class HealthDataCreate(BaseModel):
    source: str
    data_type: str
    value: float
    unit: str
    recorded_at: str
    metadata: dict | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class HealthDataResponse(BaseModel):
    id: str
    source: str
    data_type: str
    value: float
    unit: str
    recorded_at: str
    metadata: dict | None = None
    client_id: str | None = None
    client_timestamp: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None


class StravaTokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_at: int
    athlete: dict


class WithingsTokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int
    userid: str
    scope: str
