import SwiftUI

// MARK: - Canonical and legacy navigation

extension FitnessDeepLinkDestination {
    static let primaryNavigation: [FitnessDeepLinkDestination] = [
        .progress, .log, .plan, .overview,
    ]

    var title: String {
        switch self {
        case .overview: "More".localized
        case .activities: "Activities".localized
        case .log: "Food".localized
        case .plan: "Train".localized
        case .progress: "Review".localized
        case .coach: "Coach".localized
        }
    }

    /// Stable, non-localized test identifier component.
    var accessibilityIdentifierComponent: String {
        switch self {
        case .overview: "More"
        case .activities: "Activities"
        case .log: "Food"
        case .plan: "Train"
        case .progress: "Review"
        case .coach: "Coach"
        }
    }

    var icon: String {
        switch self {
        case .overview: "ellipsis"
        case .activities: "clock.arrow.circlepath"
        case .log: "fork.knife"
        case .plan: "dumbbell.fill"
        case .progress: "chart.xyaxis.line"
        case .coach: "bubble.left.and.text.bubble.right.fill"
        }
    }

    var primaryNavigationSelection: FitnessDeepLinkDestination {
        switch self {
        case .activities, .progress: .progress
        case .coach, .overview: .overview
        case .log: .log
        case .plan: .plan
        }
    }
}

enum FitnessPrimaryNavigationLayout {
    static let minimumItemWidth: CGFloat = 56
    static let spacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 8

    static func minimumRailWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return horizontalPadding * 2 }
        return (CGFloat(itemCount) * minimumItemWidth)
            + (CGFloat(itemCount - 1) * spacing)
            + (horizontalPadding * 2)
    }

    static func itemWidth(isAccessibilitySize: Bool) -> CGFloat {
        isAccessibilitySize ? 96 : minimumItemWidth
    }
}

enum FitnessLegacyPlanSurface: String, Equatable, Hashable {
    case training, strength, runPlans
}

enum FitnessLegacyProgressSurface: String, Equatable, Hashable {
    case activities, recovery, progress, analysis, explore
}

enum FitnessLegacyDetail: Equatable, Hashable {
    case plan(surface: FitnessLegacyPlanSurface, targetId: String?)
    case progress(surface: FitnessLegacyProgressSurface, targetId: String?)
}

struct FitnessLegacyResolution: Equatable, Hashable {
    let destination: FitnessDeepLinkDestination
    let detail: FitnessLegacyDetail?
}

/// Typed migration map for links created by the previous eleven-section hub.
/// The primary destination is canonical while the specialist surface remains
/// available as detail context.
enum FitnessLegacyDestination: String, CaseIterable, Equatable, Hashable {
    case today, nutrition, training, strength, runPlans, activities, recovery, progress, analysis, explore, coach

    func resolve(targetId: String? = nil) -> FitnessLegacyResolution {
        switch self {
        case .today:
            FitnessLegacyResolution(destination: .overview, detail: nil)
        case .nutrition:
            FitnessLegacyResolution(destination: .log, detail: nil)
        case .training:
            FitnessLegacyResolution(
                destination: .plan,
                detail: .plan(surface: .training, targetId: targetId)
            )
        case .strength:
            FitnessLegacyResolution(
                destination: .plan,
                detail: .plan(surface: .strength, targetId: targetId)
            )
        case .runPlans:
            FitnessLegacyResolution(
                destination: .plan,
                detail: .plan(surface: .runPlans, targetId: targetId)
            )
        case .activities:
            FitnessLegacyResolution(
                destination: .activities,
                detail: .progress(surface: .activities, targetId: targetId)
            )
        case .recovery:
            FitnessLegacyResolution(
                destination: .progress,
                detail: .progress(surface: .recovery, targetId: targetId)
            )
        case .progress:
            FitnessLegacyResolution(
                destination: .progress,
                detail: .progress(surface: .progress, targetId: targetId)
            )
        case .analysis:
            FitnessLegacyResolution(
                destination: .progress,
                detail: .progress(surface: .analysis, targetId: targetId)
            )
        case .explore:
            FitnessLegacyResolution(
                destination: .progress,
                detail: .progress(surface: .explore, targetId: targetId)
            )
        case .coach:
            FitnessLegacyResolution(destination: .coach, detail: nil)
        }
    }

