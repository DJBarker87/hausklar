"""Shared owner scope, serialization and transaction helpers for Fitness."""

import json
import sqlite3
import uuid
from datetime import date, datetime, timezone
from typing import Any

from app.services.record_history import save_history


SYNC_ENTITY_BY_TABLE = {
    "health_cycle_settings": "cycle_settings",
    "health_cycle_period_starts": "cycle_period_start",
    "health_user_settings": "nutrition_settings",
    "health_goals": "goal",
    "health_goal_relationships": "goal_relationship",
    "health_training_phases": "training_phase",
    "health_planned_sessions": "planned_session",
    "health_workout_definitions": "workout_definition",
    "health_training_programmes": "training_programme",
    "health_foods": "food",
    "health_food_versions": "food_version",
    "health_food_servings": "food_serving",
    "health_food_log_entries": "food_log_entry",
    "health_recipes": "recipe",
    "health_recipe_versions": "recipe_version",
    "health_meal_templates": "meal_template",
    "health_nutrition_targets": "nutrition_target",
    "health_body_measurements": "body_measurement",
    "health_source_records": "source_record",
    "health_source_priorities": "source_priority",
    "health_sleep_sessions": "sleep_session",
    "health_recovery_observations": "recovery_observation",
    "health_exercises": "exercise",
    "health_exercise_setups": "exercise_setup",
    "health_activities": "strength_session",
    "health_strength_session_exercises": "strength_session_exercise",
    "health_strength_set_groups": "strength_set_group",
    "health_strength_sets": "strength_set_component",
    "health_session_checkins": "session_checkin",
    "health_body_issue_observations": "body_issue",
    "health_gear_items": "gear",
    "health_activity_gear_links": "activity_gear_link",
    "health_activity_goal_links": "activity_goal_link",
    "health_progress_photos": "progress_photo",
}


class FitnessNotFoundError(LookupError):
    pass


class FitnessConflictError(ValueError):
    pass


class CanonicalIdentityChangedError(FitnessConflictError):
    def __init__(
        self,
        entity_type: str,
        target_id: str,
        target_summary: dict[str, Any] | None = None,
    ) -> None:
        self.entity_type = entity_type
        self.target_id = target_id
        self.target_summary = target_summary
        super().__init__("canonical_identity_changed")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id(requested: Any | None = None) -> str:
    return str(requested or uuid.uuid4())


def json_text(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def stored_value(value: Any) -> Any:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, (dict, list)):
        return json_text(value)
    return value


def decoded_row(row: Any, *, json_fields: set[str] | None = None) -> dict:
    data = dict(row)
    for field in json_fields or set():
        raw = data.get(field)
        if isinstance(raw, str):
            try:
                data[field.removesuffix("_json")] = json.loads(raw)
            except (TypeError, json.JSONDecodeError):
                data[field.removesuffix("_json")] = None
        if field.endswith("_json"):
            data.pop(field, None)
    for key, value in tuple(data.items()):
        if key in {
            "active",
            "favourite",
            "household_shared",
            "movable",
            "is_default",
            "is_primary",
            "bodyweight_involved",
            "is_amrap",
            "changed_session",
            "captured_before_activity_start",
            "allow_manual_advance",
            "user_confirmed",
            "manual_canonical_override",
        } and value is not None:
            data[key] = bool(value)
    return data


async def append_change(
    db,
    *,
    entity_type: str,
    entity_id: str,
    revision: int,
    operation: str,
    user: dict,
    data: dict | None = None,
    changed_at: str | None = None,
) -> None:
    timestamp = changed_at or now_iso()
    await db.execute(
        "INSERT INTO health_change_log "
        "(id, owner_user_id, entity_type, entity_id, entity_revision, operation, "
        "data_json, changed_at, revision, family_id, created_at, updated_at, created_by) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)",
        (
            new_id(),
            user["id"],
            entity_type,
            entity_id,
            revision,
            operation,
            json_text(data) if data is not None else None,
            timestamp,
            user["family_id"],
            timestamp,
            timestamp,
            user["id"],
        ),
    )


async def _append_table_change(
    db,
    *,
    table: str,
    record_id: str,
    revision: int,
    operation: str,
    user: dict,
    changed_at: str,
) -> None:
    entity_type = SYNC_ENTITY_BY_TABLE.get(table)
    if entity_type is None:
        return
    # Canonical wire data is hydrated by the sync service at read time. Storing
    # raw relational rows here would expose internal scope columns and stale nested
    # children (versions, goal links, setups, muscle roles).
    await append_change(
        db,
        entity_type=entity_type,
        entity_id=record_id,
        revision=revision,
        operation=operation,
        user=user,
        data=None,
        changed_at=changed_at,
    )


