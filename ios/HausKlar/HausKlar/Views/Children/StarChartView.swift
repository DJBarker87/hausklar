import SwiftUI

private struct PendingStarRemoval: Identifiable {
    let chart: StarChartDTO
    let star: StarDTO

    var id: String { star.id }
}

/// Star Charts view with interactive star grids, balance tracking, and celebration animations.
struct StarChartView: View {
    @StateObject private var viewModel = StarChartViewModel()
    @State private var animatingCell: CellPosition?
    @State private var pendingStarRemoval: PendingStarRemoval?
    @State private var chartToArchive: StarChartDTO?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var celebrationStarSize: CGFloat = 80
    let initialChildId: String?
    let initialChartId: String?

    init(initialChildId: String? = nil, initialChartId: String? = nil) {
        self.initialChildId = initialChildId
        self.initialChartId = initialChartId
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Child selector
                childSelector

                if viewModel.isLoading && viewModel.charts.isEmpty {
                    ProgressView("Loading star charts...")
                        .padding(.vertical, 40)
                } else {
                    // Balance card
                    balanceCard

                    // Active charts
                    if viewModel.activeCharts.isEmpty {
                        emptyState
                    } else {
                        ForEach(orderedActiveCharts) { chart in
                            chartCard(chart)
                                .id(chart.id)
                        }
                    }

                    // Completed charts
                    if !viewModel.completedCharts.isEmpty {
                        completedSection
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle("Star Charts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.resetCreateForm()
                    viewModel.showingCreateChart = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showingCreateChart) {
            createChartSheet
        }
        .sheet(isPresented: $viewModel.showingAdjustBalance) {
            adjustBalanceSheet
        }
        .sheet(isPresented: $viewModel.showingEditChart) {
            editChartSheet
        }
        .fullScreenCover(isPresented: $viewModel.showingCelebration) {
            celebrationView
        }
        .confirmationDialog(
            "Remove this star?",
            isPresented: removalConfirmationPresented,
            presenting: pendingStarRemoval
        ) { removal in
            Button("Remove star", role: .destructive) {
                Task {
                    await viewModel.removeStar(
                        chartId: removal.chart.id,
                        starId: removal.star.id
                    )
                }
            }
        } message: { removal in
            if removal.chart.completedAt != nil {
                Text("This reopens the chart and removes \(viewModel.formatPence(removal.chart.rewardAmountPence)) from the balance. You can add the star again at any time.")
            } else {
                Text("This takes one star off the chart. You can add it again at any time.")
            }
        }
        .confirmationDialog(
            "Archive this chart?",
            isPresented: archiveConfirmationPresented,
            presenting: chartToArchive
        ) { chart in
            Button("Archive chart", role: .destructive) {
                Task { await viewModel.archiveChart(chart) }
            }
        } message: { _ in
            Text("This hides the chart. The balance will not change.")
        }
        .task {
            if let initialChildId { viewModel.selectedChildId = initialChildId }
            await viewModel.loadData()
        }
        .refreshable {
            await viewModel.loadData()
        }
    }

    private var orderedActiveCharts: [StarChartDTO] {
        guard let initialChartId else { return viewModel.activeCharts }
        return viewModel.activeCharts.sorted { lhs, rhs in
            if lhs.id == initialChartId { return true }
            if rhs.id == initialChartId { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    // MARK: - Child Selector

    private var childSelector: some View {
        Group {
            if viewModel.children.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.children) { child in
                            Button {
                                viewModel.selectedChildId = child.id
                                Task { await viewModel.loadData() }
                            } label: {
                                Text(child.name)
                                    .font(.subheadline)
                                    .fontWeight(viewModel.selectedChildId == child.id ? .semibold : .regular)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        viewModel.selectedChildId == child.id
                                            ? Color.accentColor : Color(.systemGray5)
                                    )
                                    .foregroundStyle(
                                        viewModel.selectedChildId == child.id ? .white : .primary
                                    )
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Owed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.balance?.balanceDisplay ?? "£0.00")
                        .font(.title)
                        .fontWeight(.bold)
                }

                Spacer()

                Button("Adjust") {
                    viewModel.resetAdjustForm()
                    viewModel.showingAdjustBalance = true
                }
                .buttonStyle(.bordered)
            }

            if !viewModel.transactions.isEmpty {
                Divider()
                DisclosureGroup("Balance history") {
                    VStack(spacing: 10) {
                        ForEach(Array(viewModel.transactions.prefix(5))) { transaction in
                            transactionRow(transaction)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Chart Card

    private func chartCard(_ chart: StarChartDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(chart.title)
                    .font(.headline)
                Spacer()
                Text("\(chart.starsCount)/\(chart.totalCells) stars")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                chartMenu(chart)
            }

            // Progress bar
            ProgressView(value: Double(chart.starsCount), total: Double(chart.totalCells))
                .tint(.yellow)

            // Reward info
            Text("Reward: \(viewModel.formatPence(chart.rewardAmountPence))")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Star grid
            starGrid(chart: chart)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func starGrid(chart: StarChartDTO) -> some View {
        let filled = viewModel.filledCells(for: chart)

        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<chart.gridRows, id: \.self) { row in
                GridRow {
                    ForEach(0..<chart.gridColumns, id: \.self) { col in
                        let pos = CellPosition(row: row, col: col)
                        let star = chart.stars.first { $0.rowIndex == row && $0.colIndex == col }
                        let isFilled = filled.contains(pos)
                        let isAnimating = animatingCell == pos
                        let isBusy = viewModel.isCellBusy(chartId: chart.id, row: row, col: col)

                        Button {
                            if let star {
                                pendingStarRemoval = PendingStarRemoval(chart: chart, star: star)
                            } else {
                                if !reduceMotion {
                                    animatingCell = pos
                                }
                                let impact = UIImpactFeedbackGenerator(style: .medium)
                                impact.impactOccurred()
                                Task {
                                    await viewModel.placeStar(chartId: chart.id, row: row, col: col)
                                    if !reduceMotion {
                                        do {
                                            try await Task.sleep(nanoseconds: 500_000_000)
                                        } catch {
                                            animatingCell = nil
                                            return
                                        }
                                    }
                                    animatingCell = nil
                                }
                            }
                        } label: {
                            Image(systemName: isFilled ? "star.fill" : "star")
                                .font(.title2)
                                .foregroundStyle(isFilled ? .yellow : Color(.systemGray4))
                                .scaleEffect((!reduceMotion && isAnimating) ? 1.3 : 1.0)
                                .rotationEffect((!reduceMotion && isAnimating) ? .degrees(360) : .zero)
                                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.5), value: isAnimating)
                                .opacity(isBusy ? 0.6 : 1)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .accessibilityLabel(starAccessibilityLabel(
                            childName: viewModel.children.first(where: { $0.id == viewModel.selectedChildId })?.name ?? "Child",
                            chartTitle: chart.title,
                            row: row,
                            col: col,
                            isFilled: isFilled
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "star.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No active star charts")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Create Star Chart") {
                viewModel.resetCreateForm()
                viewModel.showingCreateChart = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 30)
    }

    // MARK: - Completed Section

    private var completedSection: some View {
        DisclosureGroup("Completed Charts (\(viewModel.completedCharts.count))") {
            ForEach(viewModel.completedCharts) { chart in
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(chart.title)
                        .font(.subheadline)
                    Spacer()
                    Text(viewModel.formatPence(chart.rewardAmountPence))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let star = latestStar(in: chart) {
                        Button("Undo last star") {
                            pendingStarRemoval = PendingStarRemoval(chart: chart, star: star)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    chartMenu(chart)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Celebration View

    private var celebrationView: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "star.fill")
                    .font(.system(size: celebrationStarSize))
                    .foregroundStyle(.yellow)
                    .shadow(color: reduceMotion ? .clear : .yellow.opacity(0.5), radius: reduceMotion ? 0 : 20)

                Text("Chart Complete!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Text("\(viewModel.formatPence(viewModel.celebrationReward)) added!")
                    .font(.title2)
                    .foregroundStyle(.yellow)

                Text("New balance: \(viewModel.celebrationBalance)")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))

                Button {
                    viewModel.showingCelebration = false
                } label: {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
            }
        }
    }

    // MARK: - Create Chart Sheet

    private var createChartSheet: some View {
        NavigationStack {
            Form {
                Section("Chart Settings") {
                    TextField("Title", text: $viewModel.formTitle)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stars to earn")
                            .font(.subheadline)
                        HStack(spacing: 8) {
                            chartSizeButton(stars: 10, rows: 2, columns: 5)
                            chartSizeButton(stars: 20, rows: 4, columns: 5)
                            chartSizeButton(stars: 25, rows: 5, columns: 5)
                        }
                    }

                    Text("Total: \(viewModel.formRows * viewModel.formColumns) stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DisclosureGroup("Custom layout") {
                        Stepper("Rows: \(viewModel.formRows)", value: $viewModel.formRows, in: 1...10)
                        Stepper("Columns: \(viewModel.formColumns)", value: $viewModel.formColumns, in: 1...10)
                    }
                }

                Section("Reward") {
                    HStack {
                        Text("£")
                        TextField("Amount", value: $viewModel.formRewardPounds, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.createChart() }
                    } label: {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView().padding(.trailing, 4)
                            }
                            Text("Create Chart")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(
                        viewModel.formTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.formRewardPounds < 0
                    )
                }
            }
            .navigationTitle("New Star Chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingCreateChart = false }
                }
            }
        }
    }

    // MARK: - Adjust Balance Sheet

    private func starAccessibilityLabel(childName: String, chartTitle: String, row: Int, col: Int, isFilled: Bool) -> String {
        "\(childName), \(chartTitle), row \(row + 1), column \(col + 1), \(isFilled ? "earned" : "not earned")"
    }

    private var editChartSheet: some View {
        NavigationStack {
            Form {
                Section("Chart") {
                    TextField("Title", text: $viewModel.editTitle)
                    HStack {
                        Text("Reward")
                        Spacer()
                        Text("£")
                        TextField("Amount", value: $viewModel.editRewardPounds, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.saveChartEdits() }
                    } label: {
                        Text("Save").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .disabled(
                        viewModel.editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.editRewardPounds < 0
                    )
                }
            }
            .navigationTitle("Edit Star Chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingEditChart = false }
                }
            }
        }
    }

    private func chartSizeButton(stars: Int, rows: Int, columns: Int) -> some View {
        let selected = viewModel.formRows == rows && viewModel.formColumns == columns
        return Button {
            viewModel.formRows = rows
            viewModel.formColumns = columns
        } label: {
            Label("\(stars)", systemImage: "star.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .yellow : .secondary)
    }

    private func chartMenu(_ chart: StarChartDTO) -> some View {
        Menu {
            if chart.completedAt == nil {
                Button("Edit", systemImage: "pencil") {
                    viewModel.beginEditing(chart)
                }
            }
            Button("Archive", systemImage: "archivebox", role: .destructive) {
                chartToArchive = chart
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Chart options")
    }

    private func latestStar(in chart: StarChartDTO) -> StarDTO? {
        chart.stars.max { $0.awardedAt < $1.awardedAt }
    }

    private func transactionRow(_ transaction: TransactionDTO) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.transactionTitle(transaction))
                    .foregroundStyle(.primary)
                if let notes = transaction.notes,
                   !notes.isEmpty,
                   notes.localizedCaseInsensitiveCompare("Star removed") != .orderedSame {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let date = ISODateParser.parse(transaction.createdAt) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(transactionAmount(transaction.amountPence))
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(transaction.amountPence >= 0 ? .green : .primary)
        }
    }

    private func transactionAmount(_ pence: Int) -> String {
        let amount = viewModel.formatPence(abs(pence))
        return pence >= 0 ? "+\(amount)" : "−\(amount)"
    }

    private var removalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingStarRemoval != nil },
            set: { if !$0 { pendingStarRemoval = nil } }
        )
    }

    private var archiveConfirmationPresented: Binding<Bool> {
        Binding(
            get: { chartToArchive != nil },
            set: { if !$0 { chartToArchive = nil } }
        )
    }

    private var maxPayoutPounds: Double {
        Double(viewModel.balance?.balancePence ?? 0) / 100.0
    }

    private var adjustBalanceSheet: some View {
        NavigationStack {
            Form {
                Section("Adjustment") {
                    Picker("Type", selection: $viewModel.adjustReason) {
                        Text("Payout").tag("payout")
                        Text("Bonus").tag("bonus")
                        Text("Correction").tag("correction")
                    }
                    .pickerStyle(.segmented)

                    if viewModel.adjustReason == "payout" && maxPayoutPounds > 0 {
                        VStack(spacing: 8) {
                            Text(String(format: "£%.2f", viewModel.adjustAmountPounds))
                                .font(.title)
                                .fontWeight(.bold)
                                .monospacedDigit()

                            Slider(
                                value: $viewModel.adjustAmountPounds,
                                in: 0...maxPayoutPounds,
                                step: 0.01
                            )
                            .tint(.orange)

                            HStack {
                                Text("£0")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    viewModel.adjustAmountPounds = maxPayoutPounds
                                } label: {
                                    Text(String(format: "Pay all £%.2f", maxPayoutPounds))
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack {
                            Text("£")
                            TextField("Amount", value: $viewModel.adjustAmountPounds, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }

                    TextField("Notes (optional)", text: $viewModel.adjustNotes, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    Button {
                        Task { await viewModel.adjustBalance() }
                    } label: {
                        Text("Apply").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.adjustAmountPounds <= 0)
                }
            }
            .navigationTitle("Adjust Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showingAdjustBalance = false }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        StarChartView()
    }
}
