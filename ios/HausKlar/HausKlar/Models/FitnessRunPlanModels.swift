import Foundation

enum FitnessRunDurationType: String, Codable, CaseIterable, Identifiable, Sendable {
    case distanceM = "distance_m"
    case timeS = "time_s"
    case lapButton = "lap_button"
    case open, calories
    var id: String { rawValue }
}

enum FitnessRunTargetType: String, Codable, CaseIterable, Identifiable, Sendable {
    case pace = "pace_s_per_km"
    case heartRate = "heart_rate_bpm"
    case heartRateZone = "heart_rate_zone"
    case power = "power_w"
    case powerZone = "power_zone"
    case cadence = "cadence_spm"
    case rpe, none
    var id: String { rawValue }
}

struct FitnessRunWorkoutStep: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var parentStepId: String?
    var sequence: Int
    var stepKind: String
    var repeatCount: Int?
    var durationType: FitnessRunDurationType
    var durationValue: Double?
    var targetType: FitnessRunTargetType
    var targetLow: Double?
    var targetHigh: Double?
    var targetUnit: String?
    var intensityLabel: String?
    var kilometreIndex: Int?
    var displayName: String
    var instructionText: String?
    var mentalCueText: String?
    var spokenCueText: String?
    var allowManualAdvance: Bool?
    var notes: String?
    var children: [FitnessRunWorkoutStep]?
}

struct FitnessRunWorkoutCue: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var stepId: String?
    var sequence: Int
    var triggerType: String
    var triggerValue: Double?
    var shortText: String
    var spokenText: String?
    var priority: Int
}

struct FitnessWorkoutVersionDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var purpose: String?
    var estimatedDurationS: Double?
    var estimatedDistanceM: Double?
    var structuredSummary: [String: JSONValue]?
    var versionSource: String
    var exerciseItems: [JSONValue]
    var runSteps: [FitnessRunWorkoutStep]?
    var runCues: [FitnessRunWorkoutCue]?
    var acceptedAt: String?
    var versionNumber: Int?
    var revision: Int?
    var createdAt: String?
    var updatedAt: String?
}

struct FitnessWorkoutDefinitionDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var sportKey: String
    var name: String
    var description: String?
    var active: Bool
    var version: FitnessWorkoutVersionDTO?
    var currentVersion: FitnessWorkoutVersionDTO?
    var versions: [FitnessWorkoutVersionDTO]?
    var revision: Int?
    var createdAt: String?
    var updatedAt: String?
}

struct FitnessTrainingProgrammeDTO: Codable, Identifiable, Equatable, Sendable {
    struct GoalLink: Codable, Equatable, Sendable {
        var goalId: String
        var role: String
    }
    let id: String
    var name: String
    var purpose: String?
    var startsOn: String
    var endsOn: String?
    var status: String
    var phaseId: String?
    var programmeSource: String
    var goalLinks: [GoalLink]
    var revision: Int?
    var createdAt: String?
    var updatedAt: String?
}

struct FitnessRunPlanDraft: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var definitionId: String?
    var name: String
    var description: String?
    var title: String
    var purpose: String?
    var expectedDifficulty: String?
    var goalExplanation: String?
    var terrainAssumption: String?
    var steps: [FitnessRunWorkoutStep]
    var cues: [FitnessRunWorkoutCue]
    var updatedAt: Date
}

enum FitnessSchedulePrecision: String,CaseIterable,Identifiable,Sendable {
    case exact,window,date
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exact: "Exact time"
        case .window: "Time window"
        case .date: "Date only"
        }
    }
}

struct FitnessRunPlacementDraft: Equatable,Sendable {
    var title: String
    var precision: FitnessSchedulePrecision
    var scheduledStart: Date
    var windowEnd: Date
    var scheduledDate: Date
    var goalId: String?
    var programmeId: String?
    var movable: Bool
    var visibility: String
    var sharedTitle: String?
    var reasonForPlacement: String?
}

enum FitnessIntervalsConnectionState:String,Codable,Sendable {
    case notConfigured="not_configured"
    case notConnected="not_connected"
    case connected
    case reauthRequired="reauth_required"
    case providerDown="provider_down"
    case disconnected
}

enum FitnessIntervalsAuthMethod:String,Codable,Sendable {
    case oauth
    case personalAPIKey="personal_api_key"
}

struct FitnessIntervalsStatus:Codable,Equatable,Sendable {
    let configured:Bool
    let oauthAvailable:Bool
    let personalApiKeyAvailable:Bool
    let connected:Bool
    let status:FitnessIntervalsConnectionState
    let authMethod:FitnessIntervalsAuthMethod?
    let oauthScopes:[String]
    let athleteId:String?
    let athleteName:String?
    let garminTrainingConnected:Bool?
    let lastTestedAt:String?
    let lastErrorCode:String?
    let activityReadAuthorized:Bool
    let activityImportEnabled:Bool
    let activityImportSince:String?
    let lastActivityImportAt:String?
    let lastActivityImportErrorCode:String?
    let activityImportedCount:Int
    let activityImportPendingCount:Int
    let activityImportErrorCount:Int
}

