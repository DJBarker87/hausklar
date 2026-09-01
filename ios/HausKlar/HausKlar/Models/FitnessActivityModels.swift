import CoreLocation
import Foundation

struct FitnessRegisteredSport: Codable, Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let displayName: String
    let distanceMeaningful: Bool?

    init(key: String, displayName: String, distanceMeaningful: Bool? = nil) {
        self.key = key
        self.displayName = displayName
        self.distanceMeaningful = distanceMeaningful
    }
}

/// The server registry owns the set of general activity types. The iPhone only
/// needs the sport identity here; unmodelled registry metadata remains a server
/// concern and can evolve without breaking this cache.
struct FitnessActivityRegistry: Codable, Equatable, Sendable {
    let sports: [FitnessRegisteredSport]
}

enum FitnessImportStatus: String, Codable, CaseIterable, Sendable {
    case queued, uploading, processing, complete, error
}

struct FitnessFITImportResult: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var status: FitnessImportStatus
    var activityId: String?
    var fileName: String?
    var error: String?
    var retryable: Bool?
    var sourceRecordId: String?
    var sourceRetained: Bool?
    var createdAt: String?
    var updatedAt: String?
}

struct FitnessPendingFITImport: Identifiable, Equatable, Sendable {
    let id: String
    var originalFilename: String
    var byteCount: Int
    var status: FitnessImportStatus
    var serverImportId: String?
    var activityId: String?
    var sourceRecordId: String?
    var sourceRetained: Bool
    var retryable: Bool
    var attempts: Int
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
    var hasLocalCopy: Bool
}

struct FitnessGearItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var gearTypeKey: String
    var name: String
    var brand: String?
    var model: String?
    var variant: String?
    var startedAt: String?
    var retiredAt: String?
    var initialUsageDistanceM: Double?
    var defaultForSportKey: String?
    var notes: String?
    var active: Bool?
    var activityCount: Int?
    var usageDistanceM: Double?
    var usageDurationS: Double?
    var revision: Int?
    var createdAt: String?
    var updatedAt: String?
}

struct FitnessActivityMetric: Codable, Equatable, Sendable {
    var metricKey: String
    var label: String?
    var valueNumber: Double?
    var valueText: String?
    var valueBool: Bool?
    var unitKey: String?
    var origin: String?
    var quality: String?

    var displayValue: String {
        if let valueText { return valueText }
        if let valueBool { return valueBool ? "Yes" : "No" }
        guard let valueNumber else { return "—" }
        let value = valueNumber.rounded() == valueNumber
            ? String(Int(valueNumber))
            : String(format: "%.2f", valueNumber)
        return unitKey.map { "\(value) \($0)" } ?? value
    }
}

struct FitnessActivityInterval: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var parentIntervalId: String?
    var sequence: Int
    var intervalKind: String
    var origin: String?
    var startOffsetMs: Int
    var endOffsetMs: Int
    var startDistanceM: Double?
    var endDistanceM: Double?
    var label: String?
    var metrics: [String: JSONValue]?
    var metricsJson: [String: JSONValue]?

    var metricValues: [String: JSONValue] { metrics ?? metricsJson ?? [:] }
}

struct FitnessDataQualityFinding: Codable, Identifiable, Equatable, Sendable {
    var id: String { storedId ?? "\(key):\(startOffsetMs ?? -1):\(endOffsetMs ?? -1)" }
    private var storedId: String?
    var key: String
    var severity: String
    var message: String
    var startOffsetMs: Int?
    var endOffsetMs: Int?
    var limitsAnalysisKeys: [String]?

    private enum CodingKeys: String, CodingKey {
        case storedId = "id"
        case key, severity, message, startOffsetMs, endOffsetMs, limitsAnalysisKeys
    }
}

struct FitnessActivitySummary: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var sportKey: String
    var startedAtUtc: String
    var localTimezone: String?
    var status: String?
    var plannedSessionId: String? = nil
    var plannedSessionTitle: String? = nil
    var workoutClassification: String?
    var phaseId: String?
    var phaseName: String?
    var distanceM: Double?
    var durationS: Double?
    var elapsedDurationS: Double?
    var timerDurationS: Double?
    var movingDurationS: Double? = nil
    var energyKcal: Double? = nil
    var energyEstimationMethod: String? = nil
    var energyEstimationWeightKg: Double? = nil
    var energyEstimationWeightMeasuredAtUtc: String? = nil
    var energyEstimationMet: Double? = nil
    var notes: String? = nil
    var routePreview: [[Double]]?
    var primaryMetrics: [FitnessActivityMetric]?
    var gear: [FitnessGearItem]?
    var strengthSummary: FitnessActivityStrengthSummary? = nil
    var importError: String?
    var revision: Int?
    var createdAt: String?
    var updatedAt: String?

    var startedAt: Date { FitnessDatabase.date(startedAtUtc) ?? .distantPast }

    var routeCoordinates: [CLLocationCoordinate2D] {
        (routePreview ?? []).compactMap { coordinate in
            guard coordinate.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: coordinate[0], longitude: coordinate[1])
        }
    }
}

