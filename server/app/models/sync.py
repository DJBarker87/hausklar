from typing import Literal

from pydantic import BaseModel, Field

from app.models.medicine import SafetyWarning


class SyncPushItem(BaseModel):
    operation_id: str | None = Field(default=None, min_length=1, max_length=100)
    operation: Literal["create", "update", "delete"]
    table_name: str = Field(min_length=1, max_length=100)
    record_id: str = Field(min_length=1, max_length=100)
    payload: dict | None = Field(default=None, max_length=100)
    client_id: str = Field(min_length=1, max_length=100)
    client_timestamp: str = Field(min_length=10, max_length=100)


class SyncPushRequest(BaseModel):
    items: list[SyncPushItem] = Field(min_length=1, max_length=200)


class SyncPushResult(BaseModel):
    operation_id: str | None = None
    record_id: str
    status: str  # accepted, conflict, error
    detail: str | None = None
    server_version: dict | None = None
    warnings: list[SafetyWarning] = Field(default_factory=list)


class SyncPushResponse(BaseModel):
    results: list[SyncPushResult]


class SyncPullRecord(BaseModel):
    table_name: str
    record_id: str
    operation: str  # create, update, delete
    data: dict | None = None
    updated_at: str


class SyncPullResponse(BaseModel):
    records: list[SyncPullRecord]
    server_timestamp: str
    next_cursor: str | None = None
    has_more: bool = False


class SyncStatusResponse(BaseModel):
    status: str
    last_sync: str | None = None
    pending_count: int
