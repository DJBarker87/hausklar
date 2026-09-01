import Foundation

enum FitnessHealthKitSampleKind: String, Codable, CaseIterable, Sendable {
    case bodyMass = "HKQuantityTypeIdentifierBodyMass"
    case sleepAnalysis = "HKCategoryTypeIdentifierSleepAnalysis"
    case restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
    case heartRateVariabilitySDNN = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    case workout = "HKWorkoutTypeIdentifier"

    var predicateVersion: Int { 1 }
}

struct FitnessHealthKitWorkoutImport: Codable, Equatable, Sendable {
    var sourceBundleIdentifier:String
    var workoutUuid:String
    var originProviderKey:String
    var externalUuid:String?
    var sourceName:String?
    var sourceDeviceIdentifier:String?
    var productType:String?
    var sportKey:String?
    var subSportKey:String?
    var title:String?
    var startedAtUtc:String?
    var endedAtUtc:String?
    var durationS:Double?
    var distanceM:Double?
    var energyKcal:Double?
    var localTimezone:String?
    var deleted:Bool
}

struct FitnessHealthKitWorkoutImportResponse:Codable,Equatable,Sendable {
    var status:String
    var sourceRecordId:String
    var activityId:String?
    var deleted:Bool
}

struct FitnessHealthKitWorkoutSource:Codable,Equatable,Sendable {
    var workoutUuid:String
    var sourceBundleIdentifier:String
    var originProviderKey:String
    var externalUuid:String?
    var sourceName:String?
    var sourceDeviceIdentifier:String?
    var productType:String?
}

struct FitnessHealthKitProvenance: Codable, Equatable, Sendable {
    var sourceBundleIdentifier: String
    var sourceObjectId: String
    var sourceName: String?
    var productType: String?
    var originProviderKey: String
    var externalObjectId: String?
    var sourceDeviceIdentifier: String?
    var device: [String: String]
    var metadata: [String: JSONValue]
}

struct FitnessHealthKitSample: Codable, Equatable, Sendable {
    enum DomainKind: String, Codable, Sendable {
        case bodyMeasurement = "body_measurement"
        case sleepSession = "sleep_session"
        case recoveryObservation = "recovery_observation"
    }

    var kind: FitnessHealthKitSampleKind
    var domainKind: DomainKind
    var startDate: Date
    var endDate: Date
    var value: Double?
    var unitKey: String?
    var sleepStage: String?
    var provenance: FitnessHealthKitProvenance
}

struct FitnessHealthKitDeletedObject: Codable, Equatable, Sendable {
    var kind: FitnessHealthKitSampleKind
    var sourceObjectId: String
}

struct FitnessHealthKitAnchorState: Equatable, Sendable {
    var sampleType: String
    var predicateVersion: Int
    var anchorData: Data?
    var lastCompletedAt: Date?
}

enum FitnessHealthKitAccessState: Equatable, Sendable {
    case unavailable
    case notRequested
    case needsPermission
    case enabled(lastImport: Date?)
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: "Health data is unavailable on this device"
        case .notRequested: "Health access has not been requested"
        case .needsPermission: "Review Health permissions"
        case .enabled: "Health import enabled"
        case .failed(let message): message
        }
    }
}

struct FitnessExternalSourceDTO: Codable, Equatable, Sendable {
    var transportKey: String
    var originProviderKey: String
    var sourceNamespace: String
    var sourceDeviceIdentifier: String?
    var state: String?
}

struct FitnessSourcePriorityDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var metricKey: String
    var originProviderKey: String
    var transportKey: String
    var sourceNamespace: String
    var priority: Int
    var revision: Int?
    var updatedAt: String?
    var deletedAt: String?

    func matches(_ source: FitnessExternalSourceDTO,metricKey: String) -> Bool {
        self.metricKey == metricKey
            && originProviderKey == source.originProviderKey
            && (transportKey.isEmpty || transportKey == source.transportKey)
            && (sourceNamespace.isEmpty || sourceNamespace == source.sourceNamespace)
    }
}

