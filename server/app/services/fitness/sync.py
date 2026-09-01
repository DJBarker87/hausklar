"""Version-gated, owner-private and atomic Fitness sync."""

import json
from datetime import datetime, timedelta, timezone

from pydantic import ValidationError

from app.models.fitness import (
    BodyIssuePayload,
    BodyMeasurementPayload,
    ExercisePayload,
    ExerciseSetupPayload,
    FitnessSyncRequest,
    FoodLogPayload,
    FoodPayload,
    FoodVersionPayload,
    GoalPayload,
    GoalRelationshipPayload,
    NutritionSettingsUpdate,
    NutritionTargetPayload,
    MealTemplatePayload,
    PlannedSessionPayload,
    RecipePayload,
    RecipeVersionPayload,
    SessionCheckinPayload,
    StrengthSessionExercisePayload,
    StrengthSessionPayload,
    StrengthSetComponentPayload,
    StrengthSetGroupPayload,
    ServingPayload,
    TrainingPhasePayload,
    TrainingProgrammePayload,
    WorkoutDefinitionPayload,
)
from app.models.fitness_recovery import (
    ProgressPhotoPayload,
    RecoveryObservationPayload,
    SleepSessionPayload,
    SourcePriorityPayload,
    SourceRecordPayload,
)
from app.models.fitness_activity import (
    ActivityContextPatch,
    ActivityGoalLinkPayload,
    ActivityGearLinkPayload,
    GearPayload,
    ManualActivityPayload,
)
from app.models.cycles import FitnessCycleSettingsPayload, FitnessPeriodStartPayload
from app.services.adoption import (
    classify_fitness_sync_mutation,
    record_completed_actions_in_db,
)
from app.services.fitness import (
    activities,
    cycles,
    nutrition,
    planning,
    progress_photos,
    recovery,
    strength,
    templates,
)
from app.services.fitness.activity_import import remove_fitness_storage_key
from app.services.fitness.common import (
    CanonicalIdentityChangedError,
    FitnessConflictError,
    FitnessNotFoundError,
    append_change,
    canonical_identity_summary,
    decoded_row,
    insert_owned,
    new_id,
    now_iso,
    owned_row,
    soft_delete_owned,
    update_owned,
    validate_owned_reference,
)

CURRENT_SYNC_PROTOCOL_VERSION = 1
SUPPORTED_SYNC_PROTOCOL_VERSIONS = [1]
MINIMUM_SUPPORTED_CLIENT_SCHEMA_VERSION = 1
CURRENT_CLIENT_SCHEMA_VERSION = 1

ENTITY_MODELS = {
    "cycle_settings": FitnessCycleSettingsPayload,
    "cycle_period_start": FitnessPeriodStartPayload,
    "source_record": SourceRecordPayload,
    "source_priority": SourcePriorityPayload,
    "nutrition_settings": NutritionSettingsUpdate,
    "goal": GoalPayload,
    "goal_relationship": GoalRelationshipPayload,
    "training_phase": TrainingPhasePayload,
    "planned_session": PlannedSessionPayload,
    "workout_definition": WorkoutDefinitionPayload,
    "training_programme": TrainingProgrammePayload,
    "food": FoodPayload,
    "food_version": FoodVersionPayload,
    "food_serving": ServingPayload,
    "food_log_entry": FoodLogPayload,
    "recipe": RecipePayload,
    "recipe_version": RecipeVersionPayload,
    "meal_template": MealTemplatePayload,
    "nutrition_target": NutritionTargetPayload,
    "body_measurement": BodyMeasurementPayload,
    "sleep_session": SleepSessionPayload,
    "recovery_observation": RecoveryObservationPayload,
    "exercise": ExercisePayload,
    "exercise_setup": ExerciseSetupPayload,
    "strength_session": StrengthSessionPayload,
    "manual_activity": ManualActivityPayload,
    "strength_session_exercise": StrengthSessionExercisePayload,
    "strength_set_group": StrengthSetGroupPayload,
    "strength_set_component": StrengthSetComponentPayload,
    "session_checkin": SessionCheckinPayload,
    "body_issue": BodyIssuePayload,
    "gear": GearPayload,
    "activity_context": ActivityContextPatch,
    "activity_gear_link": ActivityGearLinkPayload,
    "activity_goal_link": ActivityGoalLinkPayload,
    "progress_photo": ProgressPhotoPayload,
}
SUPPORTED_PAYLOAD_SCHEMA_VERSIONS = {entity: [1] for entity in ENTITY_MODELS}
ENTITY_TABLES = {
    "cycle_settings": "health_cycle_settings",
    "cycle_period_start": "health_cycle_period_starts",
    "source_record": "health_source_records",
    "source_priority": "health_source_priorities",
    "nutrition_settings": "health_user_settings",
    "goal": "health_goals",
    "goal_relationship": "health_goal_relationships",
    "training_phase": "health_training_phases",
    "planned_session": "health_planned_sessions",
    "workout_definition": "health_workout_definitions",
    "training_programme": "health_training_programmes",
    "food": "health_foods",
    "food_version": "health_food_versions",
    "food_serving": "health_food_servings",
    "food_log_entry": "health_food_log_entries",
    "recipe": "health_recipes",
    "recipe_version": "health_recipe_versions",
    "meal_template": "health_meal_templates",
    "nutrition_target": "health_nutrition_targets",
    "body_measurement": "health_body_measurements",
    "sleep_session": "health_sleep_sessions",
    "recovery_observation": "health_recovery_observations",
    "exercise": "health_exercises",
    "exercise_setup": "health_exercise_setups",
    "strength_session": "health_activities",
    "manual_activity": "health_activities",
    "strength_session_exercise": "health_strength_session_exercises",
    "strength_set_group": "health_strength_set_groups",
    "strength_set_component": "health_strength_sets",
    "session_checkin": "health_session_checkins",
    "body_issue": "health_body_issue_observations",
    "gear": "health_gear_items",
    "activity_context": "health_activities",
    "activity_gear_link": "health_activity_gear_links",
    "activity_goal_link": "health_activity_goal_links",
    "progress_photo": "health_progress_photos",
}
MUTATION_PRIORITY = {
    "cycle_settings": -3,
    "cycle_period_start": -2,
    "source_record": -10,
    "source_priority": -5,
    "nutrition_settings": 0,
    "goal": 10,
    "goal_relationship": 20,
    "food": 10,
    "food_version": 20,
    "food_serving": 20,
    "recipe": 30,
    "recipe_version": 40,
    "nutrition_target": 40,
    "meal_template": 50,
    "exercise": 10,
    "exercise_setup": 20,
    "workout_definition": 30,
    "training_phase": 30,
    "training_programme": 35,
    "planned_session": 40,
    "food_log_entry": 50,
    "body_measurement": 50,
    "sleep_session": 50,
    "recovery_observation": 50,
    "strength_session": 50,
    "manual_activity": 50,
    "strength_session_exercise": 60,
    "strength_set_group": 70,
    "strength_set_component": 80,
    "session_checkin": 90,
    "body_issue": 100,
    "gear": 15,
    "activity_context": 55,
    "activity_gear_link": 60,
    "activity_goal_link": 65,
    "progress_photo": 60,
}

