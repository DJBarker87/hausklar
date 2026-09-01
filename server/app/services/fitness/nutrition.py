"""Owner-scoped food, diary, recipe and body-measurement services."""

import json
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.fitness import (
    BodyMeasurementPayload,
    FoodLogPayload,
    FoodPatch,
    FoodPayload,
    FoodVersionPayload,
    MealTemplatePayload,
    NutritionSettingsUpdate,
    NutritionMealCompletionPayload,
    NutritionTargetPayload,
    RecipeComponentPayload,
    RecipePayload,
    RecipeVersionPayload,
    ServingPayload,
)
from app.services.fitness.common import (
    CanonicalIdentityChangedError,
    FitnessConflictError,
    FitnessNotFoundError,
    append_change,
    canonical_identity_summary,
    decoded_row,
    insert_owned,
    list_owned,
    new_id,
    now_iso,
    owned_row,
    save_owned_rows_history,
    soft_delete_owned,
    update_owned,
)
from app.services.fitness.activity_import import asset_path
from app.services.idempotency import serialized_create
from app.services.record_history import save_history

NUTRIENT_FIELDS = (
    "calories_kcal",
    "protein_g",
    "carbohydrate_g",
    "sugars_g",
    "fat_g",
    "saturated_fat_g",
    "fibre_g",
    "salt_g",
)

# Ordinary foods should be ready to log without forcing every household to build
# a catalogue first. Values are typical references per 100 g (or 100 ml for
# milk), deliberately labelled as estimates because preparation and brands vary.
BASIC_FOOD_SEEDS = (
    ("Potatoes, boiled", "starchy_carbohydrate", "g", 87, 1.9, 20.1, 0.9, 0.1, 0.0, 1.8, 0.01),
    ("Sweet potato, baked", "starchy_carbohydrate", "g", 90, 2.0, 20.7, 6.5, 0.2, 0.0, 3.3, 0.09),
    ("Rice, white, cooked", "starchy_carbohydrate", "g", 130, 2.7, 28.2, 0.1, 0.3, 0.1, 0.4, 0.0),
    ("Rice, brown, cooked", "starchy_carbohydrate", "g", 123, 2.7, 25.6, 0.2, 1.0, 0.2, 1.6, 0.0),
    ("Pasta, cooked", "starchy_carbohydrate", "g", 157, 5.8, 30.9, 0.6, 0.9, 0.2, 1.8, 0.01),
    ("Oats", "breakfast_cereal", "g", 379, 13.2, 67.7, 1.0, 6.5, 1.2, 10.1, 0.01),
    ("Bread, white", "bread", "g", 265, 9.0, 49.0, 5.0, 3.2, 0.7, 2.7, 1.2),
    ("Bread, wholemeal", "bread", "g", 247, 13.0, 41.0, 6.0, 3.4, 0.7, 7.0, 1.0),
    ("Flour tortilla wrap", "bread", "g", 312, 8.3, 52.1, 2.9, 8.3, 2.2, 3.3, 1.4),
    ("Chicken breast, cooked", "meat", "g", 165, 31.0, 0.0, 0.0, 3.6, 1.0, 0.0, 0.19),
    ("Beef mince, 5% fat, cooked", "meat", "g", 172, 26.0, 0.0, 0.0, 7.0, 3.0, 0.0, 0.18),
    ("Salmon, cooked", "fish", "g", 206, 22.0, 0.0, 0.0, 12.0, 3.0, 0.0, 0.15),
    ("Tuna in spring water, drained", "fish", "g", 116, 25.5, 0.0, 0.0, 0.8, 0.2, 0.0, 0.9),
    ("Eggs, boiled", "eggs", "g", 155, 12.6, 1.1, 1.1, 10.6, 3.3, 0.0, 0.31),
    ("Milk, semi-skimmed", "dairy", "ml", 47, 3.6, 4.8, 4.8, 1.7, 1.1, 0.0, 0.1),
    ("Greek yoghurt, 0% fat", "dairy", "g", 59, 10.3, 3.6, 3.2, 0.4, 0.1, 0.0, 0.1),
    ("Cheddar cheese", "dairy", "g", 403, 25.0, 1.3, 0.5, 33.0, 21.0, 0.0, 1.8),
    ("Butter", "fats", "g", 717, 0.9, 0.1, 0.1, 81.1, 51.4, 0.0, 1.6),
    ("Olive oil", "fats", "g", 884, 0.0, 0.0, 0.0, 100.0, 14.0, 0.0, 0.0),
    ("Peanut butter", "nuts", "g", 588, 25.0, 20.0, 9.0, 50.0, 10.0, 6.0, 0.43),
    ("Banana", "fruit", "g", 89, 1.1, 22.8, 12.2, 0.3, 0.1, 2.6, 0.0),
    ("Apple", "fruit", "g", 52, 0.3, 13.8, 10.4, 0.2, 0.0, 2.4, 0.0),
    ("Orange", "fruit", "g", 47, 0.9, 11.8, 9.4, 0.1, 0.0, 2.4, 0.0),
    ("Avocado", "fruit", "g", 160, 2.0, 8.5, 0.7, 14.7, 2.1, 6.7, 0.02),
    ("Broccoli, cooked", "vegetables", "g", 35, 2.4, 7.2, 1.4, 0.4, 0.1, 3.3, 0.04),
    ("Carrots, cooked", "vegetables", "g", 35, 0.8, 8.2, 3.5, 0.2, 0.0, 3.0, 0.08),
    ("Peas, cooked", "vegetables", "g", 84, 5.4, 15.6, 5.9, 0.2, 0.0, 5.5, 0.01),
    ("Baked beans in tomato sauce", "pulses", "g", 78, 4.7, 12.5, 4.7, 0.5, 0.1, 3.7, 0.6),
    ("Lentils, cooked", "pulses", "g", 116, 9.0, 20.0, 1.8, 0.4, 0.1, 7.9, 0.0),
    ("Chickpeas, cooked", "pulses", "g", 164, 8.9, 27.4, 4.8, 2.6, 0.3, 7.6, 0.02),
    ("Kidney beans, cooked", "pulses", "g", 127, 8.7, 22.8, 0.3, 0.5, 0.1, 6.4, 0.02),
)

BASIC_FOOD_SERVINGS = {
    "Potatoes, boiled": ("1 medium potato", 170, "g"),
    "Bread, white": ("1 slice", 38, "g"),
    "Bread, wholemeal": ("1 slice", 36, "g"),
    "Flour tortilla wrap": ("1 wrap", 64, "g"),
    "Chicken breast, cooked": ("1 breast", 170, "g"),
    "Eggs, boiled": ("1 large egg", 50, "g"),
    "Milk, semi-skimmed": ("1 glass", 200, "ml"),
    "Banana": ("1 medium banana", 118, "g"),
    "Apple": ("1 medium apple", 182, "g"),
    "Orange": ("1 medium orange", 130, "g"),
    "Avocado": ("1 medium avocado", 150, "g"),
}

BASIC_FOOD_SOURCE_NOTE = (
    "Typical food-composition value per 100 g or 100 ml; cooking, brand and variety can change it."
)


def authoritative_calories(body: FoodVersionPayload) -> float | None:
    """Printed kcal wins; kJ-only input is converted exactly once."""
    if body.calories_kcal is not None:
        return body.calories_kcal
    if body.source_energy_unit == "kcal":
        return body.source_energy_value
    if body.source_energy_unit == "kj" and body.source_energy_value is not None:
        return body.source_energy_value / 4.184
    return None


def nutrition_date_for(
    logged_at: datetime,
    timezone_name: str,
    day_start_minutes: int,
) -> date:
    try:
        zone = ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError as exc:
        raise ValueError("local_timezone is not a valid IANA timezone") from exc
    if logged_at.tzinfo is None:
        raise ValueError("logged_at_utc must include a timezone")
    local = logged_at.astimezone(zone) - timedelta(minutes=day_start_minutes)
    return local.date()


