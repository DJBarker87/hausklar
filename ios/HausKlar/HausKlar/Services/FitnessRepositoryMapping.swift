import Foundation
import GRDB

/// This extension is isolated to FitnessRepository's single actor. Its context
/// is never used independently of that facade, preserving call-site serialization.
extension FitnessRepository {
    static func goal(_ row: Row) -> FitnessGoal {
        FitnessGoal(
            id: row["id"], title: row["title"], metric: row["metric"],
            targetValue: row["target_value"], unit: row["unit"],
            targetDate: FitnessDatabase.date(row["target_date"]), revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast
        )
    }

    static func food(_ row: Row) -> FitnessFood {
        FitnessFood(
            id: row["id"], versionId: row["current_version_id"], name: row["name"], brand: row["brand"],
            kcalPer100g: row["kcal_per_100g"], defaultServingGrams: row["default_serving_grams"],
            isFavourite: (row["is_favourite"] as Int) != 0, isArchived: (row["is_archived"] as Int) != 0,
            revision: row["revision"], updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast
        )
    }

    static func foodLog(_ row: Row) -> FitnessFoodLogEntry {
        FitnessFoodLogEntry(
            id: row["id"], foodId: row["food_id"], foodVersionId: row["food_version_id"],
            foodName: row["food_name"], loggedAt: FitnessDatabase.date(row["logged_at"]) ?? .distantPast,
            nutritionDate: row["nutrition_date"], meal: FitnessMeal(rawValue: row["meal"]) ?? .snack,
            amountGrams: row["amount_grams"], kcal: row["kcal"], revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast
        )
    }

    static func bodyMeasurement(_ row: Row) -> FitnessBodyMeasurement {
        let sourceRecordId: String? = row["source_record_id"]
        let transport: String? = (row["detail_transport_key"] as String?) ?? row["transport_key"]
        let provider: String? = (row["detail_origin_provider_key"] as String?) ?? row["origin_provider_key"]
        let namespace: String? = (row["detail_source_namespace"] as String?) ?? row["source_namespace"]
        let sourceDetails: FitnessExternalSourceDTO?
        if let transport, let provider, let namespace {
            sourceDetails = FitnessExternalSourceDTO(
                transportKey: transport, originProviderKey: provider, sourceNamespace: namespace,
                sourceDeviceIdentifier: row["detail_source_device_identifier"],
                state: row["detail_source_state"]
            )
        } else {
            sourceDetails = nil
        }
        return FitnessBodyMeasurement(
            id: row["id"], metricKey: row["metric_key"] ?? "body.weight_kg",
            measuredAt: FitnessDatabase.date(row["measured_at"]) ?? .distantPast,
            value: (row["value_number"] as Double?) ?? row["weight_kg"],
            unitKey: row["unit_key"] ?? "kg", notes: row["notes"],
            measurementQuality: row["measurement_quality"] ?? "measured",
            source: FitnessMeasurementSource(rawValue: row["source"]) ?? .manual,
            isCanonical: (row["is_canonical"] as Int) != 0, revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            sourceRecordId: sourceRecordId, sourceDetails: sourceDetails,
            canonicalState: row["canonical_state"] ?? ((row["is_canonical"] as Int) != 0 ? "canonical" : "duplicate"),
            duplicateOfMeasurementId: row["duplicate_of_measurement_id"],
            manualCanonicalOverride: (row["manual_canonical_override"] as Int? ?? 0) != 0
        )
    }

