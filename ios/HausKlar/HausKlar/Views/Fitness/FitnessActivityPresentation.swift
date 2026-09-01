import SwiftUI

enum FitnessActivityPrimarySection: String, Identifiable, Sendable {
    case route
    case headlineMetrics
    case splits
    case charts
    case moreStats
    case context
    case insights

    var id: String { rawValue }
}

struct FitnessActivityChartGroups: Equatable, Sendable {
    let primary: [String]
    let additional: [String]
}

enum FitnessActivityIntervalPresentation {
    static func number(_ interval: FitnessActivityInterval, keys: [String]) -> Double? {
        keys.compactMap { interval.metricValues[$0]?.doubleValue }.first
    }

    static func elevation(_ interval: FitnessActivityInterval) -> Double? {
        number(
            interval,
            keys: ["elevation.change_m", "elevation.delta_m"]
        )
    }

    static func averageHeartRate(_ interval: FitnessActivityInterval) -> Double? {
        number(
            interval,
            keys: [
                "heart_rate.average_bpm", "average_heart_rate_bpm", "heart_rate_bpm",
            ]
        )
    }

    static func maximumHeartRate(_ interval: FitnessActivityInterval) -> Double? {
        number(
            interval,
            keys: ["heart_rate.maximum_bpm", "maximum_heart_rate_bpm"]
        )
    }

    static func averagePower(_ interval: FitnessActivityInterval) -> Double? {
        number(interval, keys: ["power.average_w", "average_power_w", "power_w"])
    }

    static func distance(_ interval: FitnessActivityInterval) -> Double? {
        if let start = interval.startDistanceM, let end = interval.endDistanceM {
            return max(0, end - start)
        }
        return interval.endDistanceM ?? number(interval, keys: ["distance_m"])
    }

    static func elapsedDuration(_ interval: FitnessActivityInterval) -> Double {
        number(
            interval,
            keys: ["elapsed_duration_s", "duration_s", "elapsed_time_s"]
        ) ?? max(0, Double(interval.endOffsetMs - interval.startOffsetMs) / 1_000)
    }

    static func timerDuration(_ interval: FitnessActivityInterval) -> Double {
        number(
            interval,
            keys: ["timer_duration_s", "moving_duration_s", "moving_time_s"]
        ) ?? elapsedDuration(interval)
    }

    static func pace(_ interval: FitnessActivityInterval) -> Double? {
        if let pace = number(
            interval, keys: ["pace_s_per_km", "pace.average_s_per_km"]
        ) {
            return pace
        }
        if let speed = number(
            interval, keys: ["speed.average_mps", "average_speed_mps"]
        ), speed > 0 {
            return 1_000 / speed
        }
        guard let distance = distance(interval), distance > 0 else { return nil }
        let duration = timerDuration(interval)
        return duration > 0 ? duration * 1_000 / distance : nil
    }
}

struct FitnessActivitySourcePresentation: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let detail: String?
}

enum FitnessActivityPresentationPolicy {
    static let primarySections: [FitnessActivityPrimarySection] = [
        .route, .headlineMetrics, .splits, .charts, .moreStats, .context, .insights,
    ]
    static let intervalGroupOrder = ["source_lap", "kilometre", "mile", "interval"]
    static let detailError = "This activity couldn’t be refreshed. Try again."
    static let actionError = "That change couldn’t be saved. Try again."

    static func isRun(_ sportKey: String) -> Bool {
        normalised(sportKey).contains("run")
    }

    static func preferredIntervalGroup(available: [String]) -> String? {
        intervalGroupOrder.first { available.contains($0) }
    }

    static func runChartGroups(_ metrics: [String]) -> FitnessActivityChartGroups {
        let available = Set(metrics)
        var primary: [String] = []
        if available.contains("pace_s_per_km") {
            primary.append("pace_s_per_km")
        } else if available.contains("speed_mps") {
            primary.append("speed_mps")
        }
        primary += ["heart_rate_bpm", "altitude_m", "cadence_spm"]
            .filter(available.contains)
        if primary.isEmpty, let first = metrics.first {
            primary = [first]
        }
        return FitnessActivityChartGroups(
            primary: primary,
            additional: metrics.filter { !primary.contains($0) }
        )
    }