CHANGE_LOG_RETENTION_DAYS = 90
REDIRECT_RETENTION_DAYS = 365
TOMBSTONE_RETENTION_DAYS = 365
MUTATION_RECEIPT_RETENTION_DAYS = 90
NOTICE_RETENTION_DAYS = 30


class PayloadUpgradeRequired(ValueError):
    def __init__(self, entity_type: str, received_version: int) -> None:
        self.entity_type = entity_type
        self.received_version = received_version
        super().__init__("payload_upgrade_required")


def capabilities() -> dict:
    return {
        "current_sync_protocol_version": CURRENT_SYNC_PROTOCOL_VERSION,
        "supported_sync_protocol_versions": SUPPORTED_SYNC_PROTOCOL_VERSIONS,
        "minimum_supported_client_schema_version": MINIMUM_SUPPORTED_CLIENT_SCHEMA_VERSION,
        "current_client_schema_version": CURRENT_CLIENT_SCHEMA_VERSION,
        "supported_payload_schema_versions_by_entity": SUPPORTED_PAYLOAD_SCHEMA_VERSIONS,
    }


def preflight_payload_versions(request: FitnessSyncRequest) -> None:
    seen: set[str] = set()
    for mutation in request.mutations:
        mutation_id = str(mutation.mutation_id)
        if mutation_id in seen:
            raise FitnessConflictError("A mutation_id may appear only once per batch")
        seen.add(mutation_id)
        versions = SUPPORTED_PAYLOAD_SCHEMA_VERSIONS.get(mutation.entity_type)
        if versions is None or mutation.payload_schema_version not in versions:
            raise PayloadUpgradeRequired(
                mutation.entity_type, mutation.payload_schema_version
            )


def decode_mutations(request: FitnessSyncRequest) -> list[tuple]:
    decoded: list[tuple] = []
    for index, mutation in enumerate(request.mutations):
        if mutation.operation == "delete":
            if mutation.payload:
                raise FitnessConflictError("Delete mutations must not contain a payload")
            decoded.append((index, mutation, None))
            continue
        model_type = ENTITY_MODELS[mutation.entity_type]
        try:
            body = model_type.model_validate(mutation.payload)
        except ValidationError as exc:
            raise FitnessConflictError(
                f"Invalid {mutation.entity_type} sync payload"
            ) from exc
        body_id = getattr(body, "id", None)
        if body_id is not None and str(body_id) != str(mutation.entity_id):
            raise FitnessConflictError("Payload id must match mutation entity_id")
        decoded.append((index, mutation, body))
    return sorted(
        decoded,
        key=lambda item: (MUTATION_PRIORITY[item[1].entity_type], item[0]),
    )


def _clean_wire(value):
    if isinstance(value, list):
        return [_clean_wire(item) for item in value]
    if not isinstance(value, dict):
        return value
    hidden = {
        "owner_user_id",
        "family_id",
        "created_by",
        "client_id",
        "client_timestamp",
        "deleted_at",
    }
    return {
        key: _clean_wire(item)
        for key, item in value.items()
        if key not in hidden
        and (not key.endswith("_json") or key in {"device_json", "metadata_json"})
    }


