import Foundation
import os

@MainActor
protocol FinanceSimpleAPI: Sendable {
    func fetchOverview(
        scope: FinanceActivityScope,
        forceRefresh: Bool
    ) async throws -> FinanceOverviewDTO
    func fetchSpaces(forceRefresh: Bool) async throws -> [FinanceSpaceDTO]
    func fetchGoals(spaceId: String, forceRefresh: Bool) async throws -> [FinanceGoalSummaryDTO]
    func fetchPlans(spaceId: String, forceRefresh: Bool) async throws -> [FinancePlanComparisonDTO]
    func generatePlans(spaceId: String, goalId: String) async throws -> FinancePlanSetDTO
    func activatePlan(id: String) async throws -> FinancePlanComparisonDTO
    func fetchPaydayActions(spaceId: String, forceRefresh: Bool) async throws -> [FinancePaydayActionDTO]
    func fetchOpportunities(spaceId: String, forceRefresh: Bool) async throws -> [FinanceFindingDTO]
    func fetchReports(spaceId: String, forceRefresh: Bool) async throws -> [FinanceDailyCoachReportDTO]
    func runAnalysis(_ request: FinanceAnalysisQueryDTO) async throws -> FinanceAnalysisResultDTO
    func createGoal(
        spaceId: String,
        request: FinanceGoalSaveRequestDTO
    ) async throws -> FinanceGoalSummaryDTO
    func updateGoal(
        id: String,
        request: FinanceGoalSaveRequestDTO
    ) async throws -> FinanceGoalSummaryDTO
}

struct LiveFinanceSimpleAPI: FinanceSimpleAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchOverview(
        scope: FinanceActivityScope,
        forceRefresh: Bool
    ) async throws -> FinanceOverviewDTO {
        try await client.get(
            "/finance/overview",
            queryItems: [URLQueryItem(name: "scope", value: scope.rawValue)],
            bypassCache: forceRefresh
        )
    }

    func fetchSpaces(forceRefresh: Bool) async throws -> [FinanceSpaceDTO] {
        try await client.get("/finance/spaces", bypassCache: forceRefresh)
    }

    func fetchGoals(spaceId: String, forceRefresh: Bool) async throws -> [FinanceGoalSummaryDTO] {
        try await client.get(
            "/finance/goals",
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)],
            bypassCache: forceRefresh
        )
    }

    func fetchPlans(spaceId: String, forceRefresh: Bool) async throws -> [FinancePlanComparisonDTO] {
        try await client.get(
            "/finance/plans",
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)],
            bypassCache: forceRefresh
        )
    }

    func generatePlans(spaceId: String, goalId: String) async throws -> FinancePlanSetDTO {
        try await client.post(
            "/finance/plans/generate",
            body: FinancePlanGenerateRequestDTO(goalId: goalId),
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)]
        )
    }

    func activatePlan(id: String) async throws -> FinancePlanComparisonDTO {
        return try await client.post("/finance/plans/\(id)/activate")
    }

    func fetchPaydayActions(spaceId: String, forceRefresh: Bool) async throws -> [FinancePaydayActionDTO] {
        try await client.get(
            "/finance/payday-actions",
            queryItems: [
                URLQueryItem(name: "space_id", value: spaceId),
                URLQueryItem(name: "include_resolved", value: "true"),
            ],
            bypassCache: forceRefresh
        )
    }

    func fetchOpportunities(spaceId: String, forceRefresh: Bool) async throws -> [FinanceFindingDTO] {
        try await client.get(
            "/finance/opportunities",
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)],
            bypassCache: forceRefresh
        )
    }

    func fetchReports(spaceId: String, forceRefresh: Bool) async throws -> [FinanceDailyCoachReportDTO] {
        try await client.get(
            "/finance/reports",
            queryItems: [
                URLQueryItem(name: "space_id", value: spaceId),
                URLQueryItem(name: "limit", value: "1"),
            ],
            bypassCache: forceRefresh
        )
    }

    func runAnalysis(_ request: FinanceAnalysisQueryDTO) async throws -> FinanceAnalysisResultDTO {
        try await client.post("/finance/analysis", body: request)
    }

    func createGoal(
        spaceId: String,
        request: FinanceGoalSaveRequestDTO
    ) async throws -> FinanceGoalSummaryDTO {
        try await client.post(
            "/finance/goals",
            body: request,
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)]
        )
    }

    func updateGoal(
        id: String,
        request: FinanceGoalSaveRequestDTO
    ) async throws -> FinanceGoalSummaryDTO {
        return try await client.patch("/finance/goals/\(id)", body: request)
    }
}

