"""Owner-scoped strength library, live workout and deterministic analytics."""

import json
import sqlite3
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

from app.models.fitness import (
    BodyIssuePayload,
    ExercisePatch,
    ExercisePayload,
    ExerciseSetupPatch,
    ExerciseSetupPayload,
    SessionCheckinPayload,
    StrengthSessionExercisePayload,
    StrengthSessionFinish,
    StrengthSessionPayload,
    StrengthSetComponentPayload,
    StrengthSetGroupPayload,
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
    validate_owned_reference,
)
from app.services.idempotency import serialized_create


EXERCISE_SEEDS = (
    {
        "seed_key": "barbell_back_squat",
        "name": "Barbell Back Squat",
        "movement_pattern_key": "squat",
        "equipment_type": "barbell",
        "muscles": (("quadriceps", "primary"), ("glutes", "primary")),
    },
    {
        "seed_key": "barbell_deadlift",
        "name": "Barbell Deadlift",
        "movement_pattern_key": "hinge",
        "equipment_type": "barbell",
        "muscles": (("hamstrings", "primary"), ("glutes", "primary")),
    },
    {
        "seed_key": "barbell_bench_press",
        "name": "Barbell Bench Press",
        "movement_pattern_key": "horizontal_push",
        "equipment_type": "barbell",
        "muscles": (("chest", "primary"), ("triceps", "secondary")),
    },
    {
        "seed_key": "dumbbell_bench_press",
        "name": "Dumbbell Bench Press",
        "movement_pattern_key": "horizontal_push",
        "equipment_type": "dumbbell",
        "load_entry_mode": "per_hand",
        "muscles": (("chest", "primary"), ("triceps", "secondary")),
    },
    {
        "seed_key": "overhead_press",
        "name": "Overhead Press",
        "movement_pattern_key": "vertical_push",
        "equipment_type": "barbell",
        "muscles": (("front_delts", "primary"), ("triceps", "secondary")),
    },
    {
        "seed_key": "pull_up",
        "name": "Pull-up",
        "movement_pattern_key": "vertical_pull",
        "equipment_type": "bodyweight",
        "load_entry_mode": "bodyweight_only",
        "bodyweight_involved": True,
        "muscles": (("lats", "primary"), ("biceps", "secondary")),
    },
    {
        "seed_key": "barbell_row",
        "name": "Barbell Row",
        "movement_pattern_key": "horizontal_pull",
        "equipment_type": "barbell",
        "muscles": (("upper_back", "primary"), ("biceps", "secondary")),
    },
    {
        "seed_key": "romanian_deadlift",
        "name": "Romanian Deadlift",
        "movement_pattern_key": "hinge",
        "equipment_type": "barbell",
        "muscles": (("hamstrings", "primary"), ("glutes", "primary")),
    },
)

ROLE_RULES = {
    "warmup": (False, False, False),
    "working": (True, True, True),
    "backoff": (True, True, True),
    "technique": (False, False, False),
    "test": (True, True, True),
    "other": (False, False, False),
}

STRENGTH_SESSION_RESUME_WINDOW = timedelta(hours=1)


def _utc_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


async def close_expired_strength_sessions(
    db,
    *,
    user: dict,
    now: datetime | None = None,
    candidate_rows=None,
) -> list[str]:
    """Close abandoned live workouts once their one-hour resume window has passed."""
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    cutoff = current - STRENGTH_SESSION_RESUME_WINDOW
    if candidate_rows is None:
        candidate_rows = await (
            await db.execute(
                "SELECT id, planned_session_id, started_at_utc, sport_key, status "
                "FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
                "AND sport_key = 'strength' AND status = 'in_progress' "
                "AND deleted_at IS NULL AND datetime(started_at_utc) < datetime(?) "
                "ORDER BY started_at_utc",
                (user["family_id"], user["id"], cutoff.isoformat()),
            )
        ).fetchall()
    expired_ids = []
    for candidate in candidate_rows:
        row = dict(candidate)
        if (
            row.get("sport_key") == "strength"
            and row.get("status") == "in_progress"
            and row.get("started_at_utc")
            and _utc_datetime(row["started_at_utc"]) + STRENGTH_SESSION_RESUME_WINDOW < current
        ):
            expired_ids.append(row["id"])
    expired_ids = list(dict.fromkeys(expired_ids))
    if not expired_ids:
        return []

    async with serialized_create(db):
        placeholders = ",".join("?" for _ in expired_ids)
        rows = await (
            await db.execute(
                "SELECT id, planned_session_id, started_at_utc FROM health_activities "
                "WHERE family_id = ? AND owner_user_id = ? AND sport_key = 'strength' "
                "AND status = 'in_progress' AND deleted_at IS NULL "
                f"AND id IN ({placeholders}) AND datetime(started_at_utc) < datetime(?) "
                "ORDER BY started_at_utc",
                (user["family_id"], user["id"], *expired_ids, cutoff.isoformat()),
            )
        ).fetchall()
        closed: list[str] = []
        for row in rows:
            activity_id = row["id"]
            expiry = _utc_datetime(row["started_at_utc"]) + STRENGTH_SESSION_RESUME_WINDOW
            await update_owned(
                db,
                table="health_activities",
                record_id=activity_id,
                values={
                    "status": "aborted",
                    "ended_at_utc": expiry,
                    "rest_timer_deadline_utc": None,
                },
                user=user,
                now=current.isoformat(),
            )
            if row["planned_session_id"]:
                active_plan = await (
                    await db.execute(
                        "SELECT id FROM health_planned_sessions WHERE id = ? "
                        "AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL "
                        "AND status IN ('accepted','scheduled','in_progress')",
                        (row["planned_session_id"], user["family_id"], user["id"]),
                    )
                ).fetchone()
                if active_plan is not None:
                    await update_owned(
                        db,
                        table="health_planned_sessions",
                        record_id=row["planned_session_id"],
                        values={
                            "status": "cancelled",
                            "completion_activity_id": activity_id,
                            "completion_state": "aborted",
                        },
                        user=user,
                        now=current.isoformat(),
                    )
            closed.append(activity_id)
        return closed


async def _insert_default_setup(
    db, *, user: dict, exercise_id: str, setup_id: str | None = None
) -> str:
    identifier = setup_id or new_id()
    await insert_owned(
        db,
        table="health_exercise_setups",
        record_id=identifier,
        values={
            "exercise_id": exercise_id,
            "name": "Default",
            "is_default": True,
            "active": True,
            "revision": 1,
        },
        user=user,
    )
    return identifier


async def ensure_owner_exercise_seeds(db, *, user: dict) -> None:
    """Materialise common catalogue rows with fresh IDs for this owner only."""
    async with serialized_create(db):
        for seed in EXERCISE_SEEDS:
            row = await (
                await db.execute(
                    "SELECT id FROM health_exercises WHERE family_id = ? AND owner_user_id = ? "
                    "AND seed_key = ? AND active = 1 AND deleted_at IS NULL",
                    (user["family_id"], user["id"], seed["seed_key"]),
                )
            ).fetchone()
            if row is not None:
                setup = await (
                    await db.execute(
                        "SELECT id FROM health_exercise_setups WHERE family_id = ? "
                        "AND owner_user_id = ? AND exercise_id = ? AND active = 1 "
                        "AND deleted_at IS NULL LIMIT 1",
                        (user["family_id"], user["id"], row["id"]),
                    )
                ).fetchone()
                if setup is None:
                    await _insert_default_setup(db, user=user, exercise_id=row["id"])
                continue
            exercise_id = new_id()
            await insert_owned(
                db,
                table="health_exercises",
                record_id=exercise_id,
                values={
                    "seed_key": seed["seed_key"],
                    "name": seed["name"],
                    "aliases_json": [],
                    "movement_pattern_key": seed["movement_pattern_key"],
                    "measurement_mode": "reps_load",
                    "rep_count_mode": "total",
                    "load_entry_mode": seed.get("load_entry_mode", "total_external"),
                    "default_unit": "kg",
                    "unilateral_mode": "bilateral",
                    "equipment_type": seed.get("equipment_type"),
                    "bodyweight_involved": seed.get("bodyweight_involved", False),
                    "progression_direction": "higher",
                    "favourite": False,
                    "active": True,
                    "revision": 1,
                },
                user=user,
            )
            await _insert_default_setup(db, user=user, exercise_id=exercise_id)
            for muscle_key, role in seed["muscles"]:
                await insert_owned(
                    db,
                    table="health_exercise_muscle_roles",
                    record_id=new_id(),
                    values={
                        "exercise_id": exercise_id,
                        "muscle_group_key": muscle_key,
                        "role": role,
                        "contribution_weight": 1.0 if role == "primary" else 0.5,
                        "revision": 1,
                    },
                    user=user,
                )


async def resolve_exercise_id(db, *, user: dict, exercise_id: str) -> tuple[str, list[str]]:
    seen: list[str] = []
    current = exercise_id
    for _ in range(100):
        if current in seen:
            raise FitnessConflictError("Exercise merge redirect loop")
        seen.append(current)
        row = await owned_row(
            db,
            table="health_exercises",
            record_id=current,
            user=user,
            include_deleted=True,
        )
        target = row["merged_into_exercise_id"]
        if not target:
            return current, seen[:-1]
        current = target
    raise FitnessConflictError("Exercise merge redirect chain is too long")


async def resolve_setup_id(db, *, user: dict, setup_id: str) -> tuple[str, list[str]]:
    seen: list[str] = []
    current = setup_id
    for _ in range(100):
        if current in seen:
            raise FitnessConflictError("Exercise setup merge redirect loop")
        seen.append(current)
        row = await owned_row(
            db,
            table="health_exercise_setups",
            record_id=current,
            user=user,
            include_deleted=True,
        )
        target = row["merged_into_setup_id"]
        if not target:
            return current, seen[:-1]
        current = target
    raise FitnessConflictError("Exercise setup merge redirect chain is too long")


async def _exercise_response(db, *, user: dict, row) -> dict:
    data = decoded_row(row, json_fields={"aliases_json"})
    roles = await (
        await db.execute(
            "SELECT muscle_group_key, role, contribution_weight FROM "
            "health_exercise_muscle_roles WHERE family_id = ? AND owner_user_id = ? "
            "AND exercise_id = ? AND deleted_at IS NULL ORDER BY role, muscle_group_key",
            (user["family_id"], user["id"], data["id"]),
        )
    ).fetchall()
    setups = await list_owned(
        db,
        table="health_exercise_setups",
        user=user,
        where="exercise_id = ? AND active = 1",
        params=(data["id"],),
        order_by="is_default DESC, name",
    )
    data["muscle_roles"] = [dict(item) for item in roles]
    data["setups"] = [decoded_row(item) for item in setups]
    return data


async def list_exercises(
    db, *, user: dict, query: str | None = None, favourites: bool = False
) -> list[dict]:
    await ensure_owner_exercise_seeds(db, user=user)
    where = "active = 1 AND merged_into_exercise_id IS NULL"
    params: list = []
    if favourites:
        where += " AND favourite = 1"
    if query:
        where += " AND (LOWER(name) LIKE ? OR LOWER(aliases_json) LIKE ?)"
        term = f"%{query.casefold()}%"
        params.extend((term, term))
    rows = await list_owned(
        db,
        table="health_exercises",
        user=user,
        where=where,
        params=params,
        order_by="favourite DESC, name",
    )
    return [await _exercise_response(db, user=user, row=row) for row in rows]


async def get_exercise(db, *, user: dict, exercise_id: str) -> dict:
    canonical, aliases = await resolve_exercise_id(db, user=user, exercise_id=exercise_id)
    data = await _exercise_response(
        db,
        user=user,
        row=await owned_row(db, table="health_exercises", record_id=canonical, user=user),
    )
    if aliases:
        data["redirect"] = {"source_id": exercise_id, "target_id": canonical}
    return data


