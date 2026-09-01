import Foundation

enum FitnessAnalysisClassification: String, Codable, CaseIterable, Sendable {
    case descriptive
    case correlational
    case planArithmetic = "plan_arithmetic"

    var label: String {
        switch self {
        case .descriptive: "Descriptive"
        case .correlational: "Association"
        case .planArithmetic: "Plan comparison"
        }
    }

    var explanation: String {
        switch self {
        case .descriptive:
            "This summarises the records in the selected period."
        case .correlational:
            "This describes an association in the recorded data. It does not show that either factor caused the other."
        case .planArithmetic:
            "This is a calculated comparison with the recorded plan, not a prediction."
        }
    }
}

enum FitnessAnalysisChartType: String, Codable, CaseIterable, Identifiable, Sendable {
    case line
    case rollingAverage = "rolling_average"
    case bar
    case stackedBar = "stacked_bar"
    case scatter
    case histogram
    case calendarHeatmap = "calendar_heatmap"
    case rangeBand = "range_band"
    case table

    var id: String { rawValue }

    var fallbackLabel: String {
        switch self {
        case .line: "Line"
        case .rollingAverage: "Rolling average"
        case .bar: "Bar"
        case .stackedBar: "Stacked bar"
        case .scatter: "Scatter"
        case .histogram: "Histogram"
        case .calendarHeatmap: "Calendar heatmap"
        case .rangeBand: "Range band"
        case .table: "Table"
        }
    }
}

enum FitnessAnalysisStatus: String, Codable, Sendable {
    case complete, queued, processing, empty, insufficientSample = "insufficient_sample", error

    var isPending: Bool { self == .queued || self == .processing }
}

enum FitnessAnalysisFilterOperator: String, Codable, CaseIterable, Sendable {
    case equal = "eq"
    case notEqual = "not_eq"
    case containsAny = "in"
    case greaterThanOrEqual = "gte"
    case lessThanOrEqual = "lte"
    case between

    var label: String {
        switch self {
        case .equal: "is"
        case .notEqual: "is not"
        case .containsAny: "is one of"
        case .greaterThanOrEqual: "at least"
        case .lessThanOrEqual: "at most"
        case .between: "between"
        }
    }
}

struct FitnessAnalysisRegistry: Codable, Equatable, Sendable {
    struct Dimension: Codable, Identifiable, Equatable, Sendable {
        var id: String { key }
        let key: String
        let label: String
        let valueType: String
        let description: String?
    }

    struct Measure: Codable, Identifiable, Equatable, Sendable {
        var id: String { key }
        let key: String
        let label: String
        let description: String?
        let unitKey: String?
        let supportedDimensions: [String]
        let chartTypes: [FitnessAnalysisChartType]
        let allowedFilterKeys: [String]
        let comparisonForms: [String]?
        let defaultChartType: FitnessAnalysisChartType?
        let classification: FitnessAnalysisClassification
        let minimumSampleSize: Int?
    }

    struct ChartTypeDefinition: Codable, Identifiable, Equatable, Sendable {
        var id: String { key.rawValue }
        let key: FitnessAnalysisChartType
        let label: String
    }

    struct FilterDefinition: Codable, Identifiable, Equatable, Sendable {
        struct Option: Codable, Identifiable, Equatable, Sendable {
            var id: String { key }
            let key: String
            let label: String
        }

        var id: String { key }
        let key: String
        let label: String
        let valueType: String
        let operators: [FitnessAnalysisFilterOperator]
        let values: [Option]?
        let maxValues: Int?
    }

    struct Comparison: Codable, Identifiable, Equatable, Sendable {
        var id: String { key }
        let key: String
        let label: String
        let description: String?
    }

    struct Limits: Codable, Equatable, Sendable {
        let maxWindowDays: Int
        let maxOutputPoints: Int
        let maxFilters: Int
        let heavyPollIntervalMs: Int?
    }

    struct DefaultQuery: Codable, Identifiable, Equatable, Sendable {
        var id: String { key }
        let key: String
        let label: String
        let description: String?
        let dimensionKey: String
        let measureKey: String
        let chartTypeKey: FitnessAnalysisChartType
        let dateWindowDays: Int
        let filters: [FitnessAnalysisFilter]?
        let comparisonKey: String?
        let surface: String?
        let category: String?
    }

    let dimensions: [Dimension]
    let measures: [Measure]
    let chartTypes: [ChartTypeDefinition]
    let filters: [FilterDefinition]
    let comparisons: [Comparison]
    let limits: Limits
    let defaultQueries: [DefaultQuery]
}

