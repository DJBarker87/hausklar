import SwiftData
import SwiftUI

private enum QuickCapture: String, Identifiable {
    case event, task

    var id: String { rawValue }
}

enum DashboardLoadPresentation: Equatable {
    case loading
    case ready
    case unavailable

    static func resolve(hasLoadedBriefing: Bool, hasError: Bool) -> Self {
        if hasLoadedBriefing { return .ready }
        if hasError { return .unavailable }
        return .loading
    }
}

enum TodayNutritionProgressMetric: Equatable, Sendable {
    case calories
    case protein
}

struct TodayNutritionProgressState: Equatable, Sendable {
    let fraction: Double
    let reachedGoal: Bool
}

enum TodayNutritionProgressPolicy {
    private static let mainMeals: Set<FitnessMeal> = [.breakfast, .lunch, .dinner]

    static func dayIsComplete(completedMeals: Set<FitnessMeal>) -> Bool {
        mainMeals.isSubset(of: completedMeals)
    }

    static func progress(
        for metric: TodayNutritionProgressMetric,
        value: Double,
        target: Double?,
        valueIsComplete: Bool,
        hasEntries: Bool,
        dayIsComplete: Bool
    ) -> TodayNutritionProgressState? {
        guard let target, target.isFinite, target > 0, value.isFinite else { return nil }
        let boundedValue = max(0, value)
        let reachedGoal: Bool
        switch metric {
        case .calories:
            // A low calorie total is not a success while the adult is still eating.
            // It becomes one only after all three main meals were explicitly finished,
            // and only when every entry has a known calorie value.
            reachedGoal = hasEntries && dayIsComplete && valueIsComplete
                && boundedValue <= target
        case .protein:
            // An incomplete protein total is a lower bound. If even that known
            // subtotal reaches the target, the target has still genuinely been met.
            reachedGoal = hasEntries && boundedValue >= target
        }
        return TodayNutritionProgressState(
            fraction: min(boundedValue / target, 1),
            reachedGoal: reachedGoal
        )
    }
}

@MainActor
private final class TodayNutritionGoalsViewModel: FitnessViewModelBase {
    @Published private(set) var targets: [FitnessNutritionTarget] = []
    private let repository: FitnessNutritionRepository

    init(
        repository: FitnessNutritionRepository = .shared,
        database: FitnessDatabase = .shared
    ) {
        self.repository = repository
        super.init(database: database)
    }

    func load() async {
        await run {
            self.targets = try await self.repository.nutritionTargets()
        }
    }

    func value(for metric: FitnessNutritionMetric, on day: String) -> Double? {
        guard let target = currentTarget(for: metric, on: day) else { return nil }
        return FitnessNutritionViewFormatting.displayTarget(target)
    }

    func save(calories: Double, protein: Double, on day: String) async -> Bool {
        var saved = false
        await run {
            for (metric, value) in [
                (FitnessNutritionMetric.caloriesKcal, calories),
                (.proteinG, protein),
            ] {
                let existing = self.currentTarget(for: metric, on: day)
                let target = FitnessNutritionTarget(
                    id: existing?.id ?? UUID().uuidString,
                    metric: metric,
                    mode: .fixed,
                    targetValue: value,
                    targetMin: nil,
                    targetMax: nil,
                    trainingDayValue: nil,
                    restDayValue: nil,
                    phaseId: nil,
                    effectiveFrom: existing?.effectiveFrom ?? day,
                    effectiveUntil: existing?.effectiveUntil,
                    active: true,
                    revision: existing?.revision ?? 0,
                    updatedAt: Date(),
                    deletedAt: nil
                )
                _ = try await self.repository.saveTarget(
                    target,
                    baseRevision: existing?.revision
                )
            }
            self.targets = try await self.repository.nutritionTargets()
            saved = true
            HapticManager.success()
        }
        if saved {
            await syncAfterDurableWrite(context: "Today nutrition goals")
        }
        return saved
    }

    private func currentTarget(
        for metric: FitnessNutritionMetric,
        on day: String
    ) -> FitnessNutritionTarget? {
        targets.first {
            $0.active && $0.metric == metric
                && $0.effectiveFrom <= day
                && ($0.effectiveUntil.map { $0 >= day } ?? true)
        }
    }
}

private struct TodayNutritionCelebrationTrigger: Hashable {
    let active: Bool
    let reduceMotion: Bool
}

private struct TodayNutritionProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 12
    @State private var flashesGold = false
    @State private var hasCelebratedCurrentAchievement = false

    let fraction: Double
    let tint: Color
    let reachedGoal: Bool
    let celebrationIsVisible: Bool
    let label: String
    let valueDescription: String
    let accessibilityIdentifier: String

    private static let successGold = Color(
        red: 0.96,
        green: 0.67,
        blue: 0.10
    )

    private var celebrationTrigger: TodayNutritionCelebrationTrigger {
        TodayNutritionCelebrationTrigger(
            active: reachedGoal && celebrationIsVisible,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = proxy.size.width * CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                if fillWidth > 0 {
                    Capsule()
                        .fill((flashesGold ? Self.successGold : tint).gradient)
                        .frame(width: fillWidth)
                }
            }
        }
        .frame(height: barHeight)
        .overlay {
            Capsule()
                .stroke(
                    Self.successGold.opacity(flashesGold ? 0.95 : 0),
                    lineWidth: 2
                )
        }
        .shadow(
            color: Self.successGold.opacity(flashesGold ? 0.55 : 0),
            radius: flashesGold ? 7 : 0
        )
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(
            valueDescription + (reachedGoal ? ", goal achieved" : "")
        )
        .accessibilityIdentifier(accessibilityIdentifier)
        .task(id: celebrationTrigger) {
            guard reachedGoal else {
                flashesGold = false
                hasCelebratedCurrentAchievement = false
                return
            }
            guard celebrationIsVisible else {
                flashesGold = false
                return
            }
            if reduceMotion {
                // Preserve the success signal without animating it.
                flashesGold = true
                hasCelebratedCurrentAchievement = true
                return
            }
            guard !hasCelebratedCurrentAchievement else {
                flashesGold = false
                return
            }
            flashesGold = false
            do {
                // When a meal sheet has just closed, wait for its dismissal
                // transition so the brief celebration is actually visible.
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            hasCelebratedCurrentAchievement = true
            withAnimation(.easeIn(duration: 0.18)) {
                flashesGold = true
            }
            do {
                try await Task.sleep(nanoseconds: 650_000_000)
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.32)) {
                flashesGold = false
            }
        }
    }
}

