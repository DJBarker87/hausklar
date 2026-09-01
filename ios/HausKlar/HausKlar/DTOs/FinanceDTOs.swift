import Foundation

// Stable, UI-independent Finance data types shared by native Simple Finance and
// the deeper web experience. Finance remains online-only on iOS.

struct FinanceSpaceDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let name: String
    let isDefault: Bool
}

struct FinanceBalanceDTO: Codable, Equatable, Sendable {
    let bookedMinor: Int
    let availableMinor: Int?
    let creditLimitMinor: Int?
    let providerAt: String?
    let observedAt: String
}

struct FinanceAccountSummaryDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let label: String
    let institution: String?
    let accountType: String
    let purpose: String
    let currency: String
    let lastFour: String?
    let includeInCashflow: Bool
    let includeInNetWorth: Bool
    let primarySpendingAccount: Bool
    let minimumBalanceMinor: Int
    let freshThroughDate: String?
    let dataThroughAt: String?
    let balance: FinanceBalanceDTO?
}

struct FinanceRelationDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let fromTransactionId: String
    let toTransactionId: String
    let relationType: String
    let status: String
    let method: String
    let confidenceBps: Int
}

struct FinanceTransactionSplitDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let transactionId: String
    let amountMinor: Int
    let categoryId: String?
    let categoryName: String
    let spendingType: String
    let label: String?
    let createdAt: String
}

struct FinanceTransactionDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let accountId: String
    let canonicalDate: String
    let amountMinor: Int
    let currency: String
    let state: String
    let transactionKind: String
    let sourceKind: String
    let description: String
    let merchantText: String?
    let merchantId: String?
    let primaryCategoryId: String?
    let primaryCategoryName: String?
    let primarySpendingType: String?
    let supersededById: String?
    let dataThroughAt: String
    let relations: [FinanceRelationDTO]
    let splits: [FinanceTransactionSplitDTO]

    var classificationDisplayName: String {
        guard let name = primaryCategoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return "Uncategorised".localized
        }
        return name
    }

    var isConfirmedNeutralMovement: Bool {
        relations.contains {
            $0.status == "CONFIRMED"
                && ["INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT", "FX_LEG"]
                    .contains($0.relationType)
        }
    }
}

struct FinanceOverviewSpendingCategoryDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { categoryKey }
    let categoryKey: String
    let name: String
    let spendingType: String
    let spentMinor: Int
    let shareBps: Int
}

struct FinanceOverviewBudgetBucketDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { categoryKey }
    let categoryKey: String
    let name: String
    let budgetMinor: Int
    let spentMinor: Int
    let remainingMinor: Int
}

struct FinanceOverviewCommitmentDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(dueDate):\(name):\(amountMinor)" }
    let name: String
    let dueDate: String
    let amountMinor: Int
}

struct FinanceOverviewSavingsPointDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { date }
    let date: String
    let balanceMinor: Int
}

struct FinanceOverviewDTO: Codable, Equatable, Sendable {
    let scope: String
    let monthStart: String
    let throughDate: String
    let currency: String
    let accountCount: Int
    let incomeMinor: Int
    let spendingMinor: Int
    let spendingByCategory: [FinanceOverviewSpendingCategoryDTO]
    let budgetBuckets: [FinanceOverviewBudgetBucketDTO]
    let currentAvailableMinor: Int?
    let nextPaycheckDate: String?
    let nextPaycheckMinor: Int?
    let leftUntilPaydayMinor: Int?
    let commitmentsBeforePaydayMinor: Int
    let commitmentsBeforePaydayCount: Int
    let upcomingCommitments: [FinanceOverviewCommitmentDTO]
    let savingsBalanceMinor: Int?
    let savingsChangeMinor: Int?
    let savingsSeries: [FinanceOverviewSavingsPointDTO]
}

struct FinanceTransactionPageDTO: Codable, Equatable, Sendable {
    let items: [FinanceTransactionDTO]
    let offset: Int
    let limit: Int
    let hasMore: Bool
}

struct FinancePurchaseEvidenceInboxItemDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let sourceId: String
    let purchaseId: String?
    let exceptionKind: String
    let title: String
    let detail: String
    let amountMinor: Int?
    let currency: String?
    let status: String
    let priority: Int
    let createdAt: String
}

struct FinancePurchaseEvidenceInboxDTO: Codable, Equatable, Sendable {
    let items: [FinancePurchaseEvidenceInboxItemDTO]
    let openCount: Int
}

struct FinancePurchaseLineDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let lineRef: String
    let position: Int
    let lineKind: String
    let rawDescription: String
    let quantityDecimal: String
    let unitDescription: String?
    let unitPriceMinor: Int?
    let lineGrossMinor: Int?
    let lineDiscountMinor: Int?
    let lineNetMinor: Int?
    let evidenceStatus: String
    let seller: String?
    let productReference: String?
}

struct FinancePurchaseEvidenceSummaryDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sourceKind: String
    let extractionStatus: String
    let confidenceBps: Int?
    let receivedAt: String
    let parsedAt: String?
}

struct FinancePurchaseRecordDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let merchant: String
    let itemDescriptions: [String]
    let orderReference: String?
    let purchasedOn: String
    let currency: String
    let finalTotalMinor: Int
    let refundedMinor: Int
    let behaviouralNetMinor: Int
    let status: String
    let sourceKind: String
    let matchStatus: String
    let unmatchedPurchaseMinor: Int
    let unmatchedRefundMinor: Int
    let evidence: FinancePurchaseEvidenceSummaryDTO?
    let lines: [FinancePurchaseLineDTO]?
    let createdAt: String
}

struct FinanceItemAssessmentDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let lineId: String
    let purchaseId: String
    let spaceId: String
    let sourceDescription: String
    let normalizedItemId: String?
    let normalizedItemName: String?
    let beneficiary: String?
    let purpose: String?
    let plannedness: String?
    let utility: String?
    let decisionQuality: String?
    let valueForMoney: String?
    let outcomeState: String?
    let classificationSource: String
    let confidenceBps: Int
    let reviewStatus: String
    let updatedAt: String
}

struct FinanceProductPriceObservationDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let normalizedItemId: String
    let normalizedItemName: String
    let sourceKind: String
    let sourceLineId: String?
    let retailerName: String
    let productName: String
    let packQuantity: String
    let packUnit: String
    let comparableQuantity: String
    let unitBasis: String
    let priceMinor: Int
    let currency: String
    let observedOn: String
    let confidenceBps: Int
    let evidenceRefs: [String]
}

struct FinanceItemHistoryDTO: Codable, Equatable, Sendable {
    let normalizedItemId: String
    let normalizedItemName: String
    let dataThrough: String?
    let observations: [FinanceProductPriceObservationDTO]
}

struct FinanceAnalysisFiltersDTO: Codable, Equatable, Sendable {
    var accountIds: [String] = []
    var merchants: [String] = []
    var categories: [String] = []
    var normalizedItems: [String] = []
    var purposes: [String] = []
    var beneficiaries: [String] = []
}

struct FinanceAnalysisQueryDTO: Codable, Equatable, Sendable {
    let spaceId: String
    let basis: String
    let startDate: String
    let endDate: String
    let currency: String
    let grouping: String
    let measure: String
    let comparison: String
    let pendingPolicy: String
    let refundPolicy: String
    let transferPolicy: String
    let filters: FinanceAnalysisFiltersDTO
    let saveAs: String?
}

struct FinanceExactValueDTO: Codable, Equatable, Sendable {
    let numerator: Int
    let denominator: Int
}

struct FinanceAnalysisGroupDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let value: FinanceExactValueDTO
    let recordCount: Int
    let evidenceHandles: [String]
}

