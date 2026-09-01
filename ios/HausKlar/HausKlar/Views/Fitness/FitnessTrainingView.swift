import SwiftUI

private struct FitnessQuickSport: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String

    static let choices: [FitnessQuickSport] = [
        .init(id: "running", title: "Run", detail: "Just go, or add a target", systemImage: "figure.run"),
        .init(id: "strength", title: "Strength", detail: "Use sets, reps and loads", systemImage: "dumbbell"),
        .init(id: "other", title: "Other", detail: "Choose another activity", systemImage: "figure.mixed.cardio"),
    ]
}

private enum FitnessQuickSessionMoment: String, CaseIterable, Identifiable {
    case now, later, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: "Now".localized
        case .later: "Later".localized
        case .done: "Done".localized
        }
    }
    var detail: String {
        switch self {
        case .now: "I’m about to do it".localized
        case .later: "Put it in my week".localized
        case .done: "I already did it".localized
        }
    }
}

private enum FitnessQuickRunTarget: String, CaseIterable, Identifiable {
    case none, time, pace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No target".localized
        case .time: "Time".localized
        case .pace: "Pace".localized
        }
    }
}

struct FitnessTrainingView: View {
    @StateObject private var viewModel = FitnessTrainingViewModel()
    @StateObject private var strava = FitnessStravaViewModel()
    @State private var sheet: Sheet?
    @State private var quickSport: FitnessQuickSport?
    @State private var strengthSeed: FitnessSavedStrengthWorkout?
    @State private var managedPlan: FitnessPlannedSession?
    private enum Sheet: Identifiable {
        case plan, manage
        var id: String { String(describing: self) }
    }

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.plans.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading sessions…").foregroundStyle(.secondary)
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await viewModel.loadHome(refresh: true) } }
                        .disabled(viewModel.isLoading)
                }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                    ForEach(FitnessQuickSport.choices) { sport in
                        quickSportButton(sport)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What do you want to do?")
                    Text("Plan ahead, do it now, or log it afterwards.")
                        .font(.caption).textCase(nil).foregroundStyle(.secondary)
                }
            }
            if strava.status?.configured != false {
                stravaSection
            }
            Section("Up next") {
                if let plan = FitnessPlanExperiencePolicy.nextSession(in: viewModel.plans) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.title).font(.title3.bold())
                        Text(planSummary(plan)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            primaryAction(for: plan)
                            moveButton(plan)
                        }
                        VStack(spacing: 8) {
                            primaryAction(for: plan)
                            moveButton(plan)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Nothing queued", systemImage: "calendar.badge.plus",
                        description: Text("Tap an activity above whenever you want one.")
                    )
                }
            }
            Section("This week") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(FitnessPlanExperiencePolicy.week(), id: \.self) { day in weekDay(day) }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            Section {
                DisclosureGroup("Goals and training tools") {
                    NavigationLink {
                        FitnessPlanManageView(viewModel: viewModel)
                    } label: {
                        Label("Goals, gear and connections", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        FitnessRunPlansView()
                    } label: {
                        Label("Structured running plans", systemImage: "figure.run")
                    }
                    NavigationLink {
                        FitnessStrengthView()
                    } label: {
                        Label("Strength workouts", systemImage: "dumbbell")
                    }
                    ForEach(viewModel.programmes) { programme in
                        NavigationLink {
                            FitnessProgrammeDetailView(
                                programme: programme,
                                plans: viewModel.plans.filter { $0.trainingProgrammeId == programme.id }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(programme.name)
                                Text(programmeSummary(programme)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("The daily flow stays simple; deeper planning is still here when you need it.")
            }
        }
        .navigationTitle("Sessions")
        .sheet(item: $quickSport) { sport in
            FitnessQuickSessionSheet(sport: sport, viewModel: viewModel)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .plan: FitnessPlanSheet(viewModel: viewModel, seed: strengthSeed)
            case .manage:
                if let managedPlan { FitnessPlannedSessionEditorSheet(viewModel: viewModel, session: managedPlan) }
            }
        }
        .task {
            async let home: Void = viewModel.loadHome()
            async let stravaLoad: Void = strava.load()
            _ = await (home, stravaLoad)
        }
        .refreshable {
            async let home: Void = viewModel.loadHome(refresh: true)
            async let stravaLoad: Void = strava.load()
            _ = await (home, stravaLoad)
        }
    }

    private func quickSportButton(_ sport: FitnessQuickSport) -> some View {
        Button {
            HapticManager.selection()
            if sport.id == "strength" {
                Task {
                    await viewModel.loadCreateSupport()
                    strengthSeed = nil
                    sheet = .plan
                }
            } else {
                quickSport = sport
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: sport.systemImage)
                    .font(.title3).foregroundStyle(.tint).frame(width: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sport.title.localized).font(.headline).foregroundStyle(.primary)
                    Text(sport.detail.localized).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.16)) }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sport.title.localized)
        .accessibilityHint(sport.detail.localized)
    }

    private var stravaSection: some View {
        Section("Log from Strava") {
            if strava.status == nil {
                if strava.isWorking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking Strava…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(
                        (strava.errorMessage == nil
                            ? "Check the connection before importing an activity."
                            : "Strava connection could not be checked.").localized
                    )
                    .foregroundStyle(.secondary)
                    Button(
                        (strava.errorMessage == nil ? "Check Strava connection" : "Try again").localized,
                        systemImage: "arrow.clockwise"
                    ) {
                        Task { await strava.load() }
                    }
                }
            } else if strava.isConnected {
                Text(
                    (strava.status?.status == .providerDown
                        ? "Strava was unavailable last time. Your connection is safe; try the same pull again."
                        : "Bring in completed activities without typing them again.").localized
                )
                .foregroundStyle(.secondary)
                Button {
                    Task {
                        if await strava.syncActivities() > 0 {
                            do {
                                try await FitnessSyncService.shared.syncNow()
                            } catch is CancellationError {
                                return
                            } catch {
                                viewModel.errorMessage = "Strava activities were imported; Fitness will retry syncing automatically."
                            }
                            await viewModel.loadHome(refresh: true)
                        }
                    }
                } label: {
                    if strava.isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Checking Strava…")
                        }
                    } else {
                        Label(
                            (strava.status?.status == .providerDown ? "Try Strava again" : "Pull latest from Strava").localized,
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                }
                .disabled(strava.isWorking)
            } else {
                Text("Connect once, then a completed run is one tap away.")
                    .foregroundStyle(.secondary)
                Button("Connect Strava", systemImage: "link") { Task { await strava.connect() } }
                    .disabled(strava.isWorking)
            }
            if let message = strava.operationMessage {
                Label(message, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            }
            if let error = strava.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func planSummary(_ plan: FitnessPlannedSession) -> String {
        var parts = [plan.sportKey.capitalized]
        if let start = plan.scheduledStart ?? plan.timeWindowStart {
            parts.append(start.formatted(date: .abbreviated, time: .shortened))
        } else if let date = plan.plannedFor {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let duration = plan.expectedDurationSeconds {
            parts.append(String(format: "%lld min".localized, Int64(duration / 60)))
        }
        if let pace = plan.expectedPaceSecondsPerKilometre {
            parts.append("\(paceText(pace))/km")
        }
        if plan.visibility == "logistics_shared" { parts.append("Visible to family".localized) }
        return parts.joined(separator: " · ")
    }

    private func paceText(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func manage(_ plan: FitnessPlannedSession) {
        managedPlan = plan
        sheet = .manage
    }

    @ViewBuilder private func primaryAction(for plan: FitnessPlannedSession) -> some View {
        if plan.sportKey == "strength" {
            NavigationLink {
                FitnessStrengthView(initialPlanId: plan.id)
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Starts \(plan.title)")
        } else {
            Button {
                manage(plan)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens \(plan.title)")
        }
    }

    private func moveButton(_ plan: FitnessPlannedSession) -> some View {
        Button {
            manage(plan)
        } label: {
            Label("Move", systemImage: "calendar.badge.clock")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!plan.movable)
        .accessibilityHint("Changes the scheduled time for \(plan.title)")
    }

    private func weekDay(_ day: Date) -> some View {
        let sessions = FitnessPlanExperiencePolicy.sessions(on: day, in: viewModel.plans)
        return Button {
            if let first = sessions.first { manage(first) }
        } label: {
            VStack(spacing: 6) {
                Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(.semibold))
                Text(day.formatted(.dateTime.day())).font(.headline.monospacedDigit())
                Circle()
                    .fill(sessions.isEmpty ? Color.clear : Color.accentColor)
                    .frame(width: 7, height: 7)
                    .overlay { if sessions.isEmpty { Circle().stroke(Color.secondary.opacity(0.35)) } }
            }
            .frame(width: 44)
            .frame(minHeight: 72)
            .foregroundStyle(Calendar.current.isDateInToday(day) ? Color.accentColor : Color.primary)
            .background(
                Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .disabled(sessions.isEmpty)
        .accessibilityLabel(
            "\(day.formatted(date:.complete,time:.omitted)), "
                + (sessions.isEmpty ? "no sessions" : "\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
        )
        .accessibilityHint(sessions.isEmpty ? "" : "Opens the first session")
    }

    private func programmeSummary(_ programme: FitnessTrainingProgrammeDTO) -> String {
        let linked = viewModel.plans.filter { $0.trainingProgrammeId == programme.id }
        let remaining = linked.filter(\.isStartable).count
        if remaining > 0 { return "\(remaining) session\(remaining == 1 ? "" : "s") ahead" }
        return programme.purpose ?? "Open programme"
    }
}

private struct FitnessQuickSessionSheet: View {
    let sport: FitnessQuickSport
    @ObservedObject var viewModel: FitnessTrainingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var moment: FitnessQuickSessionMoment = .now
    @State private var selectedSportKey: String
    @State private var scheduledAt = Date().addingTimeInterval(3_600)
    @State private var finishedAt = Date()
    @State private var durationMinutes = ""
    @State private var distanceKilometres = ""
    @State private var runTarget: FitnessQuickRunTarget = .none
    @State private var targetMinutes = ""
    @State private var targetSeconds = ""
    @State private var paceMinutes = ""
    @State private var paceSeconds = ""
    @State private var detailsOpen = false
    @State private var title = ""
    @State private var goalId = ""
    @State private var programmeId = ""
    @State private var movable = true

    init(sport: FitnessQuickSport, viewModel: FitnessTrainingViewModel) {
        self.sport = sport
        self.viewModel = viewModel
        _selectedSportKey = State(initialValue: sport.id == "other" ? "hiking" : sport.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                if sport.id == "other" {
                    Section("Activity") {
                        Picker("Activity", selection: $selectedSportKey) {
                            ForEach(otherSports) { option in Text(option.displayName).tag(option.key) }
                        }
                    }
                }
                Section("When?") {
                    Picker("When is this session?", selection: $moment) {
                        ForEach(FitnessQuickSessionMoment.allCases) { value in Text(value.title).tag(value) }
                    }
                    .pickerStyle(.segmented)
                    Text(moment.detail).font(.footnote).foregroundStyle(.secondary)
                    if moment == .later {
                        DatePicker("Starts", selection: $scheduledAt, in: Date()...)
                    } else if moment == .done {
                        DatePicker("Finished", selection: $finishedAt, in: ...Date())
                    }
                }
                Section(moment == .done ? "What did you do?" : "Useful targets") {
                    if moment == .done {
                        TextField("Minutes", text: $durationMinutes)
                            .keyboardType(.decimalPad)
                    } else if selectedSportKey != "running" {
                        TextField("Duration in minutes (optional)", text: $durationMinutes)
                            .keyboardType(.decimalPad)
                    }
                    TextField("Distance in km (optional)", text: $distanceKilometres)
                        .keyboardType(.decimalPad)
                }
                if moment != .done, selectedSportKey == "running" {
                    Section("Want a target?") {
                        Picker("Run target", selection: $runTarget) {
                            ForEach(FitnessQuickRunTarget.allCases) { value in Text(value.title).tag(value) }
                        }
                        .pickerStyle(.segmented)
                        if runTarget == .none {
                            Text("Leave it open for an easy, unstructured run.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if runTarget == .time {
                            clockFields(minutes: $targetMinutes, seconds: $targetSeconds, suffix: nil)
                        } else {
                            clockFields(minutes: $paceMinutes, seconds: $paceSeconds, suffix: "per km")
                        }
                    }
                }
                Section {
                    DisclosureGroup("More details", isExpanded: $detailsOpen) {
                        TextField("Name (optional)", text: $title)
                        Picker("Goal (optional)", selection: $goalId) {
                            Text("No goal").tag("")
                            ForEach(viewModel.goals) { Text($0.title).tag($0.id) }
                        }
                        if moment != .done {
                            Picker("Programme (optional)", selection: $programmeId) {
                                Text("No programme").tag("")
                                ForEach(viewModel.programmes) { Text($0.name).tag($0.id) }
                            }
                            if moment == .later {
                                Toggle("HausKlar may suggest moving this", isOn: $movable)
                            }
                        }
                    }
                } footer: {
                    Text("A name, goal and programme are optional. HausKlar already knows enough to save the session.")
                }
                if let error = viewModel.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle(displaySportName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) { Task { await save() } }
                        .disabled(!isValid || viewModel.isSavingQuickSession)
                }
            }
            .task {
                if sport.id == "other" {
                    await viewModel.loadQuickDetails(includeGoals: false, includeSports: true)
                }
            }
            .onChange(of: detailsOpen) { _, open in
                if open { Task { await viewModel.loadQuickDetails() } }
            }
        }
    }

    private var otherSports: [FitnessRegisteredSport] {
        let loaded = viewModel.registeredSports.filter { !["running", "strength"].contains($0.key) }
        if !loaded.isEmpty { return loaded }
        return [
            .init(key: "walking", displayName: "Walk"),
            .init(key: "cycling", displayName: "Ride"),
            .init(key: "hiking", displayName: "Hike"),
            .init(key: "swimming_pool", displayName: "Pool swimming"),
            .init(key: "rowing_indoor", displayName: "Indoor rowing"),
            .init(key: "yoga", displayName: "Yoga"),
        ]
    }

    private var displaySportName: String {
        if let option = otherSports.first(where: { $0.key == selectedSportKey }) { return option.displayName }
        return switch selectedSportKey {
        case "running": "Run"
        case "walking": "Walk"
        case "cycling": "Ride"
        default: selectedSportKey.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var saveTitle: String {
        if viewModel.isSavingQuickSession { return "Saving…" }
        return switch moment {
        case .now: "Add for now"
        case .later: "Add to my week"
        case .done: "Log \(displaySportName.lowercased())"
        }
    }

    private var distanceMetres: Double? {
        positive(distanceKilometres).map { $0 * 1_000 }
    }
    private var enteredDurationSeconds: Int? {
        positive(durationMinutes).map { Int(($0 * 60).rounded()) }
    }
    private var targetTimeSeconds: Int? { clockSeconds(targetMinutes, targetSeconds) }
    private var targetPaceSeconds: Int? { clockSeconds(paceMinutes, paceSeconds) }
    private var plannedDurationSeconds: Int? {
        if selectedSportKey == "running", runTarget == .time { return targetTimeSeconds }
        if selectedSportKey == "running", runTarget == .pace,
            let pace = targetPaceSeconds, let distance = distanceMetres
        {
            return Int((Double(pace) * distance / 1_000).rounded())
        }
        return enteredDurationSeconds
    }
    private var isValid: Bool {
        if !distanceKilometres.isEmpty, distanceMetres == nil { return false }
        if !durationMinutes.isEmpty, enteredDurationSeconds == nil { return false }
        if moment == .done { return enteredDurationSeconds != nil }
        if selectedSportKey == "running", runTarget == .time { return targetTimeSeconds != nil }
        if selectedSportKey == "running", runTarget == .pace { return targetPaceSeconds != nil }
        return true
    }

    @ViewBuilder private func clockFields(
        minutes: Binding<String>, seconds: Binding<String>, suffix: String?
    ) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            TextField("Minutes", text: minutes).keyboardType(.numberPad)
            Text(":").font(.headline.monospacedDigit())
            TextField("Seconds", text: seconds).keyboardType(.numberPad)
            if let suffix { Text(suffix).foregroundStyle(.secondary) }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func save() async {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if moment == .done, let duration = enteredDurationSeconds {
            let payload = FitnessManualActivityPayload(
                id: UUID().uuidString, sportKey: selectedSportKey,
                title: cleanTitle.isEmpty ? nil : cleanTitle,
                startedAtUtc: finishedAt.addingTimeInterval(-Double(duration)),
                localTimezone: TimeZone.current.identifier, durationS: Double(duration),
                distanceM: distanceMetres, sessionRpe: nil, workoutClassification: nil,
                notes: nil, estimateEnergy: true
            )
            if await viewModel.logQuickSession(payload: payload, sportName: displaySportName) { dismiss() }
            return
        }
        let start = moment == .now ? Date() : scheduledAt
        let pace =
            selectedSportKey == "running" && runTarget == .pace
            ? targetPaceSeconds.map(Double.init) : nil
        if await viewModel.createQuickSession(
            sportKey: selectedSportKey, title: cleanTitle.isEmpty ? displaySportName : cleanTitle,
            scheduledStart: start, expectedDurationSeconds: plannedDurationSeconds,
            expectedDistanceMetres: distanceMetres, expectedPaceSecondsPerKilometre: pace,
            status: moment == .now ? "accepted" : "scheduled",
            movable: moment == .later ? movable : false,
            programmeId: programmeId.isEmpty ? nil : programmeId,
            primaryGoalId: goalId.isEmpty ? nil : goalId
        ) {
            dismiss()
        }
    }

    private func positive(_ value: String) -> Double? {
        guard !value.isEmpty, let parsed = Double(value.replacingOccurrences(of: ",", with: ".")),
            parsed.isFinite, parsed > 0
        else { return nil }
        return parsed
    }

    private func clockSeconds(_ minutes: String, _ seconds: String) -> Int? {
        guard let minuteValue = Int(minutes.isEmpty ? "0" : minutes),
            let secondValue = Int(seconds.isEmpty ? "0" : seconds),
            minuteValue >= 0, (0...59).contains(secondValue)
        else { return nil }
        let total = minuteValue * 60 + secondValue
        return total > 0 ? total : nil
    }
}

private struct FitnessProgrammeDetailView: View {
    let programme: FitnessTrainingProgrammeDTO
    let plans: [FitnessPlannedSession]

    var body: some View {
        List {
            Section {
                Text(programme.name).font(.title2.bold())
                if let purpose = programme.purpose { Text(purpose).foregroundStyle(.secondary) }
                LabeledContent("Dates", value: dateRange)
            }
            Section("Sessions") {
                if plans.isEmpty { Text("No sessions have been added yet.").foregroundStyle(.secondary) }
                ForEach(plans.sorted { planDate($0) < planDate($1) }) { plan in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.title)
                        Text(planDate(plan).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Continue") {
                NavigationLink {
                    FitnessRunPlansView()
                } label: {
                    Label("Running plans", systemImage: "figure.run")
                }
                NavigationLink {
                    FitnessStrengthView()
                } label: {
                    Label("Strength workouts", systemImage: "dumbbell")
                }
            }
        }
        .navigationTitle("Programme")
    }

    private func planDate(_ plan: FitnessPlannedSession) -> Date {
        plan.scheduledStart ?? plan.timeWindowStart ?? plan.plannedFor ?? .distantFuture
    }

    private var dateRange: String {
        let start = displayDate(programme.startsOn)
        return programme.endsOn.map { "\(start) – \(displayDate($0))" } ?? "From \(start)"
    }

    private func displayDate(_ value: String) -> String {
        FitnessDatabase.date(value)?.formatted(date: .abbreviated, time: .omitted) ?? value
    }
}

private struct FitnessPlanManageView: View {
    @ObservedObject var viewModel: FitnessTrainingViewModel
    @State private var sheet: Sheet?
    private enum Sheet: Identifiable {
        case goal, phase, gear
        var id: String { String(describing: self) }
    }

    var body: some View {
        List {
            Section("What do you want to improve?") {
                ForEach(viewModel.goals) { goal in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(goal.title)
                        if let value = goal.targetValue {
                            Text("\(value.formatted()) \(goal.unit ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Choose a goal", systemImage: "plus.circle") { sheet = .goal }
            }
            Section("Training phases") {
                ForEach(viewModel.phases) { phase in
                    LabeledContent(phase.name, value: human(phase.phaseType))
                }
                Button("Add training phase", systemImage: "plus.circle") { sheet = .phase }
            }
            Section("Gear") {
                ForEach(viewModel.gear.filter { $0.active ?? true }) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.name)
                            if item.defaultForSportKey == "running" {
                                Text("Running default").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text([item.brand, item.model, human(item.gearTypeKey)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Use for running", systemImage: "figure.run") {
                            Task { await viewModel.setDefaultRunningGear(item) }
                        }
                        Button("Retire", systemImage: "archivebox", role: .destructive) {
                            Task { await viewModel.retireGear(item) }
                        }
                    }
                }
                if viewModel.gear.isEmpty { Text("No gear added yet.").foregroundStyle(.secondary) }
                Button("Add gear", systemImage: "plus.circle") { sheet = .gear }
            }
            Section("Connections") {
                NavigationLink {
                    FitnessConnectionsView(plans: viewModel.plans)
                } label: {
                    Label("Apps and devices", systemImage: "link")
                }
            }
        }
        .navigationTitle("Goals and training tools")
        .task { await viewModel.loadManage() }
        .refreshable { await viewModel.loadManage(refresh: true) }
        .sheet(item: $sheet) { value in
            switch value {
            case .goal: FitnessGoalTemplateSheet(viewModel: viewModel)
            case .phase: FitnessPhaseSheet(viewModel: viewModel)
            case .gear: FitnessGearSheet(viewModel: viewModel)
            }
        }
    }

    private func human(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct FitnessGearSheet: View {
    @ObservedObject var viewModel: FitnessTrainingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "running_shoe"
    @State private var brand = ""
    @State private var model = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Gear") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        Text("Running shoes").tag("running_shoe")
                        Text("Bike").tag("bike")
                        Text("Strength gear").tag("strength_equipment")
                        Text("Other").tag("other")
                    }
                    TextField("Brand (optional)", text: $brand)
                    TextField("Model (optional)", text: $model)
                }
                if let error = viewModel.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Add gear")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.createGear(name: name, type: type, brand: brand, model: model) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
                }
            }
        }
    }
}

struct FitnessConnectionsView: View {
    let plans: [FitnessPlannedSession]
    @StateObject private var health = FitnessRecoveryViewModel()
    @StateObject private var measurements = FitnessMeasurementTrendsViewModel()
    @StateObject private var intervals = FitnessIntervalsViewModel()
    @StateObject private var strava = FitnessStravaViewModel()

    var body: some View {
        List {
            Section("Apple Health") {
                Label(health.healthAccess.label, systemImage: "heart.text.square")
                switch health.healthAccess {
                case .notRequested, .needsPermission:
                    Button("Review access") { Task { await health.requestHealthAccess() } }
                case .enabled, .failed:
                    Button("Import latest records") { Task { await health.importHealthNow() } }
                case .unavailable:
                    Text("Apple Health is not available on this device.").foregroundStyle(.secondary)
                }
            }
            Section("Withings") {
                Label(measurements.withingsStatus?.connected == true ? "Connected" : "Not connected", systemImage: "scalemass")
                if measurements.withingsStatus?.connected == true {
                    Button("Import latest measurements") { Task { await measurements.syncWithingsNow() } }
                } else if measurements.withingsStatus?.configured == true {
                    Button("Connect Withings") { Task { await measurements.connectWithings() } }
                }
            }
            FitnessStravaConnectionSection(viewModel: strava)
            FitnessIntervalsConnectionSection(viewModel: intervals, plans: plans)
        }
        .navigationTitle("Apps and devices")
        .task {
            async let healthLoad: Void = health.loadHealthAccess()
            async let measurementLoad: Void = measurements.loadConnectionStatus()
            async let intervalLoad: Void = intervals.load()
            async let stravaLoad: Void = strava.load()
            _ = await (healthLoad, measurementLoad, intervalLoad, stravaLoad)
        }
    }
}

private struct FitnessStravaConnectionSection: View {
    @ObservedObject var viewModel: FitnessStravaViewModel
    @State private var showingDisconnect = false

    var body: some View {
        Section("Strava") {
            if let status = viewModel.status {
                if !status.configured {
                    Label("Strava is not available on this HausKlar server.", systemImage: "gear.badge.xmark")
                        .foregroundStyle(.secondary)
                } else if viewModel.isConnected {
                    Label(
                        status.status == .providerDown ? "Strava was temporarily unavailable" : status.athleteName ?? "Strava connected",
                        systemImage: status.status == .providerDown ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .foregroundStyle(status.status == .providerDown ? Color.orange : Color.green)
                    Text(
                        status.status == .providerDown
                            ? "Your connection is safe. Try importing again when it suits you."
                            : "Completed activities stay private to your account and can be pulled in with one tap."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    Button(
                        status.status == .providerDown ? "Try Strava again" : "Pull latest from Strava",
                        systemImage: "arrow.down.circle.fill"
                    ) {
                        Task { _ = await viewModel.syncActivities() }
                    }
                    .disabled(viewModel.isWorking)
                    Button("Disconnect", role: .destructive) { showingDisconnect = true }
                        .disabled(viewModel.isWorking)
                } else {
                    Text("Connect once, then import completed runs, walks and rides without typing them again.")
                        .foregroundStyle(.secondary)
                    Button(status.status == .reauthRequired ? "Reconnect Strava" : "Connect Strava", systemImage: "link") {
                        Task { await viewModel.connect() }
                    }
                    .disabled(viewModel.isWorking)
                }
            } else if viewModel.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking Strava…").foregroundStyle(.secondary)
                }
            } else {
                Button("Check Strava connection", systemImage: "arrow.clockwise") {
                    Task { await viewModel.load() }
                }
            }
            if let message = viewModel.operationMessage {
                Label(message, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            }
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            }
        }
        .confirmationDialog("Disconnect Strava?", isPresented: $showingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await viewModel.disconnect() } }
            Button("Keep connected", role: .cancel) {}
        } message: {
            Text("Activities already imported into HausKlar remain in your history.")
        }
    }
}

private struct FitnessPlanWorkoutChoice: Identifiable {
    let id: String
    let label: String
}

struct FitnessPlannedSessionEditorSheet: View {
    @ObservedObject var viewModel: FitnessTrainingViewModel
    let session: FitnessPlannedSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FitnessPlannedSessionEditDraft
    @State private var durationMinutes: String
    @State private var distanceKilometres: String
    @State private var paceMinutes: String
    @State private var paceSeconds: String
    @State private var closingAction: String?

    init(viewModel: FitnessTrainingViewModel, session: FitnessPlannedSession) {
        self.viewModel = viewModel
        self.session = session
        _draft = State(initialValue: .init(session: session))
        _durationMinutes = State(initialValue: session.expectedDurationSeconds.map { String(Int(($0 / 60).rounded())) } ?? "")
        _distanceKilometres = State(initialValue: session.expectedDistanceMetres.map { String($0 / 1_000) } ?? "")
        let pace = session.expectedPaceSecondsPerKilometre.map { Int($0.rounded()) }
        _paceMinutes = State(initialValue: pace.map { String($0 / 60) } ?? "")
        _paceSeconds = State(initialValue: pace.map { String($0 % 60) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Title", text: $draft.title)
                    LabeledContent("Status", value: draft.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    Picker("Timing", selection: $draft.precision) {
                        ForEach(FitnessSchedulePrecision.allCases) { value in Text(value.title).tag(value) }
                    }
                    .pickerStyle(.segmented)
                    switch draft.precision {
                    case .exact:
                        DatePicker("Starts", selection: $draft.scheduledStart)
                    case .window:
                        DatePicker("Window starts", selection: $draft.scheduledStart)
                        DatePicker("Window ends", selection: $draft.windowEnd, in: draft.scheduledStart...)
                    case .date:
                        DatePicker("Date", selection: $draft.scheduledDate, displayedComponents: .date)
                    }
                    TextField("Shorten or extend (minutes)", text: $durationMinutes)
                        .keyboardType(.numberPad)
                    if draft.sportKey == "running" {
                        TextField("Expected distance (km)", text: $distanceKilometres)
                            .keyboardType(.decimalPad)
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            TextField("Pace min", text: $paceMinutes).keyboardType(.numberPad)
                            Text(":").font(.headline.monospacedDigit())
                            TextField("Pace sec", text: $paceSeconds).keyboardType(.numberPad)
                            Text("per km").foregroundStyle(.secondary)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Session can move", isOn: $draft.movable)
                    TextField("Reason for placement or change", text: optional($draft.reasonForPlacement), axis: .vertical)
                }
                Section("Links") {
                    Picker("Primary goal", selection: optionalSelection($draft.primaryGoalId)) {
                        Text("No primary goal").tag("")
                        ForEach(viewModel.goals) { Text($0.title).tag($0.id) }
                    }
                    Picker("Programme", selection: optionalSelection($draft.programmeId)) {
                        Text("No programme").tag("")
                        ForEach(viewModel.programmes) { Text($0.name).tag($0.id) }
                    }
                    Picker("Replace workout", selection: optionalSelection($draft.workoutVersionId)) {
                        Text("No structured workout").tag("")
                        ForEach(workoutChoices) { choice in Text(choice.label).tag(choice.id) }
                    }
                    Text("Choosing another workout never changes the accepted workout itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !viewModel.gear.filter({ $0.active ?? true }).isEmpty {
                    Section("Intended gear") {
                        ForEach(viewModel.gear.filter { $0.active ?? true }) { gear in
                            Toggle(gear.name, isOn: gearSelection(gear.id))
                        }
                    }
                }
                Section("Household calendar") {
                    Toggle(
                        "Share logistics only",
                        isOn: Binding(
                            get: { draft.visibility == "logistics_shared" },
                            set: { draft.visibility = $0 ? "logistics_shared" : "private" }
                        ))
                    if draft.visibility == "logistics_shared" {
                        TextField("Shared title", text: optional($draft.sharedTitle))
                        Text(
                            "Only this title and the approved date or time are shared. Workout, route, readiness and health details stay private."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("This session stays on your private Fitness calendar layer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = viewModel.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                Section {
                    if draft.status == "proposed" {
                        Button("Accept plan", systemImage: "checkmark.seal") { Task { await save(status: "accepted") } }
                            .disabled(!isValid || viewModel.isLoading)
                    }
                    Button("Skip this session", systemImage: "forward.end", role: .destructive) {
                        closingAction = "skipped"
                    }
                    .disabled(["skipped", "cancelled"].contains(draft.status) || viewModel.isLoading)
                    Button("Cancel this session", systemImage: "xmark.circle", role: .destructive) {
                        closingAction = "cancelled"
                    }
                    .disabled(draft.status == "cancelled" || viewModel.isLoading)
                } footer: {
                    Text(
                        "Skipping records that you deliberately did not do this session. Cancelling closes the placement without deleting its history."
                    )
                }
            }
            .navigationTitle("Manage session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(status: draft.status) } }
                        .disabled(!isValid || viewModel.isLoading)
                }
            }
        }
        .confirmationDialog(
            closingAction == "skipped" ? "Skip this session?" : "Cancel this session?",
            isPresented: Binding(get: { closingAction != nil }, set: { if !$0 { closingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let closingAction {
                Button(closingAction == "skipped" ? "Skip session" : "Cancel session", role: .destructive) {
                    Task { await save(status: closingAction) }
                }
            }
            Button("Keep session", role: .cancel) { closingAction = nil }
        } message: {
            Text(
                closingAction == "skipped"
                    ? "The session stays in history with a skipped outcome."
                    : "The session stays in history as cancelled and will no longer be startable.")
        }
    }

    private var workoutChoices: [FitnessPlanWorkoutChoice] {
        viewModel.definitions.compactMap { definition in
            guard definition.sportKey == draft.sportKey,
                let version = definition.currentVersion ?? definition.version,
                version.acceptedAt != nil
            else { return nil }
            return .init(id: version.id, label: definition.name)
        }
    }

    private var isValid: Bool {
        let titleOK = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let durationOK = durationMinutes.isEmpty || Int(durationMinutes).map { $0 >= 0 } == true
        let distanceOK = distanceKilometres.isEmpty || Double(distanceKilometres).map { $0.isFinite && $0 >= 0 } == true
        let paceOK = paceMinutes.isEmpty && paceSeconds.isEmpty || parsedPace != nil
        let windowOK = draft.precision != .window || draft.windowEnd > draft.scheduledStart
        let sharingOK =
            draft.visibility != "logistics_shared"
            || draft.sharedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return titleOK && durationOK && distanceOK && paceOK && windowOK && sharingOK
    }

    private func save(status: String) async {
        draft.status = status
        draft.expectedDurationSeconds = durationMinutes.isEmpty ? nil : Int(durationMinutes).map { $0 * 60 }
        draft.expectedDistanceMetres = distanceKilometres.isEmpty ? nil : Double(distanceKilometres).map { $0 * 1_000 }
        draft.expectedPaceSecondsPerKilometre = parsedPace.map(Double.init)
        if await viewModel.updatePlannedSession(draft) { dismiss() }
    }

    private var parsedPace: Int? {
        guard let minutes = Int(paceMinutes.isEmpty ? "0" : paceMinutes),
            let seconds = Int(paceSeconds.isEmpty ? "0" : paceSeconds),
            minutes >= 0, (0...59).contains(seconds)
        else { return nil }
        let total = minutes * 60 + seconds
        return total > 0 ? total : nil
    }

    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func optionalSelection(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func gearSelection(_ id: String) -> Binding<Bool> {
        Binding(
            get: { draft.intendedGearIds.contains(id) },
            set: { selected in
                if selected {
                    if !draft.intendedGearIds.contains(id) { draft.intendedGearIds.append(id) }
                } else {
                    draft.intendedGearIds.removeAll { $0 == id }
                }
            }
        )
    }
}

private struct FitnessPhaseSheet: View {
    @ObservedObject var viewModel: FitnessTrainingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "strength_emphasis"
    @State private var goalId = ""
    private let types = ["strength_emphasis", "fat_loss", "maintenance", "recomposition", "recovery", "return_to_training", "custom"]
    var body: some View {
        NavigationStack {
            Form {
                TextField("Phase name", text: $name)
                Picker("Type", selection: $type) {
                    ForEach(types, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                }
                Picker("Primary goal", selection: $goalId) {
                    Text("None").tag("")
                    ForEach(viewModel.goals) { Text($0.title).tag($0.id) }
                }
            }
            .navigationTitle("Training phase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.createPhase(name: name, type: type, primaryGoalId: goalId.isEmpty ? nil : goalId) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

private struct FitnessPlanSheet: View {
    @ObservedObject var viewModel: FitnessTrainingViewModel
    let seed: FitnessSavedStrengthWorkout?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FitnessStrengthPlanDraft
    @State private var scheduleMode = "exact"

    init(viewModel: FitnessTrainingViewModel, seed: FitnessSavedStrengthWorkout? = nil) {
        self.viewModel = viewModel
        self.seed = seed
        if let seed {
            _draft = State(
                initialValue: FitnessStrengthPlanDraft(
                    definitionId: seed.definitionId, name: seed.name, title: seed.title,
                    purpose: seed.purpose, exercises: seed.exercises, scheduledStart: Date(),
                    expectedDurationSeconds: 3_600
                ))
        } else {
            _draft = State(initialValue: FitnessStrengthPlanDraft(scheduledStart: Date()))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(seed == nil ? "Reusable workout" : "Updated workout details") {
                    TextField("Workout name", text: $draft.name)
                    TextField("Calendar title", text: $draft.title)
                    TextField("Description", text: optional($draft.description), axis: .vertical)
                    TextField("Purpose", text: optional($draft.purpose), axis: .vertical)
                    if seed != nil {
                        Label("The current workout stays unchanged; saving creates an updated copy.", systemImage: "lock.example_567dc489")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach($draft.exercises) { $item in
                        NavigationLink {
                            FitnessPlanExerciseEditor(item: $item, viewModel: viewModel)
                        } label: {
                            let exercise = viewModel.exercises.first { $0.id == item.exerciseId }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exercise?.name ?? "Exercise")
                                Text("\(item.sets.count) prescribed sets · explicit setup")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { draft.exercises.remove(atOffsets: $0) }
                    .onMove { draft.exercises.move(fromOffsets: $0, toOffset: $1) }
                    Menu("Add exercise", systemImage: "plus") {
                        ForEach(
                            viewModel.exercises.filter { exercise in
                                exercise.active && !draft.exercises.contains { $0.exerciseId == exercise.id }
                            }
                        ) { exercise in
                            Button(exercise.name) { addExercise(exercise) }
                        }
                    }
                } header: {
                    Text("Exercises")
                }
                Section("Placement") {
                    Picker("When", selection: $scheduleMode) {
                        Text("Decide later").tag("none")
                        Text("Exact start").tag("exact")
                        Text("Time window").tag("window")
                    }
                    if scheduleMode == "exact" {
                        DatePicker(
                            "Start",
                            selection: Binding(
                                get: { draft.scheduledStart ?? Date() }, set: { draft.scheduledStart = $0 }
                            ))
                    } else if scheduleMode == "window" {
                        DatePicker(
                            "Window starts",
                            selection: Binding(
                                get: { draft.timeWindowStart ?? Date() }, set: { draft.timeWindowStart = $0 }
                            ))
                        DatePicker(
                            "Window ends",
                            selection: Binding(
                                get: { draft.timeWindowEnd ?? Date().addingTimeInterval(3_600) },
                                set: { draft.timeWindowEnd = $0 }
                            ))
                    }
                    Stepper(
                        "Expected duration \((draft.expectedDurationSeconds ?? 0)/60) min",
                        value: Binding(get: { draft.expectedDurationSeconds ?? 0 }, set: { draft.expectedDurationSeconds = $0 }),
                        in: 0...14_400, step: 300
                    )
                    Toggle("Can be moved", isOn: $draft.movable)
                    TextField("Note (optional)", text: optional($draft.reasonForPlacement), axis: .vertical)
                }
                Section("Programme and goals") {
                    Picker("Programme", selection: optional($draft.trainingProgrammeId)) {
                        Text("None").tag("")
                        ForEach(viewModel.programmes) { Text($0.name).tag($0.id) }
                    }
                    Picker("Primary goal", selection: optional($draft.primaryGoalId)) {
                        Text("None").tag("")
                        ForEach(viewModel.goals) { Text($0.title).tag($0.id) }
                    }
                    ForEach(viewModel.goals.filter { $0.id != draft.primaryGoalId }) { goal in
                        Toggle(goal.title, isOn: membership(goal.id, in: $draft.secondaryGoalIds))
                    }
                }
                Section("Gear") {
                    ForEach(viewModel.gear.filter { $0.active ?? true }) { gear in
                        Toggle(gear.name, isOn: membership(gear.id, in: $draft.intendedGearIds))
                    }
                    if viewModel.gear.isEmpty { Text("No active gear").foregroundStyle(.secondary) }
                }
                Section("Calendar privacy") {
                    Picker("Visibility", selection: $draft.visibility) {
                        Text("Private").tag("private")
                        Text("Share logistics only").tag("logistics_shared")
                    }
                    if draft.visibility == "logistics_shared" {
                        TextField("Shared calendar title", text: optional($draft.sharedTitle))
                        Text("Only the logistics title is shared; exercises, sets and health context remain private.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = viewModel.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Strength plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish & accept") {
                        Task {
                            normalizeSchedule()
                            if await viewModel.createStrengthPlan(draft) { dismiss() }
                        }
                    }
                    .disabled(!isValid)
                }
            }
            .task {
                for exercise in draft.exercises { await viewModel.loadSetups(for: exercise.exerciseId) }
            }
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.exercises.isEmpty
            && draft.exercises.allSatisfy { !$0.setupId.isEmpty && !$0.sets.isEmpty }
            && (draft.visibility != "logistics_shared"
                || draft.sharedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
    private func addExercise(_ exercise: FitnessExercise) {
        Task {
            await viewModel.loadSetups(for: exercise.id)
            guard let setup = viewModel.setups[exercise.id]?.first else { return }
            draft.exercises.append(.init(exerciseId: exercise.id, setupId: setup.id))
        }
    }
    private func normalizeSchedule() {
        switch scheduleMode {
        case "none":
            draft.scheduledStart = nil
            draft.timeWindowStart = nil
            draft.timeWindowEnd = nil
        case "exact":
            draft.timeWindowStart = nil
            draft.timeWindowEnd = nil
        default: draft.scheduledStart = nil
        }
    }
    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
    private func membership(_ value: String, in values: Binding<[String]>) -> Binding<Bool> {
        Binding(
            get: { values.wrappedValue.contains(value) },
            set: { enabled in
                if enabled {
                    if !values.wrappedValue.contains(value) { values.wrappedValue.append(value) }
                } else {
                    values.wrappedValue.removeAll { $0 == value }
                }
            }
        )
    }
}

private struct FitnessPlanExerciseEditor: View {
    @Binding var item: FitnessStrengthPlanExerciseDraft
    @ObservedObject var viewModel: FitnessTrainingViewModel

    private var exercise: FitnessExercise? { viewModel.exercises.first { $0.id == item.exerciseId } }
    private var setups: [FitnessExerciseSetup] { viewModel.setups[item.exerciseId] ?? [] }

    var body: some View {
        Form {
            Section("Exercise details") {
                LabeledContent("Exercise", value: exercise?.name ?? "Unavailable")
                Picker("Setup", selection: $item.setupId) {
                    ForEach(setups.filter { $0.active }) { setup in Text(setup.name).tag(setup.id) }
                }
                TextField("Superset group (optional)", text: optional($item.supersetGroupKey))
                TextField("Exercise notes", text: optional($item.notes), axis: .vertical)
            }
            Section("Allowed substitutions") {
                ForEach(viewModel.exercises.filter { $0.active && $0.id != item.exerciseId }) { exercise in
                    Toggle(exercise.name, isOn: membership(exercise.id))
                }
            }
            Section("Ordered set prescription") {
                ForEach($item.sets) { $set in
                    NavigationLink {
                        FitnessPlanSetEditor(set: $set)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(set.role.title) · \(set.structure.title)")
                            Text(prescription(set)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { item.sets.remove(atOffsets: $0) }
                .onMove { item.sets.move(fromOffsets: $0, toOffset: $1) }
                Button("Add set", systemImage: "plus") { item.sets.append(.init()) }
            }
        }
        .navigationTitle(exercise?.name ?? "Exercise")
        .task { await viewModel.loadSetups(for: item.exerciseId) }
    }

    private func prescription(_ set: FitnessStrengthPlanSetDraft) -> String {
        var parts: [String] = []
        if let low = set.repsMin { parts.append(low == set.repsMax ? "\(low) reps" : "\(low)–\(set.repsMax.map(String.init) ?? "?") reps") }
        if let low = set.loadMin {
            parts.append(
                low == set.loadMax
                    ? "\(low.formatted()) \(set.loadUnit ?? "")"
                    : "\(low.formatted())–\(set.loadMax?.formatted() ?? "?") \(set.loadUnit ?? "")")
        }
        if let rest = set.restSeconds { parts.append("\(rest)s rest") }
        return parts.isEmpty ? "Open prescription" : parts.joined(separator: " · ")
    }
    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
    private func membership(_ value: String) -> Binding<Bool> {
        Binding(
            get: { item.substitutionExerciseIds.contains(value) },
            set: { enabled in
                if enabled {
                    if !item.substitutionExerciseIds.contains(value) { item.substitutionExerciseIds.append(value) }
                } else {
                    item.substitutionExerciseIds.removeAll { $0 == value }
                }
            }
        )
    }
}

private struct FitnessPlanSetEditor: View {
    @Binding var set: FitnessStrengthPlanSetDraft
    var body: some View {
        Form {
            Picker("Role", selection: $set.role) {
                ForEach(FitnessSetRole.allCases) { Text($0.title).tag($0) }
            }
            Picker("Structure", selection: $set.structure) {
                ForEach(FitnessSetStructure.allCases) { Text($0.title).tag($0) }
            }
            Stepper("Components \(set.componentCount)", value: $set.componentCount, in: 1...20)
            Section("Repetitions") {
                TextField("Minimum", value: $set.repsMin, format: .number).keyboardType(.numberPad)
                TextField("Maximum", value: $set.repsMax, format: .number).keyboardType(.numberPad)
                Toggle("AMRAP", isOn: $set.isAMRAP)
            }
            Section("Load") {
                TextField("Minimum", value: $set.loadMin, format: .number).keyboardType(.decimalPad)
                TextField("Maximum", value: $set.loadMax, format: .number).keyboardType(.decimalPad)
                TextField("Unit", text: optional($set.loadUnit))
            }
            Section("Effort") {
                TextField("RPE minimum", value: $set.rpeMin, format: .number).keyboardType(.decimalPad)
                TextField("RPE maximum", value: $set.rpeMax, format: .number).keyboardType(.decimalPad)
                TextField("RIR minimum", value: $set.rirMin, format: .number).keyboardType(.decimalPad)
                TextField("RIR maximum", value: $set.rirMax, format: .number).keyboardType(.decimalPad)
            }
            Section("Rest and notes") {
                TextField("Rest seconds", value: $set.restSeconds, format: .number).keyboardType(.numberPad)
                TextField("Notes", text: optional($set.notes), axis: .vertical)
            }
        }
        .navigationTitle("Set prescription")
    }
    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

private struct LegacyFitnessStrengthView: View {
    @StateObject private var viewModel = LegacyFitnessStrengthViewModel()
    @State private var sheet: Sheet?
    @State private var selectedExercise: FitnessSessionExercise?
    @State private var selectedDropGroup: FitnessSetGroup?
    private enum Sheet: Identifiable {
        case start, library, finish
        var id: String { String(describing: self) }
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            if let active = viewModel.activeWorkout {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(active.title).font(.title3.bold())
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(context.date.timeIntervalSince(active.startedAt).formattedWorkoutDuration)
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let readiness = active.readiness { Text("Readiness \(readiness)/5").font(.caption).foregroundStyle(.secondary) }
                    }
                    if active.readiness == nil {
                        Menu("Add retrospective readiness") {
                            ForEach(1...5, id: \.self) { value in Button("\(value)/5") { Task { await viewModel.addLateReadiness(value) } }
                            }
                        }
                    }
                } header: {
                    Text("Active workout")
                }

                ForEach(viewModel.workoutExercises) { item in
                    Section {
                        ForEach(item.groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(group.group.role.title) · \(group.group.structure.title)").font(.subheadline.weight(.medium))
                                    Spacer()
                                    if group.group.status != .completed {
                                        Text(group.group.status.title).font(.caption.bold()).foregroundStyle(.secondary)
                                    }
                                    if group.group.isAMRAP { Text("AMRAP").font(.caption.bold()).foregroundStyle(.orange) }
                                }
                                ForEach(group.components) { component in
                                    Text(setDescription(component)).font(.body.monospacedDigit())
                                }
                                Button("Add drop component") { selectedDropGroup = group.group }
                                    .font(.caption)
                            }
                        }
                        Button("Add set") { selectedExercise = item.exercise }
                    } header: {
                        VStack(alignment: .leading) {
                            Text(item.exercise.exerciseName)
                            Text(item.exercise.setupName).font(.caption).textCase(nil)
                        }
                    }
                }
                Section {
                    Button("Add exercise") { sheet = .library }
                    Button("Finish workout") { sheet = .finish }.foregroundStyle(.indigo)
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "No active workout",
                        systemImage: "dumbbell",
                        description: Text("Start blank or use a planned session. Your workout is saved after every action.")
                    )
                    Button("Start workout") { sheet = .start }.buttonStyle(.borderedProminent)
                }
                Section("Exercise library") {
                    if viewModel.exercises.isEmpty {
                        Text("Sync for the starter catalogue, or create a custom exercise offline.").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.exercises.prefix(12)) { exercise in
                        LabeledContent(exercise.name, value: exercise.category)
                    }
                }
            }
        }
        .navigationTitle("Strength")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if viewModel.activeWorkout == nil { Button("Start workout", systemImage: "play.fill") { sheet = .start } }
                    Button("New custom exercise", systemImage: "plus") { sheet = .library }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .start: FitnessStartWorkoutSheet(viewModel: viewModel)
            case .library: FitnessExercisePickerSheet(viewModel: viewModel, addsToWorkout: viewModel.activeWorkout != nil)
            case .finish: FitnessFinishWorkoutSheet(viewModel: viewModel)
            }
        }
        .sheet(item: $selectedExercise) { FitnessAddSetSheet(exercise: $0, viewModel: viewModel) }
        .sheet(item: $selectedDropGroup) { FitnessDropSetSheet(group: $0, viewModel: viewModel) }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    private func setDescription(_ component: FitnessSetComponent) -> String {
        if component.status == .skipped { return "Skipped" }
        let load = component.loadKg.map { String(format: "%.1f kg", $0) } ?? "Bodyweight"
        let reps = component.reps.map { " × \($0)" } ?? ""
        let effort =
            component.rir.map { " · RIR \(String(format: "%.0f", $0))" }
            ?? component.rpe.map { " · RPE \(String(format: "%.1f", $0))" }
            ?? ""
        return (component.status == .partial ? "Partial · " : "") + load + reps + effort
    }
}

extension TimeInterval {
    fileprivate var formattedWorkoutDuration: String {
        let minutes = max(0, Int(self) / 60)
        return "\(minutes / 60)h \(minutes % 60)m elapsed"
    }
}

private struct FitnessStartWorkoutSheet: View {
    @ObservedObject var viewModel: LegacyFitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Strength workout"
    @State private var planId = ""
    @State private var readiness = 3
    @State private var includeReadiness = true
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                Picker("Plan", selection: $planId) {
                    Text("Blank workout").tag("")
                    ForEach(viewModel.plans.filter { !$0.isCompleted }) { Text($0.title).tag($0.id) }
                }
                Toggle("Record readiness", isOn: $includeReadiness)
                if includeReadiness { Stepper("Readiness \(readiness)/5", value: $readiness, in: 1...5) }
            }
            .navigationTitle("Start workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let plan = viewModel.plans.first { $0.id == planId }
                        Task {
                            await viewModel.start(title: plan?.title ?? title, plan: plan, readiness: includeReadiness ? readiness : nil)
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    }
                }
            }
        }
    }
}

private struct FitnessExercisePickerSheet: View {
    @ObservedObject var viewModel: LegacyFitnessStrengthViewModel
    let addsToWorkout: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = "Strength"
    @State private var mode = FitnessLoadMode.total
    var body: some View {
        NavigationStack {
            List {
                if addsToWorkout {
                    Section("Add existing") {
                        ForEach(viewModel.exercises) { exercise in
                            Button(exercise.name) {
                                Task {
                                    await viewModel.addExercise(exercise)
                                    if viewModel.errorMessage == nil { dismiss() }
                                }
                            }
                        }
                    }
                }
                Section("Create custom exercise") {
                    TextField("Name", text: $name)
                    TextField("Category", text: $category)
                    Picker("Load entry", selection: $mode) { ForEach(FitnessLoadMode.allCases) { Text($0.title).tag($0) } }
                    Button("Create") {
                        Task { if await viewModel.createExercise(name: name, category: category, mode: mode) { dismiss() } }
                    }
                    .disabled(name.isEmpty)
                }
            }
            .navigationTitle(addsToWorkout ? "Add exercise" : "Exercise library")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct FitnessAddSetSheet: View {
    let exercise: FitnessSessionExercise
    @ObservedObject var viewModel: LegacyFitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var load = ""
    @State private var reps = ""
    @State private var rir = ""
    @State private var rpe = ""
    @State private var role = FitnessSetRole.working
    @State private var structure = FitnessSetStructure.straight
    @State private var isAMRAP = false
    @State private var failure = FitnessFailureType.unknown
    @State private var groupStatus = FitnessSetStatus.completed
    @State private var componentStatus = FitnessComponentStatus.completed
    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Exercise", value: exercise.exerciseName)
                LabeledContent("Setup", value: exercise.setupName)
                Picker("Role", selection: $role) { ForEach(FitnessSetRole.allCases) { Text($0.title).tag($0) } }
                Picker("Structure", selection: $structure) { ForEach(FitnessSetStructure.allCases) { Text($0.title).tag($0) } }
                Picker("Set status", selection: $groupStatus) {
                    ForEach([FitnessSetStatus.completed, .partial, .skipped]) { Text($0.title).tag($0) }
                }
                Picker("Performed work", selection: $componentStatus) {
                    ForEach(FitnessComponentStatus.allCases) { Text($0.title).tag($0) }
                }
                Toggle("AMRAP", isOn: $isAMRAP)
                TextField("Load kg", text: $load).keyboardType(.decimalPad)
                TextField("Reps", text: $reps).keyboardType(.numberPad)
                TextField("RIR (optional)", text: $rir).keyboardType(.decimalPad)
                TextField("RPE (optional)", text: $rpe).keyboardType(.decimalPad)
                Picker("Failure", selection: $failure) { ForEach(FitnessFailureType.allCases) { Text($0.title).tag($0) } }
            }
            .navigationTitle("Add set")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.addSet(
                                to: exercise, role: role, structure: structure, isAMRAP: isAMRAP,
                                groupStatus: groupStatus, componentStatus: componentStatus,
                                loadKg: Double(load), reps: Int(reps), rir: Double(rir), rpe: Double(rpe), failure: failure
                            )
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(componentStatus != .skipped && Int(reps) == nil && Double(load) == nil)
                }
            }
        }
    }
}

private struct FitnessDropSetSheet: View {
    let group: FitnessSetGroup
    @ObservedObject var viewModel: LegacyFitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var load = ""
    @State private var reps = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Drop load kg", text: $load).keyboardType(.decimalPad)
                TextField("Reps", text: $reps).keyboardType(.numberPad)
            }
            .navigationTitle("Drop component")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.addDrop(to: group, loadKg: Double(load), reps: Int(reps))
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    }
                }
            }
        }
    }
}

private struct FitnessFinishWorkoutSheet: View {
    @ObservedObject var viewModel: LegacyFitnessStrengthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var rpe = ""
    @State private var performance = 3
    @State private var note = ""
    @State private var addIssue = false
    @State private var issue = NewBodyIssue(
        issueTypeKey: "discomfort", bodyLocationKey: "", side: "not_applicable",
        severity: 3, timing: "during", changedSession: false, sessionChangeKey: "none", note: nil
    )
    var body: some View {
        NavigationStack {
            Form {
                TextField("Session RPE (optional)", text: $rpe).keyboardType(.decimalPad)
                Stepper("Performance \(performance)/5", value: $performance, in: 1...5)
                TextField("Note (optional)", text: $note, axis: .vertical)
                Toggle("Record a body issue", isOn: $addIssue)
                if addIssue { FitnessBodyIssueFields(issue: $issue, locations: FitnessBodyLocation.fallback) }
                Text("HausKlar records training and reminders only; it does not provide medical advice.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Finish workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        Task {
                            if await viewModel.finish(
                                rpe: Double(rpe), performance: performance, note: note,
                                issue: addIssue ? issue : nil
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(addIssue && issue.bodyLocationKey.isEmpty)
                }
            }
        }
    }
}
