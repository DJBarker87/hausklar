import SwiftUI

struct FitnessTodayView: View {
    @StateObject private var viewModel = FitnessHubViewModel()
    @StateObject private var healthViewModel = FitnessTodayHealthViewModel()
    @StateObject private var trainingViewModel = FitnessTrainingViewModel()
    @State private var readiness: Int?
    @State private var readinessPlanId: String?
    @State private var showStrength = false
    @State private var managedPlan: FitnessPlannedSession?

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.plans.isEmpty && viewModel.activeWorkout == nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading today…").foregroundStyle(.secondary)
                    }
                }
            }
            if let error = viewModel.errorMessage ?? healthViewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await reload() } }
                        .disabled(viewModel.isLoading || healthViewModel.isLoading)
                }
            }
            if let action = viewModel.nextAction {
                Section {
                    FitnessNextActionCard(
                        action: action, currentSection: .today, dismiss: viewModel.dismissNextAction,
                        openPlannedSession: { openPlan($0) }, recordReadiness: { showReadiness(for: $0) },
                        handleCurrentSection: { _ in Task { await reload() } }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else if let error = viewModel.nextActionError {
                Section("Next action") {
                    Label("Could not load the current recommendation.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await viewModel.load() } }
                        .accessibilityHint(error)
                }
            }
            if let workout = viewModel.activeWorkout {
                Section("In progress now") {
                    NavigationLink(value: FitnessSection.strength) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Resume \(workout.title)", systemImage: "dumbbell.fill").font(.headline)
                            Text("Active strength workout · separate from the sessions still planned below")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Today’s plan") {
                if viewModel.todayPlans.isEmpty {
                    Text("Nothing is planned for today.").font(.headline)
                    NavigationLink(value: FitnessSection.training) { Label("Plan the next session", systemImage: "calendar.badge.plus") }
                }
                ForEach(viewModel.todayPlans) { plan in
                    VStack(alignment: .leading, spacing: 9) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plan.title).font(.headline)
                            Text(planDetail(plan)).font(.caption).foregroundStyle(.secondary)
                            if let gear = gearLabel(plan) { Label(gear, systemImage: "shoe").font(.caption) }
                            if let issue = viewModel.activeIssues.first {
                                Label(
                                    "Active \(issue.bodyLocationKey.replacingOccurrences(of:"_",with:" ")) issue · \(issue.severity)/10",
                                    systemImage: "bandage"
                                )
                                .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { planActions(plan) }
                            VStack(alignment: .leading, spacing: 8) { planActions(plan) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let plan = readinessPlan {
                    Picker("Readiness", selection: $readiness) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    Text("Choose how ready you feel, then record it. No score is assumed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(readiness.map { "Record readiness \($0) of 5" } ?? "Choose a readiness score", systemImage: "bolt.heart") {
                        guard let readiness else { return }
                        Task { await viewModel.recordReadiness(readiness, for: plan) }
                    }
                    .disabled(viewModel.isLoading || readiness == nil)
                    if viewModel.recordedReadiness[plan.id] != nil {
                        Label("Captured before activity start", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
            Section("Food and recovery") {
                LabeledContent(
                    "Calories", value: position(viewModel.nutritionDay.totals.caloriesKcal, target: viewModel.calorieTarget, unit: "kcal"))
                LabeledContent(
                    "Protein", value: position(viewModel.nutritionDay.totals.proteinG, target: viewModel.proteinTarget, unit: "g"))
                if let average = viewModel.recoverySummary?.sleep.averageDurationS {
                    LabeledContent("Average sleep", value: String(format: "%.1f h", average / 3_600))
                } else if let sleep = healthViewModel.latestSleep {
                    LabeledContent("Latest sleep", value: String(format: "%.1f h", sleep.durationS / 3_600))
                }
                NavigationLink(value: FitnessSection.nutrition) { Label("Log food", systemImage: "fork.knife") }
                NavigationLink(value: FitnessSection.recovery) { Label("Recovery details", systemImage: "waveform.path.ecg") }
            }
        }
        .navigationTitle("Today")
        .navigationDestination(isPresented: $showStrength) { FitnessStrengthView() }
        .sheet(item: $managedPlan) { FitnessPlannedSessionEditorSheet(viewModel: trainingViewModel, session: $0) }
        .task { await reload() }
        .refreshable { await reload(refresh: true) }
    }

    @ViewBuilder private func planActions(_ plan: FitnessPlannedSession) -> some View {
        if plan.status == "proposed" {
            Button("Accept", systemImage: "checkmark.seal") { Task { await accept(plan) } }
                .buttonStyle(.borderedProminent)
        }
        if plan.isStartable, plan.sportKey == "strength" {
            Button("Start", systemImage: "play.fill") { Task { if await viewModel.start(plan) { showStrength = true } } }
                .buttonStyle(.borderedProminent).disabled(viewModel.isLoading)
        } else if plan.isStartable, plan.sportKey == "running" {
            NavigationLink(value: FitnessSection.runPlans) { Label("Start", systemImage: "figure.run") }
                .buttonStyle(.borderedProminent)
        }
        if plan.isStartable {
            Button("Readiness", systemImage: "bolt.heart") { showReadiness(for: plan.id) }.buttonStyle(.bordered)
        }
        Button("Edit", systemImage: "pencil") { managedPlan = plan }.buttonStyle(.bordered)
        if plan.movable { Button("Move", systemImage: "calendar.badge.clock") { managedPlan = plan }.buttonStyle(.bordered) }
    }

    private func reload(refresh: Bool = false) async {
        async let main: Void = viewModel.load()
        async let health: Void = healthViewModel.load(refresh: refresh)
        async let training: Void = trainingViewModel.load()
        _ = await (main, health, training)
    }
    private func accept(_ plan: FitnessPlannedSession) async {
        var draft = FitnessPlannedSessionEditDraft(session: plan)
        draft.status = "accepted"
        if await trainingViewModel.updatePlannedSession(draft) { await viewModel.load() }
    }
    private func openPlan(_ id: String) {
        managedPlan = viewModel.plans.first { $0.id == id } ?? trainingViewModel.plans.first { $0.id == id }
    }
    private func showReadiness(for id: String) {
        readinessPlanId = id
        readiness = nil
        HapticManager.selection()
    }
    private var readinessPlan: FitnessPlannedSession? {
        guard let readinessPlanId else { return nil }
        return viewModel.todayPlans.first(where: { $0.id == readinessPlanId })
    }
    private func position(_ value: Double?, target: Double?, unit: String) -> String {
        guard let value else { return "—" }
        let base = "\(Int(value.rounded())) \(unit)"
        return target.map { "\(base) of \(Int($0.rounded()))" } ?? base
    }
    private func planDetail(_ plan: FitnessPlannedSession) -> String {
        var parts = [plan.status.replacingOccurrences(of: "_", with: " ").capitalized, plan.sportKey.capitalized]
        if let duration = plan.expectedDurationSeconds { parts.append("\(Int(duration/60)) min") }
        if let start = plan.scheduledStart {
            parts.append(start.formatted(date: .omitted, time: .shortened))
        } else if let start = plan.timeWindowStart, let end = plan.timeWindowEnd {
            parts.append("\(start.formatted(date:.omitted,time:.shortened))–\(end.formatted(date:.omitted,time:.shortened))")
        }
        return parts.joined(separator: " · ")
    }
    private func gearLabel(_ plan: FitnessPlannedSession) -> String? {
        let names = viewModel.gear.filter { plan.intendedGearIds.contains($0.id) }.map(\.name)
        if !names.isEmpty { return "Gear: \(names.joined(separator:", "))" }
        return viewModel.gear.first { $0.defaultForSportKey == plan.sportKey && ($0.active ?? true) }.map { "Default gear: \($0.name)" }
    }
}
