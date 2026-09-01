"""Immutable workout versions, reusable templates and training programmes."""

from app.models.fitness import (
    TrainingProgrammePayload,
    WorkoutDefinitionPayload,
    WorkoutVersionPayload,
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
    update_owned,
    validate_owned_reference,
)
from app.services.fitness.strength import resolve_exercise_id, resolve_setup_id


async def workout_version_response(db, *, user: dict, version_id: str) -> dict:
    data = decoded_row(
        await owned_row(
            db, table="health_workout_versions", record_id=version_id, user=user
        ),
        json_fields={"structured_summary_json"},
    )
    rows = await list_owned(
        db,
        table="health_strength_workout_exercises",
        user=user,
        where="workout_version_id = ?",
        params=(version_id,),
        order_by="sequence",
    )
    items: list[dict] = []
    for row in rows:
        item = decoded_row(row, json_fields={"substitutions_json"})
        substitutions = await (
            await db.execute(
                "SELECT substitute_exercise_id FROM "
                "health_strength_workout_exercise_substitutions WHERE family_id = ? "
                "AND owner_user_id = ? AND workout_exercise_id = ? AND deleted_at IS NULL "
                "ORDER BY sequence",
                (user["family_id"], user["id"], item["id"]),
            )
        ).fetchall()
        sets = await list_owned(
            db,
            table="health_strength_planned_sets",
            user=user,
            where="workout_exercise_id = ?",
            params=(item["id"],),
            order_by="sequence",
        )
        item.pop("substitutions", None)
        item["substitution_exercise_ids"] = [
            sub["substitute_exercise_id"] for sub in substitutions
        ]
        item["planned_sets"] = [decoded_row(planned_set) for planned_set in sets]
        items.append(item)
    data["exercise_items"] = items
    from app.services.fitness.run_plans import (
        run_cues_for_version,
        run_steps_for_version,
    )

    data["run_steps"] = await run_steps_for_version(
        db, user=user, version_id=version_id
    )
    data["run_cues"] = await run_cues_for_version(
        db, user=user, version_id=version_id
    )
    return data


async def workout_definition_response(
    db, *, user: dict, definition_id: str
) -> dict:
    data = decoded_row(
        await owned_row(
            db,
            table="health_workout_definitions",
            record_id=definition_id,
            user=user,
        )
    )
    rows = await list_owned(
        db,
        table="health_workout_versions",
        user=user,
        where="workout_definition_id = ?",
        params=(definition_id,),
        order_by="version_number DESC",
    )
    data["versions"] = [
        await workout_version_response(db, user=user, version_id=row["id"])
        for row in rows
    ]
    data["current_version"] = data["versions"][0] if data["versions"] else None
    return data


async def list_workout_definitions(
    db, *, user: dict, sport_key: str | None = None
) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_workout_definitions",
        user=user,
        where="active = 1 AND sport_key = ?" if sport_key else "active = 1",
        params=(sport_key,) if sport_key else (),
        order_by="name",
    )
    return [
        await workout_definition_response(db, user=user, definition_id=row["id"])
        for row in rows
    ]