@MainActor
protocol FinancePortfolioAPI: Sendable {
    func fetchPortfolio(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> FinancePortfolioDTO
    func createPosition(
        spaceId: String,
        request: FinancePortfolioPositionSaveRequestDTO
    ) async throws -> FinancePortfolioDTO
    func updatePosition(
        spaceId: String,
        positionId: String,
        request: FinancePortfolioPositionSaveRequestDTO
    ) async throws -> FinancePortfolioDTO
    func removePosition(spaceId: String, positionId: String) async throws -> FinancePortfolioDTO
    func refreshPortfolio(spaceId: String) async throws -> FinanceAssetPriceRefreshDTO
    func fetchNetWorthHistory(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> FinanceNetWorthHistoryDTO
    func fetchAssetSources(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> [FinanceAssetSourceDTO]
    func createWatchAddress(
        spaceId: String,
        request: FinanceWatchAddressSaveRequestDTO
    ) async throws -> FinanceAssetSourceDTO
    func refreshWatchAddress(sourceId: String) async throws -> FinanceAssetSnapshotDTO
    func disconnectSource(sourceId: String) async throws -> FinanceAssetSourceDTO
}

struct LiveFinancePortfolioAPI: FinancePortfolioAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchPortfolio(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> FinancePortfolioDTO {
        try await client.get(
            "/finance/assets/portfolio",
            queryItems: [
                URLQueryItem(name: "space_id", value: spaceId),
                URLQueryItem(name: "currency", value: "GBP"),
                URLQueryItem(name: "days", value: "365"),
            ],
            bypassCache: forceRefresh
        )
    }

    func createPosition(
        spaceId: String,
        request: FinancePortfolioPositionSaveRequestDTO
    ) async throws -> FinancePortfolioDTO {
        try await client.post(
            "/finance/assets/portfolio/positions",
            body: request,
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)]
        )
    }

    func updatePosition(
        spaceId: String,
        positionId: String,
        request: FinancePortfolioPositionSaveRequestDTO
    ) async throws -> FinancePortfolioDTO {
        return try await client.put(
            "/finance/assets/portfolio/positions/\(positionId)",
            body: request,
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)]
        )
    }

    func removePosition(spaceId: String, positionId: String) async throws -> FinancePortfolioDTO {
        return try await client.deleteReturning(
            "/finance/assets/portfolio/positions/\(positionId)",
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)]
        )
    }

    func refreshPortfolio(spaceId: String) async throws -> FinanceAssetPriceRefreshDTO {
        try await client.post(
            "/finance/assets/portfolio/refresh",
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)]
        )
    }

    func fetchNetWorthHistory(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> FinanceNetWorthHistoryDTO {
        try await client.get(
            "/finance/assets/net-worth-history",
            queryItems: [
                URLQueryItem(name: "space_id", value: spaceId),
                URLQueryItem(name: "currency", value: "GBP"),
                URLQueryItem(name: "days", value: "365"),
            ],
            bypassCache: forceRefresh
        )
    }

    func fetchAssetSources(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> [FinanceAssetSourceDTO] {
        try await client.get(
            "/finance/assets/sources",
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)],
            bypassCache: forceRefresh
        )
    }

    func createWatchAddress(
        spaceId: String,
        request: FinanceWatchAddressSaveRequestDTO
    ) async throws -> FinanceAssetSourceDTO {
        try await client.post(
            "/finance/assets/watch-addresses",
            body: request,
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)]
        )
    }

    func refreshWatchAddress(sourceId: String) async throws -> FinanceAssetSnapshotDTO {
        return try await client.post("/finance/assets/sources/\(sourceId)/refresh")
    }

    func disconnectSource(sourceId: String) async throws -> FinanceAssetSourceDTO {
        return try await client.deleteReturning("/finance/assets/sources/\(sourceId)")
    }
}

struct FinanceTrackedSavingsPoint: Identifiable, Equatable, Sendable {
    var id: String { date }
    let date: String
    let valueMinor: Int
}

struct FinanceTrackedSavingsAllocation: Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    let valueMinor: Int
}

