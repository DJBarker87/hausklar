"""User-facing Finance export and audit-history responses."""

from typing import Any, Literal

from pydantic import BaseModel


class FinanceHistoryEntryResponse(BaseModel):
    id: str
    record_type: str
    record_id: str
    changed_at: str
    changed_by_name: str | None = None
    changed_by_current_user: bool
    previous_values: dict[str, Any]


class FinanceHistoryPageResponse(BaseModel):
    scope: Literal["mine", "household"]
    offset: int
    limit: int
    has_more: bool
    items: list[FinanceHistoryEntryResponse]
