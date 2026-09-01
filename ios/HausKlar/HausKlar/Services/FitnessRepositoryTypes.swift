import Foundation

enum FitnessRepositoryError: LocalizedError {
    case missingRecord, missingFood, missingFoodLog, missingExercise, missingSetup, missingSetGroup, missingPlan
    case workoutAlreadyActive, noActiveWorkout, multiplePrimaryGoals, invalidAmount
    case invalidStrengthEntry
    case setupAlreadySnapshotted
    case exerciseAlreadyPerformed
    case invalidBodyMeasurement
    case importedBodyMeasurementReadOnly
    case invalidStrengthPlan
    case invalidSleepWindow
    case invalidCycleLength
    case invalidCycleDate
    case missingCycleSettings

    var errorDescription: String? {
        switch self {
        case .missingRecord: "That Fitness record is no longer available."
        case .missingFood: "That food is no longer available."
        case .missingFoodLog: "That food log entry is no longer available."
        case .missingExercise: "That exercise is no longer available."
        case .missingSetup: "Choose a concrete exercise setup before continuing."
        case .missingSetGroup: "That set is no longer available."
        case .missingPlan: "That planned session is no longer available."
        case .invalidAmount: "Enter a serving amount greater than zero."
        case .invalidStrengthEntry: "Enter valid performed work and finite non-negative measurements."
        case .setupAlreadySnapshotted: "This setup is already part of completed set history. Add the exercise again to use another setup."
        case .exerciseAlreadyPerformed:
            "This exercise already has performed work. Add the substitute as a new exercise so history stays honest."
        case .invalidBodyMeasurement: "Enter a positive measurement, a short unit, and a valid body metric."
        case .importedBodyMeasurementReadOnly:
            "Measurements imported from HealthKit or another source cannot be edited here. Add a manual measurement instead."
        case .invalidStrengthPlan:
            "Review the workout: every exercise needs its own setup and at least one valid prescription, and the schedule window must be coherent."
        case .invalidSleepWindow: "Sleep must end after it starts, and awake time cannot exceed the recorded window."
        case .invalidCycleLength: "Cycle length must be between 10 and 365 days."
        case .invalidCycleDate: "Choose a valid period start date."
        case .missingCycleSettings: "Set up cycle tracking before recording a period start."
        case .workoutAlreadyActive: "A workout is already active. Resume or finish it first."
        case .noActiveWorkout: "There is no active workout to finish."
        case .multiplePrimaryGoals: "A training phase can have only one primary goal."
        }
    }
}

struct NewBodyIssue: Equatable, Sendable {
    var issueTypeKey: String
    var bodyLocationKey: String
    var side: String
    var severity: Int
    var timing: String
    var changedSession: Bool
    var sessionChangeKey: String
    var note: String?
    var plannedSessionId: String? = nil
    var sessionExerciseId: String? = nil
    var setGroupId: String? = nil
    var checkinId: String? = nil
    var trendKey: String = "unknown"
    var status: String = "active"
    var resolvedAt: Date? = nil
}