    static func exercise(_ row: Row) throws -> FitnessExercise {
        try FitnessExercise(
            id: row["id"], name: row["name"], category: row["category"], primaryMuscle: row["primary_muscle"],
            isFavourite: (row["is_favourite"] as Int) != 0, isCustom: (row["is_custom"] as Int) != 0,
            isArchived: (row["is_archived"] as Int) != 0, revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            seedKey: row["seed_key"], aliases: decodeStringArray(row["aliases_json"]),
            movementPatternKey: row["movement_pattern_key"] ?? "other",
            measurementMode: row["measurement_mode"] ?? "reps_load",
            repCountMode: row["rep_count_mode"] ?? "total",
            loadEntryMode: row["load_entry_mode"] ?? "total_external",
            defaultUnit: row["default_unit"] ?? "kg", unilateralMode: row["unilateral_mode"] ?? "bilateral",
            equipmentType: row["equipment_type"], bodyweightInvolved: (row["bodyweight_involved"] as Int? ?? 0) != 0,
            progressionDirection: row["progression_direction"] ?? "higher", notes: row["notes"],
            active: (row["active"] as Int? ?? 1) != 0, mergedIntoExerciseId: row["merged_into_exercise_id"],
            muscleRoles: decodeMuscleRoles(row["muscle_roles_json"])
        )
    }

    static func setup(_ row: Row) -> FitnessExerciseSetup {
        FitnessExerciseSetup(
            id: row["id"], exerciseId: row["exercise_id"], name: row["name"],
            loadMode: FitnessLoadMode(rawValue: row["load_mode"]) ?? .total,
            incrementKg: row["increment_kg"], barWeightKg: row["bar_weight_kg"],
            isDefault: (row["is_default"] as Int) != 0, revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            location: row["location"], equipmentIdentifier: row["equipment_identifier"],
            repCountMode: row["rep_count_mode"] ?? "total", unilateralMode: row["unilateral_mode"] ?? "bilateral",
            machineBaseLoadKg: row["machine_base_load_kg"], sideMultiplier: row["side_multiplier"],
            notes: row["notes"], active: (row["active"] as Int? ?? 1) != 0,
            mergedIntoSetupId: row["merged_into_setup_id"]
        )
    }

    static func session(_ row: Row) -> FitnessStrengthSession {
        FitnessStrengthSession(
            id: row["id"], title: row["title"], status: FitnessWorkoutStatus(rawValue: row["status"]) ?? .active,
            startedAt: FitnessDatabase.date(row["started_at"]) ?? .distantPast,
            endedAt: FitnessDatabase.date(row["ended_at"]), plannedSessionId: row["planned_session_id"],
            readiness: row["readiness"], sessionRPE: row["session_rpe"], performance: row["performance"],
            note: row["note"], revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            localTimezone: row["local_timezone"] ?? TimeZone.current.identifier,
            restTimerDeadline: FitnessDatabase.date(row["rest_timer_deadline_utc"]),
            bodyweightKgSnapshot: row["bodyweight_kg_snapshot"], bodyweightSource: row["bodyweight_source"],
            matchedPlanKey: row["matched_plan_key"]
        )
    }

    static func sessionExercise(_ row: Row) -> FitnessSessionExercise {
        FitnessSessionExercise(
            id: row["id"], sessionId: row["session_id"], exerciseId: row["exercise_id"],
            exerciseName: row["exercise_name"], setupId: row["setup_id"], setupName: row["setup_name"],
            position: row["position"], revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            plannedExerciseId: row["planned_exercise_id"],
            setupLoadModeSnapshot: row["setup_load_entry_mode_snapshot"] ?? "total_external",
            repCountModeSnapshot: row["rep_count_mode_snapshot"] ?? "total",
            unilateralModeSnapshot: row["unilateral_mode_snapshot"] ?? "bilateral",
            supersetGroupKey: row["superset_group_key"], variationNote: row["variation_note"], notes: row["notes"]
        )
    }

    static func group(_ row: Row) -> FitnessSetGroup {
        FitnessSetGroup(
            id: row["id"], sessionExerciseId: row["session_exercise_id"],
            role: FitnessSetRole(rawValue: row["role"]) ?? .other,
            structure: FitnessSetStructure(rawValue: row["structure_type"]) ?? .other,
            isAMRAP: (row["is_amrap"] as Int) != 0,
            failureState: FitnessFailureType(rawValue: row["failure_state"]) ?? .unknown,
            status: FitnessSetStatus(rawValue: row["status"]) ?? .completed,
            position: row["position"], revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            plannedSetId: row["planned_set_id"], startedAt: FitnessDatabase.date(row["started_at_utc"]),
            completedAt: FitnessDatabase.date(row["completed_at_utc"]), notes: row["notes"]
        )
    }

