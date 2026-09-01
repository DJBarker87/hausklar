import SwiftUI

struct RenewalsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = RenewalsViewModel()
    @State private var showingNewRenewal = false
    @State private var showingLibraryConnect = false
    @State private var selectedRenewal: RenewalDTO?
    @State private var libraryAccountToDisconnect: LibraryAccountDTO?

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.renewals.isEmpty
                && viewModel.libraryOverview.accounts.isEmpty {
                ProgressView("Loading renewals...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                renewalList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Renewals")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewRenewal = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add renewal")
            }
        }
        .sheet(isPresented: $showingNewRenewal) {
            RenewalFormView(viewModel: viewModel, mode: .new)
        }
        .sheet(isPresented: $showingLibraryConnect) {
            LibraryConnectionView(viewModel: viewModel)
        }
        .sheet(item: $selectedRenewal) { renewal in
            RenewalDetailView(viewModel: viewModel, renewal: renewal)
        }
        .task {
            await viewModel.load()
            presentHighlightedRenewal()
        }
        .onChange(of: appState.highlightedRenewalResultId) { _, _ in
            presentHighlightedRenewal()
        }
        .refreshable { await viewModel.load() }
        .confirmationDialog(
            "Disconnect this library card?",
            isPresented: Binding(
                get: { libraryAccountToDisconnect != nil },
                set: { if !$0 { libraryAccountToDisconnect = nil } }
            )
        ) {
            Button("Disconnect", role: .destructive) {
                guard let account = libraryAccountToDisconnect else { return }
                Task {
                    await viewModel.disconnectLibraryAccount(account)
                    libraryAccountToDisconnect = nil
                }
            }
            Button("Cancel", role: .cancel) { libraryAccountToDisconnect = nil }
        } message: {
            Text("Its encrypted login and current loan list will be removed from HausKlar.")
        }
    }

    private var renewalList: some View {
        List {
            librarySection
            if viewModel.removedRenewal != nil {
                Section { undoBanner }
            }
            if let error = viewModel.errorMessage {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                        Spacer()
                        Button("Dismiss") { viewModel.errorMessage = nil }
                            .font(.caption)
                    }
                }
            }
            if viewModel.renewals.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(viewModel.renewals) { renewal in
                        Button {
                            selectedRenewal = renewal
                        } label: {
                            RenewalRow(renewal: renewal)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }
                } footer: {
                    Text("Open a renewal for its document, checklist and next action.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var librarySection: some View {
        Section {
            if let error = viewModel.libraryErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if viewModel.libraryOverview.accounts.isEmpty {
                Button {
                    showingLibraryConnect = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "books.vertical.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connect a your library card")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Keep physical loans and due dates together.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                ForEach(viewModel.libraryOverview.accounts) { account in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.label)
                                .font(.subheadline.weight(.semibold))
                            Text("Card ending \(account.cardLastFour) · \(account.statusLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await viewModel.syncLibraryAccount(account) }
                        } label: {
                            if viewModel.workingId == "library-sync-\(account.id)" {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(viewModel.workingId != nil)
                        .accessibilityLabel("Check \(account.label) library loans now")
                    }
                    .swipeActions {
                        Button("Disconnect", role: .destructive) {
                            libraryAccountToDisconnect = account
                        }
                    }
                    if let error = account.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if viewModel.libraryOverview.loans.isEmpty {
                    Text("No books are currently on loan.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.libraryOverview.loans) { loan in
                        LibraryLoanRow(loan: loan)
                    }
                }

                Button {
                    showingLibraryConnect = true
                } label: {
                    Label("Connect another card", systemImage: "plus")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Library books")
        } footer: {
            Text("Checked automatically from Example Town Libraries. Read-only: HausKlar never renews or changes an account automatically.")
        }
    }

    @ViewBuilder
    private var undoBanner: some View {
        if let removed = viewModel.removedRenewal {
            HStack {
                Text("\(removed.title) removed")
                    .font(.subheadline)
                Spacer()
                Button("Undo") {
                    Task { await viewModel.restoreRemoved() }
                }
                .fontWeight(.semibold)
                .disabled(viewModel.workingId != nil)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func presentHighlightedRenewal() {
        guard selectedRenewal == nil,
              let id = appState.highlightedRenewalResultId,
              let renewal = viewModel.renewals.first(where: { $0.id == id }) else { return }
        appState.highlightedRenewalResultId = nil
        selectedRenewal = renewal
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to renew yet", systemImage: "bell.badge")
        } description: {
            Text("Add a passport, MOT, insurance or membership and HausKlar will bring it back at the right time.")
        } actions: {
            Button("Add renewal") { showingNewRenewal = true }
                .buttonStyle(.borderedProminent)
        }
    }

}

private struct LibraryLoanRow: View {
    let loan: LibraryLoanDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(loan.status.color)
                    .frame(width: 34, height: 34)
                    .background(loan.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(loan.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text([loan.author, loan.accountLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(loan.dueLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(loan.status.color)
                    Text(loan.dueDateDisplay)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let renewalURL = loan.renewalURL {
                Link(destination: renewalURL) {
                    Label("Renew online", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Open the official your library account website")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }
}

private struct LibraryConnectionView: View {
    @ObservedObject var viewModel: RenewalsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var cardNumber = ""
    @State private var pin = ""
    @State private var reminderDays = 7

    private var canSubmit: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cardNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [4, 6].contains(pin.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Whose card?", text: $label)
                        .textContentType(.name)
                    TextField("Library card barcode", text: $cardNumber)
                        .keyboardType(.numberPad)
                        .textContentType(.username)
                    SecureField("Catalogue PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.password)
                        .onChange(of: pin) { _, value in
                            pin = String(value.filter(\.isNumber).prefix(6))
                        }
                    Stepper(
                        "Remind us \(reminderDays) day\(reminderDays == 1 ? "" : "s") before",
                        value: $reminderDays,
                        in: 0...30
                    )
                }
                Section {
                    Text("The barcode and PIN are encrypted on your HausKlar server and are never shown again. HausKlar only reads current physical loans and due dates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = viewModel.libraryErrorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Connect library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pin = ""
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isSaving ? "Checking…" : "Connect") {
                        let submittedPIN = pin
                        Task {
                            if await viewModel.connectLibraryAccount(
                                label: label,
                                cardNumber: cardNumber,
                                pin: submittedPIN,
                                reminderDaysBefore: reminderDays
                            ) {
                                pin = ""
                                cardNumber = ""
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSubmit || viewModel.isSaving)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .onDisappear { pin = "" }
    }
}

private struct RenewalRow: View {
    let renewal: RenewalDTO

    private var checklistProgress: String? {
        guard let checklist = renewal.checklist, !checklist.isEmpty else { return nil }
        return "\(checklist.filter { $0.checkedAt != nil }.count)/\(checklist.count) ready"
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: renewal.categoryValue.icon)
                .font(.title3)
                .foregroundStyle(renewal.status.color)
                .frame(width: 38, height: 38)
                .background(renewal.status.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(renewal.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(renewal.status.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(renewal.status.color.opacity(0.15), in: Capsule())
                        .foregroundStyle(renewal.status.color)
                }
                Text([renewal.provider, renewal.dueLabel, renewal.costDisplay, checklistProgress]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens renewal details")
    }
}

private struct RenewalDetailView: View {
    @ObservedObject var viewModel: RenewalsViewModel
    let renewal: RenewalDTO

    @Environment(\.dismiss) private var dismiss
    @State private var showingEdit = false
    @State private var decisionOutcome: String?
    @State private var checklistTitle = ""
    @State private var previewItem: DocumentPreviewItem?
    @State private var openingDocument = false
    @State private var showingDeleteConfirmation = false
    @State private var historyExpanded = false

    private var current: RenewalDTO { viewModel.current(renewal) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    usefulActions
                    checklistSection
                    if let notes = current.notes, !notes.isEmpty {
                        detailSection(title: "Notes") { Text(notes) }
                    }
                    historySection
                    projectionsSection
                    decisionButtons
                }
                .padding()
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Edit") { showingEdit = true }
                }
            }
            .sheet(isPresented: $showingEdit) {
                RenewalFormView(viewModel: viewModel, mode: .edit(current))
            }
            .sheet(item: $previewItem) { item in
                DocumentPreviewSheet(item: item)
                    .onDisappear { DocumentPreviewStore.remove(item.url) }
            }
            .sheet(item: Binding(
                get: { decisionOutcome.map { RenewalDecisionContext(outcome: $0) } },
                set: { decisionOutcome = $0?.outcome }
            )) { context in
                RenewalDecisionSheet(
                    viewModel: viewModel,
                    renewal: current,
                    outcome: context.outcome
                ) {
                    if context.outcome == "not_renewing" || current.recurrenceMonths == nil {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Remove this renewal?",
                isPresented: $showingDeleteConfirmation
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        await viewModel.delete(current)
                        if viewModel.removedRenewal?.id == current.id { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You can undo immediately from the Renewals list.")
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.dueLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(current.status.color)
                    Text(current.dueDateDisplay)
                        .font(.title2.bold())
                }
                Spacer()
                if let cost = current.costDisplay {
                    Text(cost)
                        .font(.title3.weight(.semibold))
                }
            }

            if let change = current.costChangePence, change != 0 {
                Text("\(change > 0 ? "+" : "−")\(Self.money(abs(change))) since last time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                if let provider = current.provider, !provider.isEmpty {
                    detailGridRow("Provider", provider)
                }
                if let reference = current.reference, !reference.isEmpty {
                    detailGridRow("Reference", reference)
                }
                if let owner = current.responsibleUserName {
                    detailGridRow("Handled by", owner)
                }
                if let recurrence = current.recurrenceLabel {
                    detailGridRow("Repeats", recurrence)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var usefulActions: some View {
        let hasAction = current.actionUrl != nil || current.comparisonUrl != nil
            || current.contactUrl != nil || current.sourceDocument != nil
        if hasAction {
            FlowLayout(spacing: 8) {
                if let url = SafeExternalURL.web(current.actionUrl) {
                    Link(destination: url) {
                        Label("Renew now", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let url = SafeExternalURL.web(current.comparisonUrl) {
                    Link(destination: url) {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.bordered)
                }
                if let url = SafeExternalURL.contact(current.contactUrl) {
                    Link(destination: url) {
                        Label("Contact", systemImage: "phone")
                    }
                    .buttonStyle(.bordered)
                }
                if let document = current.sourceDocument {
                    Button {
                        openDocument(document)
                    } label: {
                        if openingDocument {
                            ProgressView()
                        } else {
                            Label("Document", systemImage: "doc")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(openingDocument)
                }
            }
        }
    }

    private var checklistSection: some View {
        detailSection(title: "Before it is sorted", subtitle: "Tick these off as you go.") {
            if let checklist = current.checklist, !checklist.isEmpty {
                VStack(spacing: 2) {
                    ForEach(checklist) { item in
                        Button {
                            Task { await viewModel.toggleChecklist(item, in: current) }
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.checkedAt == nil ? "circle" : "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(item.checkedAt == nil ? Color.secondary : Color.green)
                                Text(item.title)
                                    .strikethrough(item.checkedAt != nil)
                                    .foregroundStyle(item.checkedAt == nil ? .primary : .secondary)
                                Spacer()
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.workingId != nil)
                    }
                }
            } else {
                Text("No steps yet. Add only what will make this easier next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Add a step", text: $checklistTitle)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    Task {
                        if await viewModel.addChecklist(title: checklistTitle, to: current) {
                            checklistTitle = ""
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(checklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.workingId != nil)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let history = current.history, !history.isEmpty {
            DisclosureGroup("Previous renewals", isExpanded: $historyExpanded) {
                VStack(spacing: 10) {
                    ForEach(history) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.outcome == "renewed" ? "Renewed" : "Not renewed")
                                    .font(.subheadline.weight(.medium))
                                Text(Self.displayDate(item.dueDate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let cost = item.costPence {
                                Text(Self.money(cost))
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
            .padding(15)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var projectionsSection: some View {
        if current.showInCalendar == true || current.showInTasks == true || current.financeCommitmentId != nil {
            FlowLayout(spacing: 7) {
                if current.showInCalendar == true { Label("Calendar", systemImage: "calendar") }
                if current.showInTasks == true { Label("Tasks", systemImage: "checkmark.circle") }
                if current.financeCommitmentId != nil { Label("Household Finance", systemImage: "sterlingsign.circle") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var decisionButtons: some View {
        VStack(spacing: 9) {
            Button {
                decisionOutcome = "renewed"
            } label: {
                Label("It’s renewed", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button("Not renewing") { decisionOutcome = "not_renewing" }
                .buttonStyle(.bordered)

            Button("Remove this record", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .font(.caption)
            .padding(.top, 4)
        }
    }

    private func detailSection<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(15)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func detailGridRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private func openDocument(_ document: SourceDocumentDTO) {
        openingDocument = true
        Task {
            defer { openingDocument = false }
            do {
                let url = try await DocumentPreviewStore.download(document)
                previewItem = DocumentPreviewItem(url: url, title: document.title)
            } catch {
                viewModel.errorMessage = "The renewal document could not be opened."
            }
        }
    }

    private static func money(_ pence: Int) -> String {
        String(format: "£%.2f", Double(pence) / 100)
    }

    private static func displayDate(_ value: String) -> String {
        guard let date = ISODateParser.parse(value) else { return value }
        return ISODateParser.dateOnly(from: date)
    }
}

private struct RenewalDecisionContext: Identifiable {
    let outcome: String
    var id: String { outcome }
}

private struct RenewalDecisionSheet: View {
    @ObservedObject var viewModel: RenewalsViewModel
    let renewal: RenewalDTO
    let outcome: String
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var costPounds: String
    @State private var nextDueDate: Date
    @State private var notes = ""

    init(
        viewModel: RenewalsViewModel,
        renewal: RenewalDTO,
        outcome: String,
        onFinished: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.renewal = renewal
        self.outcome = outcome
        self.onFinished = onFinished
        _costPounds = State(initialValue: renewal.costPence.map { String(format: "%.2f", Double($0) / 100) } ?? "")
        let currentDue = ISODateParser.parse(renewal.dueDate) ?? Date()
        _nextDueDate = State(initialValue: Calendar.current.date(
            byAdding: .month,
            value: renewal.recurrenceMonths ?? 12,
            to: currentDue
        ) ?? currentDue)
    }

    var body: some View {
        NavigationStack {
            Form {
                if outcome == "renewed" {
                    Section("What happened?") {
                        HStack {
                            Text("£").foregroundStyle(.secondary)
                            TextField("Price paid", text: $costPounds)
                                .keyboardType(.decimalPad)
                        }
                        if renewal.recurrenceMonths != nil {
                            DatePicker("Next due", selection: $nextDueDate, displayedComponents: .date)
                        }
                    }
                } else {
                    Section {
                        Text("This removes it from upcoming renewals. You can undo straight afterwards.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Note") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle(outcome == "renewed" ? "Finish Renewal" : "Not Renewing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(outcome == "renewed" ? "Save" : "Confirm", role: outcome == "renewed" ? nil : .destructive) {
                        Task {
                            let succeeded = await viewModel.decide(
                                renewal,
                                outcome: outcome,
                                nextDueDate: outcome == "renewed" && renewal.recurrenceMonths != nil ? nextDueDate : nil,
                                costPence: costPence,
                                notes: notes
                            )
                            if succeeded {
                                dismiss()
                                onFinished()
                            }
                        }
                    }
                    .disabled(viewModel.workingId != nil)
                }
            }
        }
    }

    private var costPence: Int? {
        let value = costPounds.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !value.isEmpty, let pounds = Double(value), pounds >= 0 else { return nil }
        return Int((pounds * 100).rounded())
    }
}

#Preview {
    NavigationStack { RenewalsView() }
}