struct FitnessActivityStrengthSummary: Codable, Equatable, Sendable {
    var exerciseCount: Int
    var setCount: Int
    var workingSetCount: Int
    var failureSetCount: Int
    var volumeKg: Double
}

struct FitnessManualActivityPayload: Codable, Equatable, Sendable {
    let id: String
    let sportKey: String
    let title: String?
    let startedAtUtc: Date
    let localTimezone: String
    let durationS: Double
    let distanceM: Double?
    let sessionRpe: Double?
    let workoutClassification: String?
    let notes: String?
    let estimateEnergy: Bool
}

struct FitnessManualActivityDefaults: Codable, Equatable, Sendable {
    let latestWeightKg: Double?
    let latestWeightMeasuredAtUtc: String?
    let energyEstimationMethod: String
}

enum FitnessManualActivityCalculator {
    static func met(sportKey: String, durationS: Double, distanceM: Double?) -> Double {
        let hours = durationS / 3_600
        let speedKmh = distanceM.flatMap { distance in
            hours > 0 && distance > 0 ? distance / 1_000 / hours : nil
        }
        switch sportKey {
        case "running":
            guard let speedKmh else { return 8 }
            for (ceiling, value) in [(6.4, 6.0), (8, 8), (9.7, 9.8), (11.3, 11), (12.9, 11.8), (14.5, 12.8)] where speedKmh < ceiling {
                return value
            }
            return 14.5
        case "walking":
            guard let speedKmh else { return 3.5 }
            for (ceiling, value) in [(3.2, 2.8), (4.8, 3.5), (5.6, 4), (6.4, 4.8)] where speedKmh < ceiling {
                return value
            }
            return 6
        case "cycling":
            guard let speedKmh else { return 6.8 }
            for (ceiling, value) in [(16.0, 4.0), (19.0, 6.8), (22.0, 8.0), (26.0, 10.0)] where speedKmh < ceiling {
                return value
            }
            return 12
        case "hiking": return 6
        case "rowing_indoor", "rowing_water": return 7
        case "swimming_pool", "swimming_open_water": return 6
        default: return 5
        }
    }

    static func energyKcal(
        sportKey: String,
        durationS: Double,
        distanceM: Double?,
        weightKg: Double?
    ) -> Double? {
        guard let weightKg, weightKg > 0, durationS > 0 else { return nil }
        return (met(sportKey: sportKey, durationS: durationS, distanceM: distanceM)
            * weightKg * durationS / 3_600).rounded()
    }

    static func optimisticSummary(
        payload: FitnessManualActivityPayload,
        sportName: String,
        defaults: FitnessManualActivityDefaults?
    ) -> FitnessActivitySummary {
        let energy = payload.estimateEnergy ? energyKcal(
            sportKey: payload.sportKey,
            durationS: payload.durationS,
            distanceM: payload.distanceM,
            weightKg: defaults?.latestWeightKg
        ) : nil
        return FitnessActivitySummary(
            id: payload.id,
            title: payload.title ?? sportName,
            sportKey: payload.sportKey,
            startedAtUtc: FitnessDatabase.dateString(payload.startedAtUtc),
            localTimezone: payload.localTimezone,
            status: "completed",
            plannedSessionId: nil,
            workoutClassification: payload.workoutClassification,
            phaseId: nil,
            phaseName: nil,
            distanceM: payload.distanceM,
            durationS: payload.durationS,
            elapsedDurationS: payload.durationS,
            timerDurationS: payload.durationS,
            movingDurationS: payload.durationS,
            energyKcal: energy,
            energyEstimationMethod: energy == nil ? nil : defaults?.energyEstimationMethod,
            energyEstimationWeightKg: energy == nil ? nil : defaults?.latestWeightKg,
            energyEstimationWeightMeasuredAtUtc: energy == nil ? nil : defaults?.latestWeightMeasuredAtUtc,
            energyEstimationMet: energy == nil ? nil : met(
                sportKey: payload.sportKey,
                durationS: payload.durationS,
                distanceM: payload.distanceM
            ),
            notes: payload.notes,
            routePreview: [],
            primaryMetrics: [],
            gear: [],
            importError: nil,
            revision: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }
}

struct FitnessActivitySource: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var sourceType: String
    var provider: String?
    var deviceName: String?
    var status: String?
    var attachedAt: String?
    var isPrimary: Bool?
    var dataQuality: String?

