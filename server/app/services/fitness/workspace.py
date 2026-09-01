"""Per-adult opt-in and navigation preferences for Fitness."""

from app.models.fitness_workspace import FitnessWorkspaceUpdate
from app.services.fitness.common import insert_owned, new_id, update_owned
from app.services.idempotency import serialized_create


# These records indicate that an adult had genuinely used Fitness before the
# workspace preference was introduced. Merely opening settings is deliberately
# excluded so a new account remains opted out.
ESTABLISHED_FITNESS_TABLES = (
    "health_activities",
    "health_goals",
    "health_planned_sessions",
    "health_training_phases",
    "health_workout_definitions",
    "health_foods",
    "health_recipes",
    "health_food_log_entries",
    "health_body_measurements",
    "health_sleep_sessions",
    "health_recovery_observations",
    "health_body_issue_observations",
    "health_gear_items",
    "health_exercises",
    "health_training_programmes",
)


async def _row(db, *, user: dict):
    return await (
        await db.execute(
            "SELECT * FROM health_fitness_workspace_preferences "
            "WHERE family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()


async def _had_established_fitness(db, *, user: dict) -> bool:
    for table in ESTABLISHED_FITNESS_TABLES:
        found = await (
            await db.execute(
                f"SELECT 1 FROM {table} WHERE family_id = ? AND owner_user_id = ? LIMIT 1",
                (user["family_id"], user["id"]),
            )
        ).fetchone()
        if found is not None:
            return True
    return False


def _response(row, *, established: bool = False) -> dict:
    if row is None:
        return {
            "enabled": established,
            "pinned": established,
            "show_nutrition_today": False,
        }
    return {
        "enabled": bool(row["enabled"]),
        "pinned": bool(row["pinned"]),
        "show_nutrition_today": bool(row["show_nutrition_today"]),
    }


async def get_workspace(db, *, user: dict, persist: bool = True) -> dict:
    row = await _row(db, user=user)
    if row is not None:
        return _response(row)

    established = await _had_established_fitness(db, user=user)
    if not persist:
        return _response(None, established=established)

    async with serialized_create(db):
        row = await _row(db, user=user)
        if row is None:
            await insert_owned(
                db,
                table="health_fitness_workspace_preferences",
                record_id=new_id(),
                values={
                    "enabled": established,
                    "pinned": established,
                    "show_nutrition_today": False,
                    "revision": 1,
                },
                user=user,
                record_sync_change=False,
            )
            row = await _row(db, user=user)
    return _response(row)


async def update_workspace(
    db,
    *,
    user: dict,
    body: FitnessWorkspaceUpdate,
) -> dict:
    await get_workspace(db, user=user, persist=True)
    row = await _row(db, user=user)
    assert row is not None

    enabled = bool(row["enabled"])
    pinned = bool(row["pinned"])
    show_nutrition_today = bool(row["show_nutrition_today"])
    if body.enabled is not None:
        enabled = body.enabled
        if not enabled:
            pinned = False
    if body.pinned is not None:
        pinned = body.pinned
        if pinned:
            enabled = True
    if body.show_nutrition_today is not None:
        show_nutrition_today = body.show_nutrition_today
        if show_nutrition_today:
            enabled = True

    await update_owned(
        db,
        table="health_fitness_workspace_preferences",
        record_id=row["id"],
        values={
            "enabled": enabled,
            "pinned": pinned,
            "show_nutrition_today": show_nutrition_today,
        },
        user=user,
        record_sync_change=False,
    )
    return {
        "enabled": enabled,
        "pinned": pinned,
        "show_nutrition_today": show_nutrition_today,
    }


async def is_enabled(db, *, user: dict) -> bool:
    preference = await get_workspace(db, user=user, persist=False)
    return preference["enabled"]