struct FitnessAnalysisDateRange: Codable, Equatable, Sendable {
    let start: String
    let end: String
}

struct FitnessAnalysisFilter: Codable, Equatable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var `operator`: FitnessAnalysisFilterOperator
    var value: JSONValue
}

struct FitnessAnalysisQueryRequest: Codable, Equatable, Sendable {
    var measureKey: String
    var dimensionKey: String
    var chartTypeKey: FitnessAnalysisChartType
    var dateRange: FitnessAnalysisDateRange
    var filters: [FitnessAnalysisFilter]
    var comparisonKey: String?
    var maxPoints: Int
}

struct FitnessAnalysisPoint: Codable, Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let label: String
    let x: JSONValue?
    let xValue: Double?
    let value: Double?
    let low: Double?
    let high: Double?
    let sampleSize: Int?
    let missingRate: Double?
    let quality: String?

    var axisLabel: String {
        switch x {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): value.formatted()
        case .bool(let value): value ? "Yes" : "No"
        default: label
        }
    }

    var numericX: Double? {
        if let xValue { return xValue }
        switch x {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var isPlottable: Bool { value != nil }
    var isScatterPlottable: Bool { value != nil && numericX != nil }
}

struct FitnessAnalysisSeries: Codable, Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let label: String
    let unitKey: String?
    let points: [FitnessAnalysisPoint]
}

struct FitnessAnalysisMetadata: Codable, Equatable, Sendable {
    struct Period: Codable, Equatable, Sendable {
        let start: String
        let end: String
        let label: String?
    }

    let period: Period
    let sampleSize: Int
    let missingCount: Int?
    let missingRate: Double
    let sourceQuality: [String]
    let measurementQuality: [String]
    let canonicalPolicy: String
    let duplicatePolicy: String
    let classification: FitnessAnalysisClassification
}

struct FitnessAnalysisDifference: Codable, Equatable, Sendable {
    let value: Double
    let unitKey: String?
    let label: String
}

struct FitnessAnalysisQueryResult: Codable, Identifiable, Equatable, Sendable {
    var id: String { responseId ?? jobId ?? "\(measureKey)|\(dimensionKey)|\(chartTypeKey.rawValue)" }
    private let responseId: String?
    let status: FitnessAnalysisStatus
    let jobId: String?
    let pollAfterMs: Int?
    let title: String
    let description: String?
    let dimensionKey: String
    let measureKey: String
    let chartTypeKey: FitnessAnalysisChartType
    let unitKey: String?
    let series: [FitnessAnalysisSeries]
    let metadata: FitnessAnalysisMetadata
    let summary: String?
    let difference: FitnessAnalysisDifference?
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case responseId = "id"
        case status, jobId, pollAfterMs, title, description, dimensionKey, measureKey
        case chartTypeKey, unitKey, series, metadata, summary, difference, limitations
    }
}

struct FitnessSavedAnalysisChartPayload: Codable, Equatable, Sendable {
    let id: String?
    let name: String
    let measureKey: String
    let dimensionKey: String
    let chartTypeKey: FitnessAnalysisChartType
    let filterKeys: [String]
    let comparisonKey: String?
    let dateWindowDays: Int
}

struct FitnessSavedAnalysisChart: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let revision: Int?
    let createdAt: String?
    let updatedAt: String?
    let deletedAt: String?
    let queuedOffline: Bool?
    let name: String
    let measureKey: String
    let dimensionKey: String
    let chartTypeKey: FitnessAnalysisChartType
    let filterKeys: [String]
    let comparisonKey: String?
    let dateWindowDays: Int
}