struct FinanceAnalysisResultDTO: Codable, Equatable, Sendable {
    let basis: String
    let currency: String
    let total: FinanceExactValueDTO
    let groups: [FinanceAnalysisGroupDTO]
    let comparisonGroups: [FinanceAnalysisGroupDTO]
    let comparisonTotal: FinanceExactValueDTO?
    let dataThrough: String?
    let evidence: [FinanceEvidenceHandleDTO]
    let savedView: FinanceAnalysisViewDTO?
}

struct FinanceEvidenceHandleDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { handle }
    let handle: String
    let kind: String
    let recordId: String
    let deepLink: String
}

struct FinanceAnalysisViewDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let name: String
    let request: FinanceAnalysisQueryDTO
    let deepLink: String
    let createdAt: String
    let updatedAt: String
}

struct FinanceCommitmentSummaryDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let name: String
    let amountMode: String
    let exactMinor: Int?
    let expectedMinor: Int?
    let lowMinor: Int?
    let highMinor: Int?
    let currency: String
    let recurrence: String
    let nextDueDate: String?
    let priority: String
    let requiredMinor: Int
    let remainingMinor: Int
    let fundingStatus: String
    let status: String
}

struct FinanceGoalSummaryDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let name: String
    let targetMinor: Int
    let deadline: String
    let currentlyAllocatedMinor: Int
    let remainingMinor: Int
    let currency: String
    let priority: String
    let feasibility: String
    let shortfallMinor: Int?
    let status: String
}

struct FinancePlanComparisonDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let proposalGroupId: String
    let spaceId: String
    let version: Int
    let strategy: String
    let effortLevel: String
    let answerBasis: String
    let confidenceBps: Int
    let currency: String
    let goalId: String
    let targetDate: String
    let supportedGoalDate: String?
    let forecastCoverageEnd: String?
    let requiredMonthlyMinor: Int
    let plannedMonthlySavingMinor: Int
    let projectedAmountAtTargetMinor: Int
    let goalShortfallAtTargetMinor: Int
    let monthlyChangeMinor: Int
    let householdBufferMinor: Int
    let requiredReductionMinor: Int
    let achievedReductionMinor: Int
    let shortfallMinor: Int
    let feasible: Bool
    let status: String
    let rationale: String
    let assumptions: [String]
    let categories: [FinancePlanCategoryDTO]
}

struct FinancePlanCategoryDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { categoryId }
    let categoryId: String
    let name: String
    let baselineMinor: Int
    let floorMinor: Int
    let protected: Bool
    let weight: Int
    let reductionMinor: Int
    let budgetMinor: Int
}

struct FinancePlanSetDTO: Codable, Equatable, Sendable {
    let proposalGroupId: String
    let version: Int
    let recommendationStrategy: String
    let recommendationEffortLevel: String
    let plans: [FinancePlanComparisonDTO]
}

struct FinancePlanGenerateRequestDTO: Codable, Equatable, Sendable {
    let goalId: String
}

struct FinanceSafeToSpendResultDTO: Codable, Equatable, Sendable {
    let forecastId: String
    let inputSnapshotDigest: String
    let status: String
    let answerMode: String
    let currency: String
    let amountMinor: Int?
    let lowMinor: Int?
    let highMinor: Int?
    let dataThrough: String?
    let evaluatedThrough: String
    let refusalReasons: [String]
}

struct FinancePaydayActionDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let planId: String
    let dueDate: String
    let sourceAccountId: String
    let destinationAccountId: String
    let amountMinor: Int
    let safeAfterTransferMinor: Int
    let currency: String
    let status: String
    let changedAmountMinor: Int?
    let updatedAt: String
}

struct FinanceHabitExperimentDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let slot: String
    let name: String
    let trigger: String
    let baselineStart: String
    let baselineEnd: String
    let baselineMinor: Int
    let startDate: String
    let reviewDate: String
    let expectedSavingLowMinor: Int
    let expectedSavingHighMinor: Int
    let actualSpendMinor: Int
    let realisedSavingMinor: Int
    let displacementMinor: Int
    let frictionRating: Int?
    let fallback: String
    let currency: String
    let status: String
    let reviewDecision: String?
    let evidenceRefs: [String]
}

