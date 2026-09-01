import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum FinanceActivityPresentation {
    case activity
    case management
}

extension FinanceTransactionDTO {
    var activityClassificationDisplayName: String {
        guard !splits.isEmpty else { return classificationDisplayName }
        let categories = Set(splits.map { split in
            let categoryId = split.categoryId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let categoryId, !categoryId.isEmpty {
                return "category:\(categoryId)"
            }
            return "uncategorised"
        })
        if categories.count == 1 {
            return "Split · 1 category".localized
        }
        return String(
            format: "Split · %lld categories".localized,
            Int64(categories.count)
        )
    }

    var activityClassificationSpendingType: String? {
        splits.isEmpty ? primarySpendingType : nil
    }
}

struct FinanceActivityView: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel: FinanceActivityViewModel
    @State private var manualAccountSpace: FinanceSpaceDTO?
    @State private var receiptSpace: FinanceSpaceDTO?
    private let entryAction: TodayFinanceActionDTO?
    private let presentation: FinanceActivityPresentation

    init(
        initialScope: FinanceActivityScope = .mine,
        entryAction: TodayFinanceActionDTO? = nil,
        presentation: FinanceActivityPresentation = .activity
    ) {
        self.entryAction = entryAction
        self.presentation = presentation
        _viewModel = StateObject(
            wrappedValue: FinanceActivityViewModel(
                initialScope: initialScope,
                loadMode: presentation == .activity ? .activity : .management
            )
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if presentation == .management {
                    presentationExplanation
                }
                entryActionCard

                if viewModel.isInitialLoading && viewModel.snapshots.isEmpty {
                    loadingState
                } else if viewModel.snapshots.isEmpty {
                    emptyOrErrorState
                } else {
                    if let error = viewModel.errorMessage {
                        errorCard(error)
                    }
                    ForEach(viewModel.snapshots) { snapshot in
                        spaceSection(snapshot)
                    }
                    if presentation == .management {
                        detailedFinanceButton
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
            guard connected, viewModel.snapshots.isEmpty else { return }
            Task { await viewModel.load(forceRefresh: true) }
        }
        .toolbar {
            if viewModel.isLoading && !viewModel.isInitialLoading {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                        .accessibilityLabel("Updating Finance activity")
                }
            }
        }
        .sheet(item: $manualAccountSpace) { space in
            FinanceManualAccountSheet(space: space) {
                manualAccountSpace = nil
                await viewModel.load(forceRefresh: true)
            }
        }
        .sheet(item: $receiptSpace) { space in
            FinanceReceiptUploadSheet(space: space) {
                receiptSpace = nil
                await viewModel.load(forceRefresh: true)
            }
        }
    }

    @ViewBuilder
    private var entryActionCard: some View {
        if presentation == .management,
           let action = entryAction,
           action.spaceKind == "HOUSEHOLD" || viewModel.scope == .mine {
            VStack(alignment: .leading, spacing: 10) {
                Label("From Today", systemImage: "calendar.badge.clock")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(action.title ?? entryActionTitle(action))
                    .font(.headline)

                if action.kind == "PURCHASE_REVIEW", let purchaseId = action.purchaseId {
                    NavigationLink {
                        FinancePurchaseDetailView(
                            purchaseId: purchaseId,
                            scope: action.spaceKind == "HOUSEHOLD" ? .household : .mine
                        )
                    } label: {
                        Label("Review this purchase", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                } else if let destination = action.financeWebURL {
                    FinanceWebHandoffButton(destination: destination) {
                        Label("Continue this action in the browser", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(Color.accentColor.opacity(0.1), in: cardShape)
            .overlay { cardShape.stroke(Color.accentColor.opacity(0.3), lineWidth: 1) }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text((presentation == .activity ? "Loading activity…" : "Loading Finance tools…").localized)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .accessibilityElement(children: .combine)
    }

    private var presentationExplanation: some View {
        Label {
            Text(presentationExplanationText)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: presentation == .activity ? "tag.fill" : "slider.horizontal.3")
                .foregroundStyle(.tint)
        }
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .accessibilityElement(children: .combine)
    }

    private var presentationExplanationText: String {
        "Accounts, receipts and purchase review live here, away from the everyday view.".localized
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if let error = viewModel.errorMessage {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await viewModel.load(forceRefresh: true) }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .padding(24)
        } else {
            VStack(spacing: 14) {
                Image(systemName: presentation == .activity ? "list.bullet.rectangle" : "slider.horizontal.3")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text((presentation == .activity ? "No activity yet" : "No Finance records yet").localized)
                    .font(.title3.weight(.bold))
                Text((presentation == .activity
                    ? "Classified transactions will appear here."
                    : "Connect a bank or add an account to get started.").localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if presentation == .management {
                    detailedFinanceButton
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .padding(24)
        }
    }

    private func spaceSection(_ snapshot: FinanceActivitySpaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                snapshot.space.kind.lowercased() == "personal"
                    ? snapshot.space.name
                    : snapshot.space.name,
                systemImage: snapshot.space.kind.lowercased() == "personal"
                    ? "person.example_e864bc8d" : "house.fill"
            )
            .font(.title3.weight(.bold))
            .accessibilityAddTraits(.isHeader)

            if presentation == .activity {
                transactionsSection(snapshot)
            } else {
                Button {
                    receiptSpace = snapshot.space
                } label: {
                    Label("Upload a receipt", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Keeps the file inside this private Finance space")

                accountsSection(snapshot)
                purchaseReviewSection(snapshot)
                purchasesSection(snapshot)
            }
        }
    }

    private func accountsSection(_ snapshot: FinanceActivitySpaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Accounts", icon: "building.columns")
            if snapshot.accounts.isEmpty {
                emptyLine("No accounts in this space.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(snapshot.accounts) { account in
                            accountCard(account)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            if snapshot.space.id == viewModel.bankConnectionSpaceId {
                bankConnectionActions(space: snapshot.space)
            }
        }
    }

    private func bankConnectionActions(space: FinanceSpaceDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.bankConnections) { connection in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.institution)
                            .font(.subheadline.weight(.semibold))
                        Text(connection.isHistoricalReadOnly
                            ? connection.statusLabel
                            : connection.provider == "TRUELAYER"
                                ? connection.statusLabel
                                : "Managed in browser".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if connection.canReconnectInApp {
                        bankConnectionButton(
                            title: "Reconnect".localized,
                            space: space,
                            connectionId: connection.id,
                            prominent: true
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }

            if viewModel.bankConnectionsUnavailable {
                HStack(spacing: 8) {
                    Text("Couldn’t check the bank connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Try again") {
                        Task { await viewModel.retryBankConnections(spaceId: space.id) }
                    }
                    .disabled(viewModel.isLoadingBankConnections || !networkMonitor.isConnected)
                }
                .frame(minHeight: 44)
            } else if !viewModel.bankConnections.contains(where: \.canReconnectInApp) {
                bankConnectionButton(
                    title: viewModel.bankConnections.isEmpty
                        ? "Connect a bank".localized
                        : "Connect another bank".localized,
                    space: space,
                    connectionId: nil,
                    prominent: viewModel.bankConnections.isEmpty
                )
            }

            if let message = viewModel.bankConnectionMessage {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isStaticText)
            }

            Button {
                manualAccountSpace = space
            } label: {
                Label("Add an account manually", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!networkMonitor.isConnected)
            .accessibilityHint("Adds an account to \(space.name) without leaving the app")
        }
        .padding(.top, 2)
    }

    private func accountCard(_ account: FinanceAccountSummaryDTO) -> some View {
        let tint = account.accountType == "CREDIT_CARD" ? Color.indigo : Color.accentColor

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: account.accountType == "CREDIT_CARD" ? "creditcard.fill" : "building.columns.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(tint, in: Circle())
                Spacer(minLength: 8)
                if account.primarySpendingAccount {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Main spending account")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(account.label)
                    .font(.headline)
                    .lineLimit(1)
                Text(accountSubtitle(account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let balance = account.balance {
                Text(money(balance.availableMinor ?? balance.bookedMinor, currency: account.currency))
                    .font(.title2.weight(.bold).monospacedDigit())
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
            } else {
                Text("No balance")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 220, alignment: .leading)
        .frame(minHeight: 158, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .overlay { cardShape.stroke(tint.opacity(0.18), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func bankConnectionButton(
        title: String,
        space: FinanceSpaceDTO,
        connectionId: String?,
        prominent: Bool
    ) -> some View {
        if prominent {
            bankConnectionButtonControl(
                title: title,
                space: space,
                connectionId: connectionId
            )
            .buttonStyle(.borderedProminent)
        } else {
            bankConnectionButtonControl(
                title: title,
                space: space,
                connectionId: connectionId
            )
            .buttonStyle(.bordered)
        }
    }

    private func bankConnectionButtonControl(
        title: String,
        space: FinanceSpaceDTO,
        connectionId: String?
    ) -> some View {
        Button {
            HapticManager.selection()
            Task {
                await viewModel.connectBank(
                    spaceId: space.id,
                    connectionId: connectionId
                )
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isConnectingBank {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "building.columns.fill")
                }
                Text(viewModel.isConnectingBank ? "Opening bank list…".localized : title)
            }
            .frame(maxWidth: connectionId == nil ? .infinity : nil, minHeight: 44)
        }
        .disabled(
            viewModel.isConnectingBank
                || viewModel.isLoading
                || viewModel.isLoadingBankConnections
                || !networkMonitor.isConnected
        )
        .accessibilityHint(connectionId == nil
            ? "Opens your bank’s secure sign-in window"
            : "Signs in to this bank again")
    }

    private func accountRow(_ account: FinanceAccountSummaryDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.accountType == "CREDIT_CARD" ? "creditcard.fill" : "banknote.fill")
                .frame(width: 24)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.label)
                    .font(.subheadline.weight(.semibold))
                Text(accountSubtitle(account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let balance = account.balance {
                Text(money(balance.availableMinor ?? balance.bookedMinor, currency: account.currency))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
            } else {
                Text("No balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func purchaseReviewSection(_ snapshot: FinanceActivitySpaceSnapshot) -> some View {
        Group {
            if !snapshot.purchaseInbox.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("To review", icon: "doc.text.magnifyingglass")
                ForEach(snapshot.purchaseInbox) { item in
                    purchaseInboxRow(item, space: snapshot.space)
                    if item.id != snapshot.purchaseInbox.last?.id { Divider() }
                }
                }
                .padding(16)
                .background(Color.orange.opacity(0.1), in: cardShape)
            }
        }
    }

    @ViewBuilder
    private func purchaseInboxRow(
        _ item: FinancePurchaseEvidenceInboxItemDTO,
        space: FinanceSpaceDTO
    ) -> some View {
        if let purchaseId = item.purchaseId {
            NavigationLink {
                FinancePurchaseDetailView(
                    purchaseId: purchaseId,
                    scope: space.kind.lowercased() == "household" ? .household : .mine
                )
            } label: {
                purchaseInboxLabel(item)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Review the extracted purchase lines")
        } else if let destination = evidenceWebURL(item, space: space) {
            FinanceWebHandoffButton(destination: destination) {
                purchaseInboxLabel(item)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Continue this evidence review in the browser")
        } else {
            purchaseInboxLabel(item)
        }
    }

    private func purchaseInboxLabel(_ item: FinancePurchaseEvidenceInboxItemDTO) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            if let amount = item.amountMinor, let currency = item.currency {
                Text(money(amount, currency: currency))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func transactionsSection(_ snapshot: FinanceActivitySpaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Recent", icon: "list.bullet.rectangle")
            if snapshot.transactions.isEmpty {
                emptyLine("No recent activity.")
            } else {
                ForEach(snapshot.transactions) { transaction in
                    transactionRow(transaction, accounts: snapshot.accounts)
                    if transaction.id != snapshot.transactions.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
    }

    private func transactionRow(
        _ transaction: FinanceTransactionDTO,
        accounts: [FinanceAccountSummaryDTO]
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: transaction.amountMinor < 0 ? "arrow.up.right" : "arrow.down.left")
                .font(.caption.weight(.bold))
                .foregroundStyle(transaction.amountMinor < 0 ? Color.orange : Color.green)
                .frame(width: 32, height: 32)
                .background(
                    (transaction.amountMinor < 0 ? Color.orange : Color.green).opacity(0.12),
                    in: Circle()
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantText ?? transaction.description)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                let account = accounts.first { $0.id == transaction.accountId }?.label
                Text([dateText(transaction.canonicalDate), account, transactionStatus(transaction)]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if transaction.amountMinor < 0, !isTransfer(transaction) {
                    HStack(spacing: 5) {
                        Image(systemName: "tag.fill")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(transaction.activityClassificationDisplayName)
                        if let type = transaction.activityClassificationSpendingType,
                           !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           type.uppercased() != "UNCATEGORISED" {
                            Text("·")
                                .accessibilityHidden(true)
                            Text(spendingTypeName(type))
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Classification, \(transaction.activityClassificationDisplayName)"
                    )
                }
            }
            Spacer(minLength: 8)
            Text(money(transaction.amountMinor, currency: transaction.currency))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(transaction.amountMinor < 0 ? Color.primary : Color.green)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func purchasesSection(_ snapshot: FinanceActivitySpaceSnapshot) -> some View {
        Group {
            if !snapshot.purchases.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                ForEach(snapshot.purchases) { purchase in
                    NavigationLink {
                        FinancePurchaseDetailView(
                            purchaseId: purchase.id,
                            scope: snapshot.space.kind.lowercased() == "household" ? .household : .mine
                        )
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(purchase.merchant)
                                    .font(.subheadline.weight(.semibold))
                                Text(purchaseDescription(purchase))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Text(money(purchase.behaviouralNetMinor, currency: purchase.currency))
                                .font(.subheadline.weight(.bold).monospacedDigit())
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Review the item lines from the receipt")
                    if purchase.id != snapshot.purchases.last?.id { Divider() }
                }
                    }
                    .padding(.top, 12)
                } label: {
                    Label("Receipts", systemImage: "bag.fill")
                        .font(.headline)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: cardShape)
            }
        }
    }

    @ViewBuilder
    private var detailedFinanceButton: some View {
        if let destination = FinanceWebRouter.configured()?.url(
            section: "more",
            scope: viewModel.scope.webScope,
            mode: "full"
        ) {
            FinanceWebHandoffButton(destination: destination) {
                Label("Open detailed Finance in the browser", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens the website for more filters and editing tools")
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
            Spacer(minLength: 0)
            Button("Retry") {
                Task { await viewModel.load(forceRefresh: true) }
            }
            .frame(minHeight: 44)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title.localized, systemImage: icon)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text.localized)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private func evidenceWebURL(
        _ item: FinancePurchaseEvidenceInboxItemDTO,
        space: FinanceSpaceDTO
    ) -> URL? {
        let scope: FinanceWebScope = space.kind.lowercased() == "household" ? .household : .mine
        return FinanceWebRouter.configured()?.url(
            section: "more",
            scope: scope,
            recordQueryItems: [URLQueryItem(name: "evidence", value: item.sourceId)]
        )
    }

    private func accountSubtitle(_ account: FinanceAccountSummaryDTO) -> String {
        var values = [account.institution, account.lastFour.map { "•••• \($0)" }]
            .compactMap { $0 }
        if values.isEmpty {
            values.append(account.accountType.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        return values.joined(separator: " · ")
    }

    private func isTransfer(_ transaction: FinanceTransactionDTO) -> Bool {
        transaction.isConfirmedNeutralMovement
    }

    private func transactionStatus(_ transaction: FinanceTransactionDTO) -> String? {
        if isTransfer(transaction) { return "Transfer".localized }
        if transaction.state == "PENDING" { return "Pending".localized }
        return nil
    }

    private func spendingTypeName(_ value: String) -> String {
        switch value.uppercased() {
        case "FIXED": "Fixed".localized
        case "FLEXIBLE": "Flexible".localized
        case "DISCRETIONARY": "Discretionary".localized
        default: "Uncategorised".localized
        }
    }

    private func purchaseDescription(_ purchase: FinancePurchaseRecordDTO) -> String {
        let items = purchase.itemDescriptions.prefix(2).joined(separator: ", ")
        let date = dateText(purchase.purchasedOn)
        return items.isEmpty ? date : "\(date) · \(items)"
    }

    private func entryActionTitle(_ action: TodayFinanceActionDTO) -> String {
        switch action.kind {
        case "PURCHASE_REVIEW": "Review the selected purchase".localized
        case "PAYDAY_TRANSFER": "Review this month’s savings transfer".localized
        default: "Review the current Finance action".localized
        }
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
}

private struct FinanceManualAccountRequest: Encodable {
    let label: String
    let institution: String?
    let accountType: String
    let currency: String
    let lastFour: String?
    let includeInCashflow: Bool
    let includeInNetWorth: Bool
    let minimumBalanceMinor: Int
    let currentBalanceMinor: Int
    let balanceObservedAt: String
}

private struct FinanceManualAccountSheet: View {
    @Environment(\.dismiss) private var dismiss

    let space: FinanceSpaceDTO
    let onSaved: () async -> Void

    @State private var label = ""
    @State private var institution = ""
    @State private var accountType = "CURRENT"
    @State private var currency = "GBP"
    @State private var lastFour = ""
    @State private var balance = ""
    @State private var minimumBalance = "0"
    @State private var includeInCashflow = true
    @State private var includeInNetWorth = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(space.name, systemImage: space.kind.lowercased() == "household" ? "house.fill" : "lock.example_c6e20e62")
                    Text((space.kind.lowercased() == "household"
                        ? "Both adults can see this account."
                        : "Only you can see this account unless you deliberately share it.").localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Account") {
                    TextField("Name", text: $label)
                    TextField("Bank or provider (optional)", text: $institution)
                    Picker("Type", selection: $accountType) {
                        Text("Current account").tag("CURRENT")
                        Text("Savings").tag("SAVINGS")
                        Text("Credit card").tag("CREDIT_CARD")
                        Text("Cash").tag("CASH")
                        Text("Investment").tag("INVESTMENT")
                        Text("Crypto").tag("CRYPTO")
                    }
                    TextField("Currency", text: $currency)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Last four digits (optional)", text: $lastFour)
                        .keyboardType(.numberPad)
                }

                Section("Starting figures") {
                    TextField("Current balance", text: $balance)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Keep untouched", text: $minimumBalance)
                        .keyboardType(.decimalPad)
                    Toggle("Include in cash flow", isOn: $includeInCashflow)
                    Toggle("Include in net worth", isOn: $includeInNetWorth)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button((isSaving ? "Adding…" : "Add").localized) {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func save() async {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanLastFour = lastFour.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty else {
            errorMessage = "Give this account a name.".localized
            return
        }
        guard cleanCurrency.count == 3 else {
            errorMessage = "Use a three-letter currency code such as GBP.".localized
            return
        }
        guard cleanLastFour.isEmpty || (cleanLastFour.count == 4 && cleanLastFour.allSatisfy(\.isNumber)) else {
            errorMessage = "The last four digits must contain exactly four numbers.".localized
            return
        }
        guard let balanceMinor = Self.signedMinorUnits(balance) else {
            errorMessage = "Enter the current balance with no more than two decimal places.".localized
            return
        }
        guard let floorMinor = Self.signedMinorUnits(minimumBalance), floorMinor >= 0 else {
            errorMessage = "The untouched amount must be zero or more.".localized
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let request = FinanceManualAccountRequest(
                label: cleanLabel,
                institution: Self.clean(institution),
                accountType: accountType,
                currency: cleanCurrency,
                lastFour: cleanLastFour.isEmpty ? nil : cleanLastFour,
                includeInCashflow: includeInCashflow,
                includeInNetWorth: includeInNetWorth,
                minimumBalanceMinor: floorMinor,
                currentBalanceMinor: balanceMinor,
                balanceObservedAt: ISO8601DateFormatter().string(from: Date())
            )
            let _: FinanceAccountSummaryDTO = try await APIClient.shared.post(
                "/finance/accounts",
                body: request,
                queryItems: [URLQueryItem(name: "space_id", value: space.id)]
            )
            await onSaved()
            HapticManager.success()
            dismiss()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription
                ?? "That account could not be added. Try again.".localized
            HapticManager.error()
        }
    }

    private static func signedMinorUnits(_ value: String) -> Int? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: clean) else { return nil }
        let number = NSDecimalNumber(decimal: decimal * 100)
        guard number != .notANumber else { return nil }
        let rounded = number.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        ))
        guard rounded == number else { return nil }
        return rounded.intValue
    }

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct FinanceEvidenceUploadResponseDTO: Decodable {
    let source: FinancePurchaseEvidenceSummaryDTO
    let purchase: FinancePurchaseRecordDTO?
    let exception: FinancePurchaseEvidenceInboxItemDTO?
    let duplicate: Bool
}

private struct FinanceReceiptUploadSheet: View {
    @Environment(\.dismiss) private var dismiss

    let space: FinanceSpaceDTO
    let onSaved: () async -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var fileURL: URL?
    @State private var showingImporter = false
    @State private var isUploading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(space.name, systemImage: space.kind.lowercased() == "household" ? "house.fill" : "lock.example_c6e20e62")
                    Text((space.kind.lowercased() == "household"
                        ? "This receipt will be visible to both adults."
                        : "This receipt stays in your private Finance records.").localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Receipt") {
                    Button {
                        showingImporter = true
                    } label: {
                        Label(fileURL?.lastPathComponent ?? "Choose a photo or PDF".localized, systemImage: fileURL == nil ? "doc.badge.plus" : "doc.fill")
                            .frame(minHeight: 44)
                    }
                    TextField("What is this receipt for?", text: $title)
                    TextField("Note (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Text("HausKlar stores this in the selected adult Finance space, not the family Documents library. It will appear in review so no extracted facts are silently trusted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Upload Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button((isUploading ? "Uploading…" : "Upload").localized) {
                        Task { await upload() }
                    }
                    .disabled(isUploading || fileURL == nil)
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    fileURL = urls.first
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = urls.first?.deletingPathExtension().lastPathComponent ?? "Receipt".localized
                    }
                    errorMessage = nil
                case .failure:
                    errorMessage = "That file could not be opened.".localized
                }
            }
        }
    }

    private func upload() async {
        guard let fileURL else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            errorMessage = "Add a short title for this receipt.".localized
            return
        }
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        do {
            let contentType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let _: FinanceEvidenceUploadResponseDTO = try await APIClient.shared.uploadMultipart(
                "/finance/purchases/evidence/upload",
                fileURL: fileURL,
                filename: fileURL.lastPathComponent,
                mediaType: contentType,
                fields: [
                    "title": cleanTitle,
                    "notes": notes.trimmingCharacters(in: .whitespacesAndNewlines),
                ],
                queryItems: [URLQueryItem(name: "space_id", value: space.id)]
            )
            await onSaved()
            HapticManager.success()
            dismiss()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription
                ?? "That receipt could not be uploaded. Try again.".localized
            HapticManager.error()
        }
    }
}

private struct FinancePurchaseCorrectionLinePayload: Encodable {
    let lineReference: String
    let description: String
    let quantity: String
    let kind: String
    let netMinor: Int?
}

private struct FinancePurchaseCorrectionPayload: Encodable {
    let sourceId: String
    let purchaseReference: String
    let orderReference: String?
    let merchant: String
    let purchasedAt: String
    let currency: String
    let lines: [FinancePurchaseCorrectionLinePayload]
    let finalTotalMinor: Int
}

private struct FinancePurchaseCorrectionRequest: Encodable {
    let externalSourceId: String
    let adapter = "natural_language"
    let reviewed = true
    let payload: FinancePurchaseCorrectionPayload
    let correctsSourceId: String
}

private struct FinanceEditablePurchaseLine: Identifiable {
    let id: String
    let lineReference: String
    let quantity: String
    let kind: String
    var description: String
    var amount: String
}

private struct FinancePurchaseCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let purchase: FinancePurchaseRecordDTO
    let onSaved: () async -> Void

    @State private var merchant: String
    @State private var purchasedOn: Date
    @State private var total: String
    @State private var lines: [FinanceEditablePurchaseLine]
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        purchase: FinancePurchaseRecordDTO,
        onSaved: @escaping () async -> Void
    ) {
        self.purchase = purchase
        self.onSaved = onSaved
        _merchant = State(initialValue: purchase.merchant)
        _purchasedOn = State(initialValue: ISODateParser.parse(purchase.purchasedOn) ?? Date())
        _total = State(initialValue: Self.decimalText(purchase.finalTotalMinor))
        _lines = State(initialValue: (purchase.lines ?? []).map {
            FinanceEditablePurchaseLine(
                id: $0.id,
                lineReference: $0.lineRef,
                quantity: $0.quantityDecimal,
                kind: $0.lineKind,
                description: $0.rawDescription,
                amount: Self.decimalText($0.lineNetMinor)
            )
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Purchase") {
                    TextField("Merchant", text: $merchant)
                    DatePicker("Date", selection: $purchasedOn, displayedComponents: .date)
                    HStack {
                        Text(purchase.currency)
                            .foregroundStyle(.secondary)
                        TextField("Total", text: $total)
                            .keyboardType(.decimalPad)
                    }
                }

                if !lines.isEmpty {
                    Section("Items") {
                        ForEach($lines) { $line in
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Description", text: $line.description)
                                HStack {
                                    Text(purchase.currency)
                                        .foregroundStyle(.secondary)
                                    TextField("Amount", text: $line.amount)
                                        .keyboardType(.decimalPad)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    Text("Saving creates a reviewed replacement and keeps the original evidence in the audit trail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Correct Purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
        let cleanMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMerchant.isEmpty else {
            errorMessage = "Enter the merchant name.".localized
            return
        }
        guard let totalMinor = Self.minorUnits(total), totalMinor >= 0 else {
            errorMessage = "Enter a valid total with no more than two decimal places.".localized
            return
        }
        var payloadLines: [FinancePurchaseCorrectionLinePayload] = []
        var knownLineTotal = 0
        for line in lines {
            let description = line.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else {
                errorMessage = "Every saved item needs a description.".localized
                return
            }
            let amount = line.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : Self.minorUnits(line.amount)
            guard line.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || amount != nil else {
                errorMessage = "Check the item amounts.".localized
                return
            }
            knownLineTotal += amount ?? 0
            payloadLines.append(FinancePurchaseCorrectionLinePayload(
                lineReference: line.lineReference,
                description: description,
                quantity: line.quantity,
                kind: line.kind,
                netMinor: amount
            ))
        }
        guard knownLineTotal <= totalMinor else {
            errorMessage = "The item amounts cannot be more than the purchase total.".localized
            return
        }
        guard let evidenceId = purchase.evidence?.id else {
            errorMessage = "The original evidence is not available for correction.".localized
            return
        }

        let sourceId = UUID().uuidString.lowercased()
        let request = FinancePurchaseCorrectionRequest(
            externalSourceId: sourceId,
            payload: FinancePurchaseCorrectionPayload(
                sourceId: sourceId,
                purchaseReference: "correction-\(purchase.id)",
                orderReference: purchase.orderReference,
                merchant: cleanMerchant,
                purchasedAt: Self.dateText(purchasedOn),
                currency: purchase.currency,
                lines: payloadLines,
                finalTotalMinor: totalMinor
            ),
            correctsSourceId: evidenceId
        )
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let _: FinanceEvidenceUploadResponseDTO = try await APIClient.shared.post(
                "/finance/purchases/evidence",
                body: request,
                queryItems: [URLQueryItem(name: "space_id", value: purchase.spaceId)]
            )
            await onSaved()
            HapticManager.success()
            dismiss()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription
                ?? "Those corrections could not be saved. Try again.".localized
            HapticManager.error()
        }
    }

    private static func minorUnits(_ value: String) -> Int? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: clean), decimal >= 0 else { return nil }
        let number = NSDecimalNumber(decimal: decimal * 100)
        let rounded = number.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        ))
        guard number != .notANumber, rounded == number else { return nil }
        return rounded.intValue
    }

    private static func decimalText(_ minor: Int?) -> String {
        guard let minor else { return "" }
        return String(format: "%.2f", Double(minor) / 100)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct FinancePurchaseDetailView: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel: FinancePurchaseDetailViewModel
    @State private var showingCorrection = false
    private let scope: FinanceWebScope

    init(purchaseId: String, scope: FinanceWebScope) {
        self.scope = scope
        _viewModel = StateObject(
            wrappedValue: FinancePurchaseDetailViewModel(purchaseId: purchaseId)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.isLoading && viewModel.purchase == nil {
                    ProgressView("Loading purchase evidence…")
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else if let purchase = viewModel.purchase {
                    purchaseContent(purchase)
                } else {
                    purchaseErrorState
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Purchase evidence")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.load(forceRefresh: true)
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: networkMonitor.isConnected) { _, connected in
            guard connected, viewModel.purchase == nil else { return }
            Task { await viewModel.load(forceRefresh: true) }
        }
        .sheet(isPresented: $showingCorrection) {
            if let purchase = viewModel.purchase {
                FinancePurchaseCorrectionSheet(purchase: purchase) {
                    showingCorrection = false
                    await viewModel.load(forceRefresh: true)
                }
            }
        }
    }

    private func purchaseContent(_ purchase: FinancePurchaseRecordDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(purchase.merchant)
                    .font(.title2.weight(.bold))
                Text(dateText(purchase.purchasedOn))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text("Purchase total")
                    Spacer()
                    Text(money(purchase.finalTotalMinor, currency: purchase.currency))
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                if purchase.refundedMinor != 0 {
                    LabeledContent(
                        "Refunded",
                        value: money(purchase.refundedMinor, currency: purchase.currency)
                    )
                }
                LabeledContent("Payment match", value: matchLabel(purchase.matchStatus))
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape)

            if let evidence = purchase.evidence {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Source evidence", systemImage: "doc.text.fill")
                        .font(.headline)
                    LabeledContent("Source", value: sourceLabel(evidence.sourceKind))
                    LabeledContent("Extraction", value: extractionLabel(evidence.extractionStatus))
                    if let confidence = evidence.confidenceBps {
                        LabeledContent("Reading confidence", value: "\(confidence / 100)%")
                    }
                    LabeledContent("Received", value: dateText(evidence.receivedAt))
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: cardShape)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Items found in the evidence", systemImage: "list.bullet")
                    .font(.headline)
                if let lines = purchase.lines, !lines.isEmpty {
                    let orderedLines = lines.sorted { $0.position < $1.position }
                    ForEach(orderedLines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.rawDescription)
                                    .font(.subheadline.weight(.semibold))
                                Text(lineEvidenceLabel(line.evidenceStatus))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if line.quantityDecimal != "1" {
                                    Text("Quantity \(line.quantityDecimal)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if let net = line.lineNetMinor {
                                Text(money(net, currency: purchase.currency))
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                            }
                        }
                        .accessibilityElement(children: .combine)
                        if line.id != orderedLines.last?.id { Divider() }
                    }
                } else {
                    Text("No item lines have been extracted yet. HausKlar will not guess what was bought from the merchant name alone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: cardShape)

            if purchase.refundedMinor == 0 {
                Button {
                    showingCorrection = true
                } label: {
                    Label("Correct purchase details", systemImage: "pencil")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!networkMonitor.isConnected)
            }

            if (purchase.matchStatus != "MATCHED" || purchase.refundedMinor != 0),
               let destination = purchaseWebURL(purchase) {
                FinanceWebHandoffButton(destination: destination) {
                    Label("Advanced payment matching", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var purchaseErrorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(viewModel.errorMessage ?? "This purchase could not be loaded.".localized)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await viewModel.load(forceRefresh: true) }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private func purchaseWebURL(_ purchase: FinancePurchaseRecordDTO) -> URL? {
        FinanceWebRouter.configured()?.url(
            section: "more",
            scope: scope,
            recordQueryItems: [URLQueryItem(name: "purchase", value: purchase.id)]
        )
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "amazon_email": "Amazon email".localized
        case "tesco_batch": "Tesco order data".localized
        case "e_receipt": "Email receipt".localized
        case "service_invoice": "Service invoice".localized
        case "pdf": "PDF".localized
        case "image": "Photo or image".localized
        case "html": "Web receipt".localized
        case "natural_language": "Your description".localized
        default: source.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func extractionLabel(_ status: String) -> String {
        switch status {
        case "PARSED": "Parsed".localized
        case "QUARANTINED": "Quarantined".localized
        default: "Unsupported".localized
        }
    }

    private func matchLabel(_ status: String) -> String {
        switch status {
        case "MATCHED": "Matched".localized
        case "PARTIAL": "Partly matched".localized
        default: "Not matched".localized
        }
    }

    private func lineEvidenceLabel(_ status: String) -> String {
        switch status {
        case "observed_structured": "Read from structured order data".localized
        case "observed_document": "Read from the receipt or invoice".localized
        case "user_confirmed": "Confirmed by you".localized
        case "unitemised": "Not yet itemised".localized
        default: "Inferred — check before relying on it".localized
        }
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
}