    static func historyError(hasActivities: Bool) -> String {
        hasActivities
            ? "Activities couldn’t be refreshed. Try again."
            : "Activities couldn’t be loaded. Try again."
    }

    static func uniqueSports(_ values: [FitnessRegisteredSport]) -> [FitnessRegisteredSport] {
        var seen = Set<String>()
        return values.filter { value in
            let key = normalised(value.key)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    static func routeSampleIndices(count: Int, maximum: Int) -> [Int] {
        guard count > 0, maximum > 0 else { return [] }
        guard count > maximum, maximum > 1 else { return Array(0..<min(count, maximum)) }
        let scale = Double(count - 1) / Double(maximum - 1)
        return (0..<maximum).map { Int((Double($0) * scale).rounded()) }
    }

    static func uniqueAnalysisFindings(
        _ values: [FitnessAnalysisFinding]
    ) -> [FitnessAnalysisFinding] {
        var seen = Set<String>()
        return values.filter { finding in
            let key = normalised(finding.key)
            let identity =
                key.isEmpty
                ? "\(normalised(finding.title))|\(normalised(finding.summary))"
                : key
            return seen.insert(identity).inserted
        }
    }

    static func uniqueQualityFindings(
        _ values: [FitnessDataQualityFinding]
    ) -> [FitnessDataQualityFinding] {
        var ids = Set<String>()
        var content = Set<String>()
        return values.filter { finding in
            let identity = normalised(finding.id)
            let semantic = [
                normalised(finding.key),
                String(finding.startOffsetMs ?? -1), String(finding.endOffsetMs ?? -1),
            ].joined(separator: "|")
            return ids.insert(identity).inserted && content.insert(semantic).inserted
        }
    }

    static func uniqueRecords(
        _ values: [FitnessActivityRecord]
    ) -> [FitnessActivityRecord] {
        var seen = Set<String>()
        return values.filter { record in
            seen.insert("\(normalised(record.recordKey))|\(normalised(record.value))").inserted
        }
    }

    static func uniqueSources(
        _ values: [FitnessActivitySource]
    ) -> [FitnessActivitySourcePresentation] {
        var seen = Set<String>()
        return values.compactMap { source in
            let label = FitnessDisplay.sourceName(source.provider ?? source.sourceType)
            let detail = source.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = "\(normalised(label))|\(normalised(detail ?? ""))"
            guard seen.insert(identity).inserted else { return nil }
            return FitnessActivitySourcePresentation(
                id: identity, label: label, detail: detail?.isEmpty == false ? detail : nil
            )
        }
    }

    static func qualityMessage(_ finding: FitnessDataQualityFinding) -> String {
        switch finding.key {
        case "impossible_speed": "Some speed readings look implausible."
        case "gps_spike": "Part of the recorded route jumps unexpectedly."
        case "missing_route_sections": "Part of the route is missing."
        case "heart_rate_dropout", "brief_heart_rate_dropout":
            "Heart-rate readings are missing for part of this activity."
        case "cadence_gap": "Cadence readings are missing for part of this activity."
        case "heart_rate_plateau", "heart_rate_spike":
            "Some heart-rate readings look unusual."
        case "duplicate_samples": "Repeated readings were removed."
        case "timer_inconsistency": "The recorded times do not fully agree."
        case "incomplete_or_disagreeing_distance":
            "The recorded distance does not fully agree."
        default: "Some recorded data may be incomplete."
        }
    }

    static func importIcon(_ status: FitnessImportStatus) -> String {
        switch status {
        case .queued: "clock"
        case .uploading: "arrow.up.circle"
        case .processing: "hourglass"
        case .complete: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    static func importLabel(_ item: FitnessPendingFITImport) -> String {
        switch item.status {
        case .queued: "Waiting to import"
        case .uploading: "Importing"
        case .processing: "Finishing import"
        case .complete: "Ready"
        case .error: item.retryable ? "Needs a retry" : "Couldn’t import this file"
        }
    }

    private static func normalised(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct FitnessAnalysisView: View {
    var body: some View {
        FitnessAnalysisWorkspaceView(title: "Analysis", surface: "explore")
    }
}

enum FitnessDisplay {
    static func humanKey(_ key: String) -> String {
        key.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    static func sourceName(_ key: String) -> String {
        switch key {
        case "apple_health", "healthkit": "Apple Health"
        case "garmin", "garmin_connect": "Garmin"
        case "manual_fit": "FIT import"
        default: humanKey(key)
        }
    }

    static func summaryMetricTitle(_ key: String) -> String {
        switch key {
        case "running.average_pace_s_per_km": "Average pace"
        case "speed.average_mps": "Average speed"
        case "speed.maximum_mps": "Maximum speed"
        case "heart_rate.average_bpm": "Average heart rate"
        case "heart_rate.maximum_bpm": "Maximum heart rate"
        case "cadence.average_spm", "running.cadence_spm": "Average cadence"
        case "elevation.maximum_m": "Maximum elevation"
        case "elevation.gain_m": "Elevation gain"
        case "elevation.loss_m": "Elevation loss"
        default: humanKey(key)
        }
    }

    static func summaryMetricValue(_ metric: FitnessActivityMetric) -> String {
        if metric.metricKey == "running.average_pace_s_per_km" {
            return streamValue(metric.valueNumber, metric: "pace_s_per_km", unit: metric.unitKey)
        }
        if ["speed.average_mps", "speed.maximum_mps"].contains(metric.metricKey) {
            return streamValue(metric.valueNumber, metric: "speed_mps", unit: metric.unitKey)
        }
        return metric.displayValue
    }

    static func qualityFindingTitle(_ key: String) -> String {
        switch key {
        case "impossible_speed": "Speed data"
        case "gps_spike": "GPS data"
        case "missing_route_sections": "Route coverage"
        case "heart_rate_dropout", "brief_heart_rate_dropout": "Heart-rate coverage"
        case "cadence_gap": "Cadence coverage"
        case "heart_rate_plateau", "heart_rate_spike": "Heart-rate sensor"
        case "duplicate_samples": "Repeated readings"
        case "timer_inconsistency": "Timer data"
        case "incomplete_or_disagreeing_distance": "Distance data"
        default: humanKey(key)
        }
    }

    static func analysisLimitTitle(_ key: String) -> String {
        switch key {
        case "pacing_variability": "Pace consistency"
        case "split_balance": "Split balance"
        case "start_discipline": "Start pacing"
        case "slowdown_point": "Slowdown point"
        case "finishing_strength": "Finishing strength"
        case "heart_rate_zones": "Heart-rate zones"
        case "heart_rate_drift": "Heart-rate drift"
        case "heart_rate_decoupling": "Pace-to-heart-rate drift"
        case "heart_rate_recovery": "Heart-rate recovery"
        case "pace_at_comparable_heart_rate": "Pace at comparable heart rate"
        case "heart_rate_at_comparable_pace": "Heart rate at comparable pace"
        case "route_overlap": "Route comparison"
        case "distance_aligned_overlay": "Distance-aligned comparison"
        case "cadence_analysis": "Cadence analysis"
        case "plan_adherence": "Plan execution comparison"
        default: humanKey(key)
        }
    }

    static func calculationVersion(_ value: String) -> String {
        switch value {
        case "running-load-v1": "Running-load calculation v1"
        default: humanKey(value)
        }
    }

    static func averagePaceSecondsPerKilometre(
        summaryMetrics: [FitnessActivityMetric],
        distanceMetres: Double?,
        durationSeconds: Double?
    ) -> Double? {
        let directKeys = [
            "running.average_pace_s_per_km", "pace.average_s_per_km", "pace_s_per_km",
        ]
        if let pace = summaryMetrics.first(where: { directKeys.contains($0.metricKey) })?.valueNumber,
            pace.isFinite, pace > 0
        {
            return pace
        }
        if let speed = summaryMetrics.first(where: { $0.metricKey == "speed.average_mps" })?.valueNumber,
            speed.isFinite, speed > 0
        {
            return 1_000 / speed
        }
        guard let distanceMetres, let durationSeconds,
            distanceMetres.isFinite, durationSeconds.isFinite,
            distanceMetres > 0, durationSeconds > 0
        else { return nil }
        return durationSeconds / (distanceMetres / 1_000)
    }

    static func date(_ value: String) -> String {
        guard let date = FitnessDatabase.date(value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    static func day(_ date: Date) -> String {
        ISODateParser.stringDateOnly(from: date)
    }
    static func distance(_ metres: Double) -> String {
        metres >= 1_000 ? "\((metres / 1_000).formatted(.number.precision(.fractionLength(1...2)))) km" : "\(Int(metres.rounded())) m"
    }
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    static func sportIcon(_ sport: String) -> String {
        switch sport {
        case "running": "figure.run"
        case "cycling": "bicycle"
        case "walking": "figure.walk"
        case "swimming": "figure.pool.swim"
        case "strength": "dumbbell.fill"
        default: "figure.mixed.cardio"
        }
    }
    static func metric(_ key: String) -> String {
        switch key {
        case "pace_s_per_km": "Pace"
        case "speed_mps": "Speed"
        case "heart_rate_bpm": "Heart rate"
        case "altitude_m": "Elevation"
        case "cadence_spm": "Cadence"
        case "power_w": "Power"
        case "stride_length_m": "Stride length"
        case "vertical_oscillation_mm": "Vertical oscillation"
        case "vertical_ratio_pct": "Vertical ratio"
        case "ground_contact_time_ms": "Ground contact time"
        case "ground_contact_balance_pct": "Ground contact balance"
        case "respiration_rate_bpm": "Respiration rate"
        case "temperature_c": "Temperature"
        case "stroke_rate_spm": "Stroke rate"
        default: humanKey(key)
        }
    }
    static func orderedStreamMetrics(_ keys: [String]) -> [String] {
        let order = [
            "pace_s_per_km", "speed_mps", "heart_rate_bpm", "altitude_m", "cadence_spm",
            "power_w", "stride_length_m", "vertical_oscillation_mm", "vertical_ratio_pct",
            "ground_contact_time_ms", "ground_contact_balance_pct", "respiration_rate_bpm",
            "temperature_c", "stroke_rate_spm",
        ]
        let excluded = Set(["latitude_deg", "longitude_deg", "distance_m", "elapsed_ms", "timer_ms"])
        let available = keys.filter { !excluded.contains($0) }
        return order.filter(available.contains) + available.filter { !order.contains($0) }.sorted()
    }
    static func streamValue(_ value: Double?, metric: String, unit: String?) -> String {
        guard let value, value.isFinite else { return "No reading" }
        if metric == "pace_s_per_km" {
            let totalSeconds = max(0, Int(value.rounded()))
            return String(format: "%d:%02d/km", totalSeconds / 60, totalSeconds % 60)
        }
        if metric == "speed_mps" { return String(format: "%.1f km/h", value * 3.6) }
        let precision =
            ["altitude_m", "temperature_c", "stride_length_m", "vertical_ratio_pct", "ground_contact_balance_pct"].contains(metric) ? 1 : 0
        let rendered = String(format: "%.*f", precision, value)
        let displayUnit = unit == "degC" ? "°C" : (unit ?? "")
        return displayUnit.isEmpty ? rendered : "\(rendered) \(displayUnit)"
    }
    static func chartSummary(_ points: [FitnessChartPoint], unit: String?) -> String {
        guard let minimum = points.map(\.value).min(), let maximum = points.map(\.value).max() else { return "No recorded data" }
        return "From \(minimum.formatted()) to \(maximum.formatted()) \(unit ?? "")"
    }
}

/// A route point prepared entirely from activity data already stored by HausKlar.
