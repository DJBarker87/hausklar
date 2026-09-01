import SwiftUI
import Charts

/// Time-series chart for any HA entity.
/// For climate entities: shows current + target temperature lines.
/// For temperature sensors: shows temperature + humidity + outdoor.
/// For numeric sensors (battery, power, energy, humidity): shows value chart.
/// For binary sensors (on/off): shows a step timeline.
/// Fetches data from the dashboard config-api history endpoint.
struct HistoryChartView: View {
    let entityId: String
    let isClimate: Bool

    /// Initialiser for non-climate/temperature entities (generic usage).
    init(entityId: String) {
        self.entityId = entityId
        // Auto-detect climate entities
        self.isClimate = entityId.hasPrefix("climate.")
    }

    /// Explicit initialiser preserving backward compatibility.
    init(entityId: String, isClimate: Bool) {
        self.entityId = entityId
        self.isClimate = isClimate
    }

    @State private var readings: [HAClient.HistoryReading] = []
    @State private var humidityReadings: [HAClient.HistoryReading] = []
    @State private var weatherReadings: [HAClient.HistoryReading] = []
    @State private var loading = true
    @State private var selectedHours = 24
    @State private var trackedDate: Date?

    private static let rangeOptions = [
        (label: "6H", hours: 6),
        (label: "24H", hours: 24),
        (label: "7D", hours: 168),
        (label: "30D", hours: 720),
    ]

    private static let green = Color.hackerGreen
    private static let orange = Color.hackerOrange
    private static let cyan = Color.hackerCyan
    private static let grey = Color.hackerGrey
    private static let blue = Color(red: 0.39, green: 0.58, blue: 0.93) // cornflower blue

    // MARK: - Entity type detection

    /// Whether the entity is a binary (on/off) type — binary_sensor, switch, light, etc.
    private var isBinaryEntity: Bool {
        let domain = String(entityId.prefix(while: { $0 != "." }))
        return ["binary_sensor", "switch", "light"].contains(domain)
    }

    /// Whether this is a temperature sensor (non-climate).
    private var isTemperatureSensor: Bool {
        !isClimate && entityId.contains("_temperature")
    }

    // MARK: - Parsed data