struct FitnessSleepStageDTO: Codable, Equatable, Sendable {
    var stage: String
    var startAtUtc: String
    var endAtUtc: String
    var durationS: Double
    var sourceRecordId: String? = nil
}

struct FitnessSleepSessionDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var sleepStartUtc: String
    var sleepEndUtc: String
    var durationS: Double
    var awakeDurationS: Double?
    var sourceQuality: String?
    var sourceStages: [FitnessSleepStageDTO]?
    var sourceRecordId: String? = nil
    var source: FitnessExternalSourceDTO?
    var notes: String?
    var revision: Int?
    var createdAt: String?
    var updatedAt: String?
    var deletedAt: String?
}

struct FitnessRecoveryObservationDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var metricKey: String
    var observedAtUtc: String
    var valueNumber: Double?
    var valueText: String?
    var unitKey: String?
    var sourceQuality: String?
    var sourceRecordId: String? = nil
    var source: FitnessExternalSourceDTO?
    var notes: String?
    var revision: Int?
    var createdAt: String?
    var updatedAt: String?
    var deletedAt: String?
}

struct FitnessRecoverySummaryDTO: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        var fromDate: String
        var toDate: String
        var expectedDays: Int
        var daysWithSleep: Int
    }
    struct Sleep: Codable, Equatable, Sendable {
        var averageDurationS: Double?
        var averageBedtimeMinutes: Double?
        var averageWakeTimeMinutes: Double?
        var timingRegularityMinutes: Double?
    }
    struct Baseline: Codable, Identifiable, Equatable, Sendable {
        var id: String { metricKey }
        var metricKey: String
        var label: String
        var unitKey: String?
        var currentValue: Double?
        var baselineValue: Double?
        var deviationAbsolute: Double?
        var deviationPercent: Double?
        var status: String
        var windowDays: Int
        var observedAtUtc: String?
        var sourceName: String?
        var missingReason: String?
    }
    struct Relationship: Codable, Identifiable, Equatable, Sendable {
        var id: String { "\(label):\(sampleSize)" }
        var label: String
        var summary: String
        var sampleSize: Int
        var limitation: String?
    }
    var window: Window
    var sleep: Sleep
    var baselines: [Baseline]
    var relationships: [Relationship]
}

struct FitnessReadinessHistoryItem: Identifiable, Equatable, Sendable {
    let id: String
    var recordedAt: Date
    var value: Int
    var isRetrospective: Bool
    var activityTitle: String?
    var sessionRPE: Double?
    var performance: Int?
}

enum FitnessProgressPhotoPose: String, Codable, CaseIterable, Identifiable, Sendable {
    case front, sideLeft = "side_left", sideRight = "side_right", back, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .front: "Front".localized
        case .sideLeft: "Side left".localized
        case .sideRight: "Side right".localized
        case .back: "Back pose".localized
        case .custom: "Custom".localized
        }
    }
}

struct FitnessProgressPhotoDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var capturedAt: String
    var pose: FitnessProgressPhotoPose
    var bodyWeightKg: Double?
    var measurementSnapshotJson: [String: JSONValue]?
    var phaseId: String?
    var phaseName: String?
    var originalAssetId: String
    var thumbnailAssetId: String?
    var originalState: String?
    var thumbnailState: String?
    var notes: String?
    var metadataAcknowledged: Bool?
    var revision: Int?
    var createdAt: String?
    var updatedAt: String?
    var deletedAt: String?
}

struct FitnessPrivateAssetUploadResult: Codable, Equatable, Sendable {
    var assetId: String
    var state: String
    var storageClass: String
    var uploadAcknowledged: Bool
}

struct FitnessPendingProgressPhoto: Identifiable, Equatable, Sendable {
    let id: String
    var photo: FitnessProgressPhotoDTO
    var originalFilename: String
    var mediaType: String
    var byteCount: Int
    var state: String
    var uploadAcknowledged: Bool
    var metadataAcknowledged: Bool
    var attempts: Int
    var lastError: String?
    var hasLocalOriginal: Bool
}

