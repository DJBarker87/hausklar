import Foundation

struct FitnessExerciseMuscleRole: Codable, Equatable, Sendable {
    var muscleGroupKey: String
    var role: String
    var contributionWeight: Double
}

struct FitnessStrengthMergeRequest: Codable, Equatable, Sendable {
    let sourceId: String
    let targetId: String
}

struct FitnessExerciseMergePreview: Codable, Equatable, Sendable {
    let sourceId: String
    let targetId: String
    let alreadyMerged: Bool
    let plannedExercises: Int
    let sessionExercises: Int
    let movedSetups: Int
}

struct FitnessExerciseSetupMergePreview: Codable, Equatable, Sendable {
    let sourceId: String
    let targetId: String
    let alreadyMerged: Bool
    let plannedExercises: Int
    let sessionExercises: Int
}

struct FitnessBodyLocation: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var locationKey: String
    var parentKey: String?
    var displayName: String
    var active: Bool

    static let fallback: [FitnessBodyLocation] = [
        ("shoulder","Shoulder"),("elbow","Elbow"),("wrist_hand","Wrist / hand"),
        ("upper_back","Upper back"),("lower_back","Lower back"),("hip_groin","Hip / groin"),
        ("thigh","Thigh"),("knee","Knee"),("calf_shin","Calf / shin"),
        ("ankle","Ankle"),("foot","Foot"),("other","Other"),
    ].map { FitnessBodyLocation(id: $0.0,locationKey: $0.0,parentKey: nil,displayName: $0.1,active: true) }

    static func label(for key: String,locations: [FitnessBodyLocation]) -> String {
        locations.first { $0.locationKey == key }?.displayName
            ?? "Custom/legacy: \(key.replacingOccurrences(of: "_",with: " "))"
    }
}

struct FitnessPlannedStrengthSet: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var plannedExerciseId: String
    var sequence: Int
    var role: FitnessSetRole
    var structure: FitnessSetStructure
    var componentCount: Int
    var repsMin: Int?
    var repsMax: Int?
    var loadMin: Double?
    var loadMax: Double?
    var loadUnit: String?
    var rpeMin: Double?
    var rpeMax: Double?
    var rirMin: Double?
    var rirMax: Double?
    var restSeconds: Int?
    var isAMRAP: Bool
    var notes: String?
}

struct FitnessPlannedStrengthExercise: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var plannedSessionId: String
    var exerciseId: String
    var exerciseName: String
    var requestedSetupId: String?
    var sequence: Int
    var supersetGroupKey: String?
    var substitutionExerciseIds: [String]
    var notes: String?
    var sets: [FitnessPlannedStrengthSet]
}

struct FitnessStrengthPlanSetDraft: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var role: FitnessSetRole = .working
    var structure: FitnessSetStructure = .straight
    var componentCount: Int = 1
    var repsMin: Int? = 8
    var repsMax: Int? = 10
    var loadMin: Double? = nil
    var loadMax: Double? = nil
    var loadUnit: String? = "kg"
    var rpeMin: Double? = nil
    var rpeMax: Double? = nil
    var rirMin: Double? = nil
    var rirMax: Double? = nil
    var restSeconds: Int? = 120
    var isAMRAP: Bool = false
    var notes: String? = nil
}

struct FitnessStrengthPlanExerciseDraft: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var exerciseId: String
    var setupId: String
    var substitutionExerciseIds: [String] = []
    var supersetGroupKey: String? = nil
    var notes: String? = nil
    var sets: [FitnessStrengthPlanSetDraft] = [.init()]
}

struct FitnessStrengthPlanDraft: Codable, Equatable, Sendable {
    var definitionId: String? = nil
    var name: String = "Strength workout"
    var description: String? = nil
    var title: String = "Strength workout"
    var purpose: String? = nil
    var exercises: [FitnessStrengthPlanExerciseDraft] = []
    var scheduledStart: Date? = nil
    var timeWindowStart: Date? = nil
    var timeWindowEnd: Date? = nil
    var expectedDurationSeconds: Int? = 3_600
    var priority: Int = 0
    var movable: Bool = true
    var visibility: String = "private"
    var sharedTitle: String? = nil
    var reasonForPlacement: String? = nil
    var trainingProgrammeId: String? = nil
    var primaryGoalId: String? = nil
    var secondaryGoalIds: [String] = []
    var intendedGearIds: [String] = []
}

struct FitnessSavedStrengthWorkout: Identifiable, Equatable, Sendable {
    var id: String { versionId }
    var definitionId: String
    var versionId: String
    var name: String
    var title: String
    var purpose: String?
    var acceptedAt: Date?
    var exercises: [FitnessStrengthPlanExerciseDraft]
}

struct FitnessComparableSet: Identifiable, Equatable, Sendable {
    let id: String
    var performedAt: Date
    var exerciseName: String
    var setupLabelSnapshot: String
    var loadModeSnapshot: String
    var repModeSnapshot: String = "total"
    var unilateralModeSnapshot: String = "bilateral"
    var group: FitnessSetGroup
    var components: [FitnessSetComponent]
}

struct FitnessStrengthComparisonIdentity: Codable, Hashable, Identifiable, Sendable {
    var exerciseId: String
    var setupId: String
    var setupLabelSnapshot: String
    var loadModeSnapshot: String
    var repModeSnapshot: String
    var unilateralModeSnapshot: String
    var id: String {
        [exerciseId,setupId,setupLabelSnapshot,loadModeSnapshot,repModeSnapshot,unilateralModeSnapshot]
            .joined(separator: "|")
    }
}

