"""Fitness settings, goals, phases and planned-session services."""

from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models.fitness import (
    CalendarPreferencesUpdate,
    CoachPreferencesUpdate,
    GoalPatch,
    GoalPayload,
    GoalRelationshipPayload,
    NutritionSettingsUpdate,
    PlannedSessionPayload,
    TrainingPhasePayload,
)
from app.services.fitness.common import (
    FitnessConflictError,
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


def _payload_values(model, *, exclude: set[str] | None = None) -> dict:
    return model.model_dump(
        exclude={"id", "client_id", "client_timestamp", *(exclude or set())},
        exclude_unset=False,
    )


async def ensure_settings(db, *, user: dict) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM health_user_settings WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is not None:
        return decoded_row(row, json_fields={"heart_rate_zone_boundaries_bpm_json"})
    async with serialized_create(db):
        row = await (
            await db.execute(
                "SELECT * FROM health_user_settings WHERE family_id = ? AND owner_user_id = ? "
                "AND deleted_at IS NULL",
                (user["family_id"], user["id"]),
            )
        ).fetchone()
        if row is None:
            settings_id = new_id()
            await insert_owned(
                db,
                table="health_user_settings",
                record_id=settings_id,
                values={
                    "nutrition_day_start_minutes": 240,
                    "timezone": "Europe/London",
                    "revision": 1,
                },
                user=user,
            )
            row = await owned_row(
                db,
                table="health_user_settings",
                record_id=settings_id,
                user=user,
            )
    return decoded_row(row, json_fields={"heart_rate_zone_boundaries_bpm_json"})


async def update_settings(db, *, user: dict, body: NutritionSettingsUpdate) -> dict:
    existing = await ensure_settings(db, user=user)
    values = body.model_dump(exclude_none=True)
    if "heart_rate_zone_boundaries_bpm" in values:
        values["heart_rate_zone_boundaries_bpm_json"] = values.pop("heart_rate_zone_boundaries_bpm")
    await update_owned(
        db,
        table="health_user_settings",
        record_id=existing["id"],
        values=values,
        user=user,
    )
    return decoded_row(
        await owned_row(
            db,
            table="health_user_settings",
            record_id=existing["id"],
            user=user,
        ),
        json_fields={"heart_rate_zone_boundaries_bpm_json"},
    )


def _calendar_preferences(settings: dict) -> dict:
    return {
        "show_planned": bool(settings["show_planned"]),
        "show_completed": bool(settings["show_completed"]),
    }


async def get_calendar_preferences(db, *, user: dict) -> dict:
    return _calendar_preferences(await ensure_settings(db, user=user))


async def update_calendar_preferences(db, *, user: dict, body: CalendarPreferencesUpdate) -> dict:
    settings = await ensure_settings(db, user=user)
    await update_owned(
        db,
        table="health_user_settings",
        record_id=settings["id"],
        values=body.model_dump(exclude_none=True),
        user=user,
    )
    return await get_calendar_preferences(db, user=user)


def _coach_preferences(settings: dict) -> dict:
    return {
        "personality_preset": settings["coach_personality_preset"],
        "directness": int(settings["coach_directness"]),
        "challenge_bias": settings["coach_challenge_bias"],
        "detail_level": settings["coach_detail_level"],
        "custom_instruction": settings["coach_custom_instruction"],
        "coach_memory_enabled": bool(settings["coach_memory_enabled"]),
        "coach_memory_enabled_at": settings["coach_memory_enabled_at"],
    }


async def get_coach_preferences(db, *, user: dict) -> dict:
    return _coach_preferences(await ensure_settings(db, user=user))


async def update_coach_preferences(db, *, user: dict, body: CoachPreferencesUpdate) -> dict:
    settings = await ensure_settings(db, user=user)
    await update_owned(
        db,
        table="health_user_settings",
        record_id=settings["id"],
        values={
            "coach_personality_preset": body.personality_preset,
            "coach_directness": body.directness,
            "coach_challenge_bias": body.challenge_bias,
            "coach_detail_level": body.detail_level,
            "coach_custom_instruction": body.custom_instruction,
        },
        user=user,
    )
    return await get_coach_preferences(db, user=user)


async def list_goals(db, *, user: dict) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_goals",
        user=user,
        order_by="priority DESC, starts_on DESC, created_at DESC",
    )
    return [decoded_row(row) for row in rows]