struct FitnessProgressPhotoCreateRequest: Codable, Equatable, Sendable {
    var id: String
    var clientId: String
    var clientTimestamp: String
    var capturedAt: String
    var pose: FitnessProgressPhotoPose
    var bodyWeightKg: Double?
    var measurementSnapshotJson: [String: JSONValue]?
    var phaseId: String?
    var originalAssetId: String
    var notes: String?
}

// MARK: - Connected measurements and trends

enum FitnessMeasurementMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case weight
    case bodyFat = "body_fat"
    case bloodPressure = "blood_pressure"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weight: "Weight"
        case .bodyFat: "Body fat"
        case .bloodPressure: "Blood pressure"
        }
    }

    var compactTitle: String {
        switch self {
        case .weight: "Weight"
        case .bodyFat: "Body fat"
        case .bloodPressure: "BP"
        }
    }

    var symbol: String {
        switch self {
        case .weight: "scalemass.fill"
        case .bodyFat: "percent"
        case .bloodPressure: "heart.text.square.fill"
        }
    }
}

enum FitnessMeasurementDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case trend
    case raw

    var id: String { rawValue }
    var title: String {
        switch self {
        case .trend: "Smoothed"
        case .raw: "Raw"
        }
    }
}

enum FitnessMeasurementYAxisScale: String, CaseIterable, Identifiable, Sendable {
    case tight
    case fit
    case wide

    static let defaultScale: FitnessMeasurementYAxisScale = .fit

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tight: "Tight"
        case .fit: "Fit"
        case .wide: "Wide"
        }
    }
}

enum FitnessMeasurementChartDomainPolicy {
    static func domain(
        values: [Double],
        metric: FitnessMeasurementMetric,
        scale: FitnessMeasurementYAxisScale
    ) -> ClosedRange<Double> {
        let finiteValues = values.filter(\.isFinite)
        guard let low = finiteValues.min(), let high = finiteValues.max() else { return 0...1 }
        let paddingRule: (fraction: Double, minimum: Double)
        switch scale {
        case .tight:
            paddingRule = (0.05, metric == .bloodPressure ? 2 : 0.25)
        case .fit:
            paddingRule = (0.12, metric == .bloodPressure ? 5 : 1)
        case .wide:
            paddingRule = (0.35, metric == .bloodPressure ? 10 : 2)
        }
        let padding = max(paddingRule.minimum, (high - low) * paddingRule.fraction)
        return (low - padding)...(high + padding)
    }
}

/// Keeps Swift Charts work proportional to the visible window rather than to a
/// member's entire measurement history. The complete history remains available
/// for scrolling, selection and exact readouts; only the marks handed to Charts
/// are windowed and, for unusually dense data, evenly sampled.
enum FitnessMeasurementChartRenderingPolicy {
    static let maximumLinePointCount = 480
    static let maximumPointMarkCount = 180
    private static let secondsPerDay = 86_400.0

    static func visibleDaysAfterPinch(
        startingVisibleDays: Double,
        magnification: Double,
        maximumVisibleDays: Double
    ) -> Double {
        guard startingVisibleDays.isFinite, startingVisibleDays > 0,
              magnification.isFinite, magnification > 0,
              maximumVisibleDays.isFinite else {
            return max(7, min(startingVisibleDays, maximumVisibleDays))
        }
        let maximum = max(7, maximumVisibleDays)
        return min(maximum, max(7, startingVisibleDays / magnification))
    }

    static func linePoints(
        from points: [FitnessMeasurementHistoryPointDTO],
        viewportStart: Date,
        visibleDays: Double
    ) -> [FitnessMeasurementHistoryPointDTO] {
        let days = max(0, visibleDays)
        let bufferDays = min(14, max(2, days * 0.15))
        let start = viewportStart.addingTimeInterval(-bufferDays * secondsPerDay)
        let end = viewportStart.addingTimeInterval((days + bufferDays) * secondsPerDay)
        return sampled(
            pointsInRange(
                points,
                from: start,
                through: end,
                includeNeighbours: true
            ),
            maximumCount: maximumLinePointCount
        )
    }

