"""Pydantic models for the star charts feature."""

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Star Charts
# ---------------------------------------------------------------------------


class StarChartCreate(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    title: str = Field(default="Star Chart", min_length=1, max_length=200)
    grid_rows: int = Field(default=5, ge=1, le=10)
    grid_columns: int = Field(default=5, ge=1, le=10)
    reward_amount_pence: int = Field(default=500, ge=0, le=1_000_000)
    client_id: str | None = None
    client_timestamp: str | None = None


class StarChartUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    grid_rows: int | None = Field(default=None, ge=1, le=10)
    grid_columns: int | None = Field(default=None, ge=1, le=10)
    reward_amount_pence: int | None = Field(default=None, ge=0, le=1_000_000)
    client_id: str | None = None
    client_timestamp: str | None = None


class StarResponse(BaseModel):
    id: str
    chart_id: str
    row_index: int
    col_index: int
    awarded_at: str
    created_at: str


class StarChartResponse(BaseModel):
    id: str
    child_id: str
    title: str
    grid_rows: int
    grid_columns: int
    reward_amount_pence: int
    completed_at: str | None = None
    stars_count: int = 0
    total_cells: int = 0
    stars: list[StarResponse] = []
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


# ---------------------------------------------------------------------------
# Stars
# ---------------------------------------------------------------------------


class StarCreate(BaseModel):
    row_index: int = Field(ge=0, le=9)
    col_index: int = Field(ge=0, le=9)
    client_id: str | None = None
    client_timestamp: str | None = None


# ---------------------------------------------------------------------------
# Balance
# ---------------------------------------------------------------------------


class BalanceResponse(BaseModel):
    child_id: str
    balance_pence: int
    balance_display: str


class BalanceAdjust(BaseModel):
    amount_pence: int = Field(ge=-1_000_000, le=1_000_000)
    reason: str = Field(default="manual_adjustment", min_length=1, max_length=100)
    notes: str | None = Field(default=None, max_length=2_000)
    client_id: str | None = None
    client_timestamp: str | None = None


class TransactionResponse(BaseModel):
    id: str
    child_id: str
    amount_pence: int
    reason: str
    chart_id: str | None = None
    notes: str | None = None
    created_at: str


class ChartCompletedResponse(BaseModel):
    chart: StarChartResponse
    reward_amount_pence: int
    new_balance_pence: int
    new_balance_display: str
