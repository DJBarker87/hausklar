"""Strict registered-key contracts for unified Fitness analysis."""

from datetime import date
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

ChartType = Literal[
    "line",
    "rolling_average",
    "bar",
    "stacked_bar",
    "scatter",
    "histogram",
    "calendar_heatmap",
    "range_band",
    "table",
]
FilterOperator = Literal["eq", "not_eq", "in", "gte", "lte", "between"]
FilterScalar = str | float | int | bool


class AnalysisModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid", str_strip_whitespace=True, allow_inf_nan=False
    )


class AnalysisDateRange(AnalysisModel):
    start: date
    end: date

    @model_validator(mode="after")
    def valid_range(self):
        if self.end < self.start:
            raise ValueError("Analysis end date must not precede its start date")
        return self


class AnalysisFilter(AnalysisModel):
    key: str = Field(min_length=1, max_length=100)
    operator: FilterOperator
    value: FilterScalar | list[FilterScalar]


class AnalysisQueryPayload(AnalysisModel):
    measure_key: str = Field(min_length=1, max_length=120)
    dimension_key: str = Field(min_length=1, max_length=120)
    chart_type_key: ChartType
    date_range: AnalysisDateRange
    filters: list[AnalysisFilter] = Field(default_factory=list, max_length=4)
    comparison_key: str | None = Field(default=None, max_length=100)
    max_points: int = Field(default=100, ge=1, le=200)


class SavedAnalysisChartPayload(AnalysisModel):
    id: UUID | None = None
    name: str = Field(min_length=1, max_length=160)
    measure_key: str = Field(min_length=1, max_length=120)
    dimension_key: str = Field(min_length=1, max_length=120)
    chart_type_key: ChartType
    filter_keys: list[str] = Field(default_factory=list, max_length=4)
    comparison_key: str | None = Field(default=None, max_length=100)
    date_window_days: int = Field(ge=1, le=366)

    @model_validator(mode="after")
    def unique_filters(self):
        if len(set(self.filter_keys)) != len(self.filter_keys):
            raise ValueError("Saved chart filter keys must be unique")
        return self