struct FitnessIntervalsConnectRequest:Codable,Equatable,Sendable {
    let apiKey:String
}

struct FitnessIntervalsOAuthStartRequest:Codable,Equatable,Sendable {
    let returnSurface:String
}

struct FitnessIntervalsOAuthStart:Codable,Equatable,Sendable {
    let authorizationUrl:String
    let expiresAt:String
}

struct FitnessIntervalsDisconnectResult:Codable,Equatable,Sendable {
    let status:FitnessIntervalsConnectionState
    let retainedPublicationCount:Int
}

struct FitnessIntervalsActivityImportRequest:Codable,Equatable,Sendable {
    let enabled:Bool
    let lookbackDays:Int
}

struct FitnessIntervalsActivityImportSync:Codable,Equatable,Sendable {
    let discoveredCount:Int
    let queuedCount:Int
    let existingCount:Int
    let skippedCount:Int
    let status:FitnessIntervalsStatus
}

enum FitnessStravaConnectionState:String,Codable,Sendable {
    case notConfigured="not_configured"
    case notConnected="not_connected"
    case connected
    case reauthRequired="reauth_required"
    case providerDown="provider_down"
    case disconnected
}

struct FitnessStravaStatus:Codable,Equatable,Sendable {
    let configured:Bool
    let connected:Bool
    let status:FitnessStravaConnectionState
    let athleteName:String?
    let lastSyncAt:String?
    let dataThroughAt:String?
    let importedActivityCount:Int
    let lastErrorCode:String?

    var isConnectedIntegration:Bool {
        connected && (status == .connected || status == .providerDown)
    }
}

struct FitnessStravaOAuthStartRequest:Codable,Equatable,Sendable {
    let returnSurface:String
}

struct FitnessStravaOAuthStart:Codable,Equatable,Sendable {
    let authorizationUrl:String
    let expiresAt:String
}

struct FitnessStravaActivitySummary:Codable,Equatable,Sendable {
    let id:String
    let title:String
    let sportKey:String
    let startedAtUtc:String
    let durationS:Double?
    let distanceM:Double?
}

struct FitnessStravaSync:Codable,Equatable,Sendable {
    let importedCount:Int
    let updatedCount:Int
    let unchangedCount:Int
    let latestActivity:FitnessStravaActivitySummary?
    let status:FitnessStravaStatus
}

struct FitnessStravaDisconnectResult:Codable,Equatable,Sendable {
    let status:FitnessStravaConnectionState
    let retainedActivityCount:Int
}

enum FitnessIntervalsDeliveryState:String,Codable,Sendable {
    case notSent="not_sent"
    case pending,sent,cancelled,error
}

enum FitnessIntervalsDeliveryOperation:String,Codable,Sendable {
    case none,created,updated,retried,unchanged,cancelled
}

struct FitnessIntervalsDelivery:Codable,Equatable,Sendable {
    let plannedSessionId:String
    let state:FitnessIntervalsDeliveryState
    let operation:FitnessIntervalsDeliveryOperation
    let externalId:String?
    let providerEventId:String?
    let sentAt:String?
    let lastErrorCode:String?
    let pushErrors:[String]
}

struct FitnessIntervalsOwnerContext:Equatable,Sendable {
    let identity:String
    let generation:UInt64
}

extension FitnessPlannedSession {
    var isIntervalsDeliveryEligible:Bool {
        sportKey == "running" && workoutVersionId != nil
            && ["accepted","scheduled"].contains(status)
            && (scheduledStart != nil || scheduledDate != nil || plannedFor != nil)
            && !isCompleted
    }
}

struct FitnessRunPlanTotals: Equatable, Sendable {
    var distanceM: Double
    var durationS: Double
    var hasOpenDuration: Bool
}

struct FitnessRunPlanValidation: Equatable, Sendable {
    var errors: [String]
    var warnings: [String]
    var totals: FitnessRunPlanTotals
    var isValid: Bool { errors.isEmpty }
}

enum FitnessRunPlanSemantics {
    static func totals(_ steps: [FitnessRunWorkoutStep]) -> FitnessRunPlanTotals {
        steps.reduce(into: FitnessRunPlanTotals(distanceM: 0, durationS: 0, hasOpenDuration: false)) {
            total, step in
            let multiplier = step.stepKind == "repeat_block" ? max(1, step.repeatCount ?? 0) : 1
            if step.stepKind == "repeat_block" {
                let child = totals(step.children ?? [])
                total.distanceM += child.distanceM * Double(multiplier)
                total.durationS += child.durationS * Double(multiplier)
                total.hasOpenDuration = total.hasOpenDuration || child.hasOpenDuration
            } else {
                switch step.durationType {
                case .distanceM: total.distanceM += max(0, step.durationValue ?? 0)
                case .timeS: total.durationS += max(0, step.durationValue ?? 0)
                case .lapButton, .open: total.hasOpenDuration = true
                case .calories: break
                }
            }
        }
    }