    static func pointMarks(
        from points: [FitnessMeasurementHistoryPointDTO],
        viewportStart: Date,
        visibleDays: Double
    ) -> [FitnessMeasurementHistoryPointDTO] {
        sampled(
            visiblePoints(from: points, viewportStart: viewportStart, visibleDays: visibleDays),
            maximumCount: maximumPointMarkCount
        )
    }

    static func visiblePoints(
        from points: [FitnessMeasurementHistoryPointDTO],
        viewportStart: Date,
        visibleDays: Double
    ) -> [FitnessMeasurementHistoryPointDTO] {
        let end = viewportStart.addingTimeInterval(max(0, visibleDays) * secondsPerDay)
        return pointsInRange(
            points,
            from: viewportStart,
            through: end,
            includeNeighbours: false
        )
    }

    static func nearestPoint(
        in points: [FitnessMeasurementHistoryPointDTO],
        to date: Date
    ) -> FitnessMeasurementHistoryPointDTO? {
        guard !points.isEmpty else { return nil }
        let nextIndex = lowerBound(in: points, for: date)
        if nextIndex == 0 { return points[0] }
        if nextIndex == points.count { return points[points.count - 1] }
        let previous = points[nextIndex - 1]
        let next = points[nextIndex]
        guard let previousDate = previous.measuredAt else { return next }
        guard let nextDate = next.measuredAt else { return previous }
        return abs(previousDate.timeIntervalSince(date)) <= abs(nextDate.timeIntervalSince(date))
            ? previous : next
    }

    private static func pointsInRange(
        _ points: [FitnessMeasurementHistoryPointDTO],
        from start: Date,
        through end: Date,
        includeNeighbours: Bool
    ) -> [FitnessMeasurementHistoryPointDTO] {
        guard !points.isEmpty, end >= start else { return [] }
        var first = lowerBound(in: points, for: start)
        var last = upperBound(in: points, for: end)
        if includeNeighbours {
            first = max(0, first - 1)
            last = min(points.count, last + 1)
        }
        guard first < last else { return [] }
        return Array(points[first..<last])
    }

    private static func sampled(
        _ points: [FitnessMeasurementHistoryPointDTO],
        maximumCount: Int
    ) -> [FitnessMeasurementHistoryPointDTO] {
        guard maximumCount > 1, points.count > maximumCount else { return points }
        let stride = Double(points.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            points[Int((Double(index) * stride).rounded())]
        }
    }

    private static func lowerBound(
        in points: [FitnessMeasurementHistoryPointDTO],
        for date: Date
    ) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if (points[middle].measuredAt ?? .distantPast) < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func upperBound(
        in points: [FitnessMeasurementHistoryPointDTO],
        for date: Date
    ) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if (points[middle].measuredAt ?? .distantPast) <= date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

enum FitnessMeasurementRange: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case threeMonths
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "7 Days"
        case .month: "30 Days"
        case .threeMonths: "90 Days"
        case .year: "365 Days"
        }
    }

    var compactTitle: String {
        switch self {
        case .week: "7D"
        case .month: "30D"
        case .threeMonths: "90D"
        case .year: "1Y"
        }
    }

    var visibleDays: Double? {
        switch self {
        case .week: 7
        case .month: 30
        case .threeMonths: 90
        case .year: 365
        }
    }
}

struct FitnessWithingsConnectionStatusDTO: Codable, Equatable, Sendable {
    var configured: Bool
    var connected: Bool
    var status: String
    var lastSyncAt: String?
    var dataThroughAt: String?
    var lastErrorCode: String?
    var webhookStatus: String?
    var subscribedCategories: [Int]
    var importedMeasurementCount: Int
}