async def serialize_sync_entity(
    db, *, user: dict, entity_type: str, entity_id: str
) -> dict:
    if entity_type == "cycle_settings":
        row = await owned_row(
            db, table="health_cycle_settings", record_id=entity_id, user=user
        )
        data = decoded_row(row)
        for field in (
            "show_period_starts",
            "show_predicted_period",
            "show_estimated_ovulation",
            "share_period_starts_with_adults",
            "share_predicted_period_with_adults",
            "share_estimated_ovulation_with_adults",
        ):
            data[field] = bool(data[field])
    elif entity_type == "cycle_period_start":
        data = decoded_row(
            await owned_row(
                db,
                table="health_cycle_period_starts",
                record_id=entity_id,
                user=user,
            )
        )
    elif entity_type == "source_record":
        data = await recovery.source_record_response(
            db, user=user, source_id=entity_id
        )
    elif entity_type == "source_priority":
        data = decoded_row(
            await owned_row(
                db, table="health_source_priorities", record_id=entity_id, user=user
            )
        )
    elif entity_type == "nutrition_settings":
        data = decoded_row(
            await owned_row(
                db, table="health_user_settings", record_id=entity_id, user=user
            )
        )
    elif entity_type == "goal":
        data = decoded_row(
            await owned_row(db, table="health_goals", record_id=entity_id, user=user)
        )
    elif entity_type == "goal_relationship":
        data = decoded_row(
            await owned_row(
                db,
                table="health_goal_relationships",
                record_id=entity_id,
                user=user,
            )
        )
    elif entity_type == "training_phase":
        row = await owned_row(
            db, table="health_training_phases", record_id=entity_id, user=user
        )
        data = await planning._phase_response(db, user=user, row=row)
    elif entity_type == "planned_session":
        row = await owned_row(
            db, table="health_planned_sessions", record_id=entity_id, user=user
        )
        data = await planning._planned_session_response(db, user=user, row=row)
    elif entity_type == "workout_definition":
        data = await templates.workout_definition_response(
            db, user=user, definition_id=entity_id
        )
    elif entity_type == "training_programme":
        data = await templates.programme_response(
            db, user=user, programme_id=entity_id
        )
    elif entity_type == "food":
        data = await nutrition.get_food(db, user=user, food_id=entity_id)
    elif entity_type == "food_version":
        data = decoded_row(
            await owned_row(
                db, table="health_food_versions", record_id=entity_id, user=user
            ),
            json_fields={"micronutrients_json"},
        )
    elif entity_type == "food_serving":
        data = decoded_row(
            await owned_row(
                db, table="health_food_servings", record_id=entity_id, user=user
            )
        )
    elif entity_type == "food_log_entry":
        data = decoded_row(
            await owned_row(
                db, table="health_food_log_entries", record_id=entity_id, user=user
            ),
            json_fields={"micronutrients_json", "context_tags_json"},
        )
    elif entity_type == "recipe":
        data = await nutrition.get_recipe(db, user=user, recipe_id=entity_id)
    elif entity_type == "recipe_version":
        data = await nutrition._recipe_version_response(
            db,
            user=user,
            row=await owned_row(
                db, table="health_recipe_versions", record_id=entity_id, user=user
            ),
        )
    elif entity_type == "meal_template":
        data = await nutrition.get_meal_template(
            db, user=user, template_id=entity_id
        )
    elif entity_type == "nutrition_target":
        data = decoded_row(
            await owned_row(
                db, table="health_nutrition_targets", record_id=entity_id, user=user
            )
        )
    elif entity_type == "body_measurement":
        data = decoded_row(
            await owned_row(
                db, table="health_body_measurements", record_id=entity_id, user=user
            )
        )
    elif entity_type == "sleep_session":
        data = await recovery.sleep_session_response(
            db, user=user, session_id=entity_id
        )
    elif entity_type == "recovery_observation":
        data = await recovery.recovery_observation_response(
            db, user=user, observation_id=entity_id
        )
    elif entity_type == "exercise":
        data = await strength.get_exercise(db, user=user, exercise_id=entity_id)
    elif entity_type == "exercise_setup":
        data = decoded_row(
            await owned_row(
                db, table="health_exercise_setups", record_id=entity_id, user=user
            )
        )
    elif entity_type == "strength_session":
        data = await strength.get_strength_session(
            db, user=user, activity_id=entity_id
        )
    elif entity_type == "manual_activity":
        row = await owned_row(
            db, table="health_activities", record_id=entity_id, user=user
        )
        if row["parser_version"] != activities.MANUAL_ACTIVITY_PARSER_VERSION:
            raise FitnessNotFoundError("Manual activity not found")
        data = await activities.activity_summary(db, user=user, row=row)
    elif entity_type == "strength_session_exercise":
        data = decoded_row(
            await owned_row(
                db,
                table="health_strength_session_exercises",
                record_id=entity_id,
                user=user,
            )
        )
    elif entity_type == "strength_set_group":
        data = await strength.get_set_group(db, user=user, group_id=entity_id)
    elif entity_type == "strength_set_component":
        data = decoded_row(
            await owned_row(
                db, table="health_strength_sets", record_id=entity_id, user=user
            ),
            json_fields={"extra_metrics_json"},
        )
    elif entity_type == "session_checkin":
        data = decoded_row(
            await owned_row(
                db, table="health_session_checkins", record_id=entity_id, user=user
            )
        )
    elif entity_type == "body_issue":
        data = decoded_row(
            await owned_row(
                db,
                table="health_body_issue_observations",
                record_id=entity_id,
                user=user,
            )
        )
    elif entity_type == "gear":
        data = decoded_row(
            await owned_row(
                db, table="health_gear_items", record_id=entity_id, user=user
            )
        )
    elif entity_type == "activity_context":
        row = await owned_row(
            db, table="health_activities", record_id=entity_id, user=user
        )
        gear_rows = await (
            await db.execute(
                "SELECT gear_id FROM health_activity_gear_links WHERE family_id = ? "
                "AND owner_user_id = ? AND activity_id = ? AND deleted_at IS NULL "
                "ORDER BY CASE role WHEN 'primary' THEN 0 WHEN 'sensor' THEN 1 ELSE 2 END, id",
                (user["family_id"], user["id"], entity_id),
            )
        ).fetchall()
        goal_links = await activities.list_activity_goal_links(
            db, user=user, activity_id=entity_id
        )
        data = {
            "id": row["id"],
            "title": row["title"],
            "notes": row["notes"],
            "session_rpe": row["session_rpe"],
            "workout_classification": row["workout_classification"],
            "planned_session_id": row["planned_session_id"],
            "gear_ids": [item["gear_id"] for item in gear_rows],
            "goal_links": goal_links,
            "revision": row["revision"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }
    elif entity_type == "activity_gear_link":
        data = decoded_row(
            await owned_row(
                db,
                table="health_activity_gear_links",
                record_id=entity_id,
                user=user,
            )
        )
    elif entity_type == "activity_goal_link":
        data = decoded_row(
            await owned_row(
                db,
                table="health_activity_goal_links",
                record_id=entity_id,
                user=user,
            )
        )
    elif entity_type == "progress_photo":
        data = await progress_photos.progress_photo_response(
            db, user=user, photo_id=entity_id
        )
    else:
        raise FitnessConflictError("Unsupported Fitness entity")
    return _clean_wire(data)


async def _existing_entity(db, *, user: dict, entity_type: str, entity_id: str):
    return await (
        await db.execute(
            f"SELECT * FROM {ENTITY_TABLES[entity_type]} WHERE id = ? AND family_id = ? "
            "AND owner_user_id = ?",
            (entity_id, user["family_id"], user["id"]),
        )
    ).fetchone()


async def _create_notice(
    db,
    *,
    user: dict,
    entity_type: str,
    entity_id: str,
    previous_revision: int | None,
    accepted_revision: int,
    previous_values: dict | None,
    message: str,
) -> dict:
    identifier = new_id()
    timestamp = now_iso()
    expires = (datetime.now(timezone.utc) + timedelta(days=30)).isoformat()
    await insert_owned(
        db,
        table="health_sync_notices",
        record_id=identifier,
        values={
            "entity_type": entity_type,
            "entity_id": entity_id,
            "previous_revision": previous_revision,
            "accepted_revision": accepted_revision,
            "previous_values_json": previous_values,
            "message": message,
            "expires_at": expires,
            "revision": 1,
        },
        user=user,
        now=timestamp,
    )
    return await get_notice(db, user=user, notice_id=identifier)


async def get_notice(db, *, user: dict, notice_id: str) -> dict:
    return _clean_wire(
        decoded_row(
            await owned_row(
                db, table="health_sync_notices", record_id=notice_id, user=user
            ),
            json_fields={"previous_values_json"},
        )
    )


async def list_notices(db, *, user: dict) -> list[dict]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_sync_notices WHERE family_id = ? AND owner_user_id = ? "
            "AND deleted_at IS NULL AND dismissed_at IS NULL "
            "AND (expires_at IS NULL OR expires_at > ?) ORDER BY created_at DESC LIMIT 200",
            (user["family_id"], user["id"], now_iso()),
        )
    ).fetchall()
    return [
        _clean_wire(decoded_row(row, json_fields={"previous_values_json"}))
        for row in rows
    ]


