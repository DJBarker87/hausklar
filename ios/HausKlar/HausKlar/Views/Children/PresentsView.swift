import SwiftUI

struct PresentsView: View {
    @StateObject private var viewModel: PresentsViewModel
    @State private var quickTitle = ""

    init(initialChildId: String? = nil, initialIdeaId: String? = nil) {
        _viewModel = StateObject(
            wrappedValue: PresentsViewModel(
                initialChildId: initialChildId,
                initialIdeaId: initialIdeaId
            )
        )
    }

    var body: some View {
        List {
            recipientPicker

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .swipeActions {
                            Button("Dismiss") { viewModel.clearError() }
                        }
                }
            }

            Section {
                HStack(spacing: 10) {
                    TextField("Gift idea", text: $quickTitle)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(addQuickIdea)
                    Button(action: addQuickIdea) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add gift idea")
                }
            } header: {
                Text("Quick capture")
            } footer: {
                Text("Capture the thought now. Owner, price and delivery details can wait.")
            }

            if viewModel.isLoading && viewModel.ideas.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading gifts…")
                        Spacer()
                    }
                }
            } else if viewModel.visibleIdeas.isEmpty {
                Section {
                    ContentUnavailableView(
                        viewModel.showGiven ? "No gifts yet" : "No active gifts",
                        systemImage: "gift",
                        description: Text("Add the next idea before it disappears.")
                    )
                }
            } else {
                ForEach(PresentLifecycle.allCases) { lifecycle in
                    let values = viewModel.visibleIdeas.filter { $0.status == lifecycle }
                    if !values.isEmpty {
                        Section {
                            ForEach(values) { idea in
                                GiftPlanRow(idea: idea, viewModel: viewModel)
                                    .contentShape(Rectangle())
                                    .onTapGesture { viewModel.presentedIdea = idea }
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        if let next = idea.status.next {
                                            Button {
                                                Task { await viewModel.setStatus(next, for: idea) }
                                            } label: {
                                                Label(next.title, systemImage: next.symbol)
                                            }
                                            .tint(next.tint)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            Task { await viewModel.delete(idea) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        Button {
                                            viewModel.beginEditing(idea)
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                            }
                        } header: {
                            Label(lifecycle.title, systemImage: lifecycle.symbol)
                                .foregroundStyle(lifecycle.tint)
                        }
                    }
                }
            }
        }
        .navigationTitle("Gifts")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show given gifts", isOn: $viewModel.showGiven)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button {
                    viewModel.beginAdding()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add gift")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let deleted = viewModel.recentlyDeleted {
                HStack(spacing: 12) {
                    Text("Removed \(deleted.title)")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Button("Undo") {
                        Task { await viewModel.undoDelete() }
                    }
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.loadIdeas(showLoading: true) }
        .sheet(isPresented: $viewModel.showingEditor) {
            GiftEditorView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.presentedIdea) { idea in
            NavigationStack {
                GiftDetailView(ideaID: idea.id, viewModel: viewModel)
            }
        }
        .alert("Possible duplicate", isPresented: $viewModel.showingDuplicateWarning) {
            Button("Review", role: .cancel) {}
            Button("Add anyway") {
                Task {
                    await viewModel.saveEditor(forceDuplicate: true)
                    if !viewModel.showingEditor { quickTitle = "" }
                }
            }
        } message: {
            Text("A similar active gift already exists:\n\(viewModel.duplicateSummary)")
        }
    }

    private var recipientPicker: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.children) { child in
                        Button {
                            Task { await viewModel.selectChild(child.id) }
                        } label: {
                            Text(child.name)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(
                                    viewModel.selectedChildId == child.id ? Color.white : Color.primary
                                )
                                .background(
                                    viewModel.selectedChildId == child.id
                                        ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Recipient")
        }
    }

    private func addQuickIdea() {
        let title = quickTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        viewModel.resetForm()
        viewModel.formTitle = title
        Task {
            await viewModel.saveEditor()
            if !viewModel.showingDuplicateWarning { quickTitle = "" }
        }
    }
}

