"""Typed family-link and owner-private planned-meal logging contracts."""

from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import Field

from app.models.fitness import FitnessModel


class HouseholdMealLinkUpdate(FitnessModel):
    id: UUID | None = None
    recipe_version_id: UUID
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class HouseholdMealLinkResponse(FitnessModel):
    id: UUID
    meal_id: UUID
    meal_name: str
    recipe_id: UUID
    recipe_version_id: UUID
    recipe_name: str
    linked_at: datetime


class PlannedHouseholdMealResponse(FitnessModel):
    meal_plan_id: UUID
    date: date
    meal_type: Literal["breakfast", "lunch", "dinner"]
    meal_id: UUID
    meal_name: str
    link_id: UUID
    recipe_id: UUID
    recipe_version_id: UUID
    recipe_name: str
    suggested_portion: float
    suggested_unit: Literal["serving", "g"]


class PlannedMealLogRequest(FitnessModel):
    id: UUID
    portion: float = Field(gt=0, le=100_000)
    unit: Literal["serving", "g"]
    logged_at_utc: datetime
    local_timezone: str = Field(min_length=1, max_length=100)
    notes: str | None = Field(default=None, max_length=4_000)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class PrivatePlannedMealLogResponse(FitnessModel):
    id: UUID
    source_meal_plan_id: UUID
    household_meal_link_id: UUID
    recipe_version_id: UUID
    nutrition_date: date
    meal_type: str
    logged_at_utc: datetime
    portion: float
    unit: Literal["serving", "g"]
    calories_kcal: float | None = None
    protein_g: float | None = None