async def _replace_muscle_roles(db, *, user: dict, exercise_id: str, roles) -> None:
    timestamp = now_iso()
    await save_owned_rows_history(
        db,
        table="health_exercise_muscle_roles",
        user=user,
        where="exercise_id = ? AND deleted_at IS NULL",
        params=(exercise_id,),
    )
    await db.execute(
        "UPDATE health_exercise_muscle_roles SET deleted_at = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND exercise_id = ? "
        "AND deleted_at IS NULL",
        (timestamp, timestamp, user["family_id"], user["id"], exercise_id),
    )
    for role in roles:
        await insert_owned(
            db,
            table="health_exercise_muscle_roles",
            record_id=new_id(),
            values={
                "exercise_id": exercise_id,
                "muscle_group_key": role.muscle_group_key,
                "role": role.role,
                "contribution_weight": role.contribution_weight
                if role.contribution_weight is not None
                else (1.0 if role.role == "primary" else 0.5),
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )


async def upsert_exercise(
    db,
    *,
    user: dict,
    body: ExercisePayload,
    record_id: str | None = None,
    create_default_setup: bool = True,
) -> dict:
    exercise_id = record_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT * FROM health_exercises WHERE id = ? AND family_id = ? AND owner_user_id = ?",
            (exercise_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None and existing["merged_into_exercise_id"]:
        target_id = existing["merged_into_exercise_id"]
        raise CanonicalIdentityChangedError(
            "exercise",
            target_id,
            await canonical_identity_summary(
                db, user=user, entity_type="exercise", target_id=target_id
            ),
        )
    values = body.model_dump(
        exclude={"id", "client_id", "client_timestamp", "aliases", "muscle_roles"}
    )
    values["aliases_json"] = body.aliases
    if existing is None:
        await insert_owned(
            db,
            table="health_exercises",
            record_id=exercise_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
        if create_default_setup:
            await _insert_default_setup(db, user=user, exercise_id=exercise_id)
    else:
        await update_owned(
            db,
            table="health_exercises",
            record_id=exercise_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    await _replace_muscle_roles(db, user=user, exercise_id=exercise_id, roles=body.muscle_roles)
    return await get_exercise(db, user=user, exercise_id=exercise_id)


async def patch_exercise(db, *, user: dict, exercise_id: str, body: ExercisePatch) -> dict:
    row = await owned_row(
        db,
        table="health_exercises",
        record_id=exercise_id,
        user=user,
        include_deleted=True,
    )
    if row["merged_into_exercise_id"]:
        target_id = row["merged_into_exercise_id"]
        raise CanonicalIdentityChangedError(
            "exercise",
            target_id,
            await canonical_identity_summary(
                db, user=user, entity_type="exercise", target_id=target_id
            ),
        )
    values = body.model_dump(exclude_unset=True, exclude={"aliases", "muscle_roles"})
    if body.aliases is not None:
        values["aliases_json"] = body.aliases
    if values:
        await update_owned(
            db, table="health_exercises", record_id=exercise_id, values=values, user=user
        )
    if body.muscle_roles is not None:
        await _replace_muscle_roles(db, user=user, exercise_id=exercise_id, roles=body.muscle_roles)
        if not values:
            await update_owned(
                db,
                table="health_exercises",
                record_id=exercise_id,
                values={},
                user=user,
            )
    return await get_exercise(db, user=user, exercise_id=exercise_id)


async def set_exercise_favourite(
    db, *, user: dict, exercise_id: str, favourite: bool = True
) -> dict:
    await update_owned(
        db,
        table="health_exercises",
        record_id=exercise_id,
        values={"favourite": favourite},
        user=user,
    )
    return await get_exercise(db, user=user, exercise_id=exercise_id)


async def list_setups(db, *, user: dict, exercise_id: str | None = None) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_exercise_setups",
        user=user,
        where="exercise_id = ? AND active = 1" if exercise_id else "active = 1",
        params=(exercise_id,) if exercise_id else (),
        order_by="is_default DESC, name",
    )
    return [decoded_row(row) for row in rows]


async def upsert_setup(
    db,
    *,
    user: dict,
    body: ExerciseSetupPayload,
    record_id: str | None = None,
) -> dict:
    exercise_id, _ = await resolve_exercise_id(db, user=user, exercise_id=str(body.exercise_id))
    setup_id = record_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT * FROM health_exercise_setups WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (setup_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None and existing["merged_into_setup_id"]:
        target_id = existing["merged_into_setup_id"]
        raise CanonicalIdentityChangedError(
            "exercise_setup",
            target_id,
            await canonical_identity_summary(
                db, user=user, entity_type="exercise_setup", target_id=target_id
            ),
        )
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    values["exercise_id"] = exercise_id
    if body.is_default:
        await save_owned_rows_history(
            db,
            table="health_exercise_setups",
            user=user,
            where="exercise_id = ? AND is_default = 1 AND deleted_at IS NULL",
            params=(exercise_id,),
        )
        await db.execute(
            "UPDATE health_exercise_setups SET is_default = 0, updated_at = ? "
            "WHERE family_id = ? AND owner_user_id = ? AND exercise_id = ? "
            "AND deleted_at IS NULL",
            (now_iso(), user["family_id"], user["id"], exercise_id),
        )
    if existing is None:
        await insert_owned(
            db,
            table="health_exercise_setups",
            record_id=setup_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_exercise_setups",
            record_id=setup_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(db, table="health_exercise_setups", record_id=setup_id, user=user)
    )


async def patch_setup(db, *, user: dict, setup_id: str, body: ExerciseSetupPatch) -> dict:
    row = await owned_row(
        db,
        table="health_exercise_setups",
        record_id=setup_id,
        user=user,
        include_deleted=True,
    )
    if row["merged_into_setup_id"]:
        target_id = row["merged_into_setup_id"]
        raise CanonicalIdentityChangedError(
            "exercise_setup",
            target_id,
            await canonical_identity_summary(
                db, user=user, entity_type="exercise_setup", target_id=target_id
            ),
        )
    values = body.model_dump(exclude_unset=True)
    if body.is_default:
        await save_owned_rows_history(
            db,
            table="health_exercise_setups",
            user=user,
            where="exercise_id = ? AND id <> ? AND is_default = 1 AND deleted_at IS NULL",
            params=(row["exercise_id"], setup_id),
        )
        await db.execute(
            "UPDATE health_exercise_setups SET is_default = 0, updated_at = ? "
            "WHERE family_id = ? AND owner_user_id = ? AND exercise_id = ? "
            "AND id <> ? AND deleted_at IS NULL",
            (now_iso(), user["family_id"], user["id"], row["exercise_id"], setup_id),
        )
    if values:
        await update_owned(
            db,
            table="health_exercise_setups",
            record_id=setup_id,
            values=values,
            user=user,
        )
    return decoded_row(
        await owned_row(db, table="health_exercise_setups", record_id=setup_id, user=user)
    )


async def preview_exercise_merge(db, *, user: dict, source_id: str, target_id: str) -> dict:
    source, _ = await resolve_exercise_id(db, user=user, exercise_id=source_id)
    target, _ = await resolve_exercise_id(db, user=user, exercise_id=target_id)
    if source == target:
        return {
            "source_id": source_id,
            "target_id": target,
            "already_merged": True,
            "planned_exercises": 0,
            "session_exercises": 0,
            "moved_setups": 0,
        }
    await owned_row(db, table="health_exercises", record_id=source, user=user)
    await owned_row(db, table="health_exercises", record_id=target, user=user)

    async def count(table: str, column: str) -> int:
        row = await (
            await db.execute(
                f"SELECT COUNT(*) FROM {table} WHERE family_id = ? AND owner_user_id = ? "
                f"AND {column} = ? AND deleted_at IS NULL",
                (user["family_id"], user["id"], source),
            )
        ).fetchone()
        return int(row[0])

    workout_plans = await count("health_strength_workout_exercises", "exercise_id")
    session_plans = await count("health_planned_session_exercises", "exercise_id")
    return {
        "source_id": source,
        "target_id": target,
        "already_merged": False,
        "planned_exercises": workout_plans + session_plans,
        "session_exercises": await count("health_strength_session_exercises", "exercise_id"),
        "moved_setups": await count("health_exercise_setups", "exercise_id"),
    }


async def merge_exercises(db, *, user: dict, source_id: str, target_id: str) -> dict:
    preview = await preview_exercise_merge(db, user=user, source_id=source_id, target_id=target_id)
    if preview["already_merged"]:
        return preview
    source_id = preview["source_id"]
    target_id = preview["target_id"]
    source = await owned_row(db, table="health_exercises", record_id=source_id, user=user)
    target = await owned_row(db, table="health_exercises", record_id=target_id, user=user)
    source_aliases = json.loads(source["aliases_json"] or "[]")
    target_aliases = json.loads(target["aliases_json"] or "[]")
    merged_aliases = list(dict.fromkeys([*target_aliases, source["name"], *source_aliases]))
    affected_definitions = await (
        await db.execute(
            "SELECT DISTINCT v.workout_definition_id FROM health_workout_versions v "
            "JOIN health_strength_workout_exercises e ON e.workout_version_id = v.id "
            "LEFT JOIN health_strength_workout_exercise_substitutions s "
            "ON s.workout_exercise_id = e.id AND s.deleted_at IS NULL "
            "WHERE e.family_id = ? AND e.owner_user_id = ? AND e.deleted_at IS NULL "
            "AND (e.exercise_id = ? OR s.substitute_exercise_id = ?)",
            (user["family_id"], user["id"], source_id, source_id),
        )
    ).fetchall()
    affected_plans = await (
        await db.execute(
            "SELECT DISTINCT e.planned_session_id FROM health_planned_session_exercises e "
            "LEFT JOIN health_planned_session_exercise_substitutions s "
            "ON s.planned_session_exercise_id = e.id AND s.deleted_at IS NULL "
            "WHERE e.family_id = ? AND e.owner_user_id = ? AND e.deleted_at IS NULL "
            "AND (e.exercise_id = ? OR s.substitute_exercise_id = ?)",
            (user["family_id"], user["id"], source_id, source_id),
        )
    ).fetchall()

    setup_rows = await (
        await db.execute(
            "SELECT id FROM health_exercise_setups WHERE family_id = ? AND owner_user_id = ? "
            "AND exercise_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    for setup in setup_rows:
        await update_owned(
            db,
            table="health_exercise_setups",
            record_id=setup["id"],
            values={"exercise_id": target_id, "is_default": False},
            user=user,
        )

    session_rows = await (
        await db.execute(
            "SELECT id FROM health_strength_session_exercises WHERE family_id = ? "
            "AND owner_user_id = ? AND exercise_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    for session_row in session_rows:
        await update_owned(
            db,
            table="health_strength_session_exercises",
            record_id=session_row["id"],
            values={"exercise_id": target_id},
            user=user,
        )
    await save_owned_rows_history(
        db,
        table="health_strength_workout_exercises",
        user=user,
        where="exercise_id = ? AND deleted_at IS NULL",
        params=(source_id,),
    )
    await db.execute(
        "UPDATE health_strength_workout_exercises SET exercise_id = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND exercise_id = ? AND deleted_at IS NULL",
        (target_id, now_iso(), user["family_id"], user["id"], source_id),
    )
    await save_owned_rows_history(
        db,
        table="health_planned_session_exercises",
        user=user,
        where="exercise_id = ? AND deleted_at IS NULL",
        params=(source_id,),
    )
    await db.execute(
        "UPDATE health_planned_session_exercises SET exercise_id = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND exercise_id = ? AND deleted_at IS NULL",
        (target_id, now_iso(), user["family_id"], user["id"], source_id),
    )
    for table, parent_column in (
        ("health_strength_workout_exercise_substitutions", "workout_exercise_id"),
        (
            "health_planned_session_exercise_substitutions",
            "planned_session_exercise_id",
        ),
    ):
        substitutions = await (
            await db.execute(
                f"SELECT id, {parent_column} AS parent_id FROM {table} WHERE family_id = ? "
                "AND owner_user_id = ? AND substitute_exercise_id = ? AND deleted_at IS NULL",
                (user["family_id"], user["id"], source_id),
            )
        ).fetchall()
        for substitution in substitutions:
            duplicate = await (
                await db.execute(
                    f"SELECT id FROM {table} WHERE family_id = ? AND owner_user_id = ? "
                    f"AND {parent_column} = ? AND substitute_exercise_id = ? "
                    "AND deleted_at IS NULL AND id <> ?",
                    (
                        user["family_id"],
                        user["id"],
                        substitution["parent_id"],
                        target_id,
                        substitution["id"],
                    ),
                )
            ).fetchone()
            timestamp = now_iso()
            await save_owned_rows_history(
                db,
                table=table,
                user=user,
                where="id = ?",
                params=(substitution["id"],),
            )
            if duplicate:
                await db.execute(
                    f"UPDATE {table} SET deleted_at = ?, updated_at = ? WHERE id = ?",
                    (timestamp, timestamp, substitution["id"]),
                )
            else:
                await db.execute(
                    f"UPDATE {table} SET substitute_exercise_id = ?, updated_at = ? WHERE id = ?",
                    (target_id, timestamp, substitution["id"]),
                )

    source_roles = await (
        await db.execute(
            "SELECT * FROM health_exercise_muscle_roles WHERE family_id = ? "
            "AND owner_user_id = ? AND exercise_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    await save_owned_rows_history(
        db,
        table="health_exercise_muscle_roles",
        user=user,
        where="exercise_id = ? AND deleted_at IS NULL",
        params=(source_id,),
    )
    for role in source_roles:
        existing = await (
            await db.execute(
                "SELECT * FROM health_exercise_muscle_roles WHERE family_id = ? "
                "AND owner_user_id = ? AND exercise_id = ? AND muscle_group_key = ? "
                "AND deleted_at IS NULL",
                (
                    user["family_id"],
                    user["id"],
                    target_id,
                    role["muscle_group_key"],
                ),
            )
        ).fetchone()
        if existing is None:
            await db.execute(
                "UPDATE health_exercise_muscle_roles SET exercise_id = ?, updated_at = ? "
                "WHERE id = ? AND family_id = ? AND owner_user_id = ?",
                (target_id, now_iso(), role["id"], user["family_id"], user["id"]),
            )
        else:
            stronger_role = (
                "primary" if "primary" in {existing["role"], role["role"]} else "secondary"
            )
            weight = max(
                float(existing["contribution_weight"] or 0),
                float(role["contribution_weight"] or 0),
            )
            await save_owned_rows_history(
                db,
                table="health_exercise_muscle_roles",
                user=user,
                where="id = ?",
                params=(existing["id"],),
            )
            await db.execute(
                "UPDATE health_exercise_muscle_roles SET role = ?, contribution_weight = ?, "
                "updated_at = ? WHERE id = ? AND family_id = ? AND owner_user_id = ?",
                (
                    stronger_role,
                    weight,
                    now_iso(),
                    existing["id"],
                    user["family_id"],
                    user["id"],
                ),
            )
            await db.execute(
                "UPDATE health_exercise_muscle_roles SET deleted_at = ?, updated_at = ? "
                "WHERE id = ? AND family_id = ? AND owner_user_id = ?",
                (now_iso(), now_iso(), role["id"], user["family_id"], user["id"]),
            )

    await update_owned(
        db,
        table="health_exercises",
        record_id=target_id,
        values={"aliases_json": merged_aliases},
        user=user,
    )
    timestamp = now_iso()
    await save_owned_rows_history(
        db,
        table="health_exercises",
        user=user,
        where="id = ?",
        params=(source_id,),
    )
    source_revision = int(source["revision"]) + 1
    await save_owned_rows_history(
        db,
        table="health_exercises",
        user=user,
        where="merged_into_exercise_id = ? AND id <> ?",
        params=(source_id, source_id),
    )
    await db.execute(
        "UPDATE health_exercises SET active = 0, merged_into_exercise_id = ?, merged_at = ?, "
        "updated_at = ?, revision = ? WHERE id = ? AND family_id = ? AND owner_user_id = ?",
        (
            target_id,
            timestamp,
            timestamp,
            source_revision,
            source_id,
            user["family_id"],
            user["id"],
        ),
    )
    await db.execute(
        "UPDATE health_exercises SET merged_into_exercise_id = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND merged_into_exercise_id = ? "
        "AND id <> ?",
        (target_id, timestamp, user["family_id"], user["id"], source_id, source_id),
    )
    await append_change(
        db,
        entity_type="exercise",
        entity_id=source_id,
        revision=source_revision,
        operation="redirect",
        user=user,
        data={"target_id": target_id},
        changed_at=timestamp,
    )
    for definition in affected_definitions:
        await update_owned(
            db,
            table="health_workout_definitions",
            record_id=definition["workout_definition_id"],
            values={},
            user=user,
        )
    for plan in affected_plans:
        await update_owned(
            db,
            table="health_planned_sessions",
            record_id=plan["planned_session_id"],
            values={},
            user=user,
        )
    return preview


async def _setup_comparison_key(db, *, user: dict, row) -> tuple[str, str, str, str]:
    exercise_id, _ = await resolve_exercise_id(db, user=user, exercise_id=row["exercise_id"])
    exercise = await owned_row(db, table="health_exercises", record_id=exercise_id, user=user)
    return (
        exercise_id,
        row["load_entry_mode"] or exercise["load_entry_mode"],
        row["rep_count_mode"] or exercise["rep_count_mode"],
        row["unilateral_mode"] or exercise["unilateral_mode"],
    )


async def preview_setup_merge(db, *, user: dict, source_id: str, target_id: str) -> dict:
    source_id, _ = await resolve_setup_id(db, user=user, setup_id=source_id)
    target_id, _ = await resolve_setup_id(db, user=user, setup_id=target_id)
    if source_id == target_id:
        return {
            "source_id": source_id,
            "target_id": target_id,
            "already_merged": True,
            "planned_exercises": 0,
            "session_exercises": 0,
        }
    source = await owned_row(db, table="health_exercise_setups", record_id=source_id, user=user)
    target = await owned_row(db, table="health_exercise_setups", record_id=target_id, user=user)
    if await _setup_comparison_key(db, user=user, row=source) != await _setup_comparison_key(
        db, user=user, row=target
    ):
        raise FitnessConflictError("Exercise setups use incompatible comparison modes")

    async def count(table: str) -> int:
        row = await (
            await db.execute(
                f"SELECT COUNT(*) FROM {table} WHERE family_id = ? AND owner_user_id = ? "
                "AND exercise_setup_id = ? AND deleted_at IS NULL",
                (user["family_id"], user["id"], source_id),
            )
        ).fetchone()
        return int(row[0])

    explicit_plans = await count("health_planned_session_exercises")
    return {
        "source_id": source_id,
        "target_id": target_id,
        "already_merged": False,
        "planned_exercises": await count("health_strength_workout_exercises") + explicit_plans,
        "session_exercises": await count("health_strength_session_exercises"),
    }


async def merge_setups(db, *, user: dict, source_id: str, target_id: str) -> dict:
    preview = await preview_setup_merge(db, user=user, source_id=source_id, target_id=target_id)
    if preview["already_merged"]:
        return preview
    source_id = preview["source_id"]
    target_id = preview["target_id"]
    source = await owned_row(db, table="health_exercise_setups", record_id=source_id, user=user)
    affected_definitions = await (
        await db.execute(
            "SELECT DISTINCT v.workout_definition_id FROM health_workout_versions v "
            "JOIN health_strength_workout_exercises e ON e.workout_version_id = v.id "
            "WHERE e.family_id = ? AND e.owner_user_id = ? AND e.exercise_setup_id = ? "
            "AND e.deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    affected_plans = await (
        await db.execute(
            "SELECT DISTINCT planned_session_id FROM health_planned_session_exercises "
            "WHERE family_id = ? AND owner_user_id = ? AND exercise_setup_id = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"], source_id),
        )
    ).fetchall()
    # Completed and in-flight session history keeps the concrete source setup.
    # Future planning follows the redirect. Recorded snapshots preserve the
    # source label/modes, while comparisons resolve the canonical setup identity.
    await save_owned_rows_history(
        db,
        table="health_strength_workout_exercises",
        user=user,
        where="exercise_setup_id = ? AND deleted_at IS NULL",
        params=(source_id,),
    )
    await db.execute(
        "UPDATE health_strength_workout_exercises SET exercise_setup_id = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND exercise_setup_id = ? "
        "AND deleted_at IS NULL",
        (target_id, now_iso(), user["family_id"], user["id"], source_id),
    )
    await save_owned_rows_history(
        db,
        table="health_planned_session_exercises",
        user=user,
        where="exercise_setup_id = ? AND deleted_at IS NULL",
        params=(source_id,),
    )
    await db.execute(
        "UPDATE health_planned_session_exercises SET exercise_setup_id = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND exercise_setup_id = ? "
        "AND deleted_at IS NULL",
        (target_id, now_iso(), user["family_id"], user["id"], source_id),
    )
    timestamp = now_iso()
    await save_owned_rows_history(
        db,
        table="health_exercise_setups",
        user=user,
        where="id = ?",
        params=(source_id,),
    )
    revision = int(source["revision"]) + 1
    await save_owned_rows_history(
        db,
        table="health_exercise_setups",
        user=user,
        where="merged_into_setup_id = ? AND id <> ?",
        params=(source_id, source_id),
    )
    await db.execute(
        "UPDATE health_exercise_setups SET active = 0, is_default = 0, "
        "merged_into_setup_id = ?, merged_at = ?, updated_at = ?, revision = ? "
        "WHERE id = ? AND family_id = ? AND owner_user_id = ?",
        (
            target_id,
            timestamp,
            timestamp,
            revision,
            source_id,
            user["family_id"],
            user["id"],
        ),
    )
    await db.execute(
        "UPDATE health_exercise_setups SET merged_into_setup_id = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND merged_into_setup_id = ? "
        "AND id <> ?",
        (target_id, timestamp, user["family_id"], user["id"], source_id, source_id),
    )
    await append_change(
        db,
        entity_type="exercise_setup",
        entity_id=source_id,
        revision=revision,
        operation="redirect",
        user=user,
        data={"target_id": target_id},
        changed_at=timestamp,
    )
    for definition in affected_definitions:
        await update_owned(
            db,
            table="health_workout_definitions",
            record_id=definition["workout_definition_id"],
            values={},
            user=user,
        )
    for plan in affected_plans:
        await update_owned(
            db,
            table="health_planned_sessions",
            record_id=plan["planned_session_id"],
            values={},
            user=user,
        )
    return preview


async def upsert_strength_session(
    db,
    *,
    user: dict,
    body: StrengthSessionPayload,
    record_id: str | None = None,
) -> dict:
    activity_id = record_id or new_id(body.id)
    if body.ended_at_utc and body.ended_at_utc < body.started_at_utc:
        raise FitnessConflictError("ended_at_utc cannot be before started_at_utc")
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    values["sport_key"] = "strength"
    existing = await (
        await db.execute(
            "SELECT * FROM health_activities WHERE id = ? AND family_id = ? AND owner_user_id = ?",
            (activity_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    plan = None
    if body.planned_session_id:
        plan = await owned_row(
            db,
            table="health_planned_sessions",
            record_id=str(body.planned_session_id),
            user=user,
        )
        if plan["sport_key"] != "strength":
            raise FitnessConflictError("Planned session is not a strength session")
        executable_statuses = {"accepted", "scheduled", "in_progress"}
        is_idempotent_completion = (
            existing is not None
            and plan["completion_activity_id"] == activity_id
            and plan["status"]
            in {
                "completed",
                "partially_completed",
                "cancelled",
            }
        )
        if plan["status"] not in executable_statuses and not is_idempotent_completion:
            raise FitnessConflictError(
                "Accept or schedule the planned session before starting it"
                if plan["status"] == "proposed"
                else "The planned session is already closed"
            )
    if existing is not None and existing["planned_session_id"] != (
        str(body.planned_session_id) if body.planned_session_id else None
    ):
        raise FitnessConflictError("A recorded strength session cannot change its plan")
    if body.status == "in_progress":
        other_active = await (
            await db.execute(
                "SELECT id, planned_session_id, started_at_utc, sport_key, status "
                "FROM health_activities WHERE family_id = ? "
                "AND owner_user_id = ? AND sport_key = 'strength' "
                "AND status = 'in_progress' AND deleted_at IS NULL AND id <> ? LIMIT 1",
                (user["family_id"], user["id"], activity_id),
            )
        ).fetchone()
        if other_active is not None:
            closed = await close_expired_strength_sessions(
                db,
                user=user,
                candidate_rows=[other_active],
            )
            if not closed:
                raise FitnessConflictError(
                    "Finish or abandon the active strength session before starting another"
                )
            if body.planned_session_id and other_active["planned_session_id"] == str(
                body.planned_session_id
            ):
                raise FitnessConflictError(
                    "That planned session closed with the abandoned workout; plan a new one"
                )
    try:
        if existing is None:
            await insert_owned(
                db,
                table="health_activities",
                record_id=activity_id,
                values=values,
                user=user,
                client_id=body.client_id,
                client_timestamp=body.client_timestamp,
            )
        else:
            if existing["sport_key"] != "strength":
                raise FitnessConflictError("Activity is not a strength session")
            await update_owned(
                db,
                table="health_activities",
                record_id=activity_id,
                values=values,
                user=user,
                client_id=body.client_id,
                client_timestamp=body.client_timestamp,
                restore=True,
            )
    except sqlite3.IntegrityError as exc:
        if "health_activities.owner_user_id" in str(exc):
            raise FitnessConflictError(
                "Finish or abandon the active strength session before starting another"
            ) from exc
        raise
    if plan is not None:
        plan_status = "in_progress" if body.status == "in_progress" else body.status
        if plan_status == "partial":
            plan_status = "partially_completed"
        if plan_status == "aborted":
            plan_status = "cancelled"
        await update_owned(
            db,
            table="health_planned_sessions",
            record_id=str(body.planned_session_id),
            values={
                "status": plan_status,
                "completion_activity_id": activity_id,
                "completion_state": body.status,
            },
            user=user,
        )
    return await get_strength_session(db, user=user, activity_id=activity_id)


async def list_strength_sessions(db, *, user: dict, offset: int = 0, limit: int = 50) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
            "AND sport_key = 'strength' AND deleted_at IS NULL "
            "ORDER BY started_at_utc DESC LIMIT ? OFFSET ?",
            (user["family_id"], user["id"], limit, offset),
        )
    ).fetchall()
    if await close_expired_strength_sessions(db, user=user, candidate_rows=rows):
        rows = await (
            await db.execute(
                "SELECT * FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
                "AND sport_key = 'strength' AND deleted_at IS NULL "
                "ORDER BY started_at_utc DESC LIMIT ? OFFSET ?",
                (user["family_id"], user["id"], limit, offset),
            )
        ).fetchall()
    return await _batch_strength_sessions(db, user=user, activity_rows=rows)


async def _recent_comparable_groups(
    db,
    *,
    user: dict,
    exercise_id: str,
    setup_id: str,
    load_mode: str,
    rep_mode: str,
    unilateral_mode: str,
    limit: int = 8,
) -> list[dict]:
    canonical_setup_id, _ = await resolve_setup_id(db, user=user, setup_id=setup_id)
    alias_rows = await (
        await db.execute(
            "WITH RECURSIVE setup_aliases(id) AS (SELECT ? UNION ALL "
            "SELECT s.id FROM health_exercise_setups s JOIN setup_aliases a "
            "ON s.merged_into_setup_id = a.id WHERE s.family_id = ? "
            "AND s.owner_user_id = ? AND s.deleted_at IS NULL) SELECT id FROM setup_aliases",
            (canonical_setup_id, user["family_id"], user["id"]),
        )
    ).fetchall()
    comparable_setup_ids = [row["id"] for row in alias_rows]
    setup_placeholders = ",".join("?" for _ in comparable_setup_ids)
    rows = await (
        await db.execute(
            "SELECT g.*, a.started_at_utc AS activity_started_at_utc, "
            "a.title AS activity_title, "
            "se.exercise_setup_id, se.exercise_setup_name_snapshot FROM "
            "health_strength_set_groups g "
            "JOIN health_strength_session_exercises se ON se.id = g.session_exercise_id "
            "JOIN health_activities a ON a.id = g.activity_id "
            "WHERE g.family_id = ? AND g.owner_user_id = ? AND se.exercise_id = ? "
            f"AND se.exercise_setup_id IN ({setup_placeholders}) "
            "AND se.load_entry_mode_snapshot = ? AND se.rep_count_mode_snapshot = ? "
            "AND se.unilateral_mode_snapshot = ? AND g.training_role IN ('working','backoff','test') "
            "AND g.status IN ('completed','partial') AND a.status IN ('completed','partial') "
            "AND g.deleted_at IS NULL AND se.deleted_at IS NULL AND a.deleted_at IS NULL "
            "ORDER BY a.started_at_utc DESC, g.sequence DESC LIMIT ?",
            (
                user["family_id"],
                user["id"],
                exercise_id,
                *comparable_setup_ids,
                load_mode,
                rep_mode,
                unilateral_mode,
                limit,
            ),
        )
    ).fetchall()
    result: list[dict] = []
    for row in rows:
        components = [
            decoded_row(component, json_fields={"extra_metrics_json"})
            for component in await list_owned(
                db,
                table="health_strength_sets",
                user=user,
                where="set_group_id = ?",
                params=(row["id"],),
                order_by="component_index",
                limit=20,
            )
        ]
        performed = [item for item in components if is_performed_component(item)]
        if not performed:
            continue
        result.append(
            {
                "group_id": row["id"],
                "activity_id": row["activity_id"],
                "activity_title": row["activity_title"],
                "performed_at": row["activity_started_at_utc"],
                "source_setup_id": row["exercise_setup_id"],
                "canonical_setup_id": canonical_setup_id,
                "source_setup_label": row["exercise_setup_name_snapshot"],
                "training_role": row["training_role"],
                "failure_state": row["failure_state"],
                "components": [
                    {
                        "component_index": item["component_index"],
                        "reps": item["reps"],
                        "reps_left": item["reps_left"],
                        "reps_right": item["reps_right"],
                        "load_kg": item["normalized_external_load_kg"],
                        "rpe": item["rpe"],
                        "rir": item["rir"],
                    }
                    for item in performed[:8]
                ],
            }
        )
    return result


def _primary_repetitions(component: dict) -> int | None:
    if component.get("reps") is not None:
        return int(component["reps"])
    sides = [component.get("reps_left"), component.get("reps_right")]
    present = [int(value) for value in sides if value is not None]
    return min(present) if present else None


def _progression_candidate(planned_sets: list[dict], recent: list[dict]) -> dict:
    working = [
        item for item in planned_sets if item["training_role"] in {"working", "backoff", "test"}
    ]
    missing: list[str] = []
    if not working:
        missing.append("planned_working_sets")
    if not recent:
        missing.append("recent_comparable_sets")
    if working and any(
        item.get("reps_min") is None or item.get("reps_max") is None for item in working
    ):
        missing.append("planned_rep_range")
    latest_activity = recent[0]["activity_id"] if recent else None
    latest = [item for item in recent if item["activity_id"] == latest_activity]
    if missing or len(latest) < len(working):
        if working and len(latest) < len(working):
            missing.append("complete_recent_set_exposure")
        return {
            "action": "insufficient_context",
            "reason": "More comparable completed sets are needed before changing progression.",
            "evidence_group_ids": [item["group_id"] for item in latest],
            "missing_context": list(dict.fromkeys(missing)),
        }

    reached_top = True
    within_range = True
    excessive_effort = False
    effort_observed = False
    observed_groups = list(reversed(latest[: len(working)]))
    for planned, observed in zip(working, observed_groups, strict=True):
        primary = observed["components"][0]
        reps = _primary_repetitions(primary)
        reached_top = reached_top and reps is not None and reps >= planned["reps_max"]
        within_range = within_range and reps is not None and reps >= planned["reps_min"]
        if primary.get("rir") is not None:
            effort_observed = True
            if planned.get("rir_min") is not None:
                excessive_effort = excessive_effort or float(primary["rir"]) < float(
                    planned["rir_min"]
                )
        if primary.get("rpe") is not None:
            effort_observed = True
            if planned.get("rpe_max") is not None:
                excessive_effort = excessive_effort or float(primary["rpe"]) > float(
                    planned["rpe_max"]
                )
        if observed["failure_state"] in {"technical", "muscular"}:
            effort_observed = True
            excessive_effort = True
    has_effort_target = any(
        item.get("rir_min") is not None or item.get("rpe_max") is not None for item in working
    )
    if has_effort_target and not effort_observed:
        missing.append("observed_effort")
    if reached_top and not excessive_effort and not missing:
        action = "increase_load"
        reason = (
            "Every required recent set reached the top of its rep range within the effort target."
        )
        missing.append("configured_load_increment")
    elif within_range and not excessive_effort:
        action = "hold_load"
        reason = "Recent comparable sets remain inside the planned repetition and effort ranges."
    else:
        action = "hold_or_reduce"
        reason = (
            "Recent comparable sets missed the lower range or exceeded the planned effort target."
        )
    return {
        "action": action,
        "reason": reason,
        "evidence_group_ids": [item["group_id"] for item in latest],
        "missing_context": list(dict.fromkeys(missing)),
    }


def _declined_exercise_ids(rows) -> set[str]:
    declined: set[str] = set()
    for row in rows:
        try:
            payload = json.loads(row["payload_json"] or "{}")
        except json.JSONDecodeError:
            continue
        for exercise in payload.get("exercises", []):
            if isinstance(exercise, dict) and exercise.get("exercise_id"):
                declined.add(str(exercise["exercise_id"]))
    return declined


async def strength_suggestions(
    db,
    *,
    user: dict,
    available_minutes: int | None = None,
    equipment: list[str] | None = None,
    limit: int = 8,
) -> dict:
    """Return bounded, deterministic candidates; this function never writes."""
    from app.services.fitness import planning

    now = datetime.now(timezone.utc)
    plans = [
        item
        for item in await planning.list_planned_sessions(db, user=user)
        if item["sport_key"] == "strength"
        and item["status"] in {"accepted", "scheduled", "in_progress"}
    ]
    plan = plans[0] if plans else None
    issues = [
        decoded_row(row)
        for row in await list_owned(
            db,
            table="health_body_issue_observations",
            user=user,
            where="status = 'active'",
            order_by="observed_at_utc DESC",
            limit=12,
        )
    ]
    running = await (
        await db.execute(
            "SELECT COUNT(*) AS session_count, COALESCE(SUM(distance_m),0) AS distance_m, "
            "COALESCE(SUM(COALESCE(timer_duration_s,moving_duration_s,elapsed_duration_s)),0) "
            "AS duration_s, MAX(started_at_utc) AS latest_at FROM health_activities "
            "WHERE family_id = ? AND owner_user_id = ? AND sport_key = 'running' "
            "AND status IN ('completed','partial') AND started_at_utc >= ? "
            "AND deleted_at IS NULL",
            (
                user["family_id"],
                user["id"],
                (now - timedelta(days=7)).isoformat(),
            ),
        )
    ).fetchone()
    declined_rows = await (
        await db.execute(
            "SELECT payload_json FROM health_coach_proposals WHERE family_id = ? "
            "AND owner_user_id = ? AND proposal_kind = 'strength_workout' "
            "AND status = 'declined' AND deleted_at IS NULL ORDER BY declined_at DESC LIMIT 20",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    declined = _declined_exercise_ids(declined_rows)
    available = {
        value.strip().lower().replace(" ", "_") for value in equipment or [] if value.strip()
    }
    missing_context = []
    if available_minutes is None:
        missing_context.append("available_minutes")
    if not available:
        missing_context.append("available_equipment")
    if not declined_rows:
        missing_context.append("prior_rejections")
    if not plan:
        missing_context.append("planned_strength_session")

    if plan:
        planned_items = plan["exercise_items"]
    else:
        library = [
            await _exercise_response(db, user=user, row=row)
            for row in await list_owned(
                db,
                table="health_exercises",
                user=user,
                where="active = 1 AND merged_into_exercise_id IS NULL",
                order_by="favourite DESC, name",
                limit=limit,
            )
        ]
        if not library:
            missing_context.append("exercise_library")
        planned_items = [
            {
                "exercise_id": item["id"],
                "exercise_setup_id": item["setups"][0]["id"],
                "planned_sets": [],
                "substitution_exercise_ids": [],
                "sequence": index,
            }
            for index, item in enumerate(library[:limit])
            if item["setups"]
        ]

    candidates: list[dict] = []
    estimated_used = 0
    for planned in planned_items[:24]:
        exercise = await get_exercise(db, user=user, exercise_id=planned["exercise_id"])
        setup_id = planned.get("exercise_setup_id") or exercise["setups"][0]["id"]
        setup = next(
            (item for item in exercise["setups"] if item["id"] == setup_id),
            None,
        )
        if setup is None:
            setup = decoded_row(
                await owned_row(
                    db,
                    table="health_exercise_setups",
                    record_id=setup_id,
                    user=user,
                )
            )
        selected = exercise
        selected_setup = setup
        reasons = []
        equipment_key = (exercise.get("equipment_type") or "").lower().replace(" ", "_")
        unavailable = bool(available and equipment_key and equipment_key not in available)
        rejected = exercise["id"] in declined
        if unavailable:
            reasons.append(f"{exercise['name']} needs unavailable equipment: {equipment_key}.")
        if rejected:
            reasons.append("This exercise appeared in a previously declined Strength proposal.")
        if unavailable or rejected:
            for substitute_id in planned.get("substitution_exercise_ids", []):
                if substitute_id in declined:
                    continue
                substitute = await get_exercise(db, user=user, exercise_id=substitute_id)
                substitute_equipment = (
                    (substitute.get("equipment_type") or "").lower().replace(" ", "_")
                )
                if available and substitute_equipment and substitute_equipment not in available:
                    continue
                selected = substitute
                selected_setup = substitute["setups"][0]
                reasons.append(
                    f"Use the planned substitution {substitute['name']} for this session."
                )
                break
        selected_load_mode = selected_setup["load_entry_mode"] or selected["load_entry_mode"]
        selected_rep_mode = selected_setup["rep_count_mode"] or selected["rep_count_mode"]
        selected_unilateral_mode = selected_setup["unilateral_mode"] or selected["unilateral_mode"]
        recent = await _recent_comparable_groups(
            db,
            user=user,
            exercise_id=selected["id"],
            setup_id=selected_setup["id"],
            load_mode=selected_load_mode,
            rep_mode=selected_rep_mode,
            unilateral_mode=selected_unilateral_mode,
        )
        progression = _progression_candidate(planned.get("planned_sets", []), recent)
        if recent:
            latest = recent[0]
            reasons.append(
                f"Latest comparable evidence is {latest['activity_title']} on "
                f"{latest['performed_at'][:10]}."
            )
        else:
            reasons.append("No comparable completed set is available yet.")
        related_issues = issues
        if issues:
            reasons.append(
                f"There are {len(issues)} active structured body-issue observation(s) to review."
            )
        planned_groups = len(planned.get("planned_sets", [])) or 3
        estimated_minutes = max(5, planned_groups * 3)
        fits_time = (
            available_minutes is None or estimated_used + estimated_minutes <= available_minutes
        )
        if not fits_time:
            reasons.append("This item falls outside the supplied time budget.")
        else:
            estimated_used += estimated_minutes
        candidates.append(
            {
                "planned_exercise_id": planned.get("id"),
                "exercise_id": selected["id"],
                "exercise_name": selected["name"],
                "exercise_setup_id": selected_setup["id"],
                "setup_name": selected_setup["name"],
                "original_exercise_id": exercise["id"],
                "sequence": planned["sequence"],
                "included_in_time_budget": fits_time,
                "estimated_minutes": estimated_minutes,
                "progression": progression,
                "recent_evidence": recent[:4],
                "active_body_issues": related_issues[:4],
                "reasons": reasons,
            }
        )
        if len(candidates) >= limit:
            break
    running_context = {
        "window_days": 7,
        "session_count": int(running["session_count"]),
        "distance_m": float(running["distance_m"]),
        "duration_s": float(running["duration_s"]),
        "latest_at": running["latest_at"],
    }
    return {
        "generated_at": now.isoformat(),
        "planned_session": {
            "id": plan["id"],
            "title": plan["title"],
            "status": plan["status"],
            "expected_duration_s": plan["expected_duration_s"],
        }
        if plan
        else None,
        "session_candidate": {
            "kind": "planned_strength_session",
            "exercise_ids": [
                item["exercise_id"] for item in candidates if item["included_in_time_budget"]
            ],
            "estimated_minutes": estimated_used,
            "reason": "Built from the next owner-scoped Strength plan and recent comparable sets."
            if plan
            else "No session plan is available; candidates come from the private exercise library.",
        },
        "exercise_candidates": candidates,
        "recent_running_load": running_context,
        "active_body_issues": issues,
        "missing_context": missing_context,
    }


async def _default_setup(db, *, user: dict, exercise_id: str) -> str:
    row = await (
        await db.execute(
            "SELECT id FROM health_exercise_setups WHERE family_id = ? AND owner_user_id = ? "
            "AND exercise_id = ? AND active = 1 AND deleted_at IS NULL "
            "ORDER BY is_default DESC, created_at LIMIT 1",
            (user["family_id"], user["id"], exercise_id),
        )
    ).fetchone()
    if row is not None:
        return row["id"]
    return await _insert_default_setup(db, user=user, exercise_id=exercise_id)


async def _validate_planned_exercise_reference(
    db,
    *,
    user: dict,
    activity,
    exercise_id: str,
    setup_id: str,
    planned_exercise_id: str | None,
) -> tuple[str, object] | None:
    if planned_exercise_id is None:
        return None
    for table in (
        "health_planned_session_exercises",
        "health_strength_workout_exercises",
    ):
        try:
            planned = await owned_row(
                db,
                table=table,
                record_id=planned_exercise_id,
                user=user,
            )
            if table == "health_planned_session_exercises":
                if (
                    activity["planned_session_id"]
                    and planned["planned_session_id"] != activity["planned_session_id"]
                ):
                    raise FitnessConflictError(
                        "Planned exercise does not belong to this session's plan"
                    )
            elif activity["planned_session_id"]:
                plan = await owned_row(
                    db,
                    table="health_planned_sessions",
                    record_id=activity["planned_session_id"],
                    user=user,
                )
                if plan["workout_version_id"] != planned["workout_version_id"]:
                    raise FitnessConflictError(
                        "Template exercise does not belong to this session's plan"
                    )
            planned_exercise_id_canonical, _ = await resolve_exercise_id(
                db, user=user, exercise_id=planned["exercise_id"]
            )
            if planned_exercise_id_canonical != exercise_id:
                raise FitnessConflictError("Planned exercise does not match the recorded exercise")
            if planned["exercise_setup_id"]:
                planned_setup_id, _ = await resolve_setup_id(
                    db, user=user, setup_id=planned["exercise_setup_id"]
                )
                actual_setup_id, _ = await resolve_setup_id(db, user=user, setup_id=setup_id)
                if planned_setup_id != actual_setup_id:
                    raise FitnessConflictError(
                        "Planned exercise setup does not match the recorded setup"
                    )
            return table, planned
        except FitnessNotFoundError:
            continue
    raise FitnessNotFoundError("Planned exercise not found")


async def upsert_session_exercise(
    db,
    *,
    user: dict,
    body: StrengthSessionExercisePayload,
    record_id: str | None = None,
) -> dict:
    activity_id = str(body.activity_id)
    activity = await owned_row(db, table="health_activities", record_id=activity_id, user=user)
    if activity["sport_key"] != "strength":
        raise FitnessConflictError("Activity is not a strength session")
    exercise_id, _ = await resolve_exercise_id(db, user=user, exercise_id=str(body.exercise_id))
    if body.exercise_setup_id is None:
        setup_id = await _default_setup(db, user=user, exercise_id=exercise_id)
    else:
        setup_id, _ = await resolve_setup_id(db, user=user, setup_id=str(body.exercise_setup_id))
    setup = await owned_row(db, table="health_exercise_setups", record_id=setup_id, user=user)
    setup_exercise_id, _ = await resolve_exercise_id(
        db, user=user, exercise_id=setup["exercise_id"]
    )
    if setup_exercise_id != exercise_id:
        raise FitnessConflictError("Exercise setup does not belong to the exercise")
    await _validate_planned_exercise_reference(
        db,
        user=user,
        activity=activity,
        exercise_id=exercise_id,
        setup_id=setup_id,
        planned_exercise_id=str(body.planned_exercise_id) if body.planned_exercise_id else None,
    )
    identifier = record_id or new_id(body.id)
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    values.update(
        {
            "activity_id": activity_id,
            "exercise_id": exercise_id,
            "exercise_setup_id": setup_id,
        }
    )
    existing = await (
        await db.execute(
            "SELECT * FROM health_strength_session_exercises WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        exercise = await owned_row(db, table="health_exercises", record_id=exercise_id, user=user)
        values.update(
            {
                "exercise_setup_name_snapshot": setup["name"],
                "load_entry_mode_snapshot": setup["load_entry_mode"] or exercise["load_entry_mode"],
                "rep_count_mode_snapshot": setup["rep_count_mode"] or exercise["rep_count_mode"],
                "unilateral_mode_snapshot": setup["unilateral_mode"] or exercise["unilateral_mode"],
            }
        )
        await insert_owned(
            db,
            table="health_strength_session_exercises",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        if (
            existing["activity_id"] != activity_id
            or existing["exercise_id"] != exercise_id
            or existing["exercise_setup_id"] != setup_id
        ):
            raise FitnessConflictError(
                "A recorded session exercise cannot change its activity, exercise or setup"
            )
        values = {
            key: value
            for key, value in values.items()
            if key not in {"activity_id", "exercise_id", "exercise_setup_id"}
        }
        await update_owned(
            db,
            table="health_strength_session_exercises",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(
            db,
            table="health_strength_session_exercises",
            record_id=identifier,
            user=user,
        )
    )


async def upsert_set_group(
    db,
    *,
    user: dict,
    body: StrengthSetGroupPayload,
    record_id: str | None = None,
) -> dict:
    activity = await owned_row(
        db,
        table="health_activities",
        record_id=str(body.activity_id),
        user=user,
    )
    session_exercise = await owned_row(
        db,
        table="health_strength_session_exercises",
        record_id=str(body.session_exercise_id),
        user=user,
    )
    if activity["sport_key"] != "strength" or session_exercise["activity_id"] != activity["id"]:
        raise FitnessConflictError("Set group references do not belong to one strength session")
    if body.planned_set_id:
        if not session_exercise["planned_exercise_id"]:
            raise FitnessConflictError("A planned set requires a linked planned exercise")
        planned_set = None
        parent_field = None
        for table, candidate_parent_field in (
            ("health_planned_session_sets", "planned_session_exercise_id"),
            ("health_strength_planned_sets", "workout_exercise_id"),
        ):
            try:
                planned_set = await owned_row(
                    db,
                    table=table,
                    record_id=str(body.planned_set_id),
                    user=user,
                )
                parent_field = candidate_parent_field
                break
            except FitnessNotFoundError:
                continue
        if planned_set is None or parent_field is None:
            raise FitnessNotFoundError("Planned set not found")
        if planned_set[parent_field] != session_exercise["planned_exercise_id"]:
            raise FitnessConflictError("Planned set does not belong to the linked planned exercise")
    identifier = record_id or new_id(body.id)
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    existing = await (
        await db.execute(
            "SELECT id, activity_id, session_exercise_id, planned_set_id FROM "
            "health_strength_set_groups WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_strength_set_groups",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        if (
            existing["activity_id"] != activity["id"]
            or existing["session_exercise_id"] != session_exercise["id"]
            or existing["planned_set_id"]
            != (str(body.planned_set_id) if body.planned_set_id else None)
        ):
            raise FitnessConflictError(
                "A recorded set group cannot change its activity, exercise or planned set"
            )
        values = {
            key: value
            for key, value in values.items()
            if key not in {"activity_id", "session_exercise_id", "planned_set_id"}
        }
        await update_owned(
            db,
            table="health_strength_set_groups",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return await get_set_group(db, user=user, group_id=identifier)


def _positive_work(component: dict) -> bool:
    return any(
        float(component.get(field) or 0) > 0
        for field in ("reps", "reps_left", "reps_right", "duration_s", "distance_m")
    )


def is_performed_component(component: dict) -> bool:
    return component.get("component_status") == "completed" or (
        component.get("component_status") == "partial" and _positive_work(component)
    )


def summarize_group(group: dict, components: list[dict]) -> dict:
    performed_components = [item for item in components if is_performed_component(item)]
    performed = group.get("status") in {"completed", "partial"} and bool(performed_components)
    working_eligible, hard_eligible, volume_eligible = ROLE_RULES[group["training_role"]]
    effort_known = any(
        item.get("rir") is not None or item.get("rpe") is not None for item in performed_components
    ) or group.get("failure_state") in {"technical", "muscular"}
    hard = (
        performed
        and hard_eligible
        and (
            group.get("failure_state") in {"technical", "muscular"}
            or any(
                item.get("rir") is not None and float(item["rir"]) <= 3
                for item in performed_components
            )
            or any(
                item.get("rpe") is not None and float(item["rpe"]) >= 7
                for item in performed_components
            )
        )
    )
    volume = 0.0
    if performed and volume_eligible:
        for item in performed_components:
            load = item.get("normalized_external_load_kg")
            reps = item.get("reps")
            if reps is None and (
                item.get("reps_left") is not None or item.get("reps_right") is not None
            ):
                reps = int(item.get("reps_left") or 0) + int(item.get("reps_right") or 0)
            if load is not None and reps is not None:
                volume += float(load) * int(reps)
    return {
        "performed": performed,
        "performed_component_count": len(performed_components),
        "working_sets": 1 if performed and working_eligible else 0,
        "hard_sets": 1 if hard else 0,
        "hardness": "hard" if hard else ("not_hard" if effort_known else "unknown"),
        "unknown_hardness_sets": 1 if performed and working_eligible and not effort_known else 0,
        "primary_volume_kg": volume,
    }


async def _normalised_load(
    db,
    *,
    user: dict,
    group,
    body: StrengthSetComponentPayload,
) -> tuple[str, float | None, float | None, float | None]:
    session_exercise = await owned_row(
        db,
        table="health_strength_session_exercises",
        record_id=group["session_exercise_id"],
        user=user,
    )
    setup_id = session_exercise["exercise_setup_id"]
    setup = await owned_row(db, table="health_exercise_setups", record_id=setup_id, user=user)
    exercise_id, _ = await resolve_exercise_id(
        db, user=user, exercise_id=session_exercise["exercise_id"]
    )
    exercise = await owned_row(db, table="health_exercises", record_id=exercise_id, user=user)
    mode = session_exercise["load_entry_mode_snapshot"]
    rep_mode = session_exercise["rep_count_mode_snapshot"]
    unilateral_mode = session_exercise["unilateral_mode_snapshot"]
    measurement_mode = exercise["measurement_mode"]

    rep_fields = (body.reps, body.reps_left, body.reps_right)
    performed_fields = (
        *rep_fields,
        body.duration_s,
        body.distance_m,
        body.load_value,
        body.rpe,
        body.rir,
        body.completed_at_utc,
    )
    if body.component_status == "skipped":
        if any(value is not None for value in performed_fields):
            raise FitnessConflictError(
                "A skipped component cannot contain performed work or effort"
            )
    else:
        if rep_mode in {"total", "per_side"}:
            if body.reps_left is not None or body.reps_right is not None:
                raise FitnessConflictError("This setup records repetitions in the reps field")
        elif rep_mode == "left_right_separate":
            if body.reps is not None:
                raise FitnessConflictError(
                    "This setup records repetitions separately for left and right"
                )
        elif rep_mode == "not_applicable" and any(value is not None for value in rep_fields):
            raise FitnessConflictError("This setup does not record repetitions")

        if measurement_mode in {"reps_load", "reps_only"}:
            if rep_mode == "left_right_separate":
                has_work = (body.reps_left or 0) > 0 or (body.reps_right or 0) > 0
            else:
                has_work = (body.reps or 0) > 0
            if not has_work:
                raise FitnessConflictError(
                    "A completed or partial component requires recorded repetitions"
                )
        elif measurement_mode in {"duration", "duration_load"}:
            if not body.duration_s or body.duration_s <= 0:
                raise FitnessConflictError("A duration component requires positive duration_s")
        elif measurement_mode in {"distance", "distance_load"}:
            if not body.distance_m or body.distance_m <= 0:
                raise FitnessConflictError("A distance component requires positive distance_m")
        else:
            numeric_metrics = [
                value
                for value in body.extra_metrics.values()
                if isinstance(value, (int, float)) and not isinstance(value, bool)
            ]
            if not any(value > 0 for value in numeric_metrics):
                raise FitnessConflictError(
                    "A completed or partial component requires positive recorded work"
                )

    load = body.load_value
    if load is None and body.load_unit is not None:
        raise FitnessConflictError("load_unit requires load_value")
    if load is not None:
        if (
            mode
            in {
                "total_external",
                "per_hand",
                "per_side",
                "machine_stack",
                "added_bodyweight",
                "assistance",
            }
            and body.load_unit != "kg"
        ):
            raise FitnessConflictError(f"{mode} loads must use kg")
        if mode == "machine_level" and body.load_unit != "level":
            raise FitnessConflictError("machine_level loads must use level")
        if mode in {"bodyweight_only", "none"}:
            raise FitnessConflictError(f"{mode} does not accept a load value")
    normalized = None
    added = body.added_load_kg
    assistance = body.assistance_kg
    if load is not None:
        if mode in {"total_external", "machine_stack"}:
            normalized = load
        elif mode == "per_hand":
            multiplier = 1.0 if unilateral_mode == "unilateral_separate_sets" else 2.0
            normalized = load * multiplier
        elif mode == "per_side":
            multiplier = float(setup["side_multiplier"] or 2.0)
            normalized = load * multiplier + float(
                setup["bar_weight_kg"] or setup["machine_base_load_kg"] or 0
            )
        elif mode == "added_bodyweight":
            added = load
            normalized = added
        elif mode == "assistance":
            assistance = load
    return mode, normalized, added, assistance


async def upsert_set_component(
    db,
    *,
    user: dict,
    body: StrengthSetComponentPayload,
    record_id: str | None = None,
) -> dict:
    group = await owned_row(
        db,
        table="health_strength_set_groups",
        record_id=str(body.set_group_id),
        user=user,
    )
    mode, normalized, added, assistance = await _normalised_load(
        db, user=user, group=group, body=body
    )
    identifier = record_id or new_id(body.id)
    values = body.model_dump(
        exclude={
            "id",
            "client_id",
            "client_timestamp",
            "extra_metrics",
            "load_entry_mode_snapshot",
            "normalized_external_load_kg",
        }
    )
    values.update(
        {
            "load_entry_mode_snapshot": mode,
            "normalized_external_load_kg": normalized,
            "added_load_kg": added,
            "assistance_kg": assistance,
            "extra_metrics_json": body.extra_metrics,
        }
    )
    existing = await (
        await db.execute(
            "SELECT id, set_group_id FROM health_strength_sets WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_strength_sets",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        if existing["set_group_id"] != group["id"]:
            raise FitnessConflictError("A recorded set component cannot move to another set group")
        values.pop("set_group_id", None)
        await update_owned(
            db,
            table="health_strength_sets",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(db, table="health_strength_sets", record_id=identifier, user=user),
        json_fields={"extra_metrics_json"},
    )


async def get_set_group(db, *, user: dict, group_id: str) -> dict:
    group = decoded_row(
        await owned_row(db, table="health_strength_set_groups", record_id=group_id, user=user)
    )
    rows = await list_owned(
        db,
        table="health_strength_sets",
        user=user,
        where="set_group_id = ?",
        params=(group_id,),
        order_by="component_index",
    )
    components = [decoded_row(row, json_fields={"extra_metrics_json"}) for row in rows]
    group["components"] = components
    group["summary"] = summarize_group(group, components)
    return group


async def get_strength_session(db, *, user: dict, activity_id: str) -> dict:
    activity_row = await owned_row(
        db,
        table="health_activities",
        record_id=activity_id,
        user=user,
    )
    if await close_expired_strength_sessions(
        db,
        user=user,
        candidate_rows=[activity_row],
    ):
        activity_row = await owned_row(
            db,
            table="health_activities",
            record_id=activity_id,
            user=user,
        )
    activity = decoded_row(activity_row)
    if activity["sport_key"] != "strength":
        raise FitnessNotFoundError("Strength session not found")
    exercise_rows = await list_owned(
        db,
        table="health_strength_session_exercises",
        user=user,
        where="activity_id = ?",
        params=(activity_id,),
        order_by="sequence",
    )
    total = {
        "working_sets": 0,
        "hard_sets": 0,
        "unknown_hardness_sets": 0,
        "primary_volume_kg": 0.0,
    }
    exercises: list[dict] = []
    for exercise_row in exercise_rows:
        exercise = decoded_row(exercise_row)
        exercise["exercise"] = await get_exercise(
            db, user=user, exercise_id=exercise["exercise_id"]
        )
        exercise["setup"] = decoded_row(
            await owned_row(
                db,
                table="health_exercise_setups",
                record_id=exercise["exercise_setup_id"],
                user=user,
            )
        )
        exercise["source_setup_label"] = exercise["exercise_setup_name_snapshot"]
        group_rows = await list_owned(
            db,
            table="health_strength_set_groups",
            user=user,
            where="session_exercise_id = ?",
            params=(exercise["id"],),
            order_by="sequence",
        )
        exercise["set_groups"] = []
        for row in group_rows:
            group = await get_set_group(db, user=user, group_id=row["id"])
            exercise["set_groups"].append(group)
            for key in total:
                total[key] += group["summary"][key]
        exercises.append(exercise)
    activity["exercises"] = exercises
    activity["summary"] = total
    return activity


async def _batch_strength_sessions(db, *, user: dict, activity_rows) -> list[dict]:
    """Hydrate a bounded page without per-exercise or per-set-group queries."""
    if not activity_rows:
        return []
    activity_ids = [row["id"] for row in activity_rows]
    placeholders = ",".join("?" for _ in activity_ids)
    scope = (user["family_id"], user["id"], *activity_ids)
    exercise_rows = await (
        await db.execute(
            "SELECT * FROM health_strength_session_exercises WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL "
            f"AND activity_id IN ({placeholders}) ORDER BY activity_id, sequence",
            scope,
        )
    ).fetchall()
    group_rows = await (
        await db.execute(
            "SELECT * FROM health_strength_set_groups WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL "
            f"AND activity_id IN ({placeholders}) ORDER BY session_exercise_id, sequence",
            scope,
        )
    ).fetchall()
    component_rows = await (
        await db.execute(
            "SELECT s.* FROM health_strength_sets s "
            "JOIN health_strength_set_groups g ON g.id = s.set_group_id "
            "AND g.family_id = s.family_id AND g.owner_user_id = s.owner_user_id "
            "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.deleted_at IS NULL "
            "AND g.deleted_at IS NULL "
            f"AND g.activity_id IN ({placeholders}) "
            "ORDER BY s.set_group_id, s.component_index",
            scope,
        )
    ).fetchall()
    library_rows = await (
        await db.execute(
            "SELECT * FROM health_exercises WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    role_rows = await (
        await db.execute(
            "SELECT * FROM health_exercise_muscle_roles WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL "
            "ORDER BY exercise_id, role, muscle_group_key",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    setup_rows = await (
        await db.execute(
            "SELECT * FROM health_exercise_setups WHERE family_id = ? "
            "AND owner_user_id = ? AND deleted_at IS NULL "
            "ORDER BY exercise_id, is_default DESC, name",
            (user["family_id"], user["id"]),
        )
    ).fetchall()

    library_by_id = {row["id"]: row for row in library_rows}
    roles_by_exercise: dict[str, list[dict]] = defaultdict(list)
    for row in role_rows:
        roles_by_exercise[row["exercise_id"]].append(
            {
                "muscle_group_key": row["muscle_group_key"],
                "role": row["role"],
                "contribution_weight": row["contribution_weight"],
            }
        )
    setups_by_exercise: dict[str, list[dict]] = defaultdict(list)
    setup_by_id = {}
    for row in setup_rows:
        setup = decoded_row(row)
        setup_by_id[setup["id"]] = setup
        if setup["active"]:
            setups_by_exercise[setup["exercise_id"]].append(setup)

    def exercise_response(source_id: str) -> dict:
        seen: list[str] = []
        canonical_id = source_id
        while True:
            if canonical_id in seen or len(seen) >= 100:
                raise FitnessConflictError("Exercise merge redirect loop")
            seen.append(canonical_id)
            row = library_by_id.get(canonical_id)
            if row is None:
                raise FitnessNotFoundError("Fitness record not found")
            if not row["merged_into_exercise_id"]:
                break
            canonical_id = row["merged_into_exercise_id"]
        data = decoded_row(library_by_id[canonical_id], json_fields={"aliases_json"})
        data["muscle_roles"] = list(roles_by_exercise[canonical_id])
        data["setups"] = [dict(item) for item in setups_by_exercise[canonical_id]]
        if source_id != canonical_id:
            data["redirect"] = {"source_id": source_id, "target_id": canonical_id}
        return data

    components_by_group: dict[str, list[dict]] = defaultdict(list)
    for row in component_rows:
        components_by_group[row["set_group_id"]].append(
            decoded_row(row, json_fields={"extra_metrics_json"})
        )
    groups_by_exercise: dict[str, list[dict]] = defaultdict(list)
    for row in group_rows:
        group = decoded_row(row)
        components = components_by_group[group["id"]]
        group["components"] = components
        group["summary"] = summarize_group(group, components)
        groups_by_exercise[group["session_exercise_id"]].append(group)
    session_exercises_by_activity: dict[str, list[dict]] = defaultdict(list)
    for row in exercise_rows:
        exercise = decoded_row(row)
        exercise["exercise"] = exercise_response(exercise["exercise_id"])
        setup = setup_by_id.get(exercise["exercise_setup_id"])
        if setup is None:
            raise FitnessNotFoundError("Fitness record not found")
        exercise["setup"] = dict(setup)
        exercise["source_setup_label"] = exercise["exercise_setup_name_snapshot"]
        exercise["set_groups"] = groups_by_exercise[exercise["id"]]
        session_exercises_by_activity[exercise["activity_id"]].append(exercise)

    sessions = []
    for row in activity_rows:
        activity = decoded_row(row)
        exercises = session_exercises_by_activity[activity["id"]]
        total = {
            "working_sets": 0,
            "hard_sets": 0,
            "unknown_hardness_sets": 0,
            "primary_volume_kg": 0.0,
        }
        for exercise in exercises:
            for group in exercise["set_groups"]:
                for key in total:
                    total[key] += group["summary"][key]
        activity["exercises"] = exercises
        activity["summary"] = total
        sessions.append(activity)
    return sessions


async def delete_set_group(db, *, user: dict, group_id: str) -> None:
    await owned_row(db, table="health_strength_set_groups", record_id=group_id, user=user)
    rows = await list_owned(
        db,
        table="health_strength_sets",
        user=user,
        where="set_group_id = ?",
        params=(group_id,),
    )
    for row in rows:
        await soft_delete_owned(db, table="health_strength_sets", record_id=row["id"], user=user)
    await soft_delete_owned(db, table="health_strength_set_groups", record_id=group_id, user=user)


async def finish_strength_session(
    db, *, user: dict, activity_id: str, body: StrengthSessionFinish
) -> dict:
    activity = await owned_row(db, table="health_activities", record_id=activity_id, user=user)
    if activity["sport_key"] != "strength":
        raise FitnessNotFoundError("Strength session not found")
    if body.ended_at_utc.isoformat() < activity["started_at_utc"]:
        raise FitnessConflictError("ended_at_utc cannot be before started_at_utc")
    await update_owned(
        db,
        table="health_activities",
        record_id=activity_id,
        values={**body.model_dump(), "rest_timer_deadline_utc": None},
        user=user,
    )
    if activity["planned_session_id"]:
        status = {
            "completed": "completed",
            "partial": "partially_completed",
            "aborted": "cancelled",
        }[body.status]
        await update_owned(
            db,
            table="health_planned_sessions",
            record_id=activity["planned_session_id"],
            values={
                "status": status,
                "completion_activity_id": activity_id,
                "completion_state": body.status,
            },
            user=user,
        )
    return await get_strength_session(db, user=user, activity_id=activity_id)


async def upsert_checkin(
    db,
    *,
    user: dict,
    body: SessionCheckinPayload,
    record_id: str | None = None,
) -> dict:
    await validate_owned_reference(
        db,
        table="health_planned_sessions",
        record_id=str(body.planned_session_id) if body.planned_session_id else None,
        user=user,
    )
    activity = None
    if body.activity_id:
        activity = await owned_row(
            db,
            table="health_activities",
            record_id=str(body.activity_id),
            user=user,
        )
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    if activity is not None and body.timing == "pre":
        captured = body.captured_at_utc.astimezone(timezone.utc)
        started = datetime.fromisoformat(
            activity["started_at_utc"].replace("Z", "+00:00")
        ).astimezone(timezone.utc)
        before_start = captured <= started
        values["captured_before_activity_start"] = before_start
        if not before_start:
            values["capture_quality"] = "retrospective"
    identifier = record_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT id FROM health_session_checkins WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_session_checkins",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_session_checkins",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(db, table="health_session_checkins", record_id=identifier, user=user)
    )


async def list_checkins(db, *, user: dict, activity_id: str | None = None) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_session_checkins",
        user=user,
        where="activity_id = ?" if activity_id else "",
        params=(activity_id,) if activity_id else (),
        order_by="captured_at_utc DESC",
    )
    return [decoded_row(row) for row in rows]


async def upsert_body_issue(
    db,
    *,
    user: dict,
    body: BodyIssuePayload,
    record_id: str | None = None,
) -> dict:
    location = await (
        await db.execute(
            "SELECT location_key FROM health_body_locations WHERE family_id = 'system' "
            "AND owner_user_id = 'system' AND location_key = ? AND active = 1 "
            "AND deleted_at IS NULL",
            (body.body_location_key,),
        )
    ).fetchone()
    if location is None:
        raise FitnessConflictError("That body location is no longer available")

    reference_specs = {
        "planned": ("health_planned_sessions", body.planned_session_id),
        "activity": ("health_activities", body.activity_id),
        "session_exercise": (
            "health_strength_session_exercises",
            body.session_exercise_id,
        ),
        "set_group": ("health_strength_set_groups", body.set_group_id),
        "checkin": ("health_session_checkins", body.checkin_id),
    }
    references = {}
    for key, (table, raw_identifier) in reference_specs.items():
        references[key] = (
            await owned_row(
                db,
                table=table,
                record_id=str(raw_identifier),
                user=user,
            )
            if raw_identifier
            else None
        )

    session_exercise = references["session_exercise"]
    set_group = references["set_group"]
    if (
        session_exercise
        and set_group
        and set_group["session_exercise_id"] != session_exercise["id"]
    ):
        raise FitnessConflictError(
            "Body-issue set group does not belong to the referenced session exercise"
        )
    activity_ids = {
        identifier
        for identifier in (
            references["activity"]["id"] if references["activity"] else None,
            session_exercise["activity_id"] if session_exercise else None,
            set_group["activity_id"] if set_group else None,
            references["checkin"]["activity_id"] if references["checkin"] else None,
        )
        if identifier is not None
    }
    if len(activity_ids) > 1:
        raise FitnessConflictError(
            "Body-issue activity, exercise, set group and check-in references disagree"
        )
    planned_ids = {
        identifier
        for identifier in (
            references["planned"]["id"] if references["planned"] else None,
            references["activity"]["planned_session_id"] if references["activity"] else None,
            references["checkin"]["planned_session_id"] if references["checkin"] else None,
        )
        if identifier is not None
    }
    if len(planned_ids) > 1:
        raise FitnessConflictError(
            "Body-issue planned-session, activity and check-in references disagree"
        )
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    identifier = record_id or new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT id FROM health_body_issue_observations WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_body_issue_observations",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_body_issue_observations",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(
            db,
            table="health_body_issue_observations",
            record_id=identifier,
            user=user,
        )
    )


async def list_body_locations(db) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT id, location_key, parent_key, display_name, active FROM "
            "health_body_locations WHERE family_id = 'system' AND owner_user_id = 'system' "
            "AND active = 1 AND deleted_at IS NULL ORDER BY display_name, location_key"
        )
    ).fetchall()
    return [dict(row) for row in rows]


async def list_body_issues(
    db, *, user: dict, active_only: bool = False, activity_id: str | None = None
) -> list[dict]:
    clauses: list[str] = []
    params: list[str] = []
    if active_only:
        clauses.append("status = 'active'")
    if activity_id:
        clauses.append("activity_id = ?")
        params.append(activity_id)
    rows = await list_owned(
        db,
        table="health_body_issue_observations",
        user=user,
        where=" AND ".join(clauses),
        params=params,
        order_by="observed_at_utc DESC",
    )
    return [decoded_row(row) for row in rows]


async def delete_body_issue(db, *, user: dict, issue_id: str) -> None:
    await soft_delete_owned(
        db,
        table="health_body_issue_observations",
        record_id=issue_id,
        user=user,
    )


def _primary_repetitions(component: dict) -> int:
    if component.get("reps") is not None:
        return int(component["reps"])
    side_reps = [
        int(value)
        for value in (component.get("reps_left"), component.get("reps_right"))
        if value is not None
    ]
    return min(side_reps, default=0)


def estimated_one_rep_max(group: dict, component: dict) -> float | None:
    if group["structure_type"] != "straight" or group["training_role"] not in {
        "working",
        "backoff",
        "test",
    }:
        return None
    if not is_performed_component(component):
        return None
    # Left/right entries are retained as observed evidence, but summing them
    # would silently turn 8 each side into a 16-rep e1RM set.
    if component.get("reps") is None:
        return None
    reps = _primary_repetitions(component)
    load = component.get("normalized_external_load_kg")
    mode = component.get("load_entry_mode_snapshot")
    if reps < 1 or load is None or float(load) <= 0:
        return None
    if mode in {
        "assistance",
        "machine_level",
        "bodyweight_only",
        "none",
    }:
        return None
    effort_rir = None
    if component.get("rir") is not None and float(component["rir"]) <= 3:
        effort_rir = float(component["rir"])
    elif component.get("rpe") is not None and float(component["rpe"]) >= 7:
        effort_rir = 10.0 - float(component["rpe"])
    elif group.get("failure_state") in {"technical", "muscular"}:
        effort_rir = 0.0
    if effort_rir is None or reps + effort_rir > 10:
        return None
    return float(load) * (1 + (reps + effort_rir) / 30.0)


async def exercise_progress(db, *, user: dict, exercise_id: str) -> dict:
    canonical_id, aliases = await resolve_exercise_id(db, user=user, exercise_id=exercise_id)
    rows = await (
        await db.execute(
            "SELECT se.id AS session_exercise_id, se.exercise_setup_id, "
            "se.exercise_setup_name_snapshot, se.load_entry_mode_snapshot AS "
            "session_load_entry_mode_snapshot, se.rep_count_mode_snapshot, "
            "se.unilateral_mode_snapshot, a.id AS activity_id, "
            "a.title AS activity_title, a.started_at_utc, g.* "
            "FROM health_strength_session_exercises se "
            "JOIN health_activities a ON a.id = se.activity_id "
            "JOIN health_strength_set_groups g ON g.session_exercise_id = se.id "
            "WHERE se.family_id = ? AND se.owner_user_id = ? AND se.exercise_id = ? "
            "AND se.deleted_at IS NULL AND a.deleted_at IS NULL AND g.deleted_at IS NULL "
            "AND a.status IN ('completed','partial') ORDER BY a.started_at_utc, g.sequence",
            (user["family_id"], user["id"], canonical_id),
        )
    ).fetchall()
    groups: list[dict] = []
    observed: list[dict] = []
    estimates_by_session_and_setup: dict[tuple[str, str, str, str, str], dict] = {}
    canonical_setup_ids: dict[str, str] = {}
    for row in rows:
        group = decoded_row(row)
        source_setup_id = group["exercise_setup_id"]
        if source_setup_id not in canonical_setup_ids:
            canonical_setup_ids[source_setup_id], _ = await resolve_setup_id(
                db, user=user, setup_id=source_setup_id
            )
        canonical_setup_id = canonical_setup_ids[source_setup_id]
        component_rows = await list_owned(
            db,
            table="health_strength_sets",
            user=user,
            where="set_group_id = ?",
            params=(group["id"],),
            order_by="component_index",
        )
        components = [
            decoded_row(item, json_fields={"extra_metrics_json"}) for item in component_rows
        ]
        group["components"] = components
        group["summary"] = summarize_group(group, components)
        group["source_setup_id"] = source_setup_id
        group["canonical_setup_id"] = canonical_setup_id
        group["source_setup_label"] = group["exercise_setup_name_snapshot"]
        group["comparison_key"] = {
            "exercise_id": canonical_id,
            "setup_id": canonical_setup_id,
            "load_entry_mode": group["session_load_entry_mode_snapshot"],
            "rep_count_mode": group["rep_count_mode_snapshot"],
            "unilateral_mode": group["unilateral_mode_snapshot"],
        }
        groups.append(group)
        if group["training_role"] not in {"working", "backoff", "test"}:
            continue
        for component in components:
            if not is_performed_component(component):
                continue
            item = {
                "activity_id": group["activity_id"],
                "activity_title": group["activity_title"],
                "started_at_utc": group["started_at_utc"],
                "group_id": group["id"],
                "setup_id": canonical_setup_id,
                "source_setup_id": source_setup_id,
                "canonical_setup_id": canonical_setup_id,
                "source_setup_label": group["source_setup_label"],
                "comparison_key": group["comparison_key"],
                "structure_type": group["structure_type"],
                "training_role": group["training_role"],
                "failure_state": group["failure_state"],
                **component,
            }
            observed.append(item)
            estimate = estimated_one_rep_max(group, component)
            if estimate is not None:
                candidate = {
                    "estimated_1rm_kg": estimate,
                    "comparison_key": group["comparison_key"],
                    "source_setup_label": group["source_setup_label"],
                    "source_set": item,
                }
                estimate_key = (
                    group["activity_id"],
                    canonical_setup_id,
                    group["session_load_entry_mode_snapshot"],
                    group["rep_count_mode_snapshot"],
                    group["unilateral_mode_snapshot"],
                )
                current = estimates_by_session_and_setup.get(estimate_key)
                if current is None or estimate > current["estimated_1rm_kg"]:
                    estimates_by_session_and_setup[estimate_key] = candidate

    loaded_by_comparison: dict[tuple[str, str, str, str], list[dict]] = defaultdict(list)
    comparison_keys: dict[tuple[str, str, str, str], dict] = {}
    labels_by_comparison: dict[tuple[str, str, str, str], str] = {}
    for item in observed:
        if item.get("normalized_external_load_kg") is None or _primary_repetitions(item) <= 0:
            continue
        comparison = item["comparison_key"]
        token = (
            comparison["setup_id"],
            comparison["load_entry_mode"],
            comparison["rep_count_mode"],
            comparison["unilateral_mode"],
        )
        loaded_by_comparison[token].append(item)
        comparison_keys[token] = comparison
        labels_by_comparison[token] = item["source_setup_label"]

    records_by_comparison: list[dict] = []
    for token, loaded in loaded_by_comparison.items():
        heaviest = max(
            loaded,
            key=lambda item: float(item["normalized_external_load_kg"]),
        )
        rep_bands = {}
        for label, lower, upper in (
            ("1-3", 1, 3),
            ("4-6", 4, 6),
            ("7-10", 7, 10),
            ("11-15", 11, 15),
        ):
            candidates = [item for item in loaded if lower <= _primary_repetitions(item) <= upper]
            rep_bands[label] = max(
                candidates,
                key=lambda item: float(item["normalized_external_load_kg"]),
                default=None,
            )
        records_by_comparison.append(
            {
                "comparison_key": comparison_keys[token],
                "source_setup_label": labels_by_comparison[token],
                "heaviest": heaviest,
                "best_by_rep_band": rep_bands,
            }
        )
    records_by_comparison.sort(
        key=lambda item: (item["source_setup_label"].casefold(), item["comparison_key"]["setup_id"])
    )
    # Preserve the original shape only when it represents one comparable setup.
    # With multiple setup/mode keys there is deliberately no cross-setup headline.
    if len(records_by_comparison) == 1:
        records = {
            "heaviest": records_by_comparison[0]["heaviest"],
            "best_by_rep_band": records_by_comparison[0]["best_by_rep_band"],
        }
    else:
        records = {
            "heaviest": None,
            "best_by_rep_band": {
                "1-3": None,
                "4-6": None,
                "7-10": None,
                "11-15": None,
            },
        }
    return {
        "exercise": await get_exercise(db, user=user, exercise_id=canonical_id),
        "redirect": {"source_id": exercise_id, "target_id": canonical_id} if aliases else None,
        "logical_set_groups": groups,
        "observed_sets": observed,
        "records": records,
        "records_by_comparison": records_by_comparison,
        "estimated_1rm": sorted(
            estimates_by_session_and_setup.values(),
            key=lambda item: (
                item["source_set"]["started_at_utc"],
                item["source_setup_label"].casefold(),
                item["comparison_key"]["setup_id"],
            ),
        ),
    }


async def muscle_group_summary(db, *, user: dict) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT g.*, se.exercise_id, a.started_at_utc AS activity_started_at_utc "
            "FROM health_strength_set_groups g "
            "JOIN health_strength_session_exercises se ON se.id = g.session_exercise_id "
            "JOIN health_activities a ON a.id = g.activity_id "
            "WHERE g.family_id = ? AND g.owner_user_id = ? AND g.deleted_at IS NULL "
            "AND se.deleted_at IS NULL AND a.deleted_at IS NULL "
            "AND a.status IN ('completed','partial') ORDER BY a.started_at_utc",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    component_rows = await (
        await db.execute(
            "SELECT s.* FROM health_strength_sets s "
            "JOIN health_strength_set_groups g ON g.id = s.set_group_id "
            "AND g.family_id = s.family_id AND g.owner_user_id = s.owner_user_id "
            "JOIN health_activities a ON a.id = g.activity_id "
            "AND a.family_id = g.family_id AND a.owner_user_id = g.owner_user_id "
            "WHERE s.family_id = ? AND s.owner_user_id = ? AND s.deleted_at IS NULL "
            "AND g.deleted_at IS NULL AND a.deleted_at IS NULL "
            "AND a.status IN ('completed','partial') "
            "ORDER BY s.set_group_id, s.component_index",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    role_rows = await (
        await db.execute(
            "SELECT exercise_id, muscle_group_key, role, contribution_weight FROM "
            "health_exercise_muscle_roles WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL ORDER BY exercise_id, role, muscle_group_key",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    components_by_group: dict[str, list[dict]] = defaultdict(list)
    for row in component_rows:
        components_by_group[row["set_group_id"]].append(
            decoded_row(row, json_fields={"extra_metrics_json"})
        )
    roles_by_exercise: dict[str, list] = defaultdict(list)
    for row in role_rows:
        roles_by_exercise[row["exercise_id"]].append(row)
    totals: dict[str, dict] = defaultdict(
        lambda: {
            "direct_working_sets": 0,
            "indirect_set_equivalents": 0.0,
            "direct_hard_sets": 0,
            "unknown_hardness_sets": 0,
            "training_dates": set(),
            "contributing_exercises": set(),
            "last_trained_at": None,
        }
    )
    for row in rows:
        group = decoded_row(row)
        components = components_by_group[group["id"]]
        summary = summarize_group(group, components)
        if summary["working_sets"] == 0:
            continue
        for role in roles_by_exercise[group["exercise_id"]]:
            target = totals[role["muscle_group_key"]]
            if role["role"] == "primary":
                target["direct_working_sets"] += 1
                target["direct_hard_sets"] += summary["hard_sets"]
                target["unknown_hardness_sets"] += summary["unknown_hardness_sets"]
            else:
                target["indirect_set_equivalents"] += float(role["contribution_weight"] or 0.5)
            trained_at = group["activity_started_at_utc"]
            target["training_dates"].add(trained_at[:10])
            target["contributing_exercises"].add(group["exercise_id"])
            if target["last_trained_at"] is None or trained_at > target["last_trained_at"]:
                target["last_trained_at"] = trained_at
    today = datetime.now(timezone.utc).date()
    output: list[dict] = []
    for muscle_key, values in sorted(totals.items()):
        last_date = date.fromisoformat(values["last_trained_at"][:10])
        output.append(
            {
                "muscle_group_key": muscle_key,
                "direct_working_sets": values["direct_working_sets"],
                "indirect_set_equivalents": values["indirect_set_equivalents"],
                "direct_hard_sets": values["direct_hard_sets"],
                "unknown_hardness_sets": values["unknown_hardness_sets"],
                "frequency_days": len(values["training_dates"]),
                "days_since_last_trained": (today - last_date).days,
                "last_trained_at": values["last_trained_at"],
                "contributing_exercise_ids": sorted(values["contributing_exercises"]),
            }
        )
    return output