    private struct DataPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let series: String
    }

    private var dataPoints: [DataPoint] {
        var points: [DataPoint] = []

        if isBinaryEntity {
            // Binary entities: map on=1, off=0
            for r in readings {
                let v: Double = r.state == "on" ? 1.0 : 0.0
                points.append(DataPoint(date: r.date, value: v, series: "State"))
            }
        } else if isClimate {
            for r in readings {
                if let cur = r.attrDouble("current_temperature") {
                    points.append(DataPoint(date: r.date, value: cur, series: "Current"))
                }
                if let tgt = r.attrDouble("temperature") {
                    points.append(DataPoint(date: r.date, value: tgt, series: "Target"))
                }
            }
        } else if isTemperatureSensor {
            for r in readings {
                if let v = Double(r.state) {
                    points.append(DataPoint(date: r.date, value: v, series: "Temp"))
                }
            }
        } else {
            // Generic numeric sensor
            for r in readings {
                if let v = Double(r.state) {
                    points.append(DataPoint(date: r.date, value: v, series: "Value"))
                }
            }
        }

        for r in humidityReadings {
            if let v = Double(r.state) {
                points.append(DataPoint(date: r.date, value: v, series: "Humidity"))
            }
        }

        for r in weatherReadings {
            if let v = r.attrDouble("temperature") {
                points.append(DataPoint(date: r.date, value: v, series: "Outdoor"))
            }
        }

        return points
    }

    private func stats(for series: String) -> (min: Double, max: Double, avg: Double)? {
        let vals = dataPoints.filter { $0.series == series }.map(\.value)
        guard let minimum = vals.min(), let maximum = vals.max() else { return nil }
        let sum = vals.reduce(0, +)
        return (min: minimum, max: maximum, avg: sum / Double(vals.count))
    }

    /// Find the nearest data point to a given date for a specific series.
    private func nearestPoint(to date: Date, series: String) -> DataPoint? {
        let seriesPoints = dataPoints.filter { $0.series == series }
        guard !seriesPoints.isEmpty else { return nil }
        return seriesPoints.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    /// All unique series names present in the current data.
    private var activeSeries: [String] {
        Array(Set(dataPoints.map(\.series))).sorted()
    }

    /// Color for a given series name.
    private func seriesColor(_ series: String) -> Color {
        switch series {
        case "Target": return Self.orange
        case "Humidity": return Self.cyan
        case "Outdoor": return Self.blue
        case "State": return Self.green
        default: return Self.green
        }
    }

    /// Format a traced value for display.
    private func formatTracedValue(_ value: Double, series: String) -> String {
        switch series {
        case "State": return value >= 0.5 ? "ON" : "OFF"
        case "Humidity": return "\(String(format: "%.1f", value))%"
        case "Outdoor", "Current", "Target", "Temp":
            return "\(String(format: "%.1f", value))\u{00B0}"
        default: return "\(String(format: "%.1f", value))\(unitSuffix)"
        }
    }

    /// Determine the unit suffix for display based on entity ID.
    private var unitSuffix: String {
        if entityId.contains("temperature") { return "\u{00B0}" }
        if entityId.contains("humidity") { return "%" }
        if entityId.contains("battery") { return "%" }
        if entityId.contains("power") { return "W" }
        if entityId.contains("energy") { return "kWh" }
        return ""
    }

    var body: some View {
        VStack(spacing: 12) {
            // Range picker
            HStack(spacing: 0) {
                ForEach(Self.rangeOptions, id: \.hours) { opt in
                    Button {
                        selectedHours = opt.hours
                        Task { await fetchData() }
                    } label: {
                        Text(opt.label)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(selectedHours == opt.hours ? Self.green : Self.grey)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if selectedHours == opt.hours {
                                    Rectangle()
                                        .fill(Self.green)
                                        .frame(height: 2)
                                }
                            }
                    }
                }
            }

            if loading {
                Text("LOADING...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .padding(.vertical, 24)
            } else if dataPoints.isEmpty {
                Text("NO DATA")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .padding(.vertical, 24)
            } else {
                if isBinaryEntity {
                    binaryChartView
                    binaryStatsView
                } else {
                    chartView
                    statsView
                }
            }
        }
        .task {
            await fetchData()
        }
    }

    // MARK: - Trace Tooltip

    @ViewBuilder
    private var traceTooltip: some View {
        if let date = trackedDate {
            let series = activeSeries
            let nearest = series.compactMap { s -> (String, DataPoint)? in
                guard let p = nearestPoint(to: date, series: s) else { return nil }
                return (s, p)
            }

            if !nearest.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(traceTimeLabel(date))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))

                    ForEach(nearest, id: \.0) { seriesName, point in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(seriesColor(seriesName))
                                .frame(width: 5, height: 5)
                            Text("\(seriesName.uppercased()) \(formatTracedValue(point.value, series: seriesName))")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(seriesColor(seriesName))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Self.green.opacity(0.3), lineWidth: 0.5))
            }
        }
    }

    private func traceTimeLabel(_ date: Date) -> String {
        if selectedHours <= 24 {
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())
        }
    }

    // MARK: - Drag Gesture Overlay

    private func traceGesture(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard let plotFrame = proxy.plotFrame else { return }
                let origin = geometry[plotFrame].origin
                let x = drag.location.x - origin.x
                if let date: Date = proxy.value(atX: x) {
                    trackedDate = date
                }
            }
            .onEnded { _ in
                trackedDate = nil
            }
    }

    // MARK: - Trace Rule + Points (added to chart content)

    @ChartContentBuilder
    private func traceMarks(series: [String]) -> some ChartContent {
        if let date = trackedDate {
            RuleMark(x: .value("Trace", date))
                .foregroundStyle(Self.green.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            ForEach(series, id: \.self) { seriesName in
                if let point = nearestPoint(to: date, series: seriesName) {
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(seriesColor(seriesName))
                    .symbolSize(40)
                }
            }
        }
    }

    // MARK: - Binary Chart (step timeline)

    @ViewBuilder
    private var binaryChartView: some View {
        Chart {
            ForEach(dataPoints.filter { $0.series == "State" }) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("State", point.value)
                )
                .foregroundStyle(Self.green.opacity(0.15))
                .interpolationMethod(.stepEnd)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("State", point.value)
                )
                .foregroundStyle(Self.green)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.stepEnd)
            }

            traceMarks(series: ["State"])
        }
        .chartYScale(domain: -0.1...1.1)
        .chartYAxis {
            AxisMarks(values: [0, 1]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Self.green.opacity(0.1))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v >= 0.5 ? "ON" : "OFF")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(v >= 0.5 ? Self.green : Self.grey)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Self.green.opacity(0.08))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(for: date))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Self.grey)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(traceGesture(proxy: proxy, geometry: geometry))
            }
        }
        .chartPlotStyle { content in
            content.frame(height: 100)
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .topLeading) {
            traceTooltip
                .padding(.leading, 8)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var binaryStatsView: some View {
        let statePoints = dataPoints.filter { $0.series == "State" }
        let onCount = statePoints.filter { $0.value >= 0.5 }.count
        let total = statePoints.count
        let onPercent = total > 0 ? Double(onCount) / Double(total) * 100 : 0

        HStack {
            statLabel("ON", value: "\(Int(onPercent))%", color: Self.green)
            Spacer()
            statLabel("CHANGES", value: "\(countStateChanges())", color: Self.cyan)
            Spacer()
            statLabel("OFF", value: "\(Int(100 - onPercent))%", color: Self.grey)
        }
    }

    /// Count the number of state transitions in the binary data.
    private func countStateChanges() -> Int {
        let states = dataPoints.filter { $0.series == "State" }.map(\.value)
        guard states.count > 1 else { return 0 }
        var changes = 0
        for i in 1..<states.count {
            if states[i] != states[i-1] { changes += 1 }
        }
        return changes
    }

    // MARK: - Numeric Chart (existing)

    @ViewBuilder
    private var chartView: some View {
        let series = activeSeries.filter { $0 != "State" }

        Chart {
            ForEach(dataPoints) { point in
                if point.series == "Humidity" {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Humidity", point.value),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(Self.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                } else if point.series == "Target" {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Temp", point.value),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(Self.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .interpolationMethod(.stepEnd)
                } else if point.series == "Outdoor" {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Temp", point.value),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(Self.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
                    .interpolationMethod(.monotone)
                } else {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(Self.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
            }

            traceMarks(series: series)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Self.green.opacity(0.1))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.0f", v))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Self.green.opacity(0.6))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Self.green.opacity(0.08))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(for: date))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Self.grey)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(traceGesture(proxy: proxy, geometry: geometry))
            }
        }
        .chartPlotStyle { content in
            content.frame(height: 160)
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .topLeading) {
            traceTooltip
                .padding(.leading, 8)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var statsView: some View {
        // Determine primary series name
        let primarySeries: String = {
            if isClimate { return "Current" }
            if isTemperatureSensor { return "Temp" }
            return "Value"
        }()

        let suffix = unitSuffix

        if let s = stats(for: primarySeries) {
            HStack {
                statLabel("MIN", value: formatStat(s.min, suffix: suffix), color: Self.green)
                Spacer()
                statLabel("AVG", value: formatStat(s.avg, suffix: suffix), color: Self.green)
                Spacer()
                statLabel("MAX", value: formatStat(s.max, suffix: suffix), color: Self.green)
            }
        }

        if isClimate, let s = stats(for: "Target") {
            HStack {
                Spacer()
                Text("TARGET \(String(format: "%.1f", s.min))\u{00B0} \u{2013} \(String(format: "%.1f", s.max))\u{00B0}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Self.orange.opacity(0.7))
                Spacer()
            }
        }

        if let s = stats(for: "Outdoor") {
            HStack {
                Spacer()
                Text("OUTDOOR \(String(format: "%.1f", s.min))\u{00B0} \u{2013} \(String(format: "%.1f", s.max))\u{00B0}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Self.blue.opacity(0.7))
                Spacer()
            }
        }

        if let s = stats(for: "Humidity") {
            HStack {
                statLabel("MIN", value: "\(String(format: "%.0f", s.min))%", color: Self.cyan)
                Spacer()
                statLabel("AVG", value: "\(String(format: "%.0f", s.avg))%", color: Self.cyan)
                Spacer()
                statLabel("MAX", value: "\(String(format: "%.0f", s.max))%", color: Self.cyan)
            }
        }
    }

    private func formatStat(_ value: Double, suffix: String) -> String {
        if suffix == "%" || suffix == "W" || suffix == "kWh" {
            return "\(String(format: "%.1f", value))\(suffix)"
        }
        return "\(String(format: "%.1f", value))\(suffix)"
    }

    private func statLabel(_ label: String, value: String, color: Color) -> some View {
        Text("\(label) \(value)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(color.opacity(0.7))
    }

    private func axisLabel(for date: Date) -> String {
        if selectedHours <= 24 {
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private func fetchData() async {
        loading = true

        async let mainData = HAClient.shared.fetchHistory(entityId: entityId, hours: selectedHours)

        // Only fetch weather data for climate/temperature entities
        let shouldFetchWeather = isClimate || isTemperatureSensor
        async let weatherData: [HAClient.HistoryReading] = {
            if shouldFetchWeather {
                return await HAClient.shared.fetchHistory(entityId: "weather.forecast_home", hours: selectedHours)
            }
            return []
        }()

        // For temperature sensors, also fetch humidity
        let humidityEntityId: String? = {
            guard isTemperatureSensor else { return nil }
            return entityId.replacingOccurrences(of: "_temperature", with: "_humidity")
        }()

        async let humData: [HAClient.HistoryReading] = {
            if let hid = humidityEntityId {
                return await HAClient.shared.fetchHistory(entityId: hid, hours: selectedHours)
            }
            return []
        }()

        readings = await mainData
        humidityReadings = await humData
        weatherReadings = await weatherData
        loading = false
    }
}