@MainActor
final class FinancePortfolioViewModel: ObservableObject {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "FinancePortfolioViewModel"
    )

    @Published private(set) var portfolio: FinancePortfolioDTO?
    @Published private(set) var netWorthHistory: FinanceNetWorthHistoryDTO?
    @Published private(set) var sources: [FinanceAssetSourceDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSaving = false
    @Published var notice: String?
    @Published var errorMessage: String?

    private let api: FinancePortfolioAPI
    private var currentSpaceId: String?
    private var loadGeneration = 0
    private static let trackedLayers = Set([
        "BROKERAGE_INVESTMENT",
        "STABLE_CRYPTO",
        "VOLATILE_CRYPTO",
    ])

    init(api: FinancePortfolioAPI? = nil) {
        self.api = api ?? LiveFinancePortfolioAPI()
    }

    var trackedHoldings: [FinanceNetWorthHoldingDTO] {
        (netWorthHistory?.holdings ?? []).filter {
            Self.trackedLayers.contains($0.layer)
        }
    }

    var cryptoHoldings: [FinanceNetWorthHoldingDTO] {
        trackedHoldings.filter { ["STABLE_CRYPTO", "VOLATILE_CRYPTO"].contains($0.layer) }
    }

    var trackedSavingsTotalMinor: Int {
        trackedHoldings.reduce(0) { $0 + $1.valueMinor }
    }

    var trackedHistory: [FinanceTrackedSavingsPoint] {
        (netWorthHistory?.points ?? []).map { point in
            FinanceTrackedSavingsPoint(
                date: point.asOfDate,
                valueMinor: point.layers
                    .filter { Self.trackedLayers.contains($0.layer) }
                    .reduce(0) { $0 + $1.amountMinor }
            )
        }
    }

    var allocations: [FinanceTrackedSavingsAllocation] {
        trackedHoldings.map {
            FinanceTrackedSavingsAllocation(
                key: $0.key,
                name: $0.name,
                valueMinor: $0.valueMinor
            )
        }
        .filter { $0.valueMinor > 0 }
        .sorted { $0.valueMinor > $1.valueMinor }
    }

    var watchSources: [FinanceAssetSourceDTO] {
        sources.filter { ["SOLANA_PUBLIC", "HYPERLIQUID_PUBLIC"].contains($0.sourceKind) }
    }

    func load(spaceId: String, forceRefresh: Bool = false) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if currentSpaceId != spaceId {
            portfolio = nil
            netWorthHistory = nil
            sources = []
            notice = nil
            errorMessage = nil
        }
        currentSpaceId = spaceId
        isLoading = true
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            async let portfolioRequest = api.fetchPortfolio(
                spaceId: spaceId,
                forceRefresh: forceRefresh
            )
            async let historyRequest = api.fetchNetWorthHistory(
                spaceId: spaceId,
                forceRefresh: forceRefresh
            )
            async let sourceRequest = api.fetchAssetSources(
                spaceId: spaceId,
                forceRefresh: forceRefresh
            )
            let (newPortfolio, newHistory, newSources) = try await (
                portfolioRequest,
                historyRequest,
                sourceRequest
            )
            guard loadGeneration == generation,
                  currentSpaceId == spaceId else { return }
            portfolio = newPortfolio
            netWorthHistory = newHistory
            sources = newSources
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation,
                  currentSpaceId == spaceId else { return }
            errorMessage = Self.message(
                for: error,
                fallback: "Savings portfolio could not load.".localized
            )
        }
    }

    func savePosition(
        id: String?,
        name: String,
        quoteSymbol: String,
        quoteCurrency: String,
        quantity: String,
        costBasisMinor: Int?
    ) async -> Bool {
        guard let spaceId = currentSpaceId else { return false }
        isSaving = true
        notice = nil
        errorMessage = nil
        defer { isSaving = false }
        let request = FinancePortfolioPositionSaveRequestDTO(
            id: id ?? UUID().uuidString,
            name: name,
            quoteSymbol: quoteSymbol,
            quoteCurrency: quoteCurrency,
            quantity: quantity,
            costBasisMinor: costBasisMinor
        )
        do {
            if let id {
                portfolio = try await api.updatePosition(
                    spaceId: spaceId,
                    positionId: id,
                    request: request
                )
            } else {
                portfolio = try await api.createPosition(spaceId: spaceId, request: request)
            }
            notice = id == nil ? "Position added.".localized : "Position updated.".localized
            await refreshAll(showSuccessNotice: false)
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = Self.message(
                for: error,
                fallback: "That position could not be saved.".localized
            )
            return false
        }
    }

    func removePosition(_ position: FinancePortfolioPositionDTO) async {
        guard let spaceId = currentSpaceId else { return }
        isSaving = true
        notice = nil
        errorMessage = nil
        defer { isSaving = false }
        do {
            portfolio = try await api.removePosition(
                spaceId: spaceId,
                positionId: position.id
            )
            await load(spaceId: spaceId, forceRefresh: true)
            notice = "Position removed.".localized
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.message(
                for: error,
                fallback: "That position could not be removed.".localized
            )
        }
    }

    func addWatchAddress(kind: String, label: String, address: String) async -> Bool {
        guard let spaceId = currentSpaceId else { return false }
        isSaving = true
        notice = nil
        errorMessage = nil
        defer { isSaving = false }
        do {
            let source = try await api.createWatchAddress(
                spaceId: spaceId,
                request: FinanceWatchAddressSaveRequestDTO(
                    sourceKind: kind,
                    label: label,
                    publicAddress: address
                )
            )
            do {
                _ = try await api.refreshWatchAddress(sourceId: source.id)
            } catch is CancellationError {
                // Creation already committed; the authoritative reload below
                // still reconciles the saved source when the task can continue.
            } catch {
                Self.logger.info(
                    "Initial public-address refresh failed; the normal portfolio reload will reconcile the saved source."
                )
            }
            await load(spaceId: spaceId, forceRefresh: true)
            notice = "Public asset source added.".localized
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = Self.message(
                for: error,
                fallback: "That public address could not be added.".localized
            )
            return false
        }
    }

    func disconnect(_ source: FinanceAssetSourceDTO) async {
        guard let spaceId = currentSpaceId else { return }
        isSaving = true
        notice = nil
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await api.disconnectSource(sourceId: source.id)
            await load(spaceId: spaceId, forceRefresh: true)
            notice = "Public asset source disconnected.".localized
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.message(
                for: error,
                fallback: "That source could not be disconnected.".localized
            )
        }
    }

    func refreshAll(showSuccessNotice: Bool = true) async {
        guard let spaceId = currentSpaceId else { return }
        isRefreshing = true
        errorMessage = nil
        if showSuccessNotice { notice = nil }
        defer { isRefreshing = false }
        var failures = 0
        if portfolio?.sourceId != nil {
            do {
                let result = try await api.refreshPortfolio(spaceId: spaceId)
                if result.retainedHoldingCount > 0 {
                    failures += 1
                }
            } catch is CancellationError {
                return
            } catch {
                failures += 1
            }
        }
        for source in watchSources {
            do {
                let snapshot = try await api.refreshWatchAddress(sourceId: source.id)
                if snapshot.dataStatus == "PARTIAL" {
                    failures += 1
                }
            } catch is CancellationError {
                return
            } catch {
                failures += 1
            }
        }
        await load(spaceId: spaceId, forceRefresh: true)
        if failures == 0 {
            if showSuccessNotice { notice = "Savings values refreshed.".localized }
        } else {
            errorMessage = "Some prices could not be refreshed; saved values are still shown.".localized
        }
    }

    private static func message(for error: Error, fallback: String) -> String {
        if case let APIError.serverError(_, message?) = error, !message.isEmpty {
            return message
        }
        if case APIError.networkError(_) = error {
            return "Reconnect to update the savings portfolio.".localized
        }
        return fallback
    }
}