struct FinancePurchaseProposalDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let sourceKind: String
    let name: String
    let amountLowMinor: Int
    let amountHighMinor: Int
    let desiredDate: String
    let recurrence: String
    let paymentAccountId: String
    let purpose: String?
    let beneficiary: String?
    let lines: [JSONValue]
    let cheaperAlternativeMinor: Int?
    let laterDate: String?
    let uncertainties: [String]
    let currency: String
    let status: String
    let approvedScenario: String?
    let createdAt: String
    let updatedAt: String
}

struct FinancePurchaseEvaluationDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let proposalId: String
    let forecastId: String
    let verdict: String
    let rationale: String
    let scenarios: [JSONValue]
    let historicalContext: [String: JSONValue]
    let evidenceRefs: [String]
    let dataThroughAt: String?
    let createdAt: String
}

struct FinanceAnswerClaimDTO: Codable, Equatable, Sendable {
    let text: String
    let evidenceIds: [String]
}

struct FinanceAnswerEstimateDTO: Codable, Equatable, Sendable {
    let text: String
    let assumptions: [String]
    let lowMinor: Int?
    let highMinor: Int?
    let currency: String?
}

struct FinanceAnswerDTO: Codable, Equatable, Sendable {
    let kind: String
    let headline: String
    let answer: String
    let answerMode: String
    let dataThrough: String?
    let claims: [FinanceAnswerClaimDTO]
    let estimates: [FinanceAnswerEstimateDTO]
    let suggestedActions: [String]
    let analysisViewId: String?
    let questions: [String]
}

struct FinanceFindingDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let findingType: String
    let title: String
    let observation: String
    let evidenceRefs: [String]
    let savingLowMinor: Int
    let savingHighMinor: Int
    let currency: String
    let confidenceBps: Int
    let effort: Int
    let overlapGroup: String?
    let status: String
    let dataThroughDate: String
    let updatedAt: String
}

struct FinanceProductSavingOpportunityDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let normalizedItemId: String
    let normalizedItemName: String
    let researchResultId: String
    let periodStart: String
    let periodEnd: String
    let actualSpendMinor: Int
    let currency: String
    let comparisonMode: String
    let candidateLowMinor: Int
    let candidateHighMinor: Int
    let savingLowMinor: Int
    let savingHighMinor: Int
    let confidenceBps: Int
    let dataThrough: String
    let status: String
}

struct FinanceAssetLayerDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { layer }
    let layer: String
    let amountMinor: Int?
    let knownComponentsMinor: Int
    let unknownComponentCount: Int
    let includedInTotal: Bool
    let dataThrough: String?
    let note: String?
}

struct FinanceAssetSummaryDTO: Codable, Equatable, Sendable {
    let spaceId: String
    let currency: String
    let totalNetWorthMinor: Int?
    let knownNetWorthMinor: Int
    let dataThrough: String?
    let layers: [FinanceAssetLayerDTO]
}

struct FinancePortfolioPositionDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let quoteSymbol: String
    let quoteCurrency: String
    let quantity: String
    let costBasisMinor: Int?
    let unitPriceMinor: Int?
    let valueMinor: Int?
    let gainMinor: Int?
    let currency: String
    let priceObservedAt: String?
    let priceSource: String?
    let usingLastKnownPrice: Bool
}

struct FinancePortfolioHistoryPointDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { date }
    let date: String
    let valueMinor: Int
    let knownPositionCount: Int
    let unknownPositionCount: Int
}

struct FinancePortfolioDTO: Codable, Equatable, Sendable {
    let spaceId: String
    let sourceId: String?
    let label: String
    let currency: String
    let totalValueMinor: Int
    let totalCostBasisMinor: Int?
    let totalGainMinor: Int?
    let missingCostBasisCount: Int
    let unknownPositionCount: Int
    let priceObservedAt: String?
    let priceSources: [String]
    let usingLastKnownPrices: Bool
    let positions: [FinancePortfolioPositionDTO]
    let history: [FinancePortfolioHistoryPointDTO]
}