struct FitnessWithingsConnectionStartResponseDTO: Codable, Equatable, Sendable {
    var authorizationUrl: String
    var expiresAt: String
}

struct FitnessWithingsSyncResponseDTO: Codable, Equatable, Sendable {
    var status: String
    var imported: Int
    var updated: Int
    var unchanged: Int
    var ignored: Int
    var dataThroughAt: String?
}

struct FitnessWithingsDisconnectResponseDTO: Codable, Equatable, Sendable {
    var status: String
    var retainedMeasurementCount: Int
}

struct FitnessMeasurementHistoryPointDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var measuredAtUtc: String {
        didSet { cachedMeasuredAt = FitnessDatabase.date(measuredAtUtc) }
    }
    var rawValue: Double
    var trendValue: Double
    var sourceLabel: String?
    private var cachedMeasuredAt: Date?

    var measuredAt: Date? { cachedMeasuredAt }

    init(
        id: String,
        measuredAtUtc: String,
        rawValue: Double,
        trendValue: Double,
        sourceLabel: String?
    ) {
        self.id = id
        self.measuredAtUtc = measuredAtUtc
        self.rawValue = rawValue
        self.trendValue = trendValue
        self.sourceLabel = sourceLabel
        cachedMeasuredAt = FitnessDatabase.date(measuredAtUtc)
    }

    private enum CodingKeys: String, CodingKey {
        case id, measuredAtUtc, rawValue, trendValue, sourceLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        measuredAtUtc = try container.decode(String.self, forKey: .measuredAtUtc)
        rawValue = try container.decode(Double.self, forKey: .rawValue)
        trendValue = try container.decode(Double.self, forKey: .trendValue)
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        cachedMeasuredAt = FitnessDatabase.date(measuredAtUtc)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(measuredAtUtc, forKey: .measuredAtUtc)
        try container.encode(rawValue, forKey: .rawValue)
        try container.encode(trendValue, forKey: .trendValue)
        try container.encodeIfPresent(sourceLabel, forKey: .sourceLabel)
    }

    func value(for mode: FitnessMeasurementDisplayMode) -> Double {
        mode == .raw ? rawValue : trendValue
    }
}

struct FitnessMeasurementHistorySeriesDTO: Codable, Identifiable, Equatable, Sendable {
    var key: String
    var label: String
    var unit: String
    var points: [FitnessMeasurementHistoryPointDTO]
    var id: String { key }
}

struct FitnessMeasurementHistoryDTO: Codable, Equatable, Sendable {
    var metric: FitnessMeasurementMetric
    var title: String
    var unit: String
    var smoothingMethod: String
    var smoothingHalfLifeDays: Double
    var series: [FitnessMeasurementHistorySeriesDTO]
    var sampleCount: Int
    var lastUpdatedAt: String?

    var datedPoints: [(series: FitnessMeasurementHistorySeriesDTO, point: FitnessMeasurementHistoryPointDTO)] {
        series.flatMap { series in
            series.points.compactMap { point in
                point.measuredAt == nil ? nil : (series, point)
            }
        }
    }
}

/// Builds the same transparent daily, time-weighted trend used by the API. It
/// also lets the native app reconstruct charts from its encrypted local Fitness
/// store when the server cannot be reached.
enum FitnessMeasurementHistoryBuilder {
    static let smoothingHalfLifeDays = 7.0

    private struct Sample {
        let id: String
        let date: Date
        let value: Double
        let sourceLabel: String?
    }