    static func validate(_ steps: [FitnessRunWorkoutStep], cues: [FitnessRunWorkoutCue]) -> FitnessRunPlanValidation {
        var errors: [String] = []
        var warnings: [String] = []
        func visit(_ values: [FitnessRunWorkoutStep], parents: Set<String>) {
            for step in values {
                if parents.contains(step.id) {
                    errors.append("A repeat block cannot contain itself.")
                    continue
                }
                if step.stepKind == "repeat_block" {
                    if (step.repeatCount ?? 0) < 1 { errors.append("\(step.displayName) needs a finite repeat count.") }
                    if (step.children ?? []).isEmpty { errors.append("\(step.displayName) has no repeated steps.") }
                    visit(step.children ?? [], parents: parents.union([step.id]))
                    continue
                }
                if [.distanceM, .timeS, .calories].contains(step.durationType), (step.durationValue ?? 0) <= 0 {
                    errors.append("\(step.displayName) needs a duration greater than zero.")
                }
                if let low = step.targetLow, let high = step.targetHigh, low > high {
                    errors.append("\(step.displayName) has a target range in the wrong order.")
                }
                if step.targetType != .none, step.targetLow == nil, step.targetHigh == nil {
                    errors.append("\(step.displayName) needs a target range or no target.")
                }
                if step.targetType == .pace, step.targetUnit != "s/km" {
                    errors.append("\(step.displayName) pace must be stored as seconds per kilometre.")
                }
                if step.spokenCueText != nil, step.spokenCueText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    errors.append("\(step.displayName) requests an empty spoken cue.")
                }
            }
        }
        visit(steps, parents: [])
        func kilometreIndexes(_ values: [FitnessRunWorkoutStep]) -> [Int] {
            values.flatMap { step in
                let own = step.kilometreIndex.map { [$0] } ?? []
                return own + kilometreIndexes(step.children ?? [])
            }
        }
        let indexes = kilometreIndexes(steps)
        if !indexes.isEmpty {
            let expected = Array(1...(indexes.max() ?? 0))
            if indexes.sorted() != expected {
                errors.append("Kilometre steps must start at 1 with no gaps or duplicates.")
            }
        }
        for cue in cues where cue.shortText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Every cue needs short text.")
        }
        let validCueTriggers: Set<String> = [
            "workout_start", "step_start", "step_end",
            "distance_from_workout_start_m", "distance_from_step_start_m",
            "time_from_workout_start_s", "time_from_step_start_s",
            "halfway", "final_kilometre", "manual",
        ]
        let stepBoundTriggers: Set<String> = [
            "step_start", "step_end", "distance_from_step_start_m", "time_from_step_start_s",
        ]
        let valueTriggers: Set<String> = [
            "distance_from_workout_start_m", "distance_from_step_start_m",
            "time_from_workout_start_s", "time_from_step_start_s",
        ]
        func flattenedStepIds(_ values: [FitnessRunWorkoutStep]) -> Set<String> {
            Set(values.flatMap { [$0.id] + Array(flattenedStepIds($0.children ?? [])) })
        }
        let stepIds = flattenedStepIds(steps)
        for cue in cues {
            if !validCueTriggers.contains(cue.triggerType) {
                errors.append("\(cue.shortText.isEmpty ? "A cue" : cue.shortText) has an unsupported trigger.")
            }
            if stepBoundTriggers.contains(cue.triggerType),
               cue.stepId.map(stepIds.contains) != true {
                errors.append("\(cue.shortText.isEmpty ? "A cue" : cue.shortText) needs a valid step.")
            }
            if valueTriggers.contains(cue.triggerType), (cue.triggerValue ?? -1) < 0 {
                errors.append("\(cue.shortText.isEmpty ? "A cue" : cue.shortText) needs a non-negative trigger value.")
            }
        }
        if steps.isEmpty { errors.append("Add at least one run step.") }
        if steps.contains(where: { $0.mentalCueText != nil || $0.spokenCueText != nil }) {
            warnings.append("Garmin may omit or shorten human cue text; review the export mapping before relying on it.")
        }
        return FitnessRunPlanValidation(errors: errors, warnings: warnings, totals: totals(steps))
    }
}

struct FitnessGarminExport: Codable, Identifiable, Equatable, Sendable {
    struct MappingItem: Codable, Identifiable, Equatable, Sendable {
        var id: String { "\(field):\(status):\(detail)" }
        var field: String
        var status: String
        var detail: String
    }
    let id: String
    var workoutVersionId: String
    var status: String
    var fileName: String?
    var lastError: String?
    var mappingReport: [MappingItem]?

    /// `ready` is the canonical server state. `complete` is tolerated for
    /// compatibility with exports cached by early development builds.
    var isDownloadReady: Bool { status == "ready" || status == "complete" }
}