async def upsert_goal(
    db,
    *,
    user: dict,
    body: GoalPayload,
    record_id: str | None = None,
) -> dict:
    goal_id = record_id or new_id(body.id)
    values = _payload_values(body)
    values["starts_on"] = body.starts_on.isoformat()
    values["target_date"] = body.target_date.isoformat() if body.target_date else None
    existing = await (
        await db.execute(
            "SELECT * FROM health_goals WHERE id = ? AND family_id = ? AND owner_user_id = ?",
            (goal_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_goals",
            record_id=goal_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_goals",
            record_id=goal_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(await owned_row(db, table="health_goals", record_id=goal_id, user=user))


async def patch_goal(db, *, user: dict, goal_id: str, body: GoalPatch) -> dict:
    await owned_row(db, table="health_goals", record_id=goal_id, user=user)
    values = body.model_dump(exclude_unset=True)
    for key in ("starts_on", "target_date"):
        if key in values and values[key] is not None:
            values[key] = values[key].isoformat()
    if values:
        await update_owned(db, table="health_goals", record_id=goal_id, values=values, user=user)
    return decoded_row(await owned_row(db, table="health_goals", record_id=goal_id, user=user))


async def complete_goal(db, *, user: dict, goal_id: str) -> dict:
    await owned_row(db, table="health_goals", record_id=goal_id, user=user)
    await update_owned(
        db,
        table="health_goals",
        record_id=goal_id,
        values={"status": "completed", "completed_at": now_iso()},
        user=user,
    )
    return decoded_row(await owned_row(db, table="health_goals", record_id=goal_id, user=user))


async def list_goal_relationships(db, *, user: dict) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_goal_relationships",
        user=user,
        order_by="created_at, id",
    )
    return [decoded_row(row) for row in rows]


async def upsert_goal_relationship(
    db,
    *,
    user: dict,
    body: GoalRelationshipPayload,
    record_id: str | None = None,
) -> dict:
    relationship_id = record_id or new_id(body.id)
    source_goal_id = str(body.source_goal_id)
    target_goal_id = str(body.target_goal_id)
    await validate_owned_reference(db, table="health_goals", record_id=source_goal_id, user=user)
    await validate_owned_reference(db, table="health_goals", record_id=target_goal_id, user=user)
    duplicate = await (
        await db.execute(
            "SELECT id FROM health_goal_relationships WHERE family_id = ? "
            "AND owner_user_id = ? AND source_goal_id = ? AND target_goal_id = ? "
            "AND relationship = ? AND id <> ? AND deleted_at IS NULL LIMIT 1",
            (
                user["family_id"],
                user["id"],
                source_goal_id,
                target_goal_id,
                body.relationship,
                relationship_id,
            ),
        )
    ).fetchone()
    if duplicate is not None:
        raise FitnessConflictError("This goal relationship already exists")
    values = {
        "source_goal_id": source_goal_id,
        "target_goal_id": target_goal_id,
        "relationship": body.relationship,
        "notes": body.notes,
    }
    existing = await (
        await db.execute(
            "SELECT id FROM health_goal_relationships WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (relationship_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_goal_relationships",
            record_id=relationship_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_goal_relationships",
            record_id=relationship_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return decoded_row(
        await owned_row(
            db,
            table="health_goal_relationships",
            record_id=relationship_id,
            user=user,
        )
    )


async def delete_goal_relationship(db, *, user: dict, relationship_id: str) -> int:
    return await soft_delete_owned(
        db,
        table="health_goal_relationships",
        record_id=relationship_id,
        user=user,
    )


async def _replace_phase_goal_links(
    db,
    *,
    user: dict,
    phase_id: str,
    links,
) -> None:
    now = now_iso()
    await save_owned_rows_history(
        db,
        table="health_training_phase_goal_links",
        user=user,
        where="training_phase_id = ? AND deleted_at IS NULL",
        params=(phase_id,),
    )
    await db.execute(
        "UPDATE health_training_phase_goal_links SET deleted_at = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND training_phase_id = ? "
        "AND deleted_at IS NULL",
        (now, now, user["family_id"], user["id"], phase_id),
    )
    for link in links:
        await owned_row(
            db,
            table="health_goals",
            record_id=str(link.goal_id),
            user=user,
        )
        await insert_owned(
            db,
            table="health_training_phase_goal_links",
            record_id=new_id(),
            values={
                "training_phase_id": phase_id,
                "goal_id": str(link.goal_id),
                "role": link.role,
                "revision": 1,
            },
            user=user,
            now=now,
        )


async def _phase_response(db, *, user: dict, row) -> dict:
    data = decoded_row(
        row,
        json_fields={
            "calorie_policy_json",
            "protein_policy_json",
            "running_priorities_json",
            "strength_priorities_json",
            "accepted_tradeoffs_json",
        },
    )
    links = await (
        await db.execute(
            "SELECT goal_id, role FROM health_training_phase_goal_links "
            "WHERE family_id = ? AND owner_user_id = ? AND training_phase_id = ? "
            "AND deleted_at IS NULL ORDER BY CASE role WHEN 'primary' THEN 0 ELSE 1 END, created_at",
            (user["family_id"], user["id"], data["id"]),
        )
    ).fetchall()
    data["goal_links"] = [dict(link) for link in links]
    return data


async def list_phases(db, *, user: dict) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_training_phases",
        user=user,
        order_by="starts_on DESC, created_at DESC",
    )
    return [await _phase_response(db, user=user, row=row) for row in rows]


async def upsert_phase(
    db,
    *,
    user: dict,
    body: TrainingPhasePayload,
    record_id: str | None = None,
) -> dict:
    phase_id = record_id or new_id(body.id)
    values = {
        "phase_type": body.phase_type,
        "name": body.name,
        "starts_on": body.starts_on.isoformat(),
        "ends_on": body.ends_on.isoformat() if body.ends_on else None,
        "calorie_policy_json": body.calorie_policy,
        "protein_policy_json": body.protein_policy,
        "running_priorities_json": body.running_priorities,
        "strength_priorities_json": body.strength_priorities,
        "accepted_tradeoffs_json": body.accepted_tradeoffs,
        "notes": body.notes,
        "active": body.active,
    }
    existing = await (
        await db.execute(
            "SELECT * FROM health_training_phases WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (phase_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_training_phases",
            record_id=phase_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_training_phases",
            record_id=phase_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    await _replace_phase_goal_links(db, user=user, phase_id=phase_id, links=body.goal_links)
    row = await owned_row(db, table="health_training_phases", record_id=phase_id, user=user)
    return await _phase_response(db, user=user, row=row)


async def list_planned_sessions(db, *, user: dict) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_planned_sessions",
        user=user,
        order_by="COALESCE(scheduled_start_utc, scheduled_date, time_window_start_utc), created_at",
    )
    return [await _planned_session_response(db, user=user, row=row) for row in rows]


async def _replace_planned_session_goal_links(
    db, *, user: dict, planned_session_id: str, links
) -> None:
    timestamp = now_iso()
    await save_owned_rows_history(
        db,
        table="health_planned_session_goal_links",
        user=user,
        where="planned_session_id = ? AND deleted_at IS NULL",
        params=(planned_session_id,),
    )
    await db.execute(
        "UPDATE health_planned_session_goal_links SET deleted_at = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND planned_session_id = ? "
        "AND deleted_at IS NULL",
        (timestamp, timestamp, user["family_id"], user["id"], planned_session_id),
    )
    for link in links:
        await validate_owned_reference(
            db, table="health_goals", record_id=str(link.goal_id), user=user
        )
        await insert_owned(
            db,
            table="health_planned_session_goal_links",
            record_id=new_id(),
            values={
                "planned_session_id": planned_session_id,
                "goal_id": str(link.goal_id),
                "role": link.role,
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )


async def _planned_session_response(db, *, user: dict, row) -> dict:
    data = decoded_row(row)
    links = await (
        await db.execute(
            "SELECT goal_id, role FROM health_planned_session_goal_links "
            "WHERE family_id = ? AND owner_user_id = ? AND planned_session_id = ? "
            "AND deleted_at IS NULL ORDER BY CASE role WHEN 'primary' THEN 0 ELSE 1 END, created_at",
            (user["family_id"], user["id"], data["id"]),
        )
    ).fetchall()
    data["goal_links"] = [dict(link) for link in links]
    exercise_rows = await list_owned(
        db,
        table="health_planned_session_exercises",
        user=user,
        where="planned_session_id = ?",
        params=(data["id"],),
        order_by="sequence",
    )
    exercise_items: list[dict] = []
    for exercise_row in exercise_rows:
        item = decoded_row(exercise_row)
        substitutions = await (
            await db.execute(
                "SELECT substitute_exercise_id FROM "
                "health_planned_session_exercise_substitutions WHERE family_id = ? "
                "AND owner_user_id = ? AND planned_session_exercise_id = ? "
                "AND deleted_at IS NULL ORDER BY sequence",
                (user["family_id"], user["id"], item["id"]),
            )
        ).fetchall()
        set_rows = await list_owned(
            db,
            table="health_planned_session_sets",
            user=user,
            where="planned_session_exercise_id = ?",
            params=(item["id"],),
            order_by="sequence",
        )
        item["substitution_exercise_ids"] = [sub["substitute_exercise_id"] for sub in substitutions]
        item["planned_sets"] = [decoded_row(set_row) for set_row in set_rows]
        exercise_items.append(item)
    data["exercise_items"] = exercise_items
    gear_rows = await (
        await db.execute(
            "SELECT gear_id, role FROM health_planned_session_gear_links "
            "WHERE family_id = ? AND owner_user_id = ? AND planned_session_id = ? "
            "AND deleted_at IS NULL ORDER BY CASE role WHEN 'primary' THEN 0 "
            "WHEN 'sensor' THEN 1 ELSE 2 END, created_at",
            (user["family_id"], user["id"], data["id"]),
        )
    ).fetchall()
    data["gear_links"] = [dict(gear) for gear in gear_rows]
    data["intended_gear_ids"] = [gear["gear_id"] for gear in gear_rows]
    return data


async def _replace_planned_gear_links(
    db, *, user: dict, planned_session_id: str, gear_links, intended_gear_ids
) -> None:
    timestamp = now_iso()
    await save_owned_rows_history(
        db,
        table="health_planned_session_gear_links",
        user=user,
        where="planned_session_id = ? AND deleted_at IS NULL",
        params=(planned_session_id,),
    )
    await db.execute(
        "UPDATE health_planned_session_gear_links SET deleted_at = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND planned_session_id = ? "
        "AND deleted_at IS NULL",
        (timestamp, timestamp, user["family_id"], user["id"], planned_session_id),
    )
    combined = [(str(link.gear_id), link.role) for link in gear_links]
    linked_ids = {identifier for identifier, _ in combined}
    combined.extend(
        (str(identifier), "primary" if not combined and index == 0 else "secondary")
        for index, identifier in enumerate(intended_gear_ids)
        if str(identifier) not in linked_ids
    )
    for gear_id, role in combined:
        await validate_owned_reference(db, table="health_gear_items", record_id=gear_id, user=user)
        await insert_owned(
            db,
            table="health_planned_session_gear_links",
            record_id=new_id(),
            values={
                "planned_session_id": planned_session_id,
                "gear_id": gear_id,
                "role": role,
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )


async def _replace_planned_exercises(
    db, *, user: dict, planned_session_id: str, exercise_items
) -> None:
    from app.services.fitness.strength import resolve_exercise_id, resolve_setup_id

    timestamp = now_iso()
    existing_exercises = await (
        await db.execute(
            "SELECT id FROM health_planned_session_exercises WHERE family_id = ? "
            "AND owner_user_id = ? AND planned_session_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], planned_session_id),
        )
    ).fetchall()
    for existing in existing_exercises:
        await save_owned_rows_history(
            db,
            table="health_planned_session_sets",
            user=user,
            where="planned_session_exercise_id = ? AND deleted_at IS NULL",
            params=(existing["id"],),
        )
        await db.execute(
            "UPDATE health_planned_session_sets SET deleted_at = ?, updated_at = ? "
            "WHERE family_id = ? AND owner_user_id = ? AND planned_session_exercise_id = ? "
            "AND deleted_at IS NULL",
            (timestamp, timestamp, user["family_id"], user["id"], existing["id"]),
        )
        await save_owned_rows_history(
            db,
            table="health_planned_session_exercise_substitutions",
            user=user,
            where="planned_session_exercise_id = ? AND deleted_at IS NULL",
            params=(existing["id"],),
        )
        await db.execute(
            "UPDATE health_planned_session_exercise_substitutions "
            "SET deleted_at = ?, updated_at = ? WHERE family_id = ? AND owner_user_id = ? "
            "AND planned_session_exercise_id = ? AND deleted_at IS NULL",
            (timestamp, timestamp, user["family_id"], user["id"], existing["id"]),
        )
    await save_owned_rows_history(
        db,
        table="health_planned_session_exercises",
        user=user,
        where="planned_session_id = ? AND deleted_at IS NULL",
        params=(planned_session_id,),
    )
    await db.execute(
        "UPDATE health_planned_session_exercises SET deleted_at = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND planned_session_id = ? "
        "AND deleted_at IS NULL",
        (timestamp, timestamp, user["family_id"], user["id"], planned_session_id),
    )

    for exercise_item in exercise_items:
        exercise_id, _ = await resolve_exercise_id(
            db, user=user, exercise_id=str(exercise_item.exercise_id)
        )
        setup_id = None
        if exercise_item.exercise_setup_id:
            setup_id, _ = await resolve_setup_id(
                db, user=user, setup_id=str(exercise_item.exercise_setup_id)
            )
            setup = await owned_row(
                db,
                table="health_exercise_setups",
                record_id=setup_id,
                user=user,
            )
            setup_exercise_id, _ = await resolve_exercise_id(
                db, user=user, exercise_id=setup["exercise_id"]
            )
            if setup_exercise_id != exercise_id:
                raise FitnessConflictError("Planned exercise setup does not belong to the exercise")
        item_id = new_id(exercise_item.id)
        existing = await (
            await db.execute(
                "SELECT id FROM health_planned_session_exercises WHERE id = ? "
                "AND family_id = ? AND owner_user_id = ?",
                (item_id, user["family_id"], user["id"]),
            )
        ).fetchone()
        item_values = {
            "planned_session_id": planned_session_id,
            "exercise_id": exercise_id,
            "exercise_setup_id": setup_id,
            "sequence": exercise_item.sequence,
            "superset_group_key": exercise_item.superset_group_key,
            "notes": exercise_item.notes,
        }
        if existing is None:
            await insert_owned(
                db,
                table="health_planned_session_exercises",
                record_id=item_id,
                values=item_values,
                user=user,
                now=timestamp,
            )
        else:
            await update_owned(
                db,
                table="health_planned_session_exercises",
                record_id=item_id,
                values=item_values,
                user=user,
                now=timestamp,
                restore=True,
            )
        for sequence, substitute_id in enumerate(exercise_item.substitution_exercise_ids):
            canonical_substitute_id, _ = await resolve_exercise_id(
                db, user=user, exercise_id=str(substitute_id)
            )
            await insert_owned(
                db,
                table="health_planned_session_exercise_substitutions",
                record_id=new_id(),
                values={
                    "planned_session_exercise_id": item_id,
                    "substitute_exercise_id": canonical_substitute_id,
                    "sequence": sequence,
                    "revision": 1,
                },
                user=user,
                now=timestamp,
            )
        for planned_set in exercise_item.planned_sets:
            set_id = new_id(planned_set.id)
            existing_set = await (
                await db.execute(
                    "SELECT id FROM health_planned_session_sets WHERE id = ? "
                    "AND family_id = ? AND owner_user_id = ?",
                    (set_id, user["family_id"], user["id"]),
                )
            ).fetchone()
            set_values = {
                **planned_set.model_dump(exclude={"id"}),
                "planned_session_exercise_id": item_id,
            }
            if existing_set is None:
                await insert_owned(
                    db,
                    table="health_planned_session_sets",
                    record_id=set_id,
                    values=set_values,
                    user=user,
                    now=timestamp,
                )
            else:
                await update_owned(
                    db,
                    table="health_planned_session_sets",
                    record_id=set_id,
                    values=set_values,
                    user=user,
                    now=timestamp,
                    restore=True,
                )


async def upsert_planned_session(
    db,
    *,
    user: dict,
    body: PlannedSessionPayload,
    record_id: str | None = None,
) -> dict:
    session_id = record_id or new_id(body.id)
    values = _payload_values(
        body,
        exclude={"goal_links", "exercise_items", "gear_links", "intended_gear_ids"},
    )
    await validate_owned_reference(
        db,
        table="health_training_programmes",
        record_id=str(body.training_programme_id) if body.training_programme_id else None,
        user=user,
    )
    await validate_owned_reference(
        db,
        table="health_workout_versions",
        record_id=str(body.workout_version_id) if body.workout_version_id else None,
        user=user,
    )
    await validate_owned_reference(
        db,
        table="health_activities",
        record_id=str(body.completion_activity_id) if body.completion_activity_id else None,
        user=user,
    )
    for key in (
        "training_programme_id",
        "workout_version_id",
        "completion_activity_id",
        "scheduled_start_utc",
        "scheduled_date",
        "time_window_start_utc",
        "time_window_end_utc",
    ):
        if values.get(key) is not None:
            values[key] = (
                values[key].isoformat() if hasattr(values[key], "isoformat") else str(values[key])
            )
    existing = await (
        await db.execute(
            "SELECT * FROM health_planned_sessions WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (session_id, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_planned_sessions",
            record_id=session_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_planned_sessions",
            record_id=session_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    await _replace_planned_session_goal_links(
        db, user=user, planned_session_id=session_id, links=body.goal_links
    )
    await _replace_planned_exercises(
        db,
        user=user,
        planned_session_id=session_id,
        exercise_items=body.exercise_items,
    )
    await _replace_planned_gear_links(
        db,
        user=user,
        planned_session_id=session_id,
        gear_links=body.gear_links,
        intended_gear_ids=body.intended_gear_ids,
    )
    # A plan can be entered after Strava has already supplied the completed run.
    # Match only when sport, timing/day and duration leave exactly one candidate.
    from app.services.fitness import activities

    await activities.auto_match_plan(db, user=user, planned_session_id=session_id)
    # Provider work never runs inside this plan-write transaction. Once a run
    # has been sent, edits only mark its owner-private delivery row for the
    # bounded Intervals.icu retry worker.
    from app.services.fitness import intervals_icu

    await intervals_icu.queue_planned_session_delivery(db, user=user, planned_session_id=session_id)
    return await _planned_session_response(
        db,
        user=user,
        row=await owned_row(db, table="health_planned_sessions", record_id=session_id, user=user),
    )


def _as_utc(value: str | None) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _plan_occurs_on_local_day(
    plan: dict,
    *,
    day: date,
    zone: ZoneInfo,
    day_start_utc: datetime,
    day_end_utc: datetime,
) -> bool:
    if plan.get("scheduled_date") == day.isoformat():
        return True
    scheduled = _as_utc(plan.get("scheduled_start_utc"))
    if scheduled is not None and scheduled.astimezone(zone).date() == day:
        return True
    window_start = _as_utc(plan.get("time_window_start_utc"))
    window_end = _as_utc(plan.get("time_window_end_utc"))
    if window_start is not None and window_end is not None:
        return window_start < day_end_utc and window_end > day_start_utc
    if window_start is not None:
        return window_start.astimezone(zone).date() == day
    if window_end is not None:
        return window_end.astimezone(zone).date() == day
    return False


async def today_summary(db, *, user: dict, today: date | None = None) -> dict:
    from app.services.fitness.nutrition import (
        list_food_log,
        list_nutrition_targets,
        weight_trend,
    )
    from app.services.fitness.recovery import recovery_summary
    from app.services.fitness.strength import (
        close_expired_strength_sessions,
        get_strength_session,
    )

    settings = await ensure_settings(db, user=user)
    try:
        zone = ZoneInfo(settings["timezone"])
    except ZoneInfoNotFoundError:
        zone = ZoneInfo("Europe/London")
    day = today or datetime.now(timezone.utc).astimezone(zone).date()
    local_start = datetime.combine(day, time.min, tzinfo=zone)
    local_end = datetime.combine(day.fromordinal(day.toordinal() + 1), time.min, tzinfo=zone)
    day_start_utc = local_start.astimezone(timezone.utc)
    day_end_utc = local_end.astimezone(timezone.utc)
    goals = [goal for goal in await list_goals(db, user=user) if goal["status"] == "active"]
    phases = await list_phases(db, user=user)
    active_phase = next(
        (
            phase
            for phase in phases
            if phase["active"]
            and phase["starts_on"] <= day.isoformat()
            and (phase["ends_on"] is None or phase["ends_on"] >= day.isoformat())
        ),
        None,
    )
    plans = [
        plan
        for plan in await list_planned_sessions(db, user=user)
        if plan["status"] in {"accepted", "scheduled", "in_progress"}
        if _plan_occurs_on_local_day(
            plan,
            day=day,
            zone=zone,
            day_start_utc=day_start_utc,
            day_end_utc=day_end_utc,
        )
    ]
    activity = await (
        await db.execute(
            "SELECT * FROM health_activities WHERE family_id = ? AND owner_user_id = ? "
            "AND sport_key = 'strength' AND status = 'in_progress' AND deleted_at IS NULL "
            "ORDER BY started_at_utc DESC LIMIT 1",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if activity is not None:
        closed = await close_expired_strength_sessions(
            db,
            user=user,
            candidate_rows=[activity],
        )
        if closed:
            plans = [plan for plan in plans if plan.get("completion_activity_id") not in closed]
            activity = None
    active_strength_session = (
        await get_strength_session(db, user=user, activity_id=activity["id"]) if activity else None
    )
    primary_plan = plans[0] if plans else None
    available_window = None
    if primary_plan:
        window_start = _as_utc(primary_plan.get("time_window_start_utc"))
        window_end = _as_utc(primary_plan.get("time_window_end_utc"))
        available_window = {
            "start_utc": primary_plan.get("time_window_start_utc"),
            "end_utc": primary_plan.get("time_window_end_utc"),
            "duration_minutes": int((window_end - window_start).total_seconds() / 60)
            if window_start and window_end
            else None,
        }

    nutrition_day = await list_food_log(db, user=user, nutrition_date=day)
    targets = [
        target
        for target in await list_nutrition_targets(db, user=user, effective_on=day)
        if target["active"]
    ]
    targets_by_metric = {}
    for target in targets:
        metric_key = str(target["metric_key"])
        targets_by_metric.setdefault(metric_key, target)
        targets_by_metric.setdefault(f"nutrition.{metric_key.removeprefix('nutrition.')}", target)

    def target_position(metric_key: str, *, prefer_minimum: bool = False):
        target = targets_by_metric.get(metric_key)
        if not target:
            return None
        if target.get("target_value") is not None:
            return target["target_value"]
        if prefer_minimum and target.get("target_min") is not None:
            return target["target_min"]
        target_max = target.get("target_max")
        return target_max if target_max is not None else target.get("target_min")

    recovery_detail = await recovery_summary(
        db,
        user=user,
        from_date=day - timedelta(days=6),
        to_date=day,
    )
    latest_readiness = None
    if primary_plan:
        latest_readiness = await (
            await db.execute(
                "SELECT readiness_1_5, captured_at_utc, planned_session_id, activity_id "
                "FROM health_session_checkins WHERE family_id = ? AND owner_user_id = ? "
                "AND timing = 'pre' AND readiness_1_5 IS NOT NULL AND deleted_at IS NULL "
                "AND captured_at_utc >= ? AND captured_at_utc < ? "
                "AND (planned_session_id = ? OR (? IS NOT NULL AND activity_id = ?)) "
                "ORDER BY captured_at_utc DESC LIMIT 1",
                (
                    user["family_id"],
                    user["id"],
                    day_start_utc.isoformat(),
                    day_end_utc.isoformat(),
                    primary_plan["id"],
                    primary_plan.get("completion_activity_id"),
                    primary_plan.get("completion_activity_id"),
                ),
            )
        ).fetchone()
    recovery_warning = next(
        (
            baseline
            for baseline in recovery_detail["baselines"]
            if baseline["status"] not in {"within_baseline", "insufficient_data"}
        ),
        None,
    )
    from app.services.fitness.next_action import next_action_for_user

    next_action = await next_action_for_user(
        db,
        user=user,
        day=day,
        settings_row=settings,
        planned_sessions=plans,
        recovery_detail=recovery_detail,
        latest_readiness=latest_readiness,
    )
    next_action_data = next_action.model_dump(mode="json")
    recommendation = {
        "id": next_action.source,
        "title": next_action.title,
        "message": next_action.body,
    }
    sync_attention_rows = await (
        await db.execute(
            "SELECT id, entity_type, entity_id, message, created_at FROM health_sync_notices "
            "WHERE family_id = ? AND owner_user_id = ? AND dismissed_at IS NULL "
            "AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?) "
            "ORDER BY created_at DESC LIMIT 5",
            (user["family_id"], user["id"], now_iso()),
        )
    ).fetchall()
    weight = await weight_trend(db, user=user)
    sleep_seconds = recovery_detail["sleep"]["average_duration_s"]
    return {
        "date": day.isoformat(),
        "settings": settings,
        "active_goals": goals,
        "active_phase": active_phase,
        "planned_sessions": plans,
        "planned_session": primary_plan,
        "available_window": available_window,
        "active_strength_session": active_strength_session,
        "nutrition": {
            "calories_kcal": nutrition_day["totals"]["calories_kcal"],
            "calorie_target_kcal": target_position("nutrition.calories_kcal"),
            "protein_g": nutrition_day["totals"]["protein_g"],
            "protein_target_g": target_position("nutrition.protein_g", prefer_minimum=True),
            "nutrient_completeness": nutrition_day["nutrient_completeness"],
        },
        "weight_trend": weight,
        "recovery": {
            "sleep_hours": sleep_seconds / 3_600 if sleep_seconds is not None else None,
            "readiness": latest_readiness["readiness_1_5"] if latest_readiness else None,
            "summary": recovery_warning["label"] if recovery_warning else None,
            "detail": recovery_detail,
        },
        "next_action": next_action_data,
        "recommendation": recommendation,
        "sync_attention": [dict(row) for row in sync_attention_rows],
    }


async def progress_summary(db, *, user: dict) -> dict:
    from app.services.fitness.activities import list_activities
    from app.services.fitness.nutrition import list_body_measurements, weight_trend
    from app.services.fitness.recovery import recovery_summary
    from app.services.fitness.strength import (
        list_checkins,
        list_strength_sessions,
        muscle_group_summary,
    )

    goals = await list_goals(db, user=user)
    phases = await list_phases(db, user=user)
    sessions = await list_strength_sessions(db, user=user, limit=10)
    activities = await list_activities(db, user=user, limit=20)
    weight = await weight_trend(db, user=user)
    measurements = (await list_body_measurements(db, user=user))[:100]
    recovery = await recovery_summary(
        db,
        user=user,
        from_date=datetime.now(timezone.utc).date() - timedelta(days=27),
        to_date=datetime.now(timezone.utc).date(),
    )
    photo_rows = await (
        await db.execute(
            "SELECT id FROM health_progress_photos WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL ORDER BY captured_at DESC LIMIT 24",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    from app.services.fitness.progress_photos import progress_photo_response

    photos = [
        await progress_photo_response(db, user=user, photo_id=row["id"]) for row in photo_rows
    ]
    exercise_rows = await (
        await db.execute(
            "SELECT e.id AS exercise_id, e.name AS exercise_name, "
            "se.exercise_setup_id AS setup_id, se.exercise_setup_name_snapshot AS setup_name, "
            "MAX(a.started_at_utc) AS latest_at, "
            "MAX(s.normalized_external_load_kg) AS heaviest_observed_load_kg, "
            "COUNT(DISTINCT g.id) AS logical_set_count "
            "FROM health_strength_session_exercises se "
            "JOIN health_exercises e ON e.id = se.exercise_id AND e.family_id = se.family_id "
            "AND e.owner_user_id = se.owner_user_id "
            "JOIN health_activities a ON a.id = se.activity_id AND a.family_id = se.family_id "
            "AND a.owner_user_id = se.owner_user_id "
            "JOIN health_strength_set_groups g ON g.session_exercise_id = se.id "
            "AND g.family_id = se.family_id AND g.owner_user_id = se.owner_user_id "
            "LEFT JOIN health_strength_sets s ON s.set_group_id = g.id "
            "AND s.family_id = g.family_id AND s.owner_user_id = g.owner_user_id "
            "AND s.component_status IN ('completed','partial') AND s.deleted_at IS NULL "
            "WHERE se.family_id = ? AND se.owner_user_id = ? AND se.deleted_at IS NULL "
            "AND e.deleted_at IS NULL AND a.deleted_at IS NULL AND g.deleted_at IS NULL "
            "AND a.status IN ('completed','partial') AND g.status IN ('completed','partial') "
            "AND g.training_role IN ('working','backoff','test') "
            "GROUP BY e.id, se.exercise_setup_id, se.exercise_setup_name_snapshot "
            "ORDER BY MAX(a.started_at_utc) DESC LIMIT 30",
            (user["family_id"], user["id"]),
        )
    ).fetchall()
    today = datetime.now(timezone.utc).date().isoformat()
    active_phase = next(
        (
            phase
            for phase in phases
            if phase["active"]
            and phase["starts_on"] <= today
            and (phase["ends_on"] is None or phase["ends_on"] >= today)
        ),
        None,
    )
    return {
        "active_goals": [goal for goal in goals if goal["status"] == "active"],
        "completed_goals": [goal for goal in goals if goal["status"] == "completed"],
        "goals": goals,
        "active_phase": active_phase,
        "phase_history": phases,
        "weight": weight,
        "weight_trend": weight,
        "body_measurements": measurements,
        "recent_strength_sessions": sessions,
        "recent_sessions": sessions,
        "recent_activities": activities,
        "recent_runs": [
            activity
            for activity in activities
            if activity["sport_key"] == "running" and activity["status"] in {"completed", "partial"}
        ],
        "exercise_progress": [dict(row) for row in exercise_rows],
        "muscle_groups": await muscle_group_summary(db, user=user),
        "readiness": (await list_checkins(db, user=user))[:20],
        "recovery": recovery,
        "progress_photos": photos,
        "overall_fitness_score": None,
        "estimated_1rm_headline": None,
    }
