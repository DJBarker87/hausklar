"""Owner-private Fitness nutrition, food library and body API."""

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.auth import get_current_user
from app.database import get_db
from app.models.fitness import (
    BodyMeasurementPayload,
    FoodLogPayload,
    FoodPatch,
    FoodPayload,
    FoodVersionPayload,
    MealTemplatePayload,
    MergePayload,
    NutritionSettingsUpdate,
    NutritionMealCompletionPayload,
    NutritionTargetPayload,
    RecipePayload,
    RecipeVersionPayload,
    ServingPayload,
)
from app.models.fitness_food_lookup import FoodLookupDraft
from app.models.fitness_household_meals import (
    HouseholdMealLinkResponse,
    HouseholdMealLinkUpdate,
    PlannedHouseholdMealResponse,
    PlannedMealLogRequest,
    PrivatePlannedMealLogResponse,
)
from app.services.fitness.common import (
    CanonicalIdentityChangedError,
    FitnessConflictError,
    FitnessNotFoundError,
)
from app.services.fitness import food_lookup, household_meals, nutrition

router = APIRouter()


def _raise_domain(exc: Exception) -> None:
    if isinstance(exc, FitnessNotFoundError):
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(exc, CanonicalIdentityChangedError):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "canonical_identity_changed",
                "entity_type": exc.entity_type,
                "target_id": exc.target_id,
                "target_summary": exc.target_summary,
            },
        ) from exc
    if isinstance(exc, FitnessConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if isinstance(exc, ValueError):
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    raise exc


async def _commit(db, operation):
    try:
        result = await operation
        await db.commit()
        return result
    except Exception as exc:
        await db.rollback()
        _raise_domain(exc)


@router.get("/foods")
async def foods(
    q: str | None = Query(default=None, max_length=200),
    favourites: bool = False,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        nutrition.list_foods(db, user=current_user, query=q, favourites=favourites),
    )


@router.get("/food-lookup/barcode/{barcode}", response_model=FoodLookupDraft)
async def lookup_food_barcode(
    barcode: str,
    _current_user: dict = Depends(get_current_user),
):
    """Return a reviewable draft; this endpoint never writes a food or diary row."""
    try:
        return await food_lookup.lookup_barcode(barcode)
    except food_lookup.FoodLookupNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except food_lookup.FoodLookupUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/food-lookup/search", response_model=list[FoodLookupDraft])
async def search_food_lookup(
    q: str = Query(min_length=2, max_length=100),
    _current_user: dict = Depends(get_current_user),
):
    """Run an explicit external lookup. Results remain untrusted drafts until Add."""
    try:
        return await food_lookup.search_foods(q)
    except food_lookup.FoodLookupUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/nutrition/meal-completions")
async def meal_completions(
    date_value: date = Query(alias="date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await nutrition.list_meal_completions(db, user=current_user, nutrition_date=date_value)


@router.post("/nutrition/meal-completions", status_code=status.HTTP_201_CREATED)
async def complete_nutrition_meal(
    body: NutritionMealCompletionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, nutrition.complete_meal(db, user=current_user, body=body))


@router.post("/foods", status_code=status.HTTP_201_CREATED)
async def create_food(
    body: FoodPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, nutrition.upsert_food(db, user=current_user, body=body))


@router.get("/foods/{food_id}")
async def food(
    food_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await nutrition.get_food(db, user=current_user, food_id=food_id)
    except Exception as exc:
        _raise_domain(exc)


@router.patch("/foods/{food_id}")
async def update_food(
    food_id: str,
    body: FoodPatch,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db, nutrition.patch_food(db, user=current_user, food_id=food_id, body=body)
    )


@router.post("/foods/{food_id}/versions", status_code=status.HTTP_201_CREATED)
async def create_food_version(
    food_id: str,
    body: FoodVersionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        nutrition.add_food_version(db, user=current_user, food_id=food_id, body=body),
    )


@router.post("/foods/{food_id}/servings", status_code=status.HTTP_201_CREATED)
async def create_food_serving(
    food_id: str,
    body: ServingPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db, nutrition.add_serving(db, user=current_user, food_id=food_id, body=body)
    )


@router.post("/foods/merge/preview")
async def preview_food_merge(
    body: MergePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await nutrition.preview_food_merge(
            db,
            user=current_user,
            source_id=str(body.source_id),
            target_id=str(body.target_id),
        )
    except Exception as exc:
        _raise_domain(exc)


@router.post("/foods/merge")
async def merge_foods(
    body: MergePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        nutrition.merge_foods(
            db,
            user=current_user,
            source_id=str(body.source_id),
            target_id=str(body.target_id),
        ),
    )


@router.get(
    "/household-meals",
    response_model=list[HouseholdMealLinkResponse],
)
async def household_meal_links(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await household_meals.list_household_meal_links(
        db,
        user=current_user,
    )


@router.put(
    "/household-meals/{meal_id}",
    response_model=HouseholdMealLinkResponse,
)
async def link_household_meal(
    meal_id: str,
    body: HouseholdMealLinkUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        household_meals.link_household_meal(
            db,
            user=current_user,
            meal_id=meal_id,
            body=body,
        ),
    )


@router.delete(
    "/household-meals/{meal_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def unlink_household_meal(
    meal_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _commit(
        db,
        household_meals.delete_household_meal_link(
            db,
            user=current_user,
            meal_id=meal_id,
        ),
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get(
    "/planned-meals",
    response_model=list[PlannedHouseholdMealResponse],
)
async def planned_household_meals(
    date_: date = Query(alias="date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await household_meals.list_planned_household_meals(
        db,
        user=current_user,
        planned_date=date_,
    )


@router.post(
    "/planned-meals/{meal_plan_id}/log",
    response_model=PrivatePlannedMealLogResponse,
    status_code=status.HTTP_201_CREATED,
)
async def log_planned_household_meal(
    meal_plan_id: str,
    body: PlannedMealLogRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        household_meals.log_planned_household_meal(
            db,
            user=current_user,
            meal_plan_id=meal_plan_id,
            body=body,
        ),
    )


@router.get("/food-log")
async def food_log(
    date_: date = Query(alias="date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await nutrition.list_food_log(db, user=current_user, nutrition_date=date_)


@router.post("/food-log", status_code=status.HTTP_201_CREATED)
async def create_food_log_entry(
    body: FoodLogPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, nutrition.upsert_food_log(db, user=current_user, body=body))


@router.put("/food-log/{entry_id}")
async def update_food_log_entry(
    entry_id: str,
    body: FoodLogPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        nutrition.upsert_food_log(db, user=current_user, body=body, record_id=entry_id),
    )


@router.delete("/food-log/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_food_log_entry(
    entry_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _commit(db, nutrition.delete_food_log(db, user=current_user, entry_id=entry_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/nutrition/analysis")
async def nutrition_summary(
    start: date,
    end: date,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    if end < start:
        raise HTTPException(status_code=422, detail="end cannot be before start")
    return await nutrition.nutrition_analysis(db, user=current_user, start=start, end=end)


@router.get("/nutrition/targets")
async def nutrition_targets(
    date_: date | None = Query(default=None, alias="date"),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await nutrition.list_nutrition_targets(db, user=current_user, effective_on=date_)


@router.post("/nutrition/targets", status_code=status.HTTP_201_CREATED)
async def create_nutrition_target(
    body: NutritionTargetPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, nutrition.upsert_nutrition_target(db, user=current_user, body=body))


@router.put("/nutrition/targets/{target_id}")
async def update_nutrition_target(
    target_id: str,
    body: NutritionTargetPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        nutrition.upsert_nutrition_target(db, user=current_user, body=body, record_id=target_id),
    )


@router.post("/nutrition/settings/rebucket")
async def rebucket_nutrition_settings(
    body: NutritionSettingsUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, nutrition.rebucket_nutrition_entries(db, user=current_user, body=body))


@router.get("/body/measurements")
async def body_measurements(
    metric_key: str | None = Query(default=None, max_length=120),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await nutrition.list_body_measurements(db, user=current_user, metric_key=metric_key)


@router.post("/body/measurements", status_code=status.HTTP_201_CREATED)
async def create_body_measurement(
    body: BodyMeasurementPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, nutrition.upsert_body_measurement(db, user=current_user, body=body))


@router.put("/body/measurements/{measurement_id}")
async def update_body_measurement(
    measurement_id: str,
    body: BodyMeasurementPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        nutrition.upsert_body_measurement(
            db, user=current_user, body=body, record_id=measurement_id
        ),
    )


@router.get("/body/weight-trend")
async def body_weight_trend(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await nutrition.weight_trend(db, user=current_user)


@router.get("/recipes")
async def recipes(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await nutrition.list_recipes(db, user=current_user)


@router.get("/recipes/{recipe_id}")
async def recipe(
    recipe_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        return await nutrition.get_recipe(db, user=current_user, recipe_id=recipe_id)
    except Exception as exc:
        _raise_domain(exc)


@router.post("/recipes", status_code=status.HTTP_201_CREATED)
async def create_recipe(
    body: RecipePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, nutrition.create_recipe(db, user=current_user, body=body))


@router.post("/recipes/{recipe_id}/versions", status_code=status.HTTP_201_CREATED)
async def create_recipe_version(
    recipe_id: str,
    body: RecipeVersionPayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(
        db,
        nutrition.add_recipe_version(db, user=current_user, recipe_id=recipe_id, body=body),
    )


@router.get("/meal-templates")
async def meal_templates(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await nutrition.list_meal_templates(db, user=current_user)


@router.post("/meal-templates", status_code=status.HTTP_201_CREATED)
async def create_meal_template(
    body: MealTemplatePayload,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _commit(db, nutrition.create_meal_template(db, user=current_user, body=body))
