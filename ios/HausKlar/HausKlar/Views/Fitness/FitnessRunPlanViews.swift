import SwiftUI

struct FitnessRunPlansView: View {
    @StateObject private var viewModel = FitnessRunPlansViewModel()
    @State private var showingEditor = false

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.drafts.isEmpty && viewModel.definitions.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading run plans…").foregroundStyle(.secondary)
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try again",systemImage: "arrow.clockwise") {
                        Task { await viewModel.load(refresh: true) }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            Section("Drafts") {
                if viewModel.drafts.isEmpty {
                    Text("Create a reviewable run plan. Nothing is scheduled until you publish and accept it.")
                        .foregroundStyle(.secondary)
                    Button("Create run plan",systemImage: "plus.circle.fill") {
                        viewModel.newDraft(); showingEditor=true
                    }
                }
                ForEach(viewModel.drafts) { draft in
                    Button {
                        viewModel.edit(draft); showingEditor = true
                    } label: {
                        RunPlanSummaryLabel(
                            title: draft.name,
                            subtitle: FitnessRunPlanSemantics.validate(draft.steps, cues: draft.cues).summary
                        )
                    }
                }
            }
            Section("Published workouts") {
                if viewModel.definitions.isEmpty {
                    Text("No published run workouts yet.").foregroundStyle(.secondary)
                }
                ForEach(viewModel.definitions) { definition in
                    NavigationLink {
                        FitnessRunDefinitionView(definition: definition, viewModel: viewModel)
                    } label: {
                        RunPlanSummaryLabel(
                            title: definition.name,
                            subtitle: definition.currentVersion.map(FitnessRunPlanViews.summary) ?? "No saved workout"
                        )
                    }
                }
            }
            if !viewModel.programmes.isEmpty {
                Section("Training programmes") {
                    ForEach(viewModel.programmes) { programme in
                        VStack(alignment: .leading) {
                            Text(programme.name)
                            Text("\(programme.startsOn) · \(programme.status.capitalized)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Run plans")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.newDraft(); showingEditor = true
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("New run plan")
            }
        }
        .sheet(isPresented: $showingEditor) {
            FitnessRunPlanEditorView(viewModel: viewModel)
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load(refresh: true) }
    }
}

struct FitnessIntervalsConnectionSection: View {
    @ObservedObject var viewModel: FitnessIntervalsViewModel
    let plans: [FitnessPlannedSession]
    @State private var showingAPIKey = false
    @State private var showingDisconnect = false

    private var eligiblePlans: [FitnessPlannedSession] {
        plans.filter(\.isIntervalsDeliveryEligible)
    }

    var body: some View {
        Section("Garmin") {
            if let status = viewModel.status {
                if !status.configured {
                    Label("Intervals.icu is not available on this HausKlar server.", systemImage: "gear.badge.xmark")
                        .foregroundStyle(.secondary)
                } else if status.connected {
                    connectedContent(status)
                } else {
                    disconnectedContent(status)
                }
            } else if viewModel.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking Intervals.icu…").foregroundStyle(.secondary)
                }
            } else {
                Text("Connect once to send workouts and import completed Garmin activities.")
                    .foregroundStyle(.secondary)
                Button("Check connection", systemImage: "arrow.clockwise") {
                    Task { await viewModel.load() }
                }
            }

