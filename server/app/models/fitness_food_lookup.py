"""Typed drafts returned by the optional public food lookup."""

from typing import Literal

from pydantic import Field

from app.models.fitness import FitnessModel


class FoodLookupNutrients(FitnessModel):
    """Nutrition copied from a package database, always normalised per 100 g/ml."""

    calories_kcal: float | None = Field(default=None, ge=0)
    protein_g: float | None = Field(default=None, ge=0)
    carbohydrate_g: float | None = Field(default=None, ge=0)
    sugars_g: float | None = Field(default=None, ge=0)
    fat_g: float | None = Field(default=None, ge=0)
    saturated_fat_g: float | None = Field(default=None, ge=0)
    fibre_g: float | None = Field(default=None, ge=0)
    salt_g: float | None = Field(default=None, ge=0)
    sodium_mg: float | None = Field(default=None, ge=0)


class FoodLookupServing(FitnessModel):
    name: str = Field(min_length=1, max_length=120)
    amount: float = Field(gt=0)
    unit: Literal["g", "ml"]


class FoodLookupDraft(FitnessModel):
    """An untrusted external result that still requires a person to confirm it."""

    barcode: str = Field(pattern=r"^[0-9]{8,14}$")
    name: str = Field(min_length=1, max_length=200)
    brand: str | None = Field(default=None, max_length=160)
    reference_amount: float = 100
    reference_unit: Literal["g", "ml"]
    nutrients: FoodLookupNutrients
    serving: FoodLookupServing | None = None
    source: Literal["open_food_facts"] = "open_food_facts"
    source_url: str = Field(max_length=500)
    warnings: list[str] = Field(default_factory=list, max_length=20)
    needs_review: Literal[True] = True
