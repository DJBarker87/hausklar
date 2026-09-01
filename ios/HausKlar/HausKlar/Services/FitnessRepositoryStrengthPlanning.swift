import Foundation
import GRDB

/// This extension is isolated to FitnessRepository's single actor. Its context
/// is never used independently of that facade, preserving call-site serialization.
extension FitnessRepository {
    func existingPlanItems(planId: String, db: Database) throws -> [PlannedExercisePayload] {
        let exercises = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM fitness_planned_session_exercises
                WHERE planned_session_id=? AND deleted_at IS NULL ORDER BY position
                """, arguments: [planId]
        )
        let setRows = try Row.fetchAll(
            db,
            sql: """
                SELECT ps.* FROM fitness_planned_sets ps
                JOIN fitness_planned_session_exercises pe ON pe.id=ps.planned_exercise_id
                WHERE pe.planned_session_id=? AND pe.deleted_at IS NULL
                  AND ps.deleted_at IS NULL
                ORDER BY ps.planned_exercise_id,ps.position
                """, arguments: [planId]
        )
        var setsByExercise: [String: [PlannedSetPayload]] = [:]
        for set in setRows {
            let exerciseId: String = set["planned_exercise_id"]
            setsByExercise[exerciseId, default: []].append(
                PlannedSetPayload(
                    id: set["id"], sequence: set["position"],
                    trainingRole: set["training_role"], structureType: set["structure_type"],
                    componentCount: set["component_count"], repsMin: set["reps_min"], repsMax: set["reps_max"],
                    loadMin: set["load_min"], loadMax: set["load_max"], loadUnit: set["load_unit"],
                    rpeMin: set["rpe_min"], rpeMax: set["rpe_max"], rirMin: set["rir_min"], rirMax: set["rir_max"],
                    restS: set["rest_seconds"], isAmrap: (set["is_amrap"] as Int) != 0, notes: set["notes"]
                )
            )
        }
        return try exercises.map { exercise in
            let exerciseId: String = exercise["id"]
            return PlannedExercisePayload(
                id: exerciseId, exerciseId: exercise["exercise_id"],
                exerciseSetupId: exercise["requested_setup_id"] ?? exercise["exercise_setup_id"],
                sequence: exercise["position"], supersetGroupKey: exercise["superset_group_key"],
                substitutionExerciseIds: try Self.decodeStringArray(
                    exercise["substitution_exercise_ids_json"]
                ),
                notes: exercise["notes"], plannedSets: setsByExercise[exerciseId] ?? []
            )
        }
    }

    func workoutVersionPlanItems(versionId: String, db: Database) throws -> [PlannedExercisePayload] {
        let exercises = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM fitness_workout_version_exercises
                WHERE workout_version_id=? ORDER BY position
                """, arguments: [versionId]
        )
        let setupRows = try Row.fetchAll(
            db,
            sql: """
                SELECT DISTINCT s.* FROM fitness_exercise_setups s
                JOIN fitness_workout_version_exercises ve ON ve.exercise_id=s.exercise_id
                WHERE ve.workout_version_id=? AND s.active=1 AND s.deleted_at IS NULL
                ORDER BY s.exercise_id,s.is_default DESC,s.client_updated_at DESC
                """, arguments: [versionId]
        )
        var defaultSetupByExercise: [String: String] = [:]
        for setup in setupRows {
            let exerciseId: String = setup["exercise_id"]
            if defaultSetupByExercise[exerciseId] == nil {
                defaultSetupByExercise[exerciseId] = setup["id"]
            }
        }
        let setRows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.* FROM fitness_workout_version_sets s
                JOIN fitness_workout_version_exercises ve ON ve.id=s.workout_version_exercise_id
                WHERE ve.workout_version_id=?
                ORDER BY s.workout_version_exercise_id,s.position
                """, arguments: [versionId]
        )
        var setsByExercise: [String: [PlannedSetPayload]] = [:]
        for set in setRows {
            let sourceId: String = set["workout_version_exercise_id"]
            setsByExercise[sourceId, default: []].append(
                PlannedSetPayload(
                    id: UUID().uuidString, sequence: set["position"],
                    trainingRole: set["training_role"], structureType: set["structure_type"],
                    componentCount: set["component_count"], repsMin: set["reps_min"], repsMax: set["reps_max"],
                    loadMin: set["load_min"], loadMax: set["load_max"], loadUnit: set["load_unit"],
                    rpeMin: set["rpe_min"], rpeMax: set["rpe_max"], rirMin: set["rir_min"], rirMax: set["rir_max"],
                    restS: set["rest_seconds"], isAmrap: (set["is_amrap"] as Int) != 0, notes: set["notes"]
                )
            )
        }
        return try exercises.map { exercise in
            let sourceId: String = exercise["id"]
            let plannedExerciseId = UUID().uuidString
            let explicitSetupId: String? = exercise["exercise_setup_id"]
            let exerciseId: String = exercise["exercise_id"]
            let setupId = explicitSetupId ?? defaultSetupByExercise[exerciseId]
            guard let setupId else { throw FitnessRepositoryError.missingSetup }
            return PlannedExercisePayload(
                id: plannedExerciseId, exerciseId: exerciseId, exerciseSetupId: setupId,
                sequence: exercise["position"], supersetGroupKey: exercise["superset_group_key"],
                substitutionExerciseIds: try Self.decodeStringArray(
                    exercise["substitution_exercise_ids_json"]
                ),
                notes: exercise["notes"], plannedSets: setsByExercise[sourceId] ?? []
            )
        }
    }

    func replacePlanItems(
        planId: String, items: [PlannedExercisePayload], now: Date, db: Database
    ) throws {
        let timestamp = FitnessDatabase.dateString(now)
        let existingIds = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM fitness_planned_session_exercises
                WHERE planned_session_id=? AND deleted_at IS NULL
                """, arguments: [planId]
        )
        for id in existingIds {
            try db.execute(
                sql: "UPDATE fitness_planned_sets SET deleted_at=?,client_updated_at=? WHERE planned_exercise_id=? AND deleted_at IS NULL",
                arguments: [timestamp, timestamp, id]
            )
        }
        try db.execute(
            sql:
                "UPDATE fitness_planned_session_exercises SET deleted_at=?,client_updated_at=? WHERE planned_session_id=? AND deleted_at IS NULL",
            arguments: [timestamp, timestamp, planId]
        )
        for item in items {
            try db.execute(
                sql: """
                    INSERT INTO fitness_planned_session_exercises
                    (id,planned_session_id,exercise_id,exercise_setup_id,position,superset_group_key,
                     notes,client_updated_at,deleted_at,requested_setup_id,substitution_exercise_ids_json)
                    VALUES (?,?,?,?,?,?,?,?,NULL,?,?)
                    """,
                arguments: [
                    item.id, planId, item.exerciseId, item.exerciseSetupId, item.sequence,
                    item.supersetGroupKey, item.notes, timestamp, item.exerciseSetupId,
                    try jsonString(.array(item.substitutionExerciseIds.map(JSONValue.string))),
                ]
            )
            for set in item.plannedSets {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_planned_sets
                        (id,planned_exercise_id,position,training_role,structure_type,component_count,
                         reps_min,reps_max,load_min,load_max,load_unit,rpe_min,rpe_max,rir_min,rir_max,
                         rest_seconds,is_amrap,notes,client_updated_at,deleted_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
                        """,
                    arguments: [
                        set.id, item.id, set.sequence, set.trainingRole, set.structureType, set.componentCount,
                        set.repsMin, set.repsMax, set.loadMin, set.loadMax, set.loadUnit, set.rpeMin, set.rpeMax,
                        set.rirMin, set.rirMax, set.restS, set.isAmrap, set.notes, timestamp,
                    ]
                )
            }
        }
    }

    func validateStrengthPlan(_ draft: FitnessStrengthPlanDraft) throws {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !name.isEmpty, !draft.exercises.isEmpty,
            Set(draft.exercises.map(\.exerciseId)).count == draft.exercises.count,
            ["private", "logistics_shared"].contains(draft.visibility),
            (0...100).contains(draft.priority),
            draft.expectedDurationSeconds.map({ $0 >= 0 }) ?? true,
            draft.visibility != "logistics_shared"
                || draft.sharedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            draft.primaryGoalId.map({ !draft.secondaryGoalIds.contains($0) }) ?? true,
            Set(draft.secondaryGoalIds).count == draft.secondaryGoalIds.count
        else {
            throw FitnessRepositoryError.invalidStrengthPlan
        }
        if let start = draft.timeWindowStart, let end = draft.timeWindowEnd, end <= start {
            throw FitnessRepositoryError.invalidStrengthPlan
        }
        for exercise in draft.exercises {
            guard !exercise.sets.isEmpty, exercise.sets.count <= 30,
                Set(exercise.substitutionExerciseIds).count == exercise.substitutionExerciseIds.count,
                !exercise.substitutionExerciseIds.contains(exercise.exerciseId)
            else {
                throw FitnessRepositoryError.invalidStrengthPlan
            }
            for set in exercise.sets {
                let finite = [set.loadMin, set.loadMax, set.rpeMin, set.rpeMax, set.rirMin, set.rirMax]
                    .allSatisfy({ value in
                        value.map({ $0.isFinite && $0 >= 0 }) ?? true
                    })
                guard finite, (1...20).contains(set.componentCount),
                    set.repsMin.map({ $0 >= 0 }) ?? true,
                    set.repsMax.map({ $0 >= 0 }) ?? true,
                    set.restSeconds.map({ $0 >= 0 }) ?? true,
                    set.repsMin.map({ low in
                        set.repsMax.map({ $0 >= low }) ?? true
                    }) ?? true,
                    set.loadMin.map({ low in
                        set.loadMax.map({ $0 >= low }) ?? true
                    }) ?? true,
                    set.rpeMax.map({ $0 <= 10 }) ?? true,
                    set.rirMax.map({ $0 <= 10 }) ?? true
                else {
                    throw FitnessRepositoryError.invalidStrengthPlan
                }
            }
        }
    }

    func resolvedPlanExercises(
        _ items: [FitnessStrengthPlanExerciseDraft], db: Database
    ) throws -> [ResolvedStrengthPlanExercise] {
        let redirectRows = try Row.fetchAll(
            db,
            sql: """
                SELECT entity_type,source_id,target_id FROM fitness_redirects
                WHERE entity_type IN (?,?)
                """,
            arguments: [
                FitnessEntityType.exercise.rawValue,
                FitnessEntityType.exerciseSetup.rawValue,
            ]
        )
        var redirects: [String: [String: String]] = [:]
        for row in redirectRows {
            let type: String = row["entity_type"]
            redirects[type, default: [:]][row["source_id"]] = row["target_id"]
        }
        func resolve(_ type: FitnessEntityType, _ id: String) -> String {
            var current = id
            var visited = Set<String>()
            for _ in 0..<8 {
                guard visited.insert(current).inserted,
                    let target = redirects[type.rawValue]?[current]
                else { break }
                current = target
            }
            return current
        }
        let resolved = items.map { item in
            ResolvedStrengthPlanExercise(
                exerciseId: resolve(.exercise, item.exerciseId),
                setupId: resolve(.exerciseSetup, item.setupId),
                substitutionIds: item.substitutionExerciseIds.map { resolve(.exercise, $0) },
                sets: item.sets
            )
        }
        let setupIds = Array(Set(resolved.map(\.setupId))).sorted()
        guard !setupIds.isEmpty else { throw FitnessRepositoryError.missingSetup }
        let placeholders = Array(repeating: "?", count: setupIds.count).joined(separator: ",")
        let setupRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id,exercise_id FROM fitness_exercise_setups
                WHERE id IN (\(placeholders)) AND active=1 AND deleted_at IS NULL
                """, arguments: StatementArguments(setupIds)
        )
        var exerciseBySetup: [String: String] = [:]
        for setup in setupRows { exerciseBySetup[setup["id"]] = setup["exercise_id"] }
        guard resolved.allSatisfy({ exerciseBySetup[$0.setupId] == $0.exerciseId }) else {
            throw FitnessRepositoryError.missingSetup
        }
        return resolved
    }

    func plannedSetPayload(
        _ set: FitnessStrengthPlanSetDraft, sequence: Int, id: String? = nil
    ) -> PlannedSetPayload {
        PlannedSetPayload(
            id: id ?? set.id, sequence: sequence, trainingRole: set.role.rawValue,
            structureType: set.structure.rawValue, componentCount: set.componentCount,
            repsMin: set.repsMin, repsMax: set.repsMax, loadMin: set.loadMin,
            loadMax: set.loadMax, loadUnit: set.loadUnit, rpeMin: set.rpeMin,
            rpeMax: set.rpeMax, rirMin: set.rirMin, rirMax: set.rirMax,
            restS: set.restSeconds, isAmrap: set.isAMRAP, notes: set.notes
        )
    }

    func insertWorkoutVersionSet(
        _ set: FitnessStrengthPlanSetDraft,
        workoutVersionExerciseId: String,
        position: Int,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_workout_version_sets
                (id,workout_version_exercise_id,position,training_role,structure_type,
                 component_count,reps_min,reps_max,load_min,load_max,load_unit,rpe_min,
                 rpe_max,rir_min,rir_max,rest_seconds,is_amrap,notes)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                set.id, workoutVersionExerciseId, position, set.role.rawValue, set.structure.rawValue,
                set.componentCount, set.repsMin, set.repsMax, set.loadMin, set.loadMax, set.loadUnit,
                set.rpeMin, set.rpeMax, set.rirMin, set.rirMax, set.restSeconds, set.isAMRAP, set.notes,
            ]
        )
    }

    private func strengthVersionExerciseDrafts(
        versionId: String, db: Database
    ) throws -> [FitnessStrengthPlanExerciseDraft] {
        let exercises = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM fitness_workout_version_exercises
                WHERE workout_version_id=? ORDER BY position
                """, arguments: [versionId]
        )
        let setRows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.* FROM fitness_workout_version_sets s
                JOIN fitness_workout_version_exercises ve ON ve.id=s.workout_version_exercise_id
                WHERE ve.workout_version_id=?
                ORDER BY s.workout_version_exercise_id,s.position
                """, arguments: [versionId]
        )
        var setsByExercise: [String: [FitnessStrengthPlanSetDraft]] = [:]
        for set in setRows {
            let itemId: String = set["workout_version_exercise_id"]
            setsByExercise[itemId, default: []].append(
                FitnessStrengthPlanSetDraft(
                    id: set["id"], role: FitnessSetRole(rawValue: set["training_role"]) ?? .working,
                    structure: FitnessSetStructure(rawValue: set["structure_type"]) ?? .straight,
                    componentCount: set["component_count"], repsMin: set["reps_min"],
                    repsMax: set["reps_max"], loadMin: set["load_min"], loadMax: set["load_max"],
                    loadUnit: set["load_unit"], rpeMin: set["rpe_min"], rpeMax: set["rpe_max"],
                    rirMin: set["rir_min"], rirMax: set["rir_max"], restSeconds: set["rest_seconds"],
                    isAMRAP: (set["is_amrap"] as Int) != 0, notes: set["notes"]
                )
            )
        }
        return try exercises.map { exercise in
            let itemId: String = exercise["id"]
            return FitnessStrengthPlanExerciseDraft(
                id: itemId, exerciseId: exercise["exercise_id"],
                setupId: exercise["exercise_setup_id"],
                substitutionExerciseIds: try Self.decodeStringArray(
                    exercise["substitution_exercise_ids_json"]
                ),
                supersetGroupKey: exercise["superset_group_key"], notes: exercise["notes"],
                sets: setsByExercise[itemId] ?? []
            )
        }
    }

    func insertStrengthPlannedSession(
        _ draft: FitnessStrengthPlanDraft,
        workoutVersionId: String?,
        db: Database,
        now: Date,
        resolvedExercises providedResolvedExercises: [ResolvedStrengthPlanExercise]? = nil
    ) throws -> FitnessPlannedSession {
        try validateStrengthPlan(draft)
        let resolvedExercises: [ResolvedStrengthPlanExercise]
        if let providedResolvedExercises,
            providedResolvedExercises.count == draft.exercises.count
        {
            resolvedExercises = providedResolvedExercises
        } else {
            resolvedExercises = try resolvedPlanExercises(draft.exercises, db: db)
        }
        let id = UUID().uuidString
        let scheduled = draft.scheduledStart != nil || draft.timeWindowStart != nil
        let status = scheduled ? "scheduled" : "accepted"
        var payloadItems: [PlannedExercisePayload] = []
        for index in draft.exercises.indices {
            let item = draft.exercises[index]
            let resolved = resolvedExercises[index]
            let plannedExerciseId = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO fitness_planned_session_exercises
                    (id,planned_session_id,exercise_id,exercise_setup_id,position,superset_group_key,
                     notes,client_updated_at,requested_setup_id,substitution_exercise_ids_json,payload_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    plannedExerciseId, id, resolved.exerciseId, resolved.setupId, index,
                    item.supersetGroupKey, item.notes, FitnessDatabase.dateString(now), resolved.setupId,
                    try jsonString(.array(resolved.substitutionIds.map(JSONValue.string))), "{}",
                ]
            )
            var setPayloads: [PlannedSetPayload] = []
            for (setIndex, set) in resolved.sets.enumerated() {
                let setId = UUID().uuidString
                try db.execute(
                    sql: """
                        INSERT INTO fitness_planned_sets
                        (id,planned_exercise_id,position,training_role,structure_type,component_count,
                         reps_min,reps_max,load_min,load_max,load_unit,rpe_min,rpe_max,rir_min,rir_max,
                         rest_seconds,is_amrap,notes,client_updated_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                    arguments: [
                        setId, plannedExerciseId, setIndex, set.role.rawValue, set.structure.rawValue,
                        set.componentCount, set.repsMin, set.repsMax, set.loadMin, set.loadMax, set.loadUnit,
                        set.rpeMin, set.rpeMax, set.rirMin, set.rirMax, set.restSeconds, set.isAMRAP,
                        set.notes, FitnessDatabase.dateString(now),
                    ]
                )
                setPayloads.append(plannedSetPayload(set, sequence: setIndex, id: setId))
            }
            payloadItems.append(
                PlannedExercisePayload(
                    id: plannedExerciseId, exerciseId: resolved.exerciseId,
                    exerciseSetupId: resolved.setupId, sequence: index,
                    supersetGroupKey: item.supersetGroupKey,
                    substitutionExerciseIds: resolved.substitutionIds, notes: item.notes,
                    plannedSets: setPayloads
                )
            )
        }
        let goalLinks =
            (draft.primaryGoalId.map { [StrengthPlanGoalLinkPayload(goalId: $0, role: "primary")] } ?? [])
            + draft.secondaryGoalIds.map { StrengthPlanGoalLinkPayload(goalId: $0, role: "secondary") }
        let payload = DetailedPlannedSessionPayload(
            id: id, sportKey: "strength", title: draft.title,
            localTimezone: TimeZone.current.identifier,
            trainingProgrammeId: draft.trainingProgrammeId, workoutVersionId: workoutVersionId,
            status: status, sessionSource: "user", scheduledStartUtc: draft.scheduledStart,
            scheduledDate: nil, timeWindowStartUtc: draft.timeWindowStart,
            timeWindowEndUtc: draft.timeWindowEnd, expectedDurationS: draft.expectedDurationSeconds,
            expectedDistanceM: nil, expectedPaceSPerKm: nil,
            priority: draft.priority, movable: draft.movable,
            visibility: draft.visibility, sharedTitle: draft.sharedTitle,
            reasonForPlacement: draft.reasonForPlacement,
            completionActivityId: nil, completionState: nil, goalLinks: goalLinks,
            exerciseItems: payloadItems,
            gearLinks: draft.intendedGearIds.map { .init(gearId: $0, role: "primary") },
            intendedGearIds: draft.intendedGearIds
        )
        let payloadJSON = String(decoding: try context.encode(payload), as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO fitness_planned_sessions
                (id,title,planned_for,is_completed,training_programme_id,workout_version_id,revision,
                 client_updated_at,origin_device_id,status,available_window_minutes,intended_gear,
                 payload_json,sport_key,time_window_start_utc,time_window_end_utc,
                 expected_duration_s,intended_gear_ids_json,deleted_at)
                VALUES (?,?,?,0,?,?,0,?,?,?, ?,NULL,?,'strength',?,?,?,?,NULL)
                """,
            arguments: [
                id, draft.title, draft.scheduledStart.map(FitnessDatabase.dateString),
                draft.trainingProgrammeId, workoutVersionId, FitnessDatabase.dateString(now), try context.verifiedDeviceId(), status,
                draft.timeWindowStart.flatMap { start in draft.timeWindowEnd.map { Int($0.timeIntervalSince(start) / 60) } },
                payloadJSON, draft.timeWindowStart.map(FitnessDatabase.dateString),
                draft.timeWindowEnd.map(FitnessDatabase.dateString), draft.expectedDurationSeconds,
                try jsonString(.array(draft.intendedGearIds.map(JSONValue.string))),
            ]
        )
        try enqueue(context: context, db, type: .plannedSession, id: id, baseRevision: nil, payload: payload, now: now)
        return FitnessPlannedSession(
            id: id, title: draft.title, plannedFor: draft.scheduledStart,
            exerciseIds: draft.exercises.map(\.exerciseId), isCompleted: false,
            revision: 0, updatedAt: now, status: status,
            availableWindowMinutes: draft.timeWindowStart.flatMap { start in
                draft.timeWindowEnd.map { Int($0.timeIntervalSince(start) / 60) }
            }, sportKey: "strength", timeWindowStart: draft.timeWindowStart,
            timeWindowEnd: draft.timeWindowEnd,
            expectedDurationSeconds: draft.expectedDurationSeconds.map(Double.init),
            intendedGearIds: draft.intendedGearIds,
            trainingProgrammeId: draft.trainingProgrammeId, workoutVersionId: workoutVersionId
        )
    }

    static func validate(_ draft: FitnessStrengthSetDraft) throws {
        let nonnegative = [draft.loadValue, draft.distanceMetres, draft.rir, draft.rpe].allSatisfy {
            $0.map { $0.isFinite && $0 >= 0 } ?? true
        }
        let boundedEffort =
            draft.rir.map { $0 <= 10 } ?? true
            && (draft.rpe.map { $0 <= 10 } ?? true)
        let counts = [draft.reps, draft.repsLeft, draft.repsRight, draft.durationSeconds, draft.restBeforeSeconds]
            .allSatisfy { $0.map { $0 >= 0 } ?? true }
        let hasWork =
            (draft.reps ?? 0) > 0 || (draft.repsLeft ?? 0) > 0
            || (draft.repsRight ?? 0) > 0 || (draft.durationSeconds ?? 0) > 0
            || (draft.distanceMetres ?? 0) > 0
        guard nonnegative, boundedEffort, counts,
            draft.componentStatus == .skipped || hasWork
        else {
            throw FitnessRepositoryError.invalidStrengthEntry
        }
    }
}
