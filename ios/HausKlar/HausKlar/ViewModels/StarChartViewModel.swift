import Foundation
import SwiftUI

// MARK: - Star Chart DTOs

struct StarDTO: Codable, Identifiable {
    let id: String
    let chartId: String
    let rowIndex: Int
    let colIndex: Int
    let awardedAt: String
    let createdAt: String
}

struct StarChartDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let title: String
    let gridRows: Int
    let gridColumns: Int
    let rewardAmountPence: Int
    let completedAt: String?
    let starsCount: Int
    let totalCells: Int
    let stars: [StarDTO]
    let createdAt: String
    let updatedAt: String
}

struct BalanceDTO: Codable {
    let childId: String
    let balancePence: Int
    let balanceDisplay: String
}

struct TransactionDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let amountPence: Int
    let reason: String
    let chartId: String?
    let notes: String?
    let createdAt: String
}

struct ChartCompletedDTO: Codable {
    let chart: StarChartDTO
    let rewardAmountPence: Int
    let newBalancePence: Int
    let newBalanceDisplay: String
}

// MARK: - Request Bodies

private struct CreateChartRequest: Encodable {
    let childId: String
    let title: String
    let gridRows: Int
    let gridColumns: Int
    let rewardAmountPence: Int
}

private struct PlaceStarRequest: Encodable {
    let rowIndex: Int
    let colIndex: Int
    let clientId: String
    let clientTimestamp: String
}

private struct AdjustBalanceRequest: Encodable {
    let amountPence: Int
    let reason: String
    let notes: String?
    let clientId: String
    let clientTimestamp: String
}

private struct UpdateChartRequest: Encodable {
    let title: String
    let rewardAmountPence: Int
}

// MARK: - Cell Position

struct CellPosition: Hashable {
    let row: Int
    let col: Int
}

// MARK: - StarChartViewModel

@MainActor
final class StarChartViewModel: ObservableObject {

    // MARK: - Published State

    @Published var charts: [StarChartDTO] = []
    @Published var balance: BalanceDTO?
    @Published var transactions: [TransactionDTO] = []
    @Published var children: [ChildDTO] = []
    @Published var selectedChildId: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var busyCells: Set<String> = []

    // MARK: - Celebration State

    @Published var showingCelebration = false
    @Published var celebrationReward = 0
    @Published var celebrationBalance = ""

    // MARK: - Form State

    @Published var showingCreateChart = false
    @Published var showingAdjustBalance = false
    @Published var showingEditChart = false
    @Published var formTitle = "Star Chart"
    @Published var formRows = 2
    @Published var formColumns = 5
    @Published var formRewardPounds: Double = 5.0
    @Published var adjustAmountPounds: Double = 0.0
    @Published var adjustReason = "payout"
    @Published var adjustNotes = ""
    @Published var editTitle = ""
    @Published var editRewardPounds: Double = 0
    private var editingChartId: String?

    // MARK: - Computed

    var activeCharts: [StarChartDTO] {
        charts.filter { $0.completedAt == nil }
    }

    var completedCharts: [StarChartDTO] {
        charts.filter { $0.completedAt != nil }
    }

    func filledCells(for chart: StarChartDTO) -> Set<CellPosition> {
        Set(chart.stars.map { CellPosition(row: $0.rowIndex, col: $0.colIndex) })
    }

    // MARK: - Private

    private let apiClient = APIClient.shared

    // MARK: - Actions