async def owned_row(
    db,
    *,
    table: str,
    record_id: str,
    user: dict,
    include_deleted: bool = False,
):
    suffix = "" if include_deleted else " AND deleted_at IS NULL"
    row = await (
        await db.execute(
            f"SELECT * FROM {table} WHERE id = ? AND family_id = ? AND owner_user_id = ?{suffix}",
            (record_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        raise FitnessNotFoundError("Fitness record not found")
    return row


async def canonical_identity_summary(
    db, *, user: dict, entity_type: str, target_id: str
) -> dict[str, Any]:
    """Return a bounded owner-scoped summary for a merge redirect target."""
    contracts = {
        "food": (
            "health_foods",
            ("id", "name", "brand", "category_key", "active", "revision"),
        ),
        "exercise": (
            "health_exercises",
            (
                "id",
                "name",
                "movement_pattern_key",
                "measurement_mode",
                "default_unit",
                "active",
                "revision",
            ),
        ),
        "exercise_setup": (
            "health_exercise_setups",
            (
                "id",
                "exercise_id",
                "name",
                "load_entry_mode",
                "is_default",
                "active",
                "revision",
            ),
        ),
    }
    contract = contracts.get(entity_type)
    if contract is None:
        return {"id": target_id}
    table, fields = contract
    row = await owned_row(db, table=table, record_id=target_id, user=user)
    decoded = decoded_row(row)
    return {field: decoded[field] for field in fields if field in decoded}


async def validate_owned_reference(
    db,
    *,
    table: str,
    record_id: str | None,
    user: dict,
) -> None:
    if record_id is None:
        return
    await owned_row(db, table=table, record_id=record_id, user=user)


async def save_owned_rows_history(
    db,
    *,
    table: str,
    user: dict,
    where: str,
    params: tuple | list = (),
) -> list[str]:
    """Snapshot owner rows immediately before a coordinated direct SQL update."""
    rows = await (
        await db.execute(
            f"SELECT id FROM {table} WHERE family_id = ? AND owner_user_id = ? "
            f"AND ({where})",
            (user["family_id"], user["id"], *params),
        )
    ).fetchall()
    identifiers = [row["id"] for row in rows]
    for identifier in identifiers:
        await save_history(
            db,
            table,
            identifier,
            user["id"],
            family_id=user["family_id"],
        )
    return identifiers


async def insert_owned(
    db,
    *,
    table: str,
    record_id: str,
    values: dict[str, Any],
    user: dict,
    now: str | None = None,
    client_id: str | None = None,
    client_timestamp: str | None = None,
    record_sync_change: bool = True,
) -> None:
    timestamp = now or now_iso()
    stored = {key: stored_value(value) for key, value in values.items()}
    stored.update(
        {
            "id": record_id,
            "owner_user_id": user["id"],
            "family_id": user["family_id"],
            "created_at": timestamp,
            "updated_at": timestamp,
            "created_by": user["id"],
            "client_id": client_id,
            "client_timestamp": client_timestamp,
        }
    )
    columns = ", ".join(stored)
    placeholders = ", ".join("?" for _ in stored)
    try:
        await db.execute(
            f"INSERT INTO {table} ({columns}) VALUES ({placeholders})",
            tuple(stored.values()),
        )
    except sqlite3.IntegrityError as exc:
        # UUIDs are globally unique primary keys. A client can legitimately replay
        # its own identifier, but must never learn that a guessed identifier belongs
        # to another owner/family through a raw SQLite error.
        raise FitnessConflictError("Fitness identifier or unique value is already in use") from exc
    if record_sync_change:
        await _append_table_change(
            db,
            table=table,
            record_id=record_id,
            revision=int(values.get("revision", 1)),
            operation="upsert",
            user=user,
            changed_at=timestamp,
        )


async def update_owned(
    db,
    *,
    table: str,
    record_id: str,
    values: dict[str, Any],
    user: dict,
    now: str | None = None,
    client_id: str | None = None,
    client_timestamp: str | None = None,
    restore: bool = False,
    record_sync_change: bool = True,
    record_history: bool = True,
) -> int:
    existing = await owned_row(
        db,
        table=table,
        record_id=record_id,
        user=user,
        include_deleted=restore,
    )
    revision = int(existing["revision"]) + 1
    if record_history:
        await save_history(
            db,
            table,
            record_id,
            user["id"],
            family_id=user["family_id"],
        )
    stored = {key: stored_value(value) for key, value in values.items()}
    stored.update(
        {
            "updated_at": now or now_iso(),
            "revision": revision,
            "client_id": client_id,
            "client_timestamp": client_timestamp,
        }
    )
    if restore:
        stored["deleted_at"] = None
    clause = ", ".join(f"{column} = ?" for column in stored)
    changed_at = now or now_iso()
    stored["updated_at"] = changed_at
    cursor = await db.execute(
        f"UPDATE {table} SET {clause} WHERE id = ? AND family_id = ? AND owner_user_id = ?",
        (*stored.values(), record_id, user["family_id"], user["id"]),
    )
    if cursor.rowcount != 1:
        raise FitnessNotFoundError("Fitness record not found")
    if record_sync_change:
        await _append_table_change(
            db,
            table=table,
            record_id=record_id,
            revision=revision,
            operation="delete" if stored.get("deleted_at") else "upsert",
            user=user,
            changed_at=changed_at,
        )
    return revision


async def soft_delete_owned(
    db,
    *,
    table: str,
    record_id: str,
    user: dict,
    now: str | None = None,
    record_sync_change: bool = True,
    record_history: bool = True,
) -> int:
    row = await owned_row(db, table=table, record_id=record_id, user=user, include_deleted=True)
    if row["deleted_at"] is not None:
        return int(row["revision"])
    return await update_owned(
        db,
        table=table,
        record_id=record_id,
        values={"deleted_at": now or now_iso()},
        user=user,
        now=now,
        record_sync_change=record_sync_change,
        record_history=record_history,
    )


async def list_owned(
    db,
    *,
    table: str,
    user: dict,
    where: str = "",
    params: tuple | list = (),
    order_by: str = "updated_at DESC",
    limit: int = 200,
) -> list:
    query = (
        f"SELECT * FROM {table} WHERE family_id = ? AND owner_user_id = ? "
        "AND deleted_at IS NULL"
    )
    if where:
        query += f" AND ({where})"
    query += f" ORDER BY {order_by} LIMIT ?"
    return await (
        await db.execute(query, (user["family_id"], user["id"], *params, limit))
    ).fetchall()
