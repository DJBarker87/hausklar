import Foundation
import GRDB

/// This extension is isolated to FitnessRepository's single actor. Its context
/// is never used independently of that facade, preserving call-site serialization.
extension FitnessRepository {
    // MARK: Exercise library

    func exercises(search: String = "") throws -> [FitnessExercise] {
        try context.read { db in
            let term = "%\(search.trimmingCharacters(in: .whitespacesAndNewlines))%"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_exercises
                    WHERE deleted_at IS NULL AND is_archived = 0 AND active=1
                      AND (? = '%%' OR name LIKE ? OR category LIKE ? OR aliases_json LIKE ?)
                    ORDER BY is_favourite DESC, name COLLATE NOCASE
                    """,
                arguments: [term, term, term, term]
            ).map { try Self.exercise($0) }
        }
    }

    func setups(for exerciseId: String) throws -> [FitnessExerciseSetup] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_exercise_setups
                    WHERE exercise_id = ? AND active=1 AND deleted_at IS NULL ORDER BY is_default DESC, name
                    """,
                arguments: [exerciseId]
            ).map(Self.setup)
        }
    }

    @discardableResult
    func createExercise(name: String, category: String, loadMode: FitnessLoadMode) throws -> FitnessExercise {
        let now = Date()
        let exercise = FitnessExercise(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            primaryMuscle: nil,
            isFavourite: false,
            isCustom: true,
            isArchived: false,
            revision: 0, updatedAt: now, movementPatternKey: "other",
            measurementMode: Self.measurementMode(for: loadMode),
            loadEntryMode: Self.serverLoadMode(loadMode),
            defaultUnit: loadMode == .bodyweight ? "reps" : "kg",
            bodyweightInvolved: [.bodyweight, .added, .assistance].contains(loadMode)
        )
        let setup = FitnessExerciseSetup(
            id: UUID().uuidString,
            exerciseId: exercise.id,
            name: "Default",
            loadMode: loadMode,
            incrementKg: loadMode == .total ? 2.5 : nil,
            barWeightKg: loadMode == .total ? 20 : nil,
            isDefault: true,
            revision: 0, updatedAt: now,
            sideMultiplier: loadMode == .perSide ? 2 : nil
        )
        try context.write { db in
            try insertExercise(context: context, exercise, db: db)
            try insertSetup(context: context, setup, db: db)
            try enqueue(
                context: context,
                db,
                type: .exercise,
                id: exercise.id,
                baseRevision: nil,
                payload: ExercisePayload(
                    id: exercise.id, name: exercise.name, movementPatternKey: "other",
                    measurementMode: Self.measurementMode(for: loadMode),
                    repCountMode: "total", loadEntryMode: Self.serverLoadMode(loadMode),
                    defaultUnit: loadMode == .bodyweight ? "reps" : "kg",
                    bodyweightInvolved: [.bodyweight, .added, .assistance].contains(loadMode),
                    favourite: false, active: true
                ),
                now: now
            )
            try enqueue(
                context: context,
                db,
                type: .exerciseSetup,
                id: setup.id,
                baseRevision: nil,
                payload: SetupPayload(
                    id: setup.id,
                    exerciseId: exercise.id,
                    name: setup.name,
                    loadEntryMode: Self.serverLoadMode(loadMode),
                    repCountMode: "total",
                    barWeightKg: setup.barWeightKg,
                    sideMultiplier: loadMode == .perSide ? 2 : nil,
                    isDefault: true,
                    active: true
                ),
                now: now
            )
        }
        return exercise
    }

    // MARK: Live strength

    func activeWorkout(now: Date = Date()) throws -> FitnessStrengthSession? {
        try context.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM fitness_strength_sessions
                    WHERE status = 'active' AND deleted_at IS NULL LIMIT 1
                    """
            ) else { return nil }
            var session = Self.session(row)
            guard now.timeIntervalSince(session.startedAt) > 60 * 60 else {
                return session
            }
            let endedAt = session.startedAt.addingTimeInterval(60 * 60)
            session.status = .abandoned
            session.endedAt = endedAt
            session.restTimerDeadline = nil
            session.updatedAt = now
            try db.execute(
                sql: """
                    UPDATE fitness_strength_sessions
                    SET status='abandoned',ended_at=?,rest_timer_deadline_utc=NULL,
                        client_updated_at=? WHERE id=?
                    """,
                arguments: [
                    FitnessDatabase.dateString(endedAt),
                    FitnessDatabase.dateString(now),
                    session.id,
                ]
            )
            try enqueue(
                context: context,
                db,
                type: .strengthSession,
                id: session.id,
                baseRevision: session.revision,
                payload: StrengthSessionPayload(
                    id: session.id,
                    title: session.title,
                    startedAtUtc: session.startedAt,
                    localTimezone: session.localTimezone,
                    plannedSessionId: session.plannedSessionId,
                    status: "aborted",
                    endedAtUtc: endedAt,
                    sessionRpe: nil,
                    perceivedPerformance: nil,
                    notes: session.note,
                    restTimerDeadlineUtc: nil,
                    matchedPlanKey: session.matchedPlanKey
                ),
                now: now
            )
            if let planId = session.plannedSessionId {
                try db.execute(
                    sql: "UPDATE fitness_planned_sessions SET is_completed=1,client_updated_at=? WHERE id=?",
                    arguments: [FitnessDatabase.dateString(now), planId]
                )
            }
            return nil
        }
    }

    @discardableResult
    func recordPlannedReadiness(planId: String, value: Int) throws -> String {
        let now = Date()
        let safe = min(5, max(1, value))
        let id = UUID().uuidString
        try context.write { db in
            guard
                try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM fitness_planned_sessions WHERE id=? AND deleted_at IS NULL)",
                    arguments: [planId]
                ) == true
            else { throw FitnessRepositoryError.missingPlan }
            try db.execute(
                sql: """
                    INSERT INTO fitness_session_checkins
                    (id,session_id,kind,value,recorded_at,retrospective,revision,client_updated_at,
                     origin_device_id,planned_session_id,timing,captured_before_activity_start,payload_json)
                    VALUES (?,?,'readiness',?,?,0,0,?,?,?,'pre',1,?)
                    """,
                arguments: [
                    id, planId, safe, FitnessDatabase.dateString(now), FitnessDatabase.dateString(now),
                    try context.verifiedDeviceId(), planId,
                    try jsonString(
                        .object([
                            "id": .string(id), "planned_session_id": .string(planId),
                            "timing": .string("pre"), "capture_quality": .string("contemporaneous"),
                        ])),
                ]
            )
            try enqueue(
                context: context,
                db, type: .sessionCheckin, id: id, baseRevision: nil,
                payload: CheckinPayload(
                    id: id, plannedSessionId: planId, activityId: nil, timing: "pre", capturedAtUtc: now,
                    captureQuality: "contemporaneous", capturedBeforeActivityStart: true,
                    readiness1To5: safe, energy1To5: nil, soreness1To5: nil, motivation1To5: nil,
                    sessionRpe1To10: nil, perceivedPerformance1To5: nil, matchedPlanKey: nil, notes: nil
                ), now: now
            )
        }
        return id
    }

    func plannedReadiness(planId: String) throws -> Int? {
        try context.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT value FROM fitness_session_checkins
                    WHERE planned_session_id=? AND timing='pre' AND retrospective=0
                      AND captured_before_activity_start=1 AND value IS NOT NULL AND deleted_at IS NULL
                    ORDER BY recorded_at DESC LIMIT 1
                    """, arguments: [planId]
            )
        }
    }

    @discardableResult
    func startWorkout(
        title: String,
        planId: String? = nil,
        readiness: Int? = nil,
        energy: Int? = nil,
        soreness: Int? = nil,
        motivation: Int? = nil,
        bodyweight: FitnessBodyweightChoice = .unknown
    ) throws -> FitnessStrengthSession {
        let now = Date()
        if let kilograms = bodyweight.kilograms,
            !kilograms.isFinite || kilograms <= 0 || kilograms > 500
        {
            throw FitnessRepositoryError.invalidStrengthEntry
        }
        var session = FitnessStrengthSession(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Strength workout" : title,
            status: .active,
            startedAt: now,
            endedAt: nil,
            plannedSessionId: planId,
            readiness: readiness,
            sessionRPE: nil,
            performance: nil,
            note: nil,
            revision: 0, updatedAt: now,
            localTimezone: TimeZone.current.identifier,
            bodyweightKgSnapshot: bodyweight.kilograms,
            bodyweightSource: bodyweight.source.rawValue
        )
        try context.write { db in
            guard
                try String.fetchOne(
                    db,
                    sql: "SELECT id FROM fitness_strength_sessions WHERE status = 'active' AND deleted_at IS NULL LIMIT 1"
                ) == nil
            else { throw FitnessRepositoryError.workoutAlreadyActive }
            let existingCheckin: Row? = try planId.flatMap { planId in
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM fitness_session_checkins
                        WHERE planned_session_id=? AND timing='pre' AND retrospective=0
                          AND captured_before_activity_start=1 AND deleted_at IS NULL
                        ORDER BY recorded_at DESC LIMIT 1
                        """, arguments: [planId]
                )
            }
            if session.readiness == nil { session.readiness = existingCheckin?["value"] }
            try insertSession(context: context, session, db: db)
            try enqueue(
                context: context,
                db,
                type: .strengthSession,
                id: session.id,
                baseRevision: nil,
                payload: StrengthSessionPayload(
                    id: session.id,
                    title: session.title,
                    startedAtUtc: now,
                    localTimezone: TimeZone.current.identifier,
                    plannedSessionId: planId,
                    status: "in_progress",
                    endedAtUtc: nil,
                    sessionRpe: nil,
                    perceivedPerformance: nil,
                    notes: nil
                ),
                now: now
            )

            if let existingCheckin {
                let checkinId: String = existingCheckin["id"]
                try db.execute(
                    sql: "UPDATE fitness_session_checkins SET session_id=?,client_updated_at=? WHERE id=?",
                    arguments: [session.id, FitnessDatabase.dateString(now), checkinId]
                )
                try enqueue(
                    context: context,
                    db, type: .sessionCheckin, id: checkinId, baseRevision: existingCheckin["revision"],
                    payload: CheckinPayload(
                        id: checkinId, plannedSessionId: planId, activityId: session.id, timing: "pre",
                        capturedAtUtc: FitnessDatabase.date(existingCheckin["recorded_at"]) ?? now,
                        captureQuality: "contemporaneous", capturedBeforeActivityStart: true,
                        readiness1To5: session.readiness, energy1To5: existingCheckin["energy_1_5"],
                        soreness1To5: existingCheckin["soreness_1_5"], motivation1To5: existingCheckin["motivation_1_5"],
                        sessionRpe1To10: nil, perceivedPerformance1To5: nil, matchedPlanKey: nil,
                        notes: existingCheckin["note"]
                    ), now: now
                )
            } else if readiness != nil || energy != nil || soreness != nil || motivation != nil {
                try insertReadiness(
                    context: context,
                    readiness, energy: energy, soreness: soreness, motivation: motivation,
                    sessionId: session.id, planId: planId, retrospective: false, db: db, now: now
                )
            }

            if let planId {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                            SELECT pe.id AS planned_exercise_id,pe.exercise_id,pe.exercise_setup_id,
                                   e.name AS exercise_name
                            FROM fitness_planned_session_exercises pe
                            JOIN fitness_exercises e ON e.id = pe.exercise_id
                            WHERE pe.planned_session_id = ? AND pe.deleted_at IS NULL
                            ORDER BY pe.position
                        """,
                    arguments: [planId]
                )
                let setupRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT s.* FROM fitness_exercise_setups s
                        JOIN fitness_planned_session_exercises pe ON pe.exercise_id=s.exercise_id
                        WHERE pe.planned_session_id=? AND pe.deleted_at IS NULL
                          AND s.active=1 AND s.deleted_at IS NULL
                        ORDER BY s.exercise_id,s.is_default DESC,s.client_updated_at
                        """,
                    arguments: [planId]
                )
                var setupsByExercise: [String: [Row]] = [:]
                for setup in setupRows {
                    setupsByExercise[setup["exercise_id"], default: []].append(setup)
                }
                let plannedSetRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT ps.* FROM fitness_planned_sets ps
                        JOIN fitness_planned_session_exercises pe ON pe.id=ps.planned_exercise_id
                        WHERE pe.planned_session_id=? AND pe.deleted_at IS NULL
                          AND ps.deleted_at IS NULL
                        ORDER BY ps.planned_exercise_id,ps.position
                        """,
                    arguments: [planId]
                )
                var setsByPlannedExercise: [String: [Row]] = [:]
                for plannedSet in plannedSetRows {
                    setsByPlannedExercise[plannedSet["planned_exercise_id"], default: []].append(plannedSet)
                }
                for (position, row) in rows.enumerated() {
                    let exerciseId: String = row["exercise_id"]
                    let requestedSetupId: String? = row["exercise_setup_id"]
                    let candidates = setupsByExercise[exerciseId] ?? []
                    let setupRow =
                        requestedSetupId.flatMap { requested in
                            candidates.first { ($0["id"] as String) == requested }
                        } ?? candidates.first
                    guard let setupRow else {
                        // A plan must never silently drop an exercise because an old
                        // setup disappeared. The whole start transaction remains intact.
                        throw FitnessRepositoryError.missingSetup
                    }
                    let sessionExercise = try insertSessionExercise(
                        context: context,
                        sessionId: session.id,
                        exerciseId: exerciseId,
                        exerciseName: row["exercise_name"],
                        setupId: setupRow["id"], setupName: setupRow["name"],
                        position: position,
                        plannedExerciseId: row["planned_exercise_id"],
                        setupLoadModeSnapshot: Self.serverLoadMode(
                            FitnessLoadMode(rawValue: setupRow["load_mode"] as String) ?? .total
                        ),
                        repCountModeSnapshot: setupRow["rep_count_mode"] ?? "total",
                        unilateralModeSnapshot: setupRow["unilateral_mode"] ?? "bilateral",
                        db: db, now: now
                    )
                    let plannedExerciseId: String = row["planned_exercise_id"]
                    let plannedSets = setsByPlannedExercise[plannedExerciseId] ?? []
                    for planned in plannedSets {
                        let group = FitnessSetGroup(
                            id: UUID().uuidString, sessionExerciseId: sessionExercise.id,
                            role: FitnessSetRole(rawValue: planned["training_role"]) ?? .working,
                            structure: FitnessSetStructure(rawValue: planned["structure_type"]) ?? .straight,
                            isAMRAP: (planned["is_amrap"] as Int) != 0, failureState: .none,
                            status: .planned, position: planned["position"], revision: 0, updatedAt: now,
                            plannedSetId: planned["id"]
                        )
                        try insertGroup(context: context, group, sessionId: session.id, db: db)
                    }
                }
            }
        }
        return session
    }

    func latestCanonicalBodyweight(onOrBefore date: Date = Date()) throws -> FitnessBodyMeasurement? {
        return try context.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT m.*,
                           s.transport_key AS detail_transport_key,
                           s.origin_provider_key AS detail_origin_provider_key,
                           s.source_namespace AS detail_source_namespace,
                           s.source_device_identifier AS detail_source_device_identifier,
                           s.state AS detail_source_state
                    FROM fitness_body_measurements m
                    LEFT JOIN fitness_external_source_records s ON s.id=m.source_record_id
                    WHERE m.metric_key='body.weight_kg' AND m.is_canonical=1
                      AND m.deleted_at IS NULL AND m.measured_at<=?
                    ORDER BY m.measured_at DESC LIMIT 1
                    """,
                arguments: [FitnessDatabase.dateString(date)]
            ).map(Self.bodyMeasurement)
        }
    }

    func pendingStrengthMutationCount() throws -> Int {
        try context.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM fitness_outbox WHERE entity_type IN
                    ('strength_session','strength_session_exercise','strength_set_group',
                     'strength_set_component','session_checkin','body_issue')
                    """
            ) ?? 0
        }
    }

    func workoutExercises(sessionId: String) throws -> [FitnessWorkoutExercise] {
        try context.read { db in
            let exercises = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_strength_session_exercises
                    WHERE session_id = ? AND deleted_at IS NULL ORDER BY position
                    """,
                arguments: [sessionId]
            ).map(Self.sessionExercise)
            let groupRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT g.* FROM fitness_strength_set_groups g
                    JOIN fitness_strength_session_exercises e ON e.id=g.session_exercise_id
                    WHERE e.session_id=? AND e.deleted_at IS NULL AND g.deleted_at IS NULL
                    ORDER BY g.session_exercise_id,g.position
                    """,
                arguments: [sessionId]
            )
            let componentRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM fitness_strength_set_components c
                    JOIN fitness_strength_set_groups g ON g.id=c.group_id
                    JOIN fitness_strength_session_exercises e ON e.id=g.session_exercise_id
                    WHERE e.session_id=? AND e.deleted_at IS NULL
                      AND g.deleted_at IS NULL AND c.deleted_at IS NULL
                    ORDER BY c.group_id,c.position
                    """,
                arguments: [sessionId]
            )
            var groupsByExercise: [String: [FitnessSetGroup]] = [:]
            for row in groupRows {
                let group = Self.group(row)
                groupsByExercise[group.sessionExerciseId, default: []].append(group)
            }
            var componentsByGroup: [String: [FitnessSetComponent]] = [:]
            for row in componentRows {
                let component = try Self.component(row)
                componentsByGroup[component.groupId, default: []].append(component)
            }
            return exercises.map { exercise in
                FitnessWorkoutExercise(
                    exercise: exercise,
                    groups: (groupsByExercise[exercise.id] ?? []).map { group in
                        FitnessWorkoutGroup(
                            group: group, components: componentsByGroup[group.id] ?? []
                        )
                    }
                )
            }
        }
    }

    func plannedStrengthExercises(planId: String) throws -> [FitnessPlannedStrengthExercise] {
        try context.read { db in
            let exerciseRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT pe.*,e.name AS exercise_name
                    FROM fitness_planned_session_exercises pe
                    JOIN fitness_exercises e ON e.id=pe.exercise_id
                    WHERE pe.planned_session_id=? AND pe.deleted_at IS NULL ORDER BY pe.position
                    """,
                arguments: [planId]
            )
            let setRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM fitness_planned_sets s
                    JOIN fitness_planned_session_exercises pe ON pe.id=s.planned_exercise_id
                    WHERE pe.planned_session_id=? AND pe.deleted_at IS NULL
                      AND s.deleted_at IS NULL
                    ORDER BY s.planned_exercise_id,s.position
                    """,
                arguments: [planId]
            )
            var setsByExercise: [String: [FitnessPlannedStrengthSet]] = [:]
            for set in setRows {
                let plannedExerciseId: String = set["planned_exercise_id"]
                setsByExercise[plannedExerciseId, default: []].append(
                    FitnessPlannedStrengthSet(
                        id: set["id"], plannedExerciseId: plannedExerciseId, sequence: set["position"],
                        role: FitnessSetRole(rawValue: set["training_role"]) ?? .working,
                        structure: FitnessSetStructure(rawValue: set["structure_type"]) ?? .straight,
                        componentCount: set["component_count"], repsMin: set["reps_min"], repsMax: set["reps_max"],
                        loadMin: set["load_min"], loadMax: set["load_max"], loadUnit: set["load_unit"],
                        rpeMin: set["rpe_min"], rpeMax: set["rpe_max"], rirMin: set["rir_min"],
                        rirMax: set["rir_max"], restSeconds: set["rest_seconds"],
                        isAMRAP: (set["is_amrap"] as Int) != 0, notes: set["notes"]
                    )
                )
            }
            return try exerciseRows.map { row in
                let plannedExerciseId: String = row["id"]
                return FitnessPlannedStrengthExercise(
                    id: plannedExerciseId, plannedSessionId: planId, exerciseId: row["exercise_id"],
                    exerciseName: row["exercise_name"], requestedSetupId: row["requested_setup_id"] ?? row["exercise_setup_id"],
                    sequence: row["position"], supersetGroupKey: row["superset_group_key"],
                    substitutionExerciseIds: try Self.decodeStringArray(
                        row["substitution_exercise_ids_json"]
                    ),
                    notes: row["notes"], sets: setsByExercise[plannedExerciseId] ?? []
                )
            }
        }
    }

    func comparableSets(for exercise: FitnessSessionExercise, limit: Int = 8) throws -> [FitnessComparableSet] {
        try context.read { db in
            let requestedLimit = max(0, min(limit, 100))
            guard requestedLimit > 0 else { return [] }
            let canonical = try Self.canonicalComparableIds(
                exerciseId: exercise.exerciseId, setupId: exercise.setupId, db: db
            )
            let separator = "\u{1F}"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH RECURSIVE
                    exercise_family(id,depth,path) AS (
                      SELECT ?,0,? || ? || ?
                      UNION ALL
                      SELECT r.source_id,f.depth+1,f.path || r.source_id || ?
                      FROM fitness_redirects r
                      JOIN exercise_family f ON f.id=r.target_id
                      WHERE r.entity_type=? AND f.depth<8
                        AND instr(f.path,? || r.source_id || ?)=0
                    ),
                    setup_family(id,depth,path) AS (
                      SELECT ?,0,? || ? || ?
                      UNION ALL
                      SELECT r.source_id,f.depth+1,f.path || r.source_id || ?
                      FROM fitness_redirects r
                      JOIN setup_family f ON f.id=r.target_id
                      WHERE r.entity_type=? AND f.depth<8
                        AND instr(f.path,? || r.source_id || ?)=0
                    )
                    SELECT g.*,s.started_at AS performed_at,se.exercise_name,se.setup_name,
                           se.exercise_id AS compared_exercise_id,se.setup_id AS compared_setup_id,
                           se.setup_load_entry_mode_snapshot AS compared_load_mode,
                           se.rep_count_mode_snapshot AS compared_rep_mode,
                           se.unilateral_mode_snapshot AS compared_unilateral_mode
                    FROM fitness_strength_set_groups g
                    JOIN fitness_strength_session_exercises se ON se.id=g.session_exercise_id
                    JOIN fitness_strength_sessions s ON s.id=se.session_id
                    JOIN exercise_family ef ON ef.id=se.exercise_id
                    JOIN setup_family sf ON sf.id=se.setup_id
                    WHERE se.id<>? AND g.status IN ('completed','partial')
                      AND g.deleted_at IS NULL AND se.deleted_at IS NULL AND s.deleted_at IS NULL
                      AND COALESCE(se.setup_load_entry_mode_snapshot,'total_external')=?
                      AND COALESCE(se.rep_count_mode_snapshot,'total')=?
                      AND COALESCE(se.unilateral_mode_snapshot,'bilateral')=?
                    GROUP BY g.id
                    ORDER BY s.started_at DESC,g.position DESC,g.id LIMIT ?
                    """,
                arguments: [
                    canonical.exerciseId, separator, canonical.exerciseId, separator, separator,
                    FitnessEntityType.exercise.rawValue, separator, separator,
                    canonical.setupId, separator, canonical.setupId, separator, separator,
                    FitnessEntityType.exerciseSetup.rawValue, separator, separator,
                    exercise.id, exercise.setupLoadModeSnapshot, exercise.repCountModeSnapshot,
                    exercise.unilateralModeSnapshot, requestedLimit,
                ]
            )
            guard !rows.isEmpty else { return [] }
            let groupIds: [String] = rows.map { $0["id"] }
            let placeholders = Array(repeating: "?", count: groupIds.count).joined(separator: ",")
            let componentRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_strength_set_components
                    WHERE group_id IN (\(placeholders)) AND deleted_at IS NULL
                    ORDER BY group_id,position
                    """,
                arguments: StatementArguments(groupIds)
            )
            var componentsByGroup: [String: [FitnessSetComponent]] = [:]
            for componentRow in componentRows {
                let component = try Self.component(componentRow)
                componentsByGroup[component.groupId, default: []].append(component)
            }
            return rows.map { row in
                let group = Self.group(row)
                return FitnessComparableSet(
                    id: group.id, performedAt: FitnessDatabase.date(row["performed_at"]) ?? .distantPast,
                    exerciseName: row["exercise_name"], setupLabelSnapshot: row["setup_name"],
                    loadModeSnapshot: row["compared_load_mode"] ?? "total_external",
                    repModeSnapshot: row["compared_rep_mode"] ?? "total",
                    unilateralModeSnapshot: row["compared_unilateral_mode"] ?? "bilateral",
                    group: group, components: componentsByGroup[group.id] ?? []
                )
            }
        }
    }

    /// Resolves only the two requested redirect chains. The old implementation
    /// loaded both complete redirect tables on every set lookup, then loaded and
    /// discarded up to 400 unrelated history groups. This bounded recursive CTE
    /// performs at most eight hops per identifier and fails cycles into one
    /// deterministic family representative.
    private static func canonicalComparableIds(
        exerciseId: String, setupId: String, db: Database
    ) throws -> (exerciseId: String, setupId: String) {
        let separator = "\u{1F}"
        let rows = try Row.fetchAll(
            db,
            sql: """
                WITH RECURSIVE chain(entity_type,id,depth,path,is_cycle) AS (
                  SELECT ?,?,0,? || ? || ?,0
                  UNION ALL
                  SELECT ?,?,0,? || ? || ?,0
                  UNION ALL
                  SELECT r.entity_type,r.target_id,c.depth+1,
                         c.path || r.target_id || ?,
                         instr(c.path,? || r.target_id || ?)>0
                  FROM fitness_redirects r
                  JOIN chain c ON c.entity_type=r.entity_type AND c.id=r.source_id
                  WHERE c.depth<8 AND c.is_cycle=0
                )
                SELECT entity_type,id,depth,is_cycle FROM chain ORDER BY entity_type,depth
                """,
            arguments: [
                FitnessEntityType.exercise.rawValue, exerciseId, separator, exerciseId, separator,
                FitnessEntityType.exerciseSetup.rawValue, setupId, separator, setupId, separator,
                separator, separator, separator,
            ]
        )
        func resolved(_ type: FitnessEntityType, fallback: String) -> String {
            let chain = rows.filter { ($0["entity_type"] as String) == type.rawValue }
            guard !chain.isEmpty else { return fallback }
            if chain.contains(where: { ($0["is_cycle"] as Int) != 0 }) {
                return chain.map { $0["id"] as String }.min() ?? fallback
            }
            return chain.max { ($0["depth"] as Int) < ($1["depth"] as Int) }
                .map { $0["id"] as String } ?? fallback
        }
        return (
            resolved(.exercise, fallback: exerciseId),
            resolved(.exerciseSetup, fallback: setupId)
        )
    }

    func setRestTimer(sessionId: String, deadline: Date?) throws {
        let now = Date()
        try context.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM fitness_strength_sessions WHERE id=?", arguments: [sessionId])
            else { throw FitnessRepositoryError.noActiveWorkout }
            var session = Self.session(row)
            session.restTimerDeadline = deadline
            session.updatedAt = now
            try db.execute(
                sql: "UPDATE fitness_strength_sessions SET rest_timer_deadline_utc=?,client_updated_at=? WHERE id=?",
                arguments: [deadline.map(FitnessDatabase.dateString), FitnessDatabase.dateString(now), sessionId]
            )
            try enqueue(
                context: context,
                db, type: .strengthSession, id: sessionId, baseRevision: session.revision,
                payload: StrengthSessionPayload(
                    id: session.id, title: session.title, startedAtUtc: session.startedAt,
                    localTimezone: session.localTimezone, plannedSessionId: session.plannedSessionId,
                    status: session.status == .active ? "in_progress" : session.status.rawValue,
                    endedAtUtc: session.endedAt, sessionRpe: session.sessionRPE,
                    perceivedPerformance: session.performance, notes: session.note,
                    restTimerDeadlineUtc: deadline, matchedPlanKey: session.matchedPlanKey
                ), now: now
            )
        }
    }

    func reorderSessionExercises(sessionId: String, orderedIds: [String]) throws {
        let now = Date()
        try context.write { db in
            let existing = try Set(
                String.fetchAll(
                    db, sql: "SELECT id FROM fitness_strength_session_exercises WHERE session_id=? AND deleted_at IS NULL",
                    arguments: [sessionId]
                ))
            guard existing == Set(orderedIds), existing.count == orderedIds.count else {
                throw FitnessRepositoryError.invalidStrengthEntry
            }
            for (position, id) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE fitness_strength_session_exercises SET position=?,client_updated_at=? WHERE id=?",
                    arguments: [position, FitnessDatabase.dateString(now), id]
                )
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM fitness_strength_session_exercises WHERE id=?", arguments: [id])
                else { continue }
                let value = Self.sessionExercise(row)
                try enqueue(
                    context: context,
                    db, type: .strengthSessionExercise, id: id, baseRevision: value.revision,
                    payload: SessionExercisePayload(
                        id: id, activityId: sessionId, exerciseId: value.exerciseId,
                        exerciseSetupId: value.setupId, plannedExerciseId: value.plannedExerciseId,
                        sequence: position, supersetGroupKey: value.supersetGroupKey,
                        variationNote: value.variationNote, notes: value.notes,
                        exerciseSetupLabelSnapshot: value.setupName,
                        exerciseSetupLoadEntryModeSnapshot: value.setupLoadModeSnapshot,
                        unilateralModeSnapshot: value.unilateralModeSnapshot
                    ), now: now
                )
            }
        }
    }

    func skipSet(groupId: String) throws {
        let now = Date()
        try context.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM fitness_strength_set_groups WHERE id=?", arguments: [groupId])
            else { throw FitnessRepositoryError.missingSetGroup }
            var group = Self.group(row)
            group.status = .skipped
            group.failureState = .none
            group.completedAt = now
            group.updatedAt = now
            try updateGroup(context: context, group, sessionId: try sessionId(forGroup: groupId, db: db), db: db)
        }
    }

    func changeSetup(sessionExerciseId: String, setupId: String) throws {
        let now = Date()
        try context.write { db in
            guard
                let exerciseRow = try Row.fetchOne(
                    db, sql: "SELECT * FROM fitness_strength_session_exercises WHERE id=? AND deleted_at IS NULL",
                    arguments: [sessionExerciseId]
                ),
                let setupRow = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM fitness_exercise_setups WHERE id=? AND exercise_id=? AND active=1 AND deleted_at IS NULL",
                    arguments: [setupId, exerciseRow["exercise_id"] as String]
                )
            else { throw FitnessRepositoryError.missingSetup }
            let hasPerformed =
                (try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM fitness_strength_set_components c
                        JOIN fitness_strength_set_groups g ON g.id=c.group_id
                        WHERE g.session_exercise_id=? AND c.status<>'skipped' AND c.deleted_at IS NULL
                        """,
                    arguments: [sessionExerciseId]
                ) ?? 0) > 0
            guard !hasPerformed else { throw FitnessRepositoryError.setupAlreadySnapshotted }
            let mode = Self.serverLoadMode(FitnessLoadMode(rawValue: setupRow["load_mode"] as String) ?? .total)
            try db.execute(
                sql: """
                    UPDATE fitness_strength_session_exercises
                       SET setup_id=?,setup_name=?,setup_load_entry_mode_snapshot=?,
                           rep_count_mode_snapshot=?,unilateral_mode_snapshot=?,client_updated_at=? WHERE id=?
                    """,
                arguments: [
                    setupId, setupRow["name"], mode, setupRow["rep_count_mode"] ?? "total",
                    setupRow["unilateral_mode"] ?? "bilateral",
                    FitnessDatabase.dateString(now), sessionExerciseId,
                ]
            )
            guard
                let updated = try Row.fetchOne(
                    db, sql: "SELECT * FROM fitness_strength_session_exercises WHERE id=?", arguments: [sessionExerciseId]
                ).map(Self.sessionExercise)
            else {
                throw FitnessRepositoryError.missingRecord
            }
            try enqueue(
                context: context,
                db, type: .strengthSessionExercise, id: sessionExerciseId, baseRevision: updated.revision,
                payload: SessionExercisePayload(
                    id: updated.id, activityId: updated.sessionId, exerciseId: updated.exerciseId,
                    exerciseSetupId: updated.setupId, plannedExerciseId: updated.plannedExerciseId,
                    sequence: updated.position, supersetGroupKey: updated.supersetGroupKey,
                    variationNote: updated.variationNote, notes: updated.notes,
                    exerciseSetupLabelSnapshot: updated.setupName,
                    exerciseSetupLoadEntryModeSnapshot: updated.setupLoadModeSnapshot,
                    unilateralModeSnapshot: updated.unilateralModeSnapshot
                ), now: now
            )
        }
    }

    func substituteExercise(sessionExerciseId: String, with exerciseId: String, setupId: String? = nil) throws {
        let now = Date()
        try context.write { db in
            guard
                let current = try Row.fetchOne(
                    db, sql: "SELECT * FROM fitness_strength_session_exercises WHERE id=? AND deleted_at IS NULL",
                    arguments: [sessionExerciseId]
                )
            else { throw FitnessRepositoryError.missingExercise }
            let hasWork =
                (try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM fitness_strength_set_components c
                        JOIN fitness_strength_set_groups g ON g.id=c.group_id
                        WHERE g.session_exercise_id=? AND c.status<>'skipped' AND c.deleted_at IS NULL
                        """, arguments: [sessionExerciseId]
                ) ?? 0) > 0
            guard !hasWork else { throw FitnessRepositoryError.exerciseAlreadyPerformed }
            let canonical = try resolvedId(type: .exercise, id: exerciseId, db: db)
            guard
                let exercise = try Row.fetchOne(
                    db, sql: "SELECT * FROM fitness_exercises WHERE id=? AND active=1 AND deleted_at IS NULL",
                    arguments: [canonical]
                )
            else { throw FitnessRepositoryError.missingExercise }
            let setup: Row? =
                try setupId.flatMap { id in
                    try Row.fetchOne(
                        db, sql: "SELECT * FROM fitness_exercise_setups WHERE id=? AND exercise_id=? AND active=1 AND deleted_at IS NULL",
                        arguments: [id, canonical]
                    )
                }
                ?? Row.fetchOne(
                    db,
                    sql:
                        "SELECT * FROM fitness_exercise_setups WHERE exercise_id=? AND active=1 AND deleted_at IS NULL ORDER BY is_default DESC LIMIT 1",
                    arguments: [canonical]
                )
            guard let setup else { throw FitnessRepositoryError.missingSetup }
            let mode = Self.serverLoadMode(FitnessLoadMode(rawValue: setup["load_mode"] as String) ?? .total)
            try db.execute(
                sql: """
                    UPDATE fitness_strength_session_exercises
                       SET exercise_id=?,exercise_name=?,setup_id=?,setup_name=?,
                           setup_load_entry_mode_snapshot=?,rep_count_mode_snapshot=?,
                           unilateral_mode_snapshot=?,variation_note=?,client_updated_at=? WHERE id=?
                    """,
                arguments: [
                    canonical, exercise["name"], setup["id"], setup["name"], mode,
                    setup["rep_count_mode"] ?? "total", setup["unilateral_mode"] ?? "bilateral",
                    "Substituted for \(current["exercise_name"] as String)",
                    FitnessDatabase.dateString(now), sessionExerciseId,
                ]
            )
            guard
                let value = try Row.fetchOne(
                    db, sql: "SELECT * FROM fitness_strength_session_exercises WHERE id=?", arguments: [sessionExerciseId]
                ).map(Self.sessionExercise)
            else {
                throw FitnessRepositoryError.missingRecord
            }
            try enqueue(
                context: context,
                db, type: .strengthSessionExercise, id: value.id, baseRevision: value.revision,
                payload: SessionExercisePayload(
                    id: value.id, activityId: value.sessionId, exerciseId: value.exerciseId,
                    exerciseSetupId: value.setupId, plannedExerciseId: value.plannedExerciseId,
                    sequence: value.position, supersetGroupKey: value.supersetGroupKey,
                    variationNote: value.variationNote, notes: value.notes,
                    exerciseSetupLabelSnapshot: value.setupName,
                    exerciseSetupLoadEntryModeSnapshot: value.setupLoadModeSnapshot,
                    unilateralModeSnapshot: value.unilateralModeSnapshot
                ), now: now
            )
        }
    }

    @discardableResult
    func addExercise(_ exerciseId: String, to sessionId: String, setupId: String? = nil) throws -> FitnessSessionExercise {
        try context.write { db in
            let exerciseId = try resolvedId(type: .exercise, id: exerciseId, db: db)
            guard
                let exerciseRow = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM fitness_exercises WHERE id = ? AND deleted_at IS NULL",
                    arguments: [exerciseId]
                )
            else { throw FitnessRepositoryError.missingExercise }
            let selectedSetupRow: Row?
            if let setupId {
                selectedSetupRow = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM fitness_exercise_setups WHERE id = ? AND exercise_id = ? AND deleted_at IS NULL",
                    arguments: [setupId, exerciseId]
                )
            } else {
                selectedSetupRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM fitness_exercise_setups WHERE exercise_id = ? AND deleted_at IS NULL
                        ORDER BY is_default DESC, client_updated_at LIMIT 1
                        """,
                    arguments: [exerciseId]
                )
            }
            guard let setupRow = selectedSetupRow else { throw FitnessRepositoryError.missingSetup }
            let position =
                (try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COALESCE(MAX(position), -1) + 1 FROM fitness_strength_session_exercises WHERE session_id = ? AND deleted_at IS NULL",
                    arguments: [sessionId]
                )) ?? 0
            return try insertSessionExercise(
                context: context,
                sessionId: sessionId,
                exerciseId: exerciseId,
                exerciseName: exerciseRow["name"],
                setupId: setupRow["id"],
                setupName: setupRow["name"],
                position: position,
                setupLoadModeSnapshot: Self.serverLoadMode(
                    FitnessLoadMode(rawValue: setupRow["load_mode"] as String) ?? .total
                ),
                repCountModeSnapshot: setupRow["rep_count_mode"] ?? "total",
                unilateralModeSnapshot: setupRow["unilateral_mode"] ?? "bilateral",
                db: db,
                now: Date()
            )
        }
    }

    @discardableResult
    func addSet(
        to sessionExerciseId: String,
        sessionId: String,
        role: FitnessSetRole,
        structure: FitnessSetStructure = .straight,
        isAMRAP: Bool = false,
        groupStatus: FitnessSetStatus = .completed,
        componentStatus: FitnessComponentStatus = .completed,
        loadKg: Double?,
        reps: Int?,
        rir: Double?,
        rpe: Double?,
        failureState: FitnessFailureType = .unknown
    ) throws -> FitnessWorkoutGroup {
        try saveSet(
            to: sessionExerciseId, sessionId: sessionId,
            draft: FitnessStrengthSetDraft(
                role: role, structure: structure, isAMRAP: isAMRAP,
                groupStatus: groupStatus, componentStatus: componentStatus,
                failureState: failureState, reps: reps, loadValue: loadKg,
                loadUnit: loadKg == nil ? nil : "kg", rir: rir, rpe: rpe
            )
        )
    }

    @discardableResult
    func saveSet(
        to sessionExerciseId: String,
        sessionId: String,
        draft: FitnessStrengthSetDraft
    ) throws -> FitnessWorkoutGroup {
        try Self.validate(draft)
        let now = Date()
        return try context.write { db in
            guard
                let exerciseRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT se.*,s.load_mode,s.machine_base_load_kg,s.side_multiplier
                        FROM fitness_strength_session_exercises se
                        JOIN fitness_exercise_setups s ON s.id=se.setup_id
                        WHERE se.id=? AND se.session_id=? AND se.deleted_at IS NULL
                        """,
                    arguments: [sessionExerciseId, sessionId]
                )
            else { throw FitnessRepositoryError.missingExercise }
            let mode = Self.localLoadMode(exerciseRow["setup_load_entry_mode_snapshot"])
            let setup = FitnessExerciseSetup(
                id: exerciseRow["setup_id"], exerciseId: exerciseRow["exercise_id"],
                name: exerciseRow["setup_name"], loadMode: mode, incrementKg: nil,
                barWeightKg: nil, isDefault: true, revision: 0, updatedAt: now,
                machineBaseLoadKg: exerciseRow["machine_base_load_kg"],
                sideMultiplier: exerciseRow["side_multiplier"]
            )
            let normalized = FitnessStrengthSemantics.normalizedExternalLoad(
                value: draft.loadValue, mode: mode, setup: setup
            )
            let bodyweight = try Double.fetchOne(
                db, sql: "SELECT bodyweight_kg_snapshot FROM fitness_strength_sessions WHERE id=?",
                arguments: [sessionId]
            )
            let existing: Row? = try draft.plannedSetId.flatMap { plannedSetId in
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM fitness_strength_set_groups
                        WHERE session_exercise_id=? AND planned_set_id=? AND status='planned'
                          AND deleted_at IS NULL LIMIT 1
                        """,
                    arguments: [sessionExerciseId, plannedSetId]
                )
            }
            let group: FitnessSetGroup
            if let existing {
                var value = Self.group(existing)
                value.role = draft.role
                value.structure = draft.structure
                value.isAMRAP = draft.isAMRAP
                value.failureState = draft.failureState
                value.status = draft.groupStatus
                value.startedAt = draft.startedAt ?? now
                value.completedAt = draft.groupStatus == .inProgress ? nil : (draft.completedAt ?? now)
                value.notes = Self.trimmedOrNil(draft.notes)
                value.updatedAt = now
                try updateGroup(context: context, value, sessionId: sessionId, db: db)
                group = value
            } else {
                let position =
                    (try Int.fetchOne(
                        db,
                        sql:
                            "SELECT COALESCE(MAX(position),-1)+1 FROM fitness_strength_set_groups WHERE session_exercise_id=? AND deleted_at IS NULL",
                        arguments: [sessionExerciseId]
                    )) ?? 0
                group = FitnessSetGroup(
                    id: UUID().uuidString, sessionExerciseId: sessionExerciseId,
                    role: draft.role, structure: draft.structure, isAMRAP: draft.isAMRAP,
                    failureState: draft.failureState, status: draft.groupStatus, position: position,
                    revision: 0, updatedAt: now, plannedSetId: draft.plannedSetId,
                    startedAt: draft.startedAt ?? now,
                    completedAt: draft.groupStatus == .inProgress ? nil : (draft.completedAt ?? now),
                    notes: Self.trimmedOrNil(draft.notes)
                )
                try insertGroup(context: context, group, sessionId: sessionId, db: db)
            }
            let component = FitnessSetComponent(
                id: UUID().uuidString, groupId: group.id, status: draft.componentStatus,
                loadKg: normalized, reps: draft.reps, durationSeconds: draft.durationSeconds,
                distanceMetres: draft.distanceMetres, rir: draft.rir, rpe: draft.rpe,
                completedAt: draft.componentStatus == .skipped ? nil : (draft.completedAt ?? now), position: 0,
                revision: 0, updatedAt: now, repsLeft: draft.repsLeft, repsRight: draft.repsRight,
                loadValue: draft.loadValue, loadUnit: draft.loadUnit,
                loadEntryModeSnapshot: Self.serverLoadMode(mode),
                normalizedExternalLoadKg: normalized,
                addedLoadKg: mode == .added ? draft.loadValue : nil,
                assistanceKg: mode == .assistance ? draft.loadValue : nil,
                bodyweightKgSnapshot: [.bodyweight, .added, .assistance].contains(mode) ? bodyweight : nil,
                restBeforeSeconds: draft.restBeforeSeconds, tempoText: Self.trimmedOrNil(draft.tempoText),
                notes: Self.trimmedOrNil(draft.notes), extraMetrics: draft.extraMetrics
            )
            try insertComponent(context: context, component, db: db)
            return FitnessWorkoutGroup(group: group, components: [component])
        }
    }

    @discardableResult
    func updateSet(
        group originalGroup: FitnessSetGroup,
        component originalComponent: FitnessSetComponent,
        sessionId: String,
        draft: FitnessStrengthSetDraft
    ) throws -> FitnessWorkoutGroup {
        try Self.validate(draft)
        let now = Date()
        return try context.write { db in
            guard let setupRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT se.setup_id,se.setup_load_entry_mode_snapshot,s.machine_base_load_kg,
                           s.side_multiplier,session.bodyweight_kg_snapshot
                    FROM fitness_strength_session_exercises se
                    JOIN fitness_exercise_setups s ON s.id=se.setup_id
                    JOIN fitness_strength_sessions session ON session.id=se.session_id
                    WHERE se.id=? AND se.session_id=? AND se.deleted_at IS NULL
                    """,
                arguments: [originalGroup.sessionExerciseId, sessionId]
            ) else { throw FitnessRepositoryError.missingExercise }
            let mode = Self.localLoadMode(setupRow["setup_load_entry_mode_snapshot"])
            let setup = FitnessExerciseSetup(
                id: setupRow["setup_id"], exerciseId: "", name: "Snapshot", loadMode: mode,
                incrementKg: nil, barWeightKg: nil, isDefault: false, revision: 0, updatedAt: now,
                machineBaseLoadKg: setupRow["machine_base_load_kg"], sideMultiplier: setupRow["side_multiplier"]
            )
            let normalized = FitnessStrengthSemantics.normalizedExternalLoad(
                value: draft.loadValue, mode: mode, setup: setup
            )
            var group = originalGroup
            group.role = draft.role
            group.structure = draft.structure
            group.isAMRAP = draft.isAMRAP
            group.failureState = draft.failureState
            group.status = draft.groupStatus
            group.notes = Self.trimmedOrNil(draft.notes)
            group.updatedAt = now
            try updateGroup(context: context, group, sessionId: sessionId, db: db)

            var component = originalComponent
            component.status = draft.componentStatus
            component.loadKg = normalized
            component.reps = draft.reps
            component.repsLeft = draft.repsLeft
            component.repsRight = draft.repsRight
            component.loadValue = draft.loadValue
            component.loadUnit = draft.loadUnit
            component.loadEntryModeSnapshot = Self.serverLoadMode(mode)
            component.normalizedExternalLoadKg = normalized
            component.addedLoadKg = mode == .added ? draft.loadValue : nil
            component.assistanceKg = mode == .assistance ? draft.loadValue : nil
            component.bodyweightKgSnapshot = [.bodyweight, .added, .assistance].contains(mode)
                ? setupRow["bodyweight_kg_snapshot"] : nil
            component.durationSeconds = draft.durationSeconds
            component.distanceMetres = draft.distanceMetres
            component.rir = draft.rir
            component.rpe = draft.rpe
            component.restBeforeSeconds = draft.restBeforeSeconds
            component.tempoText = Self.trimmedOrNil(draft.tempoText)
            component.notes = Self.trimmedOrNil(draft.notes)
            component.extraMetrics = draft.extraMetrics
            component.updatedAt = now
            try db.execute(
                sql: """
                    UPDATE fitness_strength_set_components
                    SET status=?,load_kg=?,reps=?,duration_seconds=?,distance_metres=?,rir=?,rpe=?,
                        reps_left=?,reps_right=?,load_value=?,load_unit=?,load_entry_mode_snapshot=?,
                        normalized_external_load_kg=?,added_load_kg=?,assistance_kg=?,
                        bodyweight_kg_snapshot=?,rest_before_s=?,tempo_text=?,notes=?,
                        extra_metrics_json=?,client_updated_at=? WHERE id=?
                    """,
                arguments: [
                    component.status.rawValue, component.loadKg, component.reps,
                    component.durationSeconds, component.distanceMetres, component.rir, component.rpe,
                    component.repsLeft, component.repsRight, component.loadValue, component.loadUnit,
                    component.loadEntryModeSnapshot, component.normalizedExternalLoadKg,
                    component.addedLoadKg, component.assistanceKg, component.bodyweightKgSnapshot,
                    component.restBeforeSeconds, component.tempoText, component.notes,
                    try jsonString(.object(component.extraMetrics)), FitnessDatabase.dateString(now),
                    component.id,
                ]
            )
            try enqueue(
                context: context, db, type: .strengthSetComponent, id: component.id,
                baseRevision: component.revision,
                payload: SetComponentPayload(component: component), now: now
            )
            return FitnessWorkoutGroup(group: group, components: [component])
        }
    }

    @discardableResult
    func addDropComponent(
        to groupId: String,
        loadKg: Double?,
        reps: Int?,
        rir: Double?,
        rpe: Double?
    ) throws -> FitnessSetComponent {
        try addComponent(
            to: groupId, structure: .drop,
            draft: FitnessStrengthSetDraft(
                structure: .drop, reps: reps, loadValue: loadKg,
                loadUnit: loadKg == nil ? nil : "kg", rir: rir, rpe: rpe
            )
        )
    }

    @discardableResult
    func addComponent(
        to groupId: String,
        structure: FitnessSetStructure,
        draft: FitnessStrengthSetDraft
    ) throws -> FitnessSetComponent {
        try Self.validate(draft)
        guard [.drop, .restPause, .cluster, .other].contains(structure) else {
            throw FitnessRepositoryError.invalidStrengthEntry
        }
        let now = Date()
        return try context.write { db in
            let position =
                (try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COALESCE(MAX(position), -1) + 1 FROM fitness_strength_set_components WHERE group_id = ? AND deleted_at IS NULL",
                    arguments: [groupId]
                )) ?? 0
            guard
                let groupRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT g.*,se.setup_id,se.setup_load_entry_mode_snapshot,se.session_id,
                               s.load_mode,s.machine_base_load_kg,s.side_multiplier,
                               session.bodyweight_kg_snapshot
                        FROM fitness_strength_set_groups g
                        JOIN fitness_strength_session_exercises se ON se.id=g.session_exercise_id
                        JOIN fitness_exercise_setups s ON s.id=se.setup_id
                        JOIN fitness_strength_sessions session ON session.id=se.session_id
                        WHERE g.id=? AND g.deleted_at IS NULL
                        """,
                    arguments: [groupId]
                )
            else { throw FitnessRepositoryError.missingSetGroup }
            var group = Self.group(groupRow)
            group.structure = structure
            group.updatedAt = now
            try updateGroup(
                context: context,
                group, sessionId: groupRow["session_id"], db: db
            )
            let mode = Self.localLoadMode(groupRow["setup_load_entry_mode_snapshot"])
            let setup = FitnessExerciseSetup(
                id: groupRow["setup_id"], exerciseId: "", name: "Snapshot", loadMode: mode,
                incrementKg: nil, barWeightKg: nil, isDefault: false, revision: 0, updatedAt: now,
                machineBaseLoadKg: groupRow["machine_base_load_kg"], sideMultiplier: groupRow["side_multiplier"]
            )
            let normalized = FitnessStrengthSemantics.normalizedExternalLoad(
                value: draft.loadValue, mode: mode, setup: setup
            )
            let component = FitnessSetComponent(
                id: UUID().uuidString, groupId: groupId, status: draft.componentStatus,
                loadKg: normalized, reps: draft.reps, durationSeconds: draft.durationSeconds,
                distanceMetres: draft.distanceMetres, rir: draft.rir, rpe: draft.rpe,
                completedAt: draft.componentStatus == .skipped ? nil : now, position: position,
                revision: 0, updatedAt: now, repsLeft: draft.repsLeft, repsRight: draft.repsRight,
                loadValue: draft.loadValue, loadUnit: draft.loadUnit,
                loadEntryModeSnapshot: Self.serverLoadMode(mode), normalizedExternalLoadKg: normalized,
                addedLoadKg: mode == .added ? draft.loadValue : nil,
                assistanceKg: mode == .assistance ? draft.loadValue : nil,
                bodyweightKgSnapshot: [.bodyweight, .added, .assistance].contains(mode)
                    ? groupRow["bodyweight_kg_snapshot"] : nil,
                restBeforeSeconds: draft.restBeforeSeconds, tempoText: Self.trimmedOrNil(draft.tempoText),
                notes: Self.trimmedOrNil(draft.notes), extraMetrics: draft.extraMetrics
            )
            try insertComponent(context: context, component, db: db)
            return component
        }
    }

    func addLateReadiness(_ value: Int, sessionId: String) throws {
        try context.write { db in
            let planId = try String.fetchOne(
                db, sql: "SELECT planned_session_id FROM fitness_strength_sessions WHERE id=?",
                arguments: [sessionId]
            )
            // The server contract only permits pre/post. A late recollection of
            // pre-session readiness stays `pre` and is explicitly retrospective.
            try insertReadiness(
                context: context,
                value, energy: nil, soreness: nil, motivation: nil,
                sessionId: sessionId, planId: planId, retrospective: true, db: db, now: Date()
            )
        }
    }

    func finishWorkout(
        sessionId: String,
        rpe: Double?,
        performance: Int?,
        note: String?,
        matchedPlanKey: String? = nil,
        issue: NewBodyIssue? = nil
    ) throws {
        let now = Date()
        try context.write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM fitness_strength_sessions WHERE id = ? AND status = 'active'",
                    arguments: [sessionId]
                )
            else { throw FitnessRepositoryError.noActiveWorkout }
            var session = Self.session(row)
            session.status = .completed
            session.endedAt = now
            session.sessionRPE = rpe
            session.performance = performance.map { min(5, max(1, $0)) }
            session.note = Self.trimmedOrNil(note)
            session.matchedPlanKey = Self.trimmedOrNil(matchedPlanKey)
            session.updatedAt = now
            try db.execute(
                sql: """
                    UPDATE fitness_strength_sessions
                    SET status='completed',ended_at=?,session_rpe=?,performance=?,note=?,
                        matched_plan_key=?,rest_timer_deadline_utc=NULL,client_updated_at=?
                    WHERE id = ?
                    """,
                arguments: [
                    FitnessDatabase.dateString(now), rpe, session.performance, session.note,
                    session.matchedPlanKey,
                    FitnessDatabase.dateString(now), sessionId,
                ]
            )
            try enqueue(
                context: context,
                db,
                type: .strengthSession,
                id: session.id,
                baseRevision: session.revision,
                payload: StrengthSessionPayload(
                    id: session.id,
                    title: session.title,
                    startedAtUtc: session.startedAt,
                    localTimezone: TimeZone.current.identifier,
                    plannedSessionId: session.plannedSessionId,
                    status: session.status.rawValue,
                    endedAtUtc: now,
                    sessionRpe: rpe,
                    perceivedPerformance: session.performance,
                    notes: session.note, restTimerDeadlineUtc: nil, matchedPlanKey: session.matchedPlanKey
                ),
                now: now
            )
            if let planId = session.plannedSessionId {
                try db.execute(
                    sql: "UPDATE fitness_planned_sessions SET is_completed = 1, client_updated_at = ? WHERE id = ?",
                    arguments: [FitnessDatabase.dateString(now), planId]
                )
            }
            if let issue {
                try insertBodyIssue(context: context, issue, id: UUID().uuidString, sessionId: sessionId, db: db, now: now)
            }
        }
    }

    func abandonWorkout(sessionId: String) throws {
        let now = Date()
        try context.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM fitness_strength_sessions WHERE id = ?", arguments: [sessionId]) else {
                throw FitnessRepositoryError.noActiveWorkout
            }
            var session = Self.session(row)
            session.status = .abandoned
            session.endedAt = now
            try db.execute(
                sql: "UPDATE fitness_strength_sessions SET status = 'abandoned', ended_at = ?, rest_timer_deadline_utc = NULL, client_updated_at = ? WHERE id = ?",
                arguments: [FitnessDatabase.dateString(now), FitnessDatabase.dateString(now), sessionId]
            )
            try enqueue(
                context: context,
                db,
                type: .strengthSession,
                id: sessionId,
                baseRevision: session.revision,
                payload: StrengthSessionPayload(
                    id: session.id, title: session.title, startedAtUtc: session.startedAt,
                    localTimezone: TimeZone.current.identifier, plannedSessionId: session.plannedSessionId,
                    status: "aborted", endedAtUtc: now, sessionRpe: nil, perceivedPerformance: nil, notes: nil
                ),
                now: now
            )
            if let planId = session.plannedSessionId {
                try db.execute(
                    sql: "UPDATE fitness_planned_sessions SET is_completed=1,client_updated_at=? WHERE id=?",
                    arguments: [FitnessDatabase.dateString(now), planId]
                )
            }
        }
    }

    func bodyIssues() throws -> [FitnessBodyIssue] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM fitness_body_issues WHERE deleted_at IS NULL ORDER BY resolved_at IS NULL DESC, observed_at DESC"
            ).map(Self.bodyIssue)
        }
    }

    @discardableResult
    func addBodyIssue(_ issue: NewBodyIssue, sessionId: String? = nil) throws -> String {
        let id = UUID().uuidString
        try context.write { db in
            try insertBodyIssue(context: context, issue, id: id, sessionId: sessionId, db: db, now: Date())
        }
        return id
    }

    func strengthProgress(limit: Int = 20) throws -> [FitnessStrengthSummary] {
        try context.read { db in
            let sessions = try Row.fetchAll(
                db,
                sql: """
                        SELECT * FROM fitness_strength_sessions
                        WHERE status = 'completed' AND deleted_at IS NULL ORDER BY ended_at DESC LIMIT ?
                    """,
                arguments: [limit]
            ).map(Self.session)
            let groupRows = try Row.fetchAll(
                db,
                sql: """
                    WITH recent_sessions AS (
                      SELECT id FROM fitness_strength_sessions
                      WHERE status='completed' AND deleted_at IS NULL
                      ORDER BY ended_at DESC LIMIT ?
                    )
                    SELECT g.*,e.session_id AS owner_session_id
                    FROM fitness_strength_set_groups g
                    JOIN fitness_strength_session_exercises e ON e.id=g.session_exercise_id
                    JOIN recent_sessions r ON r.id=e.session_id
                    WHERE g.deleted_at IS NULL AND e.deleted_at IS NULL
                    ORDER BY e.session_id,g.position
                    """,
                arguments: [limit]
            )
            let componentRows = try Row.fetchAll(
                db,
                sql: """
                    WITH recent_sessions AS (
                      SELECT id FROM fitness_strength_sessions
                      WHERE status='completed' AND deleted_at IS NULL
                      ORDER BY ended_at DESC LIMIT ?
                    )
                    SELECT c.* FROM fitness_strength_set_components c
                    JOIN fitness_strength_set_groups g ON g.id=c.group_id
                    JOIN fitness_strength_session_exercises e ON e.id=g.session_exercise_id
                    JOIN recent_sessions r ON r.id=e.session_id
                    WHERE c.deleted_at IS NULL AND g.deleted_at IS NULL AND e.deleted_at IS NULL
                    ORDER BY c.group_id,c.position
                    """,
                arguments: [limit]
            )
            var groupsBySession: [String: [FitnessSetGroup]] = [:]
            for row in groupRows {
                let sessionId: String = row["owner_session_id"]
                groupsBySession[sessionId, default: []].append(Self.group(row))
            }
            var componentsByGroup: [String: [FitnessSetComponent]] = [:]
            for row in componentRows {
                let component = try Self.component(row)
                componentsByGroup[component.groupId, default: []].append(component)
            }
            return sessions.compactMap { session in
                guard let endedAt = session.endedAt else { return nil }
                var working = 0
                var hard = 0
                var volume = 0.0
                var estimates: [Double] = []
                for group in groupsBySession[session.id] ?? [] {
                    let components = componentsByGroup[group.id] ?? []
                    if components.contains(where: FitnessCalculations.isPerformed)
                        && (group.status == .completed || group.status == .partial)
                        && (group.role == .working || group.role == .backoff || group.role == .test)
                    {
                        working += 1
                        if FitnessCalculations.isHardSet(group: group, components: components) { hard += 1 }
                    }
                    if group.status != .skipped && group.status != .aborted
                        && group.role != .warmup && group.role != .technique
                    {
                        volume += FitnessCalculations.volume(components)
                    }
                    if let estimate = FitnessCalculations.eligibleEpley(group: group, components: components) {
                        estimates.append(estimate)
                    }
                }
                return FitnessStrengthSummary(
                    sessionId: session.id,
                    title: session.title,
                    endedAt: endedAt,
                    workingSets: working,
                    hardSets: hard,
                    volumeKg: volume,
                    estimatedOneRepMaxKg: estimates.max()
                )
            }
        }
    }

    /// Observed exercise progress is partitioned by every semantic dimension
    /// that changes what a load/repetition means. Snapshot labels are retained;
    /// a renamed setup never rewrites the historical series.
    func strengthExerciseProgress(limitSessions: Int = 120) throws -> [FitnessStrengthProgressSeries] {
        try context.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT se.*,s.ended_at AS performed_at
                    FROM fitness_strength_session_exercises se
                    JOIN fitness_strength_sessions s ON s.id=se.session_id
                    WHERE s.status='completed' AND s.deleted_at IS NULL AND se.deleted_at IS NULL
                    ORDER BY s.ended_at DESC,se.position LIMIT ?
                    """, arguments: [max(1, limitSessions) * 24]
            )
            let rowLimit = max(1, limitSessions) * 24
            let groupRows = try Row.fetchAll(
                db,
                sql: """
                    WITH recent_exercises AS (
                      SELECT se.id FROM fitness_strength_session_exercises se
                      JOIN fitness_strength_sessions s ON s.id=se.session_id
                      WHERE s.status='completed' AND s.deleted_at IS NULL
                        AND se.deleted_at IS NULL
                      ORDER BY s.ended_at DESC,se.position LIMIT ?
                    )
                    SELECT g.* FROM fitness_strength_set_groups g
                    JOIN recent_exercises r ON r.id=g.session_exercise_id
                    WHERE g.status IN ('completed','partial') AND g.deleted_at IS NULL
                    ORDER BY g.session_exercise_id,g.position
                    """, arguments: [rowLimit]
            )
            let componentRows = try Row.fetchAll(
                db,
                sql: """
                    WITH recent_exercises AS (
                      SELECT se.id FROM fitness_strength_session_exercises se
                      JOIN fitness_strength_sessions s ON s.id=se.session_id
                      WHERE s.status='completed' AND s.deleted_at IS NULL
                        AND se.deleted_at IS NULL
                      ORDER BY s.ended_at DESC,se.position LIMIT ?
                    )
                    SELECT c.* FROM fitness_strength_set_components c
                    JOIN fitness_strength_set_groups g ON g.id=c.group_id
                    JOIN recent_exercises r ON r.id=g.session_exercise_id
                    WHERE g.status IN ('completed','partial')
                      AND g.deleted_at IS NULL AND c.deleted_at IS NULL
                    ORDER BY c.group_id,c.position
                    """, arguments: [rowLimit]
            )
            var groupsByExercise: [String: [FitnessSetGroup]] = [:]
            for groupRow in groupRows {
                let group = Self.group(groupRow)
                groupsByExercise[group.sessionExerciseId, default: []].append(group)
            }
            var componentsByGroup: [String: [FitnessSetComponent]] = [:]
            for componentRow in componentRows {
                let component = try Self.component(componentRow)
                componentsByGroup[component.groupId, default: []].append(component)
            }
            var series: [String: FitnessStrengthProgressSeries] = [:]
            for row in rows {
                let exercise = Self.sessionExercise(row)
                let performedAt = FitnessDatabase.date(row["performed_at"]) ?? exercise.updatedAt
                let identity = FitnessStrengthComparisonIdentity(
                    exerciseId: exercise.exerciseId, setupId: exercise.setupId,
                    setupLabelSnapshot: exercise.setupName, loadModeSnapshot: exercise.setupLoadModeSnapshot,
                    repModeSnapshot: exercise.repCountModeSnapshot,
                    unilateralModeSnapshot: exercise.unilateralModeSnapshot
                )
                var value =
                    series[identity.id]
                    ?? FitnessStrengthProgressSeries(
                        identity: identity, exerciseName: exercise.exerciseName, points: []
                    )
                for group in groupsByExercise[exercise.id] ?? [] {
                    let components = componentsByGroup[group.id] ?? []
                    let performed = components.filter(FitnessCalculations.isPerformed)
                    guard !performed.isEmpty else { continue }
                    let recordReps = performed.compactMap(Self.recordRepetitions).max()
                    let load = performed.compactMap { $0.normalizedExternalLoadKg ?? $0.loadKg }.max()
                    value.points.append(
                        FitnessStrengthProgressPoint(
                            id: group.id, performedAt: performedAt, recordReps: recordReps,
                            normalizedLoadKg: load, volumeKg: FitnessCalculations.volume(performed),
                            eligibleE1RMKg: FitnessCalculations.eligibleEpley(group: group, components: performed)
                        ))
                }
                if !value.points.isEmpty { series[identity.id] = value }
            }
            return series.values.map { item in
                var value = item
                value.points.sort { $0.performedAt < $1.performedAt }
                return value
            }.sorted { lhs, rhs in
                let left = lhs.points.last?.performedAt ?? .distantPast
                let right = rhs.points.last?.performedAt ?? .distantPast
                return left > right
            }
        }
    }

    func muscleExposure(limitSessions: Int = 120, now: Date = Date()) throws -> [FitnessMuscleExposure] {
        try context.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT se.*,s.ended_at AS performed_at,e.muscle_roles_json
                    FROM fitness_strength_session_exercises se
                    JOIN fitness_strength_sessions s ON s.id=se.session_id
                    JOIN fitness_exercises e ON e.id=se.exercise_id
                    WHERE s.status='completed' AND s.deleted_at IS NULL
                      AND se.deleted_at IS NULL AND e.deleted_at IS NULL
                    ORDER BY s.ended_at DESC,se.position LIMIT ?
                    """, arguments: [max(1, limitSessions) * 24]
            )
            let rowLimit = max(1, limitSessions) * 24
            let groupRows = try Row.fetchAll(
                db,
                sql: """
                    WITH recent_exercises AS (
                      SELECT se.id FROM fitness_strength_session_exercises se
                      JOIN fitness_strength_sessions s ON s.id=se.session_id
                      JOIN fitness_exercises e ON e.id=se.exercise_id
                      WHERE s.status='completed' AND s.deleted_at IS NULL
                        AND se.deleted_at IS NULL AND e.deleted_at IS NULL
                      ORDER BY s.ended_at DESC,se.position LIMIT ?
                    )
                    SELECT g.* FROM fitness_strength_set_groups g
                    JOIN recent_exercises r ON r.id=g.session_exercise_id
                    WHERE g.role IN ('working','backoff','test')
                      AND g.status IN ('completed','partial') AND g.deleted_at IS NULL
                    ORDER BY g.session_exercise_id,g.position
                    """, arguments: [rowLimit]
            )
            let componentRows = try Row.fetchAll(
                db,
                sql: """
                    WITH recent_exercises AS (
                      SELECT se.id FROM fitness_strength_session_exercises se
                      JOIN fitness_strength_sessions s ON s.id=se.session_id
                      JOIN fitness_exercises e ON e.id=se.exercise_id
                      WHERE s.status='completed' AND s.deleted_at IS NULL
                        AND se.deleted_at IS NULL AND e.deleted_at IS NULL
                      ORDER BY s.ended_at DESC,se.position LIMIT ?
                    )
                    SELECT c.* FROM fitness_strength_set_components c
                    JOIN fitness_strength_set_groups g ON g.id=c.group_id
                    JOIN recent_exercises r ON r.id=g.session_exercise_id
                    WHERE g.role IN ('working','backoff','test')
                      AND g.status IN ('completed','partial')
                      AND g.deleted_at IS NULL AND c.deleted_at IS NULL
                    ORDER BY c.group_id,c.position
                    """, arguments: [rowLimit]
            )
            var groupsByExercise: [String: [FitnessSetGroup]] = [:]
            for groupRow in groupRows {
                let group = Self.group(groupRow)
                groupsByExercise[group.sessionExerciseId, default: []].append(group)
            }
            var componentsByGroup: [String: [FitnessSetComponent]] = [:]
            for componentRow in componentRows {
                let component = try Self.component(componentRow)
                componentsByGroup[component.groupId, default: []].append(component)
            }
            var direct: [String: Int] = [:]
            var indirect: [String: Double] = [:]
            var hard: [String: Int] = [:]
            var unknown: [String: Int] = [:]
            var days: [String: Set<String>] = [:]
            var last: [String: Date] = [:]
            for row in rows {
                let exercise = Self.sessionExercise(row)
                let roles = try Self.decodeMuscleRoles(row["muscle_roles_json"])
                guard !roles.isEmpty else { continue }
                let performedAt = FitnessDatabase.date(row["performed_at"]) ?? exercise.updatedAt
                let day = Self.dateOnly(performedAt)
                for group in groupsByExercise[exercise.id] ?? [] {
                    let components = componentsByGroup[group.id] ?? []
                    guard components.contains(where: FitnessCalculations.isPerformed) else { continue }
                    let isHard = FitnessCalculations.isHardSet(group: group, components: components)
                    let hardnessUnknown =
                        !isHard
                        && !components.contains { $0.rir != nil || $0.rpe != nil }
                        && (group.failureState == .none || group.failureState == .unknown)
                    for role in roles {
                        let key = role.muscleGroupKey
                        if role.role == "primary" {
                            direct[key, default: 0] += 1
                            if isHard { hard[key, default: 0] += 1 }
                            if hardnessUnknown { unknown[key, default: 0] += 1 }
                        } else {
                            indirect[key, default: 0] += max(0, role.contributionWeight)
                        }
                        days[key, default: []].insert(day)
                        last[key] = max(last[key] ?? .distantPast, performedAt)
                    }
                }
            }
            let keys = Set(direct.keys).union(indirect.keys)
            return keys.map { key in
                FitnessMuscleExposure(
                    muscleGroupKey: key, directWorkingSets: direct[key, default: 0],
                    indirectSetEquivalents: indirect[key, default: 0], directHardSets: hard[key, default: 0],
                    unknownHardnessSets: unknown[key, default: 0], frequencyDays: days[key]?.count ?? 0,
                    daysSinceLastTrained: last[key].map { max(0, Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0) }
                )
            }.sorted { $0.directWorkingSets > $1.directWorkingSets }
        }
    }

    private static func recordRepetitions(_ component: FitnessSetComponent) -> Int? {
        if let reps = component.reps, reps > 0 { return reps }
        guard let left = component.repsLeft, left > 0,
            let right = component.repsRight, right > 0
        else { return nil }
        return min(left, right)
    }

    // MARK: Sync access
}