// Exact v1 server payload shapes. These are intentionally separate from local records.
struct GoalPayload: Encodable {
    let id, goalType, metricKey, name, startsOn: String
    let targetValue: Double?
    let unitKey, targetDate: String?
}
struct CyclePeriodStartDeletePayload: Encodable { let id: String }
struct FitnessDeletePayload: Encodable { let id: String }
struct ManualSleepSessionPayload: Encodable {
    let id: String
    let sleepStartUtc: String
    let sleepEndUtc: String
    let durationS: Double
    let awakeDurationS: Double?
    let sourceQuality: String
    let sourceRecordId: String?
    let sourceStages: [FitnessSleepStageDTO]
    let notes: String?
}
struct GoalLinkPayload: Encodable { let goalId, role: String }
struct TrainingPhasePayload: Encodable {
    let id, phaseType, name, startsOn: String
    let endsOn: String?
    let goalLinks: [GoalLinkPayload]
}
struct PlannedSessionPayload: Encodable {
    let id, sportKey, title, localTimezone, status, sessionSource: String
    let scheduledStartUtc: Date?
    let exerciseItems: [PlannedExercisePayload]
}
struct ResolvedStrengthPlanExercise {
    let exerciseId: String
    let setupId: String
    let substitutionIds: [String]
    let sets: [FitnessStrengthPlanSetDraft]
}
struct StrengthWorkoutDefinitionPayload: Encodable {
    let id, sportKey, name: String
    let description: String?
    let active: Bool
    let version: StrengthWorkoutVersionPayload
}
struct StrengthWorkoutVersionPayload: Encodable {
    let id, title: String
    let purpose: String?
    let estimatedDurationS: Int?
    let structuredSummary: [String: JSONValue]
    let versionSource: String
    let acceptedAt: Date
    let exerciseItems: [PlannedExercisePayload]
    let runSteps, runCues: [JSONValue]
}
struct StrengthPlanGoalLinkPayload: Encodable {
    let goalId, role: String
}
struct StrengthPlanGearLinkPayload: Encodable {
    let gearId, role: String
}
struct DetailedPlannedSessionPayload: Encodable {
    let id, sportKey, title, localTimezone: String
    let trainingProgrammeId, workoutVersionId: String?
    let status, sessionSource: String
    let scheduledStartUtc: Date?
    let scheduledDate: String?
    let timeWindowStartUtc, timeWindowEndUtc: Date?
    let expectedDurationS: Int?
    let expectedDistanceM: Double?
    let expectedPaceSPerKm: Double?
    let priority: Int
    let movable: Bool
    let visibility: String
    let sharedTitle, reasonForPlacement: String?
    let completionActivityId, completionState: String?
    let goalLinks: [StrengthPlanGoalLinkPayload]
    let exerciseItems: [PlannedExercisePayload]
    let gearLinks: [StrengthPlanGearLinkPayload]
    let intendedGearIds: [String]
}
struct PlannedExercisePayload: Encodable {
    let id, exerciseId, exerciseSetupId: String
    let sequence: Int
    let supersetGroupKey: String?
    let substitutionExerciseIds: [String]
    let notes: String?
    let plannedSets: [PlannedSetPayload]
}
struct PlannedSetPayload: Encodable {
    let id: String
    let sequence: Int
    let trainingRole, structureType: String
    let componentCount: Int
    let repsMin, repsMax: Int?
    let loadMin, loadMax: Double?
    let loadUnit: String?
    let rpeMin, rpeMax, rirMin, rirMax: Double?
    let restS: Int?
    let isAmrap: Bool
    let notes: String?
}
struct FoodVersionPayload: Encodable {
    let id: String
    let referenceAmount: Double
    let referenceUnit: String
    let caloriesKcal: Double?
    let sourceType, confidence: String
}
struct FoodPayload: Encodable {
    let id, name: String
    let brand: String?
    let householdShared, favourite, active: Bool
    let version: FoodVersionPayload
}
struct FoodLogPayload: Encodable {
    let id, foodVersionId: String
    let loggedAtUtc: Date
    let localTimezone, mealKey: String
    let enteredAmount: Double
    let enteredUnit: String
    let canonicalAmount: Double
    let canonicalUnit, measurementQuality: String
}
struct BodyMeasurementPayload: Encodable {
    let id, metricKey: String
    let measuredAtUtc: Date
    let localTimezone: String
    let value: Double
    let unitKey, measurementQuality, canonicalState: String
    let notes: String?
}
struct ExercisePayload: Encodable {
    let id, name, movementPatternKey, measurementMode, repCountMode, loadEntryMode, defaultUnit: String
    let bodyweightInvolved, favourite, active: Bool
}
struct SetupPayload: Encodable {
    let id, exerciseId, name, loadEntryMode, repCountMode: String
    let barWeightKg, sideMultiplier: Double?
    let isDefault, active: Bool
}
struct StrengthSessionPayload: Encodable {
    let id, title: String
    let startedAtUtc: Date
    let localTimezone: String
    let plannedSessionId: String?
    let status: String
    let endedAtUtc: Date?
    let sessionRpe: Double?
    let perceivedPerformance: Int?
    let notes: String?
    var restTimerDeadlineUtc: Date? = nil
    var matchedPlanKey: String? = nil
}
struct SessionExercisePayload: Encodable {
    let id, activityId, exerciseId, exerciseSetupId: String
    var plannedExerciseId: String? = nil
    let sequence: Int
    var supersetGroupKey: String? = nil
    var variationNote: String? = nil
    var notes: String? = nil
    var exerciseSetupLabelSnapshot: String? = nil
    var exerciseSetupLoadEntryModeSnapshot: String? = nil
    var unilateralModeSnapshot: String? = nil
}
struct SetGroupPayload: Encodable {
    let id, activityId, sessionExerciseId, trainingRole, structureType, status, failureState: String
    let sequence: Int
    let isAmrap: Bool
    let plannedSetId: String?
    let startedAtUtc, completedAtUtc: Date?
    let notes: String?
    init(group: FitnessSetGroup, activityId: String) {
        id = group.id
        self.activityId = activityId
        sessionExerciseId = group.sessionExerciseId
        trainingRole = group.role.rawValue
        structureType = group.structure.rawValue
        status = group.status.rawValue
        failureState = group.failureState.rawValue
        sequence = group.position
        isAmrap = group.isAMRAP
        plannedSetId = group.plannedSetId
        startedAtUtc = group.startedAt
        completedAtUtc = group.completedAt
        notes = group.notes
    }
}
struct SetComponentPayload: Encodable {
    let id, setGroupId: String
    let componentIndex: Int
    let componentStatus: String
    let loadValue: Double?
    let loadUnit: String?
    let normalizedExternalLoadKg: Double?
    let loadEntryModeSnapshot: String?
    let addedLoadKg, assistanceKg, bodyweightKgSnapshot: Double?
    let reps, repsLeft, repsRight: Int?
    let durationS, distanceM, rir, rpe: Double?
    let completedAtUtc: Date?
    let restBeforeS: Int?
    let tempoText, notes: String?
    let extraMetrics: [String: JSONValue]
    init(component: FitnessSetComponent) {
        id = component.id
        setGroupId = component.groupId
        componentIndex = component.position
        componentStatus = component.status.rawValue
        loadValue = component.loadValue ?? component.loadKg
        loadUnit = component.loadUnit ?? (component.loadKg == nil ? nil : "kg")
        loadEntryModeSnapshot = component.loadEntryModeSnapshot
        normalizedExternalLoadKg = component.normalizedExternalLoadKg ?? component.loadKg
        addedLoadKg = component.addedLoadKg
        assistanceKg = component.assistanceKg
        bodyweightKgSnapshot = component.bodyweightKgSnapshot
        reps = component.reps
        repsLeft = component.repsLeft
        repsRight = component.repsRight
        durationS = component.durationSeconds.map(Double.init)
        distanceM = component.distanceMetres
        rir = component.rir
        rpe = component.rpe
        completedAtUtc = component.completedAt
        restBeforeS = component.restBeforeSeconds
        tempoText = component.tempoText
        notes = component.notes
        extraMetrics = component.extraMetrics
    }
}
struct CheckinPayload: Encodable {
    let id: String
    let plannedSessionId: String?
    let activityId: String?
    let timing: String
    let capturedAtUtc: Date
    let captureQuality: String
    let capturedBeforeActivityStart: Bool?
    let readiness1To5, energy1To5, soreness1To5, motivation1To5: Int?
    let sessionRpe1To10: Double?
    let perceivedPerformance1To5: Int?
    let matchedPlanKey, notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case plannedSessionId = "planned_session_id"
        case activityId = "activity_id"
        case timing
        case capturedAtUtc = "captured_at_utc"
        case captureQuality = "capture_quality"
        case capturedBeforeActivityStart = "captured_before_activity_start"
        case readiness1To5 = "readiness_1_5"
        case energy1To5 = "energy_1_5"
        case soreness1To5 = "soreness_1_5"
        case motivation1To5 = "motivation_1_5"
        case sessionRpe1To10 = "session_rpe_1_10"
        case perceivedPerformance1To5 = "perceived_performance_1_5"
        case matchedPlanKey = "matched_plan_key"
        case notes
    }
}
struct BodyIssuePayload: Encodable {
    let id: String
    let plannedSessionId, activityId, sessionExerciseId, setGroupId, checkinId: String?
    let observedAtUtc: Date
    let timing: String
    let issueTypeKey, bodyLocationKey, side: String
    let severity0To10: Int
    let changedSession: Bool
    let sessionChangeKey, trendKey, status: String
    let resolvedAtUtc: Date?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case plannedSessionId = "planned_session_id"
        case activityId = "activity_id"
        case sessionExerciseId = "session_exercise_id"
        case setGroupId = "set_group_id"
        case checkinId = "checkin_id"
        case observedAtUtc = "observed_at_utc"
        case timing
        case issueTypeKey = "issue_type_key"
        case bodyLocationKey = "body_location_key"
        case side
        case severity0To10 = "severity_0_10"
        case changedSession = "changed_session"
        case sessionChangeKey = "session_change_key"
        case trendKey = "trend_key"
        case status
        case resolvedAtUtc = "resolved_at_utc"
        case notes
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func fitnessRepositoryString(_ key: String) -> String? { self[key]?.stringValue }
    func fitnessRepositoryInt(_ key: String) -> Int? {
        self[key]?.intValue ?? self[key]?.doubleValue.map(Int.init)
    }
    func fitnessRepositoryDouble(_ key: String) -> Double? { self[key]?.doubleValue }
    func fitnessRepositoryBool(_ key: String) -> Bool? { self[key]?.boolValue }
    func fitnessRepositoryObject(_ key: String) -> [String: JSONValue]? {
        guard let value = self[key], case .object(let object) = value else { return nil }
        return object
    }
    func fitnessRepositoryObjects(_ key: String) -> [[String: JSONValue]] {
        guard let value = self[key], case .array(let values) = value else { return [] }
        return values.compactMap { value in
            guard case .object(let object) = value else { return nil }
            return object
        }
    }
}