            if let message = viewModel.operationMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

        }
        .sheet(isPresented: $showingAPIKey) {
            FitnessIntervalsAPIKeySheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "Disconnect Intervals.icu?",
            isPresented: $showingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnect() }
            }
            Button("Keep connected", role: .cancel) {}
        } message: {
            Text("Previously sent workouts stay on Intervals.icu.")
        }
    }

    @ViewBuilder
    private func connectedContent(_ status: FitnessIntervalsStatus) -> some View {
        Label(status.athleteName ?? "Intervals.icu connected", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        switch status.garminTrainingConnected {
        case true:
            Label("Garmin workout delivery ready", systemImage: "watch.analog")
                .foregroundStyle(.green)
        case false:
            Label("Garmin workout delivery needs setup", systemImage: "watch.analog")
                .foregroundStyle(.orange)
        case nil:
            Label("Garmin readiness has not been reported", systemImage: "watch.analog")
                .foregroundStyle(.secondary)
        }

        Toggle(
            "Import Garmin activities",
            isOn: Binding(
                get: { status.activityImportEnabled },
                set: { enabled in
                    Task { await viewModel.setActivityImport(enabled: enabled) }
                }
            )
        )
        .disabled(viewModel.isWorking || !status.activityReadAuthorized)
        Text("Imports completed activities, routes, laps, heart rate and running metrics.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        if !status.activityReadAuthorized, status.oauthAvailable {
            Button("Reconnect to enable imports", systemImage: "arrow.triangle.2.circlepath") {
                Task { await viewModel.connectWithOAuth() }
            }
            .disabled(viewModel.isWorking)
        }
        if status.activityImportEnabled {
            HStack {
                Label(
                    "\(status.activityImportedCount) imported"
                        + (status.activityImportPendingCount > 0
                            ? " · \(status.activityImportPendingCount) processing"
                            : ""),
                    systemImage: "figure.run"
                )
                Spacer()
                Button("Import now", systemImage: "arrow.clockwise") {
                    Task { await viewModel.importActivitiesNow() }
                }
                .disabled(viewModel.isWorking)
            }
            if status.lastActivityImportErrorCode != nil {
                Text("Last import needs another try.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Activity data may include data from Garmin devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !eligiblePlans.isEmpty {
            Button {
                Task { await viewModel.sync(eligiblePlans) }
            } label: {
                if viewModel.isBulkSyncing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Updating Intervals.icu…")
                    }
                } else {
                    Label(
                        "Sync \(eligiblePlans.count) scheduled run\(eligiblePlans.count == 1 ? "" : "s")",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }
            .disabled(viewModel.isBulkSyncing || !viewModel.isConnected)
        }

        if let settingsURL = SafeExternalURL.web("https://intervals.icu/settings") {
            Link("Open Intervals.icu settings", destination: settingsURL)
        }
        HStack {
            Button("Check connection", systemImage: "arrow.clockwise") {
                Task { await viewModel.testConnection() }
            }
            .disabled(viewModel.isWorking)
            Spacer()
            Button("Disconnect", role: .destructive) { showingDisconnect = true }
                .disabled(viewModel.isWorking)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func disconnectedContent(_ status: FitnessIntervalsStatus) -> some View {
        if status.status == .reauthRequired {
            Label("Intervals.icu needs to be reconnected.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        } else if status.status == .providerDown {
            Label("Intervals.icu could not be reached.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        } else {
            Text("Connect once to send workouts and import completed Garmin activities.")
                .foregroundStyle(.secondary)
        }

        if status.oauthAvailable {
            Button("Connect Intervals.icu", systemImage: "person.example_35fbacff.circle.badge.checkmark") {
                Task { await viewModel.connectWithOAuth() }
            }
            .disabled(viewModel.isWorking)
        }
        if status.personalApiKeyAvailable {
            Button("Use personal API key", systemImage: "key") { showingAPIKey = true }
                .disabled(viewModel.isWorking)
        }
        if !status.oauthAvailable && !status.personalApiKeyAvailable {
            Button("Check again", systemImage: "arrow.clockwise") {
                Task { await viewModel.load() }
            }
            .disabled(viewModel.isWorking)
        }
        if let settingsURL = SafeExternalURL.web("https://intervals.icu/settings") {
            Link("Open Intervals.icu settings", destination: settingsURL)
        }
    }
}

private struct FitnessIntervalsAPIKeySheet: View {
    @ObservedObject var viewModel: FitnessIntervalsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Personal API key") {
                    SecureField("Intervals.icu API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                    Text("Copy the personal API key from your Intervals.icu settings. It is used once to connect your account and is not stored on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let settingsURL = SafeExternalURL.web("https://intervals.icu/settings") {
                        Link("Open Intervals.icu settings", destination: settingsURL)
                    }
                }
                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Connect Intervals.icu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        let key = apiKey
                        Task {
                            if await viewModel.connect(apiKey: key) {
                                apiKey = ""
                                dismiss()
                            }
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 || viewModel.isWorking)
                }
            }
            .onAppear { isFocused = true }
            .onDisappear { apiKey = "" }
            .interactiveDismissDisabled(viewModel.isWorking)
        }
    }
}

struct FitnessIntervalsDeliveryControl: View {
    @ObservedObject var viewModel: FitnessIntervalsViewModel
    let plan: FitnessPlannedSession
    @State private var showingRemoveConfirmation = false

    private var delivery: FitnessIntervalsDelivery? {
        viewModel.delivery(for: plan.id)
    }

    private var isSending: Bool {
        viewModel.sendingSessionIds.contains(plan.id)
    }

    var body: some View {
        if viewModel.isConnected && plan.isIntervalsDeliveryEligible {
            VStack(alignment: .leading, spacing: 7) {
                deliveryContent
                if let delivery {
                    ForEach(delivery.pushErrors, id: \.self) { error in
                        Label("Delivery issue: \(error)", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .task(id: "\(plan.id)|\(plan.updatedAt.timeIntervalSinceReferenceDate)|\(viewModel.isConnected)") {
                await viewModel.loadDelivery(for: plan)
            }
            .confirmationDialog(
                "Remove this workout from Intervals.icu?",
                isPresented: $showingRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove workout", role: .destructive) {
                    Task { await viewModel.cancel(plan) }
                }
                Button("Keep workout", role: .cancel) {}
            } message: {
                Text("HausKlar will ask Intervals.icu to cancel this scheduled workout.")
            }
        }
    }

    @ViewBuilder
    private var deliveryContent: some View {
        if isSending || (delivery == nil && viewModel.loadingSessionIds.contains(plan.id)) {
            HStack(spacing: 8) {
                ProgressView()
                Text("Updating Intervals.icu…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch delivery?.state ?? .notSent {
            case .notSent:
                actionButton("Send to Garmin", systemImage: "watch.analog") {
                    await viewModel.send(plan)
                }
            case .pending:
                HStack {
                    Label("Updating Intervals.icu…", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await viewModel.loadDelivery(for: plan) } }
                }
                .font(.caption)
            case .sent:
                Label("Sent to Intervals.icu", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                HStack {
                    actionButton("Update Garmin workout", systemImage: "arrow.clockwise") {
                        await viewModel.send(plan)
                    }
                    Button("Remove", systemImage: "xmark.circle", role: .destructive) {
                        showingRemoveConfirmation = true
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .disabled(isSending)
                }
            case .cancelled:
                actionButton("Send to Garmin again", systemImage: "watch.analog") {
                    await viewModel.send(plan)
                }
            case .error:
                Label("Intervals.icu needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let code = delivery?.lastErrorCode {
                    Text(code.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                actionButton("Retry", systemImage: "arrow.clockwise") {
                    await viewModel.send(plan)
                }
            }
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () async -> Void
    ) -> some View {
        Button(role: role) {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .disabled(isSending)
    }
}

private enum FitnessRunPlanViews {
    static func summary(_ version: FitnessWorkoutVersionDTO) -> String {
        [
            version.estimatedDistanceM.map(FitnessDisplay.distance),
            version.estimatedDurationS.map(FitnessDisplay.duration),
            version.acceptedAt == nil ? "Needs acceptance" : "Accepted",
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct RunPlanSummaryLabel: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.primary)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FitnessRunDefinitionView: View {
    let definition: FitnessWorkoutDefinitionDTO
    @ObservedObject var viewModel: FitnessRunPlansViewModel
    @State private var versionToSchedule: FitnessWorkoutVersionDTO?

    private var versions: [FitnessWorkoutVersionDTO] {
        definition.versions ?? definition.currentVersion.map { [$0] } ?? definition.version.map { [$0] } ?? []
    }

    var body: some View {
        List {
            if let error=viewModel.errorMessage {
                Section {
                    Label(error,systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try again",systemImage: "arrow.clockwise") {
                        Task { await viewModel.load(refresh: true) }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            if viewModel.isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Updating run plan…").foregroundStyle(.secondary)
                    }
                }
            }
            if let description = definition.description {
                Section("Purpose") { Text(description) }
            }
            ForEach(versions) { version in
                Section("Saved workout \(version.versionNumber.map(String.init) ?? "—")") {
                    RunPlanVersionSummary(version: version)
                    if version.acceptedAt == nil {
                        Button("Accept this workout") {
                            Task { await viewModel.accept(definitionId: definition.id, version: version) }
                        }
                        .disabled(viewModel.isLoading)
                    } else if let acceptedAt = version.acceptedAt {
                        Label("Accepted \(FitnessDisplay.date(acceptedAt))", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("Place on calendar") { versionToSchedule = version }
                        NavigationLink {
                            FitnessRunAdvancedExportView(version:version,viewModel:viewModel)
                        } label: {
                            Label("Advanced export",systemImage:"square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .navigationTitle(definition.name)
        .sheet(item: $versionToSchedule) { version in
            FitnessScheduleRunSheet(viewModel: viewModel, version: version)
        }
    }
}

private struct FitnessRunAdvancedExportView:View {
    let version:FitnessWorkoutVersionDTO
    @ObservedObject var viewModel:FitnessRunPlansViewModel

    var body:some View {
        List {
            Section {
                Text("Create a FIT file only when you need to transfer this workout manually.")
                    .foregroundStyle(.secondary)
                Button("Create FIT file") { Task { await viewModel.exportToGarmin(version) } }
                    .disabled(viewModel.isLoading)
            }
            if let export=viewModel.garminExport,export.workoutVersionId == version.id {
                Section("File") {
                    LabeledContent("Status", value: export.status.capitalized)
                    ForEach(export.mappingReport ?? []) { item in
                        VStack(alignment: .leading) {
                            Text("\(item.field): \(item.status)")
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if export.status == "processing" || export.status == "queued" {
                        Button("Check file") { Task { await viewModel.refreshGarminExport() } }
                    }
                    if export.isDownloadReady && viewModel.shareURL == nil {
                        Button("Prepare file to share") { Task { await viewModel.refreshGarminExport() } }
                    }
                    if let url = viewModel.shareURL {
                        ShareLink(item: url) { Label("Share Garmin FIT file", systemImage: "square.and.arrow.up") }
                    }
                    if let error = export.lastError { Text(error).foregroundStyle(.red) }
                    Text("Some watches may shorten spoken or on-screen cues. The complete instructions remain in HausKlar.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Advanced export")
    }
}

private struct RunPlanVersionSummary: View {
    let version: FitnessWorkoutVersionDTO
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(version.title).font(.headline)
            if let purpose = version.purpose { Text(purpose).foregroundStyle(.secondary) }
            HStack {
                if let distance = version.estimatedDistanceM { Label(FitnessDisplay.distance(distance), systemImage: "ruler") }
                if let duration = version.estimatedDurationS { Label(FitnessDisplay.duration(duration), systemImage: "timer") }
            }.font(.caption)
            ForEach(version.runSteps ?? []) { step in RunPlanStepLabel(step: step, depth: 0) }
            if !(version.runCues ?? []).isEmpty {
                Text("\((version.runCues ?? []).count) cues")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RunPlanStepLabel: View {
    let step: FitnessRunWorkoutStep
    let depth: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if depth > 0 { Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary) }
                Text(step.displayName)
                Spacer()
                Text(FitnessRunPlanFormatting.duration(step)).font(.caption).foregroundStyle(.secondary)
            }
            if let target = FitnessRunPlanFormatting.target(step) {
                Text(target).font(.caption).foregroundStyle(.secondary)
            }
            if let cue = step.mentalCueText, !cue.isEmpty {
                Label(cue, systemImage: "brain.head.profile").font(.caption)
            }
            ForEach(step.children ?? []) { child in RunPlanStepLabel(step: child, depth: depth + 1) }
        }
    }
}

private struct FitnessScheduleRunSheet: View {
    @ObservedObject var viewModel: FitnessRunPlansViewModel
    let version: FitnessWorkoutVersionDTO
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var precision=FitnessSchedulePrecision.exact
    @State private var scheduledStart=Date()
    @State private var windowEnd=Date().addingTimeInterval(3_600)
    @State private var scheduledDate=Date()
    @State private var goalId=""
    @State private var programmeId=""
    @State private var reason=""
    @State private var movable=true
    @State private var shareLogistics=false
    @State private var sharedTitle="Running"

    init(viewModel: FitnessRunPlansViewModel, version: FitnessWorkoutVersionDTO) {
        self.viewModel = viewModel
        self.version = version
        _title = State(initialValue: version.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Placement") {
                    TextField("Fitness title", text: $title)
                    Picker("Timing",selection: $precision) {
                        ForEach(FitnessSchedulePrecision.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    switch precision {
                    case .exact:
                        DatePicker("Starts",selection: $scheduledStart)
                    case .window:
                        DatePicker("Window starts",selection: $scheduledStart)
                        DatePicker("Window ends",selection: $windowEnd,in: scheduledStart...)
                    case .date:
                        DatePicker("Date",selection: $scheduledDate,displayedComponents: .date)
                    }
                    Picker("Primary goal",selection: $goalId) {
                        Text("No primary goal").tag("")
                        ForEach(viewModel.goals) { Text($0.title).tag($0.id) }
                    }
                    Picker("Programme",selection: $programmeId) {
                        Text("No programme").tag("")
                        ForEach(viewModel.programmes.filter { $0.status == "active" }) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    TextField("Reason for placement",text: $reason,axis: .vertical)
                    Toggle("Session can move",isOn: $movable)
                }
                Section("Household calendar") {
                    Toggle("Share logistics only",isOn: $shareLogistics)
                    if shareLogistics {
                        TextField("Shared title",text: $sharedTitle)
                        Text("Only this title and the approved date or time are shared. Workout, route, readiness and health details remain private.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("This placement stays on your private Fitness calendar layer and is not shared with the household.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Place run")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.schedule(version: version,placement: placement) { dismiss() }
                        }
                    }
                    .disabled(!isValid || viewModel.isLoading)
                }
            }
        }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (precision != .window || windowEnd > scheduledStart)
            && (!shareLogistics || !sharedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var placement: FitnessRunPlacementDraft {
        FitnessRunPlacementDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),precision: precision,
            scheduledStart: scheduledStart,windowEnd: windowEnd,scheduledDate: scheduledDate,
            goalId: goalId.isEmpty ? nil : goalId,programmeId: programmeId.isEmpty ? nil : programmeId,
            movable: movable,visibility: shareLogistics ? "logistics_shared" : "private",
            sharedTitle: shareLogistics ? sharedTitle.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            reasonForPlacement: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : reason.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct FitnessRunPlanEditorView: View {
    @ObservedObject var viewModel: FitnessRunPlansViewModel
    @Environment(\.dismiss) private var dismiss

    private static let missingDraft = FitnessRunPlanDraft(
        id: "",
        definitionId: nil,
        name: "",
        description: nil,
        title: "",
        purpose: nil,
        expectedDifficulty: nil,
        goalExplanation: nil,
        terrainAssumption: nil,
        steps: [],
        cues: [],
        updatedAt: .distantPast
    )

    private var validation: FitnessRunPlanValidation {
        guard let draft = viewModel.editorDraft else {
            return FitnessRunPlanValidation(errors: ["Draft missing."], warnings: [], totals: .init(distanceM: 0, durationS: 0, hasOpenDuration: false))
        }
        return FitnessRunPlanSemantics.validate(draft.steps, cues: draft.cues)
    }

    var body: some View {
        NavigationStack {
            if viewModel.editorDraft != nil {
                Form {
                    metadata
                    steps
                    cues
                    validationSection
                }
                .navigationTitle("Run plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        Button("Save") { Task { _ = await viewModel.saveDraft() } }
                        Button("Publish") { Task { if await viewModel.publish() { dismiss() } } }
                            .disabled(!validation.isValid)
                    }
                }
            }
        }
    }

    private var draftBinding: Binding<FitnessRunPlanDraft> {
        Binding(
            get: { viewModel.editorDraft ?? Self.missingDraft },
            set: { viewModel.editorDraft = $0 }
        )
    }

    private var metadata: some View {
        Section("Plan") {
            TextField("Workout name", text: draftBinding.name)
            TextField("Activity title", text: draftBinding.title)
            TextField("Purpose", text: optional(draftBinding.purpose), axis: .vertical)
            Picker("Expected difficulty", selection: optional(draftBinding.expectedDifficulty, fallback: "moderate")) {
                ForEach(["easy", "moderate", "hard", "very_hard"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
            }
            TextField("Goal explanation", text: optional(draftBinding.goalExplanation), axis: .vertical)
            TextField("Terrain assumption", text: optional(draftBinding.terrainAssumption), axis: .vertical)
        }
    }

    private var steps: some View {
        Section {
            ForEach(draftBinding.steps) { $step in
                NavigationLink {
                    FitnessRunStepEditor(step: $step)
                } label: {
                    RunPlanStepLabel(step: step, depth: 0)
                }
            }
            .onDelete { draftBinding.wrappedValue.steps.remove(atOffsets: $0); resequence() }
            .onMove { draftBinding.wrappedValue.steps.move(fromOffsets: $0, toOffset: $1); resequence() }
            Menu("Add step", systemImage: "plus") {
                Button("Timed step") { addStep(duration: .timeS, value: 600) }
                Button("Distance step") { addStep(duration: .distanceM, value: 1_000) }
                Button("Lap-button step") { addStep(duration: .lapButton, value: nil) }
                Button("Open step") { addStep(duration: .open, value: nil) }
                Button("Repeat block") { addRepeat() }
                Button("Kilometre sequence") { addKilometres(5) }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Use Edit to reorder. Every repeat is finite; kilometre indexes must start at 1 with no gaps.")
        }
    }

    private var cues: some View {
        Section("Independent cues") {
            ForEach(draftBinding.cues) { $cue in
                VStack(alignment: .leading) {
                    TextField("Short cue", text: $cue.shortText)
                    TextField("Spoken cue", text: optional($cue.spokenText))
                    Picker("Trigger", selection: $cue.triggerType) {
                        ForEach(Self.cueTriggers, id: \.key) { trigger in
                            Text(trigger.label).tag(trigger.key)
                        }
                    }
                    .onChange(of: cue.triggerType) { _, newValue in
                        if Self.stepBoundTriggers.contains(newValue) {
                            cue.stepId = cue.stepId ?? cueSteps.first?.id
                        } else {
                            cue.stepId = nil
                        }
                        if !Self.valueTriggers.contains(newValue) { cue.triggerValue = nil }
                    }
                    if Self.stepBoundTriggers.contains(cue.triggerType) {
                        Picker("Step", selection: Binding(
                            get: { cue.stepId ?? "" },
                            set: { cue.stepId = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Choose a step").tag("")
                            ForEach(cueSteps) { step in Text(step.displayName).tag(step.id) }
                        }
                    }
                    if Self.valueTriggers.contains(cue.triggerType) {
                        TextField("Trigger value", value: $cue.triggerValue, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
            }
            .onDelete { draftBinding.wrappedValue.cues.remove(atOffsets: $0) }
            Button("Add cue", systemImage: "text.bubble") {
                draftBinding.wrappedValue.cues.append(
                    FitnessRunWorkoutCue(
                        id: UUID().uuidString, stepId: nil,
                        sequence: draftBinding.wrappedValue.cues.count,
                        triggerType: "time_from_workout_start_s", triggerValue: 0,
                        shortText: "", spokenText: nil, priority: 0
                    )
                )
            }
        }
    }

    private static let cueTriggers: [(key: String, label: String)] = [
        ("workout_start", "Workout start"),
        ("step_start", "Step start"),
        ("step_end", "Step end"),
        ("distance_from_workout_start_m", "Distance from workout start"),
        ("distance_from_step_start_m", "Distance from step start"),
        ("time_from_workout_start_s", "Time from workout start"),
        ("time_from_step_start_s", "Time from step start"),
        ("halfway", "Halfway"),
        ("final_kilometre", "Final kilometre"),
        ("manual", "Manual"),
    ]
    private static let stepBoundTriggers: Set<String> = [
        "step_start", "step_end", "distance_from_step_start_m", "time_from_step_start_s",
    ]
    private static let valueTriggers: Set<String> = [
        "distance_from_workout_start_m", "distance_from_step_start_m",
        "time_from_workout_start_s", "time_from_step_start_s",
    ]

    private var cueSteps: [FitnessRunWorkoutStep] {
        func flatten(_ steps: [FitnessRunWorkoutStep]) -> [FitnessRunWorkoutStep] {
            steps.flatMap { step in
                step.stepKind == "repeat_block" ? flatten(step.children ?? []) : [step]
            }
        }
        return flatten(draftBinding.wrappedValue.steps)
    }

    private var validationSection: some View {
        Section("Review") {
            LabeledContent("Distance", value: FitnessDisplay.distance(validation.totals.distanceM))
            LabeledContent("Timed duration", value: FitnessDisplay.duration(validation.totals.durationS))
            if validation.totals.hasOpenDuration { Label("Also contains open/manual duration", systemImage: "hand.tap") }
            ForEach(validation.errors, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            ForEach(validation.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if validation.isValid { Label("Plan checks passed", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            Text("Before accepting a demanding plan, compare it with recent running and review active body issues. Publishing does not silently accept or schedule it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func addStep(duration: FitnessRunDurationType, value: Double?) {
        let index = draftBinding.wrappedValue.steps.count
        draftBinding.wrappedValue.steps.append(
            FitnessRunWorkoutStep(
                id: UUID().uuidString, parentStepId: nil, sequence: index,
                stepKind: index == 0 ? "warmup" : "work", repeatCount: nil,
                durationType: duration, durationValue: value,
                targetType: .none, targetLow: nil, targetHigh: nil, targetUnit: nil,
                intensityLabel: nil, kilometreIndex: nil,
                displayName: index == 0 ? "Warm up" : "Run",
                instructionText: nil, mentalCueText: nil, spokenCueText: nil,
                allowManualAdvance: duration == .open || duration == .lapButton,
                notes: nil, children: nil
            )
        )
    }

    private func addRepeat() {
        let id = UUID().uuidString
        let child = FitnessRunWorkoutStep(
            id: UUID().uuidString, parentStepId: id, sequence: 0,
            stepKind: "work", repeatCount: nil, durationType: .timeS,
            durationValue: 180, targetType: .none, targetLow: nil,
            targetHigh: nil, targetUnit: nil, intensityLabel: nil,
            kilometreIndex: nil, displayName: "Work", instructionText: nil,
            mentalCueText: nil, spokenCueText: nil, allowManualAdvance: false,
            notes: nil, children: nil
        )
        draftBinding.wrappedValue.steps.append(
            FitnessRunWorkoutStep(
                id: id, parentStepId: nil, sequence: draftBinding.wrappedValue.steps.count,
                stepKind: "repeat_block", repeatCount: 4, durationType: .open,
                durationValue: nil, targetType: .none, targetLow: nil,
                targetHigh: nil, targetUnit: nil, intensityLabel: nil,
                kilometreIndex: nil, displayName: "Repeat", instructionText: nil,
                mentalCueText: nil, spokenCueText: nil, allowManualAdvance: false,
                notes: nil, children: [child]
            )
        )
    }

    private func addKilometres(_ count: Int) {
        let existing = draftBinding.wrappedValue.steps.compactMap(\.kilometreIndex).max() ?? 0
        for index in 1...count {
            draftBinding.wrappedValue.steps.append(
                FitnessRunWorkoutStep(
                    id: UUID().uuidString, parentStepId: nil,
                    sequence: draftBinding.wrappedValue.steps.count, stepKind: "work",
                    repeatCount: nil, durationType: .distanceM, durationValue: 1_000,
                    targetType: .pace, targetLow: 300, targetHigh: 330,
                    targetUnit: "s/km", intensityLabel: "controlled",
                    kilometreIndex: existing + index, displayName: "Kilometre \(existing + index)",
                    instructionText: nil, mentalCueText: nil, spokenCueText: nil,
                    allowManualAdvance: false, notes: nil, children: nil
                )
            )
        }
    }

    private func resequence() {
        for index in draftBinding.wrappedValue.steps.indices { draftBinding.wrappedValue.steps[index].sequence = index }
    }

    private func optional(_ binding: Binding<String?>, fallback: String = "") -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

private struct FitnessRunStepEditor: View {
    @Binding var step: FitnessRunWorkoutStep

    var body: some View {
        Form {
            TextField("Display name", text: $step.displayName)
            Picker("Step kind", selection: $step.stepKind) {
                ForEach(["warmup", "work", "recovery", "cooldown", "repeat_block"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            if step.stepKind == "repeat_block" {
                Stepper("Repeat \(step.repeatCount ?? 1) times", value: Binding(
                    get: { step.repeatCount ?? 1 }, set: { step.repeatCount = $0 }
                ), in: 1...99)
                Section("Repeated steps") {
                    ForEach($step.children.bound) { $child in
                        NavigationLink { FitnessRunStepEditor(step: $child) } label: { RunPlanStepLabel(step: child, depth: 1) }
                    }
                    .onDelete { step.children?.remove(atOffsets: $0) }
                    Button("Add repeated work") {
                        let parent = step.id
                        step.children = (step.children ?? []) + [
                            FitnessRunWorkoutStep(
                                id: UUID().uuidString, parentStepId: parent,
                                sequence: step.children?.count ?? 0, stepKind: "work",
                                repeatCount: nil, durationType: .timeS, durationValue: 60,
                                targetType: .none, targetLow: nil, targetHigh: nil,
                                targetUnit: nil, intensityLabel: nil, kilometreIndex: nil,
                                displayName: "Work", instructionText: nil, mentalCueText: nil,
                                spokenCueText: nil, allowManualAdvance: false, notes: nil, children: nil
                            )
                        ]
                    }
                }
            } else {
                Picker("Duration", selection: $step.durationType) {
                    ForEach(FitnessRunDurationType.allCases) { Text(FitnessRunPlanFormatting.durationType($0)).tag($0) }
                }
                if [.distanceM, .timeS, .calories].contains(step.durationType) {
                    TextField("Duration value", value: $step.durationValue, format: .number)
                        .keyboardType(.decimalPad)
                }
                Picker("Target", selection: $step.targetType) {
                    ForEach(FitnessRunTargetType.allCases) { Text(FitnessRunPlanFormatting.targetType($0)).tag($0) }
                }
                if step.targetType != .none {
                    TextField("Target low", value: $step.targetLow, format: .number).keyboardType(.decimalPad)
                    TextField("Target high", value: $step.targetHigh, format: .number).keyboardType(.decimalPad)
                    TextField("Target unit", text: Binding(get: { step.targetUnit ?? "" }, set: { step.targetUnit = $0.isEmpty ? nil : $0 }))
                    if step.targetType == .pace { Text("Pace is stored as seconds per kilometre (s/km).").font(.caption).foregroundStyle(.secondary) }
                }
                TextField("Kilometre index", value: $step.kilometreIndex, format: .number).keyboardType(.numberPad)
            }
            TextField("Instruction", text: optional($step.instructionText), axis: .vertical)
            TextField("Mental cue", text: optional($step.mentalCueText), axis: .vertical)
            TextField("Intended spoken cue", text: optional($step.spokenCueText), axis: .vertical)
            TextField("Notes", text: optional($step.notes), axis: .vertical)
        }
        .navigationTitle(step.displayName)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

private enum FitnessRunPlanFormatting {
    static func duration(_ step: FitnessRunWorkoutStep) -> String {
        if step.stepKind == "repeat_block" { return "×\(step.repeatCount ?? 0)" }
        switch step.durationType {
        case .distanceM: return FitnessDisplay.distance(step.durationValue ?? 0)
        case .timeS: return FitnessDisplay.duration(step.durationValue ?? 0)
        case .lapButton: return "Lap button"
        case .open: return "Open"
        case .calories: return "\(Int(step.durationValue ?? 0)) kcal"
        }
    }
    static func target(_ step: FitnessRunWorkoutStep) -> String? {
        guard step.targetType != .none else { return nil }
        let values = [step.targetLow, step.targetHigh].compactMap { $0?.formatted() }.joined(separator: "–")
        return "\(targetType(step.targetType)): \(values) \(step.targetUnit ?? "")"
    }
    static func durationType(_ value: FitnessRunDurationType) -> String {
        switch value { case .distanceM: "Distance"; case .timeS: "Time"; case .lapButton: "Lap button"; case .open: "Open"; case .calories: "Calories" }
    }
    static func targetType(_ value: FitnessRunTargetType) -> String {
        switch value { case .pace: "Pace"; case .heartRate: "Heart rate"; case .heartRateZone: "Heart-rate zone"; case .power: "Power"; case .powerZone: "Power zone"; case .cadence: "Cadence"; case .rpe: "RPE"; case .none: "None" }
    }
}

private extension FitnessRunPlanValidation {
    var summary: String {
        [
            totals.distanceM > 0 ? FitnessDisplay.distance(totals.distanceM) : nil,
            totals.durationS > 0 ? FitnessDisplay.duration(totals.durationS) : nil,
            isValid ? "Ready to publish" : "\(errors.count) checks need attention",
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

private extension Optional where Wrapped == [FitnessRunWorkoutStep] {
    var bound: [FitnessRunWorkoutStep] {
        get { self ?? [] }
        set { self = newValue }
    }
}
