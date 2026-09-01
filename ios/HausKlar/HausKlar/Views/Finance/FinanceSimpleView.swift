import Charts
import SwiftUI

enum FinanceNativeSection: String, Identifiable {
    case overview
    case goals
    case activity
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Position".localized
        case .goals: "Savings".localized
        case .activity: "Activity".localized
        case .more: "More".localized
        }
    }
}

struct FinanceSimpleInitialRoute: Equatable {
    let section: FinanceNativeSection
    let scope: FinanceActivityScope

    static func resolve(
        entryAction: TodayFinanceActionDTO?,
        storedScope: FinanceActivityScope?
    ) -> Self {
        guard let entryAction else {
            return Self(section: .overview, scope: storedScope ?? .mine)
        }
        return Self(
            section: .more,
            scope: entryAction.spaceKind == "HOUSEHOLD" ? .household : .mine
        )
    }
}

private struct FinanceSavingsChartPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let balanceMinor: Int
}

struct FinanceSimpleView: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel: FinanceSimpleViewModel
    @State private var selectedSection: FinanceNativeSection
    @State private var financeScope: FinanceActivityScope
    @State private var editingGoal: FinanceGoalSummaryDTO?
    @State private var showingGoalEditor = false
    private let preferenceOwner: String?
    private let entryAction: TodayFinanceActionDTO?

    init(
        entryAction: TodayFinanceActionDTO? = nil,
        preferenceOwner: String? = nil
    ) {
        self.entryAction = entryAction
        self.preferenceOwner = preferenceOwner
        let initialRoute = FinanceSimpleInitialRoute.resolve(
            entryAction: entryAction,
            storedScope: Self.storedScope(for: preferenceOwner)
        )
        _selectedSection = State(initialValue: initialRoute.section)
        _financeScope = State(initialValue: initialRoute.scope)
        _viewModel = StateObject(
            wrappedValue: FinanceSimpleViewModel(
                entryAction: entryAction,
                initialScope: initialRoute.scope
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            scopeControls

            switch selectedSection {
            case .overview:
                financeOverview
            case .goals:
                savingsPlan
            case .activity:
                FinanceActivityView(
                    initialScope: financeScope,
                    entryAction: entryAction,
                    presentation: .activity
                )
                .id("activity-\(financeScope.rawValue)")
            case .more:
                FinanceActivityView(
                    initialScope: financeScope,
                    entryAction: entryAction,
                    presentation: .management
                )
                .id("management-\(financeScope.rawValue)")
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(selectedSection == .overview ? "Finance" : selectedSection.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadOverview()
        }
        .onChange(of: financeScope) { _, newScope in
            rememberScope(newScope)
            Task {
                if selectedSection == .goals {
                    await viewModel.selectScope(newScope)
                } else {
                    await viewModel.selectOverviewScope(newScope)
                }
            }
        }
        .onChange(of: selectedSection) { _, newSection in
            Task {
                if newSection == .overview {
                    await viewModel.loadOverview()
                } else if newSection == .goals {
                    await viewModel.load()
                }
            }
        }
        .onChange(of: networkMonitor.isConnected) { _, connected in
            guard connected else { return }
            Task {
                if selectedSection == .overview, viewModel.overview == nil {
                    await viewModel.loadOverview(forceRefresh: true)
                } else if selectedSection == .goals, viewModel.goals.isEmpty {
                    await viewModel.load(forceRefresh: true)
                }
            }
        }
        .toolbar {
            if selectedSection != .overview {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        selectedSection = .overview
                    } label: {
                        Label("Position", systemImage: "chevron.left")
                    }
                    .frame(minHeight: 44)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        selectedSection = .activity
                    } label: {
                        Label("Activity", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        selectedSection = .goals
                    } label: {
                        Label("Savings", systemImage: "target")
                    }
                    Divider()
                    Button {
                        selectedSection = .more
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                } label: {
                    Label("Finance destinations", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Finance destinations")
            }
        }
        .sheet(isPresented: $showingGoalEditor, onDismiss: { editingGoal = nil }) {
            FinanceGoalEditorSheet(
                goal: editingGoal,
                defaultCurrency: viewModel.overview?.currency
                    ?? viewModel.goals.first?.currency
                    ?? "GBP",
                isSaving: viewModel.isSavingGoal
            ) { name, targetMinor, deadline, allocatedMinor, currency in
                let saved = await viewModel.saveGoal(
                    name: name,
                    targetMinor: targetMinor,
                    deadline: deadline,
                    currentlyAllocatedMinor: allocatedMinor,
                    currency: currency,
                    editing: editingGoal
                )
                if saved { showingGoalEditor = false }
                return saved
            }
        }
    }

    private var scopeControls: some View {
        Picker("Money view", selection: $financeScope) {
            ForEach(FinanceActivityScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .disabled(viewModel.isLoading || viewModel.isLoadingOverview)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var financeOverview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if viewModel.isOverviewInitialLoading {
                    overviewLoadingState
                } else if let overview = viewModel.overview,
                          overview.scope == financeScope.rawValue {
                    paydayOverviewCard(overview)
                    spendingOverviewCard(overview)
                    budgetOverviewCard(overview)
                    overviewDestinations
                } else {
                    overviewErrorState
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.loadOverview(forceRefresh: true)
        }
        .accessibilityIdentifier("financeOverview")
    }

    private var overviewLoadingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView("Loading overview…")
                .font(.headline)
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 150, height: 18)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.14))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground), in: cardShape)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var overviewErrorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(viewModel.errorMessage ?? "Finance overview could not load.".localized)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await viewModel.loadOverview(forceRefresh: true) }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    private func spendingOverviewCard(_ overview: FinanceOverviewDTO) -> some View {
        let categories = overview.spendingByCategory.filter { $0.spentMinor > 0 }
        let chartCategories = Array(categories.prefix(6))
        let chartHeight = max(150, chartCategories.count * 38)

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spent this month")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(money(overview.spendingMinor, currency: overview.currency))
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text("\(dateText(overview.monthStart)) – \(dateText(overview.throughDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if categories.isEmpty {
                emptyOverviewLine(
                    "No spending recorded this month.",
                    systemImage: "checkmark.circle"
                )
            } else {
                Chart(chartCategories) { category in
                    BarMark(
                        x: .value("Spent", category.spentMinor),
                        y: .value("Category", category.name.localized)
                    )
                    .foregroundStyle(spendingTypeColor(category.spendingType).gradient)
                    .cornerRadius(5)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let name = value.as(String.self) {
                                Text(name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(height: CGFloat(chartHeight))
                .accessibilityLabel("Spending by category")

                VStack(spacing: 0) {
                    ForEach(categories) { category in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .fill(spendingTypeColor(category.spendingType))
                                .frame(width: 9, height: 9)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name.localized)
                                    .font(.subheadline.weight(.semibold))
                                Text(spendingTypeName(category.spendingType))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(money(category.spentMinor, currency: overview.currency))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        if category.id != categories.last?.id { Divider() }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityIdentifier("financeOverviewSpending")
    }

    private func budgetOverviewCard(_ overview: FinanceOverviewDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Budget buckets", systemImage: "gauge.with.dots.needle.67percent")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            if overview.budgetBuckets.isEmpty {
                emptyOverviewSetup(
                    "No budget buckets are configured.",
                    systemImage: "tray",
                    actionTitle: "Open Goals",
                    destination: .goals
                )
            } else {
                ForEach(overview.budgetBuckets) { bucket in
                    budgetBucketRow(bucket, currency: overview.currency)
                    if bucket.id != overview.budgetBuckets.last?.id { Divider() }
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityIdentifier("financeOverviewBudgets")
    }

    private func budgetBucketRow(
        _ bucket: FinanceOverviewBudgetBucketDTO,
        currency: String
    ) -> some View {
        let progress = bucket.budgetMinor > 0
            ? min(1, max(0, Double(bucket.spentMinor) / Double(bucket.budgetMinor)))
            : 0
        let remainingText = bucket.remainingMinor >= 0
            ? "\(money(bucket.remainingMinor, currency: currency)) left"
            : "\(money(abs(bucket.remainingMinor), currency: currency)) over"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bucket.name.localized)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(money(bucket.spentMinor, currency: currency)) of \(money(bucket.budgetMinor, currency: currency))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            ProgressView(value: progress)
                .tint(bucket.remainingMinor >= 0 ? .accentColor : .orange)
            Text(remainingText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(bucket.remainingMinor >= 0 ? Color.secondary : Color.orange)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func paydayOverviewCard(_ overview: FinanceOverviewDTO) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Current position".localized, systemImage: "building.columns.fill")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            if let available = overview.currentAvailableMinor {
                VStack(alignment: .leading, spacing: 3) {
                    Text(money(available, currency: overview.currency))
                        .font(.largeTitle.weight(.bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                    Text("Available across current accounts".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                emptyOverviewSetup(
                    "No current-account balance is available.",
                    systemImage: "building.columns",
                    actionTitle: "Open setup",
                    destination: .more
                )
            }

            if overview.nextPaycheckDate != nil
                || overview.nextPaycheckMinor != nil
                || overview.leftUntilPaydayMinor != nil {
                Divider()
            }

            if overview.nextPaycheckDate != nil || overview.nextPaycheckMinor != nil {
                amountDetailRow(
                    title: overview.nextPaycheckDate.map {
                        String(format: "Next payday · %@".localized, dateText($0))
                    } ?? "Next paycheck".localized,
                    amount: overview.nextPaycheckMinor,
                    currency: overview.currency
                )
            }

            if overview.commitmentsBeforePaydayCount > 0 {
                amountDetailRow(
                    title: "Known commitments before payday".localized,
                    amount: overview.commitmentsBeforePaydayMinor,
                    currency: overview.currency
                )
            }

            if let left = overview.leftUntilPaydayMinor {
                amountDetailRow(
                    title: "Position after known commitments".localized,
                    amount: left,
                    currency: overview.currency
                )
            }

            Divider()
            Text("Still to pay this month".localized)
                .font(.subheadline.weight(.semibold))

            if overview.upcomingCommitments.isEmpty {
                Text("Nothing else known to pay this month.".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(overview.upcomingCommitments) { commitment in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commitment.name)
                            .font(.subheadline.weight(.semibold))
                        Text(dateText(commitment.dueDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(money(commitment.amountMinor, currency: overview.currency))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityIdentifier("financeOverviewPayday")
    }

    private func savingsOverviewCard(_ overview: FinanceOverviewDTO) -> some View {
        let points = overview.savingsSeries.compactMap { point -> FinanceSavingsChartPoint? in
            guard let date = ISODateParser.parse(point.date) else { return nil }
            return FinanceSavingsChartPoint(date: date, balanceMinor: point.balanceMinor)
        }

        return VStack(alignment: .leading, spacing: 14) {
            Label("Savings", systemImage: "banknote.fill")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            if let balance = overview.savingsBalanceMinor {
                Text(money(balance, currency: overview.currency))
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)

                if let change = overview.savingsChangeMinor {
                    Text(savingsChangeText(change, currency: overview.currency))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(change >= 0 ? Color.green : Color.orange)
                        .monospacedDigit()
                }

                if points.count > 1 {
                    Chart(points) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.balanceMinor)
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.1).gradient)
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.balanceMinor)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) {
                            AxisGridLine().foregroundStyle(.clear)
                            AxisTick().foregroundStyle(.secondary.opacity(0.4))
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .frame(height: 150)
                    .accessibilityLabel(
                        "Savings trend ending at \(money(balance, currency: overview.currency))"
                    )
                }
            } else {
                emptyOverviewSetup(
                    "No savings balance is available.",
                    systemImage: "chart.line.uptrend.xyaxis",
                    actionTitle: "Open setup",
                    destination: .more
                )
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityIdentifier("financeOverviewSavings")
    }

    private var overviewDestinations: some View {
        VStack(spacing: 0) {
            overviewDestinationRow(
                title: "Activity",
                detail: financeScope == .household
                    ? "Shared household transactions"
                    : "Your classified spending",
                systemImage: "list.bullet.rectangle",
                destination: .activity
            )
            Divider().padding(.leading, 48)
            overviewDestinationRow(
                title: "Savings",
                detail: "Portfolio, crypto, targets and monthly plans",
                systemImage: "target",
                destination: .goals
            )
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
    }

    private func overviewDestinationRow(
        title: String,
        detail: String,
        systemImage: String,
        destination: FinanceNativeSection
    ) -> some View {
        Button {
            HapticManager.selection()
            selectedSection = destination
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.localized)
                        .font(.headline)
                    Text(detail.localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            String(format: "Opens %@".localized, title.localized)
        )
    }

    private func amountDetailRow(
        title: String,
        amount: Int?,
        currency: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let amount {
                Text(money(amount, currency: currency))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func emptyOverviewLine(_ text: String, systemImage: String) -> some View {
        Label(text.localized, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func emptyOverviewSetup(
        _ text: String,
        systemImage: String,
        actionTitle: String,
        destination: FinanceNativeSection
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text.localized, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(actionTitle.localized) {
                selectedSection = destination
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spendingTypeName(_ value: String) -> String {
        switch value.uppercased() {
        case "FIXED": "Fixed".localized
        case "FLEXIBLE": "Flexible".localized
        case "DISCRETIONARY": "Discretionary".localized
        default: "Uncategorised".localized
        }
    }

    private func spendingTypeColor(_ value: String) -> Color {
        switch value.uppercased() {
        case "FIXED": .indigo
        case "FLEXIBLE": .blue
        case "DISCRETIONARY": .orange
        default: .gray
        }
    }

    private func savingsChangeText(_ amount: Int, currency: String) -> String {
        if amount > 0 {
            return String(
                format: "+%@ over this period".localized,
                money(amount, currency: currency)
            )
        }
        if amount < 0 {
            return String(
                format: "−%@ over this period".localized,
                money(abs(amount), currency: currency)
            )
        }
        return "No change over this period".localized
    }

    private var overviewSnapshot: FinanceMonthlySnapshot? {
        if let goal = viewModel.selectedGoal,
           let snapshot = viewModel.monthlySnapshot(for: goal) {
            return snapshot
        }
        return viewModel.monthlySnapshots.values.sorted { $0.currency < $1.currency }.first
    }

    private var decisionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Money now")
                .font(.title3.weight(.bold))

            decisionRow(
                title: "Needs attention",
                value: attentionValue,
                icon: hasAttention ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                tint: hasAttention ? .orange : .green
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                quickLookCard(
                    title: "Available after commitments",
                    value: viewModel.safeToSpend.map(safeSpendText) ?? "Not calculated".localized,
                    icon: "sterlingsign.circle.fill",
                    tint: .blue
                )
                quickLookCard(
                    title: "Next bill",
                    value: viewModel.nextBill.map {
                        "\($0.name) · \(money($0.amountMinor, currency: $0.currency))"
                    } ?? "No bill saved".localized,
                    icon: "calendar.circle.fill",
                    tint: .purple
                )
            }
        }
        .accessibilityIdentifier("financeDecisionSummary")
    }

    private var attentionValue: String {
        if let entryAction {
            return entryAction.title ?? "Review your Finance action".localized
        }
        if let goal = viewModel.selectedGoal,
           let action = viewModel.pendingPaydayAction(for: goal) {
            return String(
                format: "Set aside %@".localized,
                money(action.amountMinor, currency: action.currency)
            )
        }
        return "Nothing needs attention".localized
    }

    private var hasAttention: Bool {
        if entryAction != nil { return true }
        guard let goal = viewModel.selectedGoal else { return false }
        return viewModel.pendingPaydayAction(for: goal) != nil
    }

    private func decisionRow(
        title: String,
        value: String,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityElement(children: .combine)
    }

    private func monthlyDetail(_ snapshot: FinanceMonthlySnapshot) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                cashflowCard(snapshot)
                spendingChart(snapshot)
            }
            .padding(.top, 12)
        } label: {
            Label("Monthly detail", systemImage: "chart.bar.xaxis")
                .font(.headline)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
    }

    private func cashflowCard(_ snapshot: FinanceMonthlySnapshot) -> some View {
        let remaining = snapshot.incomeMinor - snapshot.spendingMinor
        let maximum = max(snapshot.incomeMinor, snapshot.spendingMinor, 1)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This month")
                        .font(.title3.weight(.bold))
                    Text("\(dateText(snapshot.startDate)) – \(dateText(snapshot.endDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: remaining >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                    .font(.title)
                    .foregroundStyle(remaining >= 0 ? Color.green : Color.orange)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(money(abs(remaining), currency: snapshot.currency))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text(remaining >= 0 ? "left after spending" : "spent above income")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Chart {
                BarMark(
                    x: .value("Type", "In"),
                    y: .value("Amount", snapshot.incomeMinor)
                )
                .foregroundStyle(Color.green.gradient)
                .cornerRadius(8)
                .annotation(position: .top) {
                    Text(money(snapshot.incomeMinor, currency: snapshot.currency))
                        .font(.caption.weight(.bold).monospacedDigit())
                }
                BarMark(
                    x: .value("Type", "Out"),
                    y: .value("Amount", snapshot.spendingMinor)
                )
                .foregroundStyle(Color.orange.gradient)
                .cornerRadius(8)
                .annotation(position: .top) {
                    Text(money(snapshot.spendingMinor, currency: snapshot.currency))
                        .font(.caption.weight(.bold).monospacedDigit())
                }
            }
            .chartYScale(domain: 0...(Double(maximum) * 1.18))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .frame(height: 104)
            .accessibilityLabel(
                "Money in \(money(snapshot.incomeMinor, currency: snapshot.currency)); money out \(money(snapshot.spendingMinor, currency: snapshot.currency))"
            )
        }
        .padding(18)
        .background(Color(.tertiarySystemGroupedBackground), in: cardShape)
        .overlay { cardShape.stroke(Color.blue.opacity(0.18), lineWidth: 1) }
        .accessibilityIdentifier("financeCashflowCard")
    }

    @ViewBuilder
    private func spendingChart(_ snapshot: FinanceMonthlySnapshot) -> some View {
        let categories = Array(snapshot.categories.filter { $0.amountMinor > 0 }.prefix(6))
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Spending")
                    .font(.title3.weight(.bold))

                ZStack {
                    Chart(categories) { category in
                        SectorMark(
                            angle: .value("Amount", category.amountMinor),
                            innerRadius: .ratio(0.62),
                            angularInset: 2
                        )
                        .cornerRadius(4)
                        .foregroundStyle(by: .value("Category", categoryName(category.key)))
                    }
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 10)

                    VStack(spacing: 2) {
                        Text(money(snapshot.spendingMinor, currency: snapshot.currency))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .minimumScaleFactor(0.72)
                            .lineLimit(1)
                        Text("spent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 52)
                    .allowsHitTesting(false)
                }
                .frame(height: 260)
                .accessibilityIdentifier("financeSpendingChart")
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        }
    }

    @ViewBuilder
    private var overviewAtGlance: some View {
        if viewModel.safeToSpend != nil || viewModel.nextBill != nil {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                if let safe = viewModel.safeToSpend {
                    quickLookCard(
                        title: "Available",
                        value: safeSpendText(safe),
                        icon: "checkmark.circle.fill",
                        tint: .blue
                    )
                }
                if let bill = viewModel.nextBill {
                    quickLookCard(
                        title: "Next bill",
                        value: money(bill.amountMinor, currency: bill.currency),
                        icon: "calendar.circle.fill",
                        tint: .purple
                    )
                }
            }
        }
    }

    private var overviewGoals: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Savings targets")
                    .font(.headline)
                Spacer()
                Button("See all") {
                    withAnimation { selectedSection = .goals }
                }
                .font(.subheadline.weight(.semibold))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.goals) { goal in
                        overviewGoalCard(goal)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func overviewGoalCard(_ goal: FinanceGoalSummaryDTO) -> some View {
        Button {
            viewModel.chooseGoal(goal.id)
            HapticManager.selection()
            withAnimation { selectedSection = .goals }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: goalIcon(goal))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: Circle())
                    Spacer()
                    Text("\(Int((progress(for: goal) * 100).rounded()))%")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(goal.name)
                    .font(.headline)
                    .lineLimit(2)
                ProgressView(value: progress(for: goal))
                    .tint(.accentColor)
                Text("\(money(goal.currentlyAllocatedMinor, currency: goal.currency)) of \(money(goal.targetMinor, currency: goal.currency))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(16)
            .frame(width: 220, alignment: .leading)
            .frame(minHeight: 148, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this goal")
    }

    private var noSpendingDataCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.pie.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No spending data yet")
                .font(.title3.weight(.bold))
            Button("Open activity") {
                withAnimation { selectedSection = .activity }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
    }

    private func categoryName(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
            .localized
    }

    private var savingsPlan: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if viewModel.isInitialLoading && viewModel.goals.isEmpty {
                    loadingState
                } else {
                    if let spaceId = viewModel.activeSpace?.id {
                        FinancePortfolioSection(
                            spaceId: spaceId,
                            goal: viewModel.selectedGoal
                        )
                        .id("savings-portfolio-\(spaceId)")
                    }

                    if viewModel.goals.isEmpty {
                        emptyState
                    }

                    if viewModel.goals.count > 1 {
                        goalSelector
                    }

                    if let goal = viewModel.selectedGoal {
                        savingsHero(goal)

                        if let error = viewModel.errorMessage {
                        statusCard(
                                error,
                                systemImage: "arrow.clockwise.circle",
                                tint: .orange,
                                showsRetry: true
                            )
                        }
                        if let notice = viewModel.notice {
                            statusCard(
                                notice,
                                systemImage: "checkmark.circle.fill",
                                tint: .green,
                                showsRetry: false
                            )
                        }

                        planChoicesDisclosure(goal)
                        monthlyProgressCard(goal)
                        nextStepCard(goal)
                        quickLookGrid(goal)
                        planDetails(goal)
                        fullFinanceLink
                    }
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.load(forceRefresh: true)
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: networkMonitor.isConnected) { _, connected in
            guard connected, viewModel.goals.isEmpty else { return }
            Task { await viewModel.load(forceRefresh: true) }
        }
        .toolbar {
            if selectedSection == .goals {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        editingGoal = nil
                        showingGoalEditor = true
                    } label: {
                        Label("Add goal", systemImage: "plus")
                    }
                    .disabled(viewModel.isSavingGoal || viewModel.activeSpace == nil)
                    .accessibilityIdentifier("financeAddGoal")
                    if viewModel.isLoading && !viewModel.isInitialLoading {
                    ProgressView()
                        .accessibilityLabel("Updating savings plans")
                    }
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Loading savings…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .accessibilityElement(children: .combine)
    }

    private func savingsHero(_ goal: FinanceGoalSummaryDTO) -> some View {
        let fraction = progress(for: goal)
        let percent = Int((fraction * 100).rounded())

        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: goalIcon(goal))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(goal.name)
                        .font(.title2.weight(.bold))
                    Text(dateText(goal.deadline))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    editingGoal = goal
                    showingGoalEditor = true
                } label: {
                    Label("Edit goal", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Edit \(goal.name)")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Allocated to this goal".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(money(goal.currentlyAllocatedMinor, currency: goal.currency))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text("of \(money(goal.targetMinor, currency: goal.currency))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: fraction)
                .tint(.accentColor)
                .scaleEffect(x: 1, y: 1.6)
                .accessibilityLabel("\(goal.name) progress")
                .accessibilityValue("\(percent) percent")

            HStack {
                Label("\(percent)%", systemImage: "chart.line.uptrend.xyaxis")
                Spacer(minLength: 12)
                Text("\(money(goal.remainingMinor, currency: goal.currency)) left")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .overlay { cardShape.stroke(Color.accentColor.opacity(0.2), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("financeGoalHero")
    }

    private func planChoicesDisclosure(_ goal: FinanceGoalSummaryDTO) -> some View {
        DisclosureGroup {
            monthlyPlanPicker(goal)
                .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare monthly plans")
                    .font(.headline)
                if let chosen = viewModel.chosenPlan(for: goal) {
                    Text("Using \(planName(chosen.effortLevel)): \(money(chosen.plannedMonthlySavingMinor, currency: chosen.currency))/month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Open to choose an amount")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
    }

    private func monthlyPlanPicker(_ goal: FinanceGoalSummaryDTO) -> some View {
        let plans = viewModel.plans(for: goal)
        let monthlyAmounts = Set(plans.map(\.plannedMonthlySavingMinor))

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Monthly plan")
                    .font(.title3.weight(.bold))
                Spacer(minLength: 8)
                Text("\(money(viewModel.requiredMonthlyMinor(for: goal), currency: goal.currency)) needed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if plans.isEmpty {
                Button("Create choices") {
                    Task { await viewModel.load(forceRefresh: true) }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
            } else if monthlyAmounts.count == 1,
                      let plan = plans.first(where: { $0.effortLevel == "MEDIUM" }) ?? plans.first {
                monthlyTargetButton(plan, goal: goal)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(plans) { plan in
                        monthlyPlanButton(plan, goal: goal)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityIdentifier("financeMonthlyPlan")
    }

    private func monthlyTargetButton(
        _ plan: FinancePlanComparisonDTO,
        goal: FinanceGoalSummaryDTO
    ) -> some View {
        let chosenAmount = viewModel.chosenPlan(for: goal)?.plannedMonthlySavingMinor
        let selected = chosenAmount == plan.plannedMonthlySavingMinor

        return Button {
            guard !selected else { return }
            HapticManager.selection()
            Task { await viewModel.select(plan) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "target")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly target")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(money(plan.plannedMonthlySavingMinor, currency: plan.currency))
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text("each month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if viewModel.selectingPlanId == plan.id {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemGroupedBackground), in: cardShape)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.selectingPlanId != nil)
        .accessibilityLabel(
            "Monthly target, \(money(plan.plannedMonthlySavingMinor, currency: plan.currency))"
        )
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier("financeMonthlyTarget")
    }

    private func monthlyPlanButton(
        _ plan: FinancePlanComparisonDTO,
        goal: FinanceGoalSummaryDTO
    ) -> some View {
        let selected = viewModel.chosenPlan(for: goal)?.effortLevel == plan.effortLevel
        let tint = planTint(plan.effortLevel)

        return Button {
            guard !viewModel.isSelected(plan) else { return }
            HapticManager.selection()
            Task { await viewModel.select(plan) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(selected ? tint : tint.opacity(0.12))
                        .frame(width: 36, height: 36)
                    if viewModel.selectingPlanId == plan.id {
                        ProgressView()
                            .controlSize(.small)
                            .tint(selected ? .white : tint)
                    } else {
                        Image(systemName: planIcon(plan.effortLevel))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(selected ? .white : tint)
                    }
                }

                Text(planName(plan.effortLevel))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(money(plan.plannedMonthlySavingMinor, currency: plan.currency))
                    .font(.headline.weight(.bold).monospacedDigit())
                    .minimumScaleFactor(0.68)
                    .lineLimit(1)
                Text("a month")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .background(
                selected ? tint.opacity(0.12) : Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? tint : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.selectingPlanId != nil)
        .accessibilityLabel(
            "\(planName(plan.effortLevel)), \(money(plan.plannedMonthlySavingMinor, currency: plan.currency)) a month"
        )
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier("financePlan-\(plan.effortLevel.lowercased())")
    }

    private func monthlyProgressCard(_ goal: FinanceGoalSummaryDTO) -> some View {
        let plan = viewModel.chosenPlan(for: goal) ?? viewModel.displayPlan(for: goal)
        let pace = plan?.plannedMonthlySavingMinor ?? 0
        let confirmed = viewModel.confirmedThisMonthMinor(for: goal)
        let fraction = pace > 0 ? min(1, Double(confirmed) / Double(pace)) : 0
        let remaining = max(0, pace - confirmed)
        let currency = plan?.currency ?? goal.currency

        return HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        Color.green,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                    Text("this month")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 104, height: 104)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("This month")
                    .font(.headline)
                amountLine("Saved", amount: confirmed, currency: currency)
                amountLine("Plan", amount: pace, currency: currency)
                Divider()
                Text("\(money(remaining, currency: currency)) left")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "This month, \(money(confirmed, currency: currency)) saved of \(money(pace, currency: currency))"
        )
        .accessibilityIdentifier("financeMonthlyProgress")
    }

    @ViewBuilder
    private func nextStepCard(_ goal: FinanceGoalSummaryDTO) -> some View {
        let chosen = viewModel.chosenPlan(for: goal)
        let firstChange = chosen?.categories
            .filter { $0.reductionMinor > 0 }
            .max { $0.reductionMinor < $1.reductionMinor }

        if let action = viewModel.pendingPaydayAction(for: goal) {
            HStack(spacing: 14) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("Set aside \(money(action.amountMinor, currency: action.currency))")
                        .font(.headline)
                    Text(dateText(action.dueDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1), in: cardShape)
        } else if let chosen, let firstChange {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.orange, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Try this")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(firstChange.name)
                        .font(.headline)
                    Text("\(money(firstChange.reductionMinor, currency: chosen.currency)) towards the goal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: cardShape)
        }
    }

    @ViewBuilder
    private func quickLookGrid(_ goal: FinanceGoalSummaryDTO) -> some View {
        let month = viewModel.monthlySnapshot(for: goal)
        if month != nil || viewModel.safeToSpend != nil || viewModel.nextBill != nil || viewModel.easyWin != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("At a glance")
                    .font(.title3.weight(.bold))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    if let month {
                        quickLookCard(
                            title: "Money in",
                            value: money(month.incomeMinor, currency: month.currency),
                            icon: "arrow.down.left.circle.fill",
                            tint: .green
                        )
                        quickLookCard(
                            title: "Money out",
                            value: money(month.spendingMinor, currency: month.currency),
                            icon: "arrow.up.right.circle.fill",
                            tint: .orange
                        )
                    }
                    if let safe = viewModel.safeToSpend {
                        quickLookCard(
                            title: "Available",
                            value: safeSpendText(safe),
                            icon: "checkmark.circle.fill",
                            tint: .blue
                        )
                    }
                    if let bill = viewModel.nextBill {
                        quickLookCard(
                            title: "Next bill",
                            value: money(bill.amountMinor, currency: bill.currency),
                            icon: "calendar.circle.fill",
                            tint: .purple
                        )
                    }
                }
            }
        }
    }

    private func quickLookCard(
        title: String,
        value: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.72)
                .lineLimit(1)
            Text(title.localized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func planDetails(_ goal: FinanceGoalSummaryDTO) -> some View {
        if let plan = viewModel.chosenPlan(for: goal) ?? viewModel.displayPlan(for: goal) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 16) {
                    planResult(plan)
                    if plan.categories.contains(where: { $0.reductionMinor > 0 }) {
                        Divider()
                        planFundingBreakdown(plan)
                    }
                }
                .padding(.top, 14)
            } label: {
                Label("Plan details", systemImage: "slider.horizontal.3")
                    .font(.headline)
            }
            .tint(.primary)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        }
    }

    private func amountLine(_ label: String, amount: Int, currency: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.localized)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(money(amount, currency: currency))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private func planName(_ effort: String) -> String {
        switch effort.uppercased() {
        case "EASY": "Easy".localized
        case "MEDIUM": "Steady".localized
        case "HARD": "Fast".localized
        default: effort.capitalized
        }
    }

    private func planIcon(_ effort: String) -> String {
        switch effort.uppercased() {
        case "EASY": "leaf.fill"
        case "MEDIUM": "equal.circle.fill"
        case "HARD": "bolt.fill"
        default: "circle.fill"
        }
    }

    private func planTint(_ effort: String) -> Color {
        switch effort.uppercased() {
        case "EASY": .green
        case "MEDIUM": .blue
        case "HARD": .orange
        default: .accentColor
        }
    }

    private var goalSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a goal")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.goals) { goal in
                        goalButton(goal)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func goalButton(_ goal: FinanceGoalSummaryDTO) -> some View {
        let selected = viewModel.selectedGoal?.id == goal.id
        let chosen = viewModel.chosenPlan(for: goal)
        let required = viewModel.requiredMonthlyMinor(for: goal)
        let subtitle = "\(dateText(goal.deadline)) · \(money(required, currency: goal.currency))/month needed"
        let tierText: String
        let accessibilityValue: String
        if let chosen {
            let tier = FinanceSimpleViewModel.title(for: chosen.effortLevel)
            tierText = "\(tier) · \(money(chosen.plannedMonthlySavingMinor, currency: chosen.currency))/month"
            accessibilityValue = "\(tier) tier chosen"
        } else {
            tierText = "Choose a tier"
            accessibilityValue = "No tier chosen"
        }
        let fill = selected
            ? Color.accentColor.opacity(0.12)
            : Color(.secondarySystemGroupedBackground)
        let outline = selected ? Color.accentColor : Color.secondary.opacity(0.2)

        return Button {
            viewModel.chooseGoal(goal.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(goal.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(tierText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .frame(width: 210, alignment: .leading)
            .frame(minHeight: 76, alignment: .leading)
            .padding(12)
            .background(
                fill,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        outline,
                        lineWidth: selected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(goal.name), target \(money(goal.targetMinor, currency: goal.currency)) by \(dateText(goal.deadline))"
        )
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows this savings goal")
    }

    private func planFundingBreakdown(_ plan: FinancePlanComparisonDTO) -> some View {
        let reductions = plan.categories
            .filter { $0.reductionMinor > 0 }
            .sorted { $0.reductionMinor > $1.reductionMinor }
        let totalReduction = reductions.reduce(0) { $0 + $1.reductionMinor }
        let existingSurplus = max(0, plan.plannedMonthlySavingMinor - totalReduction)

        return VStack(alignment: .leading, spacing: 8) {
            Text("How the monthly saving is funded")
                .font(.subheadline.weight(.semibold))
            if existingSurplus > 0 {
                breakdownRow(
                    "Existing monthly surplus",
                    amount: existingSurplus,
                    currency: plan.currency
                )
            }
            ForEach(Array(reductions.prefix(4))) { category in
                breakdownRow(
                    String(
                        format: "Spend less on %@".localized,
                        category.name
                    ),
                    amount: category.reductionMinor,
                    currency: plan.currency
                )
            }
            if reductions.count > 4 {
                Text("Plus \(reductions.count - 4) smaller changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func breakdownRow(_ label: String, amount: Int, currency: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.localized)
            Spacer(minLength: 8)
            Text(money(amount, currency: currency))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func planResult(_ plan: FinancePlanComparisonDTO) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("What this achieves")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if plan.goalShortfallAtTargetMinor <= 0 {
                Label {
                    Text(
                        "Reaches the target by "
                            + dateText(FinanceSimpleViewModel.completionDate(for: plan))
                    )
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Text(
                    "By \(dateText(plan.targetDate)): "
                        + "\(money(plan.projectedAmountAtTargetMinor, currency: plan.currency)) saved, "
                        + "\(money(plan.goalShortfallAtTargetMinor, currency: plan.currency)) short."
                )
                if let finish = plan.supportedGoalDate {
                    Text("Likely finish: \(dateText(finish))")
                        .fontWeight(.semibold)
                }
            }
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var fullFinanceLink: some View {
        if let fullFinanceURL {
            FinanceWebHandoffButton(destination: fullFinanceURL) {
                HStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line")
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Full Finance on the web")
                            .font(.headline)
                        Text("Transactions, evidence, charts and detailed settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("The browser may ask you to sign in again")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape)
            .accessibilityHint("Confirms before opening detailed Finance in your browser")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "target")
                .font(.system(.largeTitle, design: .rounded).weight(.medium))
                .foregroundStyle(.tint)
            Text("Set a savings target")
                .font(.title3.weight(.bold))
            Text("Add an amount, what you have saved and a date. HausKlar will show the monthly target.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                editingGoal = nil
                showingGoalEditor = true
            } label: {
                Label("Add a goal", systemImage: "plus")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.activeSpace == nil || viewModel.isSavingGoal)
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Try again") {
                Task { await viewModel.load(forceRefresh: true) }
            }
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    private func statusCard(
        _ text: String,
        systemImage: String,
        tint: Color,
        showsRetry: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
            if showsRetry {
                Button("Retry") { Task { await viewModel.load(forceRefresh: true) } }
                    .frame(minHeight: 44)
            }
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var fullFinanceURL: URL? {
        FinanceWebRouter.configured()?.url(
            section: "plan",
            scope: financeScope.webScope,
            mode: "full"
        )
    }

    private static func scopeStorageKey(for owner: String) -> String {
        OwnerScopedPreferences.financeScope(userID: owner)
    }

    private static func storedScope(for owner: String?) -> FinanceActivityScope? {
        guard let owner else { return nil }
        return UserDefaults.standard.string(forKey: scopeStorageKey(for: owner))
            .flatMap(FinanceActivityScope.init(rawValue:))
    }

    private func rememberScope(_ scope: FinanceActivityScope) {
        guard let preferenceOwner else { return }
        UserDefaults.standard.set(
            scope.rawValue,
            forKey: Self.scopeStorageKey(for: preferenceOwner)
        )
    }

    private func progress(for goal: FinanceGoalSummaryDTO) -> Double {
        guard goal.targetMinor > 0 else { return 0 }
        return min(1, max(0, Double(goal.currentlyAllocatedMinor) / Double(goal.targetMinor)))
    }

    private func goalIcon(_ goal: FinanceGoalSummaryDTO) -> String {
        let name = goal.name.lowercased()
        if name.contains("house") || name.contains("home") || name.contains("deposit") {
            return "house.fill"
        }
        if name.contains("holiday") || name.contains("travel") {
            return "airplane"
        }
        if name.contains("car") {
            return "car.fill"
        }
        if name.contains("emergency") || name.contains("buffer") {
            return "lifepreserver.fill"
        }
        return "target"
    }

    private func money(_ minor: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = .hausKlarSelected
        formatter.maximumFractionDigits = minor.isMultiple(of: 100) ? 0 : 2
        return formatter.string(from: NSNumber(value: Double(minor) / 100))
            ?? "\(currency) \(Double(minor) / 100)"
    }

    private func dateText(_ value: String) -> String {
        guard let date = ISODateParser.parse(value) else { return value }
        return date.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .locale(.hausKlarSelected)
        )
    }

    private func safeSpendText(_ safe: FinanceSafeSpendSnapshot) -> String {
        if let amount = safe.amountMinor {
            return money(amount, currency: safe.currency)
        }
        if let low = safe.lowMinor, let high = safe.highMinor {
            if low == high { return money(high, currency: safe.currency) }
            return "\(money(low, currency: safe.currency))–\(money(high, currency: safe.currency))"
        }
        return money(0, currency: safe.currency)
    }

}
