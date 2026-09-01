import SwiftUI
import Charts

/// Weight-for-age and height-for-age centile charts: WHO/UK reference bands with
/// the child's own measurements overlaid, plus their latest centile.
struct GrowthCentilesSection: View {
    @ObservedObject var viewModel: HealthRecordViewModel
    @State private var showingAddMeasurement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let response = viewModel.growth {
                HealthDisclaimerBanner(text: response.disclaimer ?? HealthDisclaimer.fallback)

                Button {
                    showingAddMeasurement = true
                } label: {
                    Label("Add measurement", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSaving)

                if response.sex == nil {
                    setSexCard(note: response.note)
                } else if response.measurements.isEmpty {
                    emptyState
                } else {
                    latestCentileCard(response.measurements)

                    CentileChart(
                        title: "Weight for age",
                        unit: "kg",
                        accent: .green,
                        reference: response.weightReference,
                        childPoints: childPoints(response.measurements, metric: .weight)
                    )

                    CentileChart(
                        title: "Height for age",
                        unit: "cm",
                        accent: .blue,
                        reference: response.heightReference,
                        childPoints: childPoints(response.measurements, metric: .height)
                    )
                }
            } else if viewModel.isLoading {
                ProgressView("Loading growth data...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }
        }
        .sheet(isPresented: $showingAddMeasurement) {
            AddHealthMeasurementSheet(viewModel: viewModel)
        }
    }

    // MARK: - Sub-views

    private func setSexCard(note: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Set \(viewModel.selectedChildName)'s sex to show the correct reference centiles.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.setSex("female") }
                } label: {
                    Text("Girl").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await viewModel.setSex("male") }
                } label: {
                    Text("Boy").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(viewModel.isSaving)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No measurements yet", systemImage: "chart.xyaxis.line")
        } description: {
            Text("Add a height or weight here to begin \(viewModel.selectedChildName)'s growth record.")
        }
    }

    private func latestCentileCard(_ measurements: [GrowthCentilePointDTO]) -> some View {
        let latest = measurements.max { lhs, rhs in
            (ISODateParser.parse(lhs.date) ?? .distantPast) < (ISODateParser.parse(rhs.date) ?? .distantPast)
        }
        return Group {
            if let latest {
                HStack(spacing: 20) {
                    centileStat("Weight", value: latest.weightCentile, tint: .green)
                    Divider().frame(height: 34)
                    centileStat("Height", value: latest.heightCentile, tint: .blue)
                    Spacer()
                    if let date = ISODateParser.parse(latest.date) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Latest")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(ISODateParser.dateOnly(from: date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func centileStat(_ label: String, value: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Rendered in primary (not the accent colour) so small centile text
            // keeps sufficient contrast on a light background; the dot carries the tint.
            Text(value.map(Self.centileLabel) ?? "—")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    /// "50th", "9th", "91st" ordinal centile.
    static func centileLabel(_ centile: Double) -> String {
        let rounded = Int(centile.rounded())
        let suffix: String
        switch rounded % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch rounded % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(rounded)\(suffix)"
    }

    // MARK: - Data shaping

    private enum Metric { case weight, height }

    private func childPoints(_ measurements: [GrowthCentilePointDTO], metric: Metric) -> [ChildCentilePoint] {
        measurements.compactMap { m in
            guard let age = m.ageMonths else { return nil }
            let value = metric == .weight ? m.weightKg : m.heightCm
            guard let value else { return nil }
            let centile = metric == .weight ? m.weightCentile : m.heightCentile
            return ChildCentilePoint(id: m.date, ageMonths: age, value: value, centile: centile)
        }
        .sorted { $0.ageMonths < $1.ageMonths }
    }
}

private struct AddHealthMeasurementSheet: View {
    @ObservedObject var viewModel: HealthRecordViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var height = ""
    @State private var weight = ""
    @State private var headCircumference = ""
    @State private var notes = ""

    private var parsedHeight: Double? { Self.number(height) }
    private var parsedWeight: Double? { Self.number(weight) }
    private var parsedHeadCircumference: Double? { Self.number(headCircumference) }
    private var hasPrimaryMeasurement: Bool { parsedHeight != nil || parsedWeight != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Measured on") {
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                }

                Section {
                    measurementField("Height", unit: "cm", text: $height)
                    measurementField("Weight", unit: "kg", text: $weight)
                    measurementField("Head circumference", unit: "cm", text: $headCircumference)
                } header: {
                    Text("Measurements")
                } footer: {
                    Text("Enter at least a height or weight. Head circumference is optional.")
                }

                Section("Notes (optional)") {
                    TextField("For example, measured at home", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.addGrowthMeasurement(
                                date: date,
                                heightCm: parsedHeight,
                                weightKg: parsedWeight,
                                headCircumferenceCm: parsedHeadCircumference,
                                notes: notes
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!hasPrimaryMeasurement || viewModel.isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func measurementField(_ label: String, unit: String, text: Binding<String>) -> some View {
        HStack {
            TextField(label, text: text)
                .keyboardType(.decimalPad)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    private static func number(_ text: String) -> Double? {
        let normalised = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalised.isEmpty else { return nil }
        return Double(normalised)
    }
}

// MARK: - Chart

struct ChildCentilePoint: Identifiable {
    let id: String
    let ageMonths: Double
    let value: Double
    let centile: Double?
}

private struct ReferenceLinePoint: Identifiable {
    let id = UUID()
    let ageMonths: Double
    let value: Double
    let percentile: String
}

/// A single centile chart: light reference bands with the child's line overlaid.
private struct CentileChart: View {
    let title: String
    let unit: String
    let accent: Color
    let reference: [ReferenceCurvePointDTO]
    let childPoints: [ChildCentilePoint]

    // Ordered outer→inner so the median reads as the emphasised middle band.
    private static let percentiles: [(name: String, path: KeyPath<ReferenceCurvePointDTO, Double>)] = [
        ("2nd", \.p2), ("9th", \.p9), ("25th", \.p25), ("50th", \.p50),
        ("75th", \.p75), ("91st", \.p91), ("98th", \.p98),
    ]

    private var referenceLines: [ReferenceLinePoint] {
        reference.flatMap { point in
            Self.percentiles.map { percentile in
                ReferenceLinePoint(
                    ageMonths: Double(point.ageMonths),
                    value: point[keyPath: percentile.path],
                    percentile: percentile.name
                )
            }
        }
    }

    private var xDomain: ClosedRange<Double>? {
        let ages = reference.map { Double($0.ageMonths) }
        guard let lower = ages.min(), let upper = ages.max(), lower < upper else { return nil }
        return lower...upper
    }

    /// The most recent measurement, used for the VoiceOver trajectory summary.
    private var latestChildPoint: ChildCentilePoint? {
        childPoints.max { $0.ageMonths < $1.ageMonths }
    }

    /// A single spoken summary of the whole chart so a VoiceOver user hears the
    /// child's latest value and centile plus the overall trajectory.
    private var chartAccessibilitySummary: String {
        guard let latest = latestChildPoint else {
            return "\(title). No measurements plotted yet."
        }
        var summary = "\(title). Latest: \(pointValueDescription(latest)) at \(months(latest.ageMonths))."
        if childPoints.count > 1 {
            summary += " \(childPoints.count) measurements plotted."
        }
        return summary
    }

    private func months(_ ageMonths: Double) -> String {
        let value = Int(ageMonths.rounded())
        return "\(value) \(value == 1 ? "month" : "months")"
    }

    /// e.g. "22.0 kg, 48th centile" (centile omitted when unknown).
    private func pointValueDescription(_ point: ChildCentilePoint) -> String {
        let valueText = "\(formattedValue(point.value)) \(unit)"
        guard let centile = point.centile else { return valueText }
        return "\(valueText), \(GrowthCentilesSection.centileLabel(centile)) centile"
    }

    private func formattedValue(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            chart
                .frame(height: 240)

            HStack(spacing: 14) {
                Label("Reference centiles", systemImage: "minus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(title, systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(accent)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var chart: some View {
        let base = Chart {
            // Reference bands are visual context only — hidden from assistive tech
            // so a VoiceOver user hears the child's own measurements, not 7×N lines.
            ForEach(referenceLines) { point in
                LineMark(
                    x: .value("Age (months)", point.ageMonths),
                    y: .value(unit, point.value),
                    series: .value("Band", point.percentile)
                )
                .foregroundStyle(.gray.opacity(point.percentile == "50th" ? 0.55 : 0.28))
                .lineStyle(StrokeStyle(lineWidth: point.percentile == "50th" ? 1.3 : 0.7))
                .interpolationMethod(.catmullRom)
                .accessibilityHidden(true)
            }

            ForEach(childPoints) { point in
                LineMark(
                    x: .value("Age (months)", point.ageMonths),
                    y: .value(unit, point.value),
                    series: .value("Band", "child")
                )
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
                .accessibilityHidden(true)

                PointMark(
                    x: .value("Age (months)", point.ageMonths),
                    y: .value(unit, point.value)
                )
                .foregroundStyle(accent)
                .symbolSize(60)
                .accessibilityLabel(months(point.ageMonths))
                .accessibilityValue(pointValueDescription(point))
            }
        }
        .chartXAxisLabel("Age (months)")
        .chartYAxisLabel(unit)
        .accessibilityLabel(chartAccessibilitySummary)

        if let xDomain {
            base.chartXScale(domain: xDomain)
        } else {
            base
        }
    }
}