    static func make(
        metric: FitnessMeasurementMetric,
        bodyMeasurements: [FitnessBodyMeasurement],
        recoveryObservations: [FitnessRecoveryObservationDTO],
        startAt: Date? = nil,
        endAt: Date? = nil
    ) -> FitnessMeasurementHistoryDTO {
        let definitions: [(key: String, label: String, metricKey: String, body: Bool)]
        switch metric {
        case .weight:
            definitions = [("weight", "Weight", "body.weight_kg", true)]
        case .bodyFat:
            definitions = [("body_fat", "Body fat", "body.body_fat_pct", true)]
        case .bloodPressure:
            definitions = [
                ("systolic", "Systolic", "vitals.blood_pressure_systolic_mmhg", false),
                ("diastolic", "Diastolic", "vitals.blood_pressure_diastolic_mmhg", false),
            ]
        }
        let unit = metric == .weight ? "kg" : (metric == .bodyFat ? "%" : "mmHg")
        let output = definitions.map { definition -> FitnessMeasurementHistorySeriesDTO in
            let samples: [Sample]
            if definition.body {
                samples = bodyMeasurements.compactMap { measurement in
                    guard measurement.metricKey == definition.metricKey,
                          measurement.isCanonical,
                          measurement.value.isFinite else { return nil }
                    return Sample(
                        id: measurement.id,date: measurement.measuredAt,value: measurement.value,
                        sourceLabel: measurement.sourceDetails?.originProviderKey
                            .replacingOccurrences(of: "_",with: " ").capitalized
                            ?? measurement.source.rawValue.capitalized
                    )
                }
            } else {
                samples = recoveryObservations.compactMap { observation in
                    guard observation.metricKey == definition.metricKey,
                          let date = FitnessDatabase.date(observation.observedAtUtc),
                          let value = observation.valueNumber,value.isFinite else { return nil }
                    return Sample(
                        id: observation.id,date: date,value: value,
                        sourceLabel: observation.source?.originProviderKey
                            .replacingOccurrences(of: "_",with: " ").capitalized
                            ?? "Imported"
                    )
                }
            }
            let ordered = samples.sorted { lhs,rhs in
                lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
            }
            let trends = exponentialTrend(ordered)
            let points = ordered.compactMap { sample -> FitnessMeasurementHistoryPointDTO? in
                if let startAt, sample.date < startAt { return nil }
                if let endAt, sample.date > endAt { return nil }
                guard let trend = trends[sample.id] else { return nil }
                return FitnessMeasurementHistoryPointDTO(
                    id: sample.id,measuredAtUtc: FitnessDatabase.dateString(sample.date),
                    rawValue: sample.value,trendValue: trend,sourceLabel: sample.sourceLabel
                )
            }
            return FitnessMeasurementHistorySeriesDTO(
                key: definition.key,label: definition.label,unit: unit,points: points
            )
        }
        let latest = output.flatMap(\.points).compactMap { FitnessDatabase.date($0.measuredAtUtc) }.max()
        return FitnessMeasurementHistoryDTO(
            metric: metric,title: metric.title,unit: unit,
            smoothingMethod: "time_weighted_exponential",
            smoothingHalfLifeDays: smoothingHalfLifeDays,series: output,
            sampleCount: output.reduce(0) { $0 + $1.points.count },
            lastUpdatedAt: latest.map(FitnessDatabase.dateString)
        )
    }

    private static func exponentialTrend(_ samples: [Sample]) -> [String: Double] {
        var daily: [Date: [Sample]] = [:]
        let calendar = utcCalendar
        for sample in samples {
            daily[calendar.startOfDay(for: sample.date),default: []].append(sample)
        }
        var values: [String: Double] = [:]
        var trend: Double?
        var previousDay: Date?
        for day in daily.keys.sorted() {
            let samplesForDay = daily[day] ?? []
            guard !samplesForDay.isEmpty else { continue }
            let dailyValue = samplesForDay.reduce(0) { $0 + $1.value } / Double(samplesForDay.count)
            if let current = trend,let previousDay {
                let elapsed = max(1,calendar.dateComponents([.day],from: previousDay,to: day).day ?? 1)
                let alpha = 1 - pow(0.5,Double(elapsed) / smoothingHalfLifeDays)
                trend = current + alpha * (dailyValue - current)
            } else {
                trend = dailyValue
            }
            guard let trend else { continue }
            samplesForDay.forEach { values[$0.id] = trend }
            previousDay = day
        }
        return values
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }
}