    func intent(targetId: String? = nil, id: UUID = UUID()) -> FitnessDeepLinkIntent {
        let resolution = resolve(targetId: targetId)
        return FitnessDeepLinkIntent(
            id: id,
            destination: resolution.destination,
            targetId: targetId,
            actionKind: "legacy:\(rawValue)"
        )
    }
}

enum FitnessIntentCommand: Equatable, Hashable {
    case select(FitnessDeepLinkDestination)
    case startBlankStrength
    case startPlan(String)
    case editPlan(String)
    case resumeWorkout(String)
    case openActivity(String)
    case openCoachResult(FitnessCoachProposalDestination)
    case openLegacyPlan(FitnessLegacyPlanSurface, targetId: String?)
    case openLegacyProgress(FitnessLegacyProgressSurface, targetId: String?)

    var destination: FitnessDeepLinkDestination {
        switch self {
        case .select(let destination): destination
        case .startBlankStrength, .startPlan, .editPlan, .resumeWorkout, .openLegacyPlan: .plan
        case .openActivity: .activities
        case .openLegacyProgress(let surface, _):
            surface == .activities ? .activities : .progress
        case .openCoachResult(let destination):
            switch destination.kind {
            case .plannedSession: .plan
            case .nutritionTarget, .mealTemplate, .foodLog: .log
            case .goal: .plan
            case .analysisChart: .progress
            case .fitnessReminder: .coach
            case .calendarEvent, .shopping, .task, .unknown: .coach
            }
        }
    }

    static func resolve(_ intent: FitnessDeepLinkIntent) -> FitnessIntentCommand? {
        if intent.actionKind == "open_coach_result" {
            guard let destination=intent.coachDestination,destination.kind.isKnown else { return nil }
            switch destination.kind {
            case .plannedSession, .nutritionTarget, .mealTemplate, .goal, .analysisChart,
                 .foodLog, .fitnessReminder:
                return .openCoachResult(destination)
            case .calendarEvent, .shopping, .task, .unknown:
                return nil
            }
        }
        if let action = intent.actionKind,
           action.hasPrefix("legacy:"),
           let legacy = FitnessLegacyDestination(rawValue: String(action.dropFirst("legacy:".count))) {
            let resolution = legacy.resolve(targetId: intent.targetId)
            switch resolution.detail {
            case .plan(let surface, let targetId):
                return .openLegacyPlan(surface, targetId: targetId)
            case .progress(let surface, let targetId):
                return .openLegacyProgress(surface, targetId: targetId)
            case nil:
                return .select(resolution.destination)
            }
        }

        switch (intent.destination, intent.actionKind, intent.targetId) {
        case (.plan, "start_strength", _):
            return .startBlankStrength
        case (.plan, "start_session", .some(let id)):
            return .startPlan(id)
        case (.plan, "move_session", .some(let id)),
             (.plan, "open_session", .some(let id)):
            return .editPlan(id)
        case (.plan, "resume_activity", .some(let id)):
            return .resumeWorkout(id)
        case (.activities, "open_activity", .some(let id)),
             (.progress, "open_activity", .some(let id)):
            return .openActivity(id)
        case (.plan, _, .some(let id)):
            return .editPlan(id)
        case (.activities, _, .some(let id)),
             (.progress, _, .some(let id)):
            return .openActivity(id)
        default:
            return .select(intent.destination)
        }
    }
}

@MainActor
final class FitnessIntentCoordinator: ObservableObject {
    private var inFlight: Set<UUID> = []
    private var completed: Set<UUID> = []

    func begin(_ intent: FitnessDeepLinkIntent) -> FitnessIntentCommand? {
        guard !inFlight.contains(intent.id), !completed.contains(intent.id) else { return nil }
        guard let command=FitnessIntentCommand.resolve(intent) else { return nil }
        inFlight.insert(intent.id)
        return command
    }

    func finish(id: UUID, succeeded: Bool) {
        inFlight.remove(id)
        if succeeded { completed.insert(id) }
    }
}

enum FitnessShellLoadPolicy {
    static func shouldLoadOverview(for _:FitnessDeepLinkDestination) -> Bool {
        false
    }

    static func shouldMountDestination(
        onboardingResolved:Bool,
        onboardingStatus:FitnessOnboardingStatus?
    ) -> Bool {
        onboardingResolved && onboardingStatus != .draft
    }
}

// MARK: - Module shell