enum FitnessAnalysisQueryValidator {
    static func problem(
        with query: FitnessAnalysisQueryRequest,
        registry: FitnessAnalysisRegistry
    ) -> String? {
        guard registry.dimensions.contains(where: { $0.key == query.dimensionKey }) else {
            return "Choose an available grouping."
        }
        guard let measure = registry.measures.first(where: { $0.key == query.measureKey }) else {
            return "Choose an available measure."
        }
        guard measure.supportedDimensions.contains(query.dimensionKey) else {
            return "That measure cannot be grouped by this dimension."
        }
        guard measure.chartTypes.contains(query.chartTypeKey),
              registry.chartTypes.contains(where: { $0.key == query.chartTypeKey }) else {
            return "That chart is not available for this measure."
        }
        guard let days = windowDays(query.dateRange), days > 0 else {
            return "Choose a valid date window."
        }
        guard days <= registry.limits.maxWindowDays else {
            return "The maximum analysis window is \(registry.limits.maxWindowDays) days."
        }
        guard (1...registry.limits.maxOutputPoints).contains(query.maxPoints) else {
            return "Results are limited to \(registry.limits.maxOutputPoints) points."
        }
        guard query.filters.count <= registry.limits.maxFilters else {
            return "Use at most \(registry.limits.maxFilters) filters."
        }
        guard Set(query.filters.map(\.key)).count == query.filters.count else {
            return "Use each filter once."
        }
        for filter in query.filters {
            guard measure.allowedFilterKeys.contains(filter.key),
                  let definition = registry.filters.first(where: { $0.key == filter.key }),
                  definition.operators.contains(filter.operator) else {
                return "Choose an available filter and condition."
            }
            let values = scalarValues(filter.value)
            guard !values.isEmpty,values.allSatisfy({ valid($0,for: definition.valueType) }) else {
                return "Choose a value for \(definition.label)."
            }
            if filter.operator == .between,values.count != 2 {
                return "Choose two values for \(definition.label)."
            }
            if let maximum = definition.maxValues, values.count > maximum {
                return "\(definition.label) accepts at most \(maximum) values."
            }
            if let options = definition.values, !options.isEmpty {
                let allowed = Set(options.map(\.key))
                guard values.allSatisfy({ valueKey($0).map(allowed.contains) == true }) else {
                    return "Choose an available \(definition.label.lowercased()) value."
                }
            }
        }
        if let comparison = query.comparisonKey {
            guard registry.comparisons.contains(where: { $0.key == comparison }),
                  measure.comparisonForms?.contains(comparison) == true else {
                return "That comparison is not available for this measure."
            }
        }
        return nil
    }

    static func query(
        from preset: FitnessAnalysisRegistry.DefaultQuery,
        registry: FitnessAnalysisRegistry,
        endingOn end: String = localDateString()
    ) -> FitnessAnalysisQueryRequest {
        let days = min(max(1, preset.dateWindowDays), registry.limits.maxWindowDays)
        return FitnessAnalysisQueryRequest(
            measureKey: preset.measureKey,
            dimensionKey: preset.dimensionKey,
            chartTypeKey: preset.chartTypeKey,
            dateRange: FitnessAnalysisDateRange(start: dateString(daysBefore: days - 1, end: end), end: end),
            filters: preset.filters ?? [],
            comparisonKey: preset.comparisonKey,
            maxPoints: registry.limits.maxOutputPoints
        )
    }

    static func savedPayload(
        name: String,
        query: FitnessAnalysisQueryRequest,
        registry: FitnessAnalysisRegistry
    ) -> FitnessSavedAnalysisChartPayload? {
        guard problem(with: query, registry: registry) == nil,
              let days = windowDays(query.dateRange) else { return nil }
        return FitnessSavedAnalysisChartPayload(
            id: nil,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            measureKey: query.measureKey,
            dimensionKey: query.dimensionKey,
            chartTypeKey: query.chartTypeKey,
            filterKeys: query.filters.map(\.key),
            comparisonKey: query.comparisonKey,
            dateWindowDays: days
        )
    }

    static func windowDays(_ range: FitnessAnalysisDateRange) -> Int? {
        guard let start = date(range.start), let end = date(range.end), end >= start else { return nil }
        return Calendar.utc.dateComponents([.day], from: start, to: end).day.map { $0 + 1 }
    }

    static func localDateString(_ value: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: value)
        let localDate = Calendar.utc.date(from: components) ?? value
        return ISODateParser.stringUTCDateOnly(from: localDate)
    }

    static func dateString(daysBefore: Int, end: String) -> String {
        guard let value = date(end),
              let result = Calendar.utc.date(byAdding: .day, value: -max(0, daysBefore), to: value) else { return end }
        return ISODateParser.stringUTCDateOnly(from: result)
    }

    private static func date(_ value: String) -> Date? {
        ISODateParser.parseUTCDateOnly(value)
    }

    private static func scalarValues(_ value: JSONValue) -> [JSONValue] {
        switch value {
        case .array(let values): values.filter(isScalar)
        default: isScalar(value) ? [value] : []
        }
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .string, .int, .double, .bool: true
        default: false
        }
    }

    private static func valueKey(_ value: JSONValue) -> String? {
        switch value {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    private static func valid(_ value: JSONValue,for valueType: String) -> Bool {
        switch valueType {
        case "number":
            if case .int = value { return true }
            if case .double = value { return true }
            return false
        case "boolean":
            if case .bool = value { return true }
            return false
        case "date":
            guard case .string(let value) = value else { return false }
            return date(value) != nil
        default:
            guard case .string(let value) = value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }
}