async def _readable_food_row(db, *, user: dict, food_id: str, include_deleted: bool = False):
    suffix = "" if include_deleted else " AND deleted_at IS NULL"
    row = await (
        await db.execute(
            "SELECT * FROM health_foods WHERE id = ? AND family_id = ? "
            "AND (owner_user_id = ? OR household_shared = 1)" + suffix,
            (food_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Fitness record not found")
    return row


async def readable_food_version(db, *, user: dict, version_id: str, include_deleted: bool = False):
    suffix = "" if include_deleted else " AND v.deleted_at IS NULL AND f.deleted_at IS NULL"
    row = await (
        await db.execute(
            "SELECT v.* FROM health_food_versions v JOIN health_foods f "
            "ON f.id = v.food_id AND f.family_id = v.family_id "
            "WHERE v.id = ? AND v.family_id = ? "
            "AND (f.owner_user_id = ? OR f.household_shared = 1)" + suffix,
            (version_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Fitness record not found")
    return row


async def _readable_recipe_row(db, *, user: dict, recipe_id: str, include_deleted: bool = False):
    suffix = "" if include_deleted else " AND deleted_at IS NULL"
    row = await (
        await db.execute(
            "SELECT * FROM health_recipes WHERE id = ? AND family_id = ? "
            "AND (owner_user_id = ? OR household_shared = 1)" + suffix,
            (recipe_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Fitness record not found")
    return row


async def readable_recipe_version(
    db, *, user: dict, version_id: str, include_deleted: bool = False
):
    suffix = "" if include_deleted else " AND v.deleted_at IS NULL AND r.deleted_at IS NULL"
    row = await (
        await db.execute(
            "SELECT v.* FROM health_recipe_versions v JOIN health_recipes r "
            "ON r.id = v.recipe_id AND r.family_id = v.family_id "
            "WHERE v.id = ? AND v.family_id = ? "
            "AND (r.owner_user_id = ? OR r.household_shared = 1)" + suffix,
            (version_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Fitness record not found")
    return row


async def resolve_food_id(db, *, user: dict, food_id: str) -> tuple[str, list[str]]:
    seen: list[str] = []
    current = food_id
    for _ in range(100):
        if current in seen:
            raise FitnessConflictError("Food merge redirect loop")
        seen.append(current)
        row = await _readable_food_row(db, user=user, food_id=current, include_deleted=True)
        target = row["merged_into_food_id"]
        if not target:
            return current, seen[:-1]
        current = target
    raise FitnessConflictError("Food merge redirect chain is too long")


async def _food_response(db, *, user: dict, row, redirected_from: str | None = None) -> dict:
    data = decoded_row(row)
    definition_owner_id = row["owner_user_id"]
    versions = await (
        await db.execute(
            "SELECT * FROM health_food_versions WHERE family_id = ? AND owner_user_id = ? "
            "AND food_id = ? AND deleted_at IS NULL ORDER BY version_number DESC",
            (user["family_id"], definition_owner_id, data["id"]),
        )
    ).fetchall()
    servings = await (
        await db.execute(
            "SELECT * FROM health_food_servings WHERE family_id = ? AND owner_user_id = ? "
            "AND food_id = ? AND deleted_at IS NULL AND active = 1 "
            "ORDER BY is_default DESC, name",
            (user["family_id"], definition_owner_id, data["id"]),
        )
    ).fetchall()
    data["versions"] = [
        decoded_row(version, json_fields={"micronutrients_json"}) for version in versions
    ]
    data["current_version"] = data["versions"][0] if data["versions"] else None
    data["servings"] = [decoded_row(serving) for serving in servings]
    data["editable"] = definition_owner_id == user["id"]
    if not data["editable"]:
        data["favourite"] = False
        for version in data["versions"]:
            version.pop("label_asset_id", None)
    usage = await (
        await db.execute(
            "SELECT l.logged_at_utc AS last_logged_at_utc, l.entered_amount AS last_amount, "
            "l.entered_unit AS last_unit, counts.frequency_count "
            "FROM health_food_log_entries l JOIN health_food_versions v "
            "ON v.id = l.food_version_id AND v.family_id = l.family_id "
            "JOIN (SELECT COUNT(*) AS frequency_count FROM health_food_log_entries cl "
            "JOIN health_food_versions cv ON cv.id = cl.food_version_id "
            "AND cv.family_id = cl.family_id WHERE cl.family_id = ? "
            "AND cl.owner_user_id = ? AND cv.food_id = ? AND cl.deleted_at IS NULL) counts "
            "WHERE l.family_id = ? AND l.owner_user_id = ? AND v.food_id = ? "
            "AND l.deleted_at IS NULL ORDER BY l.logged_at_utc DESC, l.created_at DESC LIMIT 1",
            (
                user["family_id"],
                user["id"],
                data["id"],
                user["family_id"],
                user["id"],
                data["id"],
            ),
        )
    ).fetchone()
    data["quick_use"] = (
        {
            "last_logged_at_utc": usage["last_logged_at_utc"],
            "frequency_count": int(usage["frequency_count"]),
            "last_amount": usage["last_amount"],
            "last_unit": usage["last_unit"],
            "usual_amount": usage["last_amount"],
            "usual_unit": usage["last_unit"],
        }
        if usage and usage["frequency_count"]
        else None
    )
    if redirected_from:
        data["redirect"] = {"source_id": redirected_from, "target_id": data["id"]}
    return data


async def ensure_family_basic_foods(db, *, user: dict) -> int:
    """Create one shared, idempotent starter catalogue for the family."""
    created = 0
    async with serialized_create(db):
        owner_row = await (
            await db.execute(
                "SELECT * FROM users WHERE family_id = ? AND deleted_at IS NULL "
                "ORDER BY CASE role WHEN 'admin' THEN 0 ELSE 1 END, priority DESC, created_at LIMIT 1",
                (user["family_id"],),
            )
        ).fetchone()
        owner = dict(owner_row) if owner_row is not None else user
        for seed in BASIC_FOOD_SEEDS:
            (
                name,
                category_key,
                reference_unit,
                calories_kcal,
                protein_g,
                carbohydrate_g,
                sugars_g,
                fat_g,
                saturated_fat_g,
                fibre_g,
                salt_g,
            ) = seed
            existing = await (
                await db.execute(
                    "SELECT id FROM health_foods WHERE family_id = ? "
                    "AND household_shared = 1 AND LOWER(name) = LOWER(?) "
                    "LIMIT 1",
                    (user["family_id"], name),
                )
            ).fetchone()
            if existing is not None:
                continue
            food_id = new_id()
            await insert_owned(
                db,
                table="health_foods",
                record_id=food_id,
                values={
                    "name": name,
                    "category_key": category_key,
                    "household_shared": True,
                    "favourite": False,
                    "active": True,
                    "revision": 1,
                },
                user=owner,
            )
            await insert_owned(
                db,
                table="health_food_versions",
                record_id=new_id(),
                values={
                    "food_id": food_id,
                    "version_number": 1,
                    "reference_amount": 100,
                    "reference_unit": reference_unit,
                    "calories_kcal": calories_kcal,
                    "protein_g": protein_g,
                    "carbohydrate_g": carbohydrate_g,
                    "sugars_g": sugars_g,
                    "fat_g": fat_g,
                    "saturated_fat_g": saturated_fat_g,
                    "fibre_g": fibre_g,
                    "salt_g": salt_g,
                    "micronutrients_json": {},
                    "source_type": "reference",
                    "source_note": BASIC_FOOD_SOURCE_NOTE,
                    "confidence": "estimated",
                    "revision": 1,
                },
                user=owner,
            )
            serving = BASIC_FOOD_SERVINGS.get(name)
            if serving is not None:
                serving_name, canonical_amount, canonical_unit = serving
                await insert_owned(
                    db,
                    table="health_food_servings",
                    record_id=new_id(),
                    values={
                        "food_id": food_id,
                        "name": serving_name,
                        "amount": 1,
                        "unit": "item",
                        "canonical_amount": canonical_amount,
                        "canonical_unit": canonical_unit,
                        "measurement_quality": "standard_serving",
                        "is_default": True,
                        "active": True,
                        "revision": 1,
                    },
                    user=owner,
                )
            created += 1
    return created


async def list_foods(
    db,
    *,
    user: dict,
    query: str | None = None,
    favourites: bool = False,
) -> list[dict]:
    await ensure_family_basic_foods(db, user=user)
    sql = (
        "SELECT * FROM health_foods WHERE family_id = ? AND deleted_at IS NULL "
        "AND active = 1 AND (owner_user_id = ? OR household_shared = 1)"
    )
    params: list = [user["family_id"], user["id"]]
    if favourites:
        sql += " AND owner_user_id = ? AND favourite = 1"
        params.append(user["id"])
    if query:
        sql += " AND (LOWER(name) LIKE ? OR LOWER(COALESCE(brand,'')) LIKE ?)"
        term = f"%{query.lower()}%"
        params.extend((term, term))
    sql += " ORDER BY favourite DESC, name LIMIT 200"
    rows = await (await db.execute(sql, params)).fetchall()
    responses: list[dict] = []
    for row in rows:
        responses.append(await _food_response(db, user=user, row=row))
    return responses


async def get_food(db, *, user: dict, food_id: str) -> dict:
    canonical_id, aliases = await resolve_food_id(db, user=user, food_id=food_id)
    row = await _readable_food_row(db, user=user, food_id=canonical_id)
    return await _food_response(
        db,
        user=user,
        row=row,
        redirected_from=food_id if aliases else None,
    )


async def add_food_version(
    db,
    *,
    user: dict,
    food_id: str,
    body: FoodVersionPayload,
    version_id: str | None = None,
) -> dict:
    if body.food_id is not None and str(body.food_id) != food_id:
        raise FitnessConflictError("Food version parent does not match its route")
    canonical_id, aliases = await resolve_food_id(db, user=user, food_id=food_id)
    if aliases and canonical_id != food_id:
        food_id = canonical_id
    await owned_row(db, table="health_foods", record_id=food_id, user=user)
    identifier = version_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT * FROM health_food_versions WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None:
        raise FitnessConflictError(
            "Those saved nutrition details cannot be overwritten; create a new version"
        )
    label_asset_id = str(body.label_asset_id) if body.label_asset_id else None
    if label_asset_id:
        label = await owned_row(
            db,
            table="health_file_assets",
            record_id=label_asset_id,
            user=user,
        )
        if (
            label["asset_kind"] != "nutrition_label"
            or label["storage_class"] != "private_required"
            or label["state"] != "staged"
            or not asset_path(label).is_file()
        ):
            raise FitnessConflictError("A staged private nutrition label is required")
    current = await (
        await db.execute(
            "SELECT COALESCE(MAX(version_number), 0) FROM health_food_versions "
            "WHERE family_id = ? AND owner_user_id = ? AND food_id = ?",
            (user["family_id"], user["id"], food_id),
        )
    ).fetchone()
    values = body.model_dump(
        exclude={
            "id",
            "client_id",
            "client_timestamp",
            "food_id",
            "micronutrients",
        }
    )
    values.update(
        {
            "food_id": food_id,
            "version_number": int(current[0]) + 1,
            "calories_kcal": authoritative_calories(body),
            "micronutrients_json": body.micronutrients,
            "revision": 1,
        }
    )
    await insert_owned(
        db,
        table="health_food_versions",
        record_id=identifier,
        values=values,
        user=user,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    if label_asset_id:
        await update_owned(
            db,
            table="health_file_assets",
            record_id=label_asset_id,
            values={"state": "ready"},
            user=user,
            record_sync_change=False,
        )
    await update_owned(
        db,
        table="health_foods",
        record_id=food_id,
        values={},
        user=user,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    return decoded_row(
        await owned_row(db, table="health_food_versions", record_id=identifier, user=user),
        json_fields={"micronutrients_json"},
    )


async def upsert_food(
    db,
    *,
    user: dict,
    body: FoodPayload,
    record_id: str | None = None,
) -> dict:
    food_id = record_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT * FROM health_foods WHERE id = ? AND family_id = ? AND owner_user_id = ?",
            (food_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None and existing["merged_into_food_id"]:
        target_id = existing["merged_into_food_id"]
        raise CanonicalIdentityChangedError(
            "food",
            target_id,
            await canonical_identity_summary(
                db, user=user, entity_type="food", target_id=target_id
            ),
        )
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp", "version"})
    if existing is None:
        await insert_owned(
            db,
            table="health_foods",
            record_id=food_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_foods",
            record_id=food_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    if body.version is not None and existing is None:
        await add_food_version(db, user=user, food_id=food_id, body=body.version)
    return await get_food(db, user=user, food_id=food_id)


async def patch_food(db, *, user: dict, food_id: str, body: FoodPatch) -> dict:
    row = await owned_row(
        db, table="health_foods", record_id=food_id, user=user, include_deleted=True
    )
    if row["merged_into_food_id"]:
        target_id = row["merged_into_food_id"]
        raise CanonicalIdentityChangedError(
            "food",
            target_id,
            await canonical_identity_summary(
                db, user=user, entity_type="food", target_id=target_id
            ),
        )
    values = body.model_dump(exclude_unset=True)
    if values:
        await update_owned(db, table="health_foods", record_id=food_id, values=values, user=user)
    return await get_food(db, user=user, food_id=food_id)


async def add_serving(
    db,
    *,
    user: dict,
    food_id: str,
    body: ServingPayload,
    serving_id: str | None = None,
) -> dict:
    if body.food_id is not None and str(body.food_id) != food_id:
        raise FitnessConflictError("Serving parent does not match its route")
    canonical_id, _ = await resolve_food_id(db, user=user, food_id=food_id)
    await owned_row(db, table="health_foods", record_id=canonical_id, user=user)
    serving_id = serving_id or new_id(body.id)
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp", "food_id"})
    values.update({"food_id": canonical_id, "revision": 1})
    existing = await (
        await db.execute(
            "SELECT * FROM health_food_servings WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (serving_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if body.is_default:
        await save_owned_rows_history(
            db,
            table="health_food_servings",
            user=user,
            where="food_id = ? AND id <> ? AND is_default = 1 AND deleted_at IS NULL",
            params=(canonical_id, serving_id),
        )
        await db.execute(
            "UPDATE health_food_servings SET is_default = 0, updated_at = ? "
            "WHERE family_id = ? AND owner_user_id = ? AND food_id = ? "
            "AND id <> ? AND deleted_at IS NULL",
            (now_iso(), user["family_id"], user["id"], canonical_id, serving_id),
        )
    if existing is None:
        await insert_owned(
            db,
            table="health_food_servings",
            record_id=serving_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        if existing["food_id"] != canonical_id:
            raise FitnessConflictError("Serving identity belongs to another food")
        await update_owned(
            db,
            table="health_food_servings",
            record_id=serving_id,
            values={key: value for key, value in values.items() if key != "revision"},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(db, table="health_food_servings", record_id=serving_id, user=user)
    )


async def preview_food_merge(db, *, user: dict, source_id: str, target_id: str) -> dict:
    source_final, _ = await resolve_food_id(db, user=user, food_id=source_id)
    target_final, _ = await resolve_food_id(db, user=user, food_id=target_id)
    if source_final == target_final:
        return {
            "source_id": source_id,
            "target_id": target_final,
            "already_merged": True,
            "versions": 0,
            "servings": 0,
        }
    await owned_row(db, table="health_foods", record_id=source_final, user=user)
    await owned_row(db, table="health_foods", record_id=target_final, user=user)
    versions = await (
        await db.execute(
            "SELECT COUNT(*) FROM health_food_versions WHERE family_id = ? AND owner_user_id = ? "
            "AND food_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_final),
        )
    ).fetchone()
    servings = await (
        await db.execute(
            "SELECT COUNT(*) FROM health_food_servings WHERE family_id = ? AND owner_user_id = ? "
            "AND food_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_final),
        )
    ).fetchone()
    return {
        "source_id": source_final,
        "target_id": target_final,
        "already_merged": False,
        "versions": int(versions[0]),
        "servings": int(servings[0]),
    }


async def merge_foods(db, *, user: dict, source_id: str, target_id: str) -> dict:
    async with serialized_create(db):
        preview = await preview_food_merge(db, user=user, source_id=source_id, target_id=target_id)
        if preview["already_merged"]:
            return preview
        source_id = preview["source_id"]
        target_id = preview["target_id"]
        max_row = await (
            await db.execute(
                "SELECT COALESCE(MAX(version_number), 0) FROM health_food_versions "
                "WHERE family_id = ? AND owner_user_id = ? AND food_id = ?",
                (user["family_id"], user["id"], target_id),
            )
        ).fetchone()
        versions = await (
            await db.execute(
                "SELECT id FROM health_food_versions WHERE family_id = ? AND owner_user_id = ? "
                "AND food_id = ? AND deleted_at IS NULL ORDER BY version_number, created_at",
                (user["family_id"], user["id"], source_id),
            )
        ).fetchall()
        await save_owned_rows_history(
            db,
            table="health_food_versions",
            user=user,
            where="food_id = ? AND deleted_at IS NULL",
            params=(source_id,),
        )
        version_number = int(max_row[0])
        for version in versions:
            version_number += 1
            await db.execute(
                "UPDATE health_food_versions SET food_id = ?, version_number = ?, updated_at = ? "
                "WHERE id = ? AND family_id = ? AND owner_user_id = ?",
                (
                    target_id,
                    version_number,
                    now_iso(),
                    version["id"],
                    user["family_id"],
                    user["id"],
                ),
            )
        target_names = {
            row[0].casefold()
            for row in await (
                await db.execute(
                    "SELECT name FROM health_food_servings WHERE family_id = ? AND owner_user_id = ? "
                    "AND food_id = ? AND active = 1 AND deleted_at IS NULL",
                    (user["family_id"], user["id"], target_id),
                )
            ).fetchall()
        }
        source_servings = await (
            await db.execute(
                "SELECT id, name FROM health_food_servings WHERE family_id = ? AND owner_user_id = ? "
                "AND food_id = ? AND deleted_at IS NULL",
                (user["family_id"], user["id"], source_id),
            )
        ).fetchall()
        await save_owned_rows_history(
            db,
            table="health_food_servings",
            user=user,
            where="food_id = ? AND deleted_at IS NULL",
            params=(source_id,),
        )
        timestamp = now_iso()
        for serving in source_servings:
            if serving["name"].casefold() in target_names:
                await db.execute(
                    "UPDATE health_food_servings SET active = 0, deleted_at = ?, updated_at = ? "
                    "WHERE id = ? AND family_id = ? AND owner_user_id = ?",
                    (timestamp, timestamp, serving["id"], user["family_id"], user["id"]),
                )
            else:
                await db.execute(
                    "UPDATE health_food_servings SET food_id = ?, updated_at = ? WHERE id = ? "
                    "AND family_id = ? AND owner_user_id = ?",
                    (target_id, timestamp, serving["id"], user["family_id"], user["id"]),
                )
        await save_history(db, "health_foods", source_id, user["id"], family_id=user["family_id"])
        await db.execute(
            "UPDATE health_foods SET merged_into_food_id = ?, merged_at = ?, active = 0, "
            "updated_at = ?, revision = revision + 1 WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (target_id, timestamp, timestamp, source_id, user["family_id"], user["id"]),
        )
        await save_owned_rows_history(
            db,
            table="health_foods",
            user=user,
            where="merged_into_food_id = ? AND id <> ?",
            params=(source_id, source_id),
        )
        await db.execute(
            "UPDATE health_foods SET merged_into_food_id = ?, updated_at = ?, revision = revision + 1 "
            "WHERE family_id = ? AND owner_user_id = ? AND merged_into_food_id = ? AND id <> ?",
            (target_id, timestamp, user["family_id"], user["id"], source_id, source_id),
        )
        await update_owned(
            db,
            table="health_foods",
            record_id=target_id,
            values={},
            user=user,
            now=timestamp,
        )
        source_revision = await (
            await db.execute(
                "SELECT revision FROM health_foods WHERE id = ? AND family_id = ? "
                "AND owner_user_id = ?",
                (source_id, user["family_id"], user["id"]),
            )
        ).fetchone()
        await append_change(
            db,
            entity_type="food",
            entity_id=source_id,
            revision=int(source_revision["revision"]),
            operation="redirect",
            user=user,
            data={"target_id": target_id},
            changed_at=timestamp,
        )
        preview["versions"] = len(versions)
        preview["servings"] = len(source_servings)
        return preview


async def _source_nutrients(db, *, user: dict, body: FoodLogPayload) -> tuple[dict, float]:
    if body.food_version_id:
        row = await readable_food_version(db, user=user, version_id=str(body.food_version_id))
        if body.canonical_unit != row["reference_unit"]:
            raise FitnessConflictError(
                "Food log canonical_unit must match the immutable food-version basis"
            )
        reference = float(row["reference_amount"])
    else:
        row = await readable_recipe_version(db, user=user, version_id=str(body.recipe_version_id))
        if body.canonical_unit == "g" and row["finished_weight_g"] is not None:
            reference = float(row["finished_weight_g"])
        elif body.canonical_unit == "serving" and row["servings"] is not None:
            reference = float(row["servings"])
        else:
            raise FitnessConflictError(
                "Recipe logs require grams with finished weight or servings with a serving yield"
            )
    return dict(row), body.canonical_amount / reference


async def upsert_food_log(
    db,
    *,
    user: dict,
    body: FoodLogPayload,
    record_id: str | None = None,
    source_meal_plan_id: str | None = None,
    household_meal_link_id: str | None = None,
) -> dict:
    entry_id = record_id or new_id(body.id)
    source, scale = await _source_nutrients(db, user=user, body=body)
    settings = await (
        await db.execute(
            "SELECT nutrition_day_start_minutes FROM health_user_settings "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    boundary = int(settings[0]) if settings else 240
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp", "context_tags"})
    values["nutrition_date"] = nutrition_date_for(
        body.logged_at_utc, body.local_timezone, boundary
    ).isoformat()
    values["context_tags_json"] = body.context_tags
    values["micronutrients_json"] = json.loads(source.get("micronutrients_json") or "{}")
    if source_meal_plan_id is not None:
        values["source_meal_plan_id"] = source_meal_plan_id
    if household_meal_link_id is not None:
        values["household_meal_link_id"] = household_meal_link_id
    for field in NUTRIENT_FIELDS:
        value = source.get(field)
        values[field] = None if value is None else float(value) * scale
    existing = await (
        await db.execute(
            "SELECT * FROM health_food_log_entries WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (entry_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None and existing["source_meal_plan_id"] is not None:
        requested_recipe_id = (
            str(body.recipe_version_id) if body.recipe_version_id is not None else None
        )
        if (
            requested_recipe_id != existing["recipe_version_id"]
            or body.food_version_id is not None
            or (
                source_meal_plan_id is not None
                and source_meal_plan_id != existing["source_meal_plan_id"]
            )
            or (
                household_meal_link_id is not None
                and household_meal_link_id != existing["household_meal_link_id"]
            )
        ):
            raise FitnessConflictError(
                "A planned-meal diary entry must keep its original recipe link"
            )
    if existing is None:
        await insert_owned(
            db,
            table="health_food_log_entries",
            record_id=entry_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_food_log_entries",
            record_id=entry_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(db, table="health_food_log_entries", record_id=entry_id, user=user),
        json_fields={"micronutrients_json", "context_tags_json"},
    )


async def list_food_log(db, *, user: dict, nutrition_date: date) -> dict:
    rows = await list_owned(
        db,
        table="health_food_log_entries",
        user=user,
        where="nutrition_date = ?",
        params=(nutrition_date.isoformat(),),
        order_by="logged_at_utc, created_at",
    )
    entries = [
        decoded_row(row, json_fields={"micronutrients_json", "context_tags_json"}) for row in rows
    ]
    known_subtotals = {
        field: sum(float(entry[field]) for entry in entries if entry[field] is not None)
        for field in NUTRIENT_FIELDS
    }
    nutrient_completeness = {
        field: (
            sum(entry[field] is not None for entry in entries) / len(entries) if entries else 1.0
        )
        for field in NUTRIENT_FIELDS
    }
    totals = {
        field: known_subtotals[field] if nutrient_completeness[field] == 1.0 else None
        for field in NUTRIENT_FIELDS
    }
    measured_calories = sum(
        float(entry["calories_kcal"] or 0)
        for entry in entries
        if entry["measurement_quality"] in {"weighed", "measured", "standard_serving"}
    )
    estimated_calories = sum(
        float(entry["calories_kcal"] or 0)
        for entry in entries
        if entry["measurement_quality"] in {"estimated", "restaurant_estimate"}
    )
    known_calories = known_subtotals["calories_kcal"]

    meal_totals: dict[str, dict[str, float | None]] = {}
    for meal_key in dict.fromkeys(entry["meal_key"] for entry in entries):
        meal_entries = [entry for entry in entries if entry["meal_key"] == meal_key]
        meal_totals[meal_key] = {
            field: (
                sum(float(entry[field]) for entry in meal_entries)
                if all(entry[field] is not None for entry in meal_entries)
                else None
            )
            for field in NUTRIENT_FIELDS
        }

    source_rows = await (
        await db.execute(
            "SELECT l.id, l.food_version_id, l.recipe_version_id, "
            "f.id AS food_id, f.name AS food_name, r.id AS recipe_id, "
            "r.name AS recipe_name FROM health_food_log_entries l "
            "LEFT JOIN health_food_versions fv ON fv.id = l.food_version_id "
            "AND fv.family_id = l.family_id "
            "LEFT JOIN health_foods f ON f.id = fv.food_id AND f.family_id = l.family_id "
            "AND (f.owner_user_id = ? OR f.household_shared = 1) "
            "LEFT JOIN health_recipe_versions rv ON rv.id = l.recipe_version_id "
            "AND rv.family_id = l.family_id "
            "LEFT JOIN health_recipes r ON r.id = rv.recipe_id AND r.family_id = l.family_id "
            "AND (r.owner_user_id = ? OR r.household_shared = 1) "
            "WHERE l.family_id = ? AND l.owner_user_id = ? "
            "AND l.nutrition_date = ? AND l.deleted_at IS NULL",
            (
                user["id"],
                user["id"],
                user["family_id"],
                user["id"],
                nutrition_date.isoformat(),
            ),
        )
    ).fetchall()
    sources = {row["id"]: row for row in source_rows}
    contributors: list[dict] = []
    for field in NUTRIENT_FIELDS:
        grouped: dict[tuple[str, str, str], dict[str, float | int]] = {}
        for entry in entries:
            if entry[field] is None:
                continue
            source = sources.get(entry["id"])
            if source and source["food_id"]:
                key = ("food", source["food_id"], source["food_name"] or "Saved food")
            elif source and source["recipe_id"]:
                key = (
                    "recipe",
                    source["recipe_id"],
                    source["recipe_name"] or "Saved recipe",
                )
            else:
                key = ("unknown", "unknown", "Saved item")
            current = grouped.setdefault(key, {"value": 0.0, "entry_count": 0})
            current["value"] = float(current["value"]) + float(entry[field])
            current["entry_count"] = int(current["entry_count"]) + 1
        total = known_subtotals[field]
        for (kind, key, label), item in sorted(
            grouped.items(), key=lambda pair: float(pair[1]["value"]), reverse=True
        )[:8]:
            value = float(item["value"])
            contributors.append(
                {
                    "key": key,
                    "label": label,
                    "kind": kind,
                    "nutrient_key": field,
                    "value": value,
                    "share": value / total if total > 0 else None,
                    "entry_count": int(item["entry_count"]),
                }
            )

    target_rows = await list_nutrition_targets(db, user=user, effective_on=nutrition_date)
    training_day = (
        await (
            await db.execute(
                "SELECT 1 FROM health_planned_sessions WHERE family_id = ? "
                "AND owner_user_id = ? AND scheduled_date = ? "
                "AND status NOT IN ('proposed','cancelled','skipped') "
                "AND deleted_at IS NULL LIMIT 1",
                (user["family_id"], user["id"], nutrition_date.isoformat()),
            )
        ).fetchone()
        is not None
    )
    phase_ids = {
        row["id"]
        for row in await (
            await db.execute(
                "SELECT id FROM health_training_phases WHERE family_id = ? "
                "AND owner_user_id = ? AND starts_on <= ? "
                "AND (ends_on IS NULL OR ends_on >= ?) AND active = 1 "
                "AND deleted_at IS NULL",
                (
                    user["family_id"],
                    user["id"],
                    nutrition_date.isoformat(),
                    nutrition_date.isoformat(),
                ),
            )
        ).fetchall()
    }
    targets: dict[str, float] = {}
    for target in target_rows:
        if not target["active"]:
            continue
        metric_key = str(target["metric_key"]).removeprefix("nutrition.")
        if metric_key not in NUTRIENT_FIELDS or metric_key in targets:
            continue
        if target["target_type"] == "phase" and target["phase_id"] not in phase_ids:
            continue
        if target["target_type"] == "range":
            value = target["target_max"]
        elif target["target_type"] == "training_rest":
            value = target["training_day_value"] if training_day else target["rest_day_value"]
        else:
            value = target["target_value"]
        if value is not None:
            targets[metric_key] = float(value)
    remaining = {
        field: (targets[field] - totals[field] if totals[field] is not None else None)
        for field in targets
    }
    return {
        "nutrition_date": nutrition_date.isoformat(),
        "date": nutrition_date.isoformat(),
        "entries": entries,
        "totals": totals,
        "targets": targets,
        "remaining": remaining,
        "meal_totals": meal_totals,
        "contributors": contributors,
        "known_subtotals": known_subtotals,
        "nutrient_completeness": nutrient_completeness,
        "uncertain_nutrients": [
            field for field, completeness in nutrient_completeness.items() if completeness < 1
        ],
        "measured_share": measured_calories / known_calories if known_calories > 0 else None,
        "measured_ratio": measured_calories / known_calories if known_calories > 0 else None,
        "estimated_share": estimated_calories / known_calories if known_calories > 0 else None,
    }


async def list_meal_completions(db, *, user: dict, nutrition_date: date) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_nutrition_meal_completions",
        user=user,
        where="nutrition_date = ?",
        params=(nutrition_date.isoformat(),),
        order_by="completed_at, created_at",
    )
    return [decoded_row(row) for row in rows]


async def complete_meal(
    db,
    *,
    user: dict,
    body: NutritionMealCompletionPayload,
) -> dict:
    existing = await (
        await db.execute(
            "SELECT * FROM health_nutrition_meal_completions "
            "WHERE family_id = ? AND owner_user_id = ? AND nutrition_date = ? "
            "AND meal_key = ? AND deleted_at IS NULL LIMIT 1",
            (user["family_id"], user["id"], body.nutrition_date.isoformat(), body.meal_key),
        )
    ).fetchone()
    if existing is not None:
        return decoded_row(existing)
    completion_id = new_id(body.id)
    completed_at = now_iso()
    await insert_owned(
        db,
        table="health_nutrition_meal_completions",
        record_id=completion_id,
        values={
            "nutrition_date": body.nutrition_date.isoformat(),
            "meal_key": body.meal_key,
            "completed_at": completed_at,
            "revision": 1,
        },
        user=user,
        now=completed_at,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
        record_sync_change=False,
    )
    return decoded_row(
        await owned_row(
            db,
            table="health_nutrition_meal_completions",
            record_id=completion_id,
            user=user,
        )
    )


async def nutrition_analysis(
    db,
    *,
    user: dict,
    start: date,
    end: date,
) -> dict:
    rows = await (
        await db.execute(
            "SELECT l.*, f.id AS resolved_food_id, f.name AS resolved_food_name, "
            "r.id AS resolved_recipe_id, r.name AS resolved_recipe_name "
            "FROM health_food_log_entries l "
            "LEFT JOIN health_food_versions fv ON fv.id = l.food_version_id "
            "AND fv.family_id = l.family_id "
            "LEFT JOIN health_foods f ON f.id = fv.food_id AND f.family_id = l.family_id "
            "AND (f.owner_user_id = ? OR f.household_shared = 1) "
            "AND f.deleted_at IS NULL "
            "LEFT JOIN health_recipe_versions rv ON rv.id = l.recipe_version_id "
            "AND rv.family_id = l.family_id "
            "LEFT JOIN health_recipes r ON r.id = rv.recipe_id AND r.family_id = l.family_id "
            "AND (r.owner_user_id = ? OR r.household_shared = 1) "
            "AND r.deleted_at IS NULL "
            "WHERE l.family_id = ? AND l.owner_user_id = ? AND l.deleted_at IS NULL "
            "AND l.nutrition_date BETWEEN ? AND ? ORDER BY l.nutrition_date, l.logged_at_utc",
            (
                user["id"],
                user["id"],
                user["family_id"],
                user["id"],
                start.isoformat(),
                end.isoformat(),
            ),
        )
    ).fetchall()
    days = max((end - start).days + 1, 1)
    known_totals = {
        field: sum(float(row[field]) for row in rows if row[field] is not None)
        for field in NUTRIENT_FIELDS
    }
    nutrient_completeness = {
        field: (sum(row[field] is not None for row in rows) / len(rows) if rows else 1.0)
        for field in NUTRIENT_FIELDS
    }
    totals = {
        field: known_totals[field] if nutrient_completeness[field] == 1.0 else None
        for field in NUTRIENT_FIELDS
    }
    known_by_meal: dict[str, float] = {}
    missing_by_meal: set[str] = set()
    estimated = 0.0
    for row in rows:
        calories = row["calories_kcal"]
        if calories is None:
            missing_by_meal.add(row["meal_key"])
            continue
        calories = float(calories)
        known_by_meal[row["meal_key"]] = known_by_meal.get(row["meal_key"], 0) + calories
        if row["measurement_quality"] in {"estimated", "restaurant_estimate"}:
            estimated += calories
    by_meal = {
        key: None if key in missing_by_meal else value for key, value in known_by_meal.items()
    }
    by_meal.update({key: None for key in missing_by_meal if key not in by_meal})

    contributor_metrics = (
        "calories_kcal",
        "protein_g",
        "fibre_g",
        "sugars_g",
        "saturated_fat_g",
        "salt_g",
    )
    grouped: dict[tuple[str, str, str, str], dict] = {}
    for row in rows:
        if row["resolved_food_id"]:
            item_kind = "food"
            item_id = row["resolved_food_id"]
            label = row["resolved_food_name"] or "Saved food"
        elif row["resolved_recipe_id"]:
            item_kind = "recipe"
            item_id = row["resolved_recipe_id"]
            label = row["resolved_recipe_name"] or "Saved recipe"
        else:
            # Application validation prevents this for live writes. If a legacy
            # row has lost its parent identity, do not invent an exact item name.
            continue
        key = (item_kind, item_id, label, row["meal_key"])
        item = grouped.setdefault(
            key,
            {
                "entry_count": 0,
                "days": set(),
                "amounts": {},
                "estimated_entries": 0,
                "totals": {metric: 0.0 for metric in contributor_metrics},
                "known": {metric: 0 for metric in contributor_metrics},
            },
        )
        item["entry_count"] += 1
        item["days"].add(row["nutrition_date"])
        unit = row["entered_unit"]
        item["amounts"].setdefault(unit, []).append(float(row["entered_amount"]))
        if row["measurement_quality"] in {"estimated", "restaurant_estimate"}:
            item["estimated_entries"] += 1
        for metric in contributor_metrics:
            if row[metric] is not None:
                item["totals"][metric] += float(row[metric])
                item["known"][metric] += 1

    contributors: list[dict] = []
    for metric in contributor_metrics:
        metric_items: list[dict] = []
        denominator = known_totals[metric]
        for (item_kind, item_id, label, meal_key), item in grouped.items():
            if not item["known"][metric]:
                continue
            typical_amount = None
            typical_unit = None
            if len(item["amounts"]) == 1:
                typical_unit, amounts = next(iter(item["amounts"].items()))
                ordered = sorted(amounts)
                middle = len(ordered) // 2
                typical_amount = (
                    ordered[middle]
                    if len(ordered) % 2
                    else (ordered[middle - 1] + ordered[middle]) / 2
                )
            total = float(item["totals"][metric])
            metric_items.append(
                {
                    "item_id": item_id,
                    "item_kind": item_kind,
                    "label": label,
                    "meal_key": meal_key,
                    "nutrient_key": metric,
                    "total": total,
                    "share": total / denominator if denominator > 0 else None,
                    "entry_count": item["entry_count"],
                    "sample_days": len(item["days"]),
                    "typical_amount": typical_amount,
                    "typical_unit": typical_unit,
                }
            )
        contributors.extend(
            sorted(
                metric_items,
                key=lambda item: (-item["total"], item["label"], item["meal_key"]),
            )[:8]
        )

    logged_day_keys = sorted({row["nutrition_date"] for row in rows})
    logged_days = len(logged_day_keys)
    diary_day_completeness = logged_days / days
    calorie_completeness = nutrient_completeness["calories_kcal"]
    daily_calories = {day_key: 0.0 for day_key in logged_day_keys}
    for row in rows:
        if row["calories_kcal"] is not None:
            daily_calories[row["nutrition_date"]] += float(row["calories_kcal"])

    target_rows = await (
        await db.execute(
            "SELECT * FROM health_nutrition_targets WHERE family_id = ? "
            "AND owner_user_id = ? AND metric_key IN "
            "('nutrition.calories_kcal','calories_kcal') AND active = 1 "
            "AND effective_from <= ? AND (effective_until IS NULL OR effective_until >= ?) "
            "AND deleted_at IS NULL ORDER BY effective_from DESC, updated_at DESC",
            (user["family_id"], user["id"], end.isoformat(), start.isoformat()),
        )
    ).fetchall()
    phase_rows = await (
        await db.execute(
            "SELECT id, starts_on, ends_on FROM health_training_phases "
            "WHERE family_id = ? AND owner_user_id = ? AND active = 1 "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    active_phases_by_day = {
        day_key: {
            row["id"]
            for row in phase_rows
            if row["starts_on"] <= day_key and (row["ends_on"] is None or row["ends_on"] >= day_key)
        }
        for day_key in logged_day_keys
    }
    training_days = {
        row["scheduled_date"]
        for row in await (
            await db.execute(
                "SELECT scheduled_date FROM health_planned_sessions WHERE family_id = ? "
                "AND owner_user_id = ? AND scheduled_date BETWEEN ? AND ? "
                "AND status NOT IN ('proposed','cancelled','skipped') "
                "AND deleted_at IS NULL",
                (user["family_id"], user["id"], start.isoformat(), end.isoformat()),
            )
        ).fetchall()
        if row["scheduled_date"] is not None
    }

    def calorie_target_for(day_key: str) -> float | None:
        for target in target_rows:
            if target["effective_from"] > day_key or (
                target["effective_until"] is not None and target["effective_until"] < day_key
            ):
                continue
            target_type = target["target_type"]
            if target_type == "phase" and target["phase_id"] not in active_phases_by_day[day_key]:
                continue
            if target_type == "range":
                value = target["target_max"]
            elif target_type == "training_rest":
                value = (
                    target["training_day_value"]
                    if day_key in training_days
                    else target["rest_day_value"]
                )
            else:
                value = target["target_value"]
            if value is not None and float(value) > 0:
                return float(value)
        return None

    daily_targets = {
        day_key: target
        for day_key in logged_day_keys
        if (target := calorie_target_for(day_key)) is not None
    }
    target_day_coverage = len(daily_targets) / logged_days if logged_days else 0.0
    observed_average = sum(daily_calories.values()) / logged_days if logged_days else None
    target_average = (
        sum(daily_targets.values()) / logged_days
        if logged_days and len(daily_targets) == logged_days
        else None
    )
    average_gap = (
        observed_average - target_average
        if observed_average is not None and target_average is not None
        else None
    )
    material_gap = max(25.0, target_average * 0.01) if target_average else None
    estimated_calorie_share = (
        estimated / known_totals["calories_kcal"] if known_totals["calories_kcal"] > 0 else None
    )
    sufficient_window = (
        days >= 7
        and logged_days >= 7
        and diary_day_completeness >= 0.7
        and calorie_completeness == 1.0
        and estimated_calorie_share is not None
        and estimated_calorie_share <= 0.25
        and target_day_coverage == 1.0
        and average_gap is not None
        and material_gap is not None
        and average_gap >= material_gap
    )

    recommendation = None
    recurring = []
    if sufficient_window:
        for (item_kind, item_id, label, meal_key), item in grouped.items():
            amounts = item["amounts"]
            if (
                item["entry_count"] < 2
                or len(item["days"]) < 2
                or item["known"]["calories_kcal"] != item["entry_count"]
                or len(amounts) != 1
                or item["totals"]["calories_kcal"] <= 0
            ):
                continue
            unit, values = next(iter(amounts.items()))
            if unit not in {"g", "ml", "serving", "custom"}:
                continue
            ordered = sorted(values)
            middle = len(ordered) // 2
            typical = (
                ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2
            )
            if typical <= 0:
                continue
            recurring.append(
                (
                    float(item["totals"]["calories_kcal"]),
                    len(item["days"]),
                    item["entry_count"],
                    item_kind,
                    item_id,
                    label,
                    meal_key,
                    typical,
                    unit,
                )
            )
    divisible = [candidate for candidate in recurring if candidate[-1] in {"g", "ml"}]
    if divisible:
        (
            period_calories,
            item_days,
            entry_count,
            item_kind,
            item_id,
            label,
            meal_key,
            typical,
            unit,
        ) = max(divisible, key=lambda candidate: candidate[:3])
        desired_period_effect = float(average_gap) * logged_days
        fraction = min(0.20, max(0.05, desired_period_effect / period_calories))
        amount = typical * fraction
        resulting_amount = typical - amount
        per_occurrence = period_calories / entry_count * fraction
        period_effect = period_calories * fraction
        weekly_effect = period_effect / days * 7
        estimated_entries = sum(
            row["measurement_quality"] in {"estimated", "restaurant_estimate"} for row in rows
        )
        estimated_entry_share = estimated_entries / len(rows) if rows else 0.0
        if estimated_entry_share > 0:
            uncertainty = (
                "The arithmetic uses the recorded portions; estimated entries "
                "in the period may change the wider comparison."
            )
        else:
            uncertainty = (
                "Every logged Calories value in the period is present, but recorded portions "
                "and recipe values can still differ from what was eaten."
            )
        meal_label = str(meal_key).replace("_", "-")
        percentage = fraction * 100
        recommendation = {
            "food_or_meal": label,
            "item_id": item_id,
            "item_kind": item_kind,
            "meal_key": meal_key,
            "observation_period": {
                "start": start.isoformat(),
                "end": end.isoformat(),
                "calendar_days": days,
                "logged_days": logged_days,
            },
            "calculation": {
                "observed_average_calories_kcal": observed_average,
                "target_average_calories_kcal": target_average,
                "average_gap_calories_kcal": average_gap,
                "minimum_material_gap_calories_kcal": material_gap,
                "target_days": len(daily_targets),
            },
            "frequency": {
                "entries": entry_count,
                "days": item_days,
                "per_week": entry_count / days * 7,
            },
            "typical_amount": {"value": typical, "unit": unit},
            "proposed_change": {
                "kind": "reduce_portion",
                "fraction": fraction,
                "amount": amount,
                "unit": unit,
                "resulting_amount": resulting_amount,
                "description": (
                    f"On a similar future {meal_label}, reduce the recorded {label} portion "
                    f"by {percentage:.0f}% from its typical {typical:g} {unit}."
                ),
            },
            "expected_effect": {
                "per_occurrence_calories_kcal": per_occurrence,
                "period_calories_kcal": period_effect,
                "weekly_calories_kcal": weekly_effect,
            },
            "uncertainty": {
                "nutrient_completeness": calorie_completeness,
                "diary_day_completeness": diary_day_completeness,
                "target_day_coverage": target_day_coverage,
                "estimated_entry_share": estimated_entry_share,
                "estimated_calorie_share": estimated_calorie_share,
                "description": uncertainty,
            },
            "why_practical": (
                f"Across {logged_days} logged days, recorded intake averaged "
                f"{observed_average:.0f} kcal against an applicable {target_average:.0f} kcal "
                f"target, a gap of {average_gap:.0f} kcal. {label} appeared on {item_days} "
                "of those days and was the highest-impact recurring Calories contributor "
                f"with a divisible recorded portion. A {percentage:.0f}% change keeps the "
                "item while making a modest repeatable adjustment."
            ),
        }
    return {
        "start": start.isoformat(),
        "end": end.isoformat(),
        "sample_days": len({row["nutrition_date"] for row in rows}),
        "calendar_days": days,
        "completeness": len({row["nutrition_date"] for row in rows}) / days,
        "averages": {
            field: value / days if value is not None else None for field, value in totals.items()
        },
        "totals": totals,
        "known_totals": known_totals,
        "nutrient_completeness": nutrient_completeness,
        "uncertain_nutrients": [
            field for field, completeness in nutrient_completeness.items() if completeness < 1
        ],
        "calories_by_meal": by_meal,
        "known_calories_by_meal": known_by_meal,
        "estimated_calorie_share": estimated / known_totals["calories_kcal"]
        if known_totals["calories_kcal"] > 0
        else None,
        "contributors": contributors,
        "recommendation": recommendation,
    }


async def upsert_body_measurement(
    db,
    *,
    user: dict,
    body: BodyMeasurementPayload,
    record_id: str | None = None,
) -> dict:
    measurement_id = record_id or new_id(body.id)
    source_id = str(body.source_record_id) if body.source_record_id else None
    if source_id:
        from app.services.fitness.recovery import validate_active_source

        source = await validate_active_source(
            db,
            user=user,
            source_id=source_id,
            record_kinds={"body_measurement"},
        )
        if source["domain_entity_type"] not in {None, "body_measurement"} or source[
            "domain_entity_id"
        ] not in {None, measurement_id}:
            raise FitnessConflictError("Body-measurement provenance targets another record")
    if body.duplicate_of_measurement_id:
        await owned_row(
            db,
            table="health_body_measurements",
            record_id=str(body.duplicate_of_measurement_id),
            user=user,
        )
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    values["source_record_id"] = source_id
    if source_id:
        # Imported canonical/duplicate state is always selected server-side from
        # exact provider identity and the owner's configured source priority.
        values["canonical_state"] = "canonical"
        values["duplicate_of_measurement_id"] = None
    existing = await (
        await db.execute(
            "SELECT * FROM health_body_measurements WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (measurement_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_body_measurements",
            record_id=measurement_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_body_measurements",
            record_id=measurement_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    if source_id:
        from app.services.fitness.recovery import rerank_weight_measurement

        await rerank_weight_measurement(
            db,
            user=user,
            measurement_id=measurement_id,
        )
    return decoded_row(
        await owned_row(
            db,
            table="health_body_measurements",
            record_id=measurement_id,
            user=user,
        )
    )


async def list_body_measurements(
    db,
    *,
    user: dict,
    metric_key: str | None = None,
) -> list[dict]:
    where = [
        "m.family_id = ?",
        "m.owner_user_id = ?",
        "m.deleted_at IS NULL",
    ]
    params: list[object] = [user["family_id"], user["id"]]
    if metric_key:
        where.append("m.metric_key = ?")
        params.append(metric_key)
    rows = await (
        await db.execute(
            "SELECT m.*, s.transport_key AS source_transport_key, "
            "s.origin_provider_key AS source_origin_provider_key, "
            "s.source_namespace AS source_namespace_detail, "
            "s.source_device_identifier AS source_device_identifier_detail, "
            "s.state AS source_state "
            "FROM health_body_measurements m LEFT JOIN health_source_records s "
            "ON s.id = m.source_record_id AND s.family_id = m.family_id "
            "AND s.owner_user_id = m.owner_user_id AND s.deleted_at IS NULL "
            f"WHERE {' AND '.join(where)} "
            "ORDER BY m.measured_at_utc DESC LIMIT 200",
            params,
        )
    ).fetchall()
    result = []
    for row in rows:
        measurement = decoded_row(row)
        source = {
            "transport_key": measurement.pop("source_transport_key"),
            "origin_provider_key": measurement.pop("source_origin_provider_key"),
            "source_namespace": measurement.pop("source_namespace_detail"),
            "source_device_identifier": measurement.pop("source_device_identifier_detail"),
            "state": measurement.pop("source_state"),
        }
        measurement["source"] = source if source["transport_key"] is not None else None
        result.append(measurement)
    return result


async def weight_trend(db, *, user: dict) -> dict:
    rows = await (
        await db.execute(
            "SELECT id, measured_at_utc, value, unit_key FROM health_body_measurements "
            "WHERE family_id = ? AND owner_user_id = ? AND metric_key = 'body.weight_kg' "
            "AND canonical_state = 'canonical' AND deleted_at IS NULL "
            "ORDER BY measured_at_utc",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    points: list[dict] = []
    values: list[float] = []
    for row in rows:
        values.append(float(row["value"]))
        window = values[-7:]
        points.append(
            {
                "id": row["id"],
                "measured_at_utc": row["measured_at_utc"],
                "value_kg": float(row["value"]),
                "seven_reading_average_kg": sum(window) / len(window),
            }
        )
    weekly_rate = None
    if len(points) >= 2:
        first_time = datetime.fromisoformat(points[0]["measured_at_utc"].replace("Z", "+00:00"))
        last_time = datetime.fromisoformat(points[-1]["measured_at_utc"].replace("Z", "+00:00"))
        weeks = (last_time - first_time).total_seconds() / (7 * 86_400)
        if weeks > 0:
            weekly_rate = (
                points[-1]["seven_reading_average_kg"] - points[0]["seven_reading_average_kg"]
            ) / weeks
    return {
        "metric_key": "body.weight_kg",
        "points": points,
        "current_kg": points[-1]["seven_reading_average_kg"] if points else None,
        "seven_day_average_kg": points[-1]["seven_reading_average_kg"] if points else None,
        "change_kg": points[-1]["seven_reading_average_kg"] - points[0]["seven_reading_average_kg"]
        if len(points) >= 2
        else None,
        "weekly_rate_kg": weekly_rate,
        "sample_count": len(points),
    }


async def delete_food_log(db, *, user: dict, entry_id: str) -> int:
    return await soft_delete_owned(
        db, table="health_food_log_entries", record_id=entry_id, user=user
    )


async def create_recipe(
    db,
    *,
    user: dict,
    body: RecipePayload,
    record_id: str | None = None,
) -> dict:
    recipe_id = record_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT * FROM health_recipes WHERE id = ? AND family_id = ? AND owner_user_id = ?",
            (recipe_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    values = {
        "name": body.name,
        "notes": body.notes,
        "household_shared": body.household_shared,
        "favourite": body.favourite,
        "active": body.active,
    }
    if existing is None:
        await insert_owned(
            db,
            table="health_recipes",
            record_id=recipe_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_recipes",
            record_id=recipe_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    if body.version:
        if existing is not None:
            raise FitnessConflictError("Create immutable recipe versions with the version endpoint")
        await add_recipe_version(db, user=user, recipe_id=recipe_id, body=body.version)
    return await get_recipe(db, user=user, recipe_id=recipe_id)


async def add_recipe_version(
    db,
    *,
    user: dict,
    recipe_id: str,
    body: RecipeVersionPayload,
    version_id: str | None = None,
) -> dict:
    if body.recipe_id is not None and str(body.recipe_id) != recipe_id:
        raise FitnessConflictError("Recipe version parent does not match its route")
    await owned_row(db, table="health_recipes", record_id=recipe_id, user=user)
    version_id = version_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT 1 FROM health_recipe_versions WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (version_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None:
        raise FitnessConflictError("That saved recipe cannot be overwritten; create a new version")
    component_totals: dict[str, float | None] = {field: 0.0 for field in NUTRIENT_FIELDS}
    component_rows: list[tuple[RecipeComponentPayload, object, int]] = []
    if body.components:
        for index, component in enumerate(body.components):
            source = await readable_food_version(
                db, user=user, version_id=str(component.food_version_id)
            )
            if component.canonical_unit != source["reference_unit"]:
                raise FitnessConflictError(
                    "Recipe component canonical_unit must match its food-version basis"
                )
            scale = component.canonical_amount / float(source["reference_amount"])
            for field in NUTRIENT_FIELDS:
                if source[field] is None:
                    component_totals[field] = None
                elif component_totals[field] is not None:
                    component_totals[field] += float(source[field]) * scale
            component_rows.append((component, source, index))
    values = body.model_dump(
        exclude={
            "id",
            "client_id",
            "client_timestamp",
            "recipe_id",
            "components",
        }
    )
    for field in NUTRIENT_FIELDS:
        if body.components:
            values[field] = component_totals[field]
    current = await (
        await db.execute(
            "SELECT COALESCE(MAX(version_number), 0) FROM health_recipe_versions "
            "WHERE family_id = ? AND owner_user_id = ? AND recipe_id = ?",
            (user["family_id"], user["id"], recipe_id),
        )
    ).fetchone()
    values.update({"recipe_id": recipe_id, "version_number": int(current[0]) + 1, "revision": 1})
    await insert_owned(
        db,
        table="health_recipe_versions",
        record_id=version_id,
        values=values,
        user=user,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    for component, _source, sequence in component_rows:
        await insert_owned(
            db,
            table="health_recipe_components",
            record_id=new_id(component.id),
            values={
                **component.model_dump(exclude={"id", "sequence"}),
                "recipe_version_id": version_id,
                "sequence": sequence,
                "revision": 1,
            },
            user=user,
        )
    return await _recipe_version_response(
        db,
        user=user,
        row=await owned_row(db, table="health_recipe_versions", record_id=version_id, user=user),
    )


async def _recipe_version_response(db, *, user: dict, row) -> dict:
    data = decoded_row(row)
    components = await (
        await db.execute(
            "SELECT c.*, f.name AS food_name FROM health_recipe_components c "
            "JOIN health_food_versions v ON v.id = c.food_version_id "
            "AND v.family_id = c.family_id JOIN health_foods f ON f.id = v.food_id "
            "AND f.family_id = c.family_id WHERE c.family_id = ? "
            "AND c.owner_user_id = ? AND c.recipe_version_id = ? "
            "AND c.deleted_at IS NULL ORDER BY c.sequence",
            (row["family_id"], row["owner_user_id"], row["id"]),
        )
    ).fetchall()
    data["components"] = [decoded_row(component) for component in components]
    if data["finished_weight_g"]:
        data["per_100_g"] = {
            field: (
                None
                if data[field] is None
                else float(data[field]) * 100 / float(data["finished_weight_g"])
            )
            for field in NUTRIENT_FIELDS
        }
    else:
        data["per_100_g"] = None
    return data


async def get_recipe(db, *, user: dict, recipe_id: str) -> dict:
    recipe_row = await _readable_recipe_row(db, user=user, recipe_id=recipe_id)
    data = decoded_row(recipe_row)
    versions = await (
        await db.execute(
            "SELECT * FROM health_recipe_versions WHERE family_id = ? AND owner_user_id = ? "
            "AND recipe_id = ? AND deleted_at IS NULL ORDER BY version_number DESC",
            (user["family_id"], recipe_row["owner_user_id"], recipe_id),
        )
    ).fetchall()
    data["versions"] = [await _recipe_version_response(db, user=user, row=row) for row in versions]
    data["current_version"] = data["versions"][0] if data["versions"] else None
    data["editable"] = recipe_row["owner_user_id"] == user["id"]
    if not data["editable"]:
        data["favourite"] = False
    return data


async def list_recipes(db, *, user: dict) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_recipes WHERE family_id = ? "
            "AND (owner_user_id = ? OR household_shared = 1) "
            "AND deleted_at IS NULL ORDER BY favourite DESC, name LIMIT 200",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    return [await get_recipe(db, user=user, recipe_id=row["id"]) for row in rows]


async def create_meal_template(
    db,
    *,
    user: dict,
    body: MealTemplatePayload,
    record_id: str | None = None,
) -> dict:
    template_id = record_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT * FROM health_meal_templates WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (template_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    values = {
        "name": body.name,
        "meal_key": body.meal_key,
        "time_relevance": body.time_relevance,
        "favourite": body.favourite,
        "active": body.active,
    }
    if existing is None:
        await insert_owned(
            db,
            table="health_meal_templates",
            record_id=template_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_meal_templates",
            record_id=template_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    retained_ids: set[str] = set()
    for sequence, item in enumerate(body.items):
        if item.food_version_id:
            await readable_food_version(db, user=user, version_id=str(item.food_version_id))
        else:
            await readable_recipe_version(db, user=user, version_id=str(item.recipe_version_id))
        item_id = new_id(item.id)
        if item_id in retained_ids:
            raise FitnessConflictError("Meal-template item ids must be unique")
        retained_ids.add(item_id)
        item_values = item.model_dump(exclude={"id", "label", "sequence"})
        item_values.update({"meal_template_id": template_id, "sequence": sequence})
        existing_item = await (
            await db.execute(
                "SELECT * FROM health_meal_template_items WHERE id = ? "
                "AND family_id = ? AND owner_user_id = ?",
                (item_id, user["family_id"], user["id"]),
            )
        ).fetchone()
        if existing_item is None:
            await insert_owned(
                db,
                table="health_meal_template_items",
                record_id=item_id,
                values={**item_values, "revision": 1},
                user=user,
                record_sync_change=False,
            )
        else:
            if existing_item["meal_template_id"] != template_id:
                raise FitnessConflictError(
                    "Meal-template item identity belongs to another template"
                )
            await update_owned(
                db,
                table="health_meal_template_items",
                record_id=item_id,
                values=item_values,
                user=user,
                restore=True,
                record_sync_change=False,
            )
    previous_items = await (
        await db.execute(
            "SELECT id FROM health_meal_template_items WHERE family_id = ? "
            "AND owner_user_id = ? AND meal_template_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], template_id),
        )
    ).fetchall()
    for previous in previous_items:
        if previous["id"] not in retained_ids:
            await soft_delete_owned(
                db,
                table="health_meal_template_items",
                record_id=previous["id"],
                user=user,
                record_sync_change=False,
            )
    return await get_meal_template(db, user=user, template_id=template_id)


async def get_meal_template(db, *, user: dict, template_id: str) -> dict:
    data = decoded_row(
        await owned_row(db, table="health_meal_templates", record_id=template_id, user=user)
    )
    rows = await (
        await db.execute(
            "SELECT * FROM health_meal_template_items WHERE family_id = ? AND owner_user_id = ? "
            "AND meal_template_id = ? AND deleted_at IS NULL ORDER BY sequence",
            (user["family_id"], user["id"], template_id),
        )
    ).fetchall()
    items = []
    for row in rows:
        item = decoded_row(row)
        if item["food_version_id"]:
            label = await (
                await db.execute(
                    "SELECT f.name FROM health_food_versions v JOIN health_foods f "
                    "ON f.id = v.food_id AND f.family_id = v.family_id "
                    "WHERE v.id = ? AND v.family_id = ?",
                    (item["food_version_id"], user["family_id"]),
                )
            ).fetchone()
        else:
            label = await (
                await db.execute(
                    "SELECT r.name FROM health_recipe_versions v JOIN health_recipes r "
                    "ON r.id = v.recipe_id AND r.family_id = v.family_id "
                    "WHERE v.id = ? AND v.family_id = ?",
                    (item["recipe_version_id"], user["family_id"]),
                )
            ).fetchone()
        item["label"] = label["name"] if label else None
        items.append(item)
    data["items"] = items
    return data


async def list_meal_templates(db, *, user: dict) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_meal_templates",
        user=user,
        order_by="favourite DESC, name",
    )
    return [await get_meal_template(db, user=user, template_id=row["id"]) for row in rows]


async def upsert_nutrition_target(
    db,
    *,
    user: dict,
    body: NutritionTargetPayload,
    record_id: str | None = None,
) -> dict:
    target_id = record_id or new_id(body.id)
    if body.phase_id:
        await owned_row(
            db,
            table="health_training_phases",
            record_id=str(body.phase_id),
            user=user,
        )
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    existing = await (
        await db.execute(
            "SELECT * FROM health_nutrition_targets WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (target_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_nutrition_targets",
            record_id=target_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_nutrition_targets",
            record_id=target_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(db, table="health_nutrition_targets", record_id=target_id, user=user)
    )


async def list_nutrition_targets(db, *, user: dict, effective_on: date | None = None) -> list[dict]:
    clauses = ["family_id = ?", "owner_user_id = ?", "deleted_at IS NULL"]
    params: list[object] = [user["family_id"], user["id"]]
    if effective_on:
        clauses.extend(
            [
                "effective_from <= ?",
                "(effective_until IS NULL OR effective_until >= ?)",
            ]
        )
        params.extend((effective_on.isoformat(), effective_on.isoformat()))
    rows = await (
        await db.execute(
            f"SELECT * FROM health_nutrition_targets WHERE {' AND '.join(clauses)} "
            "ORDER BY active DESC, effective_from DESC, metric_key LIMIT 200",
            params,
        )
    ).fetchall()
    return [decoded_row(row) for row in rows]


async def rebucket_nutrition_entries(db, *, user: dict, body: NutritionSettingsUpdate) -> dict:
    from app.services.fitness.planning import update_settings

    rows = await (
        await db.execute(
            "SELECT id, logged_at_utc, local_timezone, nutrition_date "
            "FROM health_food_log_entries WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    changed = 0
    for row in rows:
        logged_at = datetime.fromisoformat(row["logged_at_utc"].replace("Z", "+00:00"))
        revised_date = nutrition_date_for(
            logged_at,
            row["local_timezone"],
            body.nutrition_day_start_minutes,
        ).isoformat()
        if revised_date == row["nutrition_date"]:
            continue
        await update_owned(
            db,
            table="health_food_log_entries",
            record_id=row["id"],
            values={"nutrition_date": revised_date},
            user=user,
        )
        changed += 1
    settings = await update_settings(db, user=user, body=body)
    return {
        "status": "complete",
        "nutrition_day_start_minutes": body.nutrition_day_start_minutes,
        "timezone": body.timezone,
        "affected_entries": changed,
        "checked_entries": len(rows),
        "settings_revision": settings["revision"],
    }