struct FinancePortfolioPositionSaveRequestDTO: Encodable, Equatable, Sendable {
    let id: String?
    let name: String
    let quoteSymbol: String
    let quoteCurrency: String
    let quantity: String
    let costBasisMinor: Int?
}

struct FinanceAssetSourceDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let sourceKind: String
    let label: String
    let publicAddress: String?
    let status: String
}

struct FinanceWatchAddressSaveRequestDTO: Encodable, Equatable, Sendable {
    let sourceKind: String
    let label: String
    let publicAddress: String
}

struct FinanceAssetSnapshotDTO: Codable, Equatable, Sendable {
    let id: String
    let source: FinanceAssetSourceDTO
    let asOfAt: String
    let snapshotKind: String
    let dataStatus: String
    let positionCount: Int
}

struct FinanceAssetPriceRefreshDTO: Codable, Equatable, Sendable {
    let sourceId: String
    let sourceLabel: String
    let pricedHoldingCount: Int
    let retainedHoldingCount: Int
    let priceObservedAt: String?
    let priceSources: [String]
}

struct FinanceNetWorthPointLayerDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { layer }
    let layer: String
    let amountMinor: Int
}

struct FinanceNetWorthPointDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { asOfDate }
    let asOfDate: String
    let totalMinor: Int
    let unknownComponentCount: Int
    let layers: [FinanceNetWorthPointLayerDTO]
    let contributionsMinor: Int
    let withdrawalsMinor: Int
    let marketMovementMinor: Int?
}

struct FinanceNetWorthHoldingDTO: Codable, Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let sourceId: String?
    let sourceLabel: String
    let name: String
    let layer: String
    let valueMinor: Int
    let currency: String
    let asOfAt: String
    let quantity: String?
    let quantityUnit: String?
    let instrumentIdKind: String?
    let instrumentId: String?
    let quoteSymbol: String?
    let unitPriceMinor: Int?
    let priceSource: String
    let usingLastKnownPrice: Bool
}

struct FinanceNetWorthHistoryDTO: Codable, Equatable, Sendable {
    let spaceId: String
    let currency: String
    let points: [FinanceNetWorthPointDTO]
    let currentTotalMinor: Int
    let changeMinor: Int
    let periodContributionsMinor: Int
    let periodWithdrawalsMinor: Int
    let periodMarketMovementMinor: Int
    let holdings: [FinanceNetWorthHoldingDTO]
    let priceObservedAt: String?
    let priceSources: [String]
    let usingLastKnownPrices: Bool
}

struct FinanceDailyCoachReportDTO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let spaceId: String
    let memberUserId: String
    let reportKind: String
    let localDate: String
    let householdTimezone: String
    let locale: String
    let currency: String
    let inputDigest: String
    let dataThroughAt: String?
    let itemisedCoverageBps: Int?
    let trajectoryStatus: String
    let expectedDurableSavingMinor: Int
    let primaryAction: [String: JSONValue]?
    let optionalObservation: [String: JSONValue]?
    let summary: [String: JSONValue]
    let explanation: String
    let createdAt: String
}

struct FinanceCoachDashboardDTO: Codable, Equatable, Sendable {
    let spaceId: String
    let accounts: [FinanceAccountSummaryDTO]
    let commitments: [FinanceCommitmentSummaryDTO]
    let goals: [FinanceGoalSummaryDTO]
    let activePlan: FinancePlanComparisonDTO?
    let paydayActions: [FinancePaydayActionDTO]
    let habits: [FinanceHabitExperimentDTO]
    let latestReport: FinanceDailyCoachReportDTO?
    let findings: [FinanceFindingDTO]
    let assets: FinanceAssetSummaryDTO?
}