    var hasRetainedFitFile: Bool { sourceType == "manual_fit" }
}

struct FitnessActivityRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var recordKey: String
    var label: String
    var value: String
    var achievedAtOffsetMs: Int?
    var isPersonalBest: Bool?
}

struct FitnessAnalysisEvidence: Codable, Equatable, Sendable {
    var label: String
    var value: String
    var intervalId: String?
    var activityId: String?
}

struct FitnessAnalysisFinding: Codable, Identifiable, Equatable, Sendable {
    var id: String { key }
    var key: String
    var title: String
    var summary: String
    var status: String?
    var value: JSONValue?
    var unitKey: String?
    var quality: String?
    var confidence: Double?
    var calculationVersion: String?
    var evidence: [FitnessAnalysisEvidence]?
}

/// The activity analysis endpoint deliberately returns its evidence-backed
/// findings alongside records, achievements and any limitations. Keeping the
/// envelope intact prevents a cached finding from being shown without the data
/// quality caveat that qualified it on the server.
struct FitnessActivityAnalysisResponse: Codable, Equatable, Sendable {
    var findings: [FitnessAnalysisFinding]
    var records: [FitnessActivityRecord]
    var achievements: [FitnessActivityRecord]
    var dataQuality: [FitnessDataQualityFinding]
    var trainingLoad: FitnessRunningTrainingLoad?
}

struct FitnessRunningLoadWindow: Codable, Equatable, Sendable {
    var days: Int
    var distanceM: Double
    var durationS: Double
    var sessionCount: Int
    var hardSessionCount: Int
    var sessionRpeLoad: Double?
    var longRunShare: Double?
}

/// Transparent running-load components returned by the server. HausKlar keeps
/// volume, hard-day spacing and optional session-RPE load separate rather than
/// presenting an unexplained readiness or injury-risk score.
struct FitnessRunningTrainingLoad: Codable, Equatable, Sendable {
    var asOf: String
    var algorithmVersion: String
    var windows: [String: FitnessRunningLoadWindow]
    var previous7d: FitnessRunningLoadWindow
    var volumeChangePct: Double?
    var suddenVolumeChange: Bool
    var consecutiveHardDays: [[String]]
    var intensityDistribution7d: [String: Int]
    var trainingMonotony7d: Double?
    var missingRpeSessions: Int
    var sampleSize: Int
    var explanation: String
}

struct FitnessActivityReanalysisStatus: Codable, Equatable, Sendable {
    var status: String
    var jobId: String
    var activityId: String
}

struct FitnessComparableRun: Codable, Identifiable, Equatable, Sendable {
    var id: String { activity.id }
    var activity: FitnessActivitySummary
    var score: Double
    var reasons: [String]
    var componentScores: [String: Double?]?
    var selected: Bool?
    var isPreviousSimilarDistance: Bool?
    var automaticComparison: FitnessAutomaticRunComparison?
}

struct FitnessAutomaticRunComparison: Codable, Equatable, Sendable {
    var algorithmVersion: String
    var distanceLabel: String
    var currentDistanceM: Double
    var previousDistanceM: Double
    var distanceDeltaM: Double
    var currentDurationS: Double
    var previousDurationS: Double
    var durationDeltaS: Double
    var durationImprovementS: Double
    var currentPaceSPerKm: Double
    var previousPaceSPerKm: Double
    var paceDeltaSPerKm: Double
    var paceImprovementSPerKm: Double
}

struct FitnessActivityComparisonOverlay: Codable, Equatable, Sendable {
    var distanceM: [Double]
    var metrics: [String]
    var alignment: String?
    var activities: [FitnessActivityComparisonSeries]
}

struct FitnessActivityComparisonSeries: Codable, Identifiable, Equatable, Sendable {
    var id: String { activityId }
    var activityId: String
    var title: String
    var series: [String: [Double?]]
}

struct FitnessPlanAdherenceStep: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var state: String
    var actual: String
    var planned: String
    var targetAdherencePct: Double?
}

