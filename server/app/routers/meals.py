import json
import re
import unicodedata
import uuid
from datetime import date as date_type, datetime, timezone
from urllib.parse import unquote, urlsplit

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth import get_current_user
from app.database import get_db
from app.models.meal import (
    MealCreate,
    MealPlanCreate,
    MealPlanResponse,
    MealPlanWithRatings,
    MealRatingCreate,
    MealRatingResponse,
    MealResponse,
    MealUpdate,
    RecipePreviewRequest,
    RecipePreviewResponse,
    RecommendationDecisionRequest,
    RecommendationDecisionResponse,
    RecommendationsResponse,
    ShoppingPlanDiffApplyRequest,
    ShoppingPlanDiffApplyResponse,
    ShoppingPlanDiffItem,
    ShoppingPlanDiffResponse,
    ShoppingItemCreate,
    ShoppingItemResponse,
)
from app.services.create_records import create_or_replay_shopping_item
from app.services.idempotency import CreateReplayConflictError
from app.services.meal_recommender import derive_meal_context, recommend_meals

router = APIRouter()


async def _save_history(
    db,
    table_name: str,
    record_id: str,
    previous: dict,
    changed_by: str | None,
    *,
    family_id: str,
) -> None:
    """Insert a snapshot of the previous values into record_history."""
    await db.execute(
        """
        INSERT INTO record_history (
            id, table_name, record_id, previous_values, changed_by, changed_at, family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid.uuid4()),
            table_name,
            record_id,
            json.dumps(previous),
            changed_by,
            datetime.now(timezone.utc).isoformat(),
            family_id,
        ),
    )


def _to_meal_plan_response(row: dict) -> MealPlanResponse:
    data = dict(row)
    data["tired_household"] = bool(data.get("tired_household", 0))
    return MealPlanResponse(**data)


def _to_rating_response(row: dict) -> MealRatingResponse:
    return MealRatingResponse(**dict(row))


def _meal_response(row: dict) -> MealResponse:
    data = dict(row)
    data["not_for_us"] = bool(data.get("not_for_us", 0))
    return MealResponse(**data)


def _ingredient_key(value: str) -> str:
    normalised = unicodedata.normalize("NFKD", value).casefold()
    normalised = re.sub(r"[^a-z0-9]+", " ", normalised).strip()
    words = normalised.split()
    if words and len(words[-1]) > 4 and words[-1].endswith("s") and not words[-1].endswith("ss"):
        words[-1] = words[-1][:-1]
    return " ".join(words)


def _recipe_name_from_url(value: str) -> str:
    slug = unquote(urlsplit(value).path.rstrip("/").split("/")[-1])
    words = re.sub(r"[-_]+", " ", slug).strip()
    return words.title() if words else "New recipe"


def _parse_recipe_text(body: RecipePreviewRequest) -> RecipePreviewResponse:
    text = (body.text or "").replace("\r\n", "\n").strip()
    if not text and not body.recipe_url:
        raise HTTPException(status_code=422, detail="Paste a recipe or add its web address")

    raw_lines = [re.sub(r"\s+", " ", line).strip() for line in text.splitlines()]
    lines = [line for line in raw_lines if line]
    heading_words = {"ingredients", "ingredient", "method", "instructions", "directions"}
    name = next(
        (line.lstrip("# ") for line in lines if line.casefold().strip(":# ") not in heading_words),
        _recipe_name_from_url(body.recipe_url) if body.recipe_url else "New recipe",
    )
    name = name[:200]

    servings = None
    prep_minutes = None
    serving_match = re.search(r"\b(?:serves|servings?)\s*[:\-]?\s*(\d{1,3})\b", text, re.I)
    if serving_match:
        servings = min(int(serving_match.group(1)), 100)
    prep_match = re.search(
        r"\b(?:prep(?:aration)?(?: time)?|ready in)\s*[:\-]?\s*(?:(\d{1,2})\s*h(?:ours?)?\s*)?(\d{1,3})?\s*m?(?:in(?:utes?)?)?\b",
        text,
        re.I,
    )
    if prep_match and (prep_match.group(1) or prep_match.group(2)):
        prep_minutes = min(
            int(prep_match.group(1) or 0) * 60 + int(prep_match.group(2) or 0),
            1_440,
        )

    ingredients: list[dict[str, str | None]] = []
    in_ingredients = False
    found_ingredient_heading = False
    for line in lines:
        marker = line.casefold().strip(":# ")
        if marker in {"ingredients", "ingredient"}:
            in_ingredients = True
            found_ingredient_heading = True
            continue
        if marker in {"method", "instructions", "directions"}:
            in_ingredients = False
            if found_ingredient_heading:
                break
            continue
        if not in_ingredients:
            continue
        cleaned = re.sub(r"^[\-•*✓☐]+\s*", "", line).strip()
        if not cleaned:
            continue
        quantity = None
        ingredient_name = cleaned
        quantity_match = re.match(
            r"^((?:\d+[\d\s./¼½¾⅓⅔⅛⅜⅝⅞-]*|[¼½¾⅓⅔⅛⅜⅝⅞])(?:\s*(?:g|kg|ml|l|tsp|tbsp|cups?|cloves?|tins?|cans?|packs?|slices?|handfuls?|each))?)\s+(.+)$",
            cleaned,
            re.I,
        )
        if quantity_match:
            quantity = quantity_match.group(1).strip()
            ingredient_name = quantity_match.group(2).strip()
        ingredients.append({"name": ingredient_name[:200], "quantity": quantity, "category": None})
        if len(ingredients) == 100:
            break

    uncertain: list[str] = []
    if not lines and body.recipe_url:
        uncertain.append("name")
    if not ingredients:
        uncertain.append("ingredients")
    if prep_minutes is None:
        uncertain.append("prep_minutes")
    if servings is None:
        uncertain.append("servings")

    return RecipePreviewResponse(
        name=name,
        recipe_url=body.recipe_url,
        ingredients=ingredients,
        prep_minutes=prep_minutes,
        servings=servings,
        uncertain_fields=uncertain,
    )


async def _shopping_plan_diff(
    db,
    family_id: str,
    start: str,
    end: str,
) -> ShoppingPlanDiffResponse:
    try:
        start_date = date_type.fromisoformat(start)
        end_date = date_type.fromisoformat(end)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="Dates must use YYYY-MM-DD") from exc
    if end_date < start_date:
        raise HTTPException(status_code=422, detail="End date must not be before start date")
    if (end_date - start_date).days > 31:
        raise HTTPException(status_code=422, detail="Choose no more than 32 days")

    cursor = await db.execute(
        """
        SELECT mp.id AS plan_id, mp.date, m.name AS meal_name, m.ingredients
        FROM meal_plans mp
        JOIN meals m ON m.id = mp.meal_id AND m.family_id = mp.family_id
        WHERE mp.deleted_at IS NULL AND m.deleted_at IS NULL
          AND mp.family_id = ? AND mp.date >= ? AND mp.date <= ?
        ORDER BY mp.date, m.name
        """,
        (family_id, start, end),
    )
    plans = [dict(row) for row in await cursor.fetchall()]

    cursor = await db.execute(
        "SELECT name FROM shopping_items WHERE family_id = ? AND deleted_at IS NULL AND checked = 0",
        (family_id,),
    )
    shopping_keys = {_ingredient_key(row["name"]) for row in await cursor.fetchall()}

    from app.services.grocery import compute_stock_levels

    stock = await compute_stock_levels(db, family_id)
    at_home_keys = {
        _ingredient_key(str(item["item_name"]))
        for item in stock
        if float(item.get("remaining") or 0) > 0
    }

    combined: dict[str, dict] = {}
    for plan in plans:
        try:
            ingredients = json.loads(plan["ingredients"] or "[]")
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(ingredients, list):
            continue
        for ingredient in ingredients:
            if not isinstance(ingredient, dict):
                continue
            name = str(ingredient.get("name") or "").strip()
            key = _ingredient_key(name)
            if not key:
                continue
            item = combined.setdefault(
                key,
                {
                    "key": key,
                    "name": name,
                    "quantities": [],
                    "category": ingredient.get("category"),
                    "meal_plan_ids": [],
                    "planned_meals": [],
                },
            )
            quantity = str(ingredient.get("quantity") or "").strip()
            if quantity and quantity not in item["quantities"]:
                item["quantities"].append(quantity)
            if plan["plan_id"] not in item["meal_plan_ids"]:
                item["meal_plan_ids"].append(plan["plan_id"])
            meal_label = f"{plan['meal_name']} · {plan['date']}"
            if meal_label not in item["planned_meals"]:
                item["planned_meals"].append(meal_label)

    items = [
        ShoppingPlanDiffItem(
            key=item["key"],
            name=item["name"],
            quantity=" + ".join(item["quantities"]) or None,
            category=item["category"],
            meal_plan_ids=item["meal_plan_ids"],
            planned_meals=item["planned_meals"],
            already_on_list=item["key"] in shopping_keys,
            likely_at_home=item["key"] in at_home_keys,
        )
        for item in combined.values()
    ]
    items.sort(key=lambda item: (item.already_on_list, item.likely_at_home, item.name.casefold()))
    return ShoppingPlanDiffResponse(start=start, end=end, items=items)


async def _require_family_meal(db, family_id: str, meal_id: str) -> None:
    cursor = await db.execute(
        "SELECT 1 FROM meals WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (meal_id, family_id),
    )
    if await cursor.fetchone() is None:
        raise HTTPException(status_code=422, detail="Meal is not available to this family")


async def _require_family_children(db, family_id: str, child_ids: list[str]) -> None:
    unique_ids = list(dict.fromkeys(child_ids))
    if len(unique_ids) != len(child_ids):
        raise HTTPException(status_code=422, detail="Each child can be rated only once")
    placeholders = ",".join("?" for _ in unique_ids)
    cursor = await db.execute(
        f"SELECT id FROM children WHERE id IN ({placeholders}) "
        "AND family_id = ? AND deleted_at IS NULL",
        [*unique_ids, family_id],
    )
    if len(await cursor.fetchall()) != len(unique_ids):
        raise HTTPException(status_code=422, detail="One or more children are not in this family")


@router.get("/", response_model=list[MealResponse])
async def list_meals(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM meals WHERE deleted_at IS NULL AND family_id = ? ORDER BY name",
        (current_user["family_id"],),
    )
    rows = await cursor.fetchall()
    return [_meal_response(dict(row)) for row in rows]


@router.post("/", response_model=MealResponse, status_code=status.HTTP_201_CREATED)
async def create_meal(
    body: MealCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    meal_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    tags_json = json.dumps(body.tags) if body.tags is not None else None
    ingredients_json = (
        json.dumps([item.model_dump() for item in body.ingredients])
        if body.ingredients is not None
        else None
    )

    await db.execute(
        """
        INSERT INTO meals (
            id, name, description, recipe_url, tags, ingredients,
            last_made_at, prep_minutes, servings, allergy_notes,
            preference_notes, not_for_us, source,
            created_at, updated_at, created_by, client_id, client_timestamp,
            family_id
        ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            meal_id,
            body.name,
            body.description,
            body.recipe_url,
            tags_json,
            ingredients_json,
            body.prep_minutes,
            body.servings,
            body.allergy_notes,
            body.preference_notes,
            body.source,
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
            current_user["family_id"],
        ),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM meals WHERE id = ?", (meal_id,))
    row = await cursor.fetchone()
    return _meal_response(dict(row))


@router.post("/recipe-preview", response_model=RecipePreviewResponse)
async def preview_recipe(
    body: RecipePreviewRequest,
    current_user: dict = Depends(get_current_user),
):
    del current_user
    return _parse_recipe_text(body)


@router.put("/{meal_id}", response_model=MealResponse)
async def update_meal(
    meal_id: str,
    body: MealUpdate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM meals WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (meal_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meal not found")

    await _save_history(
        db,
        "meals",
        meal_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    updates = body.model_dump(exclude_unset=True)
    if not updates:
        return MealResponse(**dict(existing))

    if "tags" in updates:
        updates["tags"] = json.dumps(updates["tags"]) if updates["tags"] is not None else None
    if "ingredients" in updates:
        updates["ingredients"] = (
            json.dumps(updates["ingredients"])
            if updates["ingredients"] is not None
            else None
        )
    if "not_for_us" in updates:
        updates["not_for_us"] = int(updates["not_for_us"])

    updates["updated_at"] = datetime.now(timezone.utc).isoformat()
    set_clause = ", ".join(f"{key} = ?" for key in updates)
    values = list(updates.values()) + [meal_id, current_user["family_id"]]

    await db.execute(
        f"UPDATE meals SET {set_clause} WHERE id = ? AND family_id = ?",
        values,
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM meals WHERE id = ?", (meal_id,))
    row = await cursor.fetchone()
    return _meal_response(dict(row))


@router.delete("/{meal_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_meal(
    meal_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM meals WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (meal_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meal not found")

    await _save_history(
        db,
        "meals",
        meal_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE meals SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, meal_id, current_user["family_id"]),
    )
    await db.commit()


@router.post("/{meal_id}/restore", response_model=MealResponse)
async def restore_meal(
    meal_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM meals WHERE id = ? AND deleted_at IS NOT NULL AND family_id = ?",
        (meal_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail="Removed meal not found")
    await _save_history(
        db,
        "meals",
        meal_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )
    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE meals SET deleted_at = NULL, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, meal_id, current_user["family_id"]),
    )
    await db.commit()
    cursor = await db.execute("SELECT * FROM meals WHERE id = ?", (meal_id,))
    return _meal_response(dict(await cursor.fetchone()))


@router.get("/plan", response_model=list[MealPlanResponse])
async def list_meal_plans(
    start: str | None = None,
    end: str | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = """
        SELECT mp.*, m.name AS meal_name
        FROM meal_plans mp
        LEFT JOIN meals m ON mp.meal_id = m.id AND m.family_id = mp.family_id
        WHERE mp.deleted_at IS NULL AND mp.family_id = ?
    """
    params: list = [current_user["family_id"]]

    if start is not None:
        query += " AND mp.date >= ?"
        params.append(start)

    if end is not None:
        query += " AND mp.date <= ?"
        params.append(end)

    query += " ORDER BY mp.date, mp.meal_type"

    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_to_meal_plan_response(dict(row)) for row in rows]


@router.post("/plan", response_model=MealPlanResponse, status_code=status.HTTP_201_CREATED)
async def create_meal_plan(
    body: MealPlanCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    await _require_family_meal(db, current_user["family_id"], body.meal_id)
    plan_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    await db.execute(
        """
        INSERT INTO meal_plans (
            id, meal_id, date, meal_type, notes, tired_household,
            created_at, updated_at, created_by, client_id, client_timestamp,
            family_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            plan_id,
            body.meal_id,
            body.date,
            body.meal_type,
            body.notes,
            int(body.tired_household),
            now,
            now,
            current_user["id"],
            body.client_id,
            body.client_timestamp,
            current_user["family_id"],
        ),
    )
    await db.commit()

    cursor = await db.execute(
        """
        SELECT mp.*, m.name AS meal_name
        FROM meal_plans mp
        LEFT JOIN meals m ON mp.meal_id = m.id AND m.family_id = mp.family_id
        WHERE mp.id = ? AND mp.family_id = ?
        """,
        (plan_id, current_user["family_id"]),
    )
    row = await cursor.fetchone()
    return _to_meal_plan_response(dict(row))


@router.post("/plan/{plan_id}/ratings", response_model=MealPlanWithRatings)
async def submit_meal_ratings(
    plan_id: str,
    body: MealRatingCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        """
        SELECT mp.*, m.name AS meal_name
        FROM meal_plans mp
        LEFT JOIN meals m ON m.id = mp.meal_id AND m.family_id = mp.family_id
        WHERE mp.id = ? AND mp.deleted_at IS NULL AND mp.family_id = ?
        """,
        (plan_id, current_user["family_id"]),
    )
    plan = await cursor.fetchone()
    if not plan:
        raise HTTPException(status_code=404, detail="Meal plan not found")

    await _require_family_children(
        db,
        current_user["family_id"],
        [entry.child_id for entry in body.ratings],
    )

    now = datetime.now(timezone.utc).isoformat()

    for entry in body.ratings:
        if entry.rating < 1 or entry.rating > 3:
            raise HTTPException(status_code=400, detail="Rating must be between 1 and 3")

        cur = await db.execute(
            """
            SELECT * FROM meal_ratings
            WHERE meal_plan_id = ? AND child_id = ? AND deleted_at IS NULL AND family_id = ?
            """,
            (plan_id, entry.child_id, current_user["family_id"]),
        )
        existing = await cur.fetchone()
        if existing:
            await _save_history(
                db,
                "meal_ratings",
                existing["id"],
                dict(existing),
                current_user["id"],
                family_id=current_user["family_id"],
            )
            await db.execute(
                "UPDATE meal_ratings SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
                (now, now, existing["id"], current_user["family_id"]),
            )

        rating_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO meal_ratings (
                id, meal_plan_id, child_id, rating, family_id,
                created_at, updated_at, created_by, client_id, client_timestamp
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                rating_id,
                plan_id,
                entry.child_id,
                entry.rating,
                current_user["family_id"],
                now,
                now,
                current_user["id"],
                body.client_id,
                body.client_timestamp,
            ),
        )

    if body.tired_household is not None:
        await db.execute(
            "UPDATE meal_plans SET tired_household = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (int(body.tired_household), now, plan_id, current_user["family_id"]),
        )

    await db.execute(
        "UPDATE meals SET last_made_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (plan["date"], now, plan["meal_id"], current_user["family_id"]),
    )

    await db.commit()

    return await _meal_plan_with_ratings(db, current_user["family_id"], plan_id)


@router.get("/plan/{plan_id}/ratings", response_model=MealPlanWithRatings)
async def get_meal_plan_ratings(
    plan_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    result = await _meal_plan_with_ratings(db, current_user["family_id"], plan_id)
    if result is None:
        raise HTTPException(status_code=404, detail="Meal plan not found")
    return result


@router.get("/ratings/history", response_model=list[MealRatingResponse])
async def get_rating_history(
    child_id: str | None = Query(None),
    meal_id: str | None = Query(None),
    start: str | None = Query(None),
    end: str | None = Query(None),
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = """
        SELECT mr.*, c.name AS child_name
        FROM meal_ratings mr
        JOIN meal_plans mp ON mp.id = mr.meal_plan_id
        LEFT JOIN children c ON c.id = mr.child_id AND c.family_id = mr.family_id
        WHERE mr.deleted_at IS NULL AND mr.family_id = ?
    """
    params: list = [current_user["family_id"]]

    if child_id:
        query += " AND mr.child_id = ?"
        params.append(child_id)
    if meal_id:
        query += " AND mp.meal_id = ?"
        params.append(meal_id)
    if start:
        query += " AND mp.date >= ?"
        params.append(start)
    if end:
        query += " AND mp.date <= ?"
        params.append(end)

    query += " ORDER BY mp.date DESC, mr.created_at DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [_to_rating_response(dict(row)) for row in rows]


@router.get("/recommendations", response_model=RecommendationsResponse)
async def get_recommendations(
    date: str | None = Query(None),
    limit: int = Query(5, ge=1, le=20),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    target_date = date or date_type.today().isoformat()
    data = await recommend_meals(db, current_user["family_id"], target_date, limit=limit)
    return RecommendationsResponse(**data)


@router.post(
    "/recommendations/{meal_id}/decision",
    response_model=RecommendationDecisionResponse,
)
async def choose_recommendation(
    meal_id: str,
    body: RecommendationDecisionRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM meals WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
        (meal_id, current_user["family_id"]),
    )
    meal = await cursor.fetchone()
    if not meal:
        raise HTTPException(status_code=404, detail="Meal not found")

    now = datetime.now(timezone.utc).isoformat()
    if body.action == "not_for_us":
        await _save_history(
            db,
            "meals",
            meal_id,
            dict(meal),
            current_user["id"],
            family_id=current_user["family_id"],
        )
        await db.execute(
            "UPDATE meals SET not_for_us = 1, updated_at = ? WHERE id = ? AND family_id = ?",
            (now, meal_id, current_user["family_id"]),
        )
        await db.commit()
        cursor = await db.execute("SELECT * FROM meals WHERE id = ?", (meal_id,))
        return RecommendationDecisionResponse(
            action=body.action,
            meal=_meal_response(dict(await cursor.fetchone())),
            message="We will leave this out of dinner suggestions.",
        )

    target_date = date_type.today().isoformat() if body.action == "use_tonight" else body.date
    if not target_date:
        raise HTTPException(status_code=422, detail="Choose a day for this meal")
    try:
        date_type.fromisoformat(target_date)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="Date must use YYYY-MM-DD") from exc

    cursor = await db.execute(
        """
        SELECT * FROM meal_plans
        WHERE family_id = ? AND date = ? AND meal_type = 'dinner' AND deleted_at IS NULL
        """,
        (current_user["family_id"], target_date),
    )
    for existing in await cursor.fetchall():
        await _save_history(
            db,
            "meal_plans",
            existing["id"],
            dict(existing),
            current_user["id"],
            family_id=current_user["family_id"],
        )
        await db.execute(
            "UPDATE meal_plans SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (now, now, existing["id"], current_user["family_id"]),
        )

    plan_id = str(uuid.uuid4())
    await db.execute(
        """
        INSERT INTO meal_plans (
            id, meal_id, date, meal_type, notes, tired_household,
            created_at, updated_at, created_by, family_id
        ) VALUES (?, ?, ?, 'dinner', NULL, 0, ?, ?, ?, ?)
        """,
        (
            plan_id,
            meal_id,
            target_date,
            now,
            now,
            current_user["id"],
            current_user["family_id"],
        ),
    )
    await db.commit()
    cursor = await db.execute(
        """
        SELECT mp.*, m.name AS meal_name
        FROM meal_plans mp JOIN meals m ON m.id = mp.meal_id
        WHERE mp.id = ? AND mp.family_id = ?
        """,
        (plan_id, current_user["family_id"]),
    )
    plan = _to_meal_plan_response(dict(await cursor.fetchone()))
    return RecommendationDecisionResponse(
        action=body.action,
        meal=_meal_response(dict(meal)),
        plan=plan,
        message=(
            f"{meal['name']} is dinner tonight."
            if body.action == "use_tonight"
            else f"{meal['name']} is planned for {target_date}."
        ),
    )


@router.get("/recommendations/context")
@router.get("/recommendations/contextPreview")
async def get_recommendation_context(
    date: str | None = Query(None),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    target_date = date or date_type.today().isoformat()
    context = await derive_meal_context(db, current_user["family_id"], target_date)
    return {"date": target_date, "context": context}


@router.delete("/plan/{plan_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_meal_plan(
    plan_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM meal_plans WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (plan_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meal plan not found")

    await _save_history(
        db,
        "meal_plans",
        plan_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE meal_plans SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, plan_id, current_user["family_id"]),
    )
    await db.commit()


@router.get("/shopping", response_model=list[ShoppingItemResponse])
async def list_shopping_items(
    checked: bool | None = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    query = "SELECT * FROM shopping_items WHERE deleted_at IS NULL AND family_id = ?"
    params: list = [current_user["family_id"]]

    if checked is not None:
        query += " AND checked = ?"
        params.append(1 if checked else 0)

    query += " ORDER BY created_at DESC"

    cursor = await db.execute(query, params)
    rows = await cursor.fetchall()
    return [ShoppingItemResponse(**_shopping_row(row)) for row in rows]


@router.get("/shopping/plan-diff", response_model=ShoppingPlanDiffResponse)
async def preview_plan_shopping(
    start: str = Query(...),
    end: str = Query(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    return await _shopping_plan_diff(db, current_user["family_id"], start, end)


@router.post("/shopping/plan-diff/apply", response_model=ShoppingPlanDiffApplyResponse)
async def apply_plan_shopping(
    body: ShoppingPlanDiffApplyRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    preview = await _shopping_plan_diff(
        db,
        current_user["family_id"],
        body.start,
        body.end,
    )
    requested = set(body.keys)
    available = {item.key: item for item in preview.items}
    unknown = requested - available.keys()
    if unknown:
        raise HTTPException(status_code=422, detail="One or more ingredients are no longer in this plan")

    now = datetime.now(timezone.utc).isoformat()
    created: list[ShoppingItemResponse] = []
    skipped = 0
    for key in body.keys:
        item = available[key]
        if item.already_on_list:
            skipped += 1
            continue
        item_id = str(uuid.uuid4())
        await db.execute(
            """
            INSERT INTO shopping_items (
                id, name, quantity, category, meal_plan_id, checked,
                created_at, updated_at, created_by, family_id
            ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
            """,
            (
                item_id,
                item.name,
                item.quantity,
                item.category,
                item.meal_plan_ids[0] if item.meal_plan_ids else None,
                now,
                now,
                current_user["id"],
                current_user["family_id"],
            ),
        )
        cursor = await db.execute("SELECT * FROM shopping_items WHERE id = ?", (item_id,))
        created.append(ShoppingItemResponse(**_shopping_row(await cursor.fetchone())))
    await db.commit()
    return ShoppingPlanDiffApplyResponse(created=created, skipped=skipped)


@router.post("/shopping", response_model=ShoppingItemResponse, status_code=status.HTTP_201_CREATED)
async def create_shopping_item(
    body: ShoppingItemCreate,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    try:
        row, _replayed = await create_or_replay_shopping_item(
            db,
            body,
            record_id=str(body.id),
            user=current_user,
        )
    except CreateReplayConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return ShoppingItemResponse(**_shopping_row(row))


@router.patch("/shopping/{item_id}/check", response_model=ShoppingItemResponse)
async def check_shopping_item(
    item_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM shopping_items WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (item_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shopping item not found")

    await _save_history(
        db,
        "shopping_items",
        item_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    new_checked = 0 if existing["checked"] else 1
    now = datetime.now(timezone.utc).isoformat()

    await db.execute(
        "UPDATE shopping_items SET checked = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (new_checked, now, item_id, current_user["family_id"]),
    )
    await db.commit()

    cursor = await db.execute("SELECT * FROM shopping_items WHERE id = ?", (item_id,))
    row = await cursor.fetchone()
    return ShoppingItemResponse(**_shopping_row(row))


@router.post("/shopping/done-all")
async def mark_shopping_done(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM shopping_items WHERE deleted_at IS NULL AND family_id = ?",
        (current_user["family_id"],),
    )
    rows = await cursor.fetchall()

    now = datetime.now(timezone.utc).isoformat()
    for row in rows:
        item_id = row["id"]
        await _save_history(
            db,
            "shopping_items",
            item_id,
            dict(row),
            current_user["id"],
            family_id=current_user["family_id"],
        )
        await db.execute(
            "UPDATE shopping_items SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (now, now, item_id, current_user["family_id"]),
        )

    await db.commit()
    return {"cleared": len(rows)}


@router.delete("/shopping/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_shopping_item(
    item_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        "SELECT * FROM shopping_items WHERE id = ? AND deleted_at IS NULL AND family_id = ?",
        (item_id, current_user["family_id"]),
    )
    existing = await cursor.fetchone()
    if not existing:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shopping item not found")

    await _save_history(
        db,
        "shopping_items",
        item_id,
        dict(existing),
        current_user["id"],
        family_id=current_user["family_id"],
    )

    now = datetime.now(timezone.utc).isoformat()
    await db.execute(
        "UPDATE shopping_items SET deleted_at = ?, updated_at = ? WHERE id = ? AND family_id = ?",
        (now, now, item_id, current_user["family_id"]),
    )
    await db.commit()


@router.post("/shopping/generate", response_model=list[ShoppingItemResponse])
async def generate_shopping_list(
    start: str = Query(...),
    end: str = Query(...),
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    cursor = await db.execute(
        """
        SELECT mp.id AS plan_id, m.ingredients
        FROM meal_plans mp
        JOIN meals m ON mp.meal_id = m.id AND m.family_id = mp.family_id
        WHERE mp.deleted_at IS NULL
          AND m.deleted_at IS NULL
          AND mp.family_id = ?
          AND mp.date >= ?
          AND mp.date <= ?
        """,
        (current_user["family_id"], start, end),
    )
    plans = await cursor.fetchall()

    created_items: list[ShoppingItemResponse] = []
    now = datetime.now(timezone.utc).isoformat()

    for plan in plans:
        raw_ingredients = plan["ingredients"]
        if not raw_ingredients:
            continue

        ingredients = json.loads(raw_ingredients)
        for ing in ingredients:
            item_id = str(uuid.uuid4())
            await db.execute(
                """
                INSERT INTO shopping_items (
                    id, name, quantity, category, meal_plan_id, checked,
                    created_at, updated_at, created_by, family_id
                ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                """,
                (
                    item_id,
                    ing.get("name", ""),
                    ing.get("quantity"),
                    ing.get("category"),
                    plan["plan_id"],
                    now,
                    now,
                    current_user["id"],
                    current_user["family_id"],
                ),
            )

            cursor2 = await db.execute(
                "SELECT * FROM shopping_items WHERE id = ?", (item_id,)
            )
            row = await cursor2.fetchone()
            created_items.append(ShoppingItemResponse(**_shopping_row(row)))

    await db.commit()
    return created_items


async def _meal_plan_with_ratings(db, family_id: str, plan_id: str) -> MealPlanWithRatings | None:
    cursor = await db.execute(
        """
        SELECT mp.*, m.name AS meal_name
        FROM meal_plans mp
        LEFT JOIN meals m ON m.id = mp.meal_id AND m.family_id = mp.family_id
        WHERE mp.id = ? AND mp.deleted_at IS NULL AND mp.family_id = ?
        """,
        (plan_id, family_id),
    )
    row = await cursor.fetchone()
    if not row:
        return None

    cursor = await db.execute(
        """
        SELECT mr.*, c.name AS child_name
        FROM meal_ratings mr
        LEFT JOIN children c ON c.id = mr.child_id AND c.family_id = mr.family_id
        WHERE mr.meal_plan_id = ? AND mr.deleted_at IS NULL AND mr.family_id = ?
        ORDER BY c.name ASC
        """,
        (plan_id, family_id),
    )
    ratings = [_to_rating_response(dict(r)) for r in await cursor.fetchall()]

    base = _to_meal_plan_response(dict(row))
    return MealPlanWithRatings(**base.model_dump(), ratings=ratings)


def _shopping_row(row) -> dict:
    d = dict(row)
    d["checked"] = bool(d["checked"])
    return d
