import Foundation
import GRDB

/// This extension is isolated to FitnessRepository's single actor. Its context
/// is never used independently of that facade, preserving call-site serialization.
extension FitnessRepository {
    // MARK: Persistence coordination

    func enqueue<T: Encodable>(
        context: FitnessRepositoryContext,
        _ db: Database,
        type: FitnessEntityType,
        id: String,
        operation: FitnessMutationOperation = .upsert,
        baseRevision: Int?,
        payload: T,
        now: Date
    ) throws {
        let payloadData = try context.encode(payload)
        try db.execute(
            sql: """
                INSERT INTO fitness_outbox
                (mutation_id, entity_type, entity_id, operation, payload_schema_version,
                 base_revision, payload_json, created_at_client)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                UUID().uuidString, type.rawValue, id, operation.rawValue,
                FitnessContract.payloadSchemaVersion, baseRevision,
                String(decoding: payloadData, as: UTF8.self), FitnessDatabase.dateString(now),
            ]
        )
    }

    func insertFoodLog(
        context: FitnessRepositoryContext,
        _ entry: FitnessFoodLogEntry,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_food_log_entries
                (id, food_id, food_version_id, food_name, logged_at, nutrition_date, meal,
                 amount_grams, kcal, revision, client_updated_at, origin_device_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """,
            arguments: [
                entry.id, entry.foodId, entry.foodVersionId, entry.foodName,
                FitnessDatabase.dateString(entry.loggedAt), entry.nutritionDate, entry.meal.rawValue,
                entry.amountGrams, entry.kcal, FitnessDatabase.dateString(entry.updatedAt), try context.verifiedDeviceId(),
            ]
        )
    }

