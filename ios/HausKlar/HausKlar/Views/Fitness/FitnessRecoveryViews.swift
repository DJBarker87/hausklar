import SwiftUI

struct FitnessRecoveryView: View {
    let focus: FitnessRecoveryFocusRoute?
    @StateObject private var viewModel = FitnessRecoveryViewModel()
    @State private var showingIssue = false
    @State private var editingSleep: FitnessSleepSessionDTO?
    @State private var showingSleep = false
    @State private var showingMoreTools = false
    @State private var showingHistory = false
    @State private var completedInitialLoad = false

    init(focus: FitnessRecoveryFocusRoute? = nil) { self.focus = focus }

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.summary == nil && viewModel.sleepSessions.isEmpty
                && viewModel.observations.isEmpty && viewModel.readiness.isEmpty && viewModel.issues.isEmpty
            {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading recovery…").foregroundStyle(.secondary)
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task { await viewModel.load(refresh: true) }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            if let focus {
                Section("Requested recovery item") { focusedRecovery(focus) }
            }
            Section("Today") {
                if let duration = viewModel.summary?.sleep.averageDurationS {
                    LabeledContent("Average sleep", value: String(format: "%.1f hours", duration / 3_600))
                } else {
                    Text("Add sleep or a quick check-in to begin your recovery picture.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.summary?.baselines.prefix(2) ?? []) { baseline in
                    LabeledContent(baseline.label, value: baselineValue(baseline))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { recoveryActions }
                    VStack(spacing: 8) { recoveryActions }
                }
            }
            Section {
                Button {
                    withAnimation(.snappy) { showingMoreTools.toggle() }
                } label: {
                    Label(showingMoreTools ? "Hide optional recovery tools" : "More recovery tools", systemImage: "ellipsis.circle")
                }
            }
            if showingMoreTools {
                Section("Cycle tracking") {
                    NavigationLink {
                        FitnessCycleTrackingView()
                    } label: {
                        Label("Periods and calendar estimates", systemImage: "calendar.badge.clock")
                    }
                    Text(
                        "Cycle data stays in Fitness. It is used for your chosen Calendar projections only and is not sent to Coach or used to adjust training."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Sleep") {
                Button("Add sleep manually", systemImage: "plus.circle") { showingSleep = true }
                if let sleepSummary = viewModel.summary?.sleep {
                    if let duration = sleepSummary.averageDurationS {
                        LabeledContent("Average duration", value: String(format: "%.1f h", duration / 3_600))
                    }
                    if let regularity = sleepSummary.timingRegularityMinutes {
                        LabeledContent("Timing regularity", value: String(format: "±%.0f min", regularity))
                    }
                }
                if viewModel.sleepSessions.isEmpty {
                    Text(
                        "No sleep sessions are available for this profile. Check the Sleep permission in Health, or wait for a supported source to record a session."
                    )
                    .foregroundStyle(.secondary)
                }
                ForEach(viewModel.sleepSessions.prefix(7)) { session in
                    DisclosureGroup {
                        if session.sourceRecordId == nil || session.sourceQuality == "manual" {
                            Button("Correct this entry", systemImage: "pencil") {
                                editingSleep = session
                                showingSleep = true
                            }
                        }
                        let stages = session.sourceStages ?? []
                        if stages.isEmpty {
                            Text("No sleep stages were recorded.").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                                HStack {
                                    Text(stage.stage.replacingOccurrences(of: "_", with: " ").capitalized)
                                    Spacer()
                                    Text(stageDuration(stage.durationS)).foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sleepTiming(session)).font(.headline)
                            Text(String(format: "%.1f h asleep", session.durationS / 3_600))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Personal baselines") {
                let baselines = viewModel.summary?.baselines ?? []
                if baselines.isEmpty {
                    ForEach(latestRecoveryObservations) { observation in
                        recoveryObservationRow(observation)
                    }
                    if latestRecoveryObservations.isEmpty {
                        Text("Resting heart-rate and HRV trends will appear as you record more days.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(baselines) { baseline in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(baseline.label).font(.headline)
                                Spacer()
                                Text(baselineValue(baseline)).foregroundStyle(baselineColor(baseline.status))
                            }
                            if let current = baseline.currentValue, let reference = baseline.baselineValue {
                                Text(
                                    "Current \(number(current)) · \(baseline.windowDays)-day baseline \(number(reference)) \(baseline.unitKey ?? "")"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            } else if let reason = baseline.missingReason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    withAnimation(.snappy) { showingHistory.toggle() }
                } label: {
                    Label(showingHistory ? "Hide recovery history" : "Show recovery history", systemImage: "clock.arrow.circlepath")
                }
            }
            if showingHistory {
                Section("Readiness history") {
                    if viewModel.readiness.isEmpty {
                        Text("Your readiness check-ins will appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.readiness.prefix(12)) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(item.value)/5 readiness").font(.headline)
                                Spacer()
                                Text(item.recordedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            if let title = item.activityTitle { Text(title).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                if item.isRetrospective { Text("Retrospective") }
                                if let rpe = item.sessionRPE { Text("Session RPE \(number(rpe))") }
                                if let performance = item.performance { Text("Performance \(performance)/5") }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let relationships = viewModel.summary?.relationships, !relationships.isEmpty {
                    Section("Descriptive relationships") {
                        ForEach(relationships) { relationship in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(relationship.label).font(.headline)
                                Text(relationship.summary)
                            }
                        }
                    }
                }
                Section("Progress photos") {
                    NavigationLink {
                        FitnessProgressPhotosView()
                    } label: {
                        Label("Open private gallery", systemImage: "person.example_35fbacff.rectangle.stack")
                    }
                }
            }
            Section("Body issues") {
                let activeIssues = viewModel.issues.filter { $0.resolvedAt == nil && $0.status != "resolved" }
                if activeIssues.isEmpty { Text("No active body issues.").foregroundStyle(.secondary) }
                ForEach(activeIssues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(issue.bodyLocationKey.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                            Spacer()
                            Text("\(issue.severity)/10").foregroundStyle(.secondary)
                        }
                        Text("\(issue.issueTypeKey.capitalized) · \(issue.side.replacingOccurrences(of: "_", with: " "))")
                            .font(.caption).foregroundStyle(.secondary)
                        if issue.changedSession {
                            Text("Changed session: \(issue.sessionChangeKey.replacingOccurrences(of: "_", with: " "))").font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                Text("This app provides reminders and tracking only, not medical advice.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Recovery")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Sleep entry", systemImage: "bed.double") { showingSleep = true }
                    Button("Body issue", systemImage: "bandage") { showingIssue = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingIssue) { FitnessNewBodyIssueSheet(viewModel: viewModel) }
        .sheet(isPresented: $showingSleep, onDismiss: { editingSleep = nil }) {
            FitnessManualSleepSheet(viewModel: viewModel, existing: editingSleep)
        }
        .task {
            await viewModel.load()
            completedInitialLoad = true
        }
        .refreshable { await viewModel.load(refresh: true) }
    }

    @ViewBuilder private var recoveryActions: some View {
        Button("Add sleep", systemImage: "bed.double") { showingSleep = true }
            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44)
        Button("Body check-in", systemImage: "bandage") { showingIssue = true }
            .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
    }

    @ViewBuilder
    private func focusedRecovery(_ focus: FitnessRecoveryFocusRoute) -> some View {
        if !completedInitialLoad {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading \(focus.label)…")
            }
            .foregroundStyle(.secondary)
        } else {
            switch focus.kind {
            case .bodyIssue:
                if let issue = viewModel.issues.first(where: { $0.id == focus.target }) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(issue.bodyLocationKey.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.headline)
                            Spacer()
                            Text("\(issue.severity)/10").foregroundStyle(.secondary)
                        }
                        Text("\(issue.issueTypeKey.capitalized) · \(issue.side.replacingOccurrences(of:"_",with:" "))")
                            .font(.caption).foregroundStyle(.secondary)
                        Label(
                            issue.resolvedAt == nil && issue.status != "resolved" ? "Active" : "Resolved",
                            systemImage: issue.resolvedAt == nil && issue.status != "resolved"
                                ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption).foregroundStyle(
                            issue.resolvedAt == nil && issue.status != "resolved" ? .orange : .green
                        )
                    }
                } else {
                    Label("This body issue is no longer available.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text(focus.summary).font(.caption).foregroundStyle(.secondary)
                }
            case .baseline:
                if let baseline = viewModel.summary?.baselines.first(where: { $0.metricKey == focus.target }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(baseline.label).font(.headline)
                            Spacer()
                            Text(baselineValue(baseline)).foregroundStyle(baselineColor(baseline.status))
                        }
                        if let current = baseline.currentValue, let reference = baseline.baselineValue {
                            Text(
                                "Current \(number(current)) · \(baseline.windowDays)-day baseline \(number(reference)) \(baseline.unitKey ?? "")"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        } else if let reason = baseline.missingReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if let observation = viewModel.observations.first(where: { $0.metricKey == focus.target }) {
                    recoveryObservationRow(observation)
                } else {
                    Label("This recovery baseline is no longer available.", systemImage: "waveform.path.ecg")
                        .foregroundStyle(.secondary)
                    Text(focus.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var healthAccessIcon: String {
        switch viewModel.healthAccess {
        case .enabled: "heart.text.square.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unavailable: "heart.slash"
        case .notRequested, .needsPermission: "heart.text.square"
        }
    }

    private var healthAccessTint: Color {
        switch viewModel.healthAccess {
        case .enabled: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private var latestRecoveryObservations: [FitnessRecoveryObservationDTO] {
        ["recovery.resting_heart_rate_bpm", "recovery.hrv_sdnn_ms"].compactMap { metric in
            viewModel.observations.first { $0.metricKey == metric }
        }
    }

    @ViewBuilder
    private func recoveryObservationRow(_ observation: FitnessRecoveryObservationDTO) -> some View {
        let label = observation.metricKey.contains("hrv") ? "HRV (SDNN)" : "Resting heart rate"
        LabeledContent(label) {
            if let value = observation.valueNumber {
                Text("\(number(value)) \(observation.unitKey ?? "")")
            } else {
                Text("Unknown").foregroundStyle(.secondary)
            }
        }
    }

    private func sleepTiming(_ session: FitnessSleepSessionDTO) -> String {
        guard let start = FitnessDatabase.date(session.sleepStartUtc),
            let end = FitnessDatabase.date(session.sleepEndUtc)
        else { return "Sleep session" }
        return "\(start.formatted(date: .abbreviated,time: .shortened)) – \(end.formatted(date: .omitted,time: .shortened))"
    }

    private func stageDuration(_ seconds: Double) -> String {
        seconds >= 3_600 ? String(format: "%.1f h", seconds / 3_600) : "\(Int(seconds / 60)) min"
    }

    private func baselineValue(_ baseline: FitnessRecoverySummaryDTO.Baseline) -> String {
        guard let value = baseline.currentValue else { return "Missing" }
        let deviation = baseline.deviationPercent.map { String(format: "%+.0f%%", $0) }
        return "\(number(value)) \(baseline.unitKey ?? "")" + (deviation.map { " · \($0)" } ?? "")
    }

    private func baselineColor(_ status: String) -> Color {
        switch status {
        case "outside_baseline", "above_baseline", "below_baseline", "high", "low": .orange
        case "within_baseline": .green
        default: .secondary
        }
    }

    private func number(_ value: Double) -> String { String(format: value.rounded() == value ? "%.0f" : "%.1f", value) }
}

struct FitnessCycleTrackingView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = FitnessCycleTrackingViewModel()
    @State private var periodToDelete: CyclePeriodStartDTO?

    let showsDoneButton: Bool
    let onChanged: () -> Void

    init(showsDoneButton: Bool = false, onChanged: @escaping () -> Void = {}) {
        self.showsDoneButton = showsDoneButton
        self.onChanged = onChanged
    }

    var body: some View {
        Form {
            if viewModel.isLoading && viewModel.profiles.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading cycle tracking…")
                        Spacer()
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Button("Try again") { Task { await viewModel.load(refresh: true) } }
                        .frame(minHeight: 44)
                }
            }
            if let notice = viewModel.notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if !viewModel.isLoading && viewModel.ownProfile == nil {
                Section {
                    ContentUnavailableView(
                        "Cycle tracking is not set up",
                        systemImage: "calendar.badge.plus",
                        description: Text("Choose your calculation and privacy settings below. Sharing starts off.")
                    )
                }
            }

            Section("Calculation") {
                HStack {
                    Text("Cycle length")
                    Spacer()
                    TextField("Days", value: $viewModel.cycleLengthDays, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 64)
                    Text("days").foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Period starts", isOn: $viewModel.showPeriodStarts)
                Toggle("Predicted next period", isOn: $viewModel.showPredictedPeriod)
                Toggle("Estimated ovulation", isOn: $viewModel.showEstimatedOvulation)
            } header: {
                Text("Show on my Calendar")
            } footer: {
                Text("These switches control your own read-only Calendar projections. They do not share data with anyone else.")
            }

            Section {
                sharingToggle(
                    "Recorded period starts", isOn: $viewModel.sharePeriodStartsWithAdults
                )
                sharingToggle(
                    "Predicted next period", isOn: $viewModel.sharePredictedPeriodWithAdults
                )
                sharingToggle(
                    "Estimated ovulation", isOn: $viewModel.shareEstimatedOvulationWithAdults
                )
            } header: {
                Text("Share with household adults")
            } footer: {
                Text("Each category requires separate consent and is off by default. You can withdraw any permission at any time.")
            }

            Section {
                Button {
                    Task {
                        if await viewModel.saveSettings() { onChanged() }
                    }
                } label: {
                    if viewModel.isWorking {
                        ProgressView()
                    } else {
                        Label(
                            viewModel.ownProfile == nil ? "Set up cycle tracking" : "Save settings",
                            systemImage: "checkmark"
                        )
                    }
                }
                .frame(minHeight: 44)
                .disabled(viewModel.isWorking || !(10...365).contains(viewModel.cycleLengthDays))
            }

            if let profile = viewModel.ownProfile {
                Section("Record a period start") {
                    DatePicker(
                        "Started on", selection: $viewModel.periodStartDate, displayedComponents: .date
                    )
                    Button {
                        Task {
                            if await viewModel.recordPeriodStart() { onChanged() }
                        }
                    } label: {
                        if viewModel.isWorking { ProgressView() } else { Label("Period started", systemImage: "calendar.badge.plus") }
                    }
                    .frame(minHeight: 44).disabled(viewModel.isWorking)
                }

                Section("Calculated dates") {
                    LabeledContent(
                        "Latest start", value: FitnessCycleTrackingViewModel.displayDate(profile.latestPeriodStart)
                    )
                    LabeledContent(
                        "Next period", value: FitnessCycleTrackingViewModel.displayDate(profile.predictedNextPeriod)
                    )
                    LabeledContent(
                        "Estimated ovulation", value: FitnessCycleTrackingViewModel.displayDate(profile.estimatedOvulation)
                    )
                }

                if !profile.periodStarts.isEmpty {
                    Section("Recorded starts") {
                        ForEach(profile.periodStarts) { period in
                            HStack {
                                Text(FitnessCycleTrackingViewModel.displayDate(period.startedOn))
                                Spacer()
                                Button(role: .destructive) {
                                    periodToDelete = period
                                } label: {
                                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.plain).disabled(viewModel.isWorking)
                                .accessibilityLabel("Remove period start \(period.startedOn)")
                            }
                        }
                    }
                }
            }

            if !viewModel.sharedProfiles.isEmpty {
                Section("Shared with you") {
                    ForEach(viewModel.sharedProfiles) { profile in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(profile.ownerName).font(.headline)
                            if let value = profile.latestPeriodStart {
                                LabeledContent(
                                    "Latest start", value: FitnessCycleTrackingViewModel.displayDate(value)
                                )
                            }
                            if let value = profile.predictedNextPeriod {
                                LabeledContent(
                                    "Next period", value: FitnessCycleTrackingViewModel.displayDate(value)
                                )
                            }
                            if let value = profile.estimatedOvulation {
                                LabeledContent(
                                    "Estimated ovulation", value: FitnessCycleTrackingViewModel.displayDate(value)
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                Text("Cycle dates are planning estimates only, not medical advice or contraception guidance.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cycle Tracking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load(refresh: true) }
        .confirmationDialog(
            "Remove this period start?",
            isPresented: Binding(
                get: { periodToDelete != nil }, set: { if !$0 { periodToDelete = nil } }
            ), presenting: periodToDelete
        ) { period in
            Button("Remove", role: .destructive) {
                Task {
                    if await viewModel.deletePeriodStart(period) { onChanged() }
                    periodToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { periodToDelete = nil }
        } message: { period in
            Text("This removes \(FitnessCycleTrackingViewModel.displayDate(period.startedOn)) and recalculates future dates.")
        }
    }

    @ViewBuilder
    private func sharingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(isOn.wrappedValue ? "Shared with signed-in adults" : "Private")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
    }
}

struct FitnessManualSleepSheet: View {
    @ObservedObject var viewModel: FitnessRecoveryViewModel
    @Environment(\.dismiss) private var dismiss
    let existing: FitnessSleepSessionDTO?
    @State private var start: Date
    @State private var end: Date
    @State private var recordsAwake: Bool
    @State private var awakeMinutes: Double
    @State private var notes: String

    init(viewModel: FitnessRecoveryViewModel, existing: FitnessSleepSessionDTO?) {
        self.viewModel = viewModel
        self.existing = existing
        let defaultEnd = Date()
        let defaultStart = Calendar.current.date(byAdding: .hour, value: -8, to: defaultEnd) ?? defaultEnd
        _start = State(initialValue: existing.flatMap { FitnessDatabase.date($0.sleepStartUtc) } ?? defaultStart)
        _end = State(initialValue: existing.flatMap { FitnessDatabase.date($0.sleepEndUtc) } ?? defaultEnd)
        _recordsAwake = State(initialValue: existing?.awakeDurationS != nil)
        _awakeMinutes = State(initialValue: (existing?.awakeDurationS ?? 0) / 60)
        _notes = State(initialValue: existing?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sleep window") {
                    DatePicker("Fell asleep", selection: $start)
                    DatePicker("Woke up", selection: $end)
                    Toggle("Record awake time", isOn: $recordsAwake)
                    if recordsAwake {
                        Stepper("Awake: \(Int(awakeMinutes)) min", value: $awakeMinutes, in: 0...720, step: 5)
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                Section {
                    Text("Manual corrections stay clearly labelled and never overwrite imported HealthKit readings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "Add sleep" : "Correct sleep")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.saveManualSleep(
                                existing: existing, start: start, end: end,
                                awakeMinutes: recordsAwake ? awakeMinutes : nil,
                                notes: notes.isEmpty ? nil : notes
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(end <= start || (recordsAwake && awakeMinutes * 60 > end.timeIntervalSince(start)))
                }
            }
        }
    }
}

struct FitnessNewBodyIssueSheet: View {
    @ObservedObject var viewModel: FitnessRecoveryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var issue = NewBodyIssue(
        issueTypeKey: "discomfort", bodyLocationKey: "", side: "not_applicable",
        severity: 3, timing: "standalone", changedSession: false, sessionChangeKey: "none", note: nil
    )
    var body: some View {
        NavigationStack {
            Form { FitnessBodyIssueFields(issue: $issue, locations: viewModel.bodyLocations) }
                .navigationTitle("Body issue")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { if await viewModel.addIssue(issue) { dismiss() } } }
                            .disabled(issue.bodyLocationKey.isEmpty)
                    }
                }
        }
    }
}