private enum FitnessShellRoute: Hashable {
    case strength
    case runPlans
    case activity(String)
    case recovery
    case measurements
    case analysis
    case explore
    case connections
    case coachResult(FitnessCoachProposalDestination)
}

private struct FitnessIntentFailure: Identifiable {
    let intent: FitnessDeepLinkIntent
    let message: String
    var id: UUID { intent.id }
}

struct FitnessHubView: View {
    var body: some View {
        FitnessShellView()
    }
}

struct FitnessShellView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var overviewViewModel = FitnessHubViewModel()
    @StateObject private var trainingViewModel = FitnessTrainingViewModel()
    @StateObject private var intentCoordinator = FitnessIntentCoordinator()
    @StateObject private var onboardingViewModel = FitnessOnboardingViewModel()
    @State private var path: [FitnessShellRoute] = []
    @State private var editingPlan: FitnessPlannedSession?
    @State private var intentFailure: FitnessIntentFailure?
    @State private var didLoadOverview = false
    @State private var onboardingResolved=false
    @State private var didBootstrapDestination=false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                primaryNavigation

                if let failure = intentFailure {
                    intentRecovery(failure)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                if FitnessShellLoadPolicy.shouldMountDestination(
                    onboardingResolved:onboardingResolved,
                    onboardingStatus:onboardingViewModel.profile?.status
                ) {
                    primaryDestination
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier(
                            "fitnessDestination\(appState.selectedFitnessDestination.accessibilityIdentifierComponent)"
                        )
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing Fitness…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(HausKlarAccessibilityID.Fitness.shellLoading)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Fitness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if onboardingViewModel.canFinishLater {
                    ToolbarItem(placement:.topBarTrailing) {
                        Menu {
                            Button("Finish setup",systemImage:"checklist") {
                                Task { await onboardingViewModel.resumeSkippedSetup() }
                            }
                        } label: {
                            Image(systemName:"slider.horizontal.3")
                        }
                        .accessibilityLabel("Personalise Fitness")
                    }
                }
            }
            .navigationDestination(for: FitnessShellRoute.self) { route in
                routeDestination(route)
            }
            .navigationDestination(for: FitnessRecoveryFocusRoute.self) { route in
                FitnessRecoveryView(focus: route)
            }
        }
        .sheet(item: $editingPlan) { plan in
            FitnessPlannedSessionEditorSheet(viewModel: trainingViewModel, session: plan)
        }
        .fullScreenCover(isPresented:Binding(
            get:{ onboardingViewModel.shouldPresent },
            set:{ _ in }
        )) {
            FitnessFirstRunView(viewModel:onboardingViewModel)
        }
        .task {
            await onboardingViewModel.loadIfNeeded()
            onboardingResolved=true
            await bootstrapDestinationIfReady()
        }
        .onChange(of: appState.fitnessDeepLinkIntent) { _, intent in
            guard let intent else { return }
            guard FitnessShellLoadPolicy.shouldMountDestination(
                onboardingResolved:onboardingResolved,
                onboardingStatus:onboardingViewModel.profile?.status
            ) else { return }
            Task { await consume(intent) }
        }
        .onChange(of:onboardingViewModel.shouldPresent) { wasPresented,isPresented in
            guard wasPresented,!isPresented else { return }
            Task { await bootstrapDestinationIfReady() }
        }
    }

    private var primaryNavigation: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FitnessPrimaryNavigationLayout.spacing) {
                ForEach(FitnessDeepLinkDestination.primaryNavigation, id: \.self) { destination in
                    let selected = appState.selectedFitnessDestination.primaryNavigationSelection == destination
                    Button {
                        select(destination)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: destination.icon)
                                .font(.subheadline.weight(.semibold))
                            Text(destination.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .frame(
                            minWidth: FitnessPrimaryNavigationLayout.itemWidth(
                                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                            ),
                            minHeight: 44
                        )
                        .background(
                            selected ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(destination.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("fitnessPrimary\(destination.accessibilityIdentifierComponent)")
                }
            }
            .padding(.horizontal, FitnessPrimaryNavigationLayout.horizontalPadding)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var primaryDestination: some View {
        switch appState.selectedFitnessDestination {
        case .overview:
            FitnessMoreView(
                openActivities: { select(.activities) },
                openCoach: { select(.coach) },
                openRecovery: { path.append(.recovery) },
                openMeasurements: { path.append(.measurements) },
                openInsights: { path.append(.explore) },
                openConnections: { path.append(.connections) }
            )
        case .activities:
            FitnessActivityHistoryView()
                .navigationTitle("Activities")
        case .log:
            FitnessNutritionView()
                .navigationTitle("Food")
        case .plan:
            FitnessTrainingView()
                .navigationTitle("Train")
        case .progress:
            FitnessProgressView()
                .navigationTitle("Review")
        case .coach:
            FitnessCoachView()
                .navigationTitle("Coach")
        }
    }

    private var overview: some View {
        FitnessOverviewView(
            viewModel: overviewViewModel,
            isInitialLoad: !didLoadOverview,
            selectDestination: select,
            startPlan: startFromOverview,
            openPlan: openFromOverview,
            resumeWorkout: resumeFromOverview,
            openWeightProgress: { path.append(.measurements) },
            openConnections: { path.append(.connections) }
        )
    }

    private func select(_ destination: FitnessDeepLinkDestination) {
        intentFailure = nil
        path.removeAll()
        appState.selectedFitnessDestination = destination
        HapticManager.selection()
        if FitnessShellLoadPolicy.shouldLoadOverview(for:destination) {
            Task { await loadOverviewIfNeeded() }
        }
    }

    private func loadOverviewIfNeeded() async {
        guard !didLoadOverview else { return }
        await overviewViewModel.load()
        didLoadOverview=true
    }

    private func bootstrapDestinationIfReady() async {
        guard FitnessShellLoadPolicy.shouldMountDestination(
            onboardingResolved:onboardingResolved,
            onboardingStatus:onboardingViewModel.profile?.status
        ),!didBootstrapDestination else { return }
        didBootstrapDestination=true
        if let intent=appState.fitnessDeepLinkIntent { await consume(intent) }
        if FitnessShellLoadPolicy.shouldLoadOverview(for:appState.selectedFitnessDestination) {
            await loadOverviewIfNeeded()
        }
    }

    private func consume(_ intent: FitnessDeepLinkIntent) async {
        guard let command = intentCoordinator.begin(intent) else { return }
        intentFailure = nil
        path.removeAll()
        appState.selectedFitnessDestination = command.destination

        let succeeded = await perform(command)
        intentCoordinator.finish(id: intent.id, succeeded: succeeded)
        if succeeded {
            appState.completeFitnessDeepLink(id: intent.id)
        } else {
            intentFailure = FitnessIntentFailure(intent: intent, message: failureMessage(for: command))
            HapticManager.error()
        }
    }

    private func perform(_ command: FitnessIntentCommand) async -> Bool {
        switch command {
        case .select:
            return true
        case .startBlankStrength:
            guard await overviewViewModel.startBlankStrength() else { return false }
            path.append(.strength)
            return true
        case .startPlan(let id):
            guard let plan = await loadPlan(id: id) else { return false }
            if plan.sportKey != "strength" {
                editingPlan = plan
                return true
            }
            guard await overviewViewModel.start(plan) else { return false }
            path.append(.strength)
            return true
        case .editPlan(let id):
            guard let plan = await loadPlan(id: id) else { return false }
            editingPlan = plan
            return true
        case .resumeWorkout(let id):
            await overviewViewModel.load()
            guard overviewViewModel.activeWorkout?.id == id else { return false }
            path.append(.strength)
            return true
        case .openActivity(let id):
            path.append(.activity(id))
            return true
        case .openCoachResult(let destination):
            path.append(.coachResult(destination))
            return true
        case .openLegacyPlan(let surface, let targetId):
            if let targetId {
                guard let plan = await loadPlan(id: targetId) else { return false }
                editingPlan = plan
                return true
            }
            switch surface {
            case .training: break
            case .strength: path.append(.strength)
            case .runPlans: path.append(.runPlans)
            }
            return true
        case .openLegacyProgress(let surface, let targetId):
            switch surface {
            case .activities:
                if let targetId { path.append(.activity(targetId)) }
            case .recovery: path.append(.recovery)
            case .progress: break
            case .analysis: path.append(.analysis)
            case .explore: path.append(.explore)
            }
            return true
        }
    }

    private func loadPlan(id: String) async -> FitnessPlannedSession? {
        await trainingViewModel.load()
        return trainingViewModel.plans.first { $0.id == id }
    }

    private func startFromOverview(_ plan: FitnessPlannedSession) async -> Bool {
        guard plan.sportKey == "strength" else {
            return await openFromOverview(plan)
        }
        guard await overviewViewModel.start(plan) else { return false }
        appState.selectedFitnessDestination = .plan
        path.removeAll()
        path.append(.strength)
        return true
    }

    private func openFromOverview(_ plan: FitnessPlannedSession) async -> Bool {
        await trainingViewModel.load()
        guard let exactPlan = trainingViewModel.plans.first(where: { $0.id == plan.id }) else { return false }
        appState.selectedFitnessDestination = .plan
        path.removeAll()
        editingPlan = exactPlan
        return true
    }

    private func resumeFromOverview(_ workoutId: String) async -> Bool {
        guard overviewViewModel.activeWorkout?.id == workoutId else { return false }
        appState.selectedFitnessDestination = .plan
        path.removeAll()
        path.append(.strength)
        return true
    }

    private func failureMessage(for command: FitnessIntentCommand) -> String {
        switch command {
        case .startBlankStrength, .startPlan: "That workout couldn't be started.".localized
        case .editPlan, .openLegacyPlan: "That planned session couldn't be opened.".localized
        case .resumeWorkout: "That active workout is no longer available.".localized
        case .openActivity, .openLegacyProgress: "That activity couldn't be opened.".localized
        case .openCoachResult: "That saved result couldn't be opened.".localized
        case .select: "That Fitness destination couldn't be opened.".localized
        }
    }

    private func intentRecovery(_ failure: FitnessIntentFailure) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(failure.message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try again") {
                Task { await consume(failure.intent) }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func routeDestination(_ route: FitnessShellRoute) -> some View {
        switch route {
        case .strength: FitnessStrengthView()
        case .runPlans: FitnessRunPlansView()
        case .activity(let id): FitnessActivityDetailView(activityId: id)
        case .recovery: FitnessRecoveryView()
        case .measurements: FitnessMeasurementTrendsView()
        case .analysis: FitnessAnalysisView()
        case .explore: FitnessExploreView()
        case .connections: FitnessConnectionsView(plans: trainingViewModel.plans)
        case .coachResult(let destination): FitnessCoachSavedDestinationView(destination:destination)
        }
    }

}

// MARK: - Overview

private struct FitnessOverviewView: View {
    @ObservedObject var viewModel: FitnessHubViewModel
    let isInitialLoad: Bool
    let selectDestination: (FitnessDeepLinkDestination) -> Void
    let startPlan: (FitnessPlannedSession) async -> Bool
    let openPlan: (FitnessPlannedSession) async -> Bool
    let resumeWorkout: (String) async -> Bool
    let openWeightProgress: () -> Void
    let openConnections: () -> Void

    @StateObject private var syncStatus = FitnessSyncStatus.shared
    @State private var workingId: String?
    @State private var failedActionMessage: String?
    @State private var readinessPlan: FitnessPlannedSession?
    @State private var savedReadinessMessage: String?
    @State private var showingDataInbox = false
    @State private var showingConnections = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if (isInitialLoad || viewModel.isLoading) && !hasSessionData {
                    loadingSessionCard
                } else if let workout = viewModel.activeWorkout {
                    activeWorkoutCard(workout)
                } else if let plan = viewModel.todayPlan {
                    plannedSessionCard(plan)
                } else {
                    noSessionCard
                }

                dataStatus
                activityHistoryButton

                if let failedActionMessage {
                    Label(failedActionMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier(HausKlarAccessibilityID.Fitness.overviewError)
                } else if let savedReadinessMessage {
                    Label(savedReadinessMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier(HausKlarAccessibilityID.Fitness.overviewSuccess)
                }

                quickActions
                usefulFact
                weightProgress

                if hasSessionData {
                    coachCard
                }

                connectionsCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await viewModel.load() }
        .confirmationDialog(
            "How ready do you feel?",
            isPresented: Binding(
                get: { readinessPlan != nil },
                set: { if !$0 { readinessPlan = nil } }
            ),
            titleVisibility: .visible,
            presenting: readinessPlan
        ) { plan in
            Button("5 · Ready to go") { saveReadiness(5, for: plan) }
            Button("4 · Good") { saveReadiness(4, for: plan) }
            Button("3 · Okay") { saveReadiness(3, for: plan) }
            Button("2 · Low") { saveReadiness(2, for: plan) }
            Button("1 · Very low") { saveReadiness(1, for: plan) }
            Button("Cancel", role: .cancel) { readinessPlan = nil }
        } message: { plan in
            Text("Save a quick check-in for \(plan.title).")
        }
        .sheet(isPresented: $showingDataInbox) {
            dataInbox
        }
    }

    private var hasSessionData: Bool {
        viewModel.activeWorkout != nil || viewModel.todayPlan != nil
    }

    private var loadingSessionCard: some View {
        HStack(spacing: 14) {
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                Text("Loading today's session")
                    .font(.headline)
                Text("Your first action will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("fitnessOverviewLoading")
    }

    private func activeWorkoutCard(_ workout: FitnessStrengthSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sessionHeading(
                eyebrow: "In progress".localized,
                title: workout.title,
                detail: String(
                    format: "Started %@".localized,
                    shortTime(workout.startedAt)
                ),
                systemImage: "dumbbell.fill",
                tint: .indigo
            )

            Button {
                run(workout.id, failure: "That workout couldn't be resumed.") {
                    await resumeWorkout(workout.id)
                }
            } label: {
                Label((workingId == workout.id ? "Opening…" : "Resume workout").localized, systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(workingId != nil)
            .accessibilityIdentifier("fitnessOverviewResume")
        }
        .sessionCard(tint: .indigo)
    }

    private func plannedSessionCard(_ plan: FitnessPlannedSession) -> some View {
        let isStrength = plan.sportKey == "strength"
        return VStack(alignment: .leading, spacing: 14) {
            sessionHeading(
                eyebrow: "Today".localized,
                title: plan.title,
                detail: planDetail(plan),
                systemImage: isStrength ? "dumbbell.fill" : sportIcon(plan.sportKey),
                tint: isStrength ? .indigo : .blue
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { planActions(plan, isStrength: isStrength) }
                VStack(spacing: 8) { planActions(plan, isStrength: isStrength) }
            }
        }
        .sessionCard(tint: isStrength ? .indigo : .blue)
    }

    @ViewBuilder
    private func planActions(_ plan: FitnessPlannedSession, isStrength: Bool) -> some View {
        Button {
            run(plan.id, failure: isStrength ? "That workout couldn't be started." : "That session couldn't be opened.") {
                isStrength ? await startPlan(plan) : await openPlan(plan)
            }
        } label: {
                Label(
                    (workingId == plan.id ? "Opening…" : (isStrength ? "Start" : "Open")).localized,
                systemImage: isStrength ? "play.fill" : "arrow.right"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(workingId != nil)
        .accessibilityIdentifier("fitnessOverviewPrimaryAction")

        if plan.movable {
            Button {
                run(plan.id, failure: "That session couldn't be opened.") {
                    await openPlan(plan)
                }
            } label: {
                Label("Move", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(workingId != nil)
            .accessibilityIdentifier("fitnessOverviewMoveAction")
        }
    }

    private var noSessionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sessionHeading(
                eyebrow: "Today".localized,
                title: "No session planned".localized,
                detail: "Put the next workout on your plan when it suits you.".localized,
                systemImage: "calendar.badge.plus",
                tint: .blue
            )
            Button {
                selectDestination(.plan)
            } label: {
                Label("Plan your next session", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("fitnessOverviewPlanAction")
        }
        .sessionCard(tint: .blue)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick actions")
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { quickActionButtons }
                VStack(spacing: 8) { quickActionButtons }
            }
        }
    }

    private var activityHistoryButton: some View {
        Button {
            HapticManager.selection()
            selectDestination(.activities)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .accessibilityHidden(true)
                Text("Activity history")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Activity history")
        .accessibilityHint("Opens all past activities")
        .accessibilityIdentifier("fitnessOverviewActivityHistory")
    }

    @ViewBuilder
    private var quickActionButtons: some View {
        if viewModel.mainOutcome == .supportWeight {
            quickActionButton("Log food", systemImage: "fork.knife") {
                selectDestination(.log)
            }
        } else if viewModel.mainOutcome == .buildStrength || viewModel.mainOutcome == .runFurther {
            quickActionButton("Add a session", systemImage: "calendar.badge.plus") {
                selectDestination(.plan)
            }
        } else {
            quickActionButton("View progress", systemImage: "chart.xyaxis.line") {
                selectDestination(.progress)
            }
        }
        if let plan = viewModel.todayPlan {
            quickActionButton("Readiness", systemImage: "bolt.heart.fill") {
                readinessPlan = plan
                HapticManager.selection()
            }
        } else {
            quickActionButton("View sessions", systemImage: "calendar") {
                selectDestination(.plan)
            }
        }
    }

    private func quickActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title.localized, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private var usefulFact: some View {
        HStack(spacing: 12) {
            Image(systemName: usefulFactValue.icon)
                .font(.title3)
                .foregroundStyle(usefulFactValue.tint)
                .frame(width: 36, height: 36)
                .background(usefulFactValue.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(usefulFactValue.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(usefulFactValue.value)
                    .font(.headline)
                if let detail = usefulFactValue.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var weightProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weight progress")
                        .font(.headline)
                    Text("Actual weigh-ins and the clearer smoothed trend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    HapticManager.selection()
                    openWeightProgress()
                } label: {
                    Label("View all", systemImage: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("View weight progress")
            }

            FitnessMeasurementTrendsView(overview: true, history: overviewWeightHistory)
        }
        .accessibilityIdentifier("fitnessOverviewWeightProgress")
    }

    private var overviewWeightHistory: FitnessMeasurementHistoryDTO {
        FitnessMeasurementHistoryBuilder.make(
            metric: .weight,
            bodyMeasurements: viewModel.weightMeasurements,
            recoveryObservations: []
        )
    }

    @ViewBuilder
    private var dataStatus: some View {
        if canOpenDataInbox {
            Button {
                showingDataInbox = true
                HapticManager.selection()
            } label: {
                dataStatusLabel
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens one place to review Fitness data")
        } else if hasPendingUploads {
            dataStatusLabel
        }
    }

    private var dataStatusLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: dataStatusIcon)
                .foregroundStyle(dataStatusTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(dataStatusTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(dataStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if canOpenDataInbox {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fitnessDataStatus")
    }

    private var hasReviewNotices: Bool {
        !viewModel.notices.isEmpty
    }

    private var hasPendingUploads: Bool {
        viewModel.pendingMutationCount > 0
    }

    private var canOpenDataInbox: Bool {
        hasReviewNotices || (hasPendingUploads && syncStatus.message != nil)
    }

    private var dataStatusTitle: String {
        hasReviewNotices
            ? "A quick check is needed".localized
            : "Saved on this device".localized
    }

    private var dataStatusDetail: String {
        if hasReviewNotices {
            return "Your saved information is safe. Review it when convenient.".localized
        }
        let format = viewModel.pendingMutationCount == 1
            ? "%lld change will update shortly.".localized
            : "%lld changes will update shortly.".localized
        return String(format: format, Int64(viewModel.pendingMutationCount))
    }

    private var dataStatusIcon: String {
        hasReviewNotices ? "exclamationmark.circle.fill" : "checkmark.icloud.fill"
    }

    private var dataStatusTint: Color {
        hasReviewNotices ? .orange : .green
    }

    private var dataInbox: some View {
        NavigationStack {
            List {
                if hasPendingUploads && syncStatus.message != nil {
                    Section("Needs another try") {
                        Text("Saved on this device")
                            .foregroundStyle(.secondary)
                        Button("Try again", systemImage: "arrow.clockwise") {
                            Task { await viewModel.sync() }
                        }
                    }
                }
                if !viewModel.notices.isEmpty {
                    Section("Review") {
                        ForEach(viewModel.notices) { notice in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(notice.message)
                                Button("Mark reviewed") {
                                    Task { await viewModel.dismiss(notice) }
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Fitness data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingDataInbox = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var connectionsCard: some View {
        DisclosureGroup(isExpanded: $showingConnections) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Apple Health, Withings and Intervals.icu stay optional. Set them up only when they remove work for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    openConnections()
                } label: {
                    Label("Choose apps and devices", systemImage: "point.3.connected.trianglepath.dotted")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        } label: {
            Label("Apps and devices", systemImage: "applewatch")
                .font(.headline)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("fitnessConnectionsDeferred")
    }

    private var coachCard: some View {
        Button {
            selectDestination(.coach)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .foregroundStyle(.pink)
                    .frame(width: 36, height: 36)
                    .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Need to adapt today?")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Talk through your session or food log with Coach.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Fitness Coach")
    }

    private func sessionHeading(
        eyebrow: String,
        title: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func run(
        _ id: String,
        failure: String,
        action: @escaping () async -> Bool
    ) {
        guard workingId == nil else { return }
        workingId = id
        failedActionMessage = nil
        savedReadinessMessage = nil
        Task {
            let succeeded = await action()
            if !succeeded {
                failedActionMessage = failure.localized
                HapticManager.error()
            }
            workingId = nil
        }
    }

    private func saveReadiness(_ value: Int, for plan: FitnessPlannedSession) {
        readinessPlan = nil
        failedActionMessage = nil
        Task {
            await viewModel.recordReadiness(value, for: plan)
            if viewModel.recordedReadiness[plan.id] == value {
                savedReadinessMessage = String(
                    format: "Readiness saved for %@.".localized,
                    plan.title
                )
            } else {
                failedActionMessage = "Readiness couldn't be saved.".localized
            }
        }
    }

    private func planDetail(_ plan: FitnessPlannedSession) -> String {
        var parts: [String] = []
        if let start = plan.scheduledStart {
            parts.append(shortTime(start))
        } else if let start = plan.timeWindowStart, let end = plan.timeWindowEnd {
            parts.append("\(shortTime(start))–\(shortTime(end))")
        }
        if let duration = plan.expectedDurationSeconds {
            parts.append(
                String(
                    format: "%lld min".localized,
                    Int64((duration / 60).rounded())
                )
            )
        }
        parts.append(sportName(plan.sportKey))
        return parts.joined(separator: " · ")
    }

    private func sportName(_ sportKey: String) -> String {
        switch sportKey.lowercased() {
        case "running", "run": "Running".localized
        case "strength", "strength_training": "Strength".localized
        case "walking", "walk": "Walking".localized
        case "cycling", "bike", "ride": "Cycling".localized
        case "swimming", "swim": "Swimming".localized
        default: sportKey.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(.hausKlarSelected)
        )
    }

    private func sportIcon(_ sportKey: String) -> String {
        if sportKey.contains("run") { return "figure.run" }
        if sportKey.contains("cycle") || sportKey.contains("bike") { return "figure.outdoor.cycle" }
        if sportKey.contains("swim") { return "figure.pool.swim" }
        return "figure.mixed.cardio"
    }

    private var usefulFactValue: FitnessOverviewFact {
        let content = FitnessOverviewFactPolicy.fact(
            outcome: viewModel.mainOutcome,
            snapshot: overviewSnapshot
        )
        return FitnessOverviewFact(
            label: content.label,
            value: content.value,
            detail: content.detail,
            icon: factIcon(content.kind),
            tint: factTint(content.kind)
        )
    }

    private var overviewSnapshot: FitnessOverviewFactSnapshot {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let interval = calendar.dateInterval(of: .weekOfYear, for: Date())
        let activities = viewModel.recentActivities.filter {
            interval?.contains($0.startedAt) ?? false
        }
        let running = activities.filter {
            $0.sportKey.localizedCaseInsensitiveContains("run")
        }
        let strength = activities.filter {
            $0.sportKey.localizedCaseInsensitiveContains("strength")
                || $0.sportKey.localizedCaseInsensitiveContains("weight")
        }
        return .init(
            activeDays: Set(activities.map { calendar.startOfDay(for: $0.startedAt) }).count,
            strengthSessions: strength.count,
            runningSessions: running.count,
            runningDistanceMetres: running.compactMap(\.distanceM).reduce(0, +),
            averageSleepSeconds: viewModel.recoverySummary?.sleep.averageDurationS,
            weightKilograms: viewModel.weightTrend
        )
    }

    private func factIcon(_ kind: FitnessOverviewFactKind) -> String {
        switch kind {
        case .movement: "figure.walk.motion"
        case .strength: "dumbbell.fill"
        case .running: "figure.run"
        case .energy: "bolt.heart.fill"
        case .weight: "scalemass.fill"
        }
    }

    private func factTint(_ kind: FitnessOverviewFactKind) -> Color {
        switch kind {
        case .movement: .blue
        case .strength: .indigo
        case .running: .orange
        case .energy: .green
        case .weight: .purple
        }
    }
}

private struct FitnessOverviewFact {
    let label: String
    let value: String
    let detail: String?
    let icon: String
    let tint: Color
}

private extension View {
    func sessionCard(tint: Color) -> some View {
        padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(tint.opacity(0.16), lineWidth: 1)
            }
    }
}
