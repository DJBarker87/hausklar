import SwiftUI

/// The "show the GP your phone" view: a plain-language report plus a structured
/// timeline of illnesses, temperatures and medicine doses, ready to share.
struct GPSummarySection: View {
    @ObservedObject var viewModel: HealthRecordViewModel

    private let rangeOptions: [(label: String, days: Int)] = [
        ("30 days", 30), ("90 days", 90), ("6 months", 180), ("12 months", 365),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            rangePicker

            if let response = viewModel.summary {
                HealthDisclaimerBanner(text: response.disclaimer ?? HealthDisclaimer.fallback)

                reportCard(response)

                if !response.illnesses.isEmpty {
                    timelineCard(
                        title: "Illnesses",
                        icon: "bandage.fill",
                        tint: .red
                    ) {
                        ForEach(response.illnesses) { illness in
                            illnessRow(illness)
                        }
                    }
                }

                if !response.temperatures.isEmpty {
                    timelineCard(
                        title: "Temperatures",
                        icon: "thermometer.medium",
                        tint: .orange
                    ) {
                        ForEach(response.temperatures) { temp in
                            timelineRow(
                                date: temp.recordedAt,
                                primary: String(format: "%.1f°C", temp.valueCelsius),
                                secondary: nil
                            )
                        }
                    }
                }

                if !response.medicineDoses.isEmpty {
                    timelineCard(
                        title: "Medicine",
                        icon: "cross.case.fill",
                        tint: .blue
                    ) {
                        ForEach(response.medicineDoses) { dose in
                            timelineRow(
                                date: dose.givenAt,
                                primary: dose.name,
                                secondary: dose.doseAmount
                            )
                        }
                    }
                }

                if response.illnesses.isEmpty, response.temperatures.isEmpty, response.medicineDoses.isEmpty {
                    ContentUnavailableView(
                        "Nothing recorded",
                        systemImage: "checkmark.seal",
                        description: Text("No illnesses, temperatures or medicine in this window.")
                    )
                }
            } else if viewModel.isLoading {
                ProgressView("Preparing summary...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }
        }
    }

    // MARK: - Sub-views

    private var rangePicker: some View {
        Picker("Period", selection: Binding(
            get: { selectedDays },
            set: { newDays in
                viewModel.summarySince = Calendar.current.date(byAdding: .day, value: -newDays, to: Date()) ?? Date()
                Task { await viewModel.loadSummary() }
            }
        )) {
            ForEach(rangeOptions, id: \.days) { option in
                Text(option.label).tag(option.days)
            }
        }
        .pickerStyle(.segmented)
    }

    private var selectedDays: Int {
        let days = Calendar.current.dateComponents([.day], from: viewModel.summarySince, to: Date()).day ?? 90
        // Snap to the nearest configured option.
        return rangeOptions.min { abs($0.days - days) < abs($1.days - days) }?.days ?? 90
    }

    private func reportCard(_ response: SummaryResponseDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Summary", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                ShareLink(item: shareText(response)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                }
            }

            Text(response.report)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(periodLabel(response))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func timelineCard<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func illnessRow(_ illness: SummaryIllnessDTO) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(dateRange(illness.startedAt, illness.endedAt))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if illness.endedAt == nil {
                    Text("Ongoing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            if let notes = illness.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timelineRow(date: String, primary: String, secondary: String?) -> some View {
        HStack(spacing: 10) {
            Text(dateTimeLabel(date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(primary)
                .font(.caption.weight(.medium))
            if let secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Formatting

    private func periodLabel(_ response: SummaryResponseDTO) -> String {
        let since = ISODateParser.parse(response.since).map(ISODateParser.dateOnly) ?? response.since
        let until = ISODateParser.parse(response.until).map(ISODateParser.dateOnly) ?? response.until
        return "Covering \(since) to \(until)"
    }

    private func dateTimeLabel(_ iso: String) -> String {
        guard let date = ISODateParser.parse(iso) else { return iso }
        return ISODateParser.dateTime(from: date)
    }

    private func dateRange(_ start: String, _ end: String?) -> String {
        let startLabel = ISODateParser.parse(start).map(ISODateParser.dateOnly) ?? start
        guard let end, let endDate = ISODateParser.parse(end) else { return startLabel }
        return "\(startLabel) – \(ISODateParser.dateOnly(from: endDate))"
    }

    /// The full plain-text report plus a header, suitable for sharing to a GP.
    private func shareText(_ response: SummaryResponseDTO) -> String {
        var lines = ["Health summary for \(response.childName ?? viewModel.selectedChildName)"]
        lines.append(periodLabel(response))
        lines.append("")
        lines.append(response.report)
        lines.append("")
        lines.append(response.disclaimer ?? HealthDisclaimer.fallback)
        return lines.joined(separator: "\n")
    }
}