async def upsert_workout_definition(
    db,
    *,
    user: dict,
    body: WorkoutDefinitionPayload,
    record_id: str | None = None,
) -> dict:
    identifier = record_id or new_id(body.id)
    values = body.model_dump(
        exclude={"id", "client_id", "client_timestamp", "version"}
    )
    existing = await (
        await db.execute(
            "SELECT id FROM health_workout_definitions WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_workout_definitions",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_workout_definitions",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    if body.version is not None:
        await create_workout_version(
            db,
            user=user,
            definition_id=identifier,
            body=body.version,
            sport_key=body.sport_key,
        )
    return await workout_definition_response(
        db, user=user, definition_id=identifier
    )


async def create_workout_version(
    db,
    *,
    user: dict,
    definition_id: str,
    body: WorkoutVersionPayload,
    sport_key: str | None = None,
) -> dict:
    definition = await owned_row(
        db,
        table="health_workout_definitions",
        record_id=definition_id,
        user=user,
    )
    identifier = new_id(body.id)
    existing = await (
        await db.execute(
            "SELECT workout_definition_id FROM health_workout_versions WHERE id = ? "
            "AND family_id = ? AND owner_user_id = ? AND deleted_at IS NULL",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is not None:
        if existing["workout_definition_id"] != definition_id:
            raise FitnessConflictError("Workout version identifier is already in use")
        return await workout_version_response(db, user=user, version_id=identifier)
    current = await (
        await db.execute(
            "SELECT COALESCE(MAX(version_number), 0) FROM health_workout_versions "
            "WHERE family_id = ? AND owner_user_id = ? AND workout_definition_id = ?",
            (user["family_id"], user["id"], definition_id),
        )
    ).fetchone()
    from app.services.fitness.run_plans import (
        persist_run_plan,
        planning_context_warnings,
        validate_run_steps,
    )

    run_validation = validate_run_steps(
        body.run_steps,
        body.run_cues,
        expected_distance_m=body.estimated_distance_m,
        expected_duration_s=body.estimated_duration_s,
    )
    run_validation["warnings"].extend(
        await planning_context_warnings(
            db,
            user=user,
            planned_distance_m=run_validation["total_distance_m"],
        )
        if body.run_steps
        else []
    )
    values = body.model_dump(
        exclude={
            "id",
            "client_id",
            "client_timestamp",
            "structured_summary",
            "exercise_items",
            "run_steps",
            "run_cues",
        }
    )
    values.update(
        {
            "workout_definition_id": definition_id,
            "version_number": int(current[0]) + 1,
            "sport_key": sport_key or definition["sport_key"],
            "structured_summary_json": {
                **body.structured_summary,
                **({"run_validation": run_validation} if body.run_steps else {}),
            },
            "accepted_by": user["id"] if body.accepted_at else None,
            "revision": 1,
        }
    )
    await insert_owned(
        db,
        table="health_workout_versions",
        record_id=identifier,
        values=values,
        user=user,
        client_id=body.client_id,
        client_timestamp=body.client_timestamp,
    )
    for exercise_item in body.exercise_items:
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
            setup_exercise, _ = await resolve_exercise_id(
                db, user=user, exercise_id=setup["exercise_id"]
            )
            if setup_exercise != exercise_id:
                raise FitnessConflictError(
                    "Workout setup does not belong to its exercise"
                )
        workout_exercise_id = new_id(exercise_item.id)
        await insert_owned(
            db,
            table="health_strength_workout_exercises",
            record_id=workout_exercise_id,
            values={
                "workout_version_id": identifier,
                "sequence": exercise_item.sequence,
                "exercise_id": exercise_id,
                "exercise_setup_id": setup_id,
                "superset_group_key": exercise_item.superset_group_key,
                "substitutions_json": [],
                "notes": exercise_item.notes,
                "revision": 1,
            },
            user=user,
        )
        for sequence, substitute in enumerate(
            exercise_item.substitution_exercise_ids
        ):
            substitute_id, _ = await resolve_exercise_id(
                db, user=user, exercise_id=str(substitute)
            )
            await insert_owned(
                db,
                table="health_strength_workout_exercise_substitutions",
                record_id=new_id(),
                values={
                    "workout_exercise_id": workout_exercise_id,
                    "substitute_exercise_id": substitute_id,
                    "sequence": sequence,
                    "revision": 1,
                },
                user=user,
            )
        for planned_set in exercise_item.planned_sets:
            await insert_owned(
                db,
                table="health_strength_planned_sets",
                record_id=new_id(planned_set.id),
                values={
                    **planned_set.model_dump(exclude={"id"}),
                    "workout_exercise_id": workout_exercise_id,
                    "revision": 1,
                },
                user=user,
            )
    await persist_run_plan(
        db,
        user=user,
        version_id=identifier,
        steps=body.run_steps,
        cues=body.run_cues,
    )
    await update_owned(
        db,
        table="health_workout_definitions",
        record_id=definition_id,
        values={},
        user=user,
    )
    return await workout_version_response(db, user=user, version_id=identifier)


async def copy_workout_version(
    db, *, user: dict, definition_id: str, version_id: str | None = None
) -> dict:
    definition = await workout_definition_response(
        db, user=user, definition_id=definition_id
    )
    if version_id is None:
        source = definition["current_version"]
    else:
        source = await workout_version_response(db, user=user, version_id=version_id)
        if source["workout_definition_id"] != definition_id:
            raise FitnessConflictError("Workout version does not belong to this template")
    if source is None:
        raise FitnessConflictError("Workout template has no version to copy")
    items: list[dict] = []
    for source_item in source["exercise_items"]:
        item = {
            key: value
            for key, value in source_item.items()
            if key
            in {
                "exercise_id",
                "exercise_setup_id",
                "sequence",
                "superset_group_key",
                "substitution_exercise_ids",
                "notes",
            }
        }
        item["id"] = new_id()
        item["planned_sets"] = [
            {
                **{
                    key: value
                    for key, value in planned_set.items()
                    if key
                    in {
                        "sequence",
                        "training_role",
                        "structure_type",
                        "component_count",
                        "reps_min",
                        "reps_max",
                        "load_min",
                        "load_max",
                        "load_unit",
                        "rpe_min",
                        "rpe_max",
                        "rir_min",
                        "rir_max",
                        "rest_s",
                        "is_amrap",
                        "notes",
                    }
                },
                "id": new_id(),
            }
            for planned_set in source_item["planned_sets"]
        ]
        items.append(item)

    step_id_map: dict[str, str] = {}

    def copy_steps(source_steps: list[dict]) -> list[dict]:
        copied: list[dict] = []
        for source_step in source_steps:
            copied_id = new_id()
            step_id_map[source_step["id"]] = copied_id
            copied.append(
                {
                    key: value
                    for key, value in source_step.items()
                    if key
                    in {
                        "sequence",
                        "kilometre_index",
                        "step_kind",
                        "repeat_count",
                        "duration_type",
                        "duration_value",
                        "target_type",
                        "target_low",
                        "target_high",
                        "target_unit",
                        "intensity_label",
                        "display_name",
                        "instruction_text",
                        "mental_cue_text",
                        "spoken_cue_text",
                        "allow_manual_advance",
                        "notes",
                    }
                }
                | {"id": copied_id, "children": copy_steps(source_step.get("children", []))}
            )
        return copied

    copied_steps = copy_steps(source.get("run_steps", []))
    copied_cues = [
        {
            key: value
            for key, value in cue.items()
            if key in {"sequence", "trigger_type", "trigger_value", "short_text", "spoken_text", "priority"}
        }
        | {
            "id": new_id(),
            "step_id": step_id_map.get(cue.get("step_id")),
        }
        for cue in source.get("run_cues", [])
    ]
    return {
        "workout_definition_id": definition_id,
        "workout_version_id": source["id"],
        "title": source["title"],
        "sport_key": source["sport_key"],
        "exercise_items": items,
        "run_steps": copied_steps,
        "run_cues": copied_cues,
    }


async def _replace_programme_goal_links(
    db, *, user: dict, programme_id: str, links
) -> None:
    timestamp = now_iso()
    await save_owned_rows_history(
        db,
        table="health_training_programme_goal_links",
        user=user,
        where="training_programme_id = ? AND deleted_at IS NULL",
        params=(programme_id,),
    )
    await db.execute(
        "UPDATE health_training_programme_goal_links SET deleted_at = ?, updated_at = ? "
        "WHERE family_id = ? AND owner_user_id = ? AND training_programme_id = ? "
        "AND deleted_at IS NULL",
        (timestamp, timestamp, user["family_id"], user["id"], programme_id),
    )
    for link in links:
        await validate_owned_reference(
            db, table="health_goals", record_id=str(link.goal_id), user=user
        )
        await insert_owned(
            db,
            table="health_training_programme_goal_links",
            record_id=new_id(),
            values={
                "training_programme_id": programme_id,
                "goal_id": str(link.goal_id),
                "role": link.role,
                "revision": 1,
            },
            user=user,
            now=timestamp,
        )


async def programme_response(db, *, user: dict, programme_id: str) -> dict:
    data = decoded_row(
        await owned_row(
            db,
            table="health_training_programmes",
            record_id=programme_id,
            user=user,
        )
    )
    links = await (
        await db.execute(
            "SELECT goal_id, role FROM health_training_programme_goal_links "
            "WHERE family_id = ? AND owner_user_id = ? AND training_programme_id = ? "
            "AND deleted_at IS NULL ORDER BY CASE role WHEN 'primary' THEN 0 ELSE 1 END",
            (user["family_id"], user["id"], programme_id),
        )
    ).fetchall()
    data["goal_links"] = [dict(link) for link in links]
    return data


async def list_programmes(db, *, user: dict) -> list[dict]:
    rows = await list_owned(
        db,
        table="health_training_programmes",
        user=user,
        order_by="starts_on DESC, created_at DESC",
    )
    return [
        await programme_response(db, user=user, programme_id=row["id"])
        for row in rows
    ]


async def upsert_programme(
    db,
    *,
    user: dict,
    body: TrainingProgrammePayload,
    record_id: str | None = None,
) -> dict:
    identifier = record_id or new_id(body.id)
    await validate_owned_reference(
        db,
        table="health_training_phases",
        record_id=str(body.phase_id) if body.phase_id else None,
        user=user,
    )
    values = body.model_dump(
        exclude={"id", "client_id", "client_timestamp", "goal_links"}
    )
    existing = await (
        await db.execute(
            "SELECT id FROM health_training_programmes WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (identifier, user["family_id"], user["id"]),
        )
    ).fetchone()
    if existing is None:
        await insert_owned(
            db,
            table="health_training_programmes",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_training_programmes",
            record_id=identifier,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    await _replace_programme_goal_links(
        db, user=user, programme_id=identifier, links=body.goal_links
    )
    return await programme_response(db, user=user, programme_id=identifier)
