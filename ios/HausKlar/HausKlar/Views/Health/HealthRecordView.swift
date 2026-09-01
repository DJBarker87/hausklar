import SwiftUI

/// A single, calm record for one child. Current state comes first; detailed
/// records remain grouped beneath it instead of becoming separate destinations.
struct HealthRecordView: View {
    @StateObject private var viewModel: HealthRecordViewModel
    @State private var growthExpanded = true
    @State private var vaccinationsExpanded = false
    @State private var summaryExpanded = false
    @State private var illnessesExpanded = false
    @State private var didInitialLoad = false
    private let initialVaccinationKey: String?

    init(initialChildId: String? = nil, initialVaccinationKey: String? = nil) {
        _viewModel = StateObject(wrappedValue: HealthRecordViewModel(initialChildId: initialChildId))
        self.initialVaccinationKey = initialVaccinationKey
        _growthExpanded = State(initialValue: initialVaccinationKey == nil)
        _vaccinationsExpanded = State(initialValue: initialVaccinationKey != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.childrenLoaded && viewModel.children.isEmpty {
                    noChildrenState
                } else {
                    ChildSelectorChips(
                        children: viewModel.children,
                        selectedChildId: $viewModel.selectedChildId,
                        nameKeyPath: \.name
                    ) { _ in
                        Task { await viewModel.childChanged() }
                    }

                    if let error = viewModel.errorMessage {
                        HealthErrorBanner(message: error) { viewModel.errorMessage = nil }
                    }

                    currentStateCard

                    recordGroup(
                        title: "Growth",
                        icon: "chart.xyaxis.line",
                        summary: growthGroupSummary,
                        isExpanded: $growthExpanded
                    ) {
                        GrowthCentilesSection(viewModel: viewModel)
                    }

                    recordGroup(
                        title: "Vaccinations",
                        icon: "syringe.fill",
                        summary: vaccinationGroupSummary,
                        isExpanded: $vaccinationsExpanded
                    ) {
                        VaccinationsSection(viewModel: viewModel, initialVaccinationKey: initialVaccinationKey)
                    }

                    recordGroup(
                        title: "GP handover",
                        icon: "stethoscope",
                        summary: "A shareable summary of this record",
                        isExpanded: $summaryExpanded
                    ) {
                        GPSummarySection(viewModel: viewModel)
                    }

                    recordGroup(
                        title: "Illness history",
                        icon: "heart.text.clipboard",
                        summary: illnessGroupSummary,
                        isExpanded: $illnessesExpanded
                    ) {
                        IllnessHistorySection(viewModel: viewModel)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(viewModel.selectedChildName == "your child" ? "Health" : viewModel.selectedChildName)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadChildren()
            await viewModel.loadRecord()
            didInitialLoad = true
        }
        .onAppear {
            guard didInitialLoad else { return }
            Task { await viewModel.loadRecord() }
        }
        .refreshable {
            await viewModel.loadRecord()
        }
    }

    private var noChildrenState: some View {
        ContentUnavailableView {
            Label("No children yet", systemImage: "person.example_35fbacff.circle.badge.plus")
        } description: {
            Text("Add a child in HausKlar to keep their health record.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Current state

    private var currentStateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Current state")
                    .font(.headline)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let illness = viewModel.activeIllness {
                NavigationLink {
                    IllnessDetailView(
                        initialChildId: viewModel.selectedChildId,
                        illnessId: illness.id
                    )
                } label: {
                    currentStateRow(
                        icon: "thermometer.high",
                        color: .orange,
                        title: illness.notes.flatMap { $0.isEmpty ? nil : $0 } ?? "Current illness",
                        detail: "Began \(HealthRecordView.dateText(illness.startedAt))",
                        showsDisclosure: true
                    )
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 12) {
                    currentStateRow(
                        icon: "heart.fill",
                        color: .green,
                        title: "No current illness",
                        detail: "Nothing open in the illness record",
                        showsDisclosure: false
                    )
                    Spacer(minLength: 4)
                    NavigationLink {
                        IllnessDetailView(initialChildId: viewModel.selectedChildId)
                    } label: {
                        Text("Open")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                currentStateRow(
                    icon: "ruler",
                    color: .blue,
                    title: "Latest growth",
                    detail: latestGrowthText,
                    showsDisclosure: false
                )
                Spacer()
            }

            Divider()

            HStack(spacing: 12) {
                currentStateRow(
                    icon: "syringe.fill",
                    color: .teal,
                    title: "Vaccinations",
                    detail: vaccinationCurrentText,
                    showsDisclosure: false
                )
                Spacer()
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func currentStateRow(
        icon: String,
        color: Color,
        title: String,
        detail: String,
        showsDisclosure: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var latestGrowthText: String {
        guard let measurement = viewModel.latestMeasurement else { return "No measurements yet" }
        var values: [String] = []
        if let height = measurement.heightCm { values.append("\(Self.decimal(height)) cm") }
        if let weight = measurement.weightKg { values.append("\(Self.decimal(weight)) kg") }
        let joined = values.isEmpty ? "Measurement" : values.joined(separator: " · ")
        return "\(joined), \(Self.dateText(measurement.date))"
    }

    private var vaccinationCurrentText: String {
        guard viewModel.vaccinations != nil else { return "Loading record" }
        let count = viewModel.vaccinationReviewCount
        if count == 0 { return "No routine records need checking" }
        return count == 1 ? "1 routine record to check" : "\(count) routine records to check"
    }

    private var growthGroupSummary: String {
        let count = viewModel.growth?.measurements.count ?? 0
        return count == 1 ? "1 measurement" : "\(count) measurements"
    }

    private var vaccinationGroupSummary: String {
        let count = viewModel.vaccinations?.vaccinations.filter { $0.status == .given }.count ?? 0
        return count == 1 ? "1 recorded vaccination" : "\(count) recorded vaccinations"
    }

    private var illnessGroupSummary: String {
        let count = viewModel.completedIllnesses.count
        return count == 1 ? "1 completed episode" : "\(count) completed episodes"
    }

    private func recordGroup<Content: View>(
        title: String,
        icon: String,
        summary: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            content()
                .padding(.top, 14)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.teal)
                    .frame(width: 32, height: 32)
                    .background(Color.teal.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private static func dateText(_ isoString: String) -> String {
        ISODateParser.parse(isoString).map(ISODateParser.dateOnly(from:)) ?? isoString
    }

    private static func decimal(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Illness history

private struct IllnessHistorySection: View {
    @ObservedObject var viewModel: HealthRecordViewModel
    @State private var showingRecordSheet = false
    @State private var pendingDelete: IllnessDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HealthDisclaimerBanner(
                text: "A family record of completed illness episodes, not medical advice."
            )

            Button {
                showingRecordSheet = true
            } label: {
                Label("Add past illness", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSaving)

            if viewModel.isLoading && viewModel.illnesses.isEmpty {
                ProgressView("Loading illness history...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if viewModel.completedIllnesses.isEmpty {
                ContentUnavailableView {
                    Label("No completed illnesses", systemImage: "heart.text.clipboard")
                } description: {
                    Text("Recovered illness episodes will build a useful history here.")
                }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.completedIllnesses) { illness in
                        illnessRow(illness)
                    }
                }
            }
        }
        .sheet(isPresented: $showingRecordSheet) {
            RecordPastIllnessSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "Remove this illness record?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { illness in
            Button("Remove record", role: .destructive) {
                Task { await viewModel.deleteIllness(illness) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This removes the episode from the visible family record.")
        }
    }

    private func illnessRow(_ illness: IllnessDTO) -> some View {
        HStack(alignment: .center, spacing: 8) {
            NavigationLink {
                IllnessDetailView(
                    initialChildId: viewModel.selectedChildId,
                    illnessId: illness.id
                )
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "heart.text.clipboard")
                        .font(.title3)
                        .foregroundStyle(.teal)
                        .frame(width: 36, height: 36)
                        .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(illness.notes.flatMap { $0.isEmpty ? nil : $0 } ?? "Illness")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(Self.dateRange(for: illness))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let days = Self.dayCount(for: illness) {
                            Text(days == 1 ? "1 day" : "\(days) days")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button("Remove record", systemImage: "trash", role: .destructive) {
                    pendingDelete = illness
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Illness record options")
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    static func dateRange(for illness: IllnessDTO) -> String {
        guard let start = ISODateParser.parse(illness.startedAt) else { return illness.startedAt }
        let startText = ISODateParser.dateOnly(from: start)
        guard let endedAt = illness.endedAt, let end = ISODateParser.parse(endedAt) else {
            return "From \(startText)"
        }
        if Calendar.current.isDate(start, inSameDayAs: end) { return startText }
        return "\(startText) – \(ISODateParser.dateOnly(from: end))"
    }

    static func dayCount(for illness: IllnessDTO, calendar: Calendar = .current) -> Int? {
        guard
            let start = ISODateParser.parse(illness.startedAt),
            let endedAt = illness.endedAt,
            let end = ISODateParser.parse(endedAt)
        else { return nil }
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return (calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0) + 1
    }
}

private struct RecordPastIllnessSheet: View {
    @ObservedObject var viewModel: HealthRecordViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var startedOn = Date()
    @State private var endedOn = Date()
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("First day", selection: $startedOn, in: ...Date(), displayedComponents: .date)
                    DatePicker("Last day", selection: $endedOn, in: startedOn...Date(), displayedComponents: .date)
                } header: {
                    Text("Past illness")
                } footer: {
                    Text("For an illness still happening, start it from Current state instead.")
                }

                Section("What happened? (optional)") {
                    TextField("For example, stomach bug", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Past Illness")
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
                            if await viewModel.recordIllness(
                                startedOn: startedOn,
                                endedOn: endedOn,
                                notes: notes
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            .onChange(of: startedOn) { _, newStart in
                if endedOn < newStart { endedOn = newStart }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Shared components

struct HealthDisclaimerBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.teal)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct HealthErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding(.vertical, 2)
        .padding(.leading, 10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension HealthStatus {
    var color: Color {
        switch self {
        case .given: return .green
        case .overdue: return .red
        case .due: return .orange
        case .upcoming: return .secondary
        }
    }

    var label: String {
        switch self {
        case .given: return "Given"
        case .overdue: return "Overdue"
        case .due: return "Due now"
        case .upcoming: return "Upcoming"
        }
    }

    var vaccinationLabel: String {
        switch self {
        case .given: return "Given"
        case .overdue: return "Not recorded"
        case .due: return "Due now"
        case .upcoming: return "Upcoming"
        }
    }

    var vaccinationColor: Color {
        switch self {
        case .given: return .green
        case .overdue, .due: return .orange
        case .upcoming: return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        HealthRecordView()
    }
}