struct FinanceMonthlyCategory: Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let amountMinor: Int
}

struct FinanceMonthlySnapshot: Equatable, Sendable {
    let startDate: String
    let endDate: String
    let currency: String
    let incomeMinor: Int
    let spendingMinor: Int
    let categories: [FinanceMonthlyCategory]
}

struct FinanceSafeSpendSnapshot: Equatable, Sendable {
    let amountMinor: Int?
    let lowMinor: Int?
    let highMinor: Int?
    let currency: String
    let dataThrough: String?
}

struct FinanceNextBillSnapshot: Equatable, Sendable {
    let name: String
    let dueDate: String
    let amountMinor: Int
    let currency: String
}

struct FinanceCurrencyMonthlyTotals: Identifiable, Equatable, Sendable {
    var id: String { currency }
    let currency: String
    let chosenMonthlyMinor: Int
    let requiredMonthlyMinor: Int
    let goalCount: Int
    let chosenGoalCount: Int
}

struct FinanceGoalSaveRequestDTO: Encodable, Equatable, Sendable {
    let name: String
    let targetMinor: Int
    let deadline: String
    let currentlyAllocatedMinor: Int
    let currency: String
}

@MainActor
final class FinanceSimpleViewModel: ObservableObject {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "FinanceSimpleViewModel"
    )

    @Published private(set) var scope: FinanceActivityScope
    @Published private(set) var overview: FinanceOverviewDTO?
    @Published private(set) var activeSpace: FinanceSpaceDTO?
    @Published private(set) var goals: [FinanceGoalSummaryDTO] = []
    @Published private(set) var plansByGoal: [String: [FinancePlanComparisonDTO]] = [:]
    @Published private(set) var selectedGoalId: String?
    @Published private(set) var selectedPlanIds: [String: String] = [:]
    @Published private(set) var paydayActions: [FinancePaydayActionDTO] = []
    @Published private(set) var monthlySnapshots: [String: FinanceMonthlySnapshot] = [:]
    @Published private(set) var safeToSpend: FinanceSafeSpendSnapshot?
    @Published private(set) var nextBill: FinanceNextBillSnapshot?
    @Published private(set) var easyWin: FinanceFindingDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOverview = false
    @Published private(set) var selectingPlanId: String?
    @Published private(set) var isSavingGoal = false
    @Published var notice: String?
    @Published var errorMessage: String?

    /// Optional action that brought the user here. It is never presented as a
    /// separate Finance destination; the selected savings goal remains primary.
    let entryAction: TodayFinanceActionDTO?

    private let api: FinanceSimpleAPI
    private let now: () -> Date
    private var goalIdByPlanId: [String: String] = [:]
    private var householdTimezone = TimeZone.current.identifier
    private var overviewLoadGeneration = 0

    init(
        entryAction: TodayFinanceActionDTO? = nil,
        initialScope: FinanceActivityScope = .mine,
        api: FinanceSimpleAPI? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.entryAction = entryAction
        scope = initialScope
        self.api = api ?? LiveFinanceSimpleAPI()
        self.now = now
    }

    var isInitialLoading: Bool {
        isLoading && goals.isEmpty
    }

    var isOverviewInitialLoading: Bool {
        isLoadingOverview && overview == nil
    }

    var selectedGoal: FinanceGoalSummaryDTO? {
        goals.first { $0.id == selectedGoalId } ?? goals.first
    }

    var selectedGoalPlans: [FinancePlanComparisonDTO] {
        guard let goal = selectedGoal else { return [] }
        return plans(for: goal)
    }

    var selectedGoalPlan: FinancePlanComparisonDTO? {
        guard let goal = selectedGoal else { return nil }
        return chosenPlan(for: goal)
    }

    var selectedGoalDisplayPlan: FinancePlanComparisonDTO? {
        guard let goal = selectedGoal else { return nil }
        return displayPlan(for: goal)
    }

    var combinedMonthlyTotals: [FinanceCurrencyMonthlyTotals] {
        let grouped = Dictionary(grouping: goals, by: \.currency)
        return grouped.keys.sorted().compactMap { currency in
            guard let currencyGoals = grouped[currency] else { return nil }
            return FinanceCurrencyMonthlyTotals(
                currency: currency,
                chosenMonthlyMinor: currencyGoals.reduce(0) {
                    $0 + (chosenPlan(for: $1)?.plannedMonthlySavingMinor ?? 0)
                },
                requiredMonthlyMinor: currencyGoals.reduce(0) {
                    $0 + requiredMonthlyMinor(for: $1)
                },
                goalCount: currencyGoals.count,
                chosenGoalCount: currencyGoals.filter {
                    chosenPlan(for: $0) != nil
                }.count
            )
        }
    }

    var goalsWithoutChosenTier: Int {
        goals.filter { chosenPlan(for: $0) == nil }.count
    }

    func plans(for goal: FinanceGoalSummaryDTO) -> [FinancePlanComparisonDTO] {
        Self.orderedPlans(
            Self.latestPlans(for: goal.id, from: plansByGoal[goal.id] ?? [])
        )
    }

    func chosenPlan(for goal: FinanceGoalSummaryDTO) -> FinancePlanComparisonDTO? {
        guard let planId = selectedPlanIds[goal.id] else { return nil }
        return plansByGoal[goal.id]?.first { $0.id == planId }
    }

    func displayPlan(for goal: FinanceGoalSummaryDTO) -> FinancePlanComparisonDTO? {
        chosenPlan(for: goal)
            ?? plans(for: goal).first(where: { $0.effortLevel == "MEDIUM" })
            ?? plans(for: goal).first
    }

    func requiredMonthlyMinor(for goal: FinanceGoalSummaryDTO) -> Int {
        if let exact = plans(for: goal).first?.requiredMonthlyMinor, exact > 0 {
            return exact
        }
        guard goal.remainingMinor > 0 else { return 0 }
        let months = Self.monthCount(from: now(), through: goal.deadline)
        return (goal.remainingMinor + months - 1) / months
    }

    func isSelected(_ plan: FinancePlanComparisonDTO) -> Bool {
        selectedPlanIds[plan.goalId] == plan.id
    }

    func monthlySnapshot(for goal: FinanceGoalSummaryDTO) -> FinanceMonthlySnapshot? {
        monthlySnapshots[goal.currency]
    }

    func confirmedThisMonthMinor(for goal: FinanceGoalSummaryDTO) -> Int {
        let month = Self.period(containing: now(), timezoneId: householdTimezone).monthKey
        return paydayActions.reduce(into: 0) { total, action in
            guard goalIdByPlanId[action.planId] == goal.id,
                  action.dueDate.hasPrefix(month),
                  ["MATCHED", "DONE", "CHANGED"].contains(action.status) else {
                return
            }
            total += action.changedAmountMinor ?? action.amountMinor
        }
    }

    func pendingPaydayAction(for goal: FinanceGoalSummaryDTO) -> FinancePaydayActionDTO? {
        paydayActions.first {
            goalIdByPlanId[$0.planId] == goal.id && $0.status == "PENDING"
        }
    }

    func confidencePercent(for goal: FinanceGoalSummaryDTO) -> Int? {
        displayPlan(for: goal).map { Int((Double($0.confidenceBps) / 100).rounded()) }
    }

    func dataThroughDate(for goal: FinanceGoalSummaryDTO) -> String? {
        displayPlan(for: goal)?.forecastCoverageEnd ?? easyWin?.dataThroughDate
    }

    func chooseGoal(_ id: String) {
        guard goals.contains(where: { $0.id == id }) else { return }
        selectedGoalId = id
        notice = nil
    }

    func selectScope(_ newScope: FinanceActivityScope) async {
        guard scope != newScope else { return }
        scope = newScope
        overview = nil
        activeSpace = nil
        goals = []
        plansByGoal = [:]
        selectedGoalId = nil
        selectedPlanIds = [:]
        paydayActions = []
        monthlySnapshots = [:]
        safeToSpend = nil
        nextBill = nil
        easyWin = nil
        await load(forceRefresh: true)
    }

    func selectOverviewScope(_ newScope: FinanceActivityScope) async {
        guard scope != newScope else { return }
        scope = newScope
        overview = nil
        activeSpace = nil
        goals = []
        plansByGoal = [:]
        selectedGoalId = nil
        selectedPlanIds = [:]
        paydayActions = []
        monthlySnapshots = [:]
        safeToSpend = nil
        nextBill = nil
        easyWin = nil
        await loadOverview(forceRefresh: true)
    }

    func loadOverview(forceRefresh: Bool = false) async {
        overviewLoadGeneration += 1
        let generation = overviewLoadGeneration
        let requestedScope = scope
        isLoadingOverview = true
        errorMessage = nil
        defer {
            if overviewLoadGeneration == generation {
                isLoadingOverview = false
            }
        }

        do {
            let loaded = try await api.fetchOverview(
                scope: requestedScope,
                forceRefresh: forceRefresh
            )
            guard overviewLoadGeneration == generation,
                  scope == requestedScope else { return }
            guard loaded.scope == requestedScope.rawValue else {
                if overview == nil {
                    errorMessage = "Finance overview could not load. Try again.".localized
                }
                return
            }
            overview = loaded
        } catch is CancellationError {
            return
        } catch {
            guard overviewLoadGeneration == generation,
                  scope == requestedScope else { return }
            if overview == nil {
                errorMessage = "Finance overview could not load. Try again.".localized
            }
        }
    }

    @discardableResult
    func saveGoal(
        name: String,
        targetMinor: Int,
        deadline: String,
        currentlyAllocatedMinor: Int,
        currency: String,
        editing goal: FinanceGoalSummaryDTO?
    ) async -> Bool {
        guard let spaceId = activeSpace?.id, !isSavingGoal else { return false }
        isSavingGoal = true
        errorMessage = nil
        notice = nil
        defer { isSavingGoal = false }
        let request = FinanceGoalSaveRequestDTO(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            targetMinor: targetMinor,
            deadline: deadline,
            currentlyAllocatedMinor: currentlyAllocatedMinor,
            currency: currency.uppercased()
        )
        do {
            let saved: FinanceGoalSummaryDTO
            if let goal {
                guard goal.spaceId == spaceId else { return false }
                saved = try await api.updateGoal(id: goal.id, request: request)
            } else {
                saved = try await api.createGoal(spaceId: spaceId, request: request)
            }
            guard saved.spaceId == spaceId else {
                errorMessage = "That goal was not returned in this Finance space.".localized
                HapticManager.error()
                return false
            }
            await load(forceRefresh: true)
            selectedGoalId = saved.id
            notice = (goal == nil ? "Goal added." : "Goal updated.").localized
            HapticManager.success()
            return true
        } catch {
            errorMessage = (error as? APIError)?.errorDescription
                ?? "That goal could not be saved. Try again.".localized
            HapticManager.error()
            return false
        }
    }

    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        notice = nil
        defer { isLoading = false }

        do {
            let spaces = try await api.fetchSpaces(forceRefresh: forceRefresh)
            let selectedSpace: FinanceSpaceDTO?
            if scope == .household {
                selectedSpace = spaces.first(where: {
                    $0.kind.localizedCaseInsensitiveCompare("household") == .orderedSame
                })
            } else {
                selectedSpace = spaces.first(where: {
                    $0.isDefault
                        && $0.kind.localizedCaseInsensitiveCompare("personal") == .orderedSame
                }) ?? spaces.first(where: {
                    $0.kind.localizedCaseInsensitiveCompare("personal") == .orderedSame
                }) ?? spaces.first(where: {
                    $0.kind.localizedCaseInsensitiveCompare("household") == .orderedSame
                })
            }
            guard let selectedSpace else {
                activeSpace = nil
                goals = []
                plansByGoal = [:]
                return
            }
            activeSpace = selectedSpace

            async let fetchedGoals = api.fetchGoals(
                spaceId: selectedSpace.id,
                forceRefresh: forceRefresh
            )
            async let fetchedPlans: [FinancePlanComparisonDTO]? = optionalProjection(
                "plans"
            ) {
                try await api.fetchPlans(
                    spaceId: selectedSpace.id,
                    forceRefresh: forceRefresh
                )
            }
            async let fetchedPaydays: [FinancePaydayActionDTO]? = optionalProjection(
                "payday actions"
            ) {
                try await api.fetchPaydayActions(
                    spaceId: selectedSpace.id,
                    forceRefresh: forceRefresh
                )
            }
            async let fetchedOpportunities: [FinanceFindingDTO]? = optionalProjection(
                "opportunities"
            ) {
                try await api.fetchOpportunities(
                    spaceId: selectedSpace.id,
                    forceRefresh: forceRefresh
                )
            }
            async let fetchedReports: [FinanceDailyCoachReportDTO]? = optionalProjection(
                "coach report"
            ) {
                try await api.fetchReports(
                    spaceId: selectedSpace.id,
                    forceRefresh: forceRefresh
                )
            }

            let (allGoals, listedPlans, paydays, opportunities, reports) = try await (
                fetchedGoals,
                fetchedPlans,
                fetchedPaydays,
                fetchedOpportunities,
                fetchedReports
            )

            let activeGoals = Self.orderedActiveGoals(allGoals)
            goals = activeGoals
            paydayActions = (paydays ?? []).sorted { $0.dueDate < $1.dueDate }
            easyWin = Self.preferredEasyWin(from: opportunities ?? [])

            let latestReport = reports?.first
            if let report = latestReport {
                householdTimezone = report.householdTimezone
                safeToSpend = Self.safeSpend(from: report)
                nextBill = Self.nextBill(from: report)
            } else {
                safeToSpend = nil
                nextBill = nil
            }

            var allPlans = listedPlans ?? []
            var grouped: [String: [FinancePlanComparisonDTO]] = [:]
            for goal in activeGoals {
                var current = Self.latestPlans(for: goal.id, from: allPlans)
                if Self.needsFreshThreePlanSet(current, remainingMinor: goal.remainingMinor) {
                    if let generated = await optionalProjection("plan generation", {
                        try await api.generatePlans(
                            spaceId: selectedSpace.id,
                            goalId: goal.id
                        )
                    }) {
                        current = generated.plans
                        allPlans.append(contentsOf: generated.plans)
                    }
                }
                grouped[goal.id] = Self.presentedPlans(
                    for: goal.id,
                    from: allPlans
                )
            }
            plansByGoal = grouped
            goalIdByPlanId = Dictionary(
                uniqueKeysWithValues: allPlans.map { ($0.id, $0.goalId) }
            )
            selectedPlanIds = Self.activePlanIds(in: grouped)

            if let currentId = selectedGoalId,
               activeGoals.contains(where: { $0.id == currentId }) {
                selectedGoalId = currentId
            } else {
                selectedGoalId = activeGoals.first(where: {
                    selectedPlanIds[$0.id] != nil
                })?.id ?? activeGoals.first?.id
            }

            var overviewCurrencies = Set(activeGoals.map(\.currency))
            if let reportCurrency = latestReport?.currency {
                overviewCurrencies.insert(reportCurrency)
            }
            monthlySnapshots = await loadMonthlySnapshots(currencies: overviewCurrencies)
        } catch {
            if goals.isEmpty {
                errorMessage = "Savings plans could not load. Try again.".localized
            }
        }
    }

    func select(_ plan: FinancePlanComparisonDTO) async {
        guard selectingPlanId == nil, !isSelected(plan) else { return }
        selectingPlanId = plan.id
        notice = nil
        errorMessage = nil
        defer { selectingPlanId = nil }

        do {
            let activated = try await api.activatePlan(id: plan.id)
            if let spaceId = activeSpace?.id,
               let refreshed = await optionalProjection("post-selection plans", {
                   try await api.fetchPlans(
                       spaceId: spaceId,
                       forceRefresh: true
                   )
               }) {
                applyPlanList(refreshed)
            } else {
                plansByGoal[activated.goalId] = plansByGoal[activated.goalId]?.map { current in
                    if current.id == activated.id { return activated }
                    return current
                }
                selectedPlanIds[activated.goalId] = activated.id
            }
            let goalName = goals.first { $0.id == activated.goalId }?.name ?? "Goal"
            notice = String(format: "%@ plan updated.".localized, goalName)
            HapticManager.success()
        } catch APIError.serverError(let statusCode, let message)
            where statusCode == 409
                && message?.contains("changed the available monthly budget") == true {
            guard let spaceId = activeSpace?.id,
                  let goal = goals.first(where: { $0.id == plan.goalId }) else {
                errorMessage = "That tier could not be selected. Try again.".localized
                HapticManager.error()
                return
            }
            do {
                let refreshed = try await api.generatePlans(
                    spaceId: spaceId,
                    goalId: goal.id
                )
                let existing = plansByGoal[goal.id] ?? []
                plansByGoal[goal.id] = Self.presentedPlans(
                    for: goal.id,
                    from: existing + refreshed.plans
                )
                for updatedPlan in refreshed.plans {
                    goalIdByPlanId[updatedPlan.id] = updatedPlan.goalId
                }
                selectedPlanIds = Self.activePlanIds(in: plansByGoal)
                notice = String(format: "%@ choices updated.".localized, goal.name)
            } catch {
                errorMessage = "The updated amounts could not load. Try again.".localized
                HapticManager.error()
            }
        } catch {
            errorMessage = "That tier could not be selected. Try again.".localized
            HapticManager.error()
        }
    }

    static func title(for effortLevel: String) -> String {
        switch effortLevel {
        case "EASY": "Easy".localized
        case "HARD": "Hard".localized
        default: "Medium".localized
        }
    }

    static func completionDate(for plan: FinancePlanComparisonDTO) -> String {
        plan.supportedGoalDate ?? plan.targetDate
    }

    static func monthCount(from start: Date, through target: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = target.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let deadline = calendar.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
              ) else {
            return 1
        }
        let startParts = calendar.dateComponents([.year, .month, .day], from: start)
        let targetParts = calendar.dateComponents([.year, .month, .day], from: deadline)
        guard let startYear = startParts.year, let startValue = startParts.month,
              let startDay = startParts.day,
              let targetYear = targetParts.year, let targetValue = targetParts.month,
              let targetDay = targetParts.day else {
            return 1
        }
        var contributionMonths = (targetYear - startYear) * 12 + targetValue - startValue + 1
        if targetDay < startDay {
            contributionMonths -= 1
        }
        return max(1, contributionMonths)
    }

    static func orderedActiveGoals(
        _ goals: [FinanceGoalSummaryDTO]
    ) -> [FinanceGoalSummaryDTO] {
        goals
            .filter { $0.status == "ACTIVE" }
            .sorted {
                if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    static func latestPlans(
        for goalId: String,
        from plans: [FinancePlanComparisonDTO]
    ) -> [FinancePlanComparisonDTO] {
        let matching = plans.filter { $0.goalId == goalId }
        guard let version = matching.map(\.version).max() else { return [] }
        return matching.filter { $0.version == version }
    }

    static func orderedPlans(
        _ plans: [FinancePlanComparisonDTO]
    ) -> [FinancePlanComparisonDTO] {
        var byEffort: [String: FinancePlanComparisonDTO] = [:]
        for plan in plans {
            let current = byEffort[plan.effortLevel]
            if current == nil || plan.strategy == "TARGET_DATE" {
                byEffort[plan.effortLevel] = plan
            }
        }
        return ["EASY", "MEDIUM", "HARD"].compactMap { byEffort[$0] }
    }

    static func presentedPlans(
        for goalId: String,
        from plans: [FinancePlanComparisonDTO]
    ) -> [FinancePlanComparisonDTO] {
        let latest = orderedPlans(latestPlans(for: goalId, from: plans))
        guard let active = plans
            .filter({ $0.goalId == goalId && $0.status == "ACTIVE" })
            .max(by: { $0.version < $1.version }),
              !latest.contains(where: { $0.id == active.id }) else {
            return latest
        }
        return latest + [active]
    }

    static func needsFreshThreePlanSet(
        _ plans: [FinancePlanComparisonDTO],
        remainingMinor: Int
    ) -> Bool {
        let efforts = Set(plans.map(\.effortLevel))
        guard efforts == Set(["EASY", "MEDIUM", "HARD"]) else { return true }
        return remainingMinor > 0 && plans.contains { $0.requiredMonthlyMinor == 0 }
    }

    static func preferredEasyWin(from findings: [FinanceFindingDTO]) -> FinanceFindingDTO? {
        findings
            .filter { ["OPEN", "ACCEPTED"].contains($0.status) && $0.savingHighMinor > 0 }
            .sorted {
                if $0.effort != $1.effort { return $0.effort < $1.effort }
                if $0.savingHighMinor != $1.savingHighMinor {
                    return $0.savingHighMinor > $1.savingHighMinor
                }
                return $0.confidenceBps > $1.confidenceBps
            }
            .first
    }

    private func applyPlanList(_ plans: [FinancePlanComparisonDTO]) {
        var grouped = plansByGoal
        for goal in goals {
            let presented = Self.presentedPlans(for: goal.id, from: plans)
            if !presented.isEmpty {
                grouped[goal.id] = presented
            }
        }
        plansByGoal = grouped
        goalIdByPlanId = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0.goalId) })
        selectedPlanIds = Self.activePlanIds(in: grouped)
    }

    private static func activePlanIds(
        in grouped: [String: [FinancePlanComparisonDTO]]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (goalId, plans) in grouped {
            if let active = plans.first(where: { $0.status == "ACTIVE" }) {
                result[goalId] = active.id
            }
        }
        return result
    }

    private func loadMonthlySnapshots(
        currencies: Set<String>
    ) async -> [String: FinanceMonthlySnapshot] {
        guard let spaceId = activeSpace?.id else { return [:] }
        let dates = Self.period(containing: now(), timezoneId: householdTimezone)
        var result: [String: FinanceMonthlySnapshot] = [:]

        for currency in currencies {
            let filters = FinanceAnalysisFiltersDTO()
            let incomeRequest = FinanceAnalysisQueryDTO(
                spaceId: spaceId,
                basis: "TRANSACTIONS",
                startDate: dates.startDate,
                endDate: dates.endDate,
                currency: currency,
                grouping: "TOTAL",
                measure: "INCOME",
                comparison: "NONE",
                pendingPolicy: "EXCLUDE",
                refundPolicy: "NET",
                transferPolicy: "EXCLUDE",
                filters: filters,
                saveAs: nil
            )
            let spendingRequest = FinanceAnalysisQueryDTO(
                spaceId: spaceId,
                basis: "TRANSACTIONS",
                startDate: dates.startDate,
                endDate: dates.endDate,
                currency: currency,
                grouping: "CATEGORY",
                measure: "SPEND",
                comparison: "NONE",
                pendingPolicy: "EXCLUDE",
                refundPolicy: "NET",
                transferPolicy: "EXCLUDE",
                filters: filters,
                saveAs: nil
            )
            async let loadedIncome = optionalProjection("monthly income", {
                try await api.runAnalysis(incomeRequest)
            })
            async let loadedSpending = optionalProjection("monthly spending", {
                try await api.runAnalysis(spendingRequest)
            })
            guard let income = await loadedIncome,
                  let spending = await loadedSpending else {
                continue
            }
            result[currency] = FinanceMonthlySnapshot(
                startDate: dates.startDate,
                endDate: dates.endDate,
                currency: currency,
                incomeMinor: Self.minorValue(income.total),
                spendingMinor: Self.minorValue(spending.total),
                categories: spending.groups
                    .map {
                        FinanceMonthlyCategory(
                            key: $0.key,
                            amountMinor: Self.minorValue($0.value)
                        )
                    }
                    .sorted { $0.amountMinor > $1.amountMinor }
            )
        }
        return result
    }

    /// Additive Finance sections should not blank the primary goals view when a
    /// secondary endpoint is unavailable. Failures are observable and the next
    /// normal load retries them without changing partial-data behavior.
    private func optionalProjection<T>(
        _ operation: String,
        _ load: () async throws -> T
    ) async -> T? {
        do {
            return try await load()
        } catch is CancellationError {
            return nil
        } catch {
            Self.logger.info(
                "Optional Finance \(operation, privacy: .public) request failed; retaining available sections."
            )
            return nil
        }
    }

    private static func minorValue(_ value: FinanceExactValueDTO) -> Int {
        guard value.denominator != 0 else { return 0 }
        return value.numerator / value.denominator
    }

    private static func period(
        containing date: Date,
        timezoneId: String
    ) -> (startDate: String, endDate: String, monthKey: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneId) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let monthKey = String(format: "%04d-%02d", year, month)
        return (
            startDate: "\(monthKey)-01",
            endDate: String(format: "%@-%02d", monthKey, day),
            monthKey: monthKey
        )
    }

    private static func safeSpend(
        from report: FinanceDailyCoachReportDTO
    ) -> FinanceSafeSpendSnapshot? {
        guard let values = object(report.summary["safe_to_spend"]),
              let currency = values["currency"]?.stringValue else {
            return nil
        }
        return FinanceSafeSpendSnapshot(
            amountMinor: values["amount_minor"]?.intValue,
            lowMinor: values["low_minor"]?.intValue,
            highMinor: values["high_minor"]?.intValue,
            currency: currency,
            dataThrough: values["data_through"]?.stringValue
        )
    }

    private static func nextBill(
        from report: FinanceDailyCoachReportDTO
    ) -> FinanceNextBillSnapshot? {
        guard let values = object(report.summary["next_protected_commitment"]),
              let name = values["name"]?.stringValue,
              let dueDate = values["due_date"]?.stringValue,
              let amountMinor = values["amount_minor"]?.intValue,
              let currency = values["currency"]?.stringValue else {
            return nil
        }
        return FinanceNextBillSnapshot(
            name: name,
            dueDate: dueDate,
            amountMinor: amountMinor,
            currency: currency
        )
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value, case .object(let object) = value else { return nil }
        return object
    }
}