private struct GiftPlanRow: View {
    let idea: PresentIdeaDTO
    @ObservedObject var viewModel: PresentsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(idea.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let price = viewModel.moneyLabel(minor: idea.priceMinor, currency: idea.currency) {
                    Text(price)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text(idea.occasion.capitalized)
                if let owner = idea.ownerName {
                    Label(owner, systemImage: "person.example_35fbacff.circle")
                }
                if let deadline = viewModel.deadlineLabel(idea.deadline) {
                    Label(deadline, systemImage: "calendar")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let next = idea.status.next {
                Button {
                    Task { await viewModel.advance(idea) }
                } label: {
                    Label(nextAction(for: idea.status), systemImage: next.symbol)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(next.tint)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func nextAction(for lifecycle: PresentLifecycle) -> String {
        switch lifecycle {
        case .idea: "Shortlist"
        case .shortlist: "Assign"
        case .assigned: "Mark bought"
        case .bought: "Mark arrived"
        case .arrived: "Mark wrapped"
        case .wrapped: "Mark stashed"
        case .stashed: "Mark given"
        case .given: "Given"
        }
    }
}

private struct GiftEditorView: View {
    @ObservedObject var viewModel: PresentsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingMore = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gift") {
                    TextField("What is it?", text: $viewModel.formTitle)
                        .textInputAutocapitalization(.sentences)
                    TextField("Occasion", text: $viewModel.formOccasion)
                        .textInputAutocapitalization(.words)
                    Picker("Status", selection: $viewModel.formStatus) {
                        ForEach(PresentLifecycle.allCases) { lifecycle in
                            Text(lifecycle.title).tag(lifecycle)
                        }
                    }
                    Picker("Owner", selection: $viewModel.formOwnerId) {
                        Text("Unassigned").tag("")
                        ForEach(viewModel.adults) { adult in
                            Text(adult.name).tag(adult.id)
                        }
                    }
                }

                Section("Timing") {
                    Toggle("Has a deadline", isOn: $viewModel.formHasDeadline)
                    if viewModel.formHasDeadline {
                        DatePicker(
                            "Needed by",
                            selection: $viewModel.formDeadline,
                            displayedComponents: .date
                        )
                    }
                }

                Section {
                    DisclosureGroup("More details", isExpanded: $showingMore) {
                        TextField("Shop link", text: $viewModel.formURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Retailer", text: $viewModel.formRetailer)
                        TextField("Budget (£)", text: $viewModel.formBudget)
                            .keyboardType(.decimalPad)
                        TextField("Price paid (£)", text: $viewModel.formPrice)
                            .keyboardType(.decimalPad)
                        TextField("Hiding place", text: $viewModel.formHidingLocation)
                        TextField("Notes", text: $viewModel.formNotes, axis: .vertical)
                            .lineLimit(2...6)
                        Toggle("Keep hidden from recipient", isOn: $viewModel.formHiddenFromRecipient)
                    }
                } footer: {
                    Text("Gift plans are private by default, including the hiding place.")
                }
            }
            .navigationTitle(viewModel.editingIdea == nil ? "New Gift" : "Edit Gift")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showingEditor = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isSaving ? "Saving…" : "Save") {
                        Task { await viewModel.saveEditor() }
                    }
                    .disabled(
                        viewModel.isSaving
                            || viewModel.formTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct GiftDetailView: View {
    let ideaID: String
    @ObservedObject var viewModel: PresentsViewModel
    @Environment(\.dismiss) private var dismiss

    private var idea: PresentIdeaDTO? {
        viewModel.ideas.first(where: { $0.id == ideaID })
            ?? (viewModel.presentedIdea?.id == ideaID ? viewModel.presentedIdea : nil)
    }

    var body: some View {
        List {
            if let idea {
                Section {
                    HStack {
                        Label(idea.status.title, systemImage: idea.status.symbol)
                            .foregroundStyle(idea.status.tint)
                        Spacer()
                        Menu("Correct status") {
                            ForEach(PresentLifecycle.allCases) { lifecycle in
                                Button {
                                    Task { await viewModel.setStatus(lifecycle, for: idea) }
                                } label: {
                                    if lifecycle == idea.status {
                                        Label(lifecycle.title, systemImage: "checkmark")
                                    } else {
                                        Text(lifecycle.title)
                                    }
                                }
                            }
                        }
                    }
                    if let next = idea.status.next {
                        Button {
                            Task { await viewModel.advance(idea) }
                        } label: {
                            Label("Move to \(next.title)", systemImage: next.symbol)
                        }
                    }
                }

                Section("Plan") {
                    LabeledContent("Recipient", value: idea.recipientName ?? viewModel.selectedChildName)
                    LabeledContent("Occasion", value: idea.occasion.capitalized)
                    if let owner = idea.ownerName {
                        LabeledContent("Owner", value: owner)
                    }
                    if let deadline = viewModel.deadlineLabel(idea.deadline) {
                        LabeledContent("Deadline", value: deadline)
                    }
                    if let retailer = idea.retailer {
                        LabeledContent("Retailer", value: retailer)
                    }
                    if let budget = viewModel.moneyLabel(minor: idea.budgetMinor, currency: idea.currency) {
                        LabeledContent("Budget", value: budget)
                    }
                    if let price = viewModel.moneyLabel(minor: idea.priceMinor, currency: idea.currency) {
                        LabeledContent("Price paid", value: price)
                    }
                    if let destination = SafeExternalURL.web(idea.url) {
                        Link(destination: destination) {
                            Label("Open shop link", systemImage: "safari")
                        }
                    }
                }

                if idea.hidingLocation != nil || idea.notes != nil {
                    Section("Private details") {
                        if let hiding = idea.hidingLocation {
                            LabeledContent("Hiding place", value: hiding)
                        }
                        if let notes = idea.notes {
                            Text(notes)
                        }
                    }
                }

                if !idea.statusHistory.isEmpty {
                    Section("History") {
                        ForEach(idea.statusHistory.reversed()) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.toStatus.symbol)
                                    .foregroundStyle(item.toStatus.tint)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.toStatus.title)
                                    Text(historySubtitle(item))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(idea?.title ?? "Gift")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let idea {
                    Button("Edit") {
                        dismiss()
                        viewModel.beginEditing(idea)
                    }
                    Menu {
                        Button("Delete", role: .destructive) {
                            Task {
                                await viewModel.delete(idea)
                                dismiss()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func historySubtitle(_ item: PresentStatusHistoryDTO) -> String {
        let actor = item.changedByName ?? "Family"
        guard let date = ISODateParser.parse(item.changedAt) else { return actor }
        return "\(actor) · \(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }
}

private extension PresentLifecycle {
    var symbol: String {
        switch self {
        case .idea: "lightbulb"
        case .shortlist: "star"
        case .assigned: "person.example_35fbacff.circle.badge.checkmark"
        case .bought: "bag"
        case .arrived: "shippingbox"
        case .wrapped: "gift"
        case .stashed: "lock.example_c6e20e62"
        case .given: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idea: .secondary
        case .shortlist: .yellow
        case .assigned: .blue
        case .bought: .indigo
        case .arrived: .orange
        case .wrapped: .pink
        case .stashed: .purple
        case .given: .green
        }
    }
}

#Preview {
    NavigationStack { PresentsView() }
}
