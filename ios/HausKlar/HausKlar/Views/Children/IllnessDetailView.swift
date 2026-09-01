import Charts
import SwiftData
import SwiftUI

/// One coherent illness episode: current state, observations, recorded medicine,
/// recovery and corrections. Medicine always goes through the reviewed log form.
struct IllnessDetailView: View {
    @StateObject private var viewModel: IllnessViewModel
    @StateObject private var medicineVM = MedicineViewModel()
    @Environment(\.modelContext) private var modelContext

    @State private var showingMedicineReview = false
    @State private var showingEndConfirmation = false
    @State private var showingReopenConfirmation = false
    @State private var pendingTemperatureDelete: TemperatureReadingDTO?
    @State private var chartExpanded = false

    init(initialChildId: String? = nil, illnessId: String? = nil) {
        _viewModel = StateObject(
            wrappedValue: IllnessViewModel(
                initialChildId: initialChildId,
                illnessId: illnessId
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.canSelectChild {
                    childSelector
                }

                if let error = viewModel.errorMessage {
                    HealthErrorBanner(message: error) { viewModel.errorMessage = nil }
                }

                if viewModel.isLoading && viewModel.episode == nil {
                    ProgressView("Loading illness record...")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else if let illness = viewModel.episode {
                    episodeStatus(illness)

                    if viewModel.isActiveEpisode {
                        activeActions
                        medicineReminders
                    }

                    episodeTimeline

                    if let detail = viewModel.illnessDetail,
                       !detail.temperatureReadings.isEmpty {
                        DisclosureGroup(isExpanded: $chartExpanded) {
                            temperatureChart(detail)
                                .padding(.top, 12)
                        } label: {
                            Label("Temperature chart", systemImage: "chart.xyaxis.line")
                                .font(.headline)
                        }
                        .padding(16)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }

                    lifecycleAction
                } else {
                    noIllnessView
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Illness")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $viewModel.showingStartIllness) {
            startIllnessSheet
        }
        .sheet(isPresented: $viewModel.showingTemperatureEditor, onDismiss: {
            viewModel.resetTemperatureForm()
        }) {
            temperatureEditorSheet
        }
        .sheet(isPresented: $viewModel.showingEpisodeEditor) {
            episodeEditorSheet
        }
        .sheet(isPresented: $showingMedicineReview, onDismiss: {
            Task {
                if let illnessId = viewModel.episode?.id {
                    await viewModel.loadIllnessDetail(illnessId: illnessId)
                }
            }
        }) {
            LogDoseSheet(viewModel: medicineVM)
        }
        .confirmationDialog(
            "Remove this temperature?",
            isPresented: Binding(
                get: { pendingTemperatureDelete != nil },
                set: { if !$0 { pendingTemperatureDelete = nil } }
            ),
            presenting: pendingTemperatureDelete
        ) { reading in
            Button("Remove reading", role: .destructive) {
                Task { await viewModel.deleteTemperature(reading) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This removes the reading from the episode timeline.")
        }
        .alert("Mark this episode recovered?", isPresented: $showingEndConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Mark Recovered") { Task { await viewModel.endIllness() } }
        } message: {
            Text("You can correct the recovery time or reopen the episode later.")
        }
        .alert("Reopen this episode?", isPresented: $showingReopenConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reopen") { Task { await viewModel.reopenIllness() } }
        } message: {
            Text("This makes it the current illness episode for \(viewModel.selectedChildName).")
        }
        .task {
            medicineVM.bindModelContext(modelContext)
            await viewModel.loadData()
            medicineVM.selectedChildId = viewModel.selectedChildId
            await medicineVM.loadData()
            medicineVM.selectedChildId = viewModel.selectedChildId
        }
        .refreshable {
            await viewModel.loadData()
            medicineVM.selectedChildId = viewModel.selectedChildId
            await medicineVM.loadData()
            medicineVM.selectedChildId = viewModel.selectedChildId
        }
    }

    // MARK: - Child and empty state

    private var childSelector: some View {
        ChildSelectorChips(
            children: viewModel.children,
            selectedChildId: $viewModel.selectedChildId,
            nameKeyPath: \.name
        ) { childId in
            medicineVM.selectedChildId = childId
            Task {
                await viewModel.childChanged(to: childId)
                await medicineVM.loadData()
                medicineVM.selectedChildId = childId
            }
        }
    }

    private var noIllnessView: some View {
        ContentUnavailableView {
            Label("No current illness", systemImage: "heart.fill")
        } description: {
            Text("\(viewModel.selectedChildName) has no open illness episode.")
        } actions: {
            Button("Start illness episode") {
                viewModel.illnessStartedAt = Date()
                viewModel.showingStartIllness = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    // MARK: - Episode status

    private func episodeStatus(_ illness: IllnessDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: viewModel.isActiveEpisode ? "thermometer.high" : "heart.fill")
                    .font(.title2)
                    .foregroundStyle(viewModel.isActiveEpisode ? Color.orange : Color.green)
                    .frame(width: 42, height: 42)
                    .background(
                        (viewModel.isActiveEpisode ? Color.orange : Color.green).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.isActiveEpisode ? "Current illness" : "Recovered")
                        .font(.headline)
                    Text(viewModel.selectedChildName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Correct") { viewModel.prepareEpisodeCorrection() }
                    .font(.subheadline.weight(.semibold))
                    .disabled(viewModel.isSaving)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    episodeFact("Began", value: viewModel.formattedDateTime(illness.startedAt))
                    if let endedAt = illness.endedAt {
                        episodeFact("Recovered", value: viewModel.formattedDateTime(endedAt))
                    } else {
                        episodeFact("Open for", value: viewModel.episodeDuration(illness))
                    }
                }
            }

            if let notes = illness.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty {
                Divider()
                Text(notes)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Symptoms and notes: \(notes)")
            } else {
                Text("No symptoms or notes recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func episodeFact(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Live actions and reminders

    private var activeActions: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.prepareTemperatureEditor()
            } label: {
                Label("Temperature", systemImage: "thermometer.medium")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)

            Button {
                guard let childId = viewModel.episode?.childId else { return }
                medicineVM.resetLogDoseForm()
                medicineVM.selectedChildId = childId
                showingMedicineReview = true
            } label: {
                Label("Medicine", systemImage: "cross.case")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .accessibilityHint("Opens a review form before anything is recorded")
        }
        .disabled(viewModel.isSaving)
    }

    @ViewBuilder
    private var medicineReminders: some View {
        if let nextDoses = viewModel.illnessDetail?.nextDoseTimes, !nextDoses.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Medicine reminders")
                    .font(.headline)
                Text("Based on the intervals saved for your family medicines. These are record reminders, not dosing advice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(nextDoses) { dose in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: dose.color ?? "#5856D6"))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(dose.medicineName)
                                    .font(.subheadline.weight(.semibold))
                                if let amount = dose.defaultDoseAmount, !amount.isEmpty {
                                    Text(amount)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            reminderText(dose)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @ViewBuilder
    private func reminderText(_ dose: NextDoseTimeDTO) -> some View {
        if dose.isSafeNow {
            Text("Saved interval elapsed")
                .font(.caption)
                .foregroundStyle(.green)
        } else if let nextSafeAt = dose.nextSafeAt,
                  let date = ISODateParser.parse(nextSafeAt) {
            Text("Saved interval ends \(ISODateParser.relative(from: date))")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let lastGivenAt = dose.lastGivenAt {
            Text("Last recorded \(viewModel.formattedDateTime(lastGivenAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Timeline

    private var episodeTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Episode timeline")
                        .font(.headline)
                    Text("Temperatures and medicines already recorded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.isActiveEpisode {
                    Button {
                        viewModel.prepareTemperatureEditor()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Add temperature")
                }
            }

            if timelineItems.isEmpty {
                Text("No observations have been recorded in this episode yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(timelineItems.enumerated()), id: \.element.id) { index, item in
                        timelineRow(item)
                        if index < timelineItems.count - 1 { Divider().padding(.leading, 50) }
                    }
                }
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var timelineItems: [EpisodeTimelineItem] {
        guard let detail = viewModel.illnessDetail else { return [] }
        let temperatures = detail.temperatureReadings.map(EpisodeTimelineItem.temperature)
        let medicines = detail.medicineDoses.map(EpisodeTimelineItem.medicine)
        return (temperatures + medicines).sorted { $0.date > $1.date }
    }

    @ViewBuilder
    private func timelineRow(_ item: EpisodeTimelineItem) -> some View {
        switch item {
        case .temperature(let reading):
            HStack(alignment: .top, spacing: 12) {
                timelineIcon("thermometer.medium", color: reading.valueCelsius >= 37.5 ? .red : .blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "%.1f°C", reading.valueCelsius))
                        .font(.subheadline.weight(.semibold))
                    Text(viewModel.formattedDateTime(reading.recordedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let notes = reading.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("Correct reading", systemImage: "pencil") {
                        viewModel.prepareTemperatureEditor(for: reading)
                    }
                    Button("Remove reading", systemImage: "trash", role: .destructive) {
                        pendingTemperatureDelete = reading
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Temperature options")
            }
            .padding(.vertical, 10)

        case .medicine(let dose):
            HStack(alignment: .top, spacing: 12) {
                timelineIcon("cross.case.fill", color: Color(hex: dose.color ?? "#5856D6"))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(dose.medicineNameDisplay ?? "Medicine")
                            .font(.subheadline.weight(.semibold))
                        if let amount = dose.doseAmount, !amount.isEmpty {
                            Text(amount)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(viewModel.formattedDateTime(dose.givenAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let notes = dose.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
        }
    }

    private func timelineIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(color.opacity(0.12), in: Circle())
    }

    // MARK: - Chart and lifecycle

    private func temperatureChart(_ detail: IllnessDetailDTO) -> some View {
        Chart {
            ForEach(detail.temperatureReadings) { reading in
                if let date = viewModel.parseISO8601(reading.recordedAt) {
                    LineMark(
                        x: .value("Time", date),
                        y: .value("Temperature", reading.valueCelsius)
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.linear)

                    PointMark(
                        x: .value("Time", date),
                        y: .value("Temperature", reading.valueCelsius)
                    )
                    .foregroundStyle(.red)
                }
            }

            ForEach(detail.medicineDoses) { dose in
                if let date = viewModel.parseISO8601(dose.givenAt) {
                    RuleMark(x: .value("Medicine", date))
                        .foregroundStyle(Color(hex: dose.color ?? "#5856D6").opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
        }
        .chartYScale(domain: 35...42)
        .frame(height: 220)
        .accessibilityLabel("Temperature chart for this illness episode")
    }

    private var lifecycleAction: some View {
        Group {
            if viewModel.isActiveEpisode {
                Button {
                    showingEndConfirmation = true
                } label: {
                    Label("Mark Recovered", systemImage: "heart.fill")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            } else {
                Button {
                    showingReopenConfirmation = true
                } label: {
                    Label("Reopen Episode", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(viewModel.isSaving)
    }

    // MARK: - Sheets

    private var startIllnessSheet: some View {
        NavigationStack {
            Form {
                Section("When did it begin?") {
                    DatePicker(
                        "Began",
                        selection: $viewModel.illnessStartedAt,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Section("Symptoms and notes") {
                    TextField("What have you noticed?", text: $viewModel.illnessNotes, axis: .vertical)
                        .lineLimit(3...7)
                }
                sheetError
            }
            .navigationTitle("Start Illness")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingStartIllness = false }
                        .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await viewModel.startIllness() } }
                        .disabled(viewModel.isSaving)
                }
            }
        }
    }

    private var temperatureEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Temperature") {
                    HStack {
                        Text(String(format: "%.1f°C", viewModel.temperatureValue))
                            .font(.title2.weight(.bold))
                        Spacer()
                    }
                    Slider(value: $viewModel.temperatureValue, in: 30.0...45.0, step: 0.1)
                }
                Section("When") {
                    DatePicker(
                        "Recorded",
                        selection: $viewModel.temperatureDate,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Section("Notes") {
                    TextField("Any useful context", text: $viewModel.temperatureNotes, axis: .vertical)
                        .lineLimit(2...5)
                }
                sheetError
            }
            .navigationTitle(viewModel.editingTemperatureId == nil ? "Add Temperature" : "Correct Temperature")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingTemperatureEditor = false }
                        .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await viewModel.saveTemperature() } }
                        .disabled(viewModel.isSaving)
                }
            }
        }
    }

    private var episodeEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Episode dates") {
                    DatePicker(
                        "Began",
                        selection: $viewModel.correctedStartedAt,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    if !viewModel.isActiveEpisode {
                        DatePicker(
                            "Recovered",
                            selection: $viewModel.correctedEndedAt,
                            in: viewModel.correctedStartedAt...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
                Section("Symptoms and notes") {
                    TextField("What happened?", text: $viewModel.correctedNotes, axis: .vertical)
                        .lineLimit(3...8)
                }
                sheetError
            }
            .navigationTitle("Correct Episode")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingEpisodeEditor = false }
                        .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await viewModel.saveEpisodeCorrection() } }
                        .disabled(viewModel.isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var sheetError: some View {
        if let error = viewModel.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private enum EpisodeTimelineItem: Identifiable {
    case temperature(TemperatureReadingDTO)
    case medicine(IllnessDoseDTO)

    var id: String {
        switch self {
        case .temperature(let reading): return "temperature-\(reading.id)"
        case .medicine(let dose): return "medicine-\(dose.id)"
        }
    }

    var date: Date {
        switch self {
        case .temperature(let reading): return ISODateParser.parse(reading.recordedAt) ?? .distantPast
        case .medicine(let dose): return ISODateParser.parse(dose.givenAt) ?? .distantPast
        }
    }
}

#Preview {
    NavigationStack {
        IllnessDetailView()
    }
}
