import Charts
import SwiftUI

private struct FitnessBodyTrendReading: Identifiable {
    let id: String
    let measuredAt: Date
    let value: Double
    let unitKey: String
}

struct FitnessBodyMeasurementsView: View {
    @StateObject private var viewModel = FitnessBodyMeasurementsViewModel()
    @State private var editor: FitnessBodyMeasurementEditorContext?
    @State private var orderedMeasurements: [FitnessBodyMeasurement] = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        List {
            if !viewModel.measurements.isEmpty {
                Section {
                    currentMeasurements
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                Section("Trends") {
                    measurementTrend(
                        title: "Weight",
                        measurements: weightMeasurements,
                        emptyMessage: "Add a weight reading to start this graph."
                    )
                    measurementTrend(
                        title: "Body fat",
                        measurements: bodyFatMeasurements,
                        emptyMessage: "Add a body-fat reading to start this graph."
                    )
                    measurementTrend(
                        title: "BMI",
                        measurements: bmiMeasurements,
                        emptyMessage: "Add your height once to calculate BMI from your weight readings.",
                        changeUnit: "points"
                    )
                }
            }
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await viewModel.load() } }
                        .disabled(viewModel.isLoading)
                }
            }
            if viewModel.measurements.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("No body measurements", systemImage: "ruler")
                } description: {
                    Text("Record weight, height, circumferences, body-fat percentage, or your own named measurement.")
                } actions: {
                    Button("Add measurement", systemImage: "plus") {
                        editor = .init(measurement: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if !viewModel.measurements.isEmpty {
                Section("Recorded measurements") {
                    ForEach(recordedMeasurements) { measurement in
                        measurementRow(measurement)
                    }
                }
            }
        }
        .navigationTitle("Body measurements")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = .init(measurement: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add body measurement")
            }
        }
        .overlay { if viewModel.isLoading && viewModel.measurements.isEmpty { ProgressView() } }
        .sheet(item: $editor) { context in
            FitnessBodyMeasurementEditor(viewModel: viewModel, context: context)
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .onChange(of: viewModel.measurements, initial: true) { _, measurements in
            orderedMeasurements = measurements.sorted { $0.measuredAt < $1.measuredAt }
        }
    }

    private var recordedMeasurements: [FitnessBodyMeasurement] {
        Array(orderedMeasurements.reversed())
    }

    private var weightMeasurements: [FitnessBodyTrendReading] {
        trendMeasurements(for: ["body.weight_kg"])
    }

    private var bodyFatMeasurements: [FitnessBodyTrendReading] {
        trendMeasurements(for: ["body.body_fat_pct", "body.body_fat_percent"])
    }

    private var bmiMeasurements: [FitnessBodyTrendReading] {
        let heights = orderedMeasurements
            .filter { ["body.height_cm", "body.height_m"].contains($0.metricKey) && $0.isCanonical }
            .compactMap { measurement -> (date: Date, metres: Double)? in
                let unit = measurement.unitKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let metres =
                    measurement.metricKey == "body.height_m" || ["m", "metre", "metres"].contains(unit)
                    ? measurement.value
                    : measurement.value / 100
                return metres.isFinite && metres > 0 ? (measurement.measuredAt, metres) : nil
            }
        guard let firstHeight = heights.first else { return [] }
        return weightMeasurements.compactMap { weight in
            let height = heights.last(where: { $0.date <= weight.measuredAt }) ?? firstHeight
            let bmi = weight.value / (height.metres * height.metres)
            guard bmi.isFinite else { return nil }
            return FitnessBodyTrendReading(
                id: "bmi-\(weight.id)", measuredAt: weight.measuredAt, value: bmi, unitKey: ""
            )
        }
    }

    @ViewBuilder private var currentMeasurements: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 12) {
                currentMeasurementCard(title: "Current weight", measurements: weightMeasurements)
                currentMeasurementCard(title: "Current body fat", measurements: bodyFatMeasurements)
                currentMeasurementCard(
                    title: "Current BMI", measurements: bmiMeasurements,
                    emptyMessage: "Add your height to calculate BMI", changeUnit: "points"
                )
            }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    currentMeasurementCard(title: "Current weight", measurements: weightMeasurements)
                    currentMeasurementCard(title: "Current body fat", measurements: bodyFatMeasurements)
                }
                currentMeasurementCard(
                    title: "Current BMI", measurements: bmiMeasurements,
                    emptyMessage: "Add your height to calculate BMI", changeUnit: "points"
                )
            }
        }
    }

    private func trendMeasurements(for metricKeys: Set<String>) -> [FitnessBodyTrendReading] {
        Array(
            orderedMeasurements
                .filter { metricKeys.contains($0.metricKey) && $0.isCanonical }
                .suffix(30)
                .map {
                    FitnessBodyTrendReading(
                        id: $0.id, measuredAt: $0.measuredAt, value: $0.value, unitKey: $0.unitKey
                    )
                }
        )
    }

    private func currentMeasurementCard(
        title: String,
        measurements: [FitnessBodyTrendReading],
        emptyMessage: String = "No reading yet",
        changeUnit: String? = nil
    ) -> some View {
        let latest = measurements.last
        return VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let latest {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(measurementValue(latest.value))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                    if !latest.unitKey.isEmpty {
                        Text(latest.unitKey)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(weeklyChange(measurements, changeUnit: changeUnit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("—").font(.system(size: 34, weight: .bold, design: .rounded))
                Text(emptyMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func measurementTrend(
        title: String,
        measurements: [FitnessBodyTrendReading],
        emptyMessage: String,
        changeUnit: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if measurements.isEmpty {
                Label(emptyMessage, systemImage: "chart.xyaxis.line")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            } else {
                Chart(measurements) { measurement in
                    LineMark(
                        x: .value("Date", measurement.measuredAt),
                        y: .value(title, measurement.value)
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                    PointMark(
                        x: .value("Date", measurement.measuredAt),
                        y: .value(title, measurement.value)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(24)
                }
                .chartYScale(domain: measurementDomain(measurements))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .frame(height: 176)
                .accessibilityLabel("\(title) trend")
                .accessibilityValue(trendSummary(measurements, changeUnit: changeUnit))
            }
        }
        .padding(.vertical, 4)
    }

    private func weeklyChange(_ measurements: [FitnessBodyTrendReading], changeUnit: String? = nil) -> String {
        guard let latest = measurements.last,
            let target = Calendar.current.date(byAdding: .day, value: -7, to: latest.measuredAt),
            let reference = measurements.last(where: { $0.measuredAt <= target })
        else {
            return "Add a week of readings to see the weekly change"
        }
        let change = latest.value - reference.value
        if abs(change) < 0.05 { return "No change from a week ago" }
        let unit = changeUnit ?? (latest.unitKey == "%" ? "points" : latest.unitKey)
        let amount = [measurementValue(abs(change)), unit].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(amount) \(change > 0 ? "higher" : "lower") than a week ago"
    }

    private func trendSummary(_ measurements: [FitnessBodyTrendReading], changeUnit: String? = nil) -> String {
        guard let latest = measurements.last else { return "No readings yet" }
        guard let first = measurements.first, first.id != latest.id else {
            return readingValue(latest)
        }
        let change = latest.value - first.value
        if abs(change) < 0.05 {
            return "\(readingValue(latest)), unchanged across the readings shown"
        }
        let unit = changeUnit ?? latest.unitKey
        let amount = [measurementValue(abs(change)), unit].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(readingValue(latest)), \(amount) \(change > 0 ? "higher" : "lower") across the readings shown"
    }

    private func measurementDomain(_ measurements: [FitnessBodyTrendReading]) -> ClosedRange<Double> {
        let values = measurements.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.2, 0.5)
        return (low - padding)...(high + padding)
    }

    private func measurementValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func readingValue(_ measurement: FitnessBodyTrendReading) -> String {
        [measurementValue(measurement.value), measurement.unitKey]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    @ViewBuilder
    private func measurementRow(_ measurement: FitnessBodyMeasurement) -> some View {
        let content = HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(FitnessBodyMetricPreset.title(for: measurement.metricKey))
                    .font(.subheadline.weight(.semibold))
                Text(measurement.measuredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                if let notes = measurement.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text("\(measurement.value.formatted(.number.precision(.fractionLength(0...2)))) \(measurement.unitKey)")
                .font(.headline.monospacedDigit())
        }
        if measurement.source == .manual {
            Button {
                editor = .init(measurement: measurement)
            } label: {
                content
            }
            .foregroundStyle(.primary)
            .accessibilityHint("Edits this manual measurement")
        } else {
            content
        }
    }
}

struct FitnessBodyMeasurementEditorContext: Identifiable {
    let id = UUID()
    let measurement: FitnessBodyMeasurement?
}

struct FitnessBodyMetricPreset: Identifiable, Hashable {
    let key: String
    let title: String
    let unit: String
    var id: String { key }

    static let values = [
        Self(key: "body.weight_kg", title: "Weight", unit: "kg"),
        Self(key: "body.height_cm", title: "Height", unit: "cm"),
        Self(key: "body.waist_cm", title: "Waist", unit: "cm"),
        Self(key: "body.hips_cm", title: "Hips", unit: "cm"),
        Self(key: "body.chest_cm", title: "Chest", unit: "cm"),
        Self(key: "body.upper_arm_cm", title: "Upper arm", unit: "cm"),
        Self(key: "body.thigh_cm", title: "Thigh", unit: "cm"),
        Self(key: "body.body_fat_pct", title: "Body fat", unit: "%"),
    ]

    static func title(for key: String) -> String {
        if key == "body.body_fat_percent" { return "Body fat" }
        if key == "body.height_m" { return "Height" }
        return values.first { $0.key == key }?.title
            ?? key.replacingOccurrences(of: "body.", with: "")
            .replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func selectionKey(for key: String) -> String? {
        if key == "body.body_fat_percent" { return "body.body_fat_pct" }
        return values.first { $0.key == key }?.key
    }
}

struct FitnessBodyMeasurementEditor: View {
    @ObservedObject var viewModel: FitnessBodyMeasurementsViewModel
    let context: FitnessBodyMeasurementEditorContext
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String
    @State private var customName: String
    @State private var value: String
    @State private var unit: String
    @State private var measuredAt: Date
    @State private var quality: String
    @State private var notes: String

    init(viewModel: FitnessBodyMeasurementsViewModel, context: FitnessBodyMeasurementEditorContext) {
        self.viewModel = viewModel
        self.context = context
        let existing = context.measurement
        let known = existing.flatMap { item in
            FitnessBodyMetricPreset.selectionKey(for: item.metricKey)
        }
        _selection = State(initialValue: known ?? (existing == nil ? "body.weight_kg" : "custom"))
        _customName = State(initialValue: existing.map { FitnessBodyMetricPreset.title(for: $0.metricKey) } ?? "")
        _value = State(initialValue: existing.map { String(format: "%g", $0.value) } ?? "")
        _unit = State(initialValue: existing?.unitKey ?? "kg")
        _measuredAt = State(initialValue: existing?.measuredAt ?? Date())
        _quality = State(initialValue: existing?.measurementQuality ?? "measured")
        _notes = State(initialValue: existing?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Measurement") {
                    Picker("Type", selection: $selection) {
                        ForEach(FitnessBodyMetricPreset.values) { preset in Text(preset.title).tag(preset.key) }
                        Text("Custom…").tag("custom")
                    }
                    .onChange(of: selection) { _, newValue in
                        if let preset = FitnessBodyMetricPreset.values.first(where: { $0.key == newValue }) {
                            unit = preset.unit
                        }
                    }
                    if selection == "custom" {
                        TextField("Measurement name", text: $customName)
                    }
                    HStack {
                        TextField("Value", text: $value).keyboardType(.decimalPad)
                        TextField("Unit", text: $unit).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    DatePicker("Measured", selection: $measuredAt)
                    Picker("Quality", selection: $quality) {
                        Text("Measured").tag("measured")
                        Text("Estimated").tag("estimated")
                    }
                    TextField("Capture notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Text("Manual measurements remain editable. Measurements added automatically are read-only here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = viewModel.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(context.measurement == nil ? "Add measurement" : "Edit measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!isValid || viewModel.isLoading)
                }
            }
        }
    }

    private var metricKey: String {
        guard selection == "custom" else { return selection }
        let slug = customName.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "_")
        return "body.\(slug)"
    }
    private var isValid: Bool {
        guard let number = Double(value), number.isFinite, number > 0 else { return false }
        return metricKey.count > 5 && !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func save() async {
        guard let number = Double(value) else { return }
        if await viewModel.save(
            existing: context.measurement, metricKey: metricKey, value: number,
            unitKey: unit, notes: FitnessNutritionViewFormatting.emptyNil(notes), measuredAt: measuredAt, quality: quality
        ) {
            dismiss()
        }
    }
}