    func insertExercise(
        context: FitnessRepositoryContext,
        _ exercise: FitnessExercise,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_exercises
                (id, name, category, primary_muscle, is_favourite, is_custom, is_archived,
                 revision,client_updated_at,origin_device_id,seed_key,aliases_json,movement_pattern_key,
                 measurement_mode,rep_count_mode,load_entry_mode,default_unit,unilateral_mode,
                 equipment_type,bodyweight_involved,progression_direction,notes,active,
                 merged_into_exercise_id,muscle_roles_json,payload_json)
                VALUES (?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                exercise.id, exercise.name, exercise.category, exercise.primaryMuscle,
                exercise.isFavourite, exercise.isCustom, exercise.isArchived,
                FitnessDatabase.dateString(exercise.updatedAt), try context.verifiedDeviceId(), exercise.seedKey,
                try jsonString(.array(exercise.aliases.map(JSONValue.string))), exercise.movementPatternKey,
                exercise.measurementMode, exercise.repCountMode, exercise.loadEntryMode, exercise.defaultUnit,
                exercise.unilateralMode, exercise.equipmentType, exercise.bodyweightInvolved,
                exercise.progressionDirection, exercise.notes, exercise.active, exercise.mergedIntoExerciseId,
                try jsonString(
                    .array(
                        exercise.muscleRoles.map { role in
                            .object([
                                "muscle_group_key": .string(role.muscleGroupKey), "role": .string(role.role),
                                "contribution_weight": .double(role.contributionWeight),
                            ])
                        })), "{}",
            ]
        )
    }

    func insertSetup(
        context: FitnessRepositoryContext,
        _ setup: FitnessExerciseSetup,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_exercise_setups
                (id, exercise_id, name, load_mode, increment_kg, bar_weight_kg, is_default,
                 revision,client_updated_at,origin_device_id,location,equipment_identifier,
                 rep_count_mode,unilateral_mode,machine_base_load_kg,side_multiplier,notes,active,
                 merged_into_setup_id,payload_json)
                VALUES (?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                setup.id, setup.exerciseId, setup.name, setup.loadMode.rawValue,
                setup.incrementKg, setup.barWeightKg, setup.isDefault,
                FitnessDatabase.dateString(setup.updatedAt), try context.verifiedDeviceId(), setup.location,
                setup.equipmentIdentifier, setup.repCountMode, setup.unilateralMode,
                setup.machineBaseLoadKg, setup.sideMultiplier, setup.notes, setup.active,
                setup.mergedIntoSetupId, "{}",
            ]
        )
    }

    func insertSession(
        context: FitnessRepositoryContext,
        _ session: FitnessStrengthSession,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_strength_sessions
                (id, title, status, started_at, ended_at, planned_session_id, readiness,
                 session_rpe,performance,note,revision,client_updated_at,origin_device_id,
                 local_timezone,rest_timer_deadline_utc,bodyweight_kg_snapshot,bodyweight_source,
                 matched_plan_key,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                session.id, session.title, session.status.rawValue,
                FitnessDatabase.dateString(session.startedAt), session.endedAt.map(FitnessDatabase.dateString),
                session.plannedSessionId, session.readiness, session.sessionRPE, session.performance,
                session.note, FitnessDatabase.dateString(session.updatedAt), try context.verifiedDeviceId(), session.localTimezone,
                session.restTimerDeadline.map(FitnessDatabase.dateString), session.bodyweightKgSnapshot,
                session.bodyweightSource, session.matchedPlanKey, "{}",
            ]
        )
    }

    @discardableResult
    func insertSessionExercise(
        context: FitnessRepositoryContext,
        sessionId: String,
        exerciseId: String,
        exerciseName: String,
        setupId: String,
        setupName: String,
        position: Int,
        plannedExerciseId: String? = nil,
        setupLoadModeSnapshot: String = "total_external",
        repCountModeSnapshot: String = "total",
        unilateralModeSnapshot: String = "bilateral",
        db: Database,
        now: Date
    ) throws -> FitnessSessionExercise {
        let value = FitnessSessionExercise(
            id: UUID().uuidString,
            sessionId: sessionId,
            exerciseId: exerciseId,
            exerciseName: exerciseName,
            setupId: setupId,
            setupName: setupName,
            position: position,
            revision: 0, updatedAt: now, plannedExerciseId: plannedExerciseId,
            setupLoadModeSnapshot: setupLoadModeSnapshot, repCountModeSnapshot: repCountModeSnapshot,
            unilateralModeSnapshot: unilateralModeSnapshot
        )
        try db.execute(
            sql: """
                INSERT INTO fitness_strength_session_exercises
                (id, session_id, exercise_id, exercise_name, setup_id, setup_name, position,
                 revision,client_updated_at,origin_device_id,planned_exercise_id,
                 setup_load_entry_mode_snapshot,rep_count_mode_snapshot,unilateral_mode_snapshot,payload_json)
                VALUES (?,?,?,?,?,?,?,0,?,?,?,?,?,?,?)
                """,
            arguments: [
                value.id, sessionId, exerciseId, exerciseName, setupId, setupName,
                position, FitnessDatabase.dateString(now), try context.verifiedDeviceId(), plannedExerciseId,
                setupLoadModeSnapshot, repCountModeSnapshot, unilateralModeSnapshot, "{}",
            ]
        )
        try enqueue(
            context: context,
            db,
            type: .strengthSessionExercise,
            id: value.id,
            baseRevision: nil,
            payload: SessionExercisePayload(
                id: value.id, activityId: sessionId, exerciseId: exerciseId,
                exerciseSetupId: setupId, plannedExerciseId: plannedExerciseId, sequence: position,
                exerciseSetupLabelSnapshot: setupName,
                exerciseSetupLoadEntryModeSnapshot: setupLoadModeSnapshot,
                unilateralModeSnapshot: unilateralModeSnapshot
            ),
            now: now
        )
        return value
    }

    func insertGroup(
        context: FitnessRepositoryContext,
        _ group: FitnessSetGroup,
        sessionId: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_strength_set_groups
                (id, session_exercise_id, role, structure_type, is_amrap, failure_state, status, position,
                 revision,client_updated_at,origin_device_id,planned_set_id,started_at_utc,
                 completed_at_utc,notes,payload_json)
                VALUES (?,?,?,?,?,?,?,?,0,?,?,?,?,?,?,?)
                """,
            arguments: [
                group.id, group.sessionExerciseId, group.role.rawValue, group.structure.rawValue,
                group.isAMRAP, group.failureState.rawValue, group.status.rawValue, group.position,
                FitnessDatabase.dateString(group.updatedAt), try context.verifiedDeviceId(), group.plannedSetId,
                group.startedAt.map(FitnessDatabase.dateString), group.completedAt.map(FitnessDatabase.dateString),
                group.notes, "{}",
            ]
        )
        try enqueue(
            context: context,
            db,
            type: .strengthSetGroup,
            id: group.id,
            baseRevision: nil,
            payload: SetGroupPayload(group: group, activityId: sessionId),
            now: group.updatedAt
        )
    }

    func updateGroup(
        context: FitnessRepositoryContext,
        _ group: FitnessSetGroup,
        sessionId: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE fitness_strength_set_groups
                   SET role=?,structure_type=?,is_amrap=?,failure_state=?,status=?,
                       planned_set_id=?,started_at_utc=?,completed_at_utc=?,notes=?,client_updated_at=?
                 WHERE id=?
                """,
            arguments: [
                group.role.rawValue, group.structure.rawValue, group.isAMRAP, group.failureState.rawValue,
                group.status.rawValue, group.plannedSetId, group.startedAt.map(FitnessDatabase.dateString),
                group.completedAt.map(FitnessDatabase.dateString), group.notes,
                FitnessDatabase.dateString(group.updatedAt), group.id,
            ]
        )
        try enqueue(
            context: context,
            db, type: .strengthSetGroup, id: group.id, baseRevision: group.revision,
            payload: SetGroupPayload(group: group, activityId: sessionId), now: group.updatedAt
        )
    }

    func insertComponent(
        context: FitnessRepositoryContext,
        _ component: FitnessSetComponent,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_strength_set_components
                (id, group_id, status, load_kg, reps, duration_seconds, distance_metres, rir, rpe,
                 completed_at,position,revision,client_updated_at,origin_device_id,reps_left,reps_right,
                 load_value,load_unit,load_entry_mode_snapshot,normalized_external_load_kg,added_load_kg,
                 assistance_kg,bodyweight_kg_snapshot,rest_before_s,tempo_text,notes,extra_metrics_json,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                component.id, component.groupId, component.status.rawValue, component.loadKg, component.reps,
                component.durationSeconds, component.distanceMetres, component.rir, component.rpe,
                component.completedAt.map(FitnessDatabase.dateString), component.position,
                FitnessDatabase.dateString(component.updatedAt), try context.verifiedDeviceId(), component.repsLeft, component.repsRight,
                component.loadValue, component.loadUnit, component.loadEntryModeSnapshot,
                component.normalizedExternalLoadKg, component.addedLoadKg, component.assistanceKg,
                component.bodyweightKgSnapshot, component.restBeforeSeconds, component.tempoText, component.notes,
                try jsonString(.object(component.extraMetrics)), "{}",
            ]
        )
        try enqueue(
            context: context,
            db,
            type: .strengthSetComponent,
            id: component.id,
            baseRevision: nil,
            payload: SetComponentPayload(component: component),
            now: component.updatedAt
        )
    }

    func insertReadiness(
        context: FitnessRepositoryContext,
        _ value: Int?,
        energy: Int?,
        soreness: Int?,
        motivation: Int?,
        sessionId: String,
        planId: String?,
        retrospective: Bool,
        db: Database,
        now: Date
    ) throws {
        let readiness = value.map { min(5, max(1, $0)) }
        let safeEnergy = energy.map { min(5, max(1, $0)) }
        let safeSoreness = soreness.map { min(5, max(1, $0)) }
        let safeMotivation = motivation.map { min(5, max(1, $0)) }
        let id = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO fitness_session_checkins
                (id,session_id,kind,value,recorded_at,retrospective,revision,client_updated_at,
                 origin_device_id,planned_session_id,timing,captured_before_activity_start,
                 energy_1_5,soreness_1_5,motivation_1_5,payload_json)
                VALUES (?,?,'readiness',?,?,?,0,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                id, sessionId, readiness, FitnessDatabase.dateString(now), retrospective,
                FitnessDatabase.dateString(now), try context.verifiedDeviceId(), planId, "pre", !retrospective,
                safeEnergy, safeSoreness, safeMotivation,
                try jsonString(
                    .object([
                        "id": .string(id), "activity_id": .string(sessionId), "timing": .string("pre"),
                        "capture_quality": .string(retrospective ? "retrospective" : "contemporaneous"),
                    ])),
            ]
        )
        if let readiness {
            try db.execute(
                sql: "UPDATE fitness_strength_sessions SET readiness = ?, client_updated_at = ? WHERE id = ?",
                arguments: [readiness, FitnessDatabase.dateString(now), sessionId]
            )
        }
        try enqueue(
            context: context,
            db,
            type: .sessionCheckin,
            id: id,
            baseRevision: nil,
            payload: CheckinPayload(
                id: id, plannedSessionId: planId, activityId: sessionId, timing: "pre", capturedAtUtc: now,
                captureQuality: retrospective ? "retrospective" : "contemporaneous",
                capturedBeforeActivityStart: !retrospective,
                readiness1To5: readiness, energy1To5: safeEnergy, soreness1To5: safeSoreness,
                motivation1To5: safeMotivation, sessionRpe1To10: nil,
                perceivedPerformance1To5: nil, matchedPlanKey: nil, notes: nil
            ),
            now: now
        )
    }

    func insertBodyIssue(
        context: FitnessRepositoryContext,
        _ issue: NewBodyIssue,
        id: String,
        sessionId: String?,
        db: Database,
        now: Date
    ) throws {
        let validTypes = Set(FitnessBodyIssueType.allCases.map(\.rawValue))
        let validSides = Set(FitnessBodyIssueSide.allCases.map(\.rawValue))
        let validTimings = Set(FitnessBodyIssueTiming.allCases.map(\.rawValue))
        let validChanges = Set(FitnessBodyIssueSessionChange.allCases.map(\.rawValue))
        guard validTypes.contains(issue.issueTypeKey), validSides.contains(issue.side),
            validTimings.contains(issue.timing), validChanges.contains(issue.sessionChangeKey),
            !issue.bodyLocationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (0...10).contains(issue.severity), ["new", "existing_same", "worse", "better", "unknown"].contains(issue.trendKey),
            ["active", "resolved", "unknown"].contains(issue.status)
        else {
            throw FitnessRepositoryError.invalidStrengthEntry
        }
        let changeKey =
            issue.changedSession
            ? (issue.sessionChangeKey == "none" ? "other" : issue.sessionChangeKey)
            : "none"
        try db.execute(
            sql: """
                INSERT INTO fitness_body_issues
                (id, session_id, issue_type_key, body_location_key, side, severity, timing,
                 changed_session, session_change_key, note, observed_at, revision,
                 client_updated_at,origin_device_id,planned_session_id,session_exercise_id,
                 set_group_id,checkin_id,trend_key,status,resolved_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                id, sessionId, issue.issueTypeKey, issue.bodyLocationKey, issue.side,
                min(10, max(0, issue.severity)), issue.timing, issue.changedSession,
                changeKey, Self.trimmedOrNil(issue.note), FitnessDatabase.dateString(now),
                FitnessDatabase.dateString(now), try context.verifiedDeviceId(), issue.plannedSessionId, issue.sessionExerciseId,
                issue.setGroupId, issue.checkinId, issue.trendKey, issue.status,
                issue.resolvedAt.map(FitnessDatabase.dateString), "{}",
            ]
        )
        try enqueue(
            context: context,
            db,
            type: .bodyIssue,
            id: id,
            baseRevision: nil,
            payload: BodyIssuePayload(
                id: id, plannedSessionId: issue.plannedSessionId, activityId: sessionId,
                sessionExerciseId: issue.sessionExerciseId, setGroupId: issue.setGroupId,
                checkinId: issue.checkinId, observedAtUtc: now,
                timing: issue.timing,
                issueTypeKey: issue.issueTypeKey, bodyLocationKey: issue.bodyLocationKey,
                side: issue.side, severity0To10: min(10, max(0, issue.severity)),
                changedSession: issue.changedSession, sessionChangeKey: changeKey,
                trendKey: issue.trendKey, status: issue.status, resolvedAtUtc: issue.resolvedAt,
                notes: Self.trimmedOrNil(issue.note)
            ),
            now: now
        )
    }

    func sessionId(forGroup groupId: String, db: Database) throws -> String {
        guard
            let id = try String.fetchOne(
                db,
                sql: """
                    SELECT e.session_id FROM fitness_strength_set_groups g
                    JOIN fitness_strength_session_exercises e ON e.id = g.session_exercise_id
                    WHERE g.id = ?
                    """,
                arguments: [groupId]
            )
        else { throw FitnessRepositoryError.missingSetGroup }
        return id
    }

    func resolvedId(type: FitnessEntityType, id: String, db: Database) throws -> String {
        var current = id
        var visited = Set<String>()
        for _ in 0..<8 {
            guard visited.insert(current).inserted else { break }
            guard
                let target = try String.fetchOne(
                    db,
                    sql: "SELECT target_id FROM fitness_redirects WHERE entity_type=? AND source_id=?",
                    arguments: [type.rawValue, current]
                )
            else { break }
            current = target
        }
        return current
    }

}
