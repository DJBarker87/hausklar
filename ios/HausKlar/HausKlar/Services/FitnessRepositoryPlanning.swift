import Foundation
import GRDB

/// This extension is isolated to FitnessRepository's single actor. Its context
/// is never used independently of that facade, preserving call-site serialization.
extension FitnessRepository {
    // MARK: Goals and planning

    func goals() throws -> [FitnessGoal] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM fitness_goals WHERE deleted_at IS NULL ORDER BY target_date, client_updated_at DESC"
            ).map(Self.goal)
        }
    }

    func trainingPhases() throws -> [FitnessTrainingPhase] {
        try context.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM fitness_training_phases WHERE deleted_at IS NULL ORDER BY starts_on DESC"
            )
            let linkRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_training_phase_goal_links
                    WHERE deleted_at IS NULL ORDER BY phase_id, role, goal_id
                    """
            )
            var linksByPhase: [String: [FitnessGoalLink]] = [:]
            for link in linkRows {
                let phaseId: String = link["phase_id"]
                linksByPhase[phaseId, default: []].append(
                    FitnessGoalLink(
                        id: link["id"], phaseId: phaseId, goalId: link["goal_id"],
                        role: FitnessGoalLinkRole(rawValue: link["role"]) ?? .secondary
                    )
                )
            }
            return rows.map { row in
                let phaseId: String = row["id"]
                return FitnessTrainingPhase(
                    id: phaseId, phaseType: row["phase_type"], name: row["title"],
                    startsOn: row["starts_on"], endsOn: row["ends_on"],
                    goalLinks: linksByPhase[phaseId] ?? [],
                    revision: row["revision"],
                    updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast
                )
            }
        }
    }

    @discardableResult
    func createTrainingPhase(
        phaseType: String,
        name: String,
        startsOn: Date,
        endsOn: Date?,
        goalLinks: [(goalId: String, role: FitnessGoalLinkRole)]
    ) throws -> FitnessTrainingPhase {
        guard goalLinks.filter({ $0.role == .primary }).count <= 1 else {
            throw FitnessRepositoryError.multiplePrimaryGoals
        }
        let now = Date()
        let phaseId = UUID().uuidString
        let links = goalLinks.map {
            FitnessGoalLink(id: UUID().uuidString, phaseId: phaseId, goalId: $0.goalId, role: $0.role)
        }
        let phase = FitnessTrainingPhase(
            id: phaseId, phaseType: phaseType, name: name,
            startsOn: Self.dateOnly(startsOn), endsOn: endsOn.map(Self.dateOnly),
            goalLinks: links, revision: 0, updatedAt: now
        )
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_training_phases
                    (id, phase_type, title, starts_on, ends_on, revision, client_updated_at, origin_device_id)
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    phase.id, phase.phaseType, phase.name, phase.startsOn, phase.endsOn,
                    FitnessDatabase.dateString(now), try context.verifiedDeviceId(),
                ]
            )
            for link in links {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_training_phase_goal_links
                        (id, phase_id, goal_id, role, client_updated_at) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [link.id, phase.id, link.goalId, link.role.rawValue, FitnessDatabase.dateString(now)]
                )
            }
            try enqueue(
                context: context,
                db,
                type: .trainingPhase,
                id: phase.id,
                baseRevision: nil,
                payload: TrainingPhasePayload(
                    id: phase.id, phaseType: phase.phaseType, name: phase.name,
                    startsOn: phase.startsOn, endsOn: phase.endsOn,
                    goalLinks: links.map { GoalLinkPayload(goalId: $0.goalId, role: $0.role.rawValue) }
                ),
                now: now
            )
        }
        return phase
    }

    @discardableResult
    func createGoal(
        title: String,
        metric: String,
        targetValue: Double?,
        unit: String?,
        targetDate: Date?
    ) throws -> FitnessGoal {
        let now = Date()
        let goal = FitnessGoal(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            metric: metric,
            targetValue: targetValue,
            unit: unit,
            targetDate: targetDate,
            revision: 0,
            updatedAt: now
        )
        let payload = GoalPayload(
            id: goal.id,
            goalType: "fitness",
            metricKey: metric,
            name: goal.title,
            startsOn: Self.dateOnly(now),
            targetValue: targetValue,
            unitKey: unit,
            targetDate: targetDate.map(Self.dateOnly)
        )
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_goals
                    (id, title, metric, target_value, unit, target_date, revision, client_updated_at, origin_device_id)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    goal.id, goal.title, goal.metric, goal.targetValue, goal.unit,
                    goal.targetDate.map(FitnessDatabase.dateString),
                    FitnessDatabase.dateString(now), try context.verifiedDeviceId(),
                ]
            )
            try enqueue(context: context, db, type: .goal, id: goal.id, baseRevision: nil, payload: payload, now: now)
        }
        return goal
    }

    @discardableResult
    func saveManualSleepSession(
        existing: FitnessSleepSessionDTO?,
        start: Date,
        end: Date,
        awakeMinutes: Double?,
        notes: String?
    ) throws -> FitnessSleepSessionDTO {
        guard end > start else { throw FitnessRepositoryError.invalidSleepWindow }
        let elapsed = end.timeIntervalSince(start)
        let awake = awakeMinutes.map { max(0, $0 * 60) }
        guard (awake ?? 0) <= elapsed else { throw FitnessRepositoryError.invalidSleepWindow }
        let now = Date()
        let id = existing?.id ?? UUID().uuidString
        let payload = ManualSleepSessionPayload(
            id: id, sleepStartUtc: FitnessDatabase.dateString(start),
            sleepEndUtc: FitnessDatabase.dateString(end),
            durationS: elapsed - (awake ?? 0), awakeDurationS: awake,
            sourceQuality: "manual", sourceRecordId: nil, sourceStages: [],
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let value = FitnessSleepSessionDTO(
            id: id, sleepStartUtc: payload.sleepStartUtc, sleepEndUtc: payload.sleepEndUtc,
            durationS: payload.durationS, awakeDurationS: awake, sourceQuality: "manual",
            sourceStages: [], sourceRecordId: nil, source: nil, notes: payload.notes,
            revision: existing?.revision ?? 0, createdAt: existing?.createdAt,
            updatedAt: FitnessDatabase.dateString(now), deletedAt: nil
        )
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_sleep_sessions
                    (id,sleep_start_utc,sleep_end_utc,duration_s,awake_duration_s,
                     source_quality,source_stages_json,notes,revision,client_updated_at,payload_json)
                    VALUES (?,?,?,?,?,?,'[]',?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      sleep_start_utc=excluded.sleep_start_utc,sleep_end_utc=excluded.sleep_end_utc,
                      duration_s=excluded.duration_s,awake_duration_s=excluded.awake_duration_s,
                      source_quality='manual',notes=excluded.notes,
                      client_updated_at=excluded.client_updated_at,payload_json=excluded.payload_json,
                      deleted_at=NULL
                    """,
                arguments: [
                    id, payload.sleepStartUtc, payload.sleepEndUtc, payload.durationS, awake,
                    "manual", payload.notes, existing?.revision ?? 0,
                    FitnessDatabase.dateString(now), String(decoding: try context.encode(value), as: UTF8.self),
                ]
            )
            try enqueue(
                context: context,
                db, type: .sleepSession, id: id, baseRevision: existing?.revision,
                payload: payload, now: now
            )
        }
        return value
    }

    // MARK: Cycle tracking

    /// The Fitness database is the single offline source of truth for cycle
    /// tracking. Calendar reads server projections; it does not own mutations.
    func cycleProfiles() throws -> [CycleProfileDTO] {
        try context.read { db in
            let settings = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_cycle_settings
                    WHERE deleted_at IS NULL ORDER BY is_owner DESC,owner_name,id
                    """
            )
            return try settings.map { row in
                let ownerUserId: String = row["owner_user_id"]
                let periods = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM fitness_cycle_period_starts
                        WHERE owner_user_id=? AND deleted_at IS NULL
                        ORDER BY started_on DESC,client_updated_at DESC
                        """, arguments: [ownerUserId]
                ).map { period in
                    CyclePeriodStartDTO(
                        id: period["id"], startedOn: period["started_on"],
                        createdAt: period["created_at"], updatedAt: period["client_updated_at"],
                        revision: period["revision"]
                    )
                }
                let isOwner = (row["is_owner"] as Int) != 0
                let cycleLength: Int = row["cycle_length_days"]
                let storedLatest: String? = row["latest_period_start"]
                let latest = isOwner ? (periods.first?.startedOn ?? storedLatest) : storedLatest
                let calculated = latest.flatMap { Self.cycleProjection(startedOn: $0, length: cycleLength) }
                return CycleProfileDTO(
                    id: row["id"], ownerUserId: ownerUserId, ownerName: row["owner_name"],
                    isOwner: isOwner, cycleLengthDays: cycleLength,
                    showPeriodStarts: (row["show_period_starts"] as Int) != 0,
                    showPredictedPeriod: (row["show_predicted_period"] as Int) != 0,
                    showEstimatedOvulation: (row["show_estimated_ovulation"] as Int) != 0,
                    sharePeriodStartsWithAdults: (row["share_period_starts_with_adults"] as Int) != 0,
                    sharePredictedPeriodWithAdults: (row["share_predicted_period_with_adults"] as Int) != 0,
                    shareEstimatedOvulationWithAdults: (row["share_estimated_ovulation_with_adults"] as Int) != 0,
                    latestPeriodStart: latest,
                    predictedNextPeriod: isOwner ? calculated?.predicted : row["predicted_next_period"],
                    estimatedOvulation: isOwner ? calculated?.ovulation : row["estimated_ovulation"],
                    periodStarts: periods, revision: row["revision"],
                    createdAt: row["created_at"], updatedAt: row["client_updated_at"]
                )
            }
        }
    }

    /// Caches the privacy-filtered REST representation without overwriting an
    /// optimistic record which is still waiting in the Fitness outbox.
    func cacheCycleProfiles(_ profiles: [CycleProfileDTO]) throws {
        let now = FitnessDatabase.dateString(Date())
        try context.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_cycle_period_starts SET deleted_at=?
                    WHERE origin_device_id='server' AND NOT EXISTS (
                      SELECT 1 FROM fitness_outbox o
                      WHERE o.entity_type=? AND o.entity_id=fitness_cycle_period_starts.id
                    )
                    """, arguments: [now, FitnessEntityType.cyclePeriodStart.rawValue])
            try db.execute(
                sql: """
                    UPDATE fitness_cycle_settings SET deleted_at=?
                    WHERE origin_device_id='server' AND NOT EXISTS (
                      SELECT 1 FROM fitness_outbox o
                      WHERE o.entity_type=? AND o.entity_id=fitness_cycle_settings.id
                    )
                    """, arguments: [now, FitnessEntityType.cycleSettings.rawValue])

            for profile in profiles {
                let settingsPending =
                    (try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                        arguments: [FitnessEntityType.cycleSettings.rawValue, profile.id]
                    ) ?? 0) > 0
                if !settingsPending {
                    let created = profile.createdAt.isEmpty ? profile.updatedAt : profile.createdAt
                    try db.execute(
                        sql: """
                            INSERT INTO fitness_cycle_settings
                            (id,owner_user_id,owner_name,is_owner,cycle_length_days,
                             show_period_starts,show_predicted_period,show_estimated_ovulation,
                             share_period_starts_with_adults,share_predicted_period_with_adults,
                             share_estimated_ovulation_with_adults,latest_period_start,
                             predicted_next_period,estimated_ovulation,revision,server_updated_at,
                             client_updated_at,origin_device_id,created_at,deleted_at)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'server',?,NULL)
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
                              created_at=excluded.created_at,deleted_at=NULL
                            """,
                        arguments: [
                            profile.id, profile.ownerUserId, profile.ownerName, profile.isOwner,
                            profile.cycleLengthDays, profile.showPeriodStarts,
                            profile.showPredictedPeriod, profile.showEstimatedOvulation,
                            profile.sharePeriodStartsWithAdults,
                            profile.sharePredictedPeriodWithAdults,
                            profile.shareEstimatedOvulationWithAdults,
                            profile.latestPeriodStart, profile.predictedNextPeriod,
                            profile.estimatedOvulation, profile.revision, profile.updatedAt,
                            profile.updatedAt, created,
                        ])
                }
                for period in profile.periodStarts {
                    let pending =
                        (try Int.fetchOne(
                            db, sql: "SELECT COUNT(*) FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                            arguments: [FitnessEntityType.cyclePeriodStart.rawValue, period.id]
                        ) ?? 0) > 0
                    guard !pending else { continue }
                    try db.execute(
                        sql: """
                            INSERT INTO fitness_cycle_period_starts
                            (id,owner_user_id,settings_id,started_on,revision,server_updated_at,
                             client_updated_at,origin_device_id,created_at,deleted_at)
                            VALUES (?,?,?,?,?,?,?,'server',?,NULL)
                            ON CONFLICT(id) DO UPDATE SET
                              owner_user_id=excluded.owner_user_id,settings_id=excluded.settings_id,
                              started_on=excluded.started_on,revision=excluded.revision,
                              server_updated_at=excluded.server_updated_at,
                              client_updated_at=excluded.client_updated_at,origin_device_id='server',
                              created_at=excluded.created_at,deleted_at=NULL
                            """,
                        arguments: [
                            period.id, profile.ownerUserId, profile.id, period.startedOn,
                            period.revision ?? 0, period.updatedAt, period.updatedAt, period.createdAt,
                        ])
                }
            }
        }
    }

    @discardableResult
    func saveCycleSettings(
        existing: CycleProfileDTO?,
        cycleLengthDays: Int,
        showPeriodStarts: Bool,
        showPredictedPeriod: Bool,
        showEstimatedOvulation: Bool,
        sharePeriodStartsWithAdults: Bool,
        sharePredictedPeriodWithAdults: Bool,
        shareEstimatedOvulationWithAdults: Bool
    ) throws -> CycleProfileDTO {
        guard (10...365).contains(cycleLengthDays) else {
            throw FitnessRepositoryError.invalidCycleLength
        }
        let now = Date()
        let timestamp = FitnessDatabase.dateString(now)
        let id = existing?.id ?? UUID().uuidString
        let ownerUserId = existing?.ownerUserId ?? activeCycleOwnerId()
        let request = UpdateCycleSettingsRequest(
            id: id, cycleLengthDays: cycleLengthDays,
            showPeriodStarts: showPeriodStarts,
            showPredictedPeriod: showPredictedPeriod,
            showEstimatedOvulation: showEstimatedOvulation,
            sharePeriodStartsWithAdults: sharePeriodStartsWithAdults,
            sharePredictedPeriodWithAdults: sharePredictedPeriodWithAdults,
            shareEstimatedOvulationWithAdults: shareEstimatedOvulationWithAdults
        )
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_cycle_settings
                    (id,owner_user_id,owner_name,is_owner,cycle_length_days,
                     show_period_starts,show_predicted_period,show_estimated_ovulation,
                     share_period_starts_with_adults,share_predicted_period_with_adults,
                     share_estimated_ovulation_with_adults,latest_period_start,
                     predicted_next_period,estimated_ovulation,revision,server_updated_at,
                     client_updated_at,origin_device_id,created_at,deleted_at)
                    VALUES (?,?,?,1,?,?,?,?,?,?,?,?,?,?,?,NULL,?,?,?,NULL)
                    ON CONFLICT(id) DO UPDATE SET
                      cycle_length_days=excluded.cycle_length_days,
                      show_period_starts=excluded.show_period_starts,
                      show_predicted_period=excluded.show_predicted_period,
                      show_estimated_ovulation=excluded.show_estimated_ovulation,
                      share_period_starts_with_adults=excluded.share_period_starts_with_adults,
                      share_predicted_period_with_adults=excluded.share_predicted_period_with_adults,
                      share_estimated_ovulation_with_adults=excluded.share_estimated_ovulation_with_adults,
                      client_updated_at=excluded.client_updated_at,
                      origin_device_id=excluded.origin_device_id,deleted_at=NULL
                    """,
                arguments: [
                    id, ownerUserId, existing?.ownerName ?? "You", cycleLengthDays,
                    showPeriodStarts, showPredictedPeriod, showEstimatedOvulation,
                    sharePeriodStartsWithAdults, sharePredictedPeriodWithAdults,
                    shareEstimatedOvulationWithAdults, existing?.latestPeriodStart,
                    existing?.predictedNextPeriod, existing?.estimatedOvulation,
                    existing?.revision ?? 0, timestamp, try context.verifiedDeviceId(), existing?.createdAt ?? timestamp,
                ])
            // Settings are a replace-style resource; only the latest unsent
            // payload is useful and avoids self-conflicts after repeated edits.
            try db.execute(
                sql: "DELETE FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                arguments: [FitnessEntityType.cycleSettings.rawValue, id]
            )
            try enqueue(
                context: context,
                db, type: .cycleSettings, id: id, baseRevision: existing?.revision,
                payload: request, now: now
            )
        }
        guard let saved = try cycleProfiles().first(where: { $0.id == id }) else {
            throw FitnessRepositoryError.missingCycleSettings
        }
        return saved
    }

    @discardableResult
    func recordCyclePeriodStart(
        profile: CycleProfileDTO, startedOn: String
    ) throws -> CyclePeriodStartDTO {
        guard Self.validDateOnly(startedOn) else { throw FitnessRepositoryError.invalidCycleDate }
        let now = Date()
        let timestamp = FitnessDatabase.dateString(now)
        let id = UUID().uuidString
        let request = CreatePeriodStartRequest(id: id, startedOn: startedOn)
        let period = CyclePeriodStartDTO(
            id: id, startedOn: startedOn, createdAt: timestamp, updatedAt: timestamp, revision: 0
        )
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_cycle_period_starts
                    (id,owner_user_id,settings_id,started_on,revision,client_updated_at,
                     origin_device_id,created_at,deleted_at)
                    VALUES (?,?,?,?,0,?,?,?,NULL)
                    """,
                arguments: [
                    id, profile.ownerUserId, profile.id, startedOn, timestamp, try context.verifiedDeviceId(), timestamp,
                ])
            try enqueue(
                context: context,
                db, type: .cyclePeriodStart, id: id, baseRevision: nil,
                payload: request, now: now
            )
        }
        return period
    }

    func deleteCyclePeriodStart(_ period: CyclePeriodStartDTO) throws {
        let now = Date()
        let timestamp = FitnessDatabase.dateString(now)
        try context.write { db in
            let unsyncedCreate =
                (try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM fitness_outbox
                        WHERE entity_type=? AND entity_id=? AND operation='upsert' AND base_revision IS NULL
                        """, arguments: [FitnessEntityType.cyclePeriodStart.rawValue, period.id]) ?? 0) > 0
            if unsyncedCreate {
                try db.execute(
                    sql: "DELETE FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                    arguments: [FitnessEntityType.cyclePeriodStart.rawValue, period.id]
                )
                try db.execute(
                    sql: "DELETE FROM fitness_cycle_period_starts WHERE id=?", arguments: [period.id]
                )
                return
            }
            try db.execute(
                sql: "UPDATE fitness_cycle_period_starts SET deleted_at=?,client_updated_at=? WHERE id=?",
                arguments: [timestamp, timestamp, period.id]
            )
            try enqueue(
                context: context,
                db, type: .cyclePeriodStart, id: period.id, operation: .delete,
                baseRevision: period.revision, payload: CyclePeriodStartDeletePayload(id: period.id), now: now
            )
        }
    }

    func activeCycleOwnerId() -> String {
        context.activeOwnerId()
    }

    static func validDateOnly(_ value: String) -> Bool {
        cycleDate(value) != nil
    }

    private static func cycleProjection(
        startedOn: String, length: Int
    ) -> (predicted: String, ovulation: String?)? {
        guard let start = cycleDate(startedOn) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let predicted = calendar.date(byAdding: .day, value: length, to: start) else { return nil }
        let predictedValue = dateOnly(predicted)
        let ovulation = calendar.date(byAdding: .day, value: -14, to: predicted).flatMap {
            $0 > start ? dateOnly($0) : nil
        }
        return (predictedValue, ovulation)
    }

    private static func cycleDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: parts[0], month: parts[1], day: parts[2]
        )
        guard let date = calendar.date(from: components) else { return nil }
        return dateOnly(date) == value ? date : nil
    }

    func plannedSessions() throws -> [FitnessPlannedSession] {
        try context.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM fitness_planned_sessions WHERE deleted_at IS NULL ORDER BY planned_for, client_updated_at"
            )
            let exerciseRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT planned_session_id, exercise_id
                    FROM fitness_planned_session_exercises
                    WHERE deleted_at IS NULL ORDER BY planned_session_id, position
                    """
            )
            var exerciseIDsByPlan: [String: [String]] = [:]
            for exercise in exerciseRows {
                let planId: String = exercise["planned_session_id"]
                exerciseIDsByPlan[planId, default: []].append(exercise["exercise_id"])
            }
            return try rows.map { row in
                let id: String = row["id"]
                let payload = try Self.decodeJSONDictionary(row["payload_json"])
                return FitnessPlannedSession(
                    id: id,
                    title: row["title"],
                    plannedFor: FitnessDatabase.date(row["planned_for"]),
                    exerciseIds: exerciseIDsByPlan[id] ?? [],
                    isCompleted: (row["is_completed"] as Int) != 0,
                    revision: row["revision"],
                    updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
                    status: row["status"] ?? ((row["is_completed"] as Int) != 0 ? "completed" : "proposed"),
                    availableWindowMinutes: row["available_window_minutes"], intendedGear: row["intended_gear"],
                    sportKey: row["sport_key"] ?? payload.fitnessRepositoryString("sport_key") ?? "strength",
                    timeWindowStart: FitnessDatabase.date(
                        row["time_window_start_utc"] ?? payload.fitnessRepositoryString("time_window_start_utc")),
                    timeWindowEnd: FitnessDatabase.date(
                        row["time_window_end_utc"] ?? payload.fitnessRepositoryString("time_window_end_utc")),
                    expectedDurationSeconds: row["expected_duration_s"] ?? payload.fitnessRepositoryDouble("expected_duration_s"),
                    expectedDistanceMetres: payload.fitnessRepositoryDouble("expected_distance_m"),
                    expectedPaceSecondsPerKilometre: payload.fitnessRepositoryDouble("expected_pace_s_per_km"),
                    intendedGearIds: try Self.decodeStringArray(
                        row["intended_gear_ids_json"]
                    ),
                    trainingProgrammeId: row["training_programme_id"], workoutVersionId: row["workout_version_id"],
                    scheduledStart: FitnessDatabase.date(payload.fitnessRepositoryString("scheduled_start_utc")),
                    scheduledDate: payload.fitnessRepositoryString("scheduled_date"),
                    priority: payload.fitnessRepositoryInt("priority") ?? 0, movable: payload.fitnessRepositoryBool("movable") ?? true,
                    visibility: payload.fitnessRepositoryString("visibility") ?? "private",
                    sharedTitle: payload.fitnessRepositoryString("shared_title"),
                    reasonForPlacement: payload.fitnessRepositoryString("reason_for_placement"),
                    sessionSource: payload.fitnessRepositoryString("session_source") ?? "user",
                    completionActivityId: payload.fitnessRepositoryString("completion_activity_id"),
                    completionState: payload.fitnessRepositoryString("completion_state"),
                    goalLinks: payload.fitnessRepositoryObjects("goal_links").compactMap { link in
                        guard let goalId = link.fitnessRepositoryString("goal_id"), let role = link.fitnessRepositoryString("role") else {
                            return nil
                        }
                        return FitnessPlannedSessionGoalLink(goalId: goalId, role: role)
                    }
                )
            }
        }
    }

    func deletePlannedSession(_ id: String) throws {
        let now = Date()
        let timestamp = FitnessDatabase.dateString(now)
        try context.write { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT revision FROM fitness_planned_sessions WHERE id=? AND deleted_at IS NULL",
                arguments: [id]
            )
            let unsyncedCreate = (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM fitness_outbox
                    WHERE entity_type=? AND entity_id=? AND operation='upsert'
                      AND base_revision IS NULL
                    """,
                arguments: [FitnessEntityType.plannedSession.rawValue, id]
            ) ?? 0) > 0
            try db.execute(
                sql: "DELETE FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                arguments: [FitnessEntityType.plannedSession.rawValue, id]
            )
            if unsyncedCreate {
                try db.execute(
                    sql: """
                        DELETE FROM fitness_planned_sets
                        WHERE planned_exercise_id IN (
                          SELECT id FROM fitness_planned_session_exercises
                          WHERE planned_session_id=?
                        )
                        """,
                    arguments: [id]
                )
                try db.execute(
                    sql: "DELETE FROM fitness_planned_session_exercises WHERE planned_session_id=?",
                    arguments: [id]
                )
                try db.execute(
                    sql: "DELETE FROM fitness_planned_sessions WHERE id=?",
                    arguments: [id]
                )
                return
            }
            try db.execute(
                sql: """
                    UPDATE fitness_planned_sets SET deleted_at=?,client_updated_at=?
                    WHERE deleted_at IS NULL AND planned_exercise_id IN (
                      SELECT id FROM fitness_planned_session_exercises
                      WHERE planned_session_id=?
                    )
                    """,
                arguments: [timestamp, timestamp, id]
            )
            try db.execute(
                sql: """
                    UPDATE fitness_planned_session_exercises
                    SET deleted_at=?,client_updated_at=?
                    WHERE planned_session_id=? AND deleted_at IS NULL
                    """,
                arguments: [timestamp, timestamp, id]
            )
            try db.execute(
                sql: """
                    UPDATE fitness_planned_sessions SET deleted_at=?,client_updated_at=?
                    WHERE id=? AND deleted_at IS NULL
                    """,
                arguments: [timestamp, timestamp, id]
            )
            let revision: Int? = row?["revision"]
            try enqueue(
                context: context,
                db, type: .plannedSession, id: id, operation: .delete,
                baseRevision: revision, payload: FitnessDeletePayload(id: id), now: now
            )
        }
    }

    @discardableResult
    func createPlannedSession(
        title: String,
        plannedFor: Date?,
        exerciseIds: [String],
        workingSets: Int = 3,
        targetReps: Int? = nil
    ) throws -> FitnessPlannedSession {
        let now = Date()
        let id = UUID().uuidString
        let uniqueIds = Array(NSOrderedSet(array: exerciseIds)) as? [String] ?? exerciseIds
        let plan = FitnessPlannedSession(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            plannedFor: plannedFor,
            exerciseIds: uniqueIds,
            isCompleted: false,
            revision: 0, updatedAt: now, status: plannedFor == nil ? "proposed" : "scheduled"
        )
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_planned_sessions
                    (id,title,planned_for,is_completed,revision,client_updated_at,origin_device_id,status,payload_json)
                    VALUES (?,?,?,0,0,?,?,?, '{}')
                    """,
                arguments: [
                    id, plan.title, plannedFor.map(FitnessDatabase.dateString),
                    FitnessDatabase.dateString(now), try context.verifiedDeviceId(), plan.status,
                ]
            )
            var payloadItems: [PlannedExercisePayload] = []
            for (position, requestedExerciseId) in uniqueIds.enumerated() {
                let exerciseId = try resolvedId(type: .exercise, id: requestedExerciseId, db: db)
                guard
                    let setupId = try String.fetchOne(
                        db,
                        sql: """
                            SELECT id FROM fitness_exercise_setups
                            WHERE exercise_id = ? AND deleted_at IS NULL ORDER BY is_default DESC, client_updated_at LIMIT 1
                            """,
                        arguments: [exerciseId]
                    )
                else { continue }
                let plannedExerciseId = UUID().uuidString
                try db.execute(
                    sql: """
                        INSERT INTO fitness_planned_session_exercises
                        (id, planned_session_id, exercise_id, exercise_setup_id, position, client_updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [plannedExerciseId, id, exerciseId, setupId, position, FitnessDatabase.dateString(now)]
                )
                var setPayloads: [PlannedSetPayload] = []
                for setPosition in 0..<max(1, workingSets) {
                    let plannedSetId = UUID().uuidString
                    try db.execute(
                        sql: """
                            INSERT INTO fitness_planned_sets
                            (id,planned_exercise_id,position,training_role,structure_type,component_count,
                             reps_min,reps_max,is_amrap,client_updated_at)
                            VALUES (?, ?, ?, 'working', 'straight', 1, ?, ?, 0, ?)
                            """,
                        arguments: [
                            plannedSetId, plannedExerciseId, setPosition, targetReps, targetReps,
                            FitnessDatabase.dateString(now),
                        ]
                    )
                    setPayloads.append(
                        PlannedSetPayload(
                            id: plannedSetId, sequence: setPosition, trainingRole: "working",
                            structureType: "straight", componentCount: 1,
                            repsMin: targetReps, repsMax: targetReps, loadMin: nil, loadMax: nil,
                            loadUnit: nil, rpeMin: nil, rpeMax: nil, rirMin: nil, rirMax: nil,
                            restS: nil, isAmrap: false, notes: nil
                        )
                    )
                }
                payloadItems.append(
                    PlannedExercisePayload(
                        id: plannedExerciseId, exerciseId: exerciseId, exerciseSetupId: setupId,
                        sequence: position, supersetGroupKey: nil, substitutionExerciseIds: [],
                        notes: nil, plannedSets: setPayloads
                    )
                )
            }
            let payload = PlannedSessionPayload(
                id: id, sportKey: "strength", title: plan.title,
                localTimezone: TimeZone.current.identifier,
                status: plannedFor == nil ? "proposed" : "scheduled",
                sessionSource: "user", scheduledStartUtc: plannedFor,
                exerciseItems: payloadItems
            )
            try enqueue(context: context, db, type: .plannedSession, id: id, baseRevision: nil, payload: payload, now: now)
        }
        return plan
    }

    /// Creates the calm, activity-first session used by the Sessions screen.
    /// Optional targets stay in the payload so the offline outbox and server
    /// receive exactly the same record without requiring a second edit.
    @discardableResult
    func createQuickPlannedSession(
        sportKey: String,
        title: String,
        scheduledStart: Date,
        expectedDurationSeconds: Int?,
        expectedDistanceMetres: Double?,
        expectedPaceSecondsPerKilometre: Double?,
        status: String,
        movable: Bool,
        programmeId: String?,
        primaryGoalId: String?
    ) throws -> FitnessPlannedSession {
        let cleanSport = sportKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSport.isEmpty, !cleanTitle.isEmpty,
            ["accepted", "scheduled"].contains(status),
            expectedDurationSeconds.map({ $0 > 0 }) ?? true,
            expectedDistanceMetres.map({ $0.isFinite && $0 > 0 }) ?? true,
            expectedPaceSecondsPerKilometre.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            throw FitnessRepositoryError.invalidStrengthPlan
        }
        let id = UUID().uuidString
        let now = Date()
        let scheduledDate = Self.localDateOnly(scheduledStart)
        let links = primaryGoalId.map { [StrengthPlanGoalLinkPayload(goalId: $0, role: "primary")] } ?? []
        let payload = DetailedPlannedSessionPayload(
            id: id, sportKey: cleanSport, title: cleanTitle,
            localTimezone: TimeZone.current.identifier,
            trainingProgrammeId: programmeId, workoutVersionId: nil,
            status: status, sessionSource: "user", scheduledStartUtc: scheduledStart,
            scheduledDate: scheduledDate, timeWindowStartUtc: nil, timeWindowEndUtc: nil,
            expectedDurationS: expectedDurationSeconds,
            expectedDistanceM: expectedDistanceMetres,
            expectedPaceSPerKm: expectedPaceSecondsPerKilometre,
            priority: 1, movable: movable, visibility: "private", sharedTitle: nil,
            reasonForPlacement: nil, completionActivityId: nil, completionState: nil,
            goalLinks: links, exerciseItems: [], gearLinks: [], intendedGearIds: []
        )
        let payloadJSON = String(decoding: try context.encode(payload), as: UTF8.self)
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_planned_sessions
                    (id,title,planned_for,is_completed,training_programme_id,workout_version_id,
                     revision,client_updated_at,origin_device_id,status,available_window_minutes,
                     intended_gear,payload_json,sport_key,time_window_start_utc,time_window_end_utc,
                     expected_duration_s,intended_gear_ids_json,deleted_at)
                    VALUES (?,?,?,0,?,NULL,0,?,?,?,NULL,NULL,?,?,NULL,NULL,?,'[]',NULL)
                    """,
                arguments: [
                    id, cleanTitle, FitnessDatabase.dateString(scheduledStart), programmeId,
                    FitnessDatabase.dateString(now), try context.verifiedDeviceId(), status, payloadJSON, cleanSport,
                    expectedDurationSeconds,
                ]
            )
            try enqueue(context: context, db, type: .plannedSession, id: id, baseRevision: nil, payload: payload, now: now)
        }
        return FitnessPlannedSession(
            id: id, title: cleanTitle, plannedFor: scheduledStart, exerciseIds: [], isCompleted: false,
            revision: 0, updatedAt: now, status: status, sportKey: cleanSport,
            expectedDurationSeconds: expectedDurationSeconds.map(Double.init),
            expectedDistanceMetres: expectedDistanceMetres,
            expectedPaceSecondsPerKilometre: expectedPaceSecondsPerKilometre,
            trainingProgrammeId: programmeId, scheduledStart: scheduledStart,
            scheduledDate: scheduledDate, priority: 1, movable: movable,
            goalLinks: primaryGoalId.map { [.init(goalId: $0, role: "primary")] } ?? []
        )
    }

    @discardableResult
    func updatePlannedSession(_ draft: FitnessPlannedSessionEditDraft) throws -> FitnessPlannedSession {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, (0...100).contains(draft.priority),
            draft.expectedDurationSeconds.map({ $0 >= 0 }) ?? true,
            draft.expectedDistanceMetres.map({ $0.isFinite && $0 >= 0 }) ?? true,
            draft.expectedPaceSecondsPerKilometre.map({ $0.isFinite && $0 > 0 }) ?? true,
            draft.precision != .window || draft.windowEnd > draft.scheduledStart,
            ["private", "logistics_shared"].contains(draft.visibility),
            draft.visibility != "logistics_shared"
                || draft.sharedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw FitnessRepositoryError.invalidStrengthPlan
        }
        let now = Date()
        return try context.write { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM fitness_planned_sessions WHERE id=? AND deleted_at IS NULL",
                    arguments: [draft.id]
                )
            else { throw FitnessRepositoryError.missingPlan }
            let previousVersion: String? = row["workout_version_id"]
            let replacesWorkout = previousVersion != draft.workoutVersionId
            let exerciseItems: [PlannedExercisePayload]
            if replacesWorkout, let versionId = draft.workoutVersionId {
                exerciseItems = try workoutVersionPlanItems(versionId: versionId, db: db)
                if draft.sportKey == "strength", exerciseItems.isEmpty {
                    throw FitnessRepositoryError.invalidStrengthPlan
                }
            } else if replacesWorkout {
                exerciseItems = []
            } else {
                exerciseItems = try existingPlanItems(planId: draft.id, db: db)
            }
            let scheduledStart: Date? = draft.precision == .exact ? draft.scheduledStart : nil
            let scheduledDate: String? =
                draft.precision == .date
                ? Self.localDateOnly(draft.scheduledDate)
                : Self.localDateOnly(draft.scheduledStart)
            let windowStart: Date? = draft.precision == .window ? draft.scheduledStart : nil
            let windowEnd: Date? = draft.precision == .window ? draft.windowEnd : nil
            let goalLinks =
                (draft.primaryGoalId.map {
                    [StrengthPlanGoalLinkPayload(goalId: $0, role: "primary")]
                } ?? [])
                + draft.otherGoalLinks.compactMap { link in
                    guard link.goalId != draft.primaryGoalId else { return nil }
                    return StrengthPlanGoalLinkPayload(goalId: link.goalId, role: link.role)
                }
            let payload = DetailedPlannedSessionPayload(
                id: draft.id, sportKey: draft.sportKey, title: title,
                localTimezone: TimeZone.current.identifier,
                trainingProgrammeId: draft.programmeId, workoutVersionId: draft.workoutVersionId,
                status: draft.status, sessionSource: draft.sessionSource,
                scheduledStartUtc: scheduledStart, scheduledDate: scheduledDate,
                timeWindowStartUtc: windowStart, timeWindowEndUtc: windowEnd,
                expectedDurationS: draft.expectedDurationSeconds,
                expectedDistanceM: draft.expectedDistanceMetres,
                expectedPaceSPerKm: draft.expectedPaceSecondsPerKilometre,
                priority: draft.priority, movable: draft.movable, visibility: draft.visibility,
                sharedTitle: draft.visibility == "logistics_shared"
                    ? Self.trimmedOrNil(draft.sharedTitle) : nil,
                reasonForPlacement: Self.trimmedOrNil(draft.reasonForPlacement),
                completionActivityId: draft.completionActivityId, completionState: draft.completionState,
                goalLinks: goalLinks, exerciseItems: exerciseItems,
                gearLinks: draft.intendedGearIds.map { .init(gearId: $0, role: "primary") },
                intendedGearIds: draft.intendedGearIds
            )
            let payloadJSON = String(decoding: try context.encode(payload), as: UTF8.self)
            let plannedFor: Date? = scheduledStart ?? windowStart ?? draft.scheduledDate
            try db.execute(
                sql: """
                    UPDATE fitness_planned_sessions SET title=?,planned_for=?,is_completed=?,
                      training_programme_id=?,workout_version_id=?,client_updated_at=?,origin_device_id=?,
                      status=?,available_window_minutes=?,payload_json=?,sport_key=?,
                      time_window_start_utc=?,time_window_end_utc=?,expected_duration_s=?,
                      intended_gear_ids_json=? WHERE id=?
                    """,
                arguments: [
                    title, plannedFor.map(FitnessDatabase.dateString), draft.status == "completed",
                    draft.programmeId, draft.workoutVersionId, FitnessDatabase.dateString(now), try context.verifiedDeviceId(),
                    draft.status, windowStart.flatMap { start in windowEnd.map { Int($0.timeIntervalSince(start) / 60) } },
                    payloadJSON, draft.sportKey, windowStart.map(FitnessDatabase.dateString),
                    windowEnd.map(FitnessDatabase.dateString), draft.expectedDurationSeconds,
                    try jsonString(.array(draft.intendedGearIds.map(JSONValue.string))), draft.id,
                ]
            )
            if replacesWorkout {
                try replacePlanItems(planId: draft.id, items: exerciseItems, now: now, db: db)
            }
            let revision: Int = row["revision"]
            try enqueue(
                context: context,
                db, type: .plannedSession, id: draft.id, baseRevision: revision, payload: payload, now: now
            )
            return FitnessPlannedSession(
                id: draft.id, title: title, plannedFor: plannedFor,
                exerciseIds: exerciseItems.map(\.exerciseId), isCompleted: draft.status == "completed",
                revision: revision, updatedAt: now, status: draft.status,
                availableWindowMinutes: windowStart.flatMap { start in windowEnd.map { Int($0.timeIntervalSince(start) / 60) } },
                sportKey: draft.sportKey, timeWindowStart: windowStart, timeWindowEnd: windowEnd,
                expectedDurationSeconds: draft.expectedDurationSeconds.map(Double.init),
                expectedDistanceMetres: draft.expectedDistanceMetres,
                expectedPaceSecondsPerKilometre: draft.expectedPaceSecondsPerKilometre,
                intendedGearIds: draft.intendedGearIds, trainingProgrammeId: draft.programmeId,
                workoutVersionId: draft.workoutVersionId, scheduledStart: scheduledStart,
                scheduledDate: scheduledDate, priority: draft.priority, movable: draft.movable,
                visibility: draft.visibility, sharedTitle: draft.sharedTitle,
                reasonForPlacement: draft.reasonForPlacement, sessionSource: draft.sessionSource,
                completionActivityId: draft.completionActivityId, completionState: draft.completionState,
                goalLinks: (draft.primaryGoalId.map { [.init(goalId: $0, role: "primary")] } ?? [])
                    + draft.otherGoalLinks.filter { $0.goalId != draft.primaryGoalId }
            )
        }
    }

    /// Publishes an immutable strength-workout version, explicitly accepts it,
    /// and creates the concrete planned session in one local transaction. Both
    /// records enter the offline outbox; sync priority guarantees the definition
    /// reaches the server before the plan that references it.
    @discardableResult
    func createStrengthPlan(_ draft: FitnessStrengthPlanDraft) throws -> FitnessPlannedSession {
        try validateStrengthPlan(draft)
        let now = Date()
        let definitionId = draft.definitionId ?? UUID().uuidString
        let versionId = UUID().uuidString
        return try context.write { db in
            let existingDefinition = try Row.fetchOne(
                db, sql: "SELECT * FROM fitness_workout_definitions WHERE id=? AND deleted_at IS NULL",
                arguments: [definitionId]
            )
            let versionNumber =
                (try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(version_number),0)+1 FROM fitness_workout_definition_versions WHERE workout_definition_id=?",
                    arguments: [definitionId]
                )) ?? 1
            let resolvedExercises = try resolvedPlanExercises(draft.exercises, db: db)
            var versionItems: [PlannedExercisePayload] = []
            for index in draft.exercises.indices {
                let item = draft.exercises[index]
                let resolved = resolvedExercises[index]
                let itemId = UUID().uuidString
                let sets = resolved.sets.enumerated().map { sequence, set in
                    plannedSetPayload(set, sequence: sequence)
                }
                try db.execute(
                    sql: """
                        INSERT INTO fitness_workout_version_exercises
                        (id,workout_version_id,exercise_id,exercise_setup_id,position,superset_group_key,
                         substitution_exercise_ids_json,notes)
                        VALUES (?,?,?,?,?,?,?,?)
                        """,
                    arguments: [
                        itemId, versionId, resolved.exerciseId, resolved.setupId, index,
                        item.supersetGroupKey, try jsonString(.array(resolved.substitutionIds.map(JSONValue.string))),
                        item.notes,
                    ]
                )
                for (setIndex, set) in resolved.sets.enumerated() {
                    try insertWorkoutVersionSet(
                        set, workoutVersionExerciseId: itemId, position: setIndex, db: db
                    )
                }
                versionItems.append(
                    PlannedExercisePayload(
                        id: itemId, exerciseId: resolved.exerciseId, exerciseSetupId: resolved.setupId,
                        sequence: index, supersetGroupKey: item.supersetGroupKey,
                        substitutionExerciseIds: resolved.substitutionIds, notes: item.notes,
                        plannedSets: sets
                    )
                )
            }
            let versionPayload = StrengthWorkoutVersionPayload(
                id: versionId, title: draft.title, purpose: draft.purpose,
                estimatedDurationS: draft.expectedDurationSeconds,
                structuredSummary: ["strength_exercise_count": .int(draft.exercises.count)],
                versionSource: "user", acceptedAt: now, exerciseItems: versionItems,
                runSteps: [], runCues: []
            )
            let definitionPayload = StrengthWorkoutDefinitionPayload(
                id: definitionId, sportKey: "strength", name: draft.name,
                description: draft.description, active: true, version: versionPayload
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_workout_definitions
                    (id,sport_key,name,description,active,current_version_id,revision,
                     client_updated_at,origin_device_id,payload_json,deleted_at)
                    VALUES (?,'strength',?,?,1,?,?,?, ?,?,NULL)
                    ON CONFLICT(id) DO UPDATE SET
                      sport_key='strength',name=excluded.name,description=excluded.description,
                      active=1,current_version_id=excluded.current_version_id,
                      client_updated_at=excluded.client_updated_at,payload_json=excluded.payload_json,
                      deleted_at=NULL
                    """,
                arguments: [
                    definitionId, draft.name, draft.description, versionId,
                    existingDefinition?["revision"] as Int? ?? 0,
                    FitnessDatabase.dateString(now), try context.verifiedDeviceId(),
                    String(decoding: try context.encode(definitionPayload), as: UTF8.self),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_workout_definition_versions
                    (id,workout_definition_id,version_number,title,purpose,estimated_duration_seconds,
                     estimated_distance_metres,structured_summary_json,version_source,created_at,accepted_at)
                    VALUES (?,?,?,?,?,?,NULL,?,'user',?,?)
                    """,
                arguments: [
                    versionId, definitionId, versionNumber, draft.title, draft.purpose,
                    draft.expectedDurationSeconds,
                    try jsonString(.object(["strength_exercise_count": .int(draft.exercises.count)])),
                    FitnessDatabase.dateString(now), FitnessDatabase.dateString(now),
                ]
            )
            try enqueue(
                context: context,
                db, type: .workoutDefinition, id: definitionId,
                baseRevision: existingDefinition?["revision"], payload: definitionPayload, now: now
            )
            return try insertStrengthPlannedSession(
                draft, workoutVersionId: versionId, db: db, now: now.addingTimeInterval(0.001),
                resolvedExercises: resolvedExercises
            )
        }
    }

    func savedStrengthWorkouts() throws -> [FitnessSavedStrengthWorkout] {
        try context.read { db in
            let definitionRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT d.id AS definition_id,d.name,v.*
                    FROM fitness_workout_definitions d
                    JOIN fitness_workout_definition_versions v ON v.id=d.current_version_id
                    WHERE d.sport_key='strength' AND d.active=1 AND d.deleted_at IS NULL
                      AND v.accepted_at IS NOT NULL
                    ORDER BY d.name COLLATE NOCASE
                    """
            )
            let exerciseRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.* FROM fitness_workout_version_exercises e
                    JOIN fitness_workout_definition_versions v ON v.id=e.workout_version_id
                    JOIN fitness_workout_definitions d ON d.current_version_id=v.id
                    WHERE d.sport_key='strength' AND d.active=1 AND d.deleted_at IS NULL
                      AND v.accepted_at IS NOT NULL
                    ORDER BY e.workout_version_id,e.position
                    """
            )
            let setRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM fitness_workout_version_sets s
                    JOIN fitness_workout_version_exercises e ON e.id=s.workout_version_exercise_id
                    JOIN fitness_workout_definition_versions v ON v.id=e.workout_version_id
                    JOIN fitness_workout_definitions d ON d.current_version_id=v.id
                    WHERE d.sport_key='strength' AND d.active=1 AND d.deleted_at IS NULL
                      AND v.accepted_at IS NOT NULL
                    ORDER BY s.workout_version_exercise_id,s.position
                    """
            )
            var setsByExercise: [String: [FitnessStrengthPlanSetDraft]] = [:]
            for set in setRows {
                let exerciseId: String = set["workout_version_exercise_id"]
                setsByExercise[exerciseId, default: []].append(
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
            var exercisesByVersion: [String: [FitnessStrengthPlanExerciseDraft]] = [:]
            for exercise in exerciseRows {
                let itemId: String = exercise["id"]
                let versionId: String = exercise["workout_version_id"]
                exercisesByVersion[versionId, default: []].append(
                    FitnessStrengthPlanExerciseDraft(
                        id: itemId, exerciseId: exercise["exercise_id"],
                        setupId: exercise["exercise_setup_id"],
                        substitutionExerciseIds: try Self.decodeStringArray(
                            exercise["substitution_exercise_ids_json"]
                        ),
                        supersetGroupKey: exercise["superset_group_key"], notes: exercise["notes"],
                        sets: setsByExercise[itemId] ?? []
                    )
                )
            }
            return definitionRows.map { row in
                let versionId: String = row["id"]
                return FitnessSavedStrengthWorkout(
                    definitionId: row["definition_id"], versionId: versionId, name: row["name"],
                    title: row["title"], purpose: row["purpose"],
                    acceptedAt: FitnessDatabase.date(row["accepted_at"]),
                    exercises: exercisesByVersion[versionId] ?? []
                )
            }
        }
    }

    @discardableResult
    func createPlan(from workout: FitnessSavedStrengthWorkout) throws -> FitnessPlannedSession {
        var draft = FitnessStrengthPlanDraft(
            definitionId: workout.definitionId, name: workout.name, title: workout.title,
            purpose: workout.purpose, exercises: workout.exercises
        )
        draft.scheduledStart = nil
        let now = Date()
        return try context.write { db in
            try insertStrengthPlannedSession(
                draft, workoutVersionId: workout.versionId, db: db, now: now
            )
        }
    }

    func recentCompletedStrengthSessions(limit: Int = 10) throws -> [FitnessStrengthSession] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_strength_sessions
                    WHERE status IN ('completed','partial') AND deleted_at IS NULL
                    ORDER BY COALESCE(ended_at,started_at) DESC LIMIT ?
                    """, arguments: [limit]
            ).map(Self.session)
        }
    }

    func strengthSession(id: String) throws -> FitnessStrengthSession? {
        try context.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM fitness_strength_sessions WHERE id=? AND deleted_at IS NULL",
                arguments: [id]
            ).map(Self.session)
        }
    }

    @discardableResult
    func copyCompletedSessionToPlan(_ session: FitnessStrengthSession) throws -> FitnessPlannedSession {
        let exercises: [FitnessStrengthPlanExerciseDraft] = try context.read { db in
            let exerciseRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_strength_session_exercises
                    WHERE session_id=? AND deleted_at IS NULL ORDER BY position
                    """, arguments: [session.id]
            )
            let groupRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT g.* FROM fitness_strength_set_groups g
                    JOIN fitness_strength_session_exercises se ON se.id=g.session_exercise_id
                    WHERE se.session_id=? AND se.deleted_at IS NULL AND g.deleted_at IS NULL
                      AND g.status NOT IN ('skipped','aborted')
                    ORDER BY g.session_exercise_id,g.position
                    """, arguments: [session.id]
            )
            let componentRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM fitness_strength_set_components c
                    JOIN fitness_strength_set_groups g ON g.id=c.group_id
                    JOIN fitness_strength_session_exercises se ON se.id=g.session_exercise_id
                    WHERE se.session_id=? AND se.deleted_at IS NULL AND g.deleted_at IS NULL
                      AND g.status NOT IN ('skipped','aborted') AND c.deleted_at IS NULL
                    ORDER BY c.group_id,c.position
                    """, arguments: [session.id]
            )
            var groupsByExercise: [String: [Row]] = [:]
            for group in groupRows {
                groupsByExercise[group["session_exercise_id"], default: []].append(group)
            }
            var firstComponentByGroup: [String: Row] = [:]
            for component in componentRows {
                let groupId: String = component["group_id"]
                if firstComponentByGroup[groupId] == nil {
                    firstComponentByGroup[groupId] = component
                }
            }
            return exerciseRows.map { exercise in
                let sessionExerciseId: String = exercise["id"]
                let groups = groupsByExercise[sessionExerciseId] ?? []
                let sets: [FitnessStrengthPlanSetDraft] = groups.map { group in
                    let groupId: String = group["id"]
                    let component = firstComponentByGroup[groupId]
                    let reps: Int? = component?["reps"]
                    let load: Double? = (component?["load_value"] as Double?) ?? component?["load_kg"]
                    return FitnessStrengthPlanSetDraft(
                        role: FitnessSetRole(rawValue: group["role"]) ?? .working,
                        structure: FitnessSetStructure(rawValue: group["structure_type"]) ?? .straight,
                        componentCount: 1, repsMin: reps, repsMax: reps, loadMin: load, loadMax: load,
                        loadUnit: component?["load_unit"] ?? (load == nil ? nil : "kg"),
                        rpeMin: component?["rpe"], rpeMax: component?["rpe"],
                        rirMin: component?["rir"], rirMax: component?["rir"],
                        restSeconds: component?["rest_before_s"],
                        isAMRAP: (group["is_amrap"] as Int) != 0, notes: group["notes"]
                    )
                }
                return FitnessStrengthPlanExerciseDraft(
                    exerciseId: exercise["exercise_id"], setupId: exercise["setup_id"],
                    supersetGroupKey: exercise["superset_group_key"], notes: exercise["notes"],
                    sets: sets.isEmpty ? [.init()] : sets
                )
            }
        }
        var draft = FitnessStrengthPlanDraft(
            name: "\(session.title) copy", title: session.title, exercises: exercises
        )
        draft.scheduledStart = nil
        let now = Date()
        return try context.write { db in
            try insertStrengthPlannedSession(draft, workoutVersionId: nil, db: db, now: now)
        }
    }

}
