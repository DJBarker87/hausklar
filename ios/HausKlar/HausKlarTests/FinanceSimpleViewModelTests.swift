import XCTest
@testable import HausKlar

@MainActor
final class FinanceSimpleViewModelTests: XCTestCase {
    func testOverviewLoadsBackendTotalsWithoutPlanningFallbacks() async {
        let api = FinanceSimpleAPIMock()
        api.overview = overview(scope: "mine")
        let viewModel = FinanceSimpleViewModel(api: api)

        await viewModel.loadOverview()

        XCTAssertEqual(api.overviewScopes, [.mine])
        XCTAssertEqual(viewModel.overview?.spendingMinor, 183_450)
        XCTAssertEqual(viewModel.overview?.spendingByCategory.first?.name, "Quinn")
        XCTAssertEqual(viewModel.overview?.budgetBuckets.first?.remainingMinor, 21_550)
        XCTAssertEqual(viewModel.overview?.leftUntilPaydayMinor, 62_300)
        XCTAssertEqual(viewModel.overview?.savingsBalanceMinor, 1_245_000)
        XCTAssertTrue(api.goalSpaceIds.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testOverviewScopeSwitchRequestsHouseholdAggregation() async {
        let api = FinanceSimpleAPIMock()
        api.overview = overview(scope: "mine")
        let viewModel = FinanceSimpleViewModel(api: api)
        await viewModel.loadOverview()
        api.overview = overview(scope: "household")

        await viewModel.selectOverviewScope(.household)

        XCTAssertEqual(api.overviewScopes, [.mine, .household])
        XCTAssertEqual(api.overviewForceRefresh, [false, true])
        XCTAssertEqual(viewModel.scope, .household)
        XCTAssertEqual(viewModel.overview?.scope, "household")
    }

    func testOverviewRejectsMismatchedScopeAndPlanningScopeChangeClearsIt() async {
        let api = FinanceSimpleAPIMock()
        api.overview = overview(scope: "household")
        let viewModel = FinanceSimpleViewModel(api: api)

        await viewModel.loadOverview()

        XCTAssertNil(viewModel.overview)
        XCTAssertEqual(viewModel.errorMessage, "Finance overview could not load. Try again.")

        api.overview = overview(scope: "mine")
        await viewModel.loadOverview()
        XCTAssertEqual(viewModel.overview?.scope, "mine")

        await viewModel.selectScope(.household)
        XCTAssertNil(viewModel.overview)
    }

    func testScopeChangeStartsNewOverviewWhileOldRequestIsInFlight() async {
        let api = FinanceSimpleAPIMock()
        api.overviewsByScope = [
            "mine": overview(scope: "mine"),
            "household": overview(scope: "household"),
        ]
        api.overviewDelayNanoseconds = [
            "mine": 150_000_000,
            "household": 5_000_000,
        ]
        let viewModel = FinanceSimpleViewModel(api: api)

        let oldLoad = Task { await viewModel.loadOverview() }
        while api.overviewScopes.isEmpty {
            await Task.yield()
        }

        await viewModel.selectOverviewScope(.household)

        XCTAssertEqual(api.overviewScopes, [.mine, .household])
        XCTAssertEqual(viewModel.overview?.scope, "household")
        XCTAssertFalse(viewModel.isLoadingOverview)

        await oldLoad.value

        XCTAssertEqual(viewModel.overview?.scope, "household")
        XCTAssertFalse(viewModel.isLoadingOverview)
    }

    func testLoadsEveryActiveGoalAndTotalsSeparateChosenAllocations() async {
        let api = FinanceSimpleAPIMock()
        api.goals = [
            goal(id: "holiday", name: "Synthetic public demo record 16", requiredTarget: 600_000, deadline: "2027-06-01"),
            goal(id: "deposit", name: "House deposit", requiredTarget: 4_000_000, deadline: "2030-08-01"),
        ]
        api.plans = tiers(goalId: "holiday", activeEffort: "MEDIUM", amounts: [50_000, 75_000, 100_000])
            + tiers(goalId: "deposit", activeEffort: "EASY", amounts: [100_000, 180_000, 230_000])

        let viewModel = FinanceSimpleViewModel(
            api: api,
            now: { Self.date("2026-08-02") }
        )
        await viewModel.load()

        XCTAssertEqual(viewModel.goals.map(\.id), ["holiday", "deposit"])
        XCTAssertEqual(viewModel.plans(for: api.goals[0]).map(\.effortLevel), ["EASY", "MEDIUM", "HARD"])
        XCTAssertEqual(viewModel.chosenPlan(for: api.goals[0])?.effortLevel, "MEDIUM")
        XCTAssertEqual(viewModel.chosenPlan(for: api.goals[1])?.effortLevel, "EASY")
        XCTAssertEqual(
            viewModel.combinedMonthlyTotals,
            [FinanceCurrencyMonthlyTotals(
                currency: "GBP",
                chosenMonthlyMinor: 175_000,
                requiredMonthlyMinor: 400_000,
                goalCount: 2,
                chosenGoalCount: 2
            )]
        )
        XCTAssertEqual(viewModel.goalsWithoutChosenTier, 0)
        XCTAssertEqual(viewModel.monthlySnapshot(for: api.goals[0])?.incomeMinor, 500_000)
        XCTAssertEqual(viewModel.monthlySnapshot(for: api.goals[0])?.spendingMinor, 320_000)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testFailedRefreshKeepsExistingSavingsPlanWithoutAStalenessWarning() async {
        let api = FinanceSimpleAPIMock()
        api.goals = [
            goal(
                id: "holiday",
                name: "Synthetic public demo record 16",
                requiredTarget: 600_000,
                deadline: "2027-06-01"
            ),
        ]
        api.plans = tiers(
            goalId: "holiday",
            activeEffort: "MEDIUM",
            amounts: [50_000, 75_000, 100_000]
        )
        let viewModel = FinanceSimpleViewModel(api: api)

        await viewModel.load()
        api.fetchGoalsError = URLError(.notConnectedToInternet)
        await viewModel.load(forceRefresh: true)

        XCTAssertEqual(viewModel.goals.map(\.id), ["holiday"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSelectingHardTierUpdatesOnlyThatGoalsChosenPace() async {
        let api = FinanceSimpleAPIMock()
        api.goals = [
            goal(id: "car", name: "Family car", requiredTarget: 1_200_000, deadline: "2028-01-31"),
            goal(id: "buffer", name: "Emergency fund", requiredTarget: 900_000, deadline: "2027-12-31"),
        ]
        api.plans = tiers(goalId: "car", activeEffort: "MEDIUM", amounts: [40_000, 70_000, 100_000])
            + tiers(goalId: "buffer", activeEffort: "EASY", amounts: [30_000, 50_000, 75_000])

        let viewModel = FinanceSimpleViewModel(api: api)
        await viewModel.load()
        let car = try! XCTUnwrap(viewModel.goals.first { $0.id == "car" })
        let hard = try! XCTUnwrap(viewModel.plans(for: car).first { $0.effortLevel == "HARD" })

        await viewModel.select(hard)

        XCTAssertEqual(viewModel.chosenPlan(for: car)?.effortLevel, "HARD")
        XCTAssertEqual(viewModel.selectedPlanIds["buffer"], "buffer-easy")
        XCTAssertEqual(viewModel.combinedMonthlyTotals.first?.chosenMonthlyMinor, 130_000)
        XCTAssertEqual(viewModel.notice, "Family car plan updated.")
    }

    func testCombinedCommitmentsStaySeparateAcrossCurrencies() async {
        let api = FinanceSimpleAPIMock()
        api.goals = [
            goal(
                id: "sterling",
                name: "House deposit",
                requiredTarget: 4_000_000,
                deadline: "2030-08-01",
                currency: "GBP"
            ),
            goal(
                id: "euros",
                name: "Synthetic public demo record 18",
                requiredTarget: 600_000,
                deadline: "2028-06-01",
                currency: "EUR"
            ),
        ]
        api.plans = tiers(
            goalId: "sterling",
            activeEffort: "MEDIUM",
            amounts: [100_000, 180_000, 230_000],
            currency: "GBP"
        ) + tiers(
            goalId: "euros",
            activeEffort: "EASY",
            amounts: [40_000, 60_000, 80_000],
            currency: "EUR"
        )

        let viewModel = FinanceSimpleViewModel(api: api)
        await viewModel.load()

        let totals = Dictionary(
            uniqueKeysWithValues: viewModel.combinedMonthlyTotals.map { ($0.currency, $0) }
        )
        XCTAssertEqual(totals["GBP"]?.chosenMonthlyMinor, 180_000)
        XCTAssertEqual(totals["EUR"]?.chosenMonthlyMinor, 40_000)
        XCTAssertEqual(totals["GBP"]?.requiredMonthlyMinor, 200_000)
        XCTAssertEqual(totals["EUR"]?.requiredMonthlyMinor, 200_000)
    }

    func testActivationConflictRegeneratesThatGoalsAmounts() async {
        let api = FinanceSimpleAPIMock()
        api.goals = [
            goal(
                id: "car",
                name: "Family car",
                requiredTarget: 1_200_000,
                deadline: "2028-01-31"
            )
        ]
        api.plans = tiers(
            goalId: "car",
            activeEffort: "MEDIUM",
            amounts: [40_000, 70_000, 100_000]
        )
        api.activationError = APIError.serverError(
            statusCode: 409,
            message: "Another savings goal changed the available monthly budget; generate these choices again"
        )
        api.regeneratedPlansByGoal["car"] = [
            plan(id: "car-refresh-easy", goalId: "car", effort: "EASY", amount: 20_000, status: "PROPOSED", version: 2),
            plan(id: "car-refresh-medium", goalId: "car", effort: "MEDIUM", amount: 35_000, status: "PROPOSED", version: 2),
            plan(id: "car-refresh-hard", goalId: "car", effort: "HARD", amount: 50_000, status: "PROPOSED", version: 2),
        ]

        let viewModel = FinanceSimpleViewModel(api: api)
        await viewModel.load()
        let goal = try! XCTUnwrap(viewModel.goals.first)
        let oldHard = try! XCTUnwrap(
            viewModel.plans(for: goal).first { $0.effortLevel == "HARD" }
        )

        await viewModel.select(oldHard)

        XCTAssertEqual(api.generatedGoalIds, ["car"])
        XCTAssertEqual(
            viewModel.plans(for: goal).map(\.plannedMonthlySavingMinor),
            [20_000, 35_000, 50_000]
        )
        XCTAssertEqual(viewModel.chosenPlan(for: goal)?.id, "car-medium")
        XCTAssertEqual(viewModel.combinedMonthlyTotals.first?.chosenMonthlyMinor, 70_000)
        XCTAssertEqual(viewModel.notice, "Family car choices updated.")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testOlderActivePlanStaysSelectedBesideLatestThreeChoices() async {
        let api = FinanceSimpleAPIMock()
        api.goals = [
            goal(
                id: "deposit",
                name: "House deposit",
                requiredTarget: 4_000_000,
                deadline: "2030-08-01"
            )
        ]
        api.plans = [
            plan(
                id: "deposit-active-v1",
                goalId: "deposit",
                effort: "MEDIUM",
                amount: 180_000,
                status: "ACTIVE",
                version: 1
            ),
            plan(id: "deposit-easy-v2", goalId: "deposit", effort: "EASY", amount: 90_000, status: "PROPOSED", version: 2),
            plan(id: "deposit-medium-v2", goalId: "deposit", effort: "MEDIUM", amount: 150_000, status: "PROPOSED", version: 2),
            plan(id: "deposit-hard-v2", goalId: "deposit", effort: "HARD", amount: 210_000, status: "PROPOSED", version: 2),
        ]

        let viewModel = FinanceSimpleViewModel(api: api)
        await viewModel.load()
        let deposit = try! XCTUnwrap(viewModel.goals.first)

        XCTAssertEqual(
            viewModel.plans(for: deposit).map(\.id),
            ["deposit-easy-v2", "deposit-medium-v2", "deposit-hard-v2"]
        )
        XCTAssertEqual(viewModel.chosenPlan(for: deposit)?.id, "deposit-active-v1")
        XCTAssertEqual(viewModel.selectedPlanIds[deposit.id], "deposit-active-v1")
        XCTAssertEqual(viewModel.combinedMonthlyTotals.first?.chosenMonthlyMinor, 180_000)
    }

    func testCompletionDatePrefersSupportedGoalDate() {
        let reachingPlan = plan(
            id: "reaches-early",
            goalId: "deposit",
            effort: "HARD",
            amount: 100_000,
            status: "PROPOSED"
        )

        XCTAssertEqual(
            FinanceSimpleViewModel.completionDate(for: reachingPlan),
            reachingPlan.supportedGoalDate
        )
    }

    func testFallbackDoesNotCountAContributionAfterAnEarlyMonthDeadline() {
        XCTAssertEqual(
            FinanceSimpleViewModel.monthCount(
                from: Self.date("2026-08-02"),
                through: "2027-08-01"
            ),
            12
        )
    }

    func testMineUsesOnlyTheDefaultPersonalPlanningSpaceAndScopeCanSwitchToHousehold() async {
        let api = FinanceSimpleAPIMock()
        api.spaces = [
            FinanceSpaceDTO(id: "personal-current", kind: "PERSONAL", name: "Mine", isDefault: true),
            FinanceSpaceDTO(id: "personal-adult-b", kind: "PERSONAL", name: "Jordan", isDefault: false),
            FinanceSpaceDTO(id: "household", kind: "HOUSEHOLD", name: "Household", isDefault: false),
        ]
        let viewModel = FinanceSimpleViewModel(api: api)

        await viewModel.load()
        XCTAssertEqual(viewModel.activeSpace?.id, "personal-current")
        XCTAssertEqual(Set(api.goalSpaceIds), Set(["personal-current"]))

        api.goalSpaceIds.removeAll()
        await viewModel.selectScope(.household)
        XCTAssertEqual(viewModel.activeSpace?.id, "household")
        XCTAssertEqual(Set(api.goalSpaceIds), Set(["household"]))
    }

    func testTodayHouseholdActionOverridesAStoredPrivateScopeAndOpensItsAction() {
        let action = TodayFinanceActionDTO(
            id: "household-review",
            kind: "PURCHASE_REVIEW",
            spaceId: "household",
            spaceKind: "HOUSEHOLD",
            spaceName: "Household",
            dueDate: nil,
            reviewDate: "2026-08-03",
            title: "Review the receipt",
            amountMinor: nil,
            currency: nil,
            sourceAccountId: nil,
            sourceAccountLabel: nil,
            destinationAccountId: nil,
            destinationAccountLabel: nil,
            lineId: "line-1",
            purchaseId: "purchase-1",
            sourceId: nil
        )

        let route = FinanceSimpleInitialRoute.resolve(
            entryAction: action,
            storedScope: .mine
        )

        XCTAssertEqual(route.section, .more)
        XCTAssertEqual(route.scope, .household)
    }

    func testTodayPrivateActionOverridesAStoredHouseholdScopeAndOpensItsAction() {
        let action = TodayFinanceActionDTO(
            id: "private-payday",
            kind: "PAYDAY_TRANSFER",
            spaceId: "dom-private",
            spaceKind: "PERSONAL",
            spaceName: "Alex",
            dueDate: "2026-08-03",
            reviewDate: nil,
            title: "Protect payday money",
            amountMinor: 42_000,
            currency: "GBP",
            sourceAccountId: "current",
            sourceAccountLabel: "Current",
            destinationAccountId: "bills",
            destinationAccountLabel: "Bills",
            lineId: nil,
            purchaseId: nil,
            sourceId: nil
        )

        let route = FinanceSimpleInitialRoute.resolve(
            entryAction: action,
            storedScope: .household
        )

        XCTAssertEqual(route.section, .more)
        XCTAssertEqual(route.scope, .mine)
    }

    func testOrdinaryFinanceOpenStillRestoresTheAdultScopePreference() {
        let route = FinanceSimpleInitialRoute.resolve(
            entryAction: nil,
            storedScope: .household
        )

        XCTAssertEqual(route.section, .overview)
        XCTAssertEqual(route.scope, .household)
    }

    func testInAppLanguagePreferenceDrivesDynamicLocalizationAndLocale() {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: "appLanguage")
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: "appLanguage")
            } else {
                defaults.removeObject(forKey: "appLanguage")
            }
        }

        defaults.set("de", forKey: "appLanguage")
        XCTAssertEqual("Today".localized, "Heute")
        XCTAssertEqual(Locale.hausKlarSelected.identifier, "de")

        defaults.set("en", forKey: "appLanguage")
        XCTAssertEqual("Today".localized, "Today")
        XCTAssertEqual(Locale.hausKlarSelected.identifier, "en")
    }

    private func goal(
        id: String,
        name: String,
        requiredTarget: Int,
        deadline: String,
        currency: String = "GBP"
    ) -> FinanceGoalSummaryDTO {
        FinanceGoalSummaryDTO(
            id: id,
            spaceId: "household",
            name: name,
            targetMinor: requiredTarget,
            deadline: deadline,
            currentlyAllocatedMinor: 0,
            remainingMinor: requiredTarget,
            currency: currency,
            priority: "IMPORTANT",
            feasibility: "UNASSESSED",
            shortfallMinor: nil,
            status: "ACTIVE"
        )
    }

    private func overview(scope: String) -> FinanceOverviewDTO {
        FinanceOverviewDTO(
            scope: scope,
            monthStart: "2026-08-01",
            throughDate: "2026-08-10",
            currency: "GBP",
            accountCount: scope == "household" ? 4 : 2,
            incomeMinor: 410_000,
            spendingMinor: 183_450,
            spendingByCategory: [
                FinanceOverviewSpendingCategoryDTO(
                    categoryKey: "example-category",
                    name: "Quinn",
                    spendingType: "FLEXIBLE",
                    spentMinor: 58_450,
                    shareBps: 3_186
                ),
            ],
            budgetBuckets: [
                FinanceOverviewBudgetBucketDTO(
                    categoryKey: "example-category",
                    name: "Quinn",
                    budgetMinor: 80_000,
                    spentMinor: 58_450,
                    remainingMinor: 21_550
                ),
            ],
            currentAvailableMinor: 95_000,
            nextPaycheckDate: "2026-08-25",
            nextPaycheckMinor: 315_000,
            leftUntilPaydayMinor: 62_300,
            commitmentsBeforePaydayMinor: 32_700,
            commitmentsBeforePaydayCount: 2,
            upcomingCommitments: [
                FinanceOverviewCommitmentDTO(
                    name: "Energy",
                    dueDate: "2026-08-18",
                    amountMinor: 12_700
                ),
            ],
            savingsBalanceMinor: 1_245_000,
            savingsChangeMinor: 45_000,
            savingsSeries: [
                FinanceOverviewSavingsPointDTO(date: "2026-07-01", balanceMinor: 1_200_000),
                FinanceOverviewSavingsPointDTO(date: "2026-08-01", balanceMinor: 1_245_000),
            ]
        )
    }

    private func tiers(
        goalId: String,
        activeEffort: String,
        amounts: [Int],
        currency: String = "GBP"
    ) -> [FinancePlanComparisonDTO] {
        zip(["EASY", "MEDIUM", "HARD"], amounts).map { effort, amount in
            plan(
                id: "\(goalId)-\(effort.lowercased())",
                goalId: goalId,
                effort: effort,
                amount: amount,
                status: effort == activeEffort ? "ACTIVE" : "PROPOSED",
                currency: currency
            )
        }
    }

    private func plan(
        id: String,
        goalId: String,
        effort: String,
        amount: Int,
        status: String,
        currency: String = "GBP",
        version: Int = 1
    ) -> FinancePlanComparisonDTO {
        FinancePlanComparisonDTO(
            id: id,
            proposalGroupId: "\(goalId)-group",
            spaceId: "household",
            version: version,
            strategy: effort == "MEDIUM" ? "TARGET_DATE" : effort == "EASY" ? "MINIMAL_DISRUPTION" : "AGGRESSIVE",
            effortLevel: effort,
            answerBasis: "BOUNDED",
            confidenceBps: 8_000,
            currency: currency,
            goalId: goalId,
            targetDate: "2030-08-01",
            supportedGoalDate: "2031-01-01",
            forecastCoverageEnd: "2026-07-25",
            requiredMonthlyMinor: 200_000,
            plannedMonthlySavingMinor: amount,
            projectedAmountAtTargetMinor: amount * 48,
            goalShortfallAtTargetMinor: max(0, 4_000_000 - amount * 48),
            monthlyChangeMinor: amount,
            householdBufferMinor: 100_000,
            requiredReductionMinor: amount,
            achievedReductionMinor: amount,
            shortfallMinor: 0,
            feasible: true,
            status: status,
            rationale: "A justified plan based on the spending available.",
            assumptions: ["Regular income continues."],
            categories: [
                FinancePlanCategoryDTO(
                    categoryId: "eating-out",
                    name: "Eating out",
                    baselineMinor: 50_000,
                    floorMinor: 20_000,
                    protected: false,
                    weight: 1,
                    reductionMinor: min(amount, 20_000),
                    budgetMinor: 30_000
                )
            ]
        )
    }

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}

@MainActor
private final class FinanceSimpleAPIMock: FinanceSimpleAPI {
    var spaces = [
        FinanceSpaceDTO(id: "household", kind: "HOUSEHOLD", name: "Household", isDefault: true),
    ]
    var goals: [FinanceGoalSummaryDTO] = []
    var plans: [FinancePlanComparisonDTO] = []
    var regeneratedPlansByGoal: [String: [FinancePlanComparisonDTO]] = [:]
    var generatedGoalIds: [String] = []
    var activationError: Error?
    var fetchGoalsError: Error?
    var goalSpaceIds: [String] = []
    var overview: FinanceOverviewDTO?
    var overviewsByScope: [String: FinanceOverviewDTO] = [:]
    var overviewDelayNanoseconds: [String: UInt64] = [:]
    var overviewScopes: [FinanceActivityScope] = []
    var overviewForceRefresh: [Bool] = []

    func fetchOverview(
        scope: FinanceActivityScope,
        forceRefresh: Bool
    ) async throws -> FinanceOverviewDTO {
        overviewScopes.append(scope)
        overviewForceRefresh.append(forceRefresh)
        if let delay = overviewDelayNanoseconds[scope.rawValue] {
            try await Task.sleep(nanoseconds: delay)
        }
        if let scoped = overviewsByScope[scope.rawValue] {
            return scoped
        }
        guard let overview else {
            throw APIError.notFound
        }
        return overview
    }

    func fetchSpaces(forceRefresh: Bool) async throws -> [FinanceSpaceDTO] {
        spaces
    }

    func fetchGoals(spaceId: String, forceRefresh: Bool) async throws -> [FinanceGoalSummaryDTO] {
        goalSpaceIds.append(spaceId)
        if let fetchGoalsError { throw fetchGoalsError }
        return goals.filter { $0.spaceId == spaceId || spaces.count == 1 }
    }
    func fetchPlans(spaceId: String, forceRefresh: Bool) async throws -> [FinancePlanComparisonDTO] { plans }

    func generatePlans(spaceId: String, goalId: String) async throws -> FinancePlanSetDTO {
        generatedGoalIds.append(goalId)
        guard let regenerated = regeneratedPlansByGoal[goalId] else {
            XCTFail("Complete fixtures should not regenerate plans")
            return FinancePlanSetDTO(
                proposalGroupId: "unused",
                version: 1,
                recommendationStrategy: "TARGET_DATE",
                recommendationEffortLevel: "MEDIUM",
                plans: []
            )
        }
        plans.removeAll { $0.goalId == goalId }
        plans.append(contentsOf: regenerated)
        return FinancePlanSetDTO(
            proposalGroupId: "refreshed-\(goalId)",
            version: regenerated.first?.version ?? 1,
            recommendationStrategy: "TARGET_DATE",
            recommendationEffortLevel: "MEDIUM",
            plans: regenerated
        )
    }

    func activatePlan(id: String) async throws -> FinancePlanComparisonDTO {
        if let activationError {
            throw activationError
        }
        let activated = plans.first { $0.id == id }!
        plans = plans.map { plan in
            guard plan.goalId == activated.goalId else { return plan }
            return replacement(plan, status: plan.id == id ? "ACTIVE" : "PROPOSED")
        }
        return plans.first { $0.id == id }!
    }

    func fetchPaydayActions(spaceId: String, forceRefresh: Bool) async throws -> [FinancePaydayActionDTO] { [] }
    func fetchOpportunities(spaceId: String, forceRefresh: Bool) async throws -> [FinanceFindingDTO] { [] }
    func fetchReports(spaceId: String, forceRefresh: Bool) async throws -> [FinanceDailyCoachReportDTO] { [] }

    func createGoal(
        spaceId: String,
        request: FinanceGoalSaveRequestDTO
    ) async throws -> FinanceGoalSummaryDTO {
        let created = FinanceGoalSummaryDTO(
            id: UUID().uuidString,
            spaceId: spaceId,
            name: request.name,
            targetMinor: request.targetMinor,
            deadline: request.deadline,
            currentlyAllocatedMinor: request.currentlyAllocatedMinor,
            remainingMinor: max(0, request.targetMinor - request.currentlyAllocatedMinor),
            currency: request.currency,
            priority: "IMPORTANT",
            feasibility: "UNASSESSED",
            shortfallMinor: nil,
            status: "ACTIVE"
        )
        goals.append(created)
        return created
    }

    func updateGoal(
        id: String,
        request: FinanceGoalSaveRequestDTO
    ) async throws -> FinanceGoalSummaryDTO {
        guard let existing = goals.first(where: { $0.id == id }) else {
            throw APIError.notFound
        }
        let updated = FinanceGoalSummaryDTO(
            id: id,
            spaceId: existing.spaceId,
            name: request.name,
            targetMinor: request.targetMinor,
            deadline: request.deadline,
            currentlyAllocatedMinor: request.currentlyAllocatedMinor,
            remainingMinor: max(0, request.targetMinor - request.currentlyAllocatedMinor),
            currency: request.currency,
            priority: existing.priority,
            feasibility: existing.feasibility,
            shortfallMinor: existing.shortfallMinor,
            status: existing.status
        )
        goals = goals.map { $0.id == id ? updated : $0 }
        return updated
    }

    func runAnalysis(_ request: FinanceAnalysisQueryDTO) async throws -> FinanceAnalysisResultDTO {
        let amount = request.measure == "INCOME" ? 500_000 : 320_000
        return FinanceAnalysisResultDTO(
            basis: "TRANSACTIONS",
            currency: request.currency,
            total: FinanceExactValueDTO(numerator: amount, denominator: 1),
            groups: request.grouping == "CATEGORY"
                ? [FinanceAnalysisGroupDTO(
                    key: "example-category",
                    value: FinanceExactValueDTO(numerator: amount, denominator: 1),
                    recordCount: 4,
                    evidenceHandles: []
                )]
                : [],
            comparisonGroups: [],
            comparisonTotal: nil,
            dataThrough: request.endDate,
            evidence: [],
            savedView: nil
        )
    }

    private func replacement(
        _ plan: FinancePlanComparisonDTO,
        status: String
    ) -> FinancePlanComparisonDTO {
        FinancePlanComparisonDTO(
            id: plan.id,
            proposalGroupId: plan.proposalGroupId,
            spaceId: plan.spaceId,
            version: plan.version,
            strategy: plan.strategy,
            effortLevel: plan.effortLevel,
            answerBasis: plan.answerBasis,
            confidenceBps: plan.confidenceBps,
            currency: plan.currency,
            goalId: plan.goalId,
            targetDate: plan.targetDate,
            supportedGoalDate: plan.supportedGoalDate,
            forecastCoverageEnd: plan.forecastCoverageEnd,
            requiredMonthlyMinor: plan.requiredMonthlyMinor,
            plannedMonthlySavingMinor: plan.plannedMonthlySavingMinor,
            projectedAmountAtTargetMinor: plan.projectedAmountAtTargetMinor,
            goalShortfallAtTargetMinor: plan.goalShortfallAtTargetMinor,
            monthlyChangeMinor: plan.monthlyChangeMinor,
            householdBufferMinor: plan.householdBufferMinor,
            requiredReductionMinor: plan.requiredReductionMinor,
            achievedReductionMinor: plan.achievedReductionMinor,
            shortfallMinor: plan.shortfallMinor,
            feasible: plan.feasible,
            status: status,
            rationale: plan.rationale,
            assumptions: plan.assumptions,
            categories: plan.categories
        )
    }
}

@MainActor
final class FinancePortfolioViewModelTests: XCTestCase {
    func testLaterSpaceLoadWinsWhenAnEarlierRequestFinishesLast() async {
        let api = FinancePortfolioAPIMock()
        api.portfoliosBySpace["household"] = FinancePortfolioDTO(
            spaceId: "household",
            sourceId: nil,
            label: "Savings portfolio",
            currency: "GBP",
            totalValueMinor: 75_000,
            totalCostBasisMinor: nil,
            totalGainMinor: nil,
            missingCostBasisCount: 0,
            unknownPositionCount: 0,
            priceObservedAt: nil,
            priceSources: [],
            usingLastKnownPrices: false,
            positions: [],
            history: []
        )
        api.portfolioDelayNanoseconds = [
            "personal": 150_000_000,
            "household": 5_000_000,
        ]
        let viewModel = FinancePortfolioViewModel(api: api)

        let personalLoad = Task { await viewModel.load(spaceId: "personal") }
        while api.requestedPortfolioSpaces.isEmpty {
            await Task.yield()
        }

        await viewModel.load(spaceId: "household")
        XCTAssertEqual(viewModel.portfolio?.spaceId, "household")
        XCTAssertEqual(viewModel.portfolio?.totalValueMinor, 75_000)

        await personalLoad.value

        XCTAssertEqual(viewModel.portfolio?.spaceId, "household")
        XCTAssertEqual(viewModel.portfolio?.totalValueMinor, 75_000)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadCombinesSecuritiesSolanaAndHyperliquidWithoutCashOrPension() async {
        let api = FinancePortfolioAPIMock()
        let viewModel = FinancePortfolioViewModel(api: api)

        await viewModel.load(spaceId: "personal")

        XCTAssertEqual(viewModel.trackedSavingsTotalMinor, 60_000)
        XCTAssertEqual(viewModel.trackedHistory.map(\.valueMinor), [45_000, 60_000])
        XCTAssertEqual(
            viewModel.allocations.map(\.name),
            ["Global fund", "Solana", "USDC"]
        )
        XCTAssertEqual(viewModel.cryptoHoldings.map(\.name), ["Solana", "USDC"])
        XCTAssertEqual(viewModel.watchSources.map(\.id), ["hyperliquid-source", "solana-source"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCreatingPositionUsesAClientIdThenRefreshesEveryTrackedSource() async throws {
        let api = FinancePortfolioAPIMock()
        let viewModel = FinancePortfolioViewModel(api: api)
        await viewModel.load(spaceId: "personal")

        let saved = await viewModel.savePosition(
            id: nil,
            name: "World ETF",
            quoteSymbol: "VWRP.LON",
            quoteCurrency: "GBP",
            quantity: "12.5",
            costBasisMinor: 10_000
        )

        XCTAssertTrue(saved)
        let request = try XCTUnwrap(api.createdRequests.first)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(request.id)))
        XCTAssertEqual(request.costBasisMinor, 10_000)
        XCTAssertEqual(api.portfolioRefreshCount, 1)
        XCTAssertEqual(api.refreshedWatchSourceIds, ["hyperliquid-source", "solana-source"])
        XCTAssertEqual(viewModel.notice, "Position added.")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testManualRefreshCallsOutRetainedPricesAndKeepsSavedValuesVisible() async {
        let api = FinancePortfolioAPIMock()
        let viewModel = FinancePortfolioViewModel(api: api)
        await viewModel.load(spaceId: "personal")
        api.portfolioRefresh = FinanceAssetPriceRefreshDTO(
            sourceId: "portfolio-source",
            sourceLabel: "Savings portfolio",
            pricedHoldingCount: 0,
            retainedHoldingCount: 1,
            priceObservedAt: "2026-08-09T20:00:00+00:00",
            priceSources: ["Alpha Vantage daily close"]
        )

        await viewModel.refreshAll()

        XCTAssertEqual(viewModel.trackedSavingsTotalMinor, 60_000)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Some prices could not be refreshed; saved values are still shown."
        )
        XCTAssertNil(viewModel.notice)
        XCTAssertFalse(viewModel.isRefreshing)
    }

    func testPortfolioLoadExplainsThatAConnectionIsNeeded() async {
        let api = FinancePortfolioAPIMock()
        api.fetchPortfolioError = APIError.networkError(URLError(.notConnectedToInternet))
        let viewModel = FinancePortfolioViewModel(api: api)

        await viewModel.load(spaceId: "personal")

        XCTAssertEqual(
            viewModel.errorMessage,
            "Reconnect to update the savings portfolio."
        )
        XCTAssertNil(viewModel.portfolio)
    }
}

@MainActor
private final class FinancePortfolioAPIMock: FinancePortfolioAPI {
    var portfolio = FinancePortfolioDTO(
        spaceId: "personal",
        sourceId: "portfolio-source",
        label: "Savings portfolio",
        currency: "GBP",
        totalValueMinor: 40_000,
        totalCostBasisMinor: 32_000,
        totalGainMinor: 8_000,
        missingCostBasisCount: 0,
        unknownPositionCount: 0,
        priceObservedAt: "2026-08-09T20:00:00+00:00",
        priceSources: ["Alpha Vantage daily close"],
        usingLastKnownPrices: true,
        positions: [
            FinancePortfolioPositionDTO(
                id: "fund-position",
                name: "Global fund",
                quoteSymbol: "VWRP.LON",
                quoteCurrency: "GBP",
                quantity: "4",
                costBasisMinor: 32_000,
                unitPriceMinor: 10_000,
                valueMinor: 40_000,
                gainMinor: 8_000,
                currency: "GBP",
                priceObservedAt: "2026-08-09T20:00:00+00:00",
                priceSource: "Alpha Vantage daily close",
                usingLastKnownPrice: true
            ),
        ],
        history: [
            FinancePortfolioHistoryPointDTO(
                date: "2026-08-09",
                valueMinor: 40_000,
                knownPositionCount: 1,
                unknownPositionCount: 0
            ),
        ]
    )
    var history = FinanceNetWorthHistoryDTO(
        spaceId: "personal",
        currency: "GBP",
        points: [
            FinanceNetWorthPointDTO(
                asOfDate: "2026-08-09",
                totalMinor: 145_000,
                unknownComponentCount: 0,
                layers: [
                    FinanceNetWorthPointLayerDTO(
                        layer: "BROKERAGE_INVESTMENT",
                        amountMinor: 30_000
                    ),
                    FinanceNetWorthPointLayerDTO(layer: "STABLE_CRYPTO", amountMinor: 5_000),
                    FinanceNetWorthPointLayerDTO(layer: "VOLATILE_CRYPTO", amountMinor: 10_000),
                    FinanceNetWorthPointLayerDTO(layer: "PENSION_LOCKED", amountMinor: 100_000),
                ],
                contributionsMinor: 0,
                withdrawalsMinor: 0,
                marketMovementMinor: nil
            ),
            FinanceNetWorthPointDTO(
                asOfDate: "2026-08-10",
                totalMinor: 163_000,
                unknownComponentCount: 0,
                layers: [
                    FinanceNetWorthPointLayerDTO(
                        layer: "BROKERAGE_INVESTMENT",
                        amountMinor: 40_000
                    ),
                    FinanceNetWorthPointLayerDTO(layer: "STABLE_CRYPTO", amountMinor: 5_000),
                    FinanceNetWorthPointLayerDTO(layer: "VOLATILE_CRYPTO", amountMinor: 15_000),
                    FinanceNetWorthPointLayerDTO(layer: "PENSION_LOCKED", amountMinor: 100_000),
                    FinanceNetWorthPointLayerDTO(layer: "CASH", amountMinor: 3_000),
                ],
                contributionsMinor: 0,
                withdrawalsMinor: 0,
                marketMovementMinor: 18_000
            ),
        ],
        currentTotalMinor: 163_000,
        changeMinor: 18_000,
        periodContributionsMinor: 0,
        periodWithdrawalsMinor: 0,
        periodMarketMovementMinor: 18_000,
        holdings: [
            FinancePortfolioAPIMock.holding(
                key: "manual:fund-position",
                sourceId: "portfolio-source",
                sourceLabel: "Savings portfolio",
                name: "Global fund",
                layer: "BROKERAGE_INVESTMENT",
                valueMinor: 40_000
            ),
            FinancePortfolioAPIMock.holding(
                key: "solana:SOL",
                sourceId: "solana-source",
                sourceLabel: "Solana wallet",
                name: "Solana",
                layer: "VOLATILE_CRYPTO",
                valueMinor: 15_000
            ),
            FinancePortfolioAPIMock.holding(
                key: "solana:USDC",
                sourceId: "solana-source",
                sourceLabel: "Solana wallet",
                name: "USDC",
                layer: "STABLE_CRYPTO",
                valueMinor: 5_000
            ),
            FinancePortfolioAPIMock.holding(
                key: "pension",
                sourceId: "pension-source",
                sourceLabel: "Pension",
                name: "Pension",
                layer: "PENSION_LOCKED",
                valueMinor: 100_000
            ),
            FinancePortfolioAPIMock.holding(
                key: "cash",
                sourceId: nil,
                sourceLabel: "Bank",
                name: "Cash",
                layer: "CASH",
                valueMinor: 3_000
            ),
        ],
        priceObservedAt: "2026-08-09T20:00:00+00:00",
        priceSources: ["Alpha Vantage daily close", "Public Solana RPC"],
        usingLastKnownPrices: true
    )
    var sources = [
        FinanceAssetSourceDTO(
            id: "portfolio-source",
            spaceId: "personal",
            sourceKind: "MANUAL_PORTFOLIO",
            label: "Savings portfolio",
            publicAddress: nil,
            status: "ACTIVE"
        ),
        FinanceAssetSourceDTO(
            id: "hyperliquid-source",
            spaceId: "personal",
            sourceKind: "HYPERLIQUID_PUBLIC",
            label: "Hyperliquid",
            publicAddress: "0x1111111111111111111111111111111111111111",
            status: "ACTIVE"
        ),
        FinanceAssetSourceDTO(
            id: "solana-source",
            spaceId: "personal",
            sourceKind: "SOLANA_PUBLIC",
            label: "Solana wallet",
            publicAddress: "11111111111111111111111111111111",
            status: "ACTIVE"
        ),
    ]
    var portfolioRefresh = FinanceAssetPriceRefreshDTO(
        sourceId: "portfolio-source",
        sourceLabel: "Savings portfolio",
        pricedHoldingCount: 1,
        retainedHoldingCount: 0,
        priceObservedAt: "2026-08-09T20:00:00+00:00",
        priceSources: ["Alpha Vantage daily close"]
    )
    var fetchPortfolioError: Error?
    var portfoliosBySpace: [String: FinancePortfolioDTO] = [:]
    var portfolioDelayNanoseconds: [String: UInt64] = [:]
    var requestedPortfolioSpaces: [String] = []
    var createdRequests: [FinancePortfolioPositionSaveRequestDTO] = []
    var portfolioRefreshCount = 0
    var refreshedWatchSourceIds: [String] = []

    func fetchPortfolio(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> FinancePortfolioDTO {
        requestedPortfolioSpaces.append(spaceId)
        if let fetchPortfolioError { throw fetchPortfolioError }
        let response = portfoliosBySpace[spaceId] ?? portfolio
        if let delay = portfolioDelayNanoseconds[spaceId] {
            try await Task.sleep(nanoseconds: delay)
        }
        return response
    }

    func createPosition(
        spaceId: String,
        request: FinancePortfolioPositionSaveRequestDTO
    ) async throws -> FinancePortfolioDTO {
        createdRequests.append(request)
        return portfolio
    }

    func updatePosition(
        spaceId: String,
        positionId: String,
        request: FinancePortfolioPositionSaveRequestDTO
    ) async throws -> FinancePortfolioDTO {
        return portfolio
    }

    func removePosition(
        spaceId: String,
        positionId: String
    ) async throws -> FinancePortfolioDTO {
        return portfolio
    }

    func refreshPortfolio(spaceId: String) async throws -> FinanceAssetPriceRefreshDTO {
        portfolioRefreshCount += 1
        return portfolioRefresh
    }

    func fetchNetWorthHistory(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> FinanceNetWorthHistoryDTO {
        history
    }

    func fetchAssetSources(
        spaceId: String,
        forceRefresh: Bool
    ) async throws -> [FinanceAssetSourceDTO] {
        sources
    }

    func createWatchAddress(
        spaceId: String,
        request: FinanceWatchAddressSaveRequestDTO
    ) async throws -> FinanceAssetSourceDTO {
        let source = FinanceAssetSourceDTO(
            id: UUID().uuidString,
            spaceId: spaceId,
            sourceKind: request.sourceKind,
            label: request.label,
            publicAddress: request.publicAddress,
            status: "ACTIVE"
        )
        sources.append(source)
        return source
    }

    func refreshWatchAddress(sourceId: String) async throws -> FinanceAssetSnapshotDTO {
        refreshedWatchSourceIds.append(sourceId)
        let source = sources.first { $0.id == sourceId } ?? sources[0]
        return FinanceAssetSnapshotDTO(
            id: UUID().uuidString,
            source: source,
            asOfAt: "2026-08-10T04:00:00+00:00",
            snapshotKind: "WATCH_ONLY",
            dataStatus: "COMPLETE",
            positionCount: 1
        )
    }

    func disconnectSource(sourceId: String) async throws -> FinanceAssetSourceDTO {
        let source = sources.first { $0.id == sourceId } ?? sources[0]
        sources.removeAll { $0.id == sourceId }
        return FinanceAssetSourceDTO(
            id: source.id,
            spaceId: source.spaceId,
            sourceKind: source.sourceKind,
            label: source.label,
            publicAddress: source.publicAddress,
            status: "PAUSED"
        )
    }

    private static func holding(
        key: String,
        sourceId: String?,
        sourceLabel: String,
        name: String,
        layer: String,
        valueMinor: Int
    ) -> FinanceNetWorthHoldingDTO {
        FinanceNetWorthHoldingDTO(
            key: key,
            sourceId: sourceId,
            sourceLabel: sourceLabel,
            name: name,
            layer: layer,
            valueMinor: valueMinor,
            currency: "GBP",
            asOfAt: "2026-08-10T04:00:00+00:00",
            quantity: nil,
            quantityUnit: nil,
            instrumentIdKind: nil,
            instrumentId: nil,
            quoteSymbol: nil,
            unitPriceMinor: nil,
            priceSource: "Test",
            usingLastKnownPrice: false
        )
    }
}