struct FitnessStrengthProgressPoint: Identifiable, Equatable, Sendable {
    var id: String
    var performedAt: Date
    var recordReps: Int?
    var normalizedLoadKg: Double?
    var volumeKg: Double
    var eligibleE1RMKg: Double?
}

struct FitnessStrengthProgressSeries: Identifiable, Equatable, Sendable {
    var identity: FitnessStrengthComparisonIdentity
    var exerciseName: String
    var points: [FitnessStrengthProgressPoint]
    var id: String { identity.id }
}

struct FitnessMuscleExposure: Identifiable, Equatable, Sendable {
    var muscleGroupKey: String
    var directWorkingSets: Int
    var indirectSetEquivalents: Double
    var directHardSets: Int
    var unknownHardnessSets: Int
    var frequencyDays: Int
    var daysSinceLastTrained: Int?
    var id: String { muscleGroupKey }
}

struct FitnessStrengthSetDraft: Equatable, Sendable {
    var plannedSetId: String? = nil
    var role: FitnessSetRole = .working
    var structure: FitnessSetStructure = .straight
    var isAMRAP = false
    var groupStatus: FitnessSetStatus = .completed
    var componentStatus: FitnessComponentStatus = .completed
    var failureState: FitnessFailureType = .none
    var reps: Int? = nil
    var repsLeft: Int? = nil
    var repsRight: Int? = nil
    var loadValue: Double? = nil
    var loadUnit: String? = "kg"
    var durationSeconds: Int? = nil
    var distanceMetres: Double? = nil
    var rir: Double? = nil
    var rpe: Double? = nil
    var restBeforeSeconds: Int? = nil
    var tempoText: String? = nil
    var notes: String? = nil
    var extraMetrics: [String: JSONValue] = [:]
    var startedAt: Date? = nil
    var completedAt: Date? = nil
}

struct FitnessBodyweightChoice: Equatable, Sendable {
    enum Source: String, Codable, Sendable { case recentCanonical = "recent_canonical", manual, unknown }
    var kilograms: Double?
    var source: Source

    static let unknown = FitnessBodyweightChoice(kilograms: nil, source: .unknown)
}

enum FitnessBodyIssueType: String, Codable, CaseIterable, Identifiable, Sendable {
    case pain, tightness, discomfort, weakness, injury, other
    var id: String { rawValue }
}

enum FitnessBodyIssueSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right, bilateral, midline
    case notApplicable = "not_applicable"
    case unknown
    var id: String { rawValue }
}

enum FitnessBodyIssueTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    case pre, during, post
    case nextDay = "next_day"
    case standalone
    var id: String { rawValue }
}

enum FitnessBodyIssueSessionChange: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case reducedLoad = "reduced_load"
    case reducedRange = "reduced_range"
    case reducedPace = "reduced_pace"
    case substituted, stopped
    case preventedStart = "prevented_start"
    case other
    var id: String { rawValue }
}

struct FitnessStrengthSuggestionEvidence: Codable, Identifiable, Equatable, Sendable {
    var id: String { sourceId ?? "\(label)-\(summary ?? value ?? "")" }
    var sourceId: String?
    var label: String
    var summary: String?
    var value: String?
}

struct FitnessStrengthSuggestion: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var exerciseId: String?
    var title: String
    var recommendation: String?
    var reason: String
    var evidence: [FitnessStrengthSuggestionEvidence]
    var missingContext: [String]
}

struct FitnessStrengthSuggestionsResponse: Codable, Equatable, Sendable {
    var suggestions: [FitnessStrengthSuggestion]
}

enum FitnessStrengthSemantics {
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

    static func loadLabel(_ mode: FitnessLoadMode) -> String {
        switch mode {
        case .total: "kg total"
        case .each: "kg each"
        case .perSide: "kg per side"
        case .machine: "stack kg"
        case .level: "machine level"
        case .bodyweight: "bodyweight"
        case .added: "added kg"
        case .assistance: "assistance kg"
        }
    }

    static func normalizedExternalLoad(
        value: Double?, mode: FitnessLoadMode, setup: FitnessExerciseSetup
    ) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        switch mode {
        case .total, .machine: return value
        case .each: return value * 2
        case .perSide: return (setup.machineBaseLoadKg ?? 0) + value * (setup.sideMultiplier ?? 2)
        case .added: return value
        case .level, .bodyweight, .assistance: return nil
        }
    }

    static func localSuggestion(
        exercise: FitnessSessionExercise, comparable: [FitnessComparableSet]
    ) -> FitnessStrengthSuggestion? {
        guard let latest = comparable.first,
              let component = latest.components.first(where: FitnessCalculations.isPerformed)
        else { return nil }
        let effort = component.rir.map { "RIR \(Int($0))" }
            ?? component.rpe.map { "RPE \(String(format: "%.1f", $0))" }
            ?? "effort unknown"
        let work = component.reps.map { "\($0) reps" }
            ?? component.durationSeconds.map { "\($0)s" }
            ?? "recorded work"
        return FitnessStrengthSuggestion(
            id: "local-\(exercise.exerciseId)", exerciseId: exercise.exerciseId,
            title: "Repeat comparable work",
            recommendation: "Use the last comparable setup as the starting point and adjust from today's readiness.",
            reason: "The offline fallback only uses your most recent comparable observed set.",
            evidence: [
                .init(
                    sourceId: component.id, label: latest.setupLabelSnapshot,
                    summary: "\(work) at \(effort)",
                    value: component.loadValue.map { "\($0) \(component.loadUnit ?? "kg")" }
                ),
            ],
            missingContext: ["server cross-domain context unavailable"]
        )
    }
}
