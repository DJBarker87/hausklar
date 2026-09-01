import Foundation
import GRDB

/// This extension is isolated to FitnessRepository's single actor. Its context
/// is never used independently of that facade, preserving call-site serialization.
extension FitnessRepository {
    func applyRemoteChange(_ change: FitnessSyncChange, db: Database) throws {
        if change.entityType == FitnessEntityType.manualActivity.rawValue {
            if change.operation == "delete" {
                try db.execute(
                    sql: "UPDATE fitness_activities SET deleted_at=?,revision=? WHERE id=?",
                    arguments: [change.changedAt, change.revision, change.entityId]
                )
                return
            }
            guard let data = change.data, let title = data.fitnessRepositoryString("title"),
                let sportKey = data.fitnessRepositoryString("sport_key"),
                let startedAt = data.fitnessRepositoryString("started_at_utc")
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_activities
                    (id,title,sport_key,started_at_utc,status,workout_classification,phase_id,
                     gear_ids_json,distance_m,duration_s,revision,server_updated_at,payload_json,
                     cached_at,deleted_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title,sport_key=excluded.sport_key,
                      started_at_utc=excluded.started_at_utc,status=excluded.status,
                      workout_classification=excluded.workout_classification,
                      phase_id=excluded.phase_id,distance_m=excluded.distance_m,
                      duration_s=excluded.duration_s,revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,
                      payload_json=excluded.payload_json,cached_at=excluded.cached_at,deleted_at=NULL
                    """,
                arguments: [
                    change.entityId, title, sportKey, startedAt, data.fitnessRepositoryString("status"),
                    data.fitnessRepositoryString("workout_classification"), data.fitnessRepositoryString("phase_id"), "[]",
                    data.fitnessRepositoryDouble("distance_m"),
                    data.fitnessRepositoryDouble("duration_s") ?? data.fitnessRepositoryDouble("timer_duration_s"),
                    change.revision, data.fitnessRepositoryString("updated_at") ?? change.changedAt,
                    try jsonString(.object(data)), change.changedAt,
                ]
            )
            return
        }
        if change.entityType == FitnessEntityType.activityContext.rawValue {
            guard change.operation != "delete", let data = change.data else { return }
            let gearJSON = try jsonString(data["gear_ids"] ?? .array([]))
            try db.execute(
                sql: """
                    UPDATE fitness_activities SET
                      title=COALESCE(?,title),workout_classification=?,gear_ids_json=?,
                      revision=?,server_updated_at=? WHERE id=?
                    """,
                arguments: [
                    data.fitnessRepositoryString("title"), data.fitnessRepositoryString("workout_classification"), gearJSON,
                    change.revision,
                    change.changedAt, change.entityId,
                ]
            )
            return
        }
        if change.entityType == FitnessEntityType.activityGearLink.rawValue {
            // Activity-context snapshots carry the authoritative ordered gear ids.
            return
        }
        if change.entityType == FitnessEntityType.gear.rawValue {
            if change.operation == "delete" {
                try db.execute(
                    sql: "UPDATE fitness_gear_items SET deleted_at=? WHERE id=?",
                    arguments: [change.changedAt, change.entityId]
                )
                return
            }
            guard let data = change.data, let name = data.fitnessRepositoryString("name"),
                let type = data.fitnessRepositoryString("gear_type_key")
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_gear_items
                    (id,gear_type_key,name,active,default_for_sport_key,revision,payload_json,cached_at,deleted_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      gear_type_key=excluded.gear_type_key,name=excluded.name,active=excluded.active,
                      default_for_sport_key=excluded.default_for_sport_key,
                      revision=excluded.revision,payload_json=excluded.payload_json,
                      cached_at=excluded.cached_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, type, name, data.fitnessRepositoryBool("active") ?? true,
                    data.fitnessRepositoryString("default_for_sport_key"), change.revision,
                    try jsonString(.object(data)), change.changedAt, data.fitnessRepositoryString("deleted_at"),
                ]
            )
            return
        }
        if change.entityType == FitnessEntityType.sourcePriority.rawValue {
            if change.operation == "delete" {
                try db.execute(
                    sql: "UPDATE fitness_source_priorities SET deleted_at=?,updated_at=? WHERE id=?",
                    arguments: [change.changedAt, change.changedAt, change.entityId]
                )
                return
            }
            guard let data = change.data,
                let metric = data.fitnessRepositoryString("metric_key"),
                let provider = data.fitnessRepositoryString("origin_provider_key"),
                let priority = data.fitnessRepositoryInt("priority")
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_source_priorities
                    (id,metric_key,origin_provider_key,transport_key,source_namespace,priority,
                     revision,updated_at,deleted_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(metric_key,origin_provider_key,transport_key,source_namespace) DO UPDATE SET
                      id=excluded.id,priority=excluded.priority,revision=excluded.revision,
                      updated_at=excluded.updated_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, metric, provider, data.fitnessRepositoryString("transport_key") ?? "",
                    data.fitnessRepositoryString("source_namespace") ?? "", priority, change.revision,
                    data.fitnessRepositoryString("updated_at") ?? change.changedAt, data.fitnessRepositoryString("deleted_at"),
                ]
            )
            return
        }
        if change.entityType == FitnessEntityType.sourceRecord.rawValue {
            if change.operation == "delete" {
                try db.execute(
                    sql: "UPDATE fitness_external_source_records SET state='deleted',updated_at=? WHERE id=?",
                    arguments: [change.changedAt, change.entityId]
                )
                return
            }
            guard let data = change.data,
                let recordKind = data.fitnessRepositoryString("record_kind"),
                let transport = data.fitnessRepositoryString("transport_key"),
                let provider = data.fitnessRepositoryString("origin_provider_key"),
                let namespace = data.fitnessRepositoryString("source_namespace"),
                let objectId = data.fitnessRepositoryString("source_object_id")
            else { return }
            let sampleType = data.fitnessRepositoryString("sample_type") ?? "external:\(recordKind)"
            let domainType = data.fitnessRepositoryString("domain_entity_type") ?? "other"
            let domainId = data.fitnessRepositoryString("domain_entity_id") ?? ""
            try db.execute(
                sql: """
                    INSERT INTO fitness_external_source_records
                    (id,record_kind,sample_type,transport_key,origin_provider_key,source_namespace,
                     source_object_id,external_object_id,source_device_identifier,source_name,product_type,
                     device_json,metadata_json,domain_entity_type,domain_entity_id,state,created_at,updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(record_kind,transport_key,source_namespace,source_object_id) DO UPDATE SET
                      sample_type=excluded.sample_type,origin_provider_key=excluded.origin_provider_key,
                      external_object_id=excluded.external_object_id,
                      source_device_identifier=excluded.source_device_identifier,
                      source_name=excluded.source_name,product_type=excluded.product_type,
                      device_json=excluded.device_json,metadata_json=excluded.metadata_json,
                      domain_entity_type=excluded.domain_entity_type,domain_entity_id=excluded.domain_entity_id,
                      state=excluded.state,updated_at=excluded.updated_at
                    """,
                arguments: [
                    change.entityId, recordKind, sampleType, transport, provider, namespace, objectId,
                    data.fitnessRepositoryString("external_object_id"), data.fitnessRepositoryString("source_device_identifier"),
                    data.fitnessRepositoryString("source_name"), data.fitnessRepositoryString("product_type"),
                    String(decoding: try context.encode(data["device_json"] ?? .object([:])), as: UTF8.self),
                    String(decoding: try context.encode(data["metadata_json"] ?? .object([:])), as: UTF8.self),
                    domainType, domainId, data.fitnessRepositoryString("state") ?? "active",
                    data.fitnessRepositoryString("created_at") ?? change.changedAt,
                    data.fitnessRepositoryString("updated_at") ?? change.changedAt,
                ]
            )
            return
        }
        let tableByEntity: [String: String] = [
            FitnessEntityType.nutritionSettings.rawValue: "fitness_nutrition_settings",
            FitnessEntityType.goal.rawValue: "fitness_goals",
            FitnessEntityType.goalRelationship.rawValue: "fitness_goal_relationships",
            FitnessEntityType.trainingPhase.rawValue: "fitness_training_phases",
            FitnessEntityType.workoutDefinition.rawValue: "fitness_workout_definitions",
            FitnessEntityType.trainingProgramme.rawValue: "fitness_training_programmes",
            FitnessEntityType.food.rawValue: "fitness_foods",
            FitnessEntityType.foodVersion.rawValue: "fitness_food_versions",
            FitnessEntityType.foodServing.rawValue: "fitness_food_servings",
            FitnessEntityType.foodLogEntry.rawValue: "fitness_food_log_entries",
            FitnessEntityType.recipe.rawValue: "fitness_recipes",
            FitnessEntityType.recipeVersion.rawValue: "fitness_recipe_versions",
            FitnessEntityType.mealTemplate.rawValue: "fitness_meal_templates",
            FitnessEntityType.nutritionTarget.rawValue: "fitness_nutrition_targets",
            FitnessEntityType.bodyMeasurement.rawValue: "fitness_body_measurements",
            FitnessEntityType.exercise.rawValue: "fitness_exercises",
            FitnessEntityType.exerciseSetup.rawValue: "fitness_exercise_setups",
            FitnessEntityType.plannedSession.rawValue: "fitness_planned_sessions",
            FitnessEntityType.strengthSession.rawValue: "fitness_strength_sessions",
            FitnessEntityType.strengthSessionExercise.rawValue: "fitness_strength_session_exercises",
            FitnessEntityType.strengthSetGroup.rawValue: "fitness_strength_set_groups",
            FitnessEntityType.strengthSetComponent.rawValue: "fitness_strength_set_components",
            FitnessEntityType.sessionCheckin.rawValue: "fitness_session_checkins",
            FitnessEntityType.bodyIssue.rawValue: "fitness_body_issues",
            FitnessEntityType.sleepSession.rawValue: "fitness_sleep_sessions",
            FitnessEntityType.recoveryObservation.rawValue: "fitness_recovery_observations",
            FitnessEntityType.progressPhoto.rawValue: "fitness_progress_photos",
            FitnessEntityType.cycleSettings.rawValue: "fitness_cycle_settings",
            FitnessEntityType.cyclePeriodStart.rawValue: "fitness_cycle_period_starts",
        ]
        guard let table = tableByEntity[change.entityType] else { return }
        if change.operation == "delete" {
            if try db.tableExists(table) {
                try db.execute(
                    sql: "UPDATE \(table) SET deleted_at = ?, revision = ? WHERE id = ?",
                    arguments: [change.changedAt, change.revision, change.entityId]
                )
            }
            return
        }
        guard let data = change.data else { return }
        let updatedAt = data.fitnessRepositoryString("updated_at") ?? change.changedAt
        switch change.entityType {
        case FitnessEntityType.nutritionSettings.rawValue:
            let minutes = data.fitnessRepositoryInt("nutrition_day_start_minutes") ?? 240
            try db.execute(
                sql: """
                    INSERT INTO fitness_nutrition_settings
                    (id, day_boundary_hour, energy_target_kcal, revision, server_updated_at,
                     client_updated_at, origin_device_id, deleted_at,timezone,
                     nutrition_day_start_minutes,payload_json,heart_rate_zone_boundaries_json)
                    VALUES (?, ?, ?, ?, ?, ?, 'server', ?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      day_boundary_hour=excluded.day_boundary_hour,
                      energy_target_kcal=excluded.energy_target_kcal,
                      timezone=excluded.timezone,
                      nutrition_day_start_minutes=excluded.nutrition_day_start_minutes,
                      revision=excluded.revision, server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at, deleted_at=excluded.deleted_at,
                      payload_json=excluded.payload_json,
                      heart_rate_zone_boundaries_json=excluded.heart_rate_zone_boundaries_json
                    """,
                arguments: [
                    change.entityId, minutes / 60, data.fitnessRepositoryDouble("energy_target_kcal"), change.revision,
                    change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"),
                    data.fitnessRepositoryString("timezone") ?? TimeZone.current.identifier, minutes,
                    try jsonString(.object(data)),
                    try data["heart_rate_zone_boundaries_bpm"].map { try jsonString($0) },
                ]
            )
        case FitnessEntityType.goal.rawValue:
            guard let name = data.fitnessRepositoryString("name"), let metric = data.fitnessRepositoryString("metric_key") else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_goals
                    (id,title,metric,target_value,unit,target_date,revision,server_updated_at,
                     client_updated_at,origin_device_id,deleted_at)
                    VALUES (?,?,?,?,?,?,?,?,?,'server',?)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title, metric=excluded.metric, target_value=excluded.target_value,
                      unit=excluded.unit, target_date=excluded.target_date, revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at, client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, name, metric, data.fitnessRepositoryDouble("target_value"), data.fitnessRepositoryString("unit_key"),
                    data.fitnessRepositoryString("target_date"), change.revision, change.changedAt, updatedAt,
                    data.fitnessRepositoryString("deleted_at"),
                ]
            )
        case FitnessEntityType.goalRelationship.rawValue:
            guard let source = data.fitnessRepositoryString("source_goal_id"),
                let target = data.fitnessRepositoryString("target_goal_id"),
                let relationship = data.fitnessRepositoryString("relationship")
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_goal_relationships
                    (id,source_goal_id,target_goal_id,relationship,notes,revision,
                     server_updated_at,client_updated_at,origin_device_id,deleted_at)
                    VALUES (?,?,?,?,?,?,?,?, 'server',?)
                    ON CONFLICT(id) DO UPDATE SET
                      source_goal_id=excluded.source_goal_id,target_goal_id=excluded.target_goal_id,
                      relationship=excluded.relationship,notes=excluded.notes,
                      revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, source, target, relationship, data.fitnessRepositoryString("notes"), change.revision,
                    change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"),
                ]
            )
        case FitnessEntityType.trainingPhase.rawValue:
            guard let name = data.fitnessRepositoryString("name"), let phaseType = data.fitnessRepositoryString("phase_type") else {
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO fitness_training_phases
                    (id,phase_type,title,starts_on,ends_on,revision,server_updated_at,
                     client_updated_at,origin_device_id,deleted_at)
                    VALUES (?,?,?,?,?,?,?,?, 'server',?)
                    ON CONFLICT(id) DO UPDATE SET
                      phase_type=excluded.phase_type,title=excluded.title,starts_on=excluded.starts_on,
                      ends_on=excluded.ends_on,revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, phaseType, name, data.fitnessRepositoryString("starts_on") ?? "",
                    data.fitnessRepositoryString("ends_on"), change.revision, change.changedAt, updatedAt,
                    data.fitnessRepositoryString("deleted_at"),
                ]
            )
            try db.execute(
                sql: "DELETE FROM fitness_training_phase_goal_links WHERE phase_id = ?",
                arguments: [change.entityId]
            )
            for link in data.fitnessRepositoryObjects("goal_links") {
                guard let goalId = link.fitnessRepositoryString("goal_id"), let role = link.fitnessRepositoryString("role") else {
                    continue
                }
                try db.execute(
                    sql: """
                        INSERT INTO fitness_training_phase_goal_links
                        (id,phase_id,goal_id,role,client_updated_at) VALUES (?,?,?,?,?)
                        """,
                    arguments: [link.fitnessRepositoryString("id") ?? UUID().uuidString, change.entityId, goalId, role, updatedAt]
                )
            }
        case FitnessEntityType.workoutDefinition.rawValue:
            try upsertRemoteWorkoutDefinition(change: change, data: data, updatedAt: updatedAt, db: db)
        case FitnessEntityType.trainingProgramme.rawValue:
            guard let name = data.fitnessRepositoryString("name"), let startsOn = data.fitnessRepositoryString("starts_on") else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_training_programmes
                    (id,name,purpose,starts_on,ends_on,status,phase_id,programme_source,revision,
                     server_updated_at,client_updated_at,origin_device_id,deleted_at,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,'server',?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      name=excluded.name,purpose=excluded.purpose,starts_on=excluded.starts_on,
                      ends_on=excluded.ends_on,status=excluded.status,phase_id=excluded.phase_id,
                      programme_source=excluded.programme_source,revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                    """,
                arguments: [
                    change.entityId, name, data.fitnessRepositoryString("purpose"), startsOn, data.fitnessRepositoryString("ends_on"),
                    data.fitnessRepositoryString("status") ?? "active", data.fitnessRepositoryString("phase_id"),
                    data.fitnessRepositoryString("programme_source") ?? "user", change.revision, change.changedAt,
                    updatedAt, data.fitnessRepositoryString("deleted_at"), try jsonString(.object(data)),
                ]
            )
            try db.execute(
                sql: "DELETE FROM fitness_training_programme_goal_links WHERE training_programme_id = ?",
                arguments: [change.entityId]
            )
            for link in data.fitnessRepositoryObjects("goal_links") {
                guard let goalId = link.fitnessRepositoryString("goal_id"), let role = link.fitnessRepositoryString("role") else {
                    continue
                }
                try db.execute(
                    sql: """
                        INSERT INTO fitness_training_programme_goal_links
                        (id,training_programme_id,goal_id,role,client_updated_at) VALUES (?,?,?,?,?)
                        """,
                    arguments: [
                        link.fitnessRepositoryString("id") ?? "\(change.entityId):\(goalId)",
                        change.entityId, goalId, role, updatedAt,
                    ]
                )
            }
        case FitnessEntityType.plannedSession.rawValue:
            guard let title = data.fitnessRepositoryString("title") else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_planned_sessions
                    (id,title,planned_for,is_completed,training_programme_id,workout_version_id,
                     revision,server_updated_at,client_updated_at,origin_device_id,deleted_at,status,
                     available_window_minutes,intended_gear,payload_json,sport_key,time_window_start_utc,
                     time_window_end_utc,expected_duration_s,intended_gear_ids_json)
                    VALUES (?,?,?,?,?,?,?,?,?,'server',?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title,planned_for=excluded.planned_for,
                      is_completed=excluded.is_completed,
                      training_programme_id=excluded.training_programme_id,
                      workout_version_id=excluded.workout_version_id,revision=excluded.revision,
                      status=excluded.status,available_window_minutes=excluded.available_window_minutes,
                      intended_gear=excluded.intended_gear,payload_json=excluded.payload_json,
                      sport_key=excluded.sport_key,time_window_start_utc=excluded.time_window_start_utc,
                      time_window_end_utc=excluded.time_window_end_utc,
                      expected_duration_s=excluded.expected_duration_s,
                      intended_gear_ids_json=excluded.intended_gear_ids_json,
                      server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, title,
                    data.fitnessRepositoryString("scheduled_start_utc") ?? data.fitnessRepositoryString("scheduled_date"),
                    data.fitnessRepositoryString("status") == "completed", data.fitnessRepositoryString("training_programme_id"),
                    data.fitnessRepositoryString("workout_version_id"), change.revision, change.changedAt, updatedAt,
                    data.fitnessRepositoryString("deleted_at"), data.fitnessRepositoryString("status") ?? "proposed",
                    data.fitnessRepositoryInt("available_window_minutes")
                        ?? data.fitnessRepositoryInt("available_window_s").map { $0 / 60 },
                    data.fitnessRepositoryString("intended_gear"), try jsonString(.object(data)),
                    data.fitnessRepositoryString("sport_key") ?? "strength", data.fitnessRepositoryString("time_window_start_utc"),
                    data.fitnessRepositoryString("time_window_end_utc"), data.fitnessRepositoryDouble("expected_duration_s"),
                    try jsonString(data["intended_gear_ids"] ?? .array([])),
                ]
            )
            if !data.fitnessRepositoryObjects("exercise_items").isEmpty {
                try db.execute(
                    sql: "DELETE FROM fitness_planned_session_exercises WHERE planned_session_id = ?", arguments: [change.entityId])
                for item in data.fitnessRepositoryObjects("exercise_items") {
                    guard let exerciseId = item.fitnessRepositoryString("exercise_id") else { continue }
                    let setupId: String?
                    if let explicitSetupId = item.fitnessRepositoryString("exercise_setup_id") {
                        setupId = explicitSetupId
                    } else {
                        setupId = try String.fetchOne(
                            db,
                            sql:
                                "SELECT id FROM fitness_exercise_setups WHERE exercise_id=? AND deleted_at IS NULL ORDER BY is_default DESC LIMIT 1",
                            arguments: [exerciseId]
                        )
                    }
                    guard let setupId else { continue }
                    try db.execute(
                        sql: """
                            INSERT INTO fitness_planned_session_exercises
                            (id,planned_session_id,exercise_id,exercise_setup_id,position,client_updated_at)
                            VALUES (?,?,?,?,?,?)
                            """,
                        arguments: [
                            item.fitnessRepositoryString("id") ?? UUID().uuidString, change.entityId, exerciseId, setupId,
                            item.fitnessRepositoryInt("sequence") ?? 0, updatedAt,
                        ]
                    )
                    let plannedExerciseId = item.fitnessRepositoryString("id") ?? ""
                    if !plannedExerciseId.isEmpty {
                        try db.execute(
                            sql: "DELETE FROM fitness_planned_sets WHERE planned_exercise_id = ?",
                            arguments: [plannedExerciseId]
                        )
                        for set in item.fitnessRepositoryObjects("planned_sets") {
                            try db.execute(
                                sql: """
                                    INSERT INTO fitness_planned_sets
                                    (id,planned_exercise_id,position,training_role,structure_type,component_count,
                                     reps_min,reps_max,load_min,load_max,load_unit,rpe_min,rpe_max,rir_min,rir_max,
                                     rest_seconds,is_amrap,notes,client_updated_at)
                                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                                    """,
                                arguments: [
                                    set.fitnessRepositoryString("id") ?? UUID().uuidString, plannedExerciseId,
                                    set.fitnessRepositoryInt("sequence") ?? 0,
                                    set.fitnessRepositoryString("training_role") ?? "working",
                                    set.fitnessRepositoryString("structure_type") ?? "straight",
                                    set.fitnessRepositoryInt("component_count") ?? 1, set.fitnessRepositoryInt("reps_min"),
                                    set.fitnessRepositoryInt("reps_max"),
                                    set.fitnessRepositoryDouble("load_min"), set.fitnessRepositoryDouble("load_max"),
                                    set.fitnessRepositoryString("load_unit"),
                                    set.fitnessRepositoryDouble("rpe_min"), set.fitnessRepositoryDouble("rpe_max"),
                                    set.fitnessRepositoryDouble("rir_min"), set.fitnessRepositoryDouble("rir_max"),
                                    set.fitnessRepositoryInt("rest_s"), set.fitnessRepositoryBool("is_amrap") ?? false,
                                    set.fitnessRepositoryString("notes"), updatedAt,
                                ]
                            )
                        }
                    }
                }
            }
        case FitnessEntityType.food.rawValue:
            try upsertRemoteFood(change: change, data: data, updatedAt: updatedAt, db: db)
        case FitnessEntityType.foodVersion.rawValue:
            try upsertRemoteFoodVersion(
                id: change.entityId, data: data, revision: change.revision,
                changedAt: change.changedAt, updatedAt: updatedAt, foodId: data.fitnessRepositoryString("food_id"), db: db
            )
        case FitnessEntityType.foodServing.rawValue:
            try upsertRemoteFoodServing(
                id: change.entityId, data: data, revision: change.revision,
                changedAt: change.changedAt, updatedAt: updatedAt, db: db
            )
        case FitnessEntityType.recipe.rawValue:
            try upsertRemoteRecipe(change: change, data: data, updatedAt: updatedAt, db: db)
        case FitnessEntityType.recipeVersion.rawValue:
            try upsertRemoteRecipeVersion(
                id: change.entityId, data: data, revision: change.revision,
                changedAt: change.changedAt, updatedAt: updatedAt, recipeId: data.fitnessRepositoryString("recipe_id"), db: db
            )
        case FitnessEntityType.mealTemplate.rawValue:
            try upsertRemoteMealTemplate(change: change, data: data, updatedAt: updatedAt, db: db)
        case FitnessEntityType.nutritionTarget.rawValue:
            try upsertRemoteNutritionTarget(change: change, data: data, updatedAt: updatedAt, db: db)
        case FitnessEntityType.foodLogEntry.rawValue:
            guard let loggedAt = data.fitnessRepositoryString("logged_at_utc") else { return }
            let versionId = data.fitnessRepositoryString("food_version_id")
            let recipeVersionId = data.fitnessRepositoryString("recipe_version_id")
            let foodRow: Row?
            if let versionId {
                foodRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT f.id AS food_id,f.name AS item_name
                        FROM fitness_food_versions v JOIN fitness_foods f ON f.id=v.food_id WHERE v.id=?
                        """,
                    arguments: [versionId]
                )
            } else if let recipeVersionId {
                foodRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT NULL AS food_id,r.name AS item_name
                        FROM fitness_recipe_versions v JOIN fitness_recipes r ON r.id=v.recipe_id WHERE v.id=?
                        """,
                    arguments: [recipeVersionId]
                )
            } else {
                return
            }
            let foodId: String? = foodRow?["food_id"]
            let foodName: String = foodRow?["item_name"] ?? "Saved item"
            let canonicalAmount = data.fitnessRepositoryDouble("canonical_amount")
            let grams = data.fitnessRepositoryString("canonical_unit") == "g" ? canonicalAmount : nil
            try db.execute(
                sql: """
                    INSERT INTO fitness_food_log_entries
                    (id,food_id,food_version_id,food_name,logged_at,nutrition_date,meal,
                     amount_grams,kcal,revision,server_updated_at,client_updated_at,origin_device_id,deleted_at,
                     recipe_version_id,local_timezone,meal_key,entered_amount,entered_unit,
                     canonical_amount,canonical_unit,calories_kcal,protein_g,carbohydrate_g,sugars_g,
                     fat_g,saturated_fat_g,fibre_g,salt_g,sodium_mg,micronutrients_json,
                     measurement_quality,notes,context_tags_json,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?, 'server',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      food_id=excluded.food_id,food_version_id=excluded.food_version_id,
                      recipe_version_id=excluded.recipe_version_id,
                      food_name=excluded.food_name,logged_at=excluded.logged_at,
                      nutrition_date=excluded.nutrition_date,meal=excluded.meal,meal_key=excluded.meal_key,
                      amount_grams=excluded.amount_grams,kcal=excluded.kcal,
                      local_timezone=excluded.local_timezone,entered_amount=excluded.entered_amount,
                      entered_unit=excluded.entered_unit,canonical_amount=excluded.canonical_amount,
                      canonical_unit=excluded.canonical_unit,calories_kcal=excluded.calories_kcal,
                      protein_g=excluded.protein_g,carbohydrate_g=excluded.carbohydrate_g,
                      sugars_g=excluded.sugars_g,fat_g=excluded.fat_g,
                      saturated_fat_g=excluded.saturated_fat_g,fibre_g=excluded.fibre_g,
                      salt_g=excluded.salt_g,sodium_mg=excluded.sodium_mg,
                      micronutrients_json=excluded.micronutrients_json,
                      measurement_quality=excluded.measurement_quality,notes=excluded.notes,
                      context_tags_json=excluded.context_tags_json,payload_json=excluded.payload_json,
                      revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, foodId, versionId, foodName, loggedAt,
                    data.fitnessRepositoryString("nutrition_date")
                        ?? FitnessCalculations.nutritionDate(for: FitnessDatabase.date(loggedAt) ?? Date()),
                    data.fitnessRepositoryString("meal_key") ?? "snack", grams, data.fitnessRepositoryDouble("calories_kcal"),
                    change.revision, change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"),
                    recipeVersionId, data.fitnessRepositoryString("local_timezone") ?? "UTC",
                    data.fitnessRepositoryString("meal_key") ?? "snack",
                    data.fitnessRepositoryDouble("entered_amount") ?? canonicalAmount,
                    data.fitnessRepositoryString("entered_unit") ?? data.fitnessRepositoryString("canonical_unit") ?? "serving",
                    canonicalAmount, data.fitnessRepositoryString("canonical_unit") ?? "serving",
                    data.fitnessRepositoryDouble("calories_kcal"),
                    data.fitnessRepositoryDouble("protein_g"), data.fitnessRepositoryDouble("carbohydrate_g"),
                    data.fitnessRepositoryDouble("sugars_g"),
                    data.fitnessRepositoryDouble("fat_g"), data.fitnessRepositoryDouble("saturated_fat_g"),
                    data.fitnessRepositoryDouble("fibre_g"),
                    data.fitnessRepositoryDouble("salt_g"), data.fitnessRepositoryDouble("sodium_mg"),
                    try jsonString(data["micronutrients"] ?? data["micronutrients_json"] ?? .object([:])),
                    data.fitnessRepositoryString("measurement_quality") ?? "estimated", data.fitnessRepositoryString("notes"),
                    try jsonString(data["context_tags"] ?? data["context_tags_json"] ?? .array([])),
                    try jsonString(.object(data)),
                ]
            )
        case FitnessEntityType.bodyMeasurement.rawValue:
            guard let metricKey = data.fitnessRepositoryString("metric_key"),
                metricKey.hasPrefix("body."),
                let measuredAt = data.fitnessRepositoryString("measured_at_utc"),
                let value = data.fitnessRepositoryDouble("value")
            else { return }
            let sourceId = data.fitnessRepositoryString("source_record_id")
            let source: Row?
            if let sourceId {
                source = try Row.fetchOne(
                    db, sql: "SELECT * FROM fitness_external_source_records WHERE id=?", arguments: [sourceId]
                )
            } else {
                source = nil
            }
            try db.execute(
                sql: """
                    INSERT INTO fitness_body_measurements
                    (id,measured_at,weight_kg,source,source_identifier,is_canonical,revision,
                     server_updated_at,client_updated_at,origin_device_id,deleted_at,source_record_id,
                     canonical_state,duplicate_of_measurement_id,origin_provider_key,transport_key,
                     source_namespace,external_object_id,measurement_quality,metric_key,value_number,
                     unit_key,notes,manual_canonical_override)
                    VALUES (?,?,?,?,?,?,?, ?,?,'server',?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      measured_at=excluded.measured_at,weight_kg=excluded.weight_kg,
                      is_canonical=excluded.is_canonical,revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at,source_record_id=excluded.source_record_id,
                      canonical_state=excluded.canonical_state,
                      duplicate_of_measurement_id=excluded.duplicate_of_measurement_id,
                      origin_provider_key=excluded.origin_provider_key,transport_key=excluded.transport_key,
                      source_namespace=excluded.source_namespace,external_object_id=excluded.external_object_id,
                      measurement_quality=excluded.measurement_quality,
                      metric_key=excluded.metric_key,value_number=excluded.value_number,
                      unit_key=excluded.unit_key,notes=excluded.notes,
                      manual_canonical_override=excluded.manual_canonical_override
                    """,
                arguments: [
                    change.entityId, measuredAt, value, sourceId == nil ? "manual" : "imported", sourceId,
                    data.fitnessRepositoryString("canonical_state") == "canonical", change.revision,
                    change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"), sourceId,
                    data.fitnessRepositoryString("canonical_state") ?? "canonical",
                    data.fitnessRepositoryString("duplicate_of_measurement_id"),
                    source?["origin_provider_key"], source?["transport_key"], source?["source_namespace"],
                    source?["external_object_id"], data.fitnessRepositoryString("measurement_quality") ?? "measured",
                    metricKey, value, data.fitnessRepositoryString("unit_key") ?? "unit", data.fitnessRepositoryString("notes"),
                    data.fitnessRepositoryBool("manual_canonical_override") ?? false,
                ]
            )
        case FitnessEntityType.sleepSession.rawValue:
            guard let start = data.fitnessRepositoryString("sleep_start_utc"),
                let end = data.fitnessRepositoryString("sleep_end_utc"),
                let duration = data.fitnessRepositoryDouble("duration_s")
            else { return }
            var payload = data
            payload["id"] = .string(change.entityId)
            try db.execute(
                sql: """
                    INSERT INTO fitness_sleep_sessions
                    (id,sleep_start_utc,sleep_end_utc,duration_s,awake_duration_s,source_quality,
                     source_stages_json,source_record_id,notes,revision,client_updated_at,deleted_at,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      sleep_start_utc=excluded.sleep_start_utc,sleep_end_utc=excluded.sleep_end_utc,
                      duration_s=excluded.duration_s,awake_duration_s=excluded.awake_duration_s,
                      source_quality=excluded.source_quality,source_stages_json=excluded.source_stages_json,
                      source_record_id=excluded.source_record_id,notes=excluded.notes,
                      revision=excluded.revision,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                    """,
                arguments: [
                    change.entityId, start, end, duration, data.fitnessRepositoryDouble("awake_duration_s"),
                    data.fitnessRepositoryString("source_quality"),
                    String(decoding: try context.encode(data["source_stages"] ?? .array([])), as: UTF8.self),
                    data.fitnessRepositoryString("source_record_id"), data.fitnessRepositoryString("notes"), change.revision, updatedAt,
                    data.fitnessRepositoryString("deleted_at"), String(decoding: try context.encode(payload), as: UTF8.self),
                ]
            )
        case FitnessEntityType.recoveryObservation.rawValue:
            guard let metric = data.fitnessRepositoryString("metric_key"), let observed = data.fitnessRepositoryString("observed_at_utc")
            else { return }
            var payload = data
            payload["id"] = .string(change.entityId)
            try db.execute(
                sql: """
                    INSERT INTO fitness_recovery_observations
                    (id,metric_key,observed_at_utc,value_number,value_text,unit_key,source_quality,
                     source_record_id,notes,revision,client_updated_at,deleted_at,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      metric_key=excluded.metric_key,observed_at_utc=excluded.observed_at_utc,
                      value_number=excluded.value_number,value_text=excluded.value_text,
                      unit_key=excluded.unit_key,source_quality=excluded.source_quality,
                      source_record_id=excluded.source_record_id,notes=excluded.notes,
                      revision=excluded.revision,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                    """,
                arguments: [
                    change.entityId, metric, observed, data.fitnessRepositoryDouble("value_number"),
                    data.fitnessRepositoryString("value_text"),
                    data.fitnessRepositoryString("unit_key"), data.fitnessRepositoryString("source_quality"),
                    data.fitnessRepositoryString("source_record_id"),
                    data.fitnessRepositoryString("notes"), change.revision, updatedAt, data.fitnessRepositoryString("deleted_at"),
                    String(decoding: try context.encode(payload), as: UTF8.self),
                ]
            )
        case FitnessEntityType.progressPhoto.rawValue:
            guard let captured = data.fitnessRepositoryString("captured_at"), let pose = data.fitnessRepositoryString("pose"),
                let assetId = data.fitnessRepositoryString("original_asset_id")
            else { return }
            var payload = data
            payload["id"] = .string(change.entityId)
            try db.execute(
                sql: """
                    INSERT INTO fitness_progress_photos
                    (id,captured_at,pose,body_weight_kg,phase_id,phase_name,original_asset_id,
                     thumbnail_asset_id,original_state,thumbnail_state,notes,metadata_acknowledged,
                     revision,client_updated_at,deleted_at,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      captured_at=excluded.captured_at,pose=excluded.pose,body_weight_kg=excluded.body_weight_kg,
                      phase_id=excluded.phase_id,phase_name=excluded.phase_name,
                      original_asset_id=excluded.original_asset_id,thumbnail_asset_id=excluded.thumbnail_asset_id,
                      original_state=excluded.original_state,thumbnail_state=excluded.thumbnail_state,
                      notes=excluded.notes,metadata_acknowledged=excluded.metadata_acknowledged,
                      revision=excluded.revision,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                    """,
                arguments: [
                    change.entityId, captured, pose, data.fitnessRepositoryDouble("body_weight_kg"),
                    data.fitnessRepositoryString("phase_id"),
                    data.fitnessRepositoryString("phase_name"), assetId, data.fitnessRepositoryString("thumbnail_asset_id"),
                    data.fitnessRepositoryString("original_state") ?? "ready", data.fitnessRepositoryString("thumbnail_state"),
                    data.fitnessRepositoryString("notes"),
                    data.fitnessRepositoryBool("metadata_acknowledged") ?? true, change.revision, updatedAt,
                    data.fitnessRepositoryString("deleted_at"),
                    String(decoding: try context.encode(payload), as: UTF8.self),
                ]
            )
        case FitnessEntityType.exercise.rawValue:
            try upsertRemoteExercise(change: change, data: data, updatedAt: updatedAt, db: db)
        case FitnessEntityType.exerciseSetup.rawValue:
            try upsertRemoteSetup(change: change, data: data, updatedAt: updatedAt, db: db)
        case FitnessEntityType.strengthSession.rawValue:
            guard let title = data.fitnessRepositoryString("title"), let startedAt = data.fitnessRepositoryString("started_at_utc") else {
                return
            }
            let serverStatus = data.fitnessRepositoryString("status") ?? "in_progress"
            let localStatus = serverStatus == "in_progress" ? "active" : (serverStatus == "aborted" ? "abandoned" : "completed")
            if localStatus == "active" {
                try db.execute(
                    sql: "UPDATE fitness_strength_sessions SET status='abandoned' WHERE status='active' AND id<>?",
                    arguments: [change.entityId]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO fitness_strength_sessions
                    (id,title,status,started_at,ended_at,planned_session_id,readiness,session_rpe,
                     performance,note,revision,server_updated_at,client_updated_at,origin_device_id,deleted_at,
                     local_timezone,rest_timer_deadline_utc,matched_plan_key,payload_json)
                    VALUES (?,?,?,?,?,?,NULL,?,?,?,?,?,?,'server',?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title,status=excluded.status,started_at=excluded.started_at,
                      ended_at=excluded.ended_at,planned_session_id=excluded.planned_session_id,
                      session_rpe=excluded.session_rpe,performance=excluded.performance,note=excluded.note,
                      local_timezone=excluded.local_timezone,
                      rest_timer_deadline_utc=excluded.rest_timer_deadline_utc,
                      matched_plan_key=excluded.matched_plan_key,payload_json=excluded.payload_json,
                      revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, title, localStatus, startedAt, data.fitnessRepositoryString("ended_at_utc"),
                    data.fitnessRepositoryString("planned_session_id"), data.fitnessRepositoryDouble("session_rpe"),
                    data.fitnessRepositoryInt("perceived_performance"), data.fitnessRepositoryString("notes"), change.revision,
                    change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"),
                    data.fitnessRepositoryString("local_timezone") ?? "UTC", data.fitnessRepositoryString("rest_timer_deadline_utc"),
                    data.fitnessRepositoryString("matched_plan_key"), try jsonString(.object(data)),
                ]
            )
        case FitnessEntityType.strengthSessionExercise.rawValue:
            guard let sessionId = data.fitnessRepositoryString("activity_id"), let exerciseId = data.fitnessRepositoryString("exercise_id"),
                let setupId = data.fitnessRepositoryString("exercise_setup_id"),
                let exerciseName = try String.fetchOne(db, sql: "SELECT name FROM fitness_exercises WHERE id=?", arguments: [exerciseId]),
                let setupName = try String.fetchOne(db, sql: "SELECT name FROM fitness_exercise_setups WHERE id=?", arguments: [setupId])
            else { return }
            let storedSetupMode = try String.fetchOne(
                db, sql: "SELECT load_mode FROM fitness_exercise_setups WHERE id=?", arguments: [setupId]
            )
            let storedUnilateralMode = try String.fetchOne(
                db, sql: "SELECT unilateral_mode FROM fitness_exercise_setups WHERE id=?", arguments: [setupId]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_strength_session_exercises
                    (id,session_id,exercise_id,exercise_name,setup_id,setup_name,position,revision,
                     server_updated_at,client_updated_at,origin_device_id,deleted_at,planned_exercise_id,
                     setup_load_entry_mode_snapshot,rep_count_mode_snapshot,superset_group_key,
                     unilateral_mode_snapshot,variation_note,notes,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,'server',?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      session_id=excluded.session_id,exercise_id=excluded.exercise_id,
                      exercise_name=excluded.exercise_name,setup_id=excluded.setup_id,setup_name=excluded.setup_name,
                      planned_exercise_id=excluded.planned_exercise_id,
                      setup_load_entry_mode_snapshot=excluded.setup_load_entry_mode_snapshot,
                      rep_count_mode_snapshot=excluded.rep_count_mode_snapshot,
                      unilateral_mode_snapshot=excluded.unilateral_mode_snapshot,
                      superset_group_key=excluded.superset_group_key,variation_note=excluded.variation_note,
                      notes=excluded.notes,payload_json=excluded.payload_json,
                      position=excluded.position,revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                      deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, sessionId, exerciseId, exerciseName, setupId,
                    data.fitnessRepositoryString("exercise_setup_label_snapshot") ?? setupName,
                    data.fitnessRepositoryInt("sequence") ?? 0, change.revision, change.changedAt, updatedAt,
                    data.fitnessRepositoryString("deleted_at"),
                    data.fitnessRepositoryString("planned_exercise_id"),
                    data.fitnessRepositoryString("exercise_setup_load_entry_mode_snapshot")
                        ?? Self.serverLoadMode(Self.localLoadMode(storedSetupMode)),
                    data.fitnessRepositoryString("rep_count_mode_snapshot") ?? "total", data.fitnessRepositoryString("superset_group_key"),
                    data.fitnessRepositoryString("unilateral_mode_snapshot") ?? storedUnilateralMode ?? "bilateral",
                    data.fitnessRepositoryString("variation_note"), data.fitnessRepositoryString("notes"), try jsonString(.object(data)),
                ]
            )
        case FitnessEntityType.strengthSetGroup.rawValue:
            guard let sessionExerciseId = data.fitnessRepositoryString("session_exercise_id") else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_strength_set_groups
                    (id,session_exercise_id,role,structure_type,is_amrap,failure_state,status,position,
                     revision,server_updated_at,client_updated_at,origin_device_id,deleted_at,planned_set_id,
                     started_at_utc,completed_at_utc,notes,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,'server',?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      session_exercise_id=excluded.session_exercise_id,role=excluded.role,
                      structure_type=excluded.structure_type,is_amrap=excluded.is_amrap,
                      failure_state=excluded.failure_state,status=excluded.status,position=excluded.position,
                      planned_set_id=excluded.planned_set_id,started_at_utc=excluded.started_at_utc,
                      completed_at_utc=excluded.completed_at_utc,notes=excluded.notes,
                      payload_json=excluded.payload_json,
                      revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, sessionExerciseId, data.fitnessRepositoryString("training_role") ?? "other",
                    data.fitnessRepositoryString("structure_type") ?? "other", data.fitnessRepositoryBool("is_amrap") ?? false,
                    data.fitnessRepositoryString("failure_state") ?? "unknown", data.fitnessRepositoryString("status") ?? "completed",
                    data.fitnessRepositoryInt("sequence") ?? 0, change.revision, change.changedAt, updatedAt,
                    data.fitnessRepositoryString("deleted_at"),
                    data.fitnessRepositoryString("planned_set_id"), data.fitnessRepositoryString("started_at_utc"),
                    data.fitnessRepositoryString("completed_at_utc"),
                    data.fitnessRepositoryString("notes"), try jsonString(.object(data)),
                ]
            )
        case FitnessEntityType.strengthSetComponent.rawValue:
            guard let groupId = data.fitnessRepositoryString("set_group_id") else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_strength_set_components
                    (id,group_id,status,load_kg,reps,duration_seconds,distance_metres,rir,rpe,
                     completed_at,position,revision,server_updated_at,client_updated_at,origin_device_id,deleted_at,
                     reps_left,reps_right,load_value,load_unit,load_entry_mode_snapshot,
                     normalized_external_load_kg,added_load_kg,assistance_kg,bodyweight_kg_snapshot,
                     rest_before_s,tempo_text,notes,extra_metrics_json,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,'server',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      group_id=excluded.group_id,status=excluded.status,load_kg=excluded.load_kg,
                      reps=excluded.reps,duration_seconds=excluded.duration_seconds,
                      distance_metres=excluded.distance_metres,rir=excluded.rir,rpe=excluded.rpe,
                      reps_left=excluded.reps_left,reps_right=excluded.reps_right,
                      load_value=excluded.load_value,load_unit=excluded.load_unit,
                      load_entry_mode_snapshot=excluded.load_entry_mode_snapshot,
                      normalized_external_load_kg=excluded.normalized_external_load_kg,
                      added_load_kg=excluded.added_load_kg,assistance_kg=excluded.assistance_kg,
                      bodyweight_kg_snapshot=excluded.bodyweight_kg_snapshot,
                      rest_before_s=excluded.rest_before_s,tempo_text=excluded.tempo_text,
                      notes=excluded.notes,extra_metrics_json=excluded.extra_metrics_json,
                      payload_json=excluded.payload_json,
                      completed_at=excluded.completed_at,position=excluded.position,
                      revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, groupId, data.fitnessRepositoryString("component_status") ?? "completed",
                    data.fitnessRepositoryDouble("normalized_external_load_kg") ?? data.fitnessRepositoryDouble("load_value"),
                    data.fitnessRepositoryInt("reps"),
                    data.fitnessRepositoryInt("duration_s"), data.fitnessRepositoryDouble("distance_m"),
                    data.fitnessRepositoryDouble("rir"), data.fitnessRepositoryDouble("rpe"),
                    data.fitnessRepositoryString("completed_at_utc"), data.fitnessRepositoryInt("component_index") ?? 0, change.revision,
                    change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"), data.fitnessRepositoryInt("reps_left"),
                    data.fitnessRepositoryInt("reps_right"),
                    data.fitnessRepositoryDouble("load_value"), data.fitnessRepositoryString("load_unit"),
                    data.fitnessRepositoryString("load_entry_mode_snapshot"),
                    data.fitnessRepositoryDouble("normalized_external_load_kg"), data.fitnessRepositoryDouble("added_load_kg"),
                    data.fitnessRepositoryDouble("assistance_kg"), data.fitnessRepositoryDouble("bodyweight_kg_snapshot"),
                    data.fitnessRepositoryInt("rest_before_s"), data.fitnessRepositoryString("tempo_text"),
                    data.fitnessRepositoryString("notes"),
                    try jsonString(data["extra_metrics"] ?? .object([:])), try jsonString(.object(data)),
                ]
            )
        case FitnessEntityType.sessionCheckin.rawValue:
            guard let sessionId = data.fitnessRepositoryString("activity_id"),
                let capturedAt = data.fitnessRepositoryString("captured_at_utc")
            else { return }
            let readiness = data.fitnessRepositoryInt("readiness_1_5")
            try db.execute(
                sql: """
                    INSERT INTO fitness_session_checkins
                    (id,session_id,kind,value,note,recorded_at,retrospective,revision,
                     server_updated_at,client_updated_at,origin_device_id,deleted_at,planned_session_id,
                     timing,captured_before_activity_start,energy_1_5,soreness_1_5,motivation_1_5,
                     session_rpe_1_10,perceived_performance_1_5,matched_plan_key,payload_json)
                    VALUES (?,?,'readiness',?,?,?,?,?,?,?,'server',?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      session_id=excluded.session_id,value=excluded.value,note=excluded.note,
                      recorded_at=excluded.recorded_at,retrospective=excluded.retrospective,
                      planned_session_id=excluded.planned_session_id,timing=excluded.timing,
                      captured_before_activity_start=excluded.captured_before_activity_start,
                      energy_1_5=excluded.energy_1_5,soreness_1_5=excluded.soreness_1_5,
                      motivation_1_5=excluded.motivation_1_5,session_rpe_1_10=excluded.session_rpe_1_10,
                      perceived_performance_1_5=excluded.perceived_performance_1_5,
                      matched_plan_key=excluded.matched_plan_key,payload_json=excluded.payload_json,
                      revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, sessionId, readiness, data.fitnessRepositoryString("notes"), capturedAt,
                    data.fitnessRepositoryString("capture_quality") == "retrospective", change.revision,
                    change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"),
                    data.fitnessRepositoryString("planned_session_id"),
                    data.fitnessRepositoryString("timing") ?? "pre", data.fitnessRepositoryBool("captured_before_activity_start"),
                    data.fitnessRepositoryInt("energy_1_5"), data.fitnessRepositoryInt("soreness_1_5"),
                    data.fitnessRepositoryInt("motivation_1_5"),
                    data.fitnessRepositoryDouble("session_rpe_1_10"), data.fitnessRepositoryInt("perceived_performance_1_5"),
                    data.fitnessRepositoryString("matched_plan_key"), try jsonString(.object(data)),
                ]
            )
            if let readiness {
                try db.execute(sql: "UPDATE fitness_strength_sessions SET readiness=? WHERE id=?", arguments: [readiness, sessionId])
            }
        case FitnessEntityType.bodyIssue.rawValue:
            guard let observedAt = data.fitnessRepositoryString("observed_at_utc"),
                let location = data.fitnessRepositoryString("body_location_key")
            else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_body_issues
                    (id,session_id,issue_type_key,body_location_key,side,severity,timing,changed_session,
                     session_change_key,note,observed_at,resolved_at,revision,server_updated_at,
                     client_updated_at,origin_device_id,deleted_at,planned_session_id,session_exercise_id,
                     set_group_id,checkin_id,trend_key,status,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'server',?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      session_id=excluded.session_id,issue_type_key=excluded.issue_type_key,
                      body_location_key=excluded.body_location_key,side=excluded.side,severity=excluded.severity,
                      timing=excluded.timing,changed_session=excluded.changed_session,
                      session_change_key=excluded.session_change_key,note=excluded.note,
                      observed_at=excluded.observed_at,resolved_at=excluded.resolved_at,
                      planned_session_id=excluded.planned_session_id,
                      session_exercise_id=excluded.session_exercise_id,set_group_id=excluded.set_group_id,
                      checkin_id=excluded.checkin_id,trend_key=excluded.trend_key,status=excluded.status,
                      payload_json=excluded.payload_json,
                      revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, data.fitnessRepositoryString("activity_id"), data.fitnessRepositoryString("issue_type_key") ?? "other",
                    location, data.fitnessRepositoryString("side") ?? "unknown", data.fitnessRepositoryInt("severity_0_10") ?? 0,
                    data.fitnessRepositoryString("timing") ?? "standalone", data.fitnessRepositoryBool("changed_session") ?? false,
                    data.fitnessRepositoryString("session_change_key") ?? "none", data.fitnessRepositoryString("notes"), observedAt,
                    data.fitnessRepositoryString("resolved_at_utc"), change.revision, change.changedAt, updatedAt,
                    data.fitnessRepositoryString("deleted_at"),
                ]
                    + [
                        data.fitnessRepositoryString("planned_session_id"), data.fitnessRepositoryString("session_exercise_id"),
                        data.fitnessRepositoryString("set_group_id"), data.fitnessRepositoryString("checkin_id"),
                        data.fitnessRepositoryString("trend_key") ?? "unknown", data.fitnessRepositoryString("status") ?? "active",
                        try jsonString(.object(data)),
                    ]
            )
        case FitnessEntityType.cycleSettings.rawValue:
            let ownerUserId = data.fitnessRepositoryString("owner_user_id") ?? activeCycleOwnerId()
            let isOwner = data.fitnessRepositoryBool("is_owner") ?? (ownerUserId == activeCycleOwnerId())
            try db.execute(
                sql: """
                    INSERT INTO fitness_cycle_settings
                    (id,owner_user_id,owner_name,is_owner,cycle_length_days,
                     show_period_starts,show_predicted_period,show_estimated_ovulation,
                     share_period_starts_with_adults,share_predicted_period_with_adults,
                     share_estimated_ovulation_with_adults,latest_period_start,
                     predicted_next_period,estimated_ovulation,revision,server_updated_at,
                     client_updated_at,origin_device_id,created_at,deleted_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'server',?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      owner_user_id=excluded.owner_user_id,owner_name=excluded.owner_name,
                      is_owner=excluded.is_owner,cycle_length_days=excluded.cycle_length_days,
                      show_period_starts=excluded.show_period_starts,
                      show_predicted_period=excluded.show_predicted_period,
                      show_estimated_ovulation=excluded.show_estimated_ovulation,
                      share_period_starts_with_adults=excluded.share_period_starts_with_adults,
                      share_predicted_period_with_adults=excluded.share_predicted_period_with_adults,
                      share_estimated_ovulation_with_adults=excluded.share_estimated_ovulation_with_adults,
                      latest_period_start=excluded.latest_period_start,
                      predicted_next_period=excluded.predicted_next_period,
                      estimated_ovulation=excluded.estimated_ovulation,revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,origin_device_id='server',
                      created_at=excluded.created_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, ownerUserId, data.fitnessRepositoryString("owner_name") ?? (isOwner ? "You" : "Household adult"),
                    isOwner, data.fitnessRepositoryInt("cycle_length_days") ?? 28,
                    data.fitnessRepositoryBool("show_period_starts") ?? true,
                    data.fitnessRepositoryBool("show_predicted_period") ?? true,
                    data.fitnessRepositoryBool("show_estimated_ovulation") ?? true,
                    data.fitnessRepositoryBool("share_period_starts_with_adults") ?? false,
                    data.fitnessRepositoryBool("share_predicted_period_with_adults") ?? false,
                    data.fitnessRepositoryBool("share_estimated_ovulation_with_adults") ?? false,
                    data.fitnessRepositoryString("latest_period_start"), data.fitnessRepositoryString("predicted_next_period"),
                    data.fitnessRepositoryString("estimated_ovulation"), change.revision, change.changedAt, updatedAt,
                    data.fitnessRepositoryString("created_at") ?? updatedAt, data.fitnessRepositoryString("deleted_at"),
                ])
        case FitnessEntityType.cyclePeriodStart.rawValue:
            let settingsId = data.fitnessRepositoryString("settings_id") ?? data.fitnessRepositoryString("cycle_settings_id")
            let settingsOwner: String? = try settingsId.flatMap {
                try String.fetchOne(
                    db, sql: "SELECT owner_user_id FROM fitness_cycle_settings WHERE id=?", arguments: [$0]
                )
            }
            let ownerUserId = data.fitnessRepositoryString("owner_user_id") ?? settingsOwner ?? activeCycleOwnerId()
            guard let startedOn = data.fitnessRepositoryString("started_on"), Self.validDateOnly(startedOn) else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_cycle_period_starts
                    (id,owner_user_id,settings_id,started_on,revision,server_updated_at,
                     client_updated_at,origin_device_id,created_at,deleted_at)
                    VALUES (?,?,?,?,?,?,?,'server',?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      owner_user_id=excluded.owner_user_id,settings_id=excluded.settings_id,
                      started_on=excluded.started_on,revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,origin_device_id='server',
                      created_at=excluded.created_at,deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    change.entityId, ownerUserId, settingsId, startedOn, change.revision,
                    change.changedAt, updatedAt, data.fitnessRepositoryString("created_at") ?? updatedAt,
                    data.fitnessRepositoryString("deleted_at"),
                ])
        default:
            break
        }
    }

    private func upsertRemoteWorkoutDefinition(
        change: FitnessSyncChange,
        data: [String: JSONValue],
        updatedAt: String,
        db: Database
    ) throws {
        guard let name = data.fitnessRepositoryString("name"), let sportKey = data.fitnessRepositoryString("sport_key") else { return }
        let versions = data.fitnessRepositoryObjects("versions")
        let currentVersion = data.fitnessRepositoryObject("current_version") ?? data.fitnessRepositoryObject("version") ?? versions.first
        let currentVersionId = currentVersion?.fitnessRepositoryString("id") ?? data.fitnessRepositoryString("current_version_id")
        try db.execute(
            sql: """
                INSERT INTO fitness_workout_definitions
                (id,sport_key,name,description,active,current_version_id,revision,server_updated_at,
                 client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,'server',?,?)
                ON CONFLICT(id) DO UPDATE SET
                  sport_key=excluded.sport_key,name=excluded.name,description=excluded.description,
                  active=excluded.active,current_version_id=excluded.current_version_id,
                  revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                change.entityId, sportKey, name, data.fitnessRepositoryString("description"), data.fitnessRepositoryBool("active") ?? true,
                currentVersionId, change.revision, change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"),
                try jsonString(.object(data)),
            ]
        )

        let versionRows = versions.isEmpty ? currentVersion.map { [$0] } ?? [] : versions
        for version in versionRows {
            guard let versionId = version.fitnessRepositoryString("id"), let title = version.fitnessRepositoryString("title") else {
                continue
            }
            let summaryJSON = try jsonString(version["structured_summary"] ?? .object([:]))
            try db.execute(
                sql: """
                    INSERT INTO fitness_workout_definition_versions
                    (id,workout_definition_id,version_number,title,purpose,estimated_duration_seconds,
                     estimated_distance_metres,structured_summary_json,version_source,created_at,accepted_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      accepted_at=COALESCE(excluded.accepted_at,accepted_at)
                    """,
                arguments: [
                    versionId, change.entityId, version.fitnessRepositoryInt("version_number") ?? 1, title,
                    version.fitnessRepositoryString("purpose"), version.fitnessRepositoryInt("estimated_duration_s"),
                    version.fitnessRepositoryDouble("estimated_distance_m"), summaryJSON,
                    version.fitnessRepositoryString("version_source") ?? "user", version.fitnessRepositoryString("created_at") ?? updatedAt,
                    version.fitnessRepositoryString("accepted_at"),
                ]
            )
            try db.execute(
                sql: """
                    DELETE FROM fitness_workout_version_sets
                    WHERE workout_version_exercise_id IN (
                        SELECT id FROM fitness_workout_version_exercises WHERE workout_version_id = ?
                    )
                    """,
                arguments: [versionId]
            )
            try db.execute(
                sql: "DELETE FROM fitness_workout_version_exercises WHERE workout_version_id = ?",
                arguments: [versionId]
            )
            for item in version.fitnessRepositoryObjects("exercise_items") {
                guard let exerciseId = item.fitnessRepositoryString("exercise_id") else { continue }
                let itemId = item.fitnessRepositoryString("id") ?? UUID().uuidString
                let substitutionsJSON = try jsonString(
                    item["substitution_exercise_ids"] ?? .array([])
                )
                try db.execute(
                    sql: """
                        INSERT INTO fitness_workout_version_exercises
                        (id,workout_version_id,exercise_id,exercise_setup_id,position,superset_group_key,
                         substitution_exercise_ids_json,notes)
                        VALUES (?,?,?,?,?,?,?,?)
                        """,
                    arguments: [
                        itemId, versionId, exerciseId, item.fitnessRepositoryString("exercise_setup_id"),
                        item.fitnessRepositoryInt("sequence") ?? 0, item.fitnessRepositoryString("superset_group_key"),
                        substitutionsJSON, item.fitnessRepositoryString("notes"),
                    ]
                )
                for set in item.fitnessRepositoryObjects("planned_sets") {
                    try db.execute(
                        sql: """
                            INSERT INTO fitness_workout_version_sets
                            (id,workout_version_exercise_id,position,training_role,structure_type,
                             component_count,reps_min,reps_max,load_min,load_max,load_unit,rpe_min,
                             rpe_max,rir_min,rir_max,rest_seconds,is_amrap,notes)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                            """,
                        arguments: [
                            set.fitnessRepositoryString("id") ?? UUID().uuidString, itemId, set.fitnessRepositoryInt("sequence") ?? 0,
                            set.fitnessRepositoryString("training_role") ?? "working",
                            set.fitnessRepositoryString("structure_type") ?? "straight", set.fitnessRepositoryInt("component_count") ?? 1,
                            set.fitnessRepositoryInt("reps_min"), set.fitnessRepositoryInt("reps_max"),
                            set.fitnessRepositoryDouble("load_min"),
                            set.fitnessRepositoryDouble("load_max"), set.fitnessRepositoryString("load_unit"),
                            set.fitnessRepositoryDouble("rpe_min"),
                            set.fitnessRepositoryDouble("rpe_max"), set.fitnessRepositoryDouble("rir_min"),
                            set.fitnessRepositoryDouble("rir_max"),
                            set.fitnessRepositoryInt("rest_s"), set.fitnessRepositoryBool("is_amrap") ?? false,
                            set.fitnessRepositoryString("notes"),
                        ]
                    )
                }
            }
            try db.execute(
                sql: "DELETE FROM fitness_run_workout_steps WHERE workout_version_id=?",
                arguments: [versionId]
            )
            try db.execute(
                sql: "DELETE FROM fitness_run_workout_cues WHERE workout_version_id=?",
                arguments: [versionId]
            )
            try insertRemoteRunSteps(
                version.fitnessRepositoryObjects("run_steps"), versionId: versionId, parentId: nil, db: db
            )
            for cue in version.fitnessRepositoryObjects("run_cues") {
                guard let cueId = cue.fitnessRepositoryString("id"), let trigger = cue.fitnessRepositoryString("trigger_type"),
                    let shortText = cue.fitnessRepositoryString("short_text")
                else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO fitness_run_workout_cues
                        (id,workout_version_id,step_id,sequence,trigger_type,trigger_value,
                         short_text,spoken_text,priority)
                        VALUES (?,?,?,?,?,?,?,?,?)
                        """,
                    arguments: [
                        cueId, versionId, cue.fitnessRepositoryString("step_id"), cue.fitnessRepositoryInt("sequence") ?? 0, trigger,
                        cue.fitnessRepositoryDouble("trigger_value"), shortText, cue.fitnessRepositoryString("spoken_text"),
                        cue.fitnessRepositoryInt("priority") ?? 0,
                    ]
                )
            }
        }
    }

    private func insertRemoteRunSteps(
        _ steps: [[String: JSONValue]],
        versionId: String,
        parentId: String?,
        db: Database
    ) throws {
        for step in steps {
            guard let id = step.fitnessRepositoryString("id"), let kind = step.fitnessRepositoryString("step_kind"),
                let durationType = step.fitnessRepositoryString("duration_type"),
                let targetType = step.fitnessRepositoryString("target_type"),
                let displayName = step.fitnessRepositoryString("display_name")
            else { continue }
            try db.execute(
                sql: """
                    INSERT INTO fitness_run_workout_steps
                    (id,workout_version_id,parent_step_id,sequence,step_kind,repeat_count,duration_type,
                     duration_value,target_type,target_low,target_high,target_unit,intensity_label,
                     kilometre_index,display_name,instruction_text,mental_cue_text,spoken_cue_text,
                     allow_manual_advance,notes)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    id, versionId, parentId ?? step.fitnessRepositoryString("parent_step_id"), step.fitnessRepositoryInt("sequence") ?? 0,
                    kind, step.fitnessRepositoryInt("repeat_count"), durationType, step.fitnessRepositoryDouble("duration_value"),
                    targetType,
                    step.fitnessRepositoryDouble("target_low"), step.fitnessRepositoryDouble("target_high"),
                    step.fitnessRepositoryString("target_unit"),
                    step.fitnessRepositoryString("intensity_label"), step.fitnessRepositoryInt("kilometre_index"), displayName,
                    step.fitnessRepositoryString("instruction_text"),
                    step.fitnessRepositoryString("mental_cue_text"), step.fitnessRepositoryString("spoken_cue_text"),
                    step.fitnessRepositoryBool("allow_manual_advance") ?? false, step.fitnessRepositoryString("notes"),
                ]
            )
            try insertRemoteRunSteps(step.fitnessRepositoryObjects("children"), versionId: versionId, parentId: id, db: db)
        }
    }

    func jsonString(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func upsertRemoteFood(
        change: FitnessSyncChange,
        data: [String: JSONValue],
        updatedAt: String,
        db: Database
    ) throws {
        guard let name = data.fitnessRepositoryString("name") else { return }
        let versions = data.fitnessRepositoryObjects("versions")
        let version = data.fitnessRepositoryObject("current_version") ?? data.fitnessRepositoryObject("version") ?? versions.first
        let existingVersionId = try String.fetchOne(
            db, sql: "SELECT current_version_id FROM fitness_foods WHERE id=?", arguments: [change.entityId]
        )
        guard let versionId = version?.fitnessRepositoryString("id") ?? existingVersionId else { return }
        let active = data.fitnessRepositoryBool("active") ?? true
        try db.execute(
            sql: """
                INSERT INTO fitness_foods
                (id,current_version_id,name,brand,is_favourite,is_archived,revision,server_updated_at,
                 client_updated_at,origin_device_id,deleted_at,category_key,barcode,notes,
                 household_shared,active,merged_into_food_id,editable,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,'server',?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  current_version_id=COALESCE(excluded.current_version_id,fitness_foods.current_version_id),
                  name=excluded.name,brand=excluded.brand,
                  is_favourite=excluded.is_favourite,is_archived=excluded.is_archived,
                  category_key=excluded.category_key,barcode=excluded.barcode,notes=excluded.notes,
                  household_shared=excluded.household_shared,active=excluded.active,
                  merged_into_food_id=excluded.merged_into_food_id,editable=excluded.editable,
                  revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                change.entityId, versionId, name, data.fitnessRepositoryString("brand"), data.fitnessRepositoryBool("favourite") ?? false,
                !active, change.revision, change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"),
                data.fitnessRepositoryString("category_key"), data.fitnessRepositoryString("barcode"),
                data.fitnessRepositoryString("notes"),
                data.fitnessRepositoryBool("household_shared") ?? false, active, data.fitnessRepositoryString("merged_into_food_id"),
                data.fitnessRepositoryBool("editable") ?? true, try jsonString(.object(data)),
            ]
        )
        var versionPayloads = versions
        if let version, !versionPayloads.contains(where: { $0.fitnessRepositoryString("id") == version.fitnessRepositoryString("id") }) {
            versionPayloads.append(version)
        }
        for item in versionPayloads {
            guard let id = item.fitnessRepositoryString("id") else { continue }
            try upsertRemoteFoodVersion(
                id: id, data: item, revision: item.fitnessRepositoryInt("revision") ?? change.revision,
                changedAt: item.fitnessRepositoryString("updated_at") ?? change.changedAt,
                updatedAt: item.fitnessRepositoryString("updated_at") ?? updatedAt, foodId: change.entityId, db: db
            )
        }
        for item in data.fitnessRepositoryObjects("servings") {
            guard let id = item.fitnessRepositoryString("id") else { continue }
            try upsertRemoteFoodServing(
                id: id, data: item, revision: item.fitnessRepositoryInt("revision") ?? change.revision,
                changedAt: item.fitnessRepositoryString("updated_at") ?? change.changedAt,
                updatedAt: item.fitnessRepositoryString("updated_at") ?? updatedAt, db: db
            )
        }
        if let serving = data.fitnessRepositoryObjects("servings").first(where: {
            $0.fitnessRepositoryBool("is_default") == true && $0.fitnessRepositoryString("canonical_unit") == "g"
        }) {
            try db.execute(
                sql: "UPDATE fitness_food_versions SET default_serving_grams=? WHERE id=?",
                arguments: [serving.fitnessRepositoryDouble("canonical_amount"), versionId]
            )
        }
    }

    private func upsertRemoteFoodVersion(
        id: String, data: [String: JSONValue], revision: Int, changedAt: String,
        updatedAt: String, foodId explicitFoodId: String?, db: Database
    ) throws {
        guard let foodId = explicitFoodId ?? data.fitnessRepositoryString("food_id") else { return }
        let amount = data.fitnessRepositoryDouble("reference_amount") ?? 100
        let unit = data.fitnessRepositoryString("reference_unit") ?? "g"
        let calories = data.fitnessRepositoryDouble("calories_kcal")
        let kcalPer100 = unit == "g" ? calories.map { $0 * 100 / max(amount, 0.000_001) } : nil
        try db.execute(
            sql: """
                INSERT INTO fitness_food_versions
                (id,food_id,kcal_per_100g,default_serving_grams,created_at,superseded_at,
                 version_number,effective_from,reference_amount,reference_unit,calories_kcal,
                 source_energy_value,source_energy_unit,protein_g,carbohydrate_g,sugars_g,fat_g,
                 saturated_fat_g,fibre_g,salt_g,sodium_mg,micronutrients_json,source_type,
                 source_note,confidence,label_asset_id,revision,server_updated_at,client_updated_at,
                 origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'server',?,?)
                ON CONFLICT(id) DO UPDATE SET food_id=excluded.food_id,
                  kcal_per_100g=excluded.kcal_per_100g,version_number=excluded.version_number,
                  effective_from=excluded.effective_from,reference_amount=excluded.reference_amount,
                  reference_unit=excluded.reference_unit,calories_kcal=excluded.calories_kcal,
                  source_energy_value=excluded.source_energy_value,source_energy_unit=excluded.source_energy_unit,
                  protein_g=excluded.protein_g,carbohydrate_g=excluded.carbohydrate_g,
                  sugars_g=excluded.sugars_g,fat_g=excluded.fat_g,
                  saturated_fat_g=excluded.saturated_fat_g,fibre_g=excluded.fibre_g,
                  salt_g=excluded.salt_g,sodium_mg=excluded.sodium_mg,
                  micronutrients_json=excluded.micronutrients_json,source_type=excluded.source_type,
                  source_note=excluded.source_note,confidence=excluded.confidence,
                  label_asset_id=excluded.label_asset_id,revision=excluded.revision,
                  server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                  deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                """,
            arguments: [
                id, foodId, kcalPer100, nil, data.fitnessRepositoryString("created_at") ?? updatedAt,
                data.fitnessRepositoryString("superseded_at"), data.fitnessRepositoryInt("version_number"),
                data.fitnessRepositoryString("effective_from"),
                amount, unit, calories, data.fitnessRepositoryDouble("source_energy_value"),
                data.fitnessRepositoryString("source_energy_unit"),
                data.fitnessRepositoryDouble("protein_g"), data.fitnessRepositoryDouble("carbohydrate_g"),
                data.fitnessRepositoryDouble("sugars_g"),
                data.fitnessRepositoryDouble("fat_g"), data.fitnessRepositoryDouble("saturated_fat_g"),
                data.fitnessRepositoryDouble("fibre_g"),
                data.fitnessRepositoryDouble("salt_g"), data.fitnessRepositoryDouble("sodium_mg"),
                try jsonString(data["micronutrients"] ?? data["micronutrients_json"] ?? .object([:])),
                data.fitnessRepositoryString("source_type") ?? "manual", data.fitnessRepositoryString("source_note"),
                data.fitnessRepositoryString("confidence") ?? "unknown", data.fitnessRepositoryString("label_asset_id"), revision,
                changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"), try jsonString(.object(data)),
            ]
        )
        try db.execute(
            sql:
                "UPDATE fitness_foods SET current_version_id=? WHERE id=? AND (current_version_id IS NULL OR COALESCE((SELECT version_number FROM fitness_food_versions WHERE id=current_version_id),0)<=?)",
            arguments: [id, foodId, data.fitnessRepositoryInt("version_number") ?? 0]
        )
    }

    private func upsertRemoteFoodServing(
        id: String, data: [String: JSONValue], revision: Int, changedAt: String,
        updatedAt: String, db: Database
    ) throws {
        guard let foodId = data.fitnessRepositoryString("food_id"), let name = data.fitnessRepositoryString("name"),
            let amount = data.fitnessRepositoryDouble("amount"), let unit = data.fitnessRepositoryString("unit"),
            let canonicalAmount = data.fitnessRepositoryDouble("canonical_amount"),
            let canonicalUnit = data.fitnessRepositoryString("canonical_unit")
        else { return }
        if data.fitnessRepositoryBool("is_default") == true {
            try db.execute(sql: "UPDATE fitness_food_servings SET is_default=0 WHERE food_id=?", arguments: [foodId])
        }
        try db.execute(
            sql: """
                INSERT INTO fitness_food_servings
                (id,food_id,name,amount,unit,canonical_amount,canonical_unit,measurement_quality,
                 is_default,active,revision,server_updated_at,client_updated_at,origin_device_id,
                 deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'server',?,?)
                ON CONFLICT(id) DO UPDATE SET food_id=excluded.food_id,name=excluded.name,
                  amount=excluded.amount,unit=excluded.unit,canonical_amount=excluded.canonical_amount,
                  canonical_unit=excluded.canonical_unit,measurement_quality=excluded.measurement_quality,
                  is_default=excluded.is_default,active=excluded.active,revision=excluded.revision,
                  server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                  deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                """,
            arguments: [
                id, foodId, name, amount, unit, canonicalAmount, canonicalUnit,
                data.fitnessRepositoryString("measurement_quality") ?? "standard_serving",
                data.fitnessRepositoryBool("is_default") ?? false,
                data.fitnessRepositoryBool("active") ?? true, revision, changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"),
                try jsonString(.object(data)),
            ]
        )
    }

    private func upsertRemoteRecipe(
        change: FitnessSyncChange, data: [String: JSONValue], updatedAt: String, db: Database
    ) throws {
        guard let name = data.fitnessRepositoryString("name") else { return }
        var versions = data.fitnessRepositoryObjects("versions")
        if let current = data.fitnessRepositoryObject("current_version"),
            !versions.contains(where: { $0.fitnessRepositoryString("id") == current.fitnessRepositoryString("id") })
        {
            versions.append(current)
        }
        let storedCurrentId = try String.fetchOne(
            db, sql: "SELECT current_version_id FROM fitness_recipes WHERE id=?", arguments: [change.entityId]
        )
        let currentId =
            data.fitnessRepositoryObject("current_version")?.fitnessRepositoryString("id")
            ?? versions.first?.fitnessRepositoryString("id") ?? storedCurrentId
        try db.execute(
            sql: """
                INSERT INTO fitness_recipes
                (id,current_version_id,name,notes,household_shared,favourite,active,editable,revision,
                 server_updated_at,client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,'server',?,?)
                ON CONFLICT(id) DO UPDATE SET
                  current_version_id=COALESCE(excluded.current_version_id,fitness_recipes.current_version_id),
                  name=excluded.name,notes=excluded.notes,household_shared=excluded.household_shared,
                  favourite=excluded.favourite,active=excluded.active,editable=excluded.editable,
                  revision=excluded.revision,
                  server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                  deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                """,
            arguments: [
                change.entityId, currentId, name, data.fitnessRepositoryString("notes"),
                data.fitnessRepositoryBool("household_shared") ?? false,
                data.fitnessRepositoryBool("favourite") ?? false, data.fitnessRepositoryBool("active") ?? true,
                data.fitnessRepositoryBool("editable") ?? true, change.revision,
                change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"), try jsonString(.object(data)),
            ]
        )
        for item in versions {
            guard let id = item.fitnessRepositoryString("id") else { continue }
            try upsertRemoteRecipeVersion(
                id: id, data: item, revision: item.fitnessRepositoryInt("revision") ?? change.revision,
                changedAt: item.fitnessRepositoryString("updated_at") ?? change.changedAt,
                updatedAt: item.fitnessRepositoryString("updated_at") ?? updatedAt, recipeId: change.entityId, db: db
            )
        }
    }

    private func upsertRemoteRecipeVersion(
        id: String, data: [String: JSONValue], revision: Int, changedAt: String,
        updatedAt: String, recipeId explicitRecipeId: String?, db: Database
    ) throws {
        guard let recipeId = explicitRecipeId ?? data.fitnessRepositoryString("recipe_id") else { return }
        let nutrients: [String] = [
            "calories_kcal", "protein_g", "carbohydrate_g", "sugars_g", "fat_g", "saturated_fat_g", "fibre_g", "salt_g",
        ]
        try db.execute(
            sql: """
                INSERT INTO fitness_recipe_versions
                (id,recipe_id,version_number,finished_weight_g,servings,calories_kcal,protein_g,
                 carbohydrate_g,sugars_g,fat_g,saturated_fat_g,fibre_g,salt_g,
                 lower_calories_kcal,upper_calories_kcal,confidence,source_note,components_json,
                 per_100_g_json,revision,server_updated_at,client_updated_at,origin_device_id,
                 deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'server',?,?)
                ON CONFLICT(id) DO UPDATE SET recipe_id=excluded.recipe_id,
                  version_number=excluded.version_number,finished_weight_g=excluded.finished_weight_g,
                  servings=excluded.servings,calories_kcal=excluded.calories_kcal,
                  protein_g=excluded.protein_g,carbohydrate_g=excluded.carbohydrate_g,
                  sugars_g=excluded.sugars_g,fat_g=excluded.fat_g,
                  saturated_fat_g=excluded.saturated_fat_g,fibre_g=excluded.fibre_g,
                  salt_g=excluded.salt_g,lower_calories_kcal=excluded.lower_calories_kcal,
                  upper_calories_kcal=excluded.upper_calories_kcal,confidence=excluded.confidence,
                  source_note=excluded.source_note,components_json=excluded.components_json,
                  per_100_g_json=excluded.per_100_g_json,revision=excluded.revision,
                  server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                  deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                """,
            arguments: [
                id, recipeId, data.fitnessRepositoryInt("version_number"), data.fitnessRepositoryDouble("finished_weight_g"),
                data.fitnessRepositoryDouble("servings"),
                data.fitnessRepositoryDouble(nutrients[0]), data.fitnessRepositoryDouble(nutrients[1]),
                data.fitnessRepositoryDouble(nutrients[2]),
                data.fitnessRepositoryDouble(nutrients[3]), data.fitnessRepositoryDouble(nutrients[4]),
                data.fitnessRepositoryDouble(nutrients[5]),
                data.fitnessRepositoryDouble(nutrients[6]), data.fitnessRepositoryDouble(nutrients[7]),
                data.fitnessRepositoryDouble("lower_calories_kcal"),
                data.fitnessRepositoryDouble("upper_calories_kcal"), data.fitnessRepositoryString("confidence") ?? "calculated",
                data.fitnessRepositoryString("source_note"), try jsonString(data["components"] ?? .array([])),
                try data["per_100_g"].map(jsonString), revision, changedAt, updatedAt,
                data.fitnessRepositoryString("deleted_at"), try jsonString(.object(data)),
            ]
        )
        try db.execute(sql: "UPDATE fitness_recipes SET current_version_id=? WHERE id=?", arguments: [id, recipeId])
    }

    private func upsertRemoteMealTemplate(
        change: FitnessSyncChange, data: [String: JSONValue], updatedAt: String, db: Database
    ) throws {
        guard let name = data.fitnessRepositoryString("name"), let meal = data.fitnessRepositoryString("meal_key") else { return }
        try db.execute(
            sql: """
                INSERT INTO fitness_meal_templates
                (id,name,meal_key,time_relevance,favourite,active,items_json,revision,
                 server_updated_at,client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,'server',?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,meal_key=excluded.meal_key,
                  time_relevance=excluded.time_relevance,favourite=excluded.favourite,
                  active=excluded.active,items_json=excluded.items_json,revision=excluded.revision,
                  server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                  deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                """,
            arguments: [
                change.entityId, name, meal, data.fitnessRepositoryString("time_relevance"),
                data.fitnessRepositoryBool("favourite") ?? false,
                data.fitnessRepositoryBool("active") ?? true, try jsonString(data["items"] ?? .array([])), change.revision,
                change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"), try jsonString(.object(data)),
            ]
        )
    }

    private func upsertRemoteNutritionTarget(
        change: FitnessSyncChange, data: [String: JSONValue], updatedAt: String, db: Database
    ) throws {
        guard let rawMetric = data.fitnessRepositoryString("metric_key"), let type = data.fitnessRepositoryString("target_type"),
            let effective = data.fitnessRepositoryString("effective_from")
        else { return }
        let metric = rawMetric.hasPrefix("nutrition.")
            ? String(rawMetric.dropFirst("nutrition.".count))
            : rawMetric
        try db.execute(
            sql: """
                INSERT INTO fitness_nutrition_targets
                (id,metric_key,target_type,target_value,target_min,target_max,training_day_value,
                 rest_day_value,phase_id,effective_from,effective_until,active,revision,
                 server_updated_at,client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'server',?,?)
                ON CONFLICT(id) DO UPDATE SET metric_key=excluded.metric_key,
                  target_type=excluded.target_type,target_value=excluded.target_value,
                  target_min=excluded.target_min,target_max=excluded.target_max,
                  training_day_value=excluded.training_day_value,rest_day_value=excluded.rest_day_value,
                  phase_id=excluded.phase_id,effective_from=excluded.effective_from,
                  effective_until=excluded.effective_until,active=excluded.active,
                  revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                change.entityId, metric, type, data.fitnessRepositoryDouble("target_value"), data.fitnessRepositoryDouble("target_min"),
                data.fitnessRepositoryDouble("target_max"), data.fitnessRepositoryDouble("training_day_value"),
                data.fitnessRepositoryDouble("rest_day_value"),
                data.fitnessRepositoryString("phase_id"), effective, data.fitnessRepositoryString("effective_until"),
                data.fitnessRepositoryBool("active") ?? true,
                change.revision, change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"), try jsonString(.object(data)),
            ]
        )
    }

    private func upsertRemoteExercise(
        change: FitnessSyncChange,
        data: [String: JSONValue],
        updatedAt: String,
        db: Database
    ) throws {
        guard let name = data.fitnessRepositoryString("name") else { return }
        let primaryMuscle = data.fitnessRepositoryObjects("muscle_roles").first { $0.fitnessRepositoryString("role") == "primary" }?
            .fitnessRepositoryString("muscle_group_key")
        try db.execute(
            sql: """
                INSERT INTO fitness_exercises
                (id,name,category,primary_muscle,is_favourite,is_custom,is_archived,revision,
                 server_updated_at,client_updated_at,origin_device_id,deleted_at,seed_key,aliases_json,
                 movement_pattern_key,measurement_mode,rep_count_mode,load_entry_mode,default_unit,
                 unilateral_mode,equipment_type,bodyweight_involved,progression_direction,notes,active,
                 merged_into_exercise_id,muscle_roles_json,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,'server',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  name=excluded.name,category=excluded.category,primary_muscle=excluded.primary_muscle,
                  is_favourite=excluded.is_favourite,is_custom=excluded.is_custom,
                  is_archived=excluded.is_archived,revision=excluded.revision,
                  seed_key=excluded.seed_key,aliases_json=excluded.aliases_json,
                  movement_pattern_key=excluded.movement_pattern_key,
                  measurement_mode=excluded.measurement_mode,rep_count_mode=excluded.rep_count_mode,
                  load_entry_mode=excluded.load_entry_mode,default_unit=excluded.default_unit,
                  unilateral_mode=excluded.unilateral_mode,equipment_type=excluded.equipment_type,
                  bodyweight_involved=excluded.bodyweight_involved,
                  progression_direction=excluded.progression_direction,notes=excluded.notes,
                  active=excluded.active,merged_into_exercise_id=excluded.merged_into_exercise_id,
                  muscle_roles_json=excluded.muscle_roles_json,payload_json=excluded.payload_json,
                  server_updated_at=excluded.server_updated_at,client_updated_at=excluded.client_updated_at,
                  deleted_at=excluded.deleted_at
                """,
            arguments: [
                change.entityId, name, data.fitnessRepositoryString("movement_pattern_key") ?? "other", primaryMuscle,
                data.fitnessRepositoryBool("favourite") ?? false, data.fitnessRepositoryString("seed_key") == nil,
                !(data.fitnessRepositoryBool("active") ?? true), change.revision, change.changedAt, updatedAt,
                data.fitnessRepositoryString("deleted_at"), data.fitnessRepositoryString("seed_key"),
                try jsonString(data["aliases"] ?? .array([])),
                data.fitnessRepositoryString("movement_pattern_key") ?? "other",
                data.fitnessRepositoryString("measurement_mode") ?? "reps_load",
                data.fitnessRepositoryString("rep_count_mode") ?? "total",
                data.fitnessRepositoryString("load_entry_mode") ?? "total_external", data.fitnessRepositoryString("default_unit") ?? "kg",
                data.fitnessRepositoryString("unilateral_mode") ?? "bilateral", data.fitnessRepositoryString("equipment_type"),
                data.fitnessRepositoryBool("bodyweight_involved") ?? false,
                data.fitnessRepositoryString("progression_direction") ?? "higher",
                data.fitnessRepositoryString("notes"), data.fitnessRepositoryBool("active") ?? true,
                data.fitnessRepositoryString("merged_into_exercise_id"),
                try jsonString(data["muscle_roles"] ?? .array([])), try jsonString(.object(data)),
            ]
        )
        if let target = data.fitnessRepositoryString("merged_into_exercise_id") {
            try db.execute(
                sql: "INSERT OR REPLACE INTO fitness_redirects(entity_type,source_id,target_id,updated_at) VALUES (?,?,?,?)",
                arguments: [FitnessEntityType.exercise.rawValue, change.entityId, target, updatedAt]
            )
        }
        for setup in data.fitnessRepositoryObjects("setups") {
            guard let setupId = setup.fitnessRepositoryString("id") else { continue }
            let setupChange = FitnessSyncChange(
                sequence: change.sequence, entityType: FitnessEntityType.exerciseSetup.rawValue,
                entityId: setupId, revision: setup.fitnessRepositoryInt("revision") ?? change.revision,
                operation: "upsert", data: setup, changedAt: change.changedAt
            )
            try upsertRemoteSetup(change: setupChange, data: setup, updatedAt: updatedAt, db: db)
        }
    }

    private func upsertRemoteSetup(
        change: FitnessSyncChange,
        data: [String: JSONValue],
        updatedAt: String,
        db: Database
    ) throws {
        guard let exerciseId = data.fitnessRepositoryString("exercise_id"), let name = data.fitnessRepositoryString("name") else { return }
        let mode = Self.localLoadMode(data.fitnessRepositoryString("load_entry_mode"))
        try db.execute(
            sql: """
                INSERT INTO fitness_exercise_setups
                (id,exercise_id,name,load_mode,increment_kg,bar_weight_kg,is_default,revision,
                 server_updated_at,client_updated_at,origin_device_id,deleted_at,location,equipment_identifier,
                 rep_count_mode,unilateral_mode,machine_base_load_kg,side_multiplier,notes,active,
                 merged_into_setup_id,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,'server',?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  exercise_id=excluded.exercise_id,name=excluded.name,load_mode=excluded.load_mode,
                  increment_kg=excluded.increment_kg,bar_weight_kg=excluded.bar_weight_kg,
                  is_default=excluded.is_default,location=excluded.location,
                  equipment_identifier=excluded.equipment_identifier,
                  rep_count_mode=excluded.rep_count_mode,unilateral_mode=excluded.unilateral_mode,
                  machine_base_load_kg=excluded.machine_base_load_kg,side_multiplier=excluded.side_multiplier,
                  notes=excluded.notes,active=excluded.active,
                  merged_into_setup_id=excluded.merged_into_setup_id,payload_json=excluded.payload_json,
                  revision=excluded.revision,server_updated_at=excluded.server_updated_at,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at
                """,
            arguments: [
                change.entityId, exerciseId, name, mode.rawValue, data.fitnessRepositoryDouble("increment_kg"),
                data.fitnessRepositoryDouble("bar_weight_kg"), data.fitnessRepositoryBool("is_default") ?? false, change.revision,
                change.changedAt, updatedAt, data.fitnessRepositoryString("deleted_at"), data.fitnessRepositoryString("location"),
                data.fitnessRepositoryString("equipment_identifier"), data.fitnessRepositoryString("rep_count_mode") ?? "total",
                data.fitnessRepositoryString("unilateral_mode") ?? "bilateral", data.fitnessRepositoryDouble("machine_base_load_kg"),
                data.fitnessRepositoryDouble("side_multiplier"), data.fitnessRepositoryString("notes"),
                data.fitnessRepositoryBool("active") ?? true,
                data.fitnessRepositoryString("merged_into_setup_id"), try jsonString(.object(data)),
            ]
        )
        if let target = data.fitnessRepositoryString("merged_into_setup_id") {
            try db.execute(
                sql: "INSERT OR REPLACE INTO fitness_redirects(entity_type,source_id,target_id,updated_at) VALUES (?,?,?,?)",
                arguments: [FitnessEntityType.exerciseSetup.rawValue, change.entityId, target, updatedAt]
            )
        }
    }

}