struct FitnessPlanAdherence: Codable, Equatable, Sendable {
    var status: String?
    var completedDistanceM: Double?
    var plannedDistanceM: Double?
    var completedDurationS: Double?
    var plannedDurationS: Double?
    var timeInTargetS: Double?
    var targetTimeS: Double?
    var explanation: String?
    var steps: [FitnessPlanAdherenceStep]?
}

struct FitnessActivityCheckinDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var plannedSessionId: String?
    var activityId: String?
    var capturedAtUtc: String
    var timing: String
    var captureQuality: String
    var capturedBeforeActivityStart: Bool?
    var readiness15: Int?
    var energy15: Int?
    var soreness15: Int?
    var motivation15: Int?
    var sessionRpe110: Double?
    var notes: String?
}

struct FitnessActivityBodyIssueDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var plannedSessionId: String?
    var activityId: String?
    var observedAtUtc: String
    var issueTypeKey: String
    var bodyLocationKey: String
    var side: String?
    var severity010: Int
    var timing: String
    var changedSession: Bool
    var sessionChangeKey: String?
    var notes: String?
}

struct FitnessActivityGoalLinkDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var activityId: String
    var goalId: String
    var role: String
    var revision: Int?

    var isEditable: Bool { role == "user_assigned" || role == "inferred_reviewed" }
}

struct FitnessRemotePlannedSession: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var sportKey: String
    var title: String
    var status: String
    var scheduledStartUtc: String?
    var scheduledDate: String?
    var workoutVersionId: String?
    var trainingProgrammeId: String?
    var expectedDurationS: Double?
    var expectedDistanceM: Double?
}

struct FitnessActivityDetail: Codable, Equatable, Sendable {
    var activity: FitnessActivitySummary
    var sources: [FitnessActivitySource]
    var summaryMetrics: [FitnessActivityMetric]
    var availableStreamMetrics: [String]
    var recommendedPanels: [String]?
    var intervals: [FitnessActivityInterval]
    var records: [FitnessActivityRecord]?
    var achievements: [FitnessActivityRecord]?
    var notes: String?
    var sessionRpe: Double?
    var plannedSession: FitnessRemotePlannedSession?
    var checkins: [FitnessActivityCheckinDTO]?
    var bodyIssues: [FitnessActivityBodyIssueDTO]?
    var gear: [FitnessGearItem]?
    var goalLinks: [FitnessActivityGoalLinkDTO]?
    var dataQuality: [FitnessDataQualityFinding]?
    var adherence: FitnessPlanAdherence?
}

struct FitnessActivityStream: Codable, Equatable, Sendable {
    struct RequestedRange: Codable, Equatable, Sendable {
        var fromOffsetMs: Int
        var toOffsetMs: Int
    }

    var activityId: String
    var clock: String
    var offsetMs: [Int]
    var distanceM: [Double?]?
    var series: [String: [Double?]]
    var units: [String: String]
    var downsampled: Bool
    var sourcePointCount: Int?
    var requestedRange: RequestedRange?

    func value(metric: String, nearest offset: Int) -> Double? {
        guard let values = series[metric], !offsetMs.isEmpty,
              let index = offsetMs.indices.min(by: {
                  abs(offsetMs[$0] - offset) < abs(offsetMs[$1] - offset)
              }), values.indices.contains(index) else { return nil }
        return values[index]
    }
}

struct FitnessActivityFilter: Equatable, Sendable {
    var sportKey: String?
    var dateFrom: String?
    var dateTo: String?
    var phaseId: String?
    var workoutClassification: String?
    var gearId: String?
    var status: String?
}

struct FitnessActivityContextUpdate: Codable, Equatable, Sendable {
    var title: String?
    var notes: String?
    var sessionRpe: Double?
    var workoutClassification: String?
    var plannedSessionId: String?
    var gearIds: [String]?
}

struct FitnessActivityGoalLinkInput: Codable, Equatable, Sendable {
    var goalId: String
    var role: String = "user_assigned"
}

struct FitnessActivityGoalLinksUpdate: Codable, Equatable, Sendable {
    var links: [FitnessActivityGoalLinkInput]
}

struct FitnessCalendarLayerItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var ownerUserId: String? = nil
    var layerKind: String
    var displayTitle: String
    var sportKey: String
    var status: String
    var scheduledStartUtc: String?
    var scheduledDate: String?
    var timeWindowStartUtc: String?
    var timeWindowEndUtc: String?
    var durationS: Double?
    var detailId: String
}