    static func component(_ row: Row) throws -> FitnessSetComponent {
        try FitnessSetComponent(
            id: row["id"], groupId: row["group_id"],
            status: FitnessComponentStatus(rawValue: row["status"]) ?? .completed,
            loadKg: row["load_kg"], reps: row["reps"],
            durationSeconds: row["duration_seconds"], distanceMetres: row["distance_metres"],
            rir: row["rir"], rpe: row["rpe"],
            completedAt: FitnessDatabase.date(row["completed_at"]), position: row["position"],
            revision: row["revision"], updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            repsLeft: row["reps_left"], repsRight: row["reps_right"], loadValue: row["load_value"],
            loadUnit: row["load_unit"], loadEntryModeSnapshot: row["load_entry_mode_snapshot"],
            normalizedExternalLoadKg: row["normalized_external_load_kg"], addedLoadKg: row["added_load_kg"],
            assistanceKg: row["assistance_kg"], bodyweightKgSnapshot: row["bodyweight_kg_snapshot"],
            restBeforeSeconds: row["rest_before_s"], tempoText: row["tempo_text"], notes: row["notes"],
            extraMetrics: decodeJSONDictionary(row["extra_metrics_json"])
        )
    }

    static func bodyIssue(_ row: Row) -> FitnessBodyIssue {
        FitnessBodyIssue(
            id: row["id"], sessionId: row["session_id"], issueTypeKey: row["issue_type_key"],
            bodyLocationKey: row["body_location_key"], side: row["side"], severity: row["severity"],
            timing: row["timing"], changedSession: (row["changed_session"] as Int) != 0,
            sessionChangeKey: row["session_change_key"], note: row["note"],
            observedAt: FitnessDatabase.date(row["observed_at"]) ?? .distantPast,
            resolvedAt: FitnessDatabase.date(row["resolved_at"]), revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            plannedSessionId: row["planned_session_id"], sessionExerciseId: row["session_exercise_id"],
            setGroupId: row["set_group_id"], checkinId: row["checkin_id"],
            trendKey: row["trend_key"] ?? "unknown", status: row["status"] ?? "active"
        )
    }

    static func dateOnly(_ date: Date) -> String {
        ISODateParser.stringUTCDateOnly(from: date)
    }

    static func localDateOnly(_ date: Date) -> String {
        ISODateParser.stringDateOnly(from: date)
    }

    static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func decodeStringArray(_ value: String?) throws -> [String] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([String].self, from: data)
    }

    static func decodeMuscleRoles(
        _ value: String?
    ) throws -> [FitnessExerciseMuscleRole] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([FitnessExerciseMuscleRole].self, from: data)
    }

    static func decodeJSONDictionary(
        _ value: String?
    ) throws -> [String: JSONValue] {
        guard let value, let data = value.data(using: .utf8) else { return [:] }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    static func serverLoadMode(_ mode: FitnessLoadMode) -> String {
        switch mode {
        case .total: "total_external"
        case .each: "per_hand"
        case .perSide: "per_side"
        case .machine: "machine_stack"
        case .level: "machine_level"
        case .bodyweight: "bodyweight_only"
        case .added: "added_bodyweight"
        case .assistance: "assistance"
        }
    }

    static func measurementMode(for mode: FitnessLoadMode) -> String {
        mode == .bodyweight ? "reps_only" : "reps_load"
    }

    static func localLoadMode(_ serverValue: String?) -> FitnessLoadMode {
        switch serverValue {
        case "per_hand": .each
        case "per_side": .perSide
        case "machine_stack": .machine
        case "machine_level": .level
        case "bodyweight_only", "none": .bodyweight
        case "added_bodyweight": .added
        case "assistance": .assistance
        default: .total
        }
    }

}
