import SwiftUI

struct UniversalCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CaptureViewModel()
    @StateObject private var dictation = DictationService()
    @State private var dictationPrefix = ""

    let initialText: String
    let onScanDocument: () -> Void
    let onContinueInBismarck: (String) -> Void
    let onCaptureCommitted: () -> Void

    init(
        initialText: String = "",
        onScanDocument: @escaping () -> Void,
        onContinueInBismarck: @escaping (String) -> Void = { _ in },
        onCaptureCommitted: @escaping () -> Void = {}
    ) {
        self.initialText = initialText
        self.onScanDocument = onScanDocument
        self.onContinueInBismarck = onContinueInBismarck
        self.onCaptureCommitted = onCaptureCommitted
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.stage {
                case .input: inputView
                case .review: reviewView
                case .complete: completeView
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(HausKlarAccessibilityID.Capture.screen)
            .toolbar { toolbarContent }
            .task {
                viewModel.prepare(ownerID: appState.currentUser?.id, initialText: initialText)
                await viewModel.loadMembers()
            }
            .onChange(of: viewModel.inputText) { _, _ in viewModel.persistDraft() }
            .onChange(of: viewModel.proposals) { _, _ in viewModel.persistDraft() }
            .onChange(of: viewModel.results) { _, _ in viewModel.persistDraft() }
            .onChange(of: viewModel.stage) { _, stage in
                viewModel.persistDraft()
                if stage == .complete { onCaptureCommitted() }
            }
            .onChange(of: dictation.transcript) { _, transcript in
                viewModel.inputText = dictationPrefix + transcript
            }
            .onDisappear { dictation.stop() }
            .interactiveDismissDisabled(viewModel.isParsing || viewModel.isSaving)
        }
    }

    private var title: String {
        switch viewModel.stage {
        case .input: return "Add".localized
        case .review: return "Check before adding".localized
        case .complete: return "Added".localized
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            switch viewModel.stage {
            case .review:
                if viewModel.savedCount == 0 {
                    Button {
                        viewModel.returnToInput()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back to your text")
                }
            case .input:
                Button("Close") { dismiss() }
            case .complete:
                EmptyView()
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            switch viewModel.stage {
            case .input:
                if !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Clear", role: .destructive) { viewModel.discardDraft() }
                }
            case .review:
                Menu {
                    Button("Event", systemImage: "calendar.badge.plus") {
                        viewModel.addProposal(.event)
                    }
                    Button("Task", systemImage: "checkmark.circle") {
                        viewModel.addProposal(.task)
                    }
                    Button("Shopping item", systemImage: "cart.badge.plus") {
                        viewModel.addProposal(.shopping)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add another item")
            case .complete:
                Button("Done") { dismiss() }
            }
        }
    }

    private var inputView: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    if viewModel.inputText.isEmpty {
                        Text("What needs adding or sorting out?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.inputText)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("What needs adding or sorting out")
                        .accessibilityIdentifier(HausKlarAccessibilityID.Capture.input)
                }

                inputActions
            } footer: {
                Text("You will check every change before anything is added.")
            }

            Section("Quick add") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.recentDirectActions, id: \.rawValue) { action in
                            Button {
                                useDirectAction(action)
                            } label: {
                                Label(action.title, systemImage: action.icon)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let message = dictation.errorMessage ?? viewModel.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier(HausKlarAccessibilityID.Capture.error)
                }
            }

            Section {
                Button {
                    dictation.stop()
                    Task { await viewModel.reviewInput() }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isParsing {
                            ProgressView()
                        } else {
                            Label("Review", systemImage: "arrow.right")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.isParsing
                        || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || viewModel.inputText.count > 10_000
                )
                .accessibilityLabel(
                    Text(viewModel.isParsing ? "Reviewing".localized : "Review".localized)
                )
                .accessibilityIdentifier(HausKlarAccessibilityID.Capture.review)
            }
        }
    }

    private var reviewView: some View {
        Form {
            if viewModel.suggestsBismarck {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This may need a little more thought.")
                            .font(.subheadline.weight(.semibold))
                        Text("You can check the items below, or ask Bismarck to work through the whole request with you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Ask Bismarck", systemImage: "sparkles") {
                            continueInBismarck()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier(HausKlarAccessibilityID.Capture.error)
                }
            }

            ForEach($viewModel.proposals) { $proposal in
                Section {
                    CaptureProposalEditor(
                        proposal: $proposal,
                        result: viewModel.result(for: proposal.id),
                        familyMembers: viewModel.familyMembers,
                        readOnly: false,
                        onRemove: { viewModel.removeProposal(id: proposal.id) },
                        onOpen: { result in openResult(result, proposal: proposal) }
                    )
                }
            }

            if viewModel.proposals.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing clear to add yet",
                        systemImage: "text.bubble",
                        description: Text("Go back and reword it, add an item below, or ask Bismarck for help.")
                    )
                }
            }

            Section {
                Button {
                    Task { await viewModel.confirm() }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isSaving {
                            ProgressView()
                        } else {
                            Label(confirmButtonTitle, systemImage: "checkmark")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSaving || viewModel.includedCount == 0)
                .accessibilityIdentifier(HausKlarAccessibilityID.Capture.confirm)
            }
        }
        .accessibilityIdentifier(HausKlarAccessibilityID.Capture.reviewScreen)
    }

    private var completeView: some View {
        Form {
            Section {
                Label(completionTitle, systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            ForEach($viewModel.proposals) { $proposal in
                if let result = viewModel.result(for: proposal.id), result.state == .succeeded {
                    Section {
                        CaptureProposalEditor(
                            proposal: $proposal,
                            result: result,
                            familyMembers: viewModel.familyMembers,
                            readOnly: true,
                            onRemove: {},
                            onOpen: { saved in openResult(saved, proposal: proposal) }
                        )
                    }
                }
            }

            Section {
                Button("Done") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityIdentifier(HausKlarAccessibilityID.Capture.complete)
    }

    private func useDirectAction(_ action: CaptureDirectAction) {
        dictation.stop()
        if action == .document {
            viewModel.recordDocumentAction()
            dismiss()
            onScanDocument()
        } else {
            viewModel.startDirect(action)
        }
    }

    @ViewBuilder
    private var characterLimitStatus: some View {
        let remaining = 10_000 - viewModel.inputText.count
        if remaining >= 0 {
            Text(String(format: "%lld characters left".localized, Int64(remaining)))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(
                String(format: "%lld characters over the limit".localized, Int64(-remaining)),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var inputActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.inputText.count > 9_000 {
                    characterLimitStatus
                }
                dictationButton
            }
        } else {
            HStack {
                if viewModel.inputText.count > 9_000 {
                    characterLimitStatus
                }
                Spacer()
                dictationButton
            }
        }
    }

    private var dictationButton: some View {
        Button {
            toggleDictation()
        } label: {
            Label(
                (dictation.isRecording ? "Stop" : "Dictate").localized,
                systemImage: dictation.isRecording ? "stop.fill" : "mic.fill"
            )
        }
        .buttonStyle(.bordered)
        .tint(dictation.isRecording ? .red : nil)
        .accessibilityHint("Uses on-device speech recognition when available")
        .accessibilityIdentifier(HausKlarAccessibilityID.Capture.dictate)
    }

    private var confirmButtonTitle: String {
        viewModel.includedCount == 1
            ? "Add 1 item".localized
            : String(format: "Add %lld items".localized, Int64(viewModel.includedCount))
    }

    private var completionTitle: String {
        viewModel.savedCount == 1
            ? "1 item added".localized
            : String(format: "%lld items added".localized, Int64(viewModel.savedCount))
    }

    private func continueInBismarck() {
        let text = viewModel.inputText
        // The authenticated app shell now owns the exact unsent message, so a
        // later Capture session must not offer the same changes a second time.
        viewModel.discardDraft()
        dictation.stop()
        dismiss()
        onContinueInBismarck(text)
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        let existing = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationPrefix = existing.isEmpty ? "" : existing + "\n"
        Task { await dictation.start() }
    }

    private func openResult(_ result: CaptureItemResult, proposal: EditableCaptureProposal) {
        guard let resultID = result.resultId else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            switch result.kind {
            case .event:
                appState.highlightedCalendarResultId = resultID
                appState.preferredCalendarDate = proposal.startDate
                appState.selectedTab = .calendar
            case .task:
                appState.highlightedTaskResultId = resultID
                appState.preferredTaskShowCompleted = false
                appState.openLists(.tasks)
            case .shopping:
                appState.highlightedShoppingResultId = resultID
                appState.preferredMealsSection = 2
                appState.preferredTescoSubpage = 1
                appState.openLists(.meals)
            }
        }
    }
}

private struct CaptureProposalEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var proposal: EditableCaptureProposal
    let result: CaptureItemResult?
    let familyMembers: [FamilyMemberDTO]
    let readOnly: Bool
    let onRemove: () -> Void
    let onOpen: (CaptureItemResult) -> Void

    private var locked: Bool { readOnly || result?.state == .succeeded || result?.state == .saving }

    var body: some View {
        FamilyChangeReviewCard(
            actionTitle: proposal.kind.reviewActionTitle,
            title: proposal.trimmedTitle.isEmpty ? "Untitled".localized : proposal.trimmedTitle,
            summary: summary,
            systemImage: proposal.kind.icon,
            status: status,
            statusColor: statusColor,
            statusSystemImage: statusSystemImage,
            showsDetails: !readOnly,
            details: { detailFields.disabled(locked) },
            footer: { footer }
        )
    }

    @ViewBuilder
    private var detailFields: some View {
        if dynamicTypeSize.isAccessibilitySize {
            kindPicker.pickerStyle(.menu)
        } else {
            kindPicker.pickerStyle(.segmented)
        }

        TextField(
            proposal.kind == .shopping ? "Item".localized : "Title".localized,
            text: $proposal.title
        )
        .textInputAutocapitalization(.sentences)

        switch proposal.kind {
        case .event:
            TextField("Notes", text: $proposal.details, axis: .vertical)
                .lineLimit(2...5)
            Toggle("All day", isOn: $proposal.allDay)
            DatePicker(
                "Starts",
                selection: $proposal.startDate,
                displayedComponents: proposal.allDay ? [.date] : [.date, .hourAndMinute]
            )
            if !proposal.allDay {
                Toggle("End time", isOn: $proposal.hasEndDate)
                if proposal.hasEndDate {
                    DatePicker(
                        "Ends",
                        selection: $proposal.endDate,
                        in: proposal.startDate...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }
            assigneePicker
        case .task:
            TextField("Notes", text: $proposal.details, axis: .vertical)
                .lineLimit(2...5)
            Toggle("Due date", isOn: $proposal.hasDueDate)
            if proposal.hasDueDate {
                DatePicker(
                    "Due",
                    selection: $proposal.dueDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
            assigneePicker
        case .shopping:
            TextField("Quantity", text: $proposal.quantity)
            TextField("Category", text: $proposal.category)
        }
    }

    private var kindPicker: some View {
        Picker("Type", selection: $proposal.kind) {
            ForEach(UniversalCaptureKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
    }

    private var assigneePicker: some View {
        Picker("For", selection: $proposal.assignedTo) {
            Text("Everyone").tag(String?.none)
            ForEach(familyMembers) { member in
                Text(member.name).tag(Optional(member.id))
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let result, result.state == .succeeded, result.resultId != nil {
            Button("Open item", systemImage: "arrow.right.circle") { onOpen(result) }
                .buttonStyle(.bordered)
        } else if !readOnly {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    inclusionButton
                    removeButton
                }
            } else {
                HStack(spacing: 10) {
                    inclusionButton
                    Spacer()
                    removeButton
                }
            }
        }
    }

    private var inclusionButton: some View {
        Button {
            proposal.isIncluded.toggle()
            HapticManager.selection()
        } label: {
            Label(
                (proposal.isIncluded ? "Included" : "Not included").localized,
                systemImage: proposal.isIncluded ? "checkmark.circle.fill" : "circle"
            )
        }
        .buttonStyle(.bordered)
        .disabled(result?.state == .saving)
    }

    private var removeButton: some View {
        Button(role: .destructive, action: onRemove) {
            Label("Remove", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(result?.state == .saving)
    }

    private var summary: String? {
        var parts: [String] = []
        switch proposal.kind {
        case .event:
            parts.append(
                proposal.startDate.formatted(
                    proposal.allDay
                        ? Date.FormatStyle(date: .abbreviated, time: .omitted)
                        : Date.FormatStyle(date: .abbreviated, time: .shortened)
                )
            )
            if let name = assigneeName { parts.append(name) }
        case .task:
            if proposal.hasDueDate {
                parts.append(proposal.dueDate.formatted(date: .abbreviated, time: .shortened))
            }
            if let name = assigneeName { parts.append(name) }
        case .shopping:
            let quantity = proposal.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quantity.isEmpty { parts.append(quantity) }
            let category = proposal.category.trimmingCharacters(in: .whitespacesAndNewlines)
            if !category.isEmpty { parts.append(category) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var assigneeName: String? {
        guard let assignedTo = proposal.assignedTo else { return nil }
        return familyMembers.first(where: { $0.id == assignedTo })?.name
    }

    private var status: String? {
        switch result?.state {
        case .saving: return "Adding…".localized
        case .succeeded: return "Added".localized
        case .failed: return result?.message
        case nil: return nil
        }
    }

    private var statusColor: Color {
        switch result?.state {
        case .succeeded: return .green
        case .failed: return .red
        case .saving, nil: return .secondary
        }
    }

    private var statusSystemImage: String {
        switch result?.state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .saving, nil: return "clock"
        }
    }
}

/// Shared visual language for deterministic Capture and Bismarck proposals.
/// The family sees the ordinary-language effect first; optional fields stay tucked away.
struct FamilyChangeReviewCard<Details: View, Footer: View>: View {
    let actionTitle: String
    let title: String
    let summary: String?
    let systemImage: String
    let status: String?
    let statusColor: Color
    let statusSystemImage: String
    let showsDetails: Bool
    let details: Details
    let footer: Footer
    @State private var detailsExpanded = false

    init(
        actionTitle: String,
        title: String,
        summary: String? = nil,
        systemImage: String,
        status: String? = nil,
        statusColor: Color = .secondary,
        statusSystemImage: String = "info.circle.fill",
        showsDetails: Bool,
        @ViewBuilder details: () -> Details,
        @ViewBuilder footer: () -> Footer
    ) {
        self.actionTitle = actionTitle
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.status = status
        self.statusColor = statusColor
        self.statusSystemImage = statusSystemImage
        self.showsDetails = showsDetails
        self.details = details()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
            }

            if let status {
                Label {
                    Text(status)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: statusSystemImage)
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            if showsDetails {
                DisclosureGroup("Check or change details", isExpanded: $detailsExpanded) {
                    VStack(alignment: .leading, spacing: 12) { details }
                        .padding(.top, 10)
                }
                .font(.subheadline)
            }

            footer
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