/// Calendar-led home screen for the family's current day.
struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.locale) private var locale
    @StateObject private var viewModel = DashboardViewModel()
    @StateObject private var quickEntryViewModel = TodayQuickEntryViewModel()
    @StateObject private var commitmentsViewModel = CommitmentsViewModel()
    @State private var quickCapture: QuickCapture?
    @State private var showingMoreToday = false
    @State private var showingFacilityDetails = false
    @State private var showingMealEntry = false
    @State private var showingNutritionGoals = false
    @State private var suppressingNutritionCelebration = false
    @State private var mealSeedEntries: [FitnessFoodLogEntry] = []
    @State private var showingExerciseEntry = false
    @State private var exerciseWasAdded = false
    @State private var showingCommitments = false

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    dayHeader

                    if let error = viewModel.errorMessage, !viewModel.isLoading {
                        errorBanner(error)
                    }

                    if let error = viewModel.coordinationError {
                        coordinationErrorBanner(error)
                    }

                    needsAttentionSection
                    plansToSortSection
                    scheduleSection
                    facilityQuickFactSection
                    homeworkSection
                    giftPreparationSection
                    tasksSection
                    primaryDecision
                    if appState.fitnessWorkspacePreference.enabled {
                        fitnessQuickEntrySection
                        fitnessTodaySection
                    }
                    viTimetableSection
                    financeActionSection

                    DisclosureGroup(isExpanded: $showingMoreToday) {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if viewModel.tomorrowCard?.loadPrompt != nil {
                                tomorrowSortedCard
                            }
                            prepPacksSection
                            preparationSection
                            insightsSection
                            memoriesSection
                        }
                        .padding(.top, 12)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("More today")
                                .font(.headline)
                            Text("Routines, suggestions and family moments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                    if appState.fitnessWorkspacePreference.enabled {
                        fitnessExerciseEntrySection
                    }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        HapticManager.selection()
                        showingCommitments = true
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("Plans to sort")
                    .accessibilityHint("Review or start a family plan")
                    .accessibilityIdentifier("todayPlansToSortButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.showingSettings = true
                    } label: {
                        Image(systemName: "person.example_35fbacff.circle")
                    }
                    .accessibilityLabel("Settings and profile")
                }
            }
            .refreshable {
                async let dashboard: Void = viewModel.loadDashboard(
                    fitnessEnabled: appState.fitnessWorkspacePreference.enabled
                )
                async let quickEntry: Void = loadTodayQuickActions(refresh: true)
                async let commitments: Void = loadCommitments(refresh: true)
                _ = await (dashboard, quickEntry, commitments)
            }
            .task(id: appState.currentUser?.id) {
                async let dashboard: Void = viewModel.loadDashboard(
                    fitnessEnabled: appState.fitnessWorkspacePreference.enabled
                )
                async let quickEntry: Void = loadTodayQuickActions(refresh: false)
                async let commitments: Void = loadCommitments(refresh: false)
                _ = await (dashboard, quickEntry, commitments)
            }
            .sheet(item: $quickCapture) { capture in
                switch capture {
                case .event:
                    QuickEventSheet(initialDate: Date())
                case .task:
                    QuickTaskSheet(initialDate: Date())
                }
            }
            .sheet(isPresented: $showingFacilityDetails) {
                if let fact = viewModel.facilityQuickFact {
                    FacilityTimesSheet(fact: fact) {
                        Task { await viewModel.refreshFitnessTodayCard() }
                    }
                }
            }
            .sheet(isPresented: $showingMealEntry, onDismiss: {
                Task { await refreshTodayNutritionAfterMealEntry() }
            }) {
                if let prompt = quickEntryViewModel.mealPrompt {
                    TodayMealEntrySheet(
                        quickEntryViewModel: quickEntryViewModel,
                        meal: prompt.meal,
                        seedEntries: mealSeedEntries,
                        hasExistingEntries: prompt.hasEntries
                    )
                }
            }
            .sheet(isPresented: $showingNutritionGoals) {
                if let nutrition = viewModel.fitnessTodayCard?.nutrition {
                    TodayNutritionGoalsSheet(
                        date: viewModel.fitnessTodayCard?.date
                            ?? Self.dateOnlyFormatter.string(from: Date()),
                        initialCalories: nutrition.calorieTargetKcal,
                        initialProtein: nutrition.proteinTargetG
                    ) {
                        await viewModel.refreshFitnessTodayCard()
                    }
                }
            }
            .sheet(isPresented: $showingExerciseEntry, onDismiss: {
                Task {
                    await viewModel.loadDashboard(
                        fitnessEnabled: appState.fitnessWorkspacePreference.enabled
                    )
                }
            }) {
                TodayExerciseEntrySheet(viewModel: quickEntryViewModel) {
                    exerciseWasAdded = true
                }
            }
            .sheet(isPresented: $showingCommitments) {
                CommitmentsHubView(
                    viewModel: commitmentsViewModel,
                    currentUserId: appState.currentUser?.id,
                    fallbackMembers: viewModel.familyMembers
                )
            }
        }
    }

    private func loadCommitments(refresh: Bool) async {
        commitmentsViewModel.configure(currentUserId: appState.currentUser?.id)
        await commitmentsViewModel.loadPending(refresh: refresh)
    }

    private func loadTodayQuickActions(refresh: Bool) async {
        if appState.fitnessWorkspacePreference.enabled {
            await quickEntryViewModel.load(refresh: refresh)
        } else {
            // Vi's public schedule is an owner-resolved Today fact. Do not touch the
            // optional private Nutrition workspace merely to show it.
            await quickEntryViewModel.loadViSchedule(
                for: Date(),
                refresh: refresh
            )
        }
    }

    private func refreshTodayNutritionAfterMealEntry() async {
        defer { suppressingNutritionCelebration = false }
        await quickEntryViewModel.refreshMealContext()
        // Food entries are offline-first. Await any already-scheduled upload
        // before asking the server for the compact Today totals.
        _ = try? await FitnessSyncService.shared.syncNow()
        await viewModel.refreshFitnessTodayCard()
    }

    @ViewBuilder
    private var primaryDecision: some View {
        if viewModel.tomorrowCard?.loadPrompt != nil {
            loadPromptCard
        } else {
            tomorrowSortedCard
        }
    }

    @ViewBuilder
    private var tomorrowSortedCard: some View {
        if let card = viewModel.tomorrowCard, card.visible, !card.acknowledged {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TOMORROW")
                            .font(.caption2.weight(.bold))
                            .tracking(1)
                            .opacity(0.7)
                        Text("Tomorrow, sorted")
                            .font(.title3.weight(.semibold))
                    }
                } icon: {
                    Image(systemName: "moon.stars.fill")
                        .font(.title3)
                        .opacity(0.8)
                }

                let items = Array(card.events.prefix(3))
                let facility = viewModel.facilityQuickFact?.tomorrow
                if items.isEmpty && card.tasks.isEmpty && facility?.covered != true {
                    Text("Nothing's in the calendar for tomorrow yet.")
                        .font(.subheadline)
                        .opacity(0.78)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(tomorrowEventTime(event))
                                    .font(.caption)
                                    .frame(width: 62, alignment: .leading)
                                    .opacity(0.72)
                                Text(event.title)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(event.isSchoolMilestone ? 10 : 0)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: event.isSchoolMilestone ? 58 : nil,
                                alignment: .leading
                            )
                            .background {
                                if event.isSchoolMilestone {
                                    SchoolMilestoneBackground()
                                }
                            }
                        }
                        ForEach(card.tasks.prefix(max(0, 3 - items.count))) { task in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("To do")
                                    .font(.caption)
                                    .frame(width: 62, alignment: .leading)
                                    .opacity(0.72)
                                Text(task.title)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        if let facility, facility.covered {
                            tomorrowFacilityRow(
                                label: "Swim",
                                value: facility.familySwimmingLabel
                            )
                            if let weights = facility.weightsRoomLabel {
                                tomorrowFacilityRow(label: "Weights", value: weights)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await viewModel.acknowledgeTomorrow() }
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.coordinationBusy == "ack" {
                                ProgressView().tint(Color(.systemBackground))
                            }
                            Label("Looks right", systemImage: "checkmark")
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(.systemBackground))
                    .foregroundStyle(Color(.label))
                    .disabled(viewModel.coordinationBusy != nil)

                    Button {
                        appState.selectedTab = card.events.isEmpty ? .lists : .calendar
                        if card.events.isEmpty { appState.listsRoute = .tasks }
                    } label: {
                        Text("Fix something")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(.systemBackground))
                    .disabled(viewModel.coordinationBusy != nil)
                }
            }
            .foregroundStyle(Color(.systemBackground))
            .padding(20)
            .background(Color(.label), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }

    private func tomorrowFacilityRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .frame(width: 62, alignment: .leading)
                .opacity(0.72)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private var loadPromptCard: some View {
        if let prompt = viewModel.tomorrowCard?.loadPrompt {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.example_f47e224f.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 10) {
                    Text("NEEDS AN OWNER")
                        .font(.caption2.weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    Text("Who’s handling “\(prompt.title)”?")
                        .font(.headline)

                    loadPromptActions
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func coordinationErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                viewModel.coordinationError = nil
            } label: {
                Text("Dismiss")
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var loadPromptActions: some View {
        let adults = viewModel.familyMembers.filter { $0.memberType == "user" }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(adults) { member in
                    loadAssignmentButton(member)
                }
                deferLoadButton
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(adults) { member in
                    loadAssignmentButton(member)
                }
                deferLoadButton
            }
        }
    }

    private func loadAssignmentButton(_ member: FamilyMemberDTO) -> some View {
        Button {
            Task { await viewModel.assignLoad(to: member) }
        } label: {
            HStack(spacing: 7) {
                if viewModel.coordinationBusy == member.id {
                    ProgressView().controlSize(.small)
                }
                Label(member.name, systemImage: "person.example_35fbacff.circle.badge.checkmark")
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.coordinationBusy != nil)
    }

    private var deferLoadButton: some View {
        Button {
            Task { await viewModel.deferLoad() }
        } label: {
            Text("Later")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.coordinationBusy != nil)
    }

    @ViewBuilder
    private var financeActionSection: some View {
        if let action = viewModel.financeAction {
            plannerSection("Money", icon: "sterlingsign.circle.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(financeActionTitle(action))
                        .font(.headline)

                    NavigationLink {
                        FinanceSimpleView(
                            entryAction: action,
                            preferenceOwner: appState.currentUser?.id
                        )
                    } label: {
                        Label("Open Finance", systemImage: "sterlingsign.circle")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens this money action")
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func financeActionTitle(_ action: TodayFinanceActionDTO) -> String {
        if action.kind == "PAYDAY_TRANSFER" {
            let amount = action.amountMinor.flatMap { amount in
                guard let currency = action.currency else { return nil }
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.currencyCode = currency
                formatter.locale = .hausKlarSelected
                return formatter.string(from: NSNumber(value: Double(amount) / 100))
            } ?? "the protected money".localized
            return String(
                format: "Review moving %@ from %@ to %@".localized,
                amount,
                action.sourceAccountLabel ?? "the spending account".localized,
                action.destinationAccountLabel ?? "the protected account".localized
            )
        }
        if let title = action.title, !title.isEmpty { return title }
        return (action.kind == "PURCHASE_REVIEW"
            ? "Review the selected purchase"
            : "Review the current money habit").localized
    }

    @ViewBuilder
    private var facilityQuickFactSection: some View {
        if let fact = viewModel.facilityQuickFact, fact.today.covered {
            Button {
                HapticManager.selection()
                showingFacilityDetails = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "water.waves")
                        .font(.headline)
                        .foregroundStyle(.blue)
                        .frame(width: 40, height: 40)
                        .background(Color(.systemBackground), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text("SCHOOL TODAY")
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(.secondary)
                        Text(fact.today.familySwimmingLabel)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(facilityQuickDetail(fact))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.blue.opacity(0.18), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See Example School swimming and weights times for today and tomorrow")
        }
    }

    private func facilityQuickDetail(_ fact: FacilityQuickFactDTO) -> String {
        var parts: [String] = []
        if let todayWeights = fact.today.weightsRoomLabel { parts.append(todayWeights) }
        parts.append(
            String(
                format: "Tomorrow: %@".localized,
                fact.tomorrow.familySwimmingLabel
            )
        )
        if let tomorrowWeights = fact.tomorrow.weightsRoomLabel { parts.append(tomorrowWeights) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var prepPacksSection: some View {
        if !viewModel.prepSuggestions.isEmpty || viewModel.prepNotice != nil {
            VStack(alignment: .leading, spacing: 12) {
                if let notice = viewModel.prepNotice {
                    Label(
                        notice,
                        systemImage: viewModel.prepNoticeIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(viewModel.prepNoticeIsError ? .red : .green)
                        .padding(.horizontal, 4)
                }

                ForEach(viewModel.prepSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 14) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prepEventTime(suggestion))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Things to pack for \(suggestion.eventTitle)")
                                    .font(.headline)
                            }
                        } icon: {
                            Image(systemName: "backpack.fill")
                                .foregroundStyle(.tint)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(suggestion.items, id: \.self) { item in
                                Label(item, systemImage: "checkmark")
                                    .font(.subheadline)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                Task { await viewModel.applyPrepPack(suggestion) }
                            } label: {
                                HStack(spacing: 8) {
                                    if viewModel.prepBusy == suggestion.id {
                                        ProgressView().controlSize(.small)
                                    }
                                    Label("Add \(suggestion.items.count) \(suggestion.items.count == 1 ? "task" : "tasks")", systemImage: "plus")
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)

                            HStack(spacing: 8) {
                                Button {
                                    Task { await viewModel.dismissPrepPack(suggestion) }
                                } label: {
                                    Text("Not this time")
                                        .frame(minHeight: 44)
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    appState.openLists(.prepPacks)
                                } label: {
                                    Text("Edit packing list")
                                        .frame(minHeight: 44)
                                }
                                .font(.subheadline.weight(.medium))
                            }
                        }
                        .disabled(viewModel.prepBusy != nil)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func prepEventTime(_ suggestion: PrepPackSuggestionDTO) -> String {
        guard let date = ISODateParser.parse(suggestion.eventStart) else {
            return "Coming up".localized
        }
        let day = Calendar.current.isDateInToday(date)
            ? "Today".localized
            : date.formatted(
                .dateTime.weekday(.wide).locale(.hausKlarSelected)
            )
        return suggestion.eventAllDay
            ? day
            : String(
                format: "%@ at %@".localized,
                day,
                shortTime(date)
            )
    }

    private func tomorrowEventTime(_ event: TomorrowEventDTO) -> String {
        guard !event.allDay else { return "All day" }
        if let date = ISODateParser.parse(event.startTime) {
            return shortTime(date)
        }
        return ""
    }

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                Date().formatted(
                    .dateTime.weekday(.wide).day().month(.wide).locale(locale)
                )
            )
                .font(.title2.weight(.semibold))

            if let user = appState.currentUser {
                Text(
                    String(
                        format: "%@, %@".localized,
                        timeBasedGreeting,
                        user.name
                    )
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let weather = viewModel.dailyBriefing?.weather {
                Label {
                    Text("\(weather.description.capitalized) · \(Int(weather.tempHigh.rounded()))° / \(Int(weather.tempLow.rounded()))°")
                } icon: {
                    Image(systemName: weatherIcon(for: weather.description))
                        .foregroundStyle(.blue)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var needsAttentionSection: some View {
        if hasNeedsAttention {
            plannerSection("Needs attention", icon: "bell.badge.fill") {
                VStack(spacing: 0) {
                    if viewModel.unavailableFeeds.contains("medicine") {
                        vitalFeedUnavailableRow(
                            title: "Medicine status could not refresh",
                            icon: "cross.case.fill",
                            color: .orange,
                            reviewTitle: "Review medicine"
                        ) {
                            appState.openFamily(.medicine)
                        }
                    }

                    ForEach(viewModel.activeIllnesses) { illness in
                        statusButton(
                            title: String(
                                format: "%@ is unwell".localized,
                                viewModel.childNames[illness.childId] ?? "Child".localized
                            ),
                            subtitle: illness.notes ?? "Open the illness tracker".localized,
                            icon: "thermometer.high",
                            color: .red
                        ) {
                            appState.openFamily(.illness, childId: illness.childId)
                        }
                    }

                    ForEach(viewModel.activeNaps) { nap in
                        statusButton(
                            title: String(
                                format: "%@ is sleeping".localized,
                                viewModel.memberName(for: nap.childId) ?? "Child".localized
                            ),
                            subtitle: napSubtitle(nap),
                            icon: "moon.zzz.fill",
                            color: .purple
                        ) {
                            appState.openFamily(.naps, childId: nap.childId)
                        }
                    }

                    ForEach(viewModel.medicineAttention) { medicine in
                        statusButton(
                            title: String(
                                format: "%@ timing for %@".localized,
                                medicine.medicineName,
                                medicine.childName
                            ),
                            subtitle: medicine.isSafeNow
                                ? "Minimum interval has passed — check history and limits before recording".localized
                                : medicineNextSafe(medicine),
                            icon: "cross.case.fill",
                            color: medicine.isSafeNow ? .blue : .orange
                        ) {
                            appState.openFamily(.medicine, childId: medicine.childId)
                        }
                    }

                    ForEach(birthdaysToday) { birthday in
                        statusButton(
                            title: String(
                                format: "%@'s birthday today".localized,
                                birthday.personName
                            ),
                            subtitle: birthday.turningAge.map {
                                String(format: "Turns %lld".localized, Int64($0))
                            } ?? "Birthday today".localized,
                            icon: "birthday.cake.fill",
                            color: .pink
                        ) {
                            appState.openFamily(.birthdays)
                        }
                    }

                }
            }
        }
    }

    @ViewBuilder
    private var plansToSortSection: some View {
        if let urgent = commitmentsViewModel.urgent {
            Button {
                HapticManager.selection()
                commitmentsViewModel.select(urgent)
                showingCommitments = true
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: urgent.kind.symbol)
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .frame(width: 40, height: 40)
                        .background(Color.orange.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(commitmentWaitingTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(urgent.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Text(commitmentUrgencySubtitle(urgent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(14)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the most urgent plan for review")
            .accessibilityIdentifier("todayPlansToSortCard")
        }
    }

    private var commitmentWaitingTitle: String {
        let count = commitmentsViewModel.items.count
        return count == 1
            ? "1 plan to sort".localized
            : String(format: "%lld plans to sort".localized, Int64(count))
    }

    private func commitmentUrgencySubtitle(_ commitment: Commitment) -> String {
        let visibility = commitment.visibility == .owner ? "Just me".localized : "Family".localized
        guard let urgency = commitment.temporalUrgency else {
            return "\(commitment.kind.title) · \(visibility)"
        }
        let date = urgency.formatted(locale: .hausKlarSelected)
        return "\(commitment.kind.title) · \(date) · \(visibility)"
    }

    @ViewBuilder
    private var scheduleSection: some View {
        if dashboardLoadPresentation != .unavailable {
            plannerSection("Up next", icon: "clock") {
                VStack(spacing: 0) {
                    if dashboardLoadPresentation == .loading {
                        loadingRow("Loading today's plan...")
                    } else {
                        if viewModel.eventsUnavailable && relevantEvents.isEmpty {
                            feedUnavailableRow("Calendar could not refresh")
                        }

                        if focusEvent == nil {
                            if !viewModel.eventsUnavailable {
                                actionEmptyState(
                                    title: viewModel.todaysEvents.isEmpty ? "Nothing scheduled yet" : "Nothing else scheduled today",
                                    actionTitle: "Add event",
                                    icon: "calendar.badge.plus"
                                ) {
                                    quickCapture = .event
                                }
                            }
                        } else if let event = focusEvent {
                            Button {
                                openCalendarEvent(event)
                            } label: {
                                eventRow(event, isNext: true)
                            }
                            .buttonStyle(.plain)

                            if relevantEvents.count > 1 {
                                Button {
                                    appState.selectedTab = .calendar
                                } label: {
                                    Text("\(relevantEvents.count - 1) more today")
                                        .frame(minHeight: 44)
                                }
                                .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("todayUpNextSection")
        }
    }

    @ViewBuilder
    private var homeworkSection: some View {
        if !viewModel.upcomingHomework.isEmpty {
            plannerSection("School", icon: "book.fill") {
                VStack(spacing: 0) {
                    ForEach(viewModel.upcomingHomework.prefix(3)) { item in
                        statusButton(
                            title: String(
                                format: "%@'s spellings".localized,
                                item.childName
                            ),
                            subtitle: homeworkDueLabel(item),
                            icon: "textformat.abc",
                            color: item.status == "overdue" ? .red : .purple
                        ) {
                            appState.openHomework(childId: item.childId, spellingsId: item.id)
                        }
                    }
                }
            }
        }
    }

    private func homeworkDueLabel(_ item: TodayHomeworkDTO) -> String {
        let words = item.wordCount == 1
            ? "1 word".localized
            : String(format: "%lld words".localized, Int64(item.wordCount))
        let practices = item.practiceCount == 1
            ? "1 practice".localized
            : String(format: "%lld practices".localized, Int64(item.practiceCount))
        let practice = String(format: "%@ · %@".localized, words, practices)
        guard let due = Self.dateOnlyFormatter.date(from: item.testDate) else {
            return String(
                format: "Test %@ · %@".localized,
                item.testDate,
                practice
            )
        }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: due)
        ).day ?? 0
        let dueText: String
        switch days {
        case ..<0:
            dueText = days == -1
                ? "Due yesterday".localized
                : String(format: "Overdue by %lld days".localized, Int64(-days))
        case 0: dueText = "Due today".localized
        case 1: dueText = "Due tomorrow".localized
        default:
            dueText = String(
                format: "Test %@".localized,
                due.formatted(
                    .dateTime
                        .weekday(.abbreviated)
                        .day()
                        .month(.abbreviated)
                        .locale(.hausKlarSelected)
                )
            )
        }
        return String(format: "%@ · %@".localized, dueText, practice)
    }

    @ViewBuilder
    private var giftPreparationSection: some View {
        if !viewModel.upcomingPresents.isEmpty {
            plannerSection("Gifts", icon: "gift.fill") {
                VStack(spacing: 0) {
                    ForEach(viewModel.upcomingPresents) { item in
                        statusButton(
                            title: item.action,
                            subtitle: giftPreparationSubtitle(item),
                            icon: "gift.fill",
                            color: .pink
                        ) {
                            appState.openPresent(childId: item.childId, presentId: item.id)
                        }
                    }
                }
            }
        }
    }

    private func giftPreparationSubtitle(_ item: TodayPresentDTO) -> String {
        let recipient = item.recipientName ?? "Recipient".localized
        let due: String
        switch item.daysUntilDue {
        case ..<0: due = item.daysUntilDue == -1
            ? "overdue by a day".localized
            : String(
                format: "overdue by %lld days".localized,
                Int64(-item.daysUntilDue)
            )
        case 0: due = "due today".localized
        case 1: due = "due tomorrow".localized
        default:
            due = String(
                format: "due in %lld days".localized,
                Int64(item.daysUntilDue)
            )
        }
        if let owner = item.ownerName {
            return String(format: "%@ · %@ · %@".localized, recipient, due, owner)
        }
        return String(format: "%@ · %@".localized, recipient, due)
    }

    @ViewBuilder
    private var fitnessQuickEntrySection: some View {
        if let prompt = quickEntryViewModel.mealPrompt {
            plannerSection("Quick Fitness", icon: "bolt.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "fork.knife")
                            .font(.headline)
                            .foregroundStyle(.orange)
                            .frame(width: 36, height: 36)
                            .background(Color.orange.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prompt.hasEntries
                                ? "\(prompt.meal.title) started"
                                : "Add \(prompt.meal.title.lowercased())")
                                .font(.headline)
                            Text(prompt.hasEntries
                                ? "Add another item without leaving Today"
                                : "A quick shortcut for your private Nutrition diary")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if quickEntryViewModel.preferencesUseDefaults {
                                Text("Using standard meal times until your saved times are available")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if quickEntryViewModel.preferencesAreCached {
                                Text("Using your saved meal times offline")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { mealQuickActions(prompt) }
                        VStack(alignment: .leading, spacing: 8) { mealQuickActions(prompt) }
                    }
                    .accessibilityElement(children: .contain)
                }
                .padding(.vertical, 12)
                .accessibilityIdentifier("todayMealQuickEntryCard")
            }
        }

        if let notice = quickEntryViewModel.notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("todayQuickEntryNotice")
        }

        if let error = quickEntryViewModel.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Spacer(minLength: 4)
                Button("Try again") {
                    Task { await quickEntryViewModel.load(refresh: true) }
                }
                .disabled(quickEntryViewModel.isLoading)
            }
            .padding(.horizontal, 4)
            .accessibilityIdentifier("todayQuickEntryError")
        }
    }

    @ViewBuilder
    private var fitnessExerciseEntrySection: some View {
        if let card = viewModel.fitnessTodayCard,
           card.session == nil,
           card.primaryAction == nil,
           card.hasCompletedActivityToday != true,
           !exerciseWasAdded {
            plannerSection("Exercise", icon: "figure.run") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add exercise")
                            .font(.headline)
                        Text("Plan a run or strength session for later today.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        HapticManager.selection()
                        showingExerciseEntry = true
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("todayExerciseQuickEntryButton")
                }
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func mealQuickActions(_ prompt: FitnessTodayMealPrompt) -> some View {
        if !prompt.hasEntries, !quickEntryViewModel.yesterdayEntries.isEmpty {
            Button {
                mealSeedEntries = quickEntryViewModel.entriesForYesterdayPrompt()
                suppressingNutritionCelebration = true
                showingMealEntry = true
            } label: {
                Label("Yesterday’s \(prompt.meal.title.lowercased())", systemImage: "clock.arrow.circlepath")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(quickEntryViewModel.busyAction != nil)
            .accessibilityIdentifier("todayRepeatYesterdayMeal")
        }

        Button {
            HapticManager.selection()
            mealSeedEntries = []
            suppressingNutritionCelebration = true
            showingMealEntry = true
        } label: {
            Label(prompt.hasEntries ? "Add or edit foods" : "Add food", systemImage: "square.and.pencil")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(quickEntryViewModel.busyAction != nil)
        .accessibilityIdentifier("todayFillInMeal")
    }

    @ViewBuilder
    private var viTimetableSection: some View {
        if let schedule = quickEntryViewModel.viSchedule,
           schedule.relevant,
           schedule.provider == "vi_training" {
            plannerSection("Vi today", icon: "dumbbell.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    if let reason = schedule.unavailableReason {
                        Label(reason, systemImage: "calendar.badge.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let day = schedule.days.first(where: {
                        $0.date == Self.dateOnlyFormatter.string(from: Date())
                    }), day.covered, !day.classes.isEmpty {
                        ForEach(day.classes) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: entry.classification.symbol)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28, height: 28)
                                    .background(Color.accentColor.opacity(0.1), in: Circle())
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.label)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(entry.displayTime) · \(entry.classification.title)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 8) {
                                        if let bookingURL = SafeExternalURL.web(entry.bookingUrl) {
                                            Link(destination: bookingURL) {
                                                Label("Book in Vi", systemImage: "arrow.up.right.square")
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .accessibilityIdentifier("todayViBookLink-\(entry.id)")
                                        }

                                        Button("Booked") {
                                            Task {
                                                _ = await quickEntryViewModel.bookViClass(
                                                    day: day,
                                                    entry: entry,
                                                    online: networkMonitor.isConnected
                                                )
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(
                                            quickEntryViewModel.busyAction != nil
                                                || !networkMonitor.isConnected
                                        )
                                        .accessibilityIdentifier("todayViBooked-\(entry.id)")
                                    }
                                    if quickEntryViewModel.bookingWindowID == entry.id {
                                        ProgressView("Adding to the family calendar…")
                                            .font(.caption)
                                    }
                                }
                            }
                            .frame(minHeight: 44)
                        }
                    } else if schedule.unavailableReason == nil {
                        Text("No live Vi classes are listed for today.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    let hasClassBookingLink = schedule.days
                        .flatMap(\.classes)
                        .contains { SafeExternalURL.web($0.bookingUrl) != nil }
                    if !hasClassBookingLink,
                       let bookingURL = SafeExternalURL.web(schedule.sourceUrl) {
                        Link(destination: bookingURL) {
                            Label("Book in Vi", systemImage: "arrow.up.right.square")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("todayViBookingLink")
                    }

                    if quickEntryViewModel.viScheduleIsCached {
                        Label("Saved timetable — refresh before booking", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !networkMonitor.isConnected {
                        Label(
                            "Reconnect to add a booked class to the family calendar.",
                            systemImage: "wifi.slash"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("todayViBookingOffline")
                    }
                }
                .padding(.vertical, 10)
                .accessibilityIdentifier("todayViTimetableCard")
            }
        }
    }

    @ViewBuilder
    private var fitnessTodaySection: some View {
        if let card = viewModel.fitnessTodayCard,
           card.session != nil || card.nutrition != nil || card.primaryAction?.kind == "start_strength" {
            plannerSection("Fitness", icon: "figure.run") {
                VStack(alignment: .leading, spacing: 14) {
                    if let session = card.session,
                       let primaryAction = card.primaryAction {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: fitnessSymbol(for: session.sportKey))
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 36, height: 36)
                                .background(Color.accentColor.opacity(0.12), in: Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(fitnessSessionSummary(session))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 10) {
                            if let secondaryAction = card.secondaryAction {
                                Button {
                                    openFitness(secondaryAction, session: session)
                                } label: {
                                    Label(
                                        fitnessActionLabel(secondaryAction.kind),
                                        systemImage: fitnessActionSymbol(secondaryAction.kind)
                                    )
                                    .frame(minHeight: 44)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Opens this workout so you can move it")
                            }

                            Spacer(minLength: 0)

                            Button {
                                openFitness(primaryAction, session: session)
                            } label: {
                                Label(
                                    fitnessActionLabel(primaryAction.kind),
                                    systemImage: fitnessActionSymbol(primaryAction.kind)
                                )
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityHint("Opens \(session.title)")
                            .accessibilityIdentifier("todayFitnessPrimaryAction")
                        }
                    } else if let primaryAction=card.primaryAction,
                              primaryAction.kind == "start_strength" {
                        HStack(alignment:.top,spacing:12) {
                            Image(systemName:"dumbbell.fill")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width:36,height:36)
                                .background(Color.accentColor.opacity(0.12),in:Circle())
                            VStack(alignment:.leading,spacing:4) {
                                Text("Strength workout").font(.headline)
                                Text("Nothing logged today")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            openFitness(primaryAction,session:nil)
                        } label: {
                            Label(
                                fitnessActionLabel(primaryAction.kind),
                                systemImage:fitnessActionSymbol(primaryAction.kind)
                            )
                            .frame(maxWidth:.infinity,minHeight:44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Starts a live blank strength workout now")
                        .accessibilityIdentifier("todayFitnessPrimaryAction")
                    }

                    if card.session != nil || card.primaryAction?.kind == "start_strength",
                       card.nutrition != nil {
                        Divider()
                    }

                    if let nutrition = card.nutrition {
                        let dayIsComplete = TodayNutritionProgressPolicy.dayIsComplete(
                            completedMeals: quickEntryViewModel.completedMeals
                        )
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Nutrition today", systemImage: "fork.knife")
                                    .font(.headline)
                                Spacer()
                                Button(
                                    nutrition.calorieTargetKcal == nil
                                        || nutrition.proteinTargetG == nil
                                        ? "Set goals" : "Edit goals"
                                ) {
                                    HapticManager.selection()
                                    showingNutritionGoals = true
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("todayNutritionGoals")
                            }
                            nutritionMetric(
                                "Calories",
                                value: nutrition.caloriesKcal,
                                target: nutrition.calorieTargetKcal,
                                unit: "kcal",
                                complete: nutrition.caloriesComplete,
                                metric: .calories,
                                hasEntries: nutrition.entryCount > 0,
                                dayIsComplete: dayIsComplete
                            )
                            nutritionMetric(
                                "Protein",
                                value: nutrition.proteinG,
                                target: nutrition.proteinTargetG,
                                unit: "g",
                                complete: nutrition.proteinComplete,
                                metric: .protein,
                                hasEntries: nutrition.entryCount > 0,
                                dayIsComplete: dayIsComplete
                            )
                            Button {
                                HapticManager.selection()
                                appState.openFitness(destination: .log)
                            } label: {
                                Label("Log food", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("todayFitnessLogFood")
                        }
                    }
                }
                .padding(.vertical, 14)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("todayFitnessCard")
            }
        }
    }

    private func nutritionMetric(
        _ label: String,
        value: Double,
        target: Double?,
        unit: String,
        complete: Bool,
        metric: TodayNutritionProgressMetric,
        hasEntries: Bool,
        dayIsComplete: Bool
    ) -> some View {
        let valueDescription = target.map {
            "\(complete ? "" : "at least ")"
                + "\(Int(value.rounded())) of \(Int($0.rounded())) \(unit)"
        } ?? "\(Int(value.rounded())) \(unit), goal not set"
        let progress = TodayNutritionProgressPolicy.progress(
            for: metric,
            value: value,
            target: target,
            valueIsComplete: complete,
            hasEntries: hasEntries,
            dayIsComplete: dayIsComplete
        )
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                if progress?.reachedGoal == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.96, green: 0.67, blue: 0.10))
                        .accessibilityHidden(true)
                }
                Spacer()
                Text(
                    "\(complete ? "" : "≥ ")\(Int(value.rounded())) \(unit)"
                        + (target.map { " of \(Int($0.rounded())) \(unit)" } ?? "")
                )
                .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            TodayNutritionProgressBar(
                fraction: progress?.fraction ?? 0,
                tint: metric == .calories ? .orange : .indigo,
                reachedGoal: progress?.reachedGoal ?? false,
                celebrationIsVisible: !showingMealEntry
                    && !suppressingNutritionCelebration,
                label: label,
                valueDescription: valueDescription,
                accessibilityIdentifier: metric == .calories
                    ? "todayNutritionCaloriesProgress"
                    : "todayNutritionProteinProgress"
            )
        }
    }

    private func openFitness(
        _ action: FitnessTodayCardActionDTO,
        session: FitnessTodayCardSessionDTO?
    ) {
        HapticManager.selection()
        appState.openFitness(
            destination: action.destination,
            targetId: action.targetId ?? session?.id,
            actionKind: action.kind
        )
    }

    private func openCalendarEvent(_ event: CalendarEventDTO) {
        HapticManager.selection()
        appState.preferredCalendarDate = ISODateParser.parse(event.startTime)
        appState.highlightedCalendarResultId = event.id
        appState.selectedTab = .calendar
    }

    private func fitnessSessionSummary(_ session: FitnessTodayCardSessionDTO) -> String {
        var parts: [String] = []
        if let startsAt = session.startsAt.flatMap(ISODateParser.parse) {
            parts.append(shortTime(startsAt))
        } else if session.scheduledDate != nil {
            parts.append("Today".localized)
        }
        if let minutes = session.durationMinutes, minutes > 0 {
            let hours = minutes / 60
            let remainder = minutes % 60
            if hours > 0, remainder > 0 {
                parts.append(
                    String(
                        format: "%lldh %lldm".localized,
                        Int64(hours),
                        Int64(remainder)
                    )
                )
            } else if hours > 0 {
                parts.append(String(format: "%lldh".localized, Int64(hours)))
            } else {
                parts.append(String(format: "%lld min".localized, Int64(minutes)))
            }
        }
        return parts.isEmpty ? "Ready when you are".localized : parts.joined(separator: " • ")
    }

    private func fitnessSymbol(for sportKey: String) -> String {
        switch sportKey {
        case "cycling": "bicycle"
        case "swimming": "figure.pool.swim"
        case "strength": "dumbbell.fill"
        case "walking", "hiking": "figure.walk"
        default: "figure.run"
        }
    }

    private func fitnessActionSymbol(_ kind: String) -> String {
        switch kind {
        case "move_session": "calendar.badge.clock"
        case "resume_activity": "play.fill"
        case "start_strength", "start_session": "play"
        default: "arrow.right"
        }
    }

    private func fitnessActionLabel(_ kind: String) -> String {
        switch kind {
        case "move_session": "Move".localized
        case "resume_activity": "Resume".localized
        case "start_strength": "Start workout".localized
        case "start_session": "Start".localized
        case "open_session": "Open".localized
        default: "Open".localized
        }
    }

    @ViewBuilder
    private var preparationSection: some View {
        if !viewModel.activeRoutines.isEmpty {
            plannerSection("Prepare", icon: "backpack.fill") {
                VStack(spacing: 0) {
                    ForEach(Array(preparationMembers.enumerated()), id: \.element.id) { index, member in
                        let routines = viewModel.activeRoutines.filter { $0.personId == member.id }
                        Button {
                            appState.openLists(.routines)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(routines.first.map { Color(hex: $0.color) } ?? Color.accentColor)
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(routines.map(\.name).joined(separator: ", "))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .frame(minHeight: 44)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)

                        if index < preparationMembers.count - 1 {
                            Divider().padding(.leading, 21)
                        }
                    }
                }
            }
        }
    }

    /// Up to three proactive prompts; hidden entirely when there are none.
    @ViewBuilder
    private var insightsSection: some View {
        if !viewModel.insights.isEmpty || viewModel.insightNotice != nil {
            plannerSection("Suggestions", icon: "lightbulb") {
                VStack(spacing: 0) {
                    if let notice = viewModel.insightNotice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                    let insights = Array(viewModel.insights.prefix(3))
                    ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: insight.iconName)
                                .foregroundStyle(insightColor(insight.kind))
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(insight.message)
                                    .foregroundStyle(.primary)
                                if let detail = insight.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if insight.sourceDocumentId != nil {
                                    Label("From a scanned letter", systemImage: "doc.text.viewfinder")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if let title = insight.suggestedTaskTitle {
                                    Button {
                                        Task { await viewModel.addInsightTask(insight) }
                                    } label: {
                                        Label(
                                            viewModel.insightBusy == insight.id ? "Adding…" : title,
                                            systemImage: "plus.circle.fill"
                                        )
                                        .frame(minHeight: 44)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(viewModel.insightBusy == insight.id)
                                    .padding(.top, 6)
                                    .accessibilityLabel("Add task: \(title)")
                                }
                            }
                            Spacer()
                            Button {
                                Task { await viewModel.dismissInsight(insight.id) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss \(insight.message)")
                        }
                        .padding(.vertical, 10)

                        if index < insights.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
        }
    }

    private func insightColor(_ kind: String) -> Color {
        switch kind {
        case "missing_event": return .blue
        case "prep": return .orange
        case "weather": return .teal
        default: return .red
        }
    }

    /// "On this day" photos. Each page owns its short-lived decoded image while
    /// the shared cache keeps only a cost-bounded reusable copy.
    @ViewBuilder
    private var memoriesSection: some View {
        let visible = Array(viewModel.memories.prefix(5))
        if !visible.isEmpty {
            plannerSection("Memories", icon: "photo.on.rectangle.angled") {
                TabView {
                    ForEach(visible) { memory in
                        memoryCard(memory)
                            .padding(.vertical, 14)
                            .task(id: memory.assetId) {
                                await viewModel.loadMemoryImage(for: memory)
                            }
                            .onDisappear {
                                viewModel.releaseMemoryImage(for: memory.assetId)
                            }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: visible.count > 1 ? .automatic : .never))
                .frame(height: 280)
            }
        }
    }

    private func memoryCard(_ memory: PhotoMemoryDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = viewModel.memoryImages[memory.assetId] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemGroupedBackground))
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
                    .overlay {
                        ProgressView().accessibilityLabel("Loading memory photo")
                    }
            }
            HStack {
                Text(memory.caption)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let takenAt = memory.takenAt, let date = ISODateParser.parse(takenAt) {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var tasksSection: some View {
        if dashboardLoadPresentation != .unavailable {
            plannerSection("To do", icon: "checklist") {
                VStack(spacing: 0) {
                    if dashboardLoadPresentation == .loading {
                        loadingRow("Loading tasks...")
                    } else {
                        if viewModel.tasksUnavailable && viewModel.actionableTasks.isEmpty {
                            feedUnavailableRow("Tasks could not refresh")
                        }

                        if let completed = viewModel.recentlyCompletedTask {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("\(completed.title) completed")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    Task { await viewModel.undoTaskCompletion() }
                                } label: {
                                    Text("Undo")
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                            .padding(.vertical, 4)

                            if !viewModel.actionableTasks.isEmpty {
                                Divider()
                            }
                        }

                        if viewModel.actionableTasks.isEmpty && !viewModel.tasksUnavailable {
                            actionEmptyState(
                                title: "Nothing needs doing",
                                actionTitle: "Add task",
                                icon: "checkmark.circle"
                            ) {
                                quickCapture = .task
                            }
                        } else {
                            ForEach(Array(viewModel.actionableTasks.prefix(3).enumerated()), id: \.element.id) { index, task in
                                HStack(spacing: 8) {
                                    Button {
                                        Task { await viewModel.completeTask(task.id) }
                                    } label: {
                                        Image(systemName: "circle")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Complete \(task.title)")

                                    Button {
                                        appState.highlightedTaskResultId = task.id
                                        appState.openLists(.tasks)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(task.title)
                                                .foregroundStyle(.primary)
                                                .multilineTextAlignment(.leading)
                                            HStack(spacing: 6) {
                                                if let due = task.dueDate.flatMap(ISODateParser.parse) {
                                                    Text(dueLabel(due))
                                                        .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) ? .red : .secondary)
                                                }
                                                if let category = task.category {
                                                    Text(category.capitalized)
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 4)

                                if index < min(viewModel.actionableTasks.count, 3) - 1 {
                                    Divider().padding(.leading, 52)
                                }
                            }

                            if viewModel.actionableTasks.count > 3 {
                                Button {
                                    appState.openLists(.tasks)
                                } label: {
                                    Text("View \(viewModel.actionableTasks.count - 3) more")
                                        .frame(minHeight: 44)
                                }
                                .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                }
            }
        }
    }

    private func plannerSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.localized, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.secondary)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func eventRow(_ event: CalendarEventDTO, isNext: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(event.allDay ? "All day" : eventTime(event.startTime))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isNext ? Color.accentColor : .secondary)
                .frame(width: 52, alignment: .leading)

            RoundedRectangle(cornerRadius: 2)
                .fill(
                    event.sourceColor.map(Color.init(hex:))
                        ?? memberColor(eventPrimaryParticipantID(event))
                )
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.body.weight(isNext ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if isNext {
                        Text("NEXT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tint)
                    }
                }

                HStack(spacing: 6) {
                    Text(eventParticipantLabel(event))
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let affected = eventAffectedLabel(event) {
                    Text("Affects \(affected)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, event.isSchoolMilestone ? 10 : 0)
        .padding(.vertical, event.isSchoolMilestone ? 14 : 10)
        .frame(minHeight: event.isSchoolMilestone ? 84 : nil)
        .background {
            if event.isSchoolMilestone {
                SchoolMilestoneBackground()
            }
        }
        .contentShape(Rectangle())
    }

    private func statusButton(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.localized)
                        .foregroundStyle(.primary)
                    Text(subtitle.localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func vitalFeedUnavailableRow(
        title: LocalizedStringKey,
        icon: String,
        color: Color,
        reviewTitle: LocalizedStringKey,
        review: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    vitalReviewButton(reviewTitle, action: review)
                    retryDashboardButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    vitalReviewButton(reviewTitle, action: review)
                    retryDashboardButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func vitalReviewButton(
        _ title: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .font(.subheadline.weight(.semibold))
    }

    private var retryDashboardButton: some View {
        Button {
            Task {
                await viewModel.loadDashboard(
                    fitnessEnabled: appState.fitnessWorkspacePreference.enabled
                )
            }
        } label: {
            Text("Try again")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .font(.subheadline.weight(.semibold))
        .disabled(viewModel.isLoading)
    }

    private func actionEmptyState(
        title: String,
        actionTitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            Text(title.localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Text(actionTitle.localized)
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 8)
    }

    private func loadingRow(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func feedUnavailableRow(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task {
                    await viewModel.loadDashboard(
                        fitnessEnabled: appState.fitnessWorkspacePreference.enabled
                    )
                }
            } label: {
                Text("Try again")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .font(.subheadline.weight(.semibold))
            .disabled(viewModel.isLoading)
        }
        .padding(.vertical, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    await viewModel.loadDashboard(
                        fitnessEnabled: appState.fitnessWorkspacePreference.enabled
                    )
                }
            } label: {
                Text("Try again")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoading)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var dashboardLoadPresentation: DashboardLoadPresentation {
        DashboardLoadPresentation.resolve(
            hasLoadedBriefing: viewModel.dailyBriefing != nil,
            hasError: viewModel.errorMessage != nil
        )
    }

    private var focusEvent: CalendarEventDTO? {
        relevantEvents.first(where: \.isSchoolMilestone)
            ?? relevantEvents.first { !$0.allDay }
            ?? relevantEvents.first
    }

    private var hasNeedsAttention: Bool {
        !viewModel.activeIllnesses.isEmpty
            || !viewModel.activeNaps.isEmpty
            || !viewModel.medicineAttention.isEmpty
            || viewModel.unavailableFeeds.contains("medicine")
            || !birthdaysToday.isEmpty
    }

    private var birthdaysToday: [BriefingBirthdayDTO] {
        viewModel.dailyBriefing?.upcomingBirthdays.filter { $0.daysUntil == 0 } ?? []
    }

    private var relevantEvents: [CalendarEventDTO] {
        let now = Date()
        return viewModel.todaysEvents.filter { event in
            if event.isSchoolMilestone { return true }
            guard !event.allDay else { return true }
            let boundary = event.endTime.flatMap(ISODateParser.parse)
                ?? ISODateParser.parse(event.startTime)
                ?? .distantPast
            return boundary >= now
        }
    }

    private var preparationMembers: [FamilyMemberDTO] {
        let ids = Set(viewModel.activeRoutines.map(\.personId))
        return viewModel.familyMembers.filter { ids.contains($0.id) }
    }

    private var timeBasedGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning".localized }
        if hour < 17 { return "Good afternoon".localized }
        return "Good evening".localized
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        )
    }

    private func eventTime(_ value: String) -> String {
        guard let date = ISODateParser.parse(value) else { return value }
        return shortTime(date)
    }

    private func memberColor(_ id: String?) -> Color {
        guard let id, let index = viewModel.familyMembers.firstIndex(where: { $0.id == id }) else {
            return .purple
        }
        let colors: [Color] = [.blue, .pink, .green, .orange, .teal]
        return colors[index % colors.count]
    }

    private func eventParticipantIDs(_ event: CalendarEventDTO) -> Set<String> {
        var ids = Set(event.familyMemberIds ?? [])
        if let assignedTo = event.assignedTo { ids.insert(assignedTo) }
        return ids
    }

    private func eventPrimaryParticipantID(_ event: CalendarEventDTO) -> String? {
        let ids = eventParticipantIDs(event)
        return viewModel.familyMembers.first(where: { ids.contains($0.id) })?.id
    }

    private func eventParticipantLabel(_ event: CalendarEventDTO) -> String {
        let ids = eventParticipantIDs(event)
        guard !ids.isEmpty else { return "Everyone".localized }
        let names = viewModel.familyMembers.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? "Family members".localized : names.joined(separator: " & ")
    }

    private func eventAffectedLabel(_ event: CalendarEventDTO) -> String? {
        let ids = Set(event.affectedMemberIds ?? [])
        let names = viewModel.familyMembers.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " & ")
    }

    private func napSubtitle(_ nap: NapDTO) -> String {
        guard let start = ISODateParser.parse(nap.startedAt) else {
            return "Nap in progress".localized
        }
        let minutes = max(0, Int(Date().timeIntervalSince(start) / 60))
        return String(format: "Started %lld min ago".localized, Int64(minutes))
    }

    private func medicineNextSafe(_ medicine: GlanceMedicineDTO) -> String {
        guard let value = medicine.nextSafeAt, let date = ISODateParser.parse(value) else {
            return "Check the dose history and limits before recording".localized
        }
        return String(
            format: "Minimum interval ends at %@ — check before recording".localized,
            shortTime(date)
        )
    }

    private func dueLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Due today".localized }
        if date < Calendar.current.startOfDay(for: Date()) { return "Overdue".localized }
        return ISODateParser.dateOnly(from: date)
    }

    private func weatherIcon(for description: String) -> String {
        let value = description.lowercased()
        if value.contains("rain") { return "cloud.rain.fill" }
        if value.contains("cloud") { return "cloud.sun.fill" }
        if value.contains("snow") { return "cloud.snow.fill" }
        return "sun.max.fill"
    }
}

private struct TodayMealPortion: Identifiable, Equatable {
    let id: String
    let label: String
    let enteredUnit: String
    let defaultAmount: Double
    let canonicalAmount: Double
    let canonicalUnit: String
    let quality: FitnessNutritionMeasurementQuality
}

private struct TodayMealSource: Identifiable {
    let id: String
    let label: String
    let detail: String
    let foodVersionId: String?
    let recipeVersionId: String?
    let portions: [TodayMealPortion]
}

private struct TodayMealDraft: Identifiable {
    let id: String
    let label: String
    let foodVersionId: String?
    let recipeVersionId: String?
    var amount: String
    var portionID: String
    let portions: [TodayMealPortion]
}

private struct TodayMealEntrySheet: View {
    @ObservedObject var quickEntryViewModel: TodayQuickEntryViewModel
    let meal: FitnessMeal
    let seedEntries: [FitnessFoodLogEntry]
    let hasExistingEntries: Bool
    @StateObject private var nutritionViewModel = FitnessNutritionViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedSourceID: String?
    @State private var externalSelection: FitnessFoodBarcodeLookup?
    @State private var lookupResults: [FitnessFoodBarcodeLookup] = []
    @State private var amount = ""
    @State private var portionID = ""
    @State private var drafts: [TodayMealDraft] = []
    @State private var seeded = false
    @State private var isWorking = false
    @State private var logsWereSaved = false
    @State private var localError: String?
    @State private var showingNewFood = false
    @State private var indexedSources: [TodayMealSource] = []

    private var selectedSource: TodayMealSource? {
        guard let selectedSourceID else { return nil }
        return indexedSources.first { $0.id == selectedSourceID }
    }

    private var selectedPortions: [TodayMealPortion] {
        if let externalSelection { return lookupPortions(externalSelection) }
        return selectedSource?.portions ?? []
    }

    private var matchingSources: [TodayMealSource] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, selectedSource == nil, externalSelection == nil else { return [] }
        return Array(
            indexedSources.lazy.filter {
                $0.label.localizedCaseInsensitiveContains(term)
                    || $0.detail.localizedCaseInsensitiveContains(term)
            }.prefix(8)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if !drafts.isEmpty {
                    Section("Foods in this meal") {
                        ForEach($drafts) { $draft in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(draft.label).fontWeight(.semibold)
                                HStack {
                                    TextField("Amount", text: $draft.amount)
                                        .keyboardType(.decimalPad)
                                    Picker("Unit", selection: $draft.portionID) {
                                        ForEach(draft.portions) { portion in
                                            Text(portion.label).tag(portion.id)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                            .disabled(logsWereSaved)
                        }
                        .onDelete { offsets in
                            guard !logsWereSaved else { return }
                            drafts.remove(atOffsets: offsets)
                        }
                    }
                } else if hasExistingEntries {
                    Section {
                        Text("Foods already logged in \(meal.title.lowercased()) will stay there. Add more, or complete the meal now.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !logsWereSaved {
                    Section("Add food") {
                        if selectedSource == nil, externalSelection == nil {
                            TextField("Search foods", text: $search)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: search) { _, _ in
                                    lookupResults = []
                                    localError = nil
                                    nutritionViewModel.foodLookupError = nil
                                }

                            ForEach(matchingSources) { source in
                                Button { choose(source) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(source.label).foregroundStyle(.primary)
                                            Text(source.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               matchingSources.isEmpty {
                                Button {
                                    Task {
                                        lookupResults = await nutritionViewModel.lookupFoods(named: search)
                                    }
                                } label: {
                                    if nutritionViewModel.isLookingUpFood {
                                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                                    } else {
                                        Label("Look up “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”", systemImage: "magnifyingglass.circle")
                                    }
                                }
                                .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)

                                ForEach(lookupResults, id: \.barcode) { result in
                                    Button { choose(result) } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(result.name).foregroundStyle(.primary)
                                            Text([result.brand, "Open Food Facts"].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                Button {
                                    showingNewFood = true
                                } label: {
                                    Label("Add it manually", systemImage: "plus.circle")
                                }
                            }
                        } else {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(externalSelection?.name ?? selectedSource?.label ?? "Food")
                                        .fontWeight(.semibold)
                                    if externalSelection != nil {
                                        Text("Looked-up food").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Change") { resetSearch() }
                            }

                            HStack {
                                TextField("Amount", text: $amount)
                                    .keyboardType(.decimalPad)
                                Picker("Unit", selection: $portionID) {
                                    ForEach(selectedPortions) { portion in
                                        Text(portion.label).tag(portion.id)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: portionID) { _, id in
                                    if let portion = selectedPortions.first(where: { $0.id == id }) {
                                        amount = amountString(portion.defaultAmount)
                                    }
                                }
                            }

                            if let warnings = externalSelection?.warnings, !warnings.isEmpty {
                                Text(warnings.joined(separator: " "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }

                            Button {
                                Task { await addSelection() }
                            } label: {
                                if isWorking {
                                    ProgressView().frame(maxWidth: .infinity)
                                } else {
                                    Text("Add food").frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking || !validSelection)
                        }
                    }
                }

                if logsWereSaved {
                    Section {
                        Label("The foods are saved. Finish completing the meal below.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let error = localError ?? nutritionViewModel.foodLookupError ?? nutritionViewModel.errorMessage ?? quickEntryViewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await completeMeal() }
                    } label: {
                        if isWorking || quickEntryViewModel.busyAction == "complete-meal" {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Complete meal").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isWorking || quickEntryViewModel.busyAction != nil
                            || (!hasExistingEntries && drafts.isEmpty)
                            || drafts.contains(where: { !valid($0) })
                    )
                }
            }
            .navigationTitle("\(meal.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
            }
            .sheet(isPresented: $showingNewFood) {
                FitnessFoodEditorSheet(viewModel: nutritionViewModel)
            }
        }
        .task {
            await nutritionViewModel.loadLogHome()
            rebuildSourceIndex()
            seedYesterdayIfNeeded()
        }
        .onChange(of: nutritionViewModel.foods) { _, _ in
            rebuildSourceIndex()
            seedYesterdayIfNeeded()
        }
        .onChange(of: nutritionViewModel.recipes) { _, _ in
            rebuildSourceIndex()
            seedYesterdayIfNeeded()
        }
        .accessibilityIdentifier("todayMealFillInSheet")
    }

    private var validSelection: Bool {
        guard let value = Double(amount), value.isFinite, value > 0 else { return false }
        return selectedPortions.contains { $0.id == portionID }
    }

    private func valid(_ draft: TodayMealDraft) -> Bool {
        guard let value = Double(draft.amount), value.isFinite, value > 0 else { return false }
        return draft.portions.contains { $0.id == draft.portionID }
    }

    private func rebuildSourceIndex() {
        let foods = nutritionViewModel.foods.compactMap { food -> TodayMealSource? in
            guard food.active, let version = food.currentVersion else { return nil }
            return foodSource(food, version: version)
        }
        let recipes = nutritionViewModel.recipes.compactMap { recipe -> TodayMealSource? in
            guard recipe.active, let version = recipe.currentVersion else { return nil }
            return recipeSource(recipe, version: version)
        }
        indexedSources = (foods + recipes).sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private func choose(_ source: TodayMealSource) {
        guard let portion = source.portions.first else { return }
        selectedSourceID = source.id
        externalSelection = nil
        amount = amountString(portion.defaultAmount)
        portionID = portion.id
        lookupResults = []
        localError = nil
    }

    private func choose(_ lookup: FitnessFoodBarcodeLookup) {
        guard let portion = lookupPortions(lookup).first else { return }
        selectedSourceID = nil
        externalSelection = lookup
        amount = amountString(portion.defaultAmount)
        portionID = portion.id
        lookupResults = []
        localError = nil
    }

    private func resetSearch() {
        search = ""
        selectedSourceID = nil
        externalSelection = nil
        lookupResults = []
        amount = ""
        portionID = ""
        localError = nil
    }

    private func addSelection() async {
        guard validSelection, let entered = Double(amount),
              let portion = selectedPortions.first(where: { $0.id == portionID }) else { return }
        isWorking = true
        defer { isWorking = false }
        let source: TodayMealSource
        if let externalSelection {
            guard let food = await nutritionViewModel.createLookupFood(externalSelection),
                  let version = food.currentVersion else {
                localError = nutritionViewModel.errorMessage ?? "That food could not be saved."
                return
            }
            source = TodayMealSource(
                id: "food:\(food.id)", label: food.name,
                detail: externalSelection.brand ?? "Saved food",
                foodVersionId: version.id, recipeVersionId: nil,
                portions: selectedPortions
            )
        } else if let selectedSource {
            source = selectedSource
        } else {
            return
        }
        drafts.append(TodayMealDraft(
            id: UUID().uuidString, label: source.label,
            foodVersionId: source.foodVersionId,
            recipeVersionId: source.recipeVersionId,
            amount: amountString(entered), portionID: portion.id,
            portions: source.portions
        ))
        HapticManager.selection()
        resetSearch()
    }

    private func completeMeal() async {
        guard !isWorking else { return }
        isWorking = true
        localError = nil
        defer { isWorking = false }
        if !logsWereSaved, !drafts.isEmpty {
            let loggedAt = Date()
            let values: [FitnessFoodLogDraft] = drafts.compactMap { draft in
                guard let entered = Double(draft.amount), entered.isFinite, entered > 0,
                      let portion = draft.portions.first(where: { $0.id == draft.portionID }),
                      portion.defaultAmount > 0 else { return nil }
                return FitnessFoodLogDraft(
                    foodVersionId: draft.foodVersionId,
                    recipeVersionId: draft.recipeVersionId,
                    label: draft.label,
                    loggedAt: loggedAt,
                    localTimezone: TimeZone.current.identifier,
                    meal: meal,
                    enteredAmount: entered,
                    enteredUnit: portion.enteredUnit,
                    canonicalAmount: entered / portion.defaultAmount * portion.canonicalAmount,
                    canonicalUnit: portion.canonicalUnit,
                    measurementQuality: portion.quality,
                    notes: nil,
                    contextTags: []
                )
            }
            // Each draft row carries the id its diary entry will take, so a
            // retry after a partial failure updates those entries rather than
            // logging the items that already saved a second time.
            guard values.count == drafts.count,
                  await nutritionViewModel.saveMealLogs(values, entryIds: drafts.map(\.id)) else {
                localError = nutritionViewModel.errorMessage ?? "Check each food amount and try again."
                return
            }
            logsWereSaved = true
        }
        if await quickEntryViewModel.completeMeal(meal) {
            dismiss()
        }
    }

    private func seedYesterdayIfNeeded() {
        guard !seeded, !nutritionViewModel.isLoading else { return }
        seeded = true
        guard !seedEntries.isEmpty else { return }
        var missing = false
        drafts = seedEntries.compactMap { entry in
            guard let source = source(for: entry) else {
                missing = true
                return nil
            }
            var portions = source.portions
            let matched = portions.first {
                $0.enteredUnit == entry.enteredUnit
                    && $0.canonicalUnit == entry.canonicalUnit
            }
            let portion: TodayMealPortion
            if let matched {
                portion = matched
            } else {
                portion = TodayMealPortion(
                    id: "history:\(entry.id)", label: entry.enteredUnit,
                    enteredUnit: entry.enteredUnit,
                    defaultAmount: entry.enteredAmount,
                    canonicalAmount: entry.canonicalAmount,
                    canonicalUnit: entry.canonicalUnit,
                    quality: entry.measurementQuality
                )
                portions.insert(portion, at: 0)
            }
            return TodayMealDraft(
                id: UUID().uuidString, label: source.label,
                foodVersionId: entry.foodVersionId,
                recipeVersionId: entry.recipeVersionId,
                amount: amountString(entry.enteredAmount),
                portionID: portion.id,
                portions: portions
            )
        }
        if missing {
            localError = "Some foods from yesterday are no longer available. Review the foods below before completing."
        }
    }

    private func source(for entry: FitnessFoodLogEntry) -> TodayMealSource? {
        if let id = entry.foodVersionId,
           let food = nutritionViewModel.foods.first(where: { $0.versions.contains(where: { $0.id == id }) }),
           let version = food.versions.first(where: { $0.id == id }) {
            return foodSource(food, version: version)
        }
        if let id = entry.recipeVersionId,
           let recipe = nutritionViewModel.recipes.first(where: { $0.versions.contains(where: { $0.id == id }) }),
           let version = recipe.versions.first(where: { $0.id == id }) {
            return recipeSource(recipe, version: version)
        }
        return nil
    }

    private func foodSource(_ food: FitnessFood, version: FitnessFoodVersion) -> TodayMealSource {
        var portions = [TodayMealPortion(
            id: "base:\(version.id)", label: version.referenceUnit,
            enteredUnit: version.referenceUnit,
            defaultAmount: version.referenceAmount,
            canonicalAmount: version.referenceAmount,
            canonicalUnit: version.referenceUnit,
            quality: .estimated
        )]
        portions.append(contentsOf: food.servings.filter(\.active).map { serving in
            TodayMealPortion(
                id: "serving:\(serving.id)",
                label: serving.name == serving.unit ? serving.unit : "\(serving.name) (\(serving.unit))",
                enteredUnit: serving.unit,
                defaultAmount: serving.amount,
                canonicalAmount: serving.canonicalAmount,
                canonicalUnit: serving.canonicalUnit,
                quality: serving.measurementQuality
            )
        })
        return TodayMealSource(
            id: "food:\(food.id)", label: food.name,
            detail: food.brand ?? "Saved food",
            foodVersionId: version.id, recipeVersionId: nil,
            portions: portions
        )
    }

    private func recipeSource(_ recipe: FitnessRecipe, version: FitnessRecipeVersion) -> TodayMealSource? {
        let portions: [TodayMealPortion]
        if let weight = version.finishedWeightG, weight > 0 {
            portions = [TodayMealPortion(
                id: "recipe-g:\(version.id)", label: "g", enteredUnit: "g",
                defaultAmount: min(weight, 100), canonicalAmount: min(weight, 100),
                canonicalUnit: "g", quality: .estimated
            )]
        } else if let servings = version.servings, servings > 0 {
            portions = [TodayMealPortion(
                id: "recipe-serving:\(version.id)", label: "serving", enteredUnit: "serving",
                defaultAmount: 1, canonicalAmount: 1,
                canonicalUnit: "serving", quality: .standardServing
            )]
        } else {
            return nil
        }
        return TodayMealSource(
            id: "recipe:\(recipe.id)", label: recipe.name,
            detail: "Recipe", foodVersionId: nil,
            recipeVersionId: version.id, portions: portions
        )
    }

    private func lookupPortions(_ lookup: FitnessFoodBarcodeLookup) -> [TodayMealPortion] {
        var values = [TodayMealPortion(
            id: "lookup-base", label: lookup.referenceUnit,
            enteredUnit: lookup.referenceUnit,
            defaultAmount: lookup.referenceAmount,
            canonicalAmount: lookup.referenceAmount,
            canonicalUnit: lookup.referenceUnit,
            quality: .estimated
        )]
        if let serving = lookup.serving {
            values.append(TodayMealPortion(
                id: "lookup-serving", label: serving.name,
                enteredUnit: serving.unit, defaultAmount: serving.amount,
                canonicalAmount: serving.amount,
                canonicalUnit: lookup.referenceUnit,
                quality: .standardServing
            ))
        }
        return values
    }

    private func amountString(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

private struct TodayNutritionGoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = TodayNutritionGoalsViewModel()
    @State private var calorieValue: String
    @State private var proteinValue: String

    let date: String
    let initialCalories: Double?
    let initialProtein: Double?
    let onSaved: () async -> Void

    init(
        date: String,
        initialCalories: Double?,
        initialProtein: Double?,
        onSaved: @escaping () async -> Void
    ) {
        self.date = date
        self.initialCalories = initialCalories
        self.initialProtein = initialProtein
        self.onSaved = onSaved
        _calorieValue = State(initialValue: Self.fieldText(initialCalories))
        _proteinValue = State(initialValue: Self.fieldText(initialProtein))
    }

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    Text("Calories")
                    Spacer()
                    TextField("Daily calories", text: $calorieValue)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .accessibilityIdentifier("todayCaloriesGoal")
                    Text("kcal")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Protein")
                    Spacer()
                    TextField("Daily protein", text: $proteinValue)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .accessibilityIdentifier("todayProteinGoal")
                    Text("g")
                        .foregroundStyle(.secondary)
                }
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Daily goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!isValid || viewModel.isLoading)
                    .accessibilityIdentifier("todayNutritionGoalsSave")
                }
            }
            .task {
                await viewModel.load()
                if calorieValue.isEmpty,
                   let value = viewModel.value(for: .caloriesKcal, on: date) {
                    calorieValue = Self.fieldText(value)
                }
                if proteinValue.isEmpty,
                   let value = viewModel.value(for: .proteinG, on: date) {
                    proteinValue = Self.fieldText(value)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(viewModel.isLoading)
    }

    private var values: (calories: Double, protein: Double)? {
        guard let calories = Double(calorieValue), calories > 0,
              let protein = Double(proteinValue), protein > 0 else { return nil }
        return (calories, protein)
    }

    private var isValid: Bool { values != nil }

    private func save() async {
        guard let values else { return }
        if await viewModel.save(
            calories: values.calories,
            protein: values.protein,
            on: date
        ) {
            await onSaved()
            dismiss()
        }
    }

    private static func fieldText(_ value: Double?) -> String {
        value.map { String(format: "%g", $0) } ?? ""
    }
}

private struct TodayExerciseEntrySheet: View {
    @ObservedObject var viewModel: TodayQuickEntryViewModel
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = FitnessTodayExerciseKind.run
    @State private var start = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    Picker("Exercise", selection: $kind) {
                        ForEach(FitnessTodayExerciseKind.allCases) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("todayExerciseKind")

                    DatePicker(
                        "Starts",
                        selection: $start,
                        displayedComponents: .hourAndMinute
                    )
                    .accessibilityIdentifier("todayExerciseStart")
                }

                if kind == .strength {
                    strengthAvailabilitySection
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.busyAction != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await viewModel.addExercise(kind: kind, start: start) {
                                onAdded()
                                dismiss()
                            }
                        }
                    } label: {
                        if viewModel.busyAction == "exercise" {
                            ProgressView()
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(viewModel.busyAction != nil)
                    .accessibilityIdentifier("todayExerciseSave")
                }
            }
            .onChange(of: kind) { _, value in
                guard value == .strength else { return }
                Task { await viewModel.loadStrengthAvailability(for: start) }
            }
            .onChange(of: Calendar.current.startOfDay(for: start)) { _, _ in
                guard kind == .strength else { return }
                Task { await viewModel.loadStrengthAvailability(for: start) }
            }
        }
        .interactiveDismissDisabled(viewModel.busyAction != nil)
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("todayExerciseSheet")
    }

    @ViewBuilder
    private var strengthAvailabilitySection: some View {
        Section {
            if viewModel.isLoadingAvailability {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading strength timetable…")
                        .foregroundStyle(.secondary)
                }
            } else if let availability = viewModel.strengthAvailability {
                if let day = availability.days.first(where: {
                    $0.date == localDate(start)
                }), day.covered, !day.windows.isEmpty {
                    ForEach(day.windows) { window in
                        Button {
                            if let value = FitnessQuickEntryPolicy.date(
                                for: window.start,
                                on: start
                            ) {
                                start = value
                                HapticManager.selection()
                            }
                        } label: {
                            HStack {
                                Label(window.displayLabel, systemImage: "clock")
                                Spacer()
                                if FitnessQuickEntryPolicy.wireTime(from: start) == window.start {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("todayStrengthWindow-\(window.id)")
                    }
                } else {
                    Label(
                        availability.unavailableReason
                            ?? "No strength timetable coverage is available for this day.",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .foregroundStyle(.secondary)
                }

                if let sourceURL = SafeExternalURL.web(availability.sourceUrl) {
                    Link(destination: sourceURL) {
                        Label("Open \(availability.sourceTitle)", systemImage: "arrow.up.right.square")
                    }
                }

                if viewModel.availabilityIsCached {
                    Label("Saved timetable — refresh before relying on it", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(
                    "The strength timetable is unavailable. You can still choose a start manually.",
                    systemImage: "wifi.exclamationmark"
                )
                .foregroundStyle(.secondary)
                Button("Try timetable again") {
                    Task { await viewModel.loadStrengthAvailability(for: start, refresh: true) }
                }
            }
        } header: {
            Text(strengthTimetableTitle)
        } footer: {
            Text("The start time remains editable even when no timetable is available.")
        }
    }

    private var strengthTimetableTitle: String {
        viewModel.strengthAvailability?.displayTitle ?? "Strength timetable".localized
    }

    private func localDate(_ date: Date) -> String {
        ISODateParser.stringDateOnly(from: date)
    }
}

private struct FacilityTimesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var timetableDays: [FacilityDaySummaryDTO]?
    @State private var timetableLoading = false
    @State private var timetableError: String?
    @State private var swimmingBooking: FacilitySwimmingBookingSelection?
    @State private var weightsBooking: FacilityWeightsBookingSelection?
    @State private var bookingNotice: String?

    let fact: FacilityQuickFactDTO
    let onStrengthPlanned: () -> Void

    private static let bookingURL = SafeExternalURL.web("https://bookings.example.invalid")

    private static let sourceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static let sourceDayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                Section("Actions") {
                    Button {
                        if timetableDays != nil {
                            timetableDays = nil
                            timetableError = nil
                        } else {
                            Task { await loadTimetable() }
                        }
                    } label: {
                        if timetableLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading timetable…")
                            }
                        } else {
                            Label(
                                timetableDays == nil ? "Next 2 weeks" : "Today & tomorrow",
                                systemImage: "calendar"
                            )
                        }
                    }
                    .disabled(timetableLoading)

                    if let bookingURL = Self.bookingURL {
                        Link(destination: bookingURL) {
                            Label("Book swimming", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                if let bookingNotice {
                    Section {
                        Label(bookingNotice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let timetableDays {
                    ForEach(timetableDays, id: \.date) { day in
                        facilitySection(title: weekday(day.date), day: day)
                    }
                } else {
                    facilitySection(title: "Today", day: fact.today)
                    facilitySection(title: "Tomorrow", day: fact.tomorrow)
                }

                if let timetableError {
                    Section {
                        Label(timetableError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Try again") { Task { await loadTimetable() } }
                            .disabled(timetableLoading)
                    }
                }

                Section("Timetable") {
                    if let sourceTitle = fact.sourceTitle {
                        LabeledContent("Source", value: sourceTitle)
                    }
                    if let currentTo = fact.currentTo {
                        LabeledContent("Runs to", value: displayDate(currentTo))
                    }
                    if fact.updateDue {
                        Label(
                            "A fresh Example School timetable will be needed soon.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Example School facilities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $swimmingBooking) { selection in
            FacilitySwimmingBookingSheet(selection: selection) { notice in
                bookingNotice = notice
            }
        }
        .sheet(item: $weightsBooking) { selection in
            FacilityWeightsBookingSheet(selection: selection) { notice in
                bookingNotice = notice
                onStrengthPlanned()
            }
        }
    }

    @ViewBuilder
    private func facilitySection(
        title: String,
        day: FacilityDaySummaryDTO
    ) -> some View {
        Section {
            if day.covered {
                familySwimmingRow(day)
                if !day.laneSwimming.isEmpty {
                    facilityRow(
                        icon: "water.waves",
                        label: "Lane swimming",
                        windows: day.laneSwimming,
                        emptyLabel: "None scheduled"
                    )
                }
                if day.weightsRelevant {
                    weightsRoomRow(day)
                }
            } else {
                ContentUnavailableView(
                    "No timetable coverage",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Upload the latest Example School timetable from Calendar.")
                )
            }
        } header: {
            Text("\(title) · \(displayDate(day.date))")
        }
    }

    @ViewBuilder
    private func familySwimmingRow(_ day: FacilityDaySummaryDTO) -> some View {
        if day.familySwimming.isEmpty {
            facilityRow(
                icon: "figure.pool.swim",
                label: "Family swimming",
                windows: [],
                emptyLabel: day.poolClosed ? "Pool closed" : "None scheduled"
            )
        } else {
            ForEach(day.familySwimming, id: \.label) { window in
                HStack(spacing: 12) {
                    Label("Family swimming", systemImage: "figure.pool.swim")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(window.label)
                            .font(.subheadline.weight(.semibold))
                        Button("Booked") {
                            UsageMonitor.control(.openSwimmingBooking(.todayFacilities))
                            swimmingBooking = FacilitySwimmingBookingSelection(
                                date: day.date,
                                window: window
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minHeight: 40)
                        .accessibilityLabel(
                            "Booked swimming on \(displayDate(day.date)) within \(window.label)"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func weightsRoomRow(_ day: FacilityDaySummaryDTO) -> some View {
        if day.weightsRoom.isEmpty {
            facilityRow(
                icon: "dumbbell.fill",
                label: "Weights room",
                windows: [],
                emptyLabel: day.weightsRoomStatus == "closed"
                    ? "Closed" : "Times unavailable"
            )
        } else {
            ForEach(day.weightsRoom, id: \.label) { window in
                HStack(spacing: 12) {
                    Label("Weights room", systemImage: "dumbbell.fill")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(window.label)
                            .font(.subheadline.weight(.semibold))
                        Button("Book") {
                            weightsBooking = FacilityWeightsBookingSelection(
                                date: day.date,
                                window: window
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minHeight: 40)
                        .accessibilityLabel(
                            "Plan strength on \(displayDate(day.date)) within \(window.label)"
                        )
                    }
                }
            }
        }
    }

    private func facilityRow(
        icon: String,
        label: String,
        windows: [FacilityTimeWindowDTO],
        emptyLabel: String
    ) -> some View {
        LabeledContent {
            Text(windows.isEmpty ? emptyLabel.localized : windows.map(\.label).joined(separator: ", "))
                .multilineTextAlignment(.trailing)
        } label: {
            Label(label.localized, systemImage: icon)
        }
    }

    private func displayDate(_ value: String) -> String {
        guard let date = Self.sourceDayParser.date(from: value) else { return value }
        return Self.sourceDateFormatter.string(from: date)
    }

    private func weekday(_ value: String) -> String {
        guard let date = Self.sourceDayParser.date(from: value) else { return "Day" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    @MainActor
    private func loadTimetable() async {
        guard !timetableLoading else { return }
        timetableLoading = true
        timetableError = nil
        defer { timetableLoading = false }
        do {
            let days: [FacilityDaySummaryDTO] = try await APIClient.shared.get(
                "/facilities/timetable",
                queryItems: [
                    URLQueryItem(name: "start", value: fact.today.date),
                    URLQueryItem(name: "days", value: "14"),
                ]
            )
            timetableDays = days
        } catch {
            timetableError = "The two-week timetable could not be loaded."
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
        .environmentObject(NetworkMonitor())
}
