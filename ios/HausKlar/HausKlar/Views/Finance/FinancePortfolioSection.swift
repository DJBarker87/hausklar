import Charts
import SwiftUI

private struct FinancePortfolioChartPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let valueMinor: Int
}

struct FinancePortfolioSection: View {
    let spaceId: String
    let goal: FinanceGoalSummaryDTO?

    @StateObject private var viewModel = FinancePortfolioViewModel()
    @State private var showingPositionEditor = false
    @State private var editingPosition: FinancePortfolioPositionDTO?
    @State private var showingSourceEditor = false
    @State private var pendingRemoval: FinancePortfolioPositionDTO?
    @State private var pendingDisconnect: FinanceAssetSourceDTO?

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.portfolio == nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading portfolio…".localized)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(Color(.secondarySystemGroupedBackground), in: cardShape)
            } else {
                portfolioHero

                if let error = viewModel.errorMessage {
                    portfolioStatus(error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                } else if let notice = viewModel.notice {
                    portfolioStatus(notice, systemImage: "checkmark.circle.fill", tint: .green)
                }

                portfolioHistoryCard
                allocationCard
                positionsCard
                cryptoSourcesCard
            }
        }
        .task(id: spaceId) {
            await viewModel.load(spaceId: spaceId)
        }
        .sheet(
            isPresented: $showingPositionEditor,
            onDismiss: {
                editingPosition = nil
            }
        ) {
            FinancePositionEditorSheet(
                position: editingPosition,
                isSaving: viewModel.isSaving
            ) { id, name, symbol, quoteCurrency, quantity, costBasisMinor in
                await viewModel.savePosition(
                    id: id,
                    name: name,
                    quoteSymbol: symbol,
                    quoteCurrency: quoteCurrency,
                    quantity: quantity,
                    costBasisMinor: costBasisMinor
                )
            }
        }
        .sheet(isPresented: $showingSourceEditor) {
            FinancePublicAssetSourceEditorSheet(isSaving: viewModel.isSaving) {
                kind, label, address in
                await viewModel.addWatchAddress(kind: kind, label: label, address: address)
            }
        }
        .confirmationDialog(
            "Remove this position?".localized,
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove position".localized, role: .destructive) {
                guard let position = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await viewModel.removePosition(position) }
            }
            Button("Cancel".localized, role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Its previous values stay in portfolio history.".localized)
        }
        .confirmationDialog(
            "Remove this public address?".localized,
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { if !$0 { pendingDisconnect = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove public address".localized, role: .destructive) {
                guard let source = pendingDisconnect else { return }
                pendingDisconnect = nil
                Task { await viewModel.disconnect(source) }
            }
            Button("Cancel".localized, role: .cancel) { pendingDisconnect = nil }
        } message: {
            Text("Saved value history remains. This removes only the public address from HausKlar.".localized)
        }
    }

    private var portfolioHero: some View {
        let currency = viewModel.portfolio?.currency ?? "GBP"
        let total =
            viewModel.trackedHoldings.isEmpty
            ? (viewModel.portfolio?.totalValueMinor ?? 0)
            : viewModel.trackedSavingsTotalMinor
        let goalProgress: Double? = goal.flatMap {
            guard $0.currency.caseInsensitiveCompare(currency) == .orderedSame,
                $0.targetMinor > 0
            else { return nil }
            return min(1, Double(total) / Double($0.targetMinor))
        }

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Tracked savings".localized, systemImage: "chart.pie.fill")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(money(total, currency: currency))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    HapticManager.selection()
                    Task { await viewModel.refreshAll() }
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView()
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRefreshing || viewModel.isSaving)
                .accessibilityLabel("Refresh savings values".localized)
            }

            if let goal, let goalProgress {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(goal.name)
                                .font(.subheadline.weight(.semibold))
                            Text("Total tracked savings against this goal".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(Int((goalProgress * 100).rounded()))%")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    }
                    ProgressView(value: goalProgress)
                        .tint(.accentColor)
                    Text(
                        String(
                            format: "%@ to target".localized,
                            money(max(0, goal.targetMinor - total), currency: goal.currency)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if viewModel.portfolio?.unknownPositionCount ?? 0 > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Some positions are waiting for a public price.".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .overlay { cardShape.stroke(Color.accentColor.opacity(0.2), lineWidth: 1) }
        .accessibilityIdentifier("financeSavingsPortfolioHero")
    }

    @ViewBuilder
    private var portfolioHistoryCard: some View {
        let points = viewModel.trackedHistory.compactMap { item -> FinancePortfolioChartPoint? in
            guard let date = ISODateParser.parse(item.date) else { return nil }
            return FinancePortfolioChartPoint(date: date, valueMinor: item.valueMinor)
        }
        if points.count > 1 {
            VStack(alignment: .leading, spacing: 14) {
                Text("Portfolio value".localized)
                    .font(.title3.weight(.bold))
                Chart(points) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.valueMinor)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.12).gradient)
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.valueMinor)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick().foregroundStyle(.secondary.opacity(0.4))
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("Tracked savings value over time".localized)
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        }
    }

    @ViewBuilder
    private var allocationCard: some View {
        let slices = allocationSlices
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("What you hold".localized)
                    .font(.title3.weight(.bold))
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Value", slice.valueMinor),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Holding", slice.name))
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                .frame(height: 250)
                .accessibilityLabel("Savings allocation".localized)
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        }
    }

    private var positionsCard: some View {
        let positions = viewModel.portfolio?.positions ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Securities".localized)
                        .font(.title3.weight(.bold))
                    Text("Entered independently of any broker".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    editingPosition = nil
                    showingPositionEditor = true
                } label: {
                    Label("Add position".localized, systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSaving)
                .accessibilityLabel("Add portfolio position".localized)
            }

            if positions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("No securities entered yet.".localized, systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.secondary)
                    Button("Add your first position".localized) {
                        editingPosition = nil
                        showingPositionEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(positions) { position in
                    Divider()
                    positionRow(position)
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityIdentifier("financeSavingsSecurities")
    }

    private func positionRow(_ position: FinancePortfolioPositionDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(position.name)
                    .font(.subheadline.weight(.semibold))
                Text(
                    String(
                        format: "%@ · %@ units".localized,
                        position.quoteSymbol,
                        position.quantity
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if position.valueMinor == nil {
                    Text("Waiting for a public price".localized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if let gain = position.gainMinor {
                    Text(changeText(gain, currency: position.currency))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(gain >= 0 ? Color.green : Color.orange)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(position.valueMinor.map { money($0, currency: position.currency) } ?? "—")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                if let price = position.unitPriceMinor {
                    Text(
                        String(
                            format: "%@/unit".localized,
                            money(price, currency: position.currency)
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Menu {
                Button {
                    editingPosition = position
                    showingPositionEditor = true
                } label: {
                    Label("Edit".localized, systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingRemoval = position
                } label: {
                    Label("Remove".localized, systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(
                String(
                    format: "Position actions for %@".localized,
                    position.name
                ))
        }
        .frame(minHeight: 58)
        .accessibilityElement(children: .contain)
    }

    private var cryptoSourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Solana & Hyperliquid".localized)
                        .font(.title3.weight(.bold))
                    Text("Public addresses only · never keys or trading".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    showingSourceEditor = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSaving)
                .accessibilityLabel("Add public crypto address".localized)
            }

            if viewModel.watchSources.isEmpty {
                Label("No public crypto addresses saved.".localized, systemImage: "link")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.watchSources) { source in
                    Divider()
                    HStack(spacing: 10) {
                        Image(
                            systemName: source.sourceKind == "SOLANA_PUBLIC"
                                ? "circle.hexagongrid.fill" : "waveform.path.ecg"
                        )
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.label)
                                .font(.subheadline.weight(.semibold))
                            Text(source.sourceKind == "SOLANA_PUBLIC" ? "Solana" : "Hyperliquid")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Menu {
                            Button(role: .destructive) {
                                pendingDisconnect = source
                            } label: {
                                Label("Remove public address".localized, systemImage: "link.badge.minus")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(
                            String(
                                format: "Source actions for %@".localized,
                                source.label
                            ))
                    }
                    .frame(minHeight: 52)
                }
            }

            if !viewModel.cryptoHoldings.isEmpty {
                Divider()
                ForEach(viewModel.cryptoHoldings.prefix(8)) { holding in
                    HStack {
                        Text(holding.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(money(holding.valueMinor, currency: holding.currency))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .frame(minHeight: 40)
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityIdentifier("financeSavingsCrypto")
    }

    private func portfolioStatus(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 16)
            .background(tint.opacity(0.1), in: cardShape)
    }

    private var allocationSlices: [FinanceTrackedSavingsAllocation] {
        let allocations = viewModel.allocations
        guard allocations.count > 6 else { return allocations }
        let leading = Array(allocations.prefix(5))
        let remainder = allocations.dropFirst(5).reduce(0) { $0 + $1.valueMinor }
        return leading + [
            FinanceTrackedSavingsAllocation(
                key: "other",
                name: "Other".localized,
                valueMinor: remainder
            )
        ]
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private func money(_ minor: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale.hausKlarSelected
        return formatter.string(from: NSNumber(value: Double(minor) / 100))
            ?? "\(currency) \(Double(minor) / 100)"
    }

    private func changeText(_ minor: Int, currency: String) -> String {
        if minor > 0 {
            return String(format: "+%@ since purchase".localized, money(minor, currency: currency))
        }
        if minor < 0 {
            return String(
                format: "−%@ since purchase".localized,
                money(abs(minor), currency: currency)
            )
        }
        return "No change from cost basis".localized
    }
}

private struct FinancePositionEditorSheet: View {
    let position: FinancePortfolioPositionDTO?
    let isSaving: Bool
    let onSave: (String?, String, String, String, String, Int?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var quoteCurrency: String
    @State private var quantity: String
    @State private var costBasis: String
    @State private var validationMessage: String?

    init(
        position: FinancePortfolioPositionDTO?,
        isSaving: Bool,
        onSave: @escaping (String?, String, String, String, String, Int?) async -> Bool
    ) {
        self.position = position
        self.isSaving = isSaving
        self.onSave = onSave
        _name = State(initialValue: position?.name ?? "")
        _symbol = State(initialValue: position?.quoteSymbol ?? "")
        _quoteCurrency = State(initialValue: position?.quoteCurrency ?? "GBP")
        _quantity = State(initialValue: position?.quantity ?? "")
        _costBasis = State(initialValue: Self.decimalText(position?.costBasisMinor))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Position".localized) {
                    TextField("Name".localized, text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Public price symbol".localized, text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Quoted in".localized, selection: $quoteCurrency) {
                        Text("GBP").tag("GBP")
                        Text("GBX · pence").tag("GBX")
                        Text("USD").tag("USD")
                        Text("EUR").tag("EUR")
                    }
                    TextField("Units held".localized, text: $quantity)
                        .keyboardType(.decimalPad)
                }

                Section("Performance (optional)".localized) {
                    HStack {
                        Text("GBP")
                            .foregroundStyle(.secondary)
                        TextField("Total amount paid".localized, text: $costBasis)
                            .keyboardType(.decimalPad)
                    }
                    Text("Without this, HausKlar shows value change only from the day tracking starts.".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Use the exact symbol accepted by the public price service, such as VWRP.LON or VT.".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle((position == nil ? "Add Position" : "Edit Position").localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".localized) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button((isSaving ? "Saving…" : "Save").localized) {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func save() async {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleanName.isEmpty else {
            validationMessage = "Enter a position name.".localized
            return
        }
        guard !cleanSymbol.isEmpty else {
            validationMessage = "Enter a public market symbol.".localized
            return
        }
        guard let amount = Decimal(string: cleanQuantity), amount > 0 else {
            validationMessage = "Enter a number of units greater than zero.".localized
            return
        }
        let costBasisMinor: Int?
        if costBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            costBasisMinor = nil
        } else if let parsed = Self.minorUnits(costBasis) {
            costBasisMinor = parsed
        } else {
            validationMessage = "Enter a valid total purchase cost or leave it blank.".localized
            return
        }
        validationMessage = nil
        let saved = await onSave(
            position?.id,
            cleanName,
            cleanSymbol,
            quoteCurrency,
            cleanQuantity,
            costBasisMinor
        )
        if saved {
            HapticManager.success()
            dismiss()
        } else {
            validationMessage = "That position could not be saved.".localized
        }
    }

    private static func minorUnits(_ value: String) -> Int? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: clean), decimal >= 0 else { return nil }
        let number = NSDecimalNumber(decimal: decimal * 100)
        let rounded = number.rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            ))
        guard number != .notANumber, number == rounded else { return nil }
        return rounded.intValue
    }

    private static func decimalText(_ minor: Int?) -> String {
        guard let minor else { return "" }
        return String(format: "%.2f", Double(minor) / 100)
    }
}

private struct FinancePublicAssetSourceEditorSheet: View {
    let isSaving: Bool
    let onSave: (String, String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "SOLANA_PUBLIC"
    @State private var label = ""
    @State private var address = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Public source".localized) {
                    Picker("Network".localized, selection: $kind) {
                        Text("Solana").tag("SOLANA_PUBLIC")
                        Text("Hyperliquid").tag("HYPERLIQUID_PUBLIC")
                    }
                    .pickerStyle(.segmented)
                    TextField("Label".localized, text: $label)
                        .textInputAutocapitalization(.words)
                    TextField("Public address".localized, text: $address, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...4)
                }
                Section {
                    Label(
                        "Only a public address is accepted. Never enter a seed phrase or private key.".localized,
                        systemImage: "lock.example_9ab66176.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Public Source".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".localized) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button((isSaving ? "Saving…" : "Add").localized) {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func save() async {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty else {
            validationMessage = "Give this source a label.".localized
            return
        }
        guard !cleanAddress.isEmpty else {
            validationMessage = "Enter the public address.".localized
            return
        }
        validationMessage = nil
        if await onSave(kind, cleanLabel, cleanAddress) {
            HapticManager.success()
            dismiss()
        } else {
            validationMessage = "That public address could not be added.".localized
        }
    }
}