    func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            let fetchedChildren: [ChildDTO] = try await apiClient.get("/children/")
            children = fetchedChildren
            if selectedChildId == nil, let first = fetchedChildren.first {
                selectedChildId = first.id
            }
        } catch {}

        if let childId = selectedChildId {
            async let chartsResult = fetchCharts(childId: childId)
            async let balanceResult = fetchBalance(childId: childId)
            async let transactionsResult = fetchTransactions(childId: childId)

            let (c, b, t) = await (chartsResult, balanceResult, transactionsResult)
            charts = c
            balance = b
            transactions = t
        }

        isLoading = false
    }

    func createChart() async {
        guard let childId = selectedChildId else { return }

        isLoading = true
        errorMessage = nil

        let request = CreateChartRequest(
            childId: childId,
            title: formTitle,
            gridRows: formRows,
            gridColumns: formColumns,
            rewardAmountPence: Int(formRewardPounds * 100)
        )

        do {
            let chart: StarChartDTO = try await apiClient.post("/star-charts/", body: request)
            charts.insert(chart, at: 0)
            showingCreateChart = false
            resetCreateForm()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to create chart.".localized
        }

        isLoading = false
    }

    func placeStar(chartId: String, row: Int, col: Int) async {
        let key = cellKey(chartId: chartId, row: row, col: col)
        guard busyCells.insert(key).inserted else { return }
        defer { busyCells.remove(key) }
        guard let originalChart = charts.first(where: { $0.id == chartId }) else { return }
        let now = Date()
        let operationId = UUID().uuidString
        let request = PlaceStarRequest(
            rowIndex: row,
            colIndex: col,
            clientId: operationId,
            clientTimestamp: ISODateParser.stringNoFractional(from: now)
        )

        let pendingStar = StarDTO(
            id: "pending-\(operationId)",
            chartId: chartId,
            rowIndex: row,
            colIndex: col,
            awardedAt: ISODateParser.stringNoFractional(from: now),
            createdAt: ISODateParser.stringNoFractional(from: now)
        )
        replaceChart(originalChart, stars: originalChart.stars + [pendingStar])

        do {
            let data = try await apiClient.postData("/star-charts/\(chartId)/stars", body: request)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            // Try decoding as ChartCompletedDTO first (final star triggers completion)
            if let completed = try? decoder.decode(ChartCompletedDTO.self, from: data) {
                if let idx = charts.firstIndex(where: { $0.id == chartId }) {
                    charts[idx] = completed.chart
                }
                balance = BalanceDTO(
                    childId: completed.chart.childId,
                    balancePence: completed.newBalancePence,
                    balanceDisplay: completed.newBalanceDisplay
                )
                celebrationReward = completed.rewardAmountPence
                celebrationBalance = completed.newBalanceDisplay
                showingCelebration = true
                transactions = await fetchTransactions(childId: completed.chart.childId)
            } else {
                if let placedStar = try? decoder.decode(StarDTO.self, from: data),
                   let current = charts.first(where: { $0.id == chartId }) {
                    replaceChart(
                        current,
                        stars: current.stars.map { $0.id == pendingStar.id ? placedStar : $0 }
                    )
                } else {
                    await reloadChart(chartId: chartId)
                }
            }
        } catch let error as APIError {
            await reloadChart(chartId: chartId)
            errorMessage = error.errorDescription
        } catch {
            await reloadChart(chartId: chartId)
            errorMessage = "Failed to place star.".localized
        }
    }

    func removeStar(chartId: String, starId: String) async {
        guard let chart = charts.first(where: { $0.id == chartId }),
              let star = chart.stars.first(where: { $0.id == starId }) else { return }
        let key = cellKey(chartId: chartId, row: star.rowIndex, col: star.colIndex)
        guard busyCells.insert(key).inserted else { return }
        defer { busyCells.remove(key) }
        do {
            try await apiClient.delete("/star-charts/\(chartId)/stars/\(starId)")
            await reloadChart(chartId: chartId)
            balance = await fetchBalance(childId: chart.childId)
            transactions = await fetchTransactions(childId: chart.childId)
            HapticManager.selection()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to remove star.".localized
        }
    }

    func adjustBalance() async {
        guard let childId = selectedChildId else { return }

        isLoading = true
        let pence = Int(adjustAmountPounds * 100) * (adjustReason == "payout" ? -1 : 1)
        let request = AdjustBalanceRequest(
            amountPence: pence,
            reason: adjustReason == "payout" ? "payout" : "manual_adjustment",
            notes: adjustNotes.isEmpty ? nil : adjustNotes,
            clientId: UUID().uuidString,
            clientTimestamp: ISODateParser.stringNoFractional(from: Date())
        )

        do {
            let newBalance: BalanceDTO = try await apiClient.post("/star-charts/balance/\(childId)/adjust", body: request)
            balance = newBalance
            transactions = await fetchTransactions(childId: childId)
            showingAdjustBalance = false
            resetAdjustForm()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to adjust balance.".localized
        }

        isLoading = false
    }

    // MARK: - Helpers

    func resetCreateForm() {
        formTitle = "Star Chart"
        formRows = 2
        formColumns = 5
        formRewardPounds = 5.0
    }

    func beginEditing(_ chart: StarChartDTO) {
        editingChartId = chart.id
        editTitle = chart.title
        editRewardPounds = Double(chart.rewardAmountPence) / 100
        showingEditChart = true
    }

    func saveChartEdits() async {
        guard let chartId = editingChartId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let request = UpdateChartRequest(
                title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                rewardAmountPence: Int((editRewardPounds * 100).rounded())
            )
            let updated: StarChartDTO = try await apiClient.put(
                "/star-charts/\(chartId)",
                body: request
            )
            if let index = charts.firstIndex(where: { $0.id == chartId }) {
                charts[index] = updated
            }
            showingEditChart = false
            editingChartId = nil
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to update chart.".localized
        }
    }

    func archiveChart(_ chart: StarChartDTO) async {
        do {
            try await apiClient.delete("/star-charts/\(chart.id)")
            charts.removeAll { $0.id == chart.id }
            HapticManager.selection()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to archive chart.".localized
        }
    }

    func resetAdjustForm() {
        adjustAmountPounds = 0.0
        adjustReason = "payout"
        adjustNotes = ""
    }

    func formatPence(_ pence: Int) -> String {
        String(format: "£%.2f", Double(pence) / 100.0)
    }

    func isCellBusy(chartId: String, row: Int, col: Int) -> Bool {
        busyCells.contains(cellKey(chartId: chartId, row: row, col: col))
    }

    func transactionTitle(_ transaction: TransactionDTO) -> String {
        switch transaction.reason {
        case "chart_completed":
            let title = charts.first { $0.id == transaction.chartId }?.title
            return title.map { "Completed \($0)" } ?? "Chart completed"
        case "manual_adjustment" where transaction.chartId != nil:
            if transaction.amountPence < 0 { return "Star removed" }
            let title = charts.first { $0.id == transaction.chartId }?.title
            return title.map { "Completed \($0)" } ?? "Chart completed"
        case "payout": return "Paid out"
        default: return transaction.amountPence >= 0 ? "Balance added" : "Balance corrected"
        }
    }

    // MARK: - Private

    private func fetchCharts(childId: String) async -> [StarChartDTO] {
        do {
            return try await apiClient.get(
                "/star-charts/",
                queryItems: [URLQueryItem(name: "child_id", value: childId)]
            )
        } catch {
            return []
        }
    }

    private func fetchBalance(childId: String) async -> BalanceDTO? {
        do {
            return try await apiClient.get("/star-charts/balance/\(childId)")
        } catch {
            return nil
        }
    }

    private func fetchTransactions(childId: String) async -> [TransactionDTO] {
        do {
            return try await apiClient.get(
                "/star-charts/balance/\(childId)/transactions",
                queryItems: [URLQueryItem(name: "limit", value: "20")]
            )
        } catch {
            return []
        }
    }

    private func cellKey(chartId: String, row: Int, col: Int) -> String {
        "\(chartId):\(row):\(col)"
    }

    private func replaceChart(_ chart: StarChartDTO, stars: [StarDTO]) {
        guard let index = charts.firstIndex(where: { $0.id == chart.id }) else { return }
        charts[index] = StarChartDTO(
            id: chart.id,
            childId: chart.childId,
            title: chart.title,
            gridRows: chart.gridRows,
            gridColumns: chart.gridColumns,
            rewardAmountPence: chart.rewardAmountPence,
            completedAt: chart.completedAt,
            starsCount: stars.count,
            totalCells: chart.totalCells,
            stars: stars,
            createdAt: chart.createdAt,
            updatedAt: chart.updatedAt
        )
    }

    private func reloadChart(chartId: String) async {
        do {
            let chart: StarChartDTO = try await apiClient.get("/star-charts/\(chartId)")
            if let idx = charts.firstIndex(where: { $0.id == chartId }) {
                charts[idx] = chart
            }
        } catch {}
    }
}