async def dismiss_notice(db, *, user: dict, notice_id: str) -> dict:
    row = await owned_row(
        db, table="health_sync_notices", record_id=notice_id, user=user
    )
    timestamp = now_iso()
    await update_owned(
        db,
        table="health_sync_notices",
        record_id=notice_id,
        values={"dismissed_at": timestamp},
        user=user,
        now=timestamp,
        record_sync_change=False,
    )
    result = _clean_wire(decoded_row(row, json_fields={"previous_values_json"}))
    result["dismissed_at"] = timestamp
    return result


async def _upsert_settings(db, *, user: dict, entity_id: str, body) -> dict:
    row = await (
        await db.execute(
            "SELECT * FROM health_user_settings WHERE family_id = ? AND owner_user_id = ?",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    if row is None:
        await insert_owned(
            db,
            table="health_user_settings",
            record_id=entity_id,
            values={**body.model_dump(exclude_none=True), "revision": 1},
            user=user,
        )
        return await serialize_sync_entity(
            db, user=user, entity_type="nutrition_settings", entity_id=entity_id
        )
    if row["id"] != entity_id:
        raise FitnessConflictError("Nutrition settings identity does not match this owner")
    return await planning.update_settings(db, user=user, body=body)


async def _upsert_gear(db, *, user: dict, entity_id: str, body: GearPayload) -> dict:
    existing = await _existing_entity(
        db, user=user, entity_type="gear", entity_id=entity_id
    )
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    if body.default_for_sport_key:
        await activities._clear_default(
            db,
            user=user,
            sport_key=body.default_for_sport_key,
            except_id=entity_id,
        )
    if existing is None:
        await insert_owned(
            db,
            table="health_gear_items",
            record_id=entity_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_gear_items",
            record_id=entity_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return await serialize_sync_entity(
        db, user=user, entity_type="gear", entity_id=entity_id
    )


async def _upsert_activity_gear_link(
    db, *, user: dict, entity_id: str, body: ActivityGearLinkPayload
) -> dict:
    activity_id = str(body.activity_id)
    gear_id = str(body.gear_id)
    await validate_owned_reference(
        db, table="health_activities", record_id=activity_id, user=user
    )
    await validate_owned_reference(
        db, table="health_gear_items", record_id=gear_id, user=user
    )
    duplicate = await (
        await db.execute(
            "SELECT id FROM health_activity_gear_links WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND gear_id = ? AND role = ? "
            "AND id <> ? AND deleted_at IS NULL LIMIT 1",
            (
                user["family_id"],
                user["id"],
                activity_id,
                gear_id,
                body.role,
                entity_id,
            ),
        )
    ).fetchone()
    if duplicate is not None:
        raise FitnessConflictError("This activity gear link already exists")
    values = body.model_dump(exclude={"id", "client_id", "client_timestamp"})
    values.update({"activity_id": activity_id, "gear_id": gear_id})
    existing = await _existing_entity(
        db, user=user, entity_type="activity_gear_link", entity_id=entity_id
    )
    if existing is None:
        await insert_owned(
            db,
            table="health_activity_gear_links",
            record_id=entity_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_activity_gear_links",
            record_id=entity_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return await serialize_sync_entity(
        db, user=user, entity_type="activity_gear_link", entity_id=entity_id
    )


async def _upsert_activity_goal_link(
    db, *, user: dict, entity_id: str, body: ActivityGoalLinkPayload
) -> dict:
    activity_id = str(body.activity_id)
    goal_id = str(body.goal_id)
    await validate_owned_reference(
        db, table="health_activities", record_id=activity_id, user=user
    )
    await validate_owned_reference(
        db, table="health_goals", record_id=goal_id, user=user
    )
    existing = await _existing_entity(
        db, user=user, entity_type="activity_goal_link", entity_id=entity_id
    )
    if existing is not None and existing["role"] == "planned":
        raise FitnessConflictError("Inherited planned goal links cannot be edited")
    duplicate = await (
        await db.execute(
            "SELECT id FROM health_activity_goal_links WHERE family_id = ? "
            "AND owner_user_id = ? AND activity_id = ? AND goal_id = ? AND role = ? "
            "AND id <> ? AND deleted_at IS NULL LIMIT 1",
            (
                user["family_id"],
                user["id"],
                activity_id,
                goal_id,
                body.role,
                entity_id,
            ),
        )
    ).fetchone()
    if duplicate is not None:
        raise FitnessConflictError("This activity goal link already exists")
    values = {"activity_id": activity_id, "goal_id": goal_id, "role": body.role}
    if existing is None:
        await insert_owned(
            db,
            table="health_activity_goal_links",
            record_id=entity_id,
            values={**values, "revision": 1},
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
        )
    else:
        await update_owned(
            db,
            table="health_activity_goal_links",
            record_id=entity_id,
            values=values,
            user=user,
            client_id=body.client_id,
            client_timestamp=body.client_timestamp,
            restore=True,
        )
    return await serialize_sync_entity(
        db, user=user, entity_type="activity_goal_link", entity_id=entity_id
    )


async def _apply_upsert(
    db, *, user: dict, entity_type: str, entity_id: str, body
) -> dict:
    if entity_type == "cycle_settings":
        await cycles.upsert_cycle_settings(
            db,
            user=user,
            body=body,
            settings_id=entity_id,
        )
        return await serialize_sync_entity(
            db, user=user, entity_type=entity_type, entity_id=entity_id
        )
    if entity_type == "cycle_period_start":
        await cycles.upsert_period_start(
            db,
            user=user,
            body=body,
            period_id=entity_id,
        )
        return await serialize_sync_entity(
            db, user=user, entity_type=entity_type, entity_id=entity_id
        )
    if entity_type == "source_record":
        return await recovery.upsert_source_record(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "source_priority":
        return await recovery.upsert_source_priority(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "nutrition_settings":
        return await _upsert_settings(db, user=user, entity_id=entity_id, body=body)
    if entity_type == "goal":
        return await planning.upsert_goal(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "goal_relationship":
        return await planning.upsert_goal_relationship(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "training_phase":
        return await planning.upsert_phase(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "planned_session":
        return await planning.upsert_planned_session(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "workout_definition":
        return await templates.upsert_workout_definition(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "training_programme":
        return await templates.upsert_programme(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "food":
        return await nutrition.upsert_food(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "food_version":
        if body.food_id is None:
            raise FitnessConflictError("A synced food version requires food_id")
        return await nutrition.add_food_version(
            db,
            user=user,
            food_id=str(body.food_id),
            body=body,
            version_id=entity_id,
        )
    if entity_type == "food_serving":
        if body.food_id is None:
            raise FitnessConflictError("A synced serving requires food_id")
        return await nutrition.add_serving(
            db,
            user=user,
            food_id=str(body.food_id),
            body=body,
            serving_id=entity_id,
        )
    if entity_type == "food_log_entry":
        return await nutrition.upsert_food_log(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "recipe":
        return await nutrition.create_recipe(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "recipe_version":
        if body.recipe_id is None:
            raise FitnessConflictError("A synced recipe version requires recipe_id")
        return await nutrition.add_recipe_version(
            db,
            user=user,
            recipe_id=str(body.recipe_id),
            body=body,
            version_id=entity_id,
        )
    if entity_type == "meal_template":
        return await nutrition.create_meal_template(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "nutrition_target":
        return await nutrition.upsert_nutrition_target(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "body_measurement":
        return await nutrition.upsert_body_measurement(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "sleep_session":
        return await recovery.upsert_sleep_session(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "recovery_observation":
        return await recovery.upsert_recovery_observation(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "exercise":
        return await strength.upsert_exercise(
            db,
            user=user,
            body=body,
            record_id=entity_id,
            create_default_setup=False,
        )
    if entity_type == "exercise_setup":
        return await strength.upsert_setup(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "strength_session":
        return await strength.upsert_strength_session(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "manual_activity":
        return await activities.upsert_manual_activity(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "strength_session_exercise":
        return await strength.upsert_session_exercise(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "strength_set_group":
        return await strength.upsert_set_group(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "strength_set_component":
        return await strength.upsert_set_component(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "session_checkin":
        return await strength.upsert_checkin(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "body_issue":
        return await strength.upsert_body_issue(
            db, user=user, body=body, record_id=entity_id
        )
    if entity_type == "gear":
        return await _upsert_gear(
            db, user=user, entity_id=entity_id, body=body
        )
    if entity_type == "activity_context":
        if body.gear_ids is not None:
            raise FitnessConflictError(
                "Sync activity gear with activity_gear_link records"
            )
        result = await activities.patch_activity_context(
            db, user=user, activity_id=entity_id, body=body
        )
        row = await owned_row(
            db, table="health_activities", record_id=entity_id, user=user
        )
        await append_change(
            db,
            entity_type="activity_context",
            entity_id=entity_id,
            revision=int(row["revision"]),
            operation="upsert",
            user=user,
        )
        return result
    if entity_type == "activity_gear_link":
        return await _upsert_activity_gear_link(
            db, user=user, entity_id=entity_id, body=body
        )
    if entity_type == "activity_goal_link":
        return await _upsert_activity_goal_link(
            db, user=user, entity_id=entity_id, body=body
        )
    if entity_type == "progress_photo":
        return await progress_photos.create_progress_photo(
            db, user=user, body=body, commit=False
        )
    raise FitnessConflictError("Unsupported Fitness entity")


async def _apply_delete(
    db, *, user: dict, entity_type: str, entity_id: str
) -> tuple[int, list[tuple[str, str]]]:
    if entity_type == "nutrition_settings":
        raise FitnessConflictError("Nutrition settings cannot be deleted")
    if entity_type == "activity_context":
        raise FitnessConflictError("Activity context cannot delete its parent activity")
    if entity_type == "manual_activity":
        return (
            await activities.delete_manual_activity(
                db, user=user, activity_id=entity_id
            ),
            [],
        )
    if entity_type == "source_record":
        return (
            await recovery.delete_source_record(db, user=user, source_id=entity_id),
            [],
        )
    if entity_type == "body_measurement":
        return (
            await recovery.delete_body_measurement(
                db, user=user, measurement_id=entity_id
            ),
            [],
        )
    if entity_type == "sleep_session":
        return (
            await recovery.delete_sleep_session(
                db, user=user, session_id=entity_id
            ),
            [],
        )
    if entity_type == "recovery_observation":
        return (
            await recovery.delete_recovery_observation(
                db, user=user, observation_id=entity_id
            ),
            [],
        )
    if entity_type == "progress_photo":
        deletions = await progress_photos.delete_progress_photo(
            db, user=user, photo_id=entity_id, commit=False
        )
        row = await owned_row(
            db,
            table="health_progress_photos",
            record_id=entity_id,
            user=user,
            include_deleted=True,
        )
        return int(row["revision"]), deletions
    row = await owned_row(
        db,
        table=ENTITY_TABLES[entity_type],
        record_id=entity_id,
        user=user,
        include_deleted=True,
    )
    if entity_type == "activity_goal_link" and row["role"] == "planned":
        raise FitnessConflictError("Inherited planned goal links cannot be deleted")
    alias_column = {
        "food": "merged_into_food_id",
        "exercise": "merged_into_exercise_id",
        "exercise_setup": "merged_into_setup_id",
    }.get(entity_type)
    if alias_column and row[alias_column]:
        target_id = row[alias_column]
        raise CanonicalIdentityChangedError(
            entity_type,
            target_id,
            await canonical_identity_summary(
                db, user=user, entity_type=entity_type, target_id=target_id
            ),
        )
    if entity_type == "planned_session":
        revision = await soft_delete_owned(
            db,
            table=ENTITY_TABLES[entity_type],
            record_id=entity_id,
            user=user,
        )
        from app.services.fitness import intervals_icu

        await intervals_icu.queue_planned_session_delivery(
            db, user=user, planned_session_id=entity_id
        )
        return revision, []
    return (
        await soft_delete_owned(
            db,
            table=ENTITY_TABLES[entity_type],
            record_id=entity_id,
            user=user,
        ),
        [],
    )


async def _store_receipt(db, *, user: dict, mutation, result: dict) -> None:
    await insert_owned(
        db,
        table="health_sync_mutation_receipts",
        record_id=new_id(),
        values={
            "mutation_id": str(mutation.mutation_id),
            "entity_type": mutation.entity_type,
            "entity_id": str(mutation.entity_id),
            "result_json": result,
            "revision": 1,
        },
        user=user,
        client_id=None,
        client_timestamp=mutation.created_at_client,
    )


async def _receipt(db, *, user: dict, mutation_id: str) -> dict | None:
    row = await (
        await db.execute(
            "SELECT result_json FROM health_sync_mutation_receipts WHERE family_id = ? "
            "AND owner_user_id = ? AND mutation_id = ? AND deleted_at IS NULL",
            (user["family_id"], user["id"], mutation_id),
        )
    ).fetchone()
    return json.loads(row["result_json"]) if row is not None else None


async def _changes_since(db, *, user: dict, cursor: int) -> tuple[list[dict], list[dict], int]:
    rows = await (
        await db.execute(
            "SELECT * FROM health_change_log WHERE family_id = ? AND owner_user_id = ? "
            "AND sequence > ? AND deleted_at IS NULL ORDER BY sequence LIMIT 2000",
            (user["family_id"], user["id"], cursor),
        )
    ).fetchall()
    changes: list[dict] = []
    redirects: list[dict] = []
    next_cursor = cursor
    for row in rows:
        next_cursor = max(next_cursor, int(row["sequence"]))
        operation = row["operation"]
        if operation == "redirect":
            payload = json.loads(row["data_json"] or "{}")
            target_summary = await canonical_identity_summary(
                db,
                user=user,
                entity_type=row["entity_type"],
                target_id=payload["target_id"],
            )
            redirects.append(
                {
                    "entity_type": row["entity_type"],
                    "source_id": row["entity_id"],
                    "target_id": payload["target_id"],
                    "target_summary": target_summary,
                }
            )
            data = {**payload, "target_summary": target_summary}
        elif operation == "delete":
            data = None
        else:
            try:
                data = await serialize_sync_entity(
                    db,
                    user=user,
                    entity_type=row["entity_type"],
                    entity_id=row["entity_id"],
                )
            except FitnessNotFoundError:
                operation = "delete"
                data = None
        changes.append(
            {
                "sequence": row["sequence"],
                "entity_type": row["entity_type"],
                "entity_id": row["entity_id"],
                "revision": row["entity_revision"],
                "operation": operation,
                "data": data,
                "changed_at": row["changed_at"],
            }
        )
    return changes, redirects, next_cursor


async def _current_cursor(db, *, user: dict) -> int:
    row = await (
        await db.execute(
            "SELECT COALESCE(MAX(sequence), 0) AS cursor FROM health_change_log "
            "WHERE family_id = ? AND owner_user_id = ?",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    return int(row["cursor"] or 0)


async def cursor_requires_full_snapshot(db, *, user: dict, cursor: int) -> bool:
    state = await (
        await db.execute(
            "SELECT COALESCE(MAX(sequence), 0) AS current_cursor, "
            "COALESCE(MAX(CASE WHEN deleted_at IS NOT NULL THEN sequence END), 0) "
            "AS last_pruned_cursor FROM health_change_log WHERE family_id = ? "
            "AND owner_user_id = ?",
            (user["family_id"], user["id"]),
        )
    ).fetchone()
    current = int(state["current_cursor"] or 0)
    pruned = int(state["last_pruned_cursor"] or 0)
    return cursor > current or (pruned > 0 and cursor < pruned)


async def full_snapshot(db, *, user: dict) -> dict:
    """Return a complete current owner graph after a retained cursor expires."""
    owns_transaction = not db.in_transaction
    if owns_transaction:
        await db.execute("BEGIN IMMEDIATE")
    try:
        await planning.ensure_settings(db, user=user)
        await strength.ensure_owner_exercise_seeds(db, user=user)
        entities: list[dict] = []
        redirects: list[dict] = []
        ordered_types = sorted(
            ENTITY_MODELS,
            key=lambda entity_type: (MUTATION_PRIORITY[entity_type], entity_type),
        )
        alias_columns = {
            "food": "merged_into_food_id",
            "exercise": "merged_into_exercise_id",
            "exercise_setup": "merged_into_setup_id",
        }
        for entity_type in ordered_types:
            table = ENTITY_TABLES[entity_type]
            clauses = ["family_id = ?", "owner_user_id = ?", "deleted_at IS NULL"]
            params: list[object] = [user["family_id"], user["id"]]
            if entity_type == "strength_session":
                clauses.append("sport_key = 'strength'")
            elif entity_type == "manual_activity":
                clauses.append("parser_version = ?")
                params.append(activities.MANUAL_ACTIVITY_PARSER_VERSION)
            rows = await (
                await db.execute(
                    f"SELECT * FROM {table} WHERE {' AND '.join(clauses)} "
                    "ORDER BY created_at, id",
                    params,
                )
            ).fetchall()
            alias_column = alias_columns.get(entity_type)
            for row in rows:
                if alias_column and row[alias_column]:
                    target_id = row[alias_column]
                    redirects.append(
                        {
                            "entity_type": entity_type,
                            "source_id": row["id"],
                            "target_id": target_id,
                            "target_summary": await canonical_identity_summary(
                                db,
                                user=user,
                                entity_type=entity_type,
                                target_id=target_id,
                            ),
                        }
                    )
                    continue
                try:
                    data = await serialize_sync_entity(
                        db,
                        user=user,
                        entity_type=entity_type,
                        entity_id=row["id"],
                    )
                except FitnessNotFoundError:
                    continue
                entities.append(
                    {
                        "entity_type": entity_type,
                        "entity_id": row["id"],
                        "revision": int(row["revision"]),
                        "data": data,
                    }
                )
        response = {
            "status": "ok",
            "current_sync_protocol_version": CURRENT_SYNC_PROTOCOL_VERSION,
            "current_client_schema_version": CURRENT_CLIENT_SCHEMA_VERSION,
            "minimum_supported_client_schema_version": MINIMUM_SUPPORTED_CLIENT_SCHEMA_VERSION,
            "generated_at": now_iso(),
            "entities": entities,
            "redirects": redirects,
            "next_cursor": await _current_cursor(db, user=user),
        }
        if owns_transaction:
            await db.commit()
        return response
    except BaseException:
        if owns_transaction and db.in_transaction:
            await db.rollback()
        raise


async def cleanup_sync_state(
    db, *, reference: datetime | None = None
) -> dict[str, int]:
    """Bound operational sync state while preserving a detectable refresh gap."""
    instant = (reference or datetime.now(timezone.utc)).astimezone(timezone.utc)
    timestamp = instant.isoformat()

    async def mark_deleted(table: str, where: str, params: tuple) -> int:
        cursor = await db.execute(
            f"UPDATE {table} SET deleted_at = ?, updated_at = ?, "
            "revision = revision + 1 WHERE deleted_at IS NULL AND " + where,
            (timestamp, timestamp, *params),
        )
        return max(0, int(cursor.rowcount))

    receipt_before = (
        instant - timedelta(days=MUTATION_RECEIPT_RETENTION_DAYS)
    ).isoformat()
    notice_before = (instant - timedelta(days=NOTICE_RETENTION_DAYS)).isoformat()
    change_before = (
        instant - timedelta(days=CHANGE_LOG_RETENTION_DAYS)
    ).isoformat()
    redirect_before = (
        instant - timedelta(days=REDIRECT_RETENTION_DAYS)
    ).isoformat()
    tombstone_before = (
        instant - timedelta(days=TOMBSTONE_RETENTION_DAYS)
    ).isoformat()
    return {
        "mutation_receipts": await mark_deleted(
            "health_sync_mutation_receipts", "updated_at < ?", (receipt_before,)
        ),
        "notices": await mark_deleted(
            "health_sync_notices",
            "created_at < ? AND (dismissed_at IS NOT NULL OR expires_at < ?)",
            (notice_before, timestamp),
        ),
        "change_upserts": await mark_deleted(
            "health_change_log",
            "operation = 'upsert' AND changed_at < ?",
            (change_before,),
        ),
        "redirects": await mark_deleted(
            "health_change_log",
            "operation = 'redirect' AND changed_at < ?",
            (redirect_before,),
        ),
        "tombstones": await mark_deleted(
            "health_change_log",
            "operation = 'delete' AND changed_at < ?",
            (tombstone_before,),
        ),
    }


async def apply_sync(db, *, user: dict, request: FitnessSyncRequest) -> dict:
    preflight_payload_versions(request)
    decoded = decode_mutations(request)
    owns_transaction = not db.in_transaction
    if owns_transaction:
        await db.execute("BEGIN IMMEDIATE")
    asset_deletions: list[tuple[str, str]] = []
    try:
        await planning.ensure_settings(db, user=user)
        await strength.ensure_owner_exercise_seeds(db, user=user)
        accepted: list[dict] = []
        rejected: list[dict] = []
        acked: list[str] = []
        adoption_facts = []
        new_exercises: set[str] = set()
        for _, mutation, body in decoded:
            mutation_id = str(mutation.mutation_id)
            entity_id = str(mutation.entity_id)
            replay = await _receipt(db, user=user, mutation_id=mutation_id)
            if replay is not None:
                acked.append(mutation_id)
                (accepted if replay["status"] == "accepted" else rejected).append(
                    replay["result"]
                )
                continue
            existing = await _existing_entity(
                db,
                user=user,
                entity_type=mutation.entity_type,
                entity_id=entity_id,
            )
            previous = None
            previous_revision = int(existing["revision"]) if existing is not None else None
            stale = (
                existing is not None
                and mutation.base_revision is not None
                and mutation.base_revision != previous_revision
            )
            restoring = existing is not None and existing["deleted_at"] is not None
            if stale or restoring:
                try:
                    previous = await serialize_sync_entity(
                        db,
                        user=user,
                        entity_type=mutation.entity_type,
                        entity_id=entity_id,
                    )
                except FitnessNotFoundError:
                    previous = _clean_wire(decoded_row(existing)) if existing else None
            if mutation.entity_type == "exercise" and existing is None:
                new_exercises.add(entity_id)
            try:
                if mutation.operation == "delete":
                    revision, mutation_asset_deletions = await _apply_delete(
                        db,
                        user=user,
                        entity_type=mutation.entity_type,
                        entity_id=entity_id,
                    )
                    asset_deletions.extend(mutation_asset_deletions)
                    if (
                        mutation.entity_type == "food_version"
                        and existing is not None
                        and existing["label_asset_id"]
                    ):
                        try:
                            asset = await owned_row(
                                db,
                                table="health_file_assets",
                                record_id=existing["label_asset_id"],
                                user=user,
                            )
                        except FitnessNotFoundError:
                            asset = None
                        if asset is not None and asset["asset_kind"] == "nutrition_label":
                            await update_owned(
                                db,
                                table="health_file_assets",
                                record_id=asset["id"],
                                values={"state": "deleted", "deleted_at": now_iso()},
                                user=user,
                                record_sync_change=False,
                            )
                            asset_deletions.append(
                                (asset["storage_key"], asset["storage_class"])
                            )
                else:
                    result = await _apply_upsert(
                        db,
                        user=user,
                        entity_type=mutation.entity_type,
                        entity_id=entity_id,
                        body=body,
                    )
                    if result.get("revision") is not None:
                        revision = int(result["revision"])
                    else:
                        stored = await _existing_entity(
                            db,
                            user=user,
                            entity_type=mutation.entity_type,
                            entity_id=entity_id,
                        )
                        if stored is None:
                            raise FitnessConflictError(
                                "Synced Fitness record was not persisted"
                            )
                        revision = int(stored["revision"])
            except CanonicalIdentityChangedError as exc:
                notice = await _create_notice(
                    db,
                    user=user,
                    entity_type=mutation.entity_type,
                    entity_id=entity_id,
                    previous_revision=previous_revision,
                    accepted_revision=previous_revision or 1,
                    previous_values={
                        "attempted_fields": sorted(mutation.payload),
                        "attempted_values": mutation.payload,
                    },
                    message="This identity was merged; the attempted direct edit was not applied.",
                )
                item = {
                    "mutation_id": mutation_id,
                    "entity_id": entity_id,
                    "code": "canonical_identity_changed",
                    "target_id": exc.target_id,
                    "target_summary": exc.target_summary
                    or await canonical_identity_summary(
                        db,
                        user=user,
                        entity_type=mutation.entity_type,
                        target_id=exc.target_id,
                    ),
                    "notice_id": notice["id"],
                }
                rejected.append(item)
                acked.append(mutation_id)
                await _store_receipt(
                    db,
                    user=user,
                    mutation=mutation,
                    result={"status": "rejected", "result": item},
                )
                continue
            item = {
                "mutation_id": mutation_id,
                "entity_id": entity_id,
                "revision": revision,
            }
            accepted.append(item)
            acked.append(mutation_id)
            await _store_receipt(
                db,
                user=user,
                mutation=mutation,
                result={"status": "accepted", "result": item},
            )
            adoption_fact = classify_fitness_sync_mutation(
                entity_type=mutation.entity_type,
                operation=mutation.operation,
                existed=existing is not None and existing["deleted_at"] is None,
            )
            if adoption_fact is not None:
                adoption_facts.append(adoption_fact)
            if stale or restoring:
                await _create_notice(
                    db,
                    user=user,
                    entity_type=mutation.entity_type,
                    entity_id=entity_id,
                    previous_revision=previous_revision,
                    accepted_revision=revision,
                    previous_values=previous,
                    message=(
                        "A newer offline write restored this record."
                        if restoring
                        else "A newer offline write replaced values from another device."
                    ),
                )
        for exercise_id in new_exercises:
            setup = await (
                await db.execute(
                    "SELECT id FROM health_exercise_setups WHERE family_id = ? "
                    "AND owner_user_id = ? AND exercise_id = ? AND active = 1 "
                    "AND deleted_at IS NULL LIMIT 1",
                    (user["family_id"], user["id"], exercise_id),
                )
            ).fetchone()
            if setup is None:
                raise FitnessConflictError(
                    "A new exercise and one active owned setup must sync in the same batch"
                )
        await record_completed_actions_in_db(
            db,
            user=user,
            facts=adoption_facts,
            entry_source=request.platform,
            app_version=request.client_app_version,
        )
        snapshot_required = await cursor_requires_full_snapshot(
            db, user=user, cursor=request.cursor
        )
        if snapshot_required:
            changes: list[dict] = []
            redirects: list[dict] = []
            next_cursor = await _current_cursor(db, user=user)
        else:
            changes, redirects, next_cursor = await _changes_since(
                db, user=user, cursor=request.cursor
            )
        response = {
            "status": "full_snapshot_required" if snapshot_required else "ok",
            "current_sync_protocol_version": CURRENT_SYNC_PROTOCOL_VERSION,
            "current_client_schema_version": CURRENT_CLIENT_SCHEMA_VERSION,
            "minimum_supported_client_schema_version": MINIMUM_SUPPORTED_CLIENT_SCHEMA_VERSION,
            "accepted": accepted,
            "acked_mutation_ids": acked,
            "rejected_mutations": rejected,
            "changes": changes,
            "redirects": redirects,
            "notices": await list_notices(db, user=user),
            "next_cursor": next_cursor,
        }
        if snapshot_required:
            response.update(
                {
                    "snapshot_url": "/api/fitness/sync/snapshot",
                    "message": (
                        "This sync cursor is outside the retained history. "
                        "Accepted uploads are safe; replace local Fitness state "
                        "from the owner snapshot before advancing the cursor."
                    ),
                }
            )
        if owns_transaction:
            await db.commit()
            for storage_key, storage_class in asset_deletions:
                try:
                    await remove_fitness_storage_key(storage_key, storage_class)
                except OSError:
                    # Reconciliation identifies the now-unreferenced orphan; the
                    # committed sync result must not be replayed as a failed write.
                    pass
        return response
    except BaseException:
        if owns_transaction and db.in_transaction:
            await db.rollback()
        raise
