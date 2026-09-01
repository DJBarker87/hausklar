"""Explicit bridge from family meal plans to owner-private Fitness diaries."""

from datetime import date, datetime, timezone

from app.models.fitness import FoodLogPayload
from app.models.fitness_household_meals import (
    HouseholdMealLinkUpdate,
    PlannedMealLogRequest,
)
from app.services.fitness import nutrition
from app.services.fitness.common import (
    FitnessConflictError,
    FitnessNotFoundError,
    decoded_row,
    new_id,
    now_iso,
)
from app.services.idempotency import serialized_create
from app.services.record_history import save_history


async def _family_meal(db, *, user: dict, meal_id: str):
    row = await (
        await db.execute(
            "SELECT * FROM meals WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
            (meal_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Household meal not found")
    return row


async def _shared_recipe_version(db, *, user: dict, version_id: str):
    row = await (
        await db.execute(
            "SELECT v.*, r.id AS shared_recipe_id, r.name AS shared_recipe_name "
            "FROM health_recipe_versions v JOIN health_recipes r "
            "ON r.id = v.recipe_id AND r.family_id = v.family_id "
            "AND r.owner_user_id = v.owner_user_id "
            "WHERE v.id = ? AND v.family_id = ? AND v.deleted_at IS NULL "
            "AND r.deleted_at IS NULL AND r.active = 1 AND r.household_shared = 1",
            (version_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Shared Fitness recipe version not found")
    if row["servings"] is None and row["finished_weight_g"] is None:
        raise FitnessConflictError("Add servings or finished weight before linking this recipe")
    return row


def _link_response(row) -> dict:
    return {
        "id": row["id"],
        "meal_id": row["meal_id"],
        "meal_name": row["meal_name"],
        "recipe_id": row["recipe_id"],
        "recipe_version_id": row["recipe_version_id"],
        "recipe_name": row["recipe_name"],
        "linked_at": row["updated_at"],
    }


async def _link_row(db, *, user: dict, link_id: str):
    row = await (
        await db.execute(
            "SELECT l.*, m.name AS meal_name, r.id AS recipe_id, "
            "r.name AS recipe_name FROM health_household_meal_recipe_links l "
            "JOIN meals m ON m.id = l.meal_id AND m.family_id = l.family_id "
            "JOIN health_recipe_versions v ON v.id = l.recipe_version_id "
            "AND v.family_id = l.family_id AND v.deleted_at IS NULL "
            "JOIN health_recipes r ON r.id = v.recipe_id AND r.family_id = v.family_id "
            "AND r.owner_user_id = v.owner_user_id "
            "WHERE l.id = ? AND l.family_id = ? AND l.deleted_at IS NULL "
            "AND m.deleted_at IS NULL AND r.deleted_at IS NULL "
            "AND r.active = 1 AND r.household_shared = 1",
            (link_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Household meal link not found")
    return row


async def list_household_meal_links(db, *, user: dict) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT l.*, m.name AS meal_name, r.id AS recipe_id, "
            "r.name AS recipe_name FROM health_household_meal_recipe_links l "
            "JOIN meals m ON m.id = l.meal_id AND m.family_id = l.family_id "
            "JOIN health_recipe_versions v ON v.id = l.recipe_version_id "
            "AND v.family_id = l.family_id AND v.deleted_at IS NULL "
            "JOIN health_recipes r ON r.id = v.recipe_id AND r.family_id = v.family_id "
            "AND r.owner_user_id = v.owner_user_id "
            "WHERE l.family_id = ? AND l.deleted_at IS NULL "
            "AND m.deleted_at IS NULL AND r.deleted_at IS NULL "
            "AND r.active = 1 AND r.household_shared = 1 "
            "ORDER BY m.name, l.created_at",
            (user["family_id"],),
        )
    ).fetchall()
    return [_link_response(row) for row in rows]


async def link_household_meal(
    db,
    *,
    user: dict,
    meal_id: str,
    body: HouseholdMealLinkUpdate,
) -> dict:
    async with serialized_create(db):
        await _family_meal(db, user=user, meal_id=meal_id)
        version_id = str(body.recipe_version_id)
        await _shared_recipe_version(db, user=user, version_id=version_id)
        existing = await (
            await db.execute(
                "SELECT * FROM health_household_meal_recipe_links "
                "WHERE family_id = ? AND meal_id = ? AND deleted_at IS NULL",
                (user["family_id"], meal_id),
            )
        ).fetchone()
        if existing is not None and existing["recipe_version_id"] == version_id:
            link_id = existing["id"]
        else:
            link_id = new_id(body.id)
            identifier = await (
                await db.execute(
                    "SELECT 1 FROM health_household_meal_recipe_links WHERE id = ?",
                    (link_id,),
                )
            ).fetchone()
            if identifier is not None:
                raise FitnessConflictError("Fitness identifier or unique value is already in use")
            timestamp = now_iso()
            if existing is not None:
                await save_history(
                    db,
                    "health_household_meal_recipe_links",
                    existing["id"],
                    user["id"],
                    family_id=user["family_id"],
                )
                await db.execute(
                    "UPDATE health_household_meal_recipe_links SET deleted_at = ?, "
                    "updated_at = ?, revision = revision + 1 "
                    "WHERE id = ? AND family_id = ? AND deleted_at IS NULL",
                    (
                        timestamp,
                        timestamp,
                        existing["id"],
                        user["family_id"],
                    ),
                )
            await db.execute(
                "INSERT INTO health_household_meal_recipe_links "
                "(id, meal_id, recipe_version_id, revision, family_id, created_at, "
                "updated_at, created_by, client_id, client_timestamp) "
                "VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?)",
                (
                    link_id,
                    meal_id,
                    version_id,
                    user["family_id"],
                    timestamp,
                    timestamp,
                    user["id"],
                    body.client_id,
                    body.client_timestamp,
                ),
            )
        linked = await _link_row(db, user=user, link_id=link_id)
    return _link_response(linked)


async def delete_household_meal_link(db, *, user: dict, meal_id: str) -> None:
    row = await (
        await db.execute(
            "SELECT * FROM health_household_meal_recipe_links "
            "WHERE family_id = ? AND meal_id = ? AND deleted_at IS NULL",
            (user["family_id"], meal_id),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Household meal link not found")
    timestamp = now_iso()
    await save_history(
        db,
        "health_household_meal_recipe_links",
        row["id"],
        user["id"],
        family_id=user["family_id"],
    )
    await db.execute(
        "UPDATE health_household_meal_recipe_links SET deleted_at = ?, "
        "updated_at = ?, revision = revision + 1 WHERE id = ? AND family_id = ?",
        (timestamp, timestamp, row["id"], user["family_id"]),
    )


def _suggested_portion(row) -> tuple[float, str]:
    if row["servings"] is not None and float(row["servings"]) > 0:
        return 1.0, "serving"
    if row["finished_weight_g"] is not None and float(row["finished_weight_g"]) > 0:
        return min(100.0, float(row["finished_weight_g"])), "g"
    raise FitnessConflictError("The linked recipe does not have a loggable yield")


def _planned_response(row) -> dict:
    portion, unit = _suggested_portion(row)
    return {
        "meal_plan_id": row["meal_plan_id"],
        "date": row["date"],
        "meal_type": row["meal_type"],
        "meal_id": row["meal_id"],
        "meal_name": row["meal_name"],
        "link_id": row["link_id"],
        "recipe_id": row["recipe_id"],
        "recipe_version_id": row["recipe_version_id"],
        "recipe_name": row["recipe_name"],
        "suggested_portion": portion,
        "suggested_unit": unit,
    }


async def _planned_meal_row(db, *, user: dict, meal_plan_id: str):
    row = await (
        await db.execute(
            "SELECT mp.id AS meal_plan_id, mp.date, mp.meal_type, "
            "m.id AS meal_id, m.name AS meal_name, l.id AS link_id, "
            "v.id AS recipe_version_id, v.servings, v.finished_weight_g, "
            "r.id AS recipe_id, r.name AS recipe_name "
            "FROM meal_plans mp JOIN meals m ON m.id = mp.meal_id "
            "AND m.family_id = mp.family_id AND m.deleted_at IS NULL "
            "JOIN health_household_meal_recipe_links l ON l.meal_id = mp.meal_id "
            "AND l.family_id = mp.family_id AND l.deleted_at IS NULL "
            "JOIN health_recipe_versions v ON v.id = l.recipe_version_id "
            "AND v.family_id = l.family_id AND v.deleted_at IS NULL "
            "JOIN health_recipes r ON r.id = v.recipe_id AND r.family_id = v.family_id "
            "AND r.owner_user_id = v.owner_user_id "
            "WHERE mp.id = ? AND mp.family_id = ? AND mp.deleted_at IS NULL "
            "AND r.deleted_at IS NULL AND r.active = 1 AND r.household_shared = 1",
            (meal_plan_id, user["family_id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Linked household meal plan not found")
    return row


async def list_planned_household_meals(
    db,
    *,
    user: dict,
    planned_date: date,
) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT mp.id AS meal_plan_id, mp.date, mp.meal_type, "
            "m.id AS meal_id, m.name AS meal_name, l.id AS link_id, "
            "v.id AS recipe_version_id, v.servings, v.finished_weight_g, "
            "r.id AS recipe_id, r.name AS recipe_name "
            "FROM meal_plans mp JOIN meals m ON m.id = mp.meal_id "
            "AND m.family_id = mp.family_id AND m.deleted_at IS NULL "
            "JOIN health_household_meal_recipe_links l ON l.meal_id = mp.meal_id "
            "AND l.family_id = mp.family_id AND l.deleted_at IS NULL "
            "JOIN health_recipe_versions v ON v.id = l.recipe_version_id "
            "AND v.family_id = l.family_id AND v.deleted_at IS NULL "
            "JOIN health_recipes r ON r.id = v.recipe_id AND r.family_id = v.family_id "
            "AND r.owner_user_id = v.owner_user_id "
            "WHERE mp.family_id = ? AND mp.date = ? AND mp.deleted_at IS NULL "
            "AND r.deleted_at IS NULL AND r.active = 1 AND r.household_shared = 1 "
            "ORDER BY CASE mp.meal_type WHEN 'breakfast' THEN 1 "
            "WHEN 'lunch' THEN 2 ELSE 3 END, m.name",
            (user["family_id"], planned_date.isoformat()),
        )
    ).fetchall()
    return [_planned_response(row) for row in rows]


def _same_instant(stored: str, requested: datetime) -> bool:
    parsed = datetime.fromisoformat(stored.replace("Z", "+00:00"))
    if parsed.tzinfo is None or requested.tzinfo is None:
        return False
    return parsed.astimezone(timezone.utc) == requested.astimezone(timezone.utc)


def _same_private_log(
    existing,
    *,
    row,
    body: PlannedMealLogRequest,
) -> bool:
    expected_quality = "standard_serving" if body.unit == "serving" else "measured"
    return (
        existing["deleted_at"] is None
        and existing["source_meal_plan_id"] == row["meal_plan_id"]
        and existing["household_meal_link_id"] == row["link_id"]
        and existing["recipe_version_id"] == row["recipe_version_id"]
        and _same_instant(existing["logged_at_utc"], body.logged_at_utc)
        and existing["local_timezone"] == body.local_timezone
        and existing["meal_key"] == row["meal_type"]
        and float(existing["entered_amount"]) == body.portion
        and existing["entered_unit"] == body.unit
        and float(existing["canonical_amount"]) == body.portion
        and existing["canonical_unit"] == body.unit
        and existing["measurement_quality"] == expected_quality
        and existing["notes"] == body.notes
        and existing["client_id"] == body.client_id
        and existing["client_timestamp"] == body.client_timestamp
    )


def _private_log_response(row) -> dict:
    data = decoded_row(row)
    return {
        "id": data["id"],
        "source_meal_plan_id": data["source_meal_plan_id"],
        "household_meal_link_id": data["household_meal_link_id"],
        "recipe_version_id": data["recipe_version_id"],
        "nutrition_date": data["nutrition_date"],
        "meal_type": data["meal_key"],
        "logged_at_utc": data["logged_at_utc"],
        "portion": data["entered_amount"],
        "unit": data["entered_unit"],
        "calories_kcal": data["calories_kcal"],
        "protein_g": data["protein_g"],
    }


async def log_planned_household_meal(
    db,
    *,
    user: dict,
    meal_plan_id: str,
    body: PlannedMealLogRequest,
) -> dict:
    entry_id = str(body.id)
    async with serialized_create(db):
        row = await _planned_meal_row(
            db,
            user=user,
            meal_plan_id=meal_plan_id,
        )
        if body.unit == "serving" and (row["servings"] is None or float(row["servings"]) <= 0):
            raise FitnessConflictError("This recipe is not available by serving")
        if body.unit == "g" and (
            row["finished_weight_g"] is None or float(row["finished_weight_g"]) <= 0
        ):
            raise FitnessConflictError("This recipe is not available by grams")
        existing = await (
            await db.execute(
                "SELECT * FROM health_food_log_entries WHERE id = ?",
                (entry_id,),
            )
        ).fetchone()
        if existing is not None:
            if (
                existing["family_id"] != user["family_id"]
                or existing["owner_user_id"] != user["id"]
                or not _same_private_log(existing, row=row, body=body)
            ):
                raise FitnessConflictError(
                    "That private diary record ID was already used differently"
                )
            return _private_log_response(existing)
        prior = await (
            await db.execute(
                "SELECT 1 FROM health_food_log_entries WHERE family_id = ? "
                "AND owner_user_id = ? AND source_meal_plan_id = ? "
                "AND deleted_at IS NULL",
                (user["family_id"], user["id"], meal_plan_id),
            )
        ).fetchone()
        if prior is not None:
            raise FitnessConflictError("This planned meal is already in your diary")
        payload = FoodLogPayload(
            id=body.id,
            recipe_version_id=row["recipe_version_id"],
            logged_at_utc=body.logged_at_utc,
            local_timezone=body.local_timezone,
            meal_key=row["meal_type"],
            entered_amount=body.portion,
            entered_unit=body.unit,
            canonical_amount=body.portion,
            canonical_unit=body.unit,
            measurement_quality=("standard_serving" if body.unit == "serving" else "measured"),
            notes=body.notes,
            context_tags=[],
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
        logged = await nutrition.upsert_food_log(
            db,
            user=user,
            body=payload,
            record_id=entry_id,
            source_meal_plan_id=meal_plan_id,
            household_meal_link_id=row["link_id"],
        )
    return _private_log_response(logged)
