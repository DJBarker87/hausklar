from typing import Annotated, Literal
from urllib.parse import urlsplit
from uuid import uuid4

from pydantic import UUID4, BaseModel, ConfigDict, Field, field_validator


ShortText = Annotated[str, Field(min_length=1, max_length=100)]


class MealIngredient(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=200)
    quantity: str | None = Field(default=None, max_length=100)
    category: str | None = Field(default=None, max_length=100)


def _validate_recipe_url(value: str | None) -> str | None:
    if value is None:
        return None
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("recipe_url must be an HTTP or HTTPS URL")
    return value


# ---------------------------------------------------------------------------
# Meals
# ---------------------------------------------------------------------------


class MealCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=5_000)
    recipe_url: str | None = Field(default=None, max_length=2_000)
    tags: list[ShortText] | None = Field(default=None, max_length=30)
    ingredients: list[MealIngredient] | None = Field(default=None, max_length=100)
    prep_minutes: int | None = Field(default=None, ge=0, le=1_440)
    servings: int | None = Field(default=None, ge=1, le=100)
    allergy_notes: str | None = Field(default=None, max_length=2_000)
    preference_notes: str | None = Field(default=None, max_length=2_000)
    source: str | None = Field(default=None, max_length=100)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    _recipe_url = field_validator("recipe_url")(_validate_recipe_url)


class MealUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=5_000)
    recipe_url: str | None = Field(default=None, max_length=2_000)
    tags: list[ShortText] | None = Field(default=None, max_length=30)
    ingredients: list[MealIngredient] | None = Field(default=None, max_length=100)
    prep_minutes: int | None = Field(default=None, ge=0, le=1_440)
    servings: int | None = Field(default=None, ge=1, le=100)
    allergy_notes: str | None = Field(default=None, max_length=2_000)
    preference_notes: str | None = Field(default=None, max_length=2_000)
    not_for_us: bool | None = None
    source: str | None = Field(default=None, max_length=100)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)

    _recipe_url = field_validator("recipe_url")(_validate_recipe_url)


class MealResponse(BaseModel):
    id: str
    name: str
    description: str | None = None
    recipe_url: str | None = None
    tags: str | None = None  # stored as JSON string
    ingredients: str | None = None  # stored as JSON string
    last_made_at: str | None = None
    prep_minutes: int | None = None
    servings: int | None = None
    allergy_notes: str | None = None
    preference_notes: str | None = None
    not_for_us: bool = False
    source: str | None = None
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


# ---------------------------------------------------------------------------
# Meal Plans
# ---------------------------------------------------------------------------


class MealPlanCreate(BaseModel):
    meal_id: str = Field(min_length=1, max_length=100)
    date: str = Field(min_length=1, max_length=64)
    meal_type: Literal["breakfast", "lunch", "dinner"]
    notes: str | None = Field(default=None, max_length=2_000)
    tired_household: bool = False
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class MealPlanResponse(BaseModel):
    id: str
    meal_id: str
    date: str
    meal_type: str
    notes: str | None = None
    tired_household: bool = False
    meal_name: str | None = None  # joined from meals table
    created_at: str
    updated_at: str
    client_id: str | None = None
    client_timestamp: str | None = None


# ---------------------------------------------------------------------------
# Shopping Items
# ---------------------------------------------------------------------------


class ShoppingItemCreate(BaseModel):
    id: UUID4 = Field(default_factory=uuid4)
    name: str = Field(min_length=1, max_length=300)
    quantity: str | None = Field(default=None, max_length=100)
    category: str | None = Field(default=None, max_length=100)
    meal_plan_id: str | None = Field(default=None, max_length=100)
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class ShoppingItemResponse(BaseModel):
    id: str
    name: str
    quantity: str | None = None
    category: str | None = None
    meal_plan_id: str | None = None
    checked: bool = False
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class MealRatingInput(BaseModel):
    child_id: str = Field(min_length=1, max_length=100)
    rating: int = Field(ge=1, le=3)


class MealRatingCreate(BaseModel):
    meal_plan_id: str | None = Field(default=None, max_length=100)
    ratings: list[MealRatingInput] = Field(min_length=1, max_length=20)
    tired_household: bool | None = None
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


class MealRatingResponse(BaseModel):
    id: str
    meal_plan_id: str
    child_id: str
    child_name: str | None = None
    rating: int
    created_at: str
    updated_at: str
    created_by: str | None = None
    client_id: str | None = None
    client_timestamp: str | None = None


class MealPlanWithRatings(MealPlanResponse):
    ratings: list[MealRatingResponse] = Field(default_factory=list)


class MealContext(BaseModel):
    school_day: bool
    club_day: bool
    high_exertion: bool
    late_home: bool
    holiday_mode: bool
    day_of_week: int
    dinner_time_bucket: str


class RecommendedMeal(BaseModel):
    meal_id: str
    meal_name: str
    tags: list[str]
    score: float
    reasons: list[str]
    last_served_at: str | None = None


class RecommendationsResponse(BaseModel):
    context: MealContext
    recommendations: list[RecommendedMeal]
    date: str


class RecommendationDecisionRequest(BaseModel):
    action: Literal["use_tonight", "plan_another_day", "not_for_us"]
    date: str | None = Field(default=None, max_length=64)


class RecommendationDecisionResponse(BaseModel):
    action: str
    meal: MealResponse
    plan: MealPlanResponse | None = None
    message: str


class RecipePreviewRequest(BaseModel):
    text: str | None = Field(default=None, max_length=100_000)
    recipe_url: str | None = Field(default=None, max_length=2_000)

    _recipe_url = field_validator("recipe_url")(_validate_recipe_url)


class RecipePreviewResponse(BaseModel):
    name: str
    description: str | None = None
    recipe_url: str | None = None
    ingredients: list[MealIngredient] = Field(default_factory=list)
    prep_minutes: int | None = None
    servings: int | None = None
    tags: list[str] = Field(default_factory=list)
    uncertain_fields: list[str] = Field(default_factory=list)


class ShoppingPlanDiffItem(BaseModel):
    key: str
    name: str
    quantity: str | None = None
    category: str | None = None
    meal_plan_ids: list[str]
    planned_meals: list[str]
    already_on_list: bool = False
    likely_at_home: bool = False


class ShoppingPlanDiffResponse(BaseModel):
    start: str
    end: str
    items: list[ShoppingPlanDiffItem]


class ShoppingPlanDiffApplyRequest(BaseModel):
    start: str = Field(min_length=1, max_length=64)
    end: str = Field(min_length=1, max_length=64)
    keys: list[str] = Field(default_factory=list, max_length=500)


class ShoppingPlanDiffApplyResponse(BaseModel):
    created: list[ShoppingItemResponse]
    skipped: int = 0
