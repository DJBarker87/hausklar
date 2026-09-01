import SwiftUI

private struct AssistantEditContext: Identifiable {
    let messageID: UUID
    let action: AssistantActionState
    var id: String { action.id }
}

/// Global family assistant. Its view model is owned by the authenticated app shell so
/// closing this sheet never discards an unfinished conversation or pending proposal.
struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @ObservedObject private var viewModel: AssistantChatViewModel
    @StateObject private var aiConsent = AIConsentViewModel()
    @StateObject private var dictation = DictationService()
    @FocusState private var inputFocused: Bool
    @State private var dictationPrefix = ""
    @State private var dictationLanguage = "en_GB"
    @State private var showingPhotoSearch = false
    @State private var editingAction: AssistantEditContext?

    init(viewModel: AssistantChatViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if aiConsent.isLoading {
                    Spacer()
                    ProgressView("Checking your AI privacy choice…")
                    Spacer()
                } else if let consent = aiConsent.status, !consent.consented {
                    consentChoice(consent)
                } else if aiConsent.hasConsent {
                    if !networkMonitor.isConnected {
                        offlineBanner
                    }
                    conversation
                    if let error = dictation.errorMessage ?? viewModel.errorMessage {
                        errorBanner(error)
                    }
                    composer
                } else {
                    consentLoadError
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Bismarck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close Bismarck")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingPhotoSearch = true } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .accessibilityLabel("Search photos")

                    Button { viewModel.clear() } label: { Image(systemName: "trash") }
                        .disabled(viewModel.messages.isEmpty)
                        .accessibilityLabel("Clear conversation")
                }
            }
            .sheet(isPresented: $showingPhotoSearch) { PhotoSearchView() }
            .sheet(item: $editingAction) { context in
                if let preview = context.action.preview {
                    AssistantActionEditView(
                        preview: preview,
                        familyMembers: viewModel.familyMembers
                    ) { preview in
                        await viewModel.update(actionID: context.action.id, in: context.messageID, preview: preview)
                    }
                }
            }
            .task {
                await aiConsent.load()
                if let draft = appState.assistantDraftText,
                   viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.inputText = draft
                    appState.assistantDraftText = nil
                }
                await viewModel.loadMembers()
            }
            .onChange(of: dictation.transcript) { _, transcript in
                viewModel.inputText = dictationPrefix + transcript
            }
            .onDisappear { dictation.stop() }
        }
    }

    private func consentChoice(_ status: AIConsentStatusDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 52, height: 52)
                    .background(Color.teal.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Your choice")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text("Allow Bismarck to use OpenAI?")
                        .font(.title2.weight(.bold))
                    Text(status.disclosure)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    consentBullet("Only runs when you deliberately choose an AI feature")
                    consentBullet("No unattended or nightly AI processing")
                    consentBullet("Withdraw permission at any time in Settings")
                }

                if let privacyURL = SafeExternalURL.web("https://hausklar.example.invalid/privacy-policy") {
                    Link("Read the privacy policy", destination: privacyURL)
                        .font(.subheadline.weight(.semibold))
                }

                if let error = aiConsent.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error. \(error)")
                }

                VStack(spacing: 10) {
                    Button {
                        Task { await aiConsent.grant() }
                    } label: {
                        HStack {
                            if aiConsent.isSaving { ProgressView().tint(.white) }
                            Text(aiConsent.isSaving ? "Saving…" : "Allow and continue")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(aiConsent.isSaving || !networkMonitor.isConnected)

                    Button("Not now") { dismiss() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(aiConsent.isSaving)
                }
            }
            .padding(22)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func consentBullet(_ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
        }
    }

    private var consentLoadError: some View {
        ContentUnavailableView {
            Label("AI privacy settings unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text(aiConsent.errorMessage ?? "Reconnect and try again before using Bismarck.")
        } actions: {
            Button("Try Again") { Task { await aiConsent.load() } }
                .buttonStyle(.borderedProminent)
                .disabled(!networkMonitor.isConnected)
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if viewModel.messages.isEmpty { welcome }

                    ForEach(viewModel.messages) { message in
                        messageView(message).id(message.id)
                    }

                    if viewModel.isSending { thinkingIndicator.id("thinking") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: viewModel.isSending) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                assistantAvatar
                VStack(alignment: .leading, spacing: 5) {
                    Text("What can I help with?").font(.headline)
                    Text("Ask a question or tell me what needs doing. I will show every change for you to check before anything is saved.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 8) {
                ForEach(viewModel.suggestedPrompts, id: \.self) { prompt in
                    Button {
                        Task { await viewModel.send(prompt) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestionIcon(prompt))
                                .foregroundStyle(.teal)
                                .frame(width: 22)
                            Text(prompt.localized)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 48)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!networkMonitor.isConnected)
                }
            }
        }
        .padding(.top, 8)
    }

    private func messageView(_ message: AssistantChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant { assistantAvatar } else { Spacer(minLength: 46) }

            VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 10) {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(message.role == .user ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 310, alignment: message.role == .assistant ? .leading : .trailing)

                ForEach(message.actions) { action in
                    actionView(action, messageID: message.id)
                }
            }

            if message.role == .assistant { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity)
    }

    private func actionView(_ action: AssistantActionState, messageID: UUID) -> some View {
        FamilyChangeReviewCard(
            actionTitle: action.kind.reviewActionTitle,
            title: action.preview?.title ?? action.summary,
            summary: actionSummary(action),
            systemImage: action.kind.icon,
            status: actionStatusText(action),
            statusColor: statusColor(action.status),
            statusSystemImage: statusIcon(action.status),
            showsDetails: action.preview != nil,
            details: {
                if let preview = action.preview {
                    previewDetails(preview)
                }
            },
            footer: {
                actionFooter(action, messageID: messageID)
            }
        )
        .padding(12)
        .frame(maxWidth: 310, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10)) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionFooter(_ action: AssistantActionState, messageID: UUID) -> some View {
        switch action.status {
        case .pending:
            HStack(spacing: 8) {
                if action.editable, action.preview != nil {
                    Button("Edit", systemImage: "pencil") {
                        editingAction = AssistantEditContext(messageID: messageID, action: action)
                        HapticManager.selection()
                    }
                    .buttonStyle(.bordered)
                }

                Button(action.kind.confirmationTitle, systemImage: "checkmark") {
                    Task { await viewModel.confirm(actionID: action.id, in: messageID) }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button {
                    Task { await viewModel.decline(actionID: action.id, in: messageID) }
                } label: {
                    Image(systemName: "xmark").frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Do not make this change")
            }
            .disabled(!networkMonitor.isConnected)
        case .executing:
            EmptyView()
        case .executed:
            if action.resultId != nil {
                Button(resultLinkTitle(action.kind), systemImage: "arrow.right.circle") {
                    openResult(for: action)
                }
                .buttonStyle(.bordered)
            }
        case .declined, .failed, .expired:
            EmptyView()
        }
    }

    private func actionStatusText(_ action: AssistantActionState) -> String? {
        if let resultMessage = action.resultMessage, !resultMessage.isEmpty {
            return resultMessage
        }
        switch action.status {
        case .pending: return nil
        case .executing: return "Making this change…"
        case .executed: return "Done"
        case .declined: return "Not added"
        case .failed: return "This change could not be made."
        case .expired: return "Ask Bismarck to prepare this change again."
        }
    }

    private func actionSummary(_ action: AssistantActionState) -> String? {
        guard let preview = action.preview else { return nil }
        var parts: [String] = []
        switch preview {
        case .calendar(let value):
            parts.append(displayDate(value.startTime, allDay: value.allDay))
            if let assignedTo = value.assignedTo { parts.append(memberName(assignedTo)) }
        case .task(let value):
            if let dueDate = value.dueDate {
                parts.append(displayDate(dueDate, allDay: false))
            }
            if let assignedTo = value.assignedTo { parts.append(memberName(assignedTo)) }
        case .shopping(let value):
            if let quantity = value.quantity?.trimmingCharacters(in: .whitespacesAndNewlines),
               !quantity.isEmpty {
                parts.append(quantity)
            }
            if let category = value.category?.trimmingCharacters(in: .whitespacesAndNewlines),
               !category.isEmpty {
                parts.append(category)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func previewDetails(_ preview: AssistantActionPreview) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            switch preview {
            case .calendar(let value):
                detailRow("Title", value.title)
                detailRow(value.allDay ? "Date" : "Starts", displayDate(value.startTime, allDay: value.allDay))
                if let assignedTo = value.assignedTo { detailRow("For", memberName(assignedTo)) }
                if value.recurrenceRule != nil {
                    detailRow("Repeats", AssistantRecurrenceOption(rule: value.recurrenceRule).title)
                }
                if value.termTimeOnly { detailRow("Term", "School term only") }
            case .task(let value):
                detailRow("Task", value.title)
                if let dueDate = value.dueDate { detailRow("Due", displayDate(dueDate, allDay: false)) }
                if let assignedTo = value.assignedTo { detailRow("For", memberName(assignedTo)) }
                if value.recurrenceRule != nil {
                    detailRow("Repeats", AssistantRecurrenceOption(rule: value.recurrenceRule).title)
                }
            case .shopping(let value):
                detailRow("Item", value.name)
                if let quantity = value.quantity, !quantity.isEmpty { detailRow("Quantity", quantity) }
                if let category = value.category, !category.isEmpty { detailRow("Category", category) }
            }
        }
        .font(.caption)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thinkingIndicator: some View {
        HStack(alignment: .top, spacing: 10) {
            assistantAvatar
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(viewModel.thinkingStatus).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
    }

    private var assistantAvatar: some View {
        Image(systemName: "sparkles")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color.teal, in: Circle())
            .accessibilityHidden(true)
    }

    private var offlineBanner: some View {
        Label("Bismarck needs a connection. You can still close this and use Add.", systemImage: "wifi.slash")
            .font(.caption)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.14))
            .accessibilityLabel("Offline. Bismarck needs a connection. Add is still available.")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            if viewModel.canRetry {
                Button("Retry") {
                    Task { await viewModel.retryLastMessage() }
                }
                .font(.caption.weight(.semibold))
                .disabled(!networkMonitor.isConnected)
                .accessibilityHint("Resends without adding a duplicate message")
            }
            Button { viewModel.errorMessage = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask or tell Bismarck what needs doing", text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .focused($inputFocused)
                    .disabled(!networkMonitor.isConnected)
                    .submitLabel(.send)
                    .onSubmit { if viewModel.canSend && networkMonitor.isConnected { sendMessage() } }

                Menu {
                    Button("English", systemImage: dictationLanguage == "en_GB" ? "checkmark" : "character.bubble") {
                        dictationLanguage = "en_GB"
                    }
                    Button("Deutsch", systemImage: dictationLanguage == "de_DE" ? "checkmark" : "character.bubble") {
                        dictationLanguage = "de_DE"
                    }
                } label: {
                    Text(dictationLanguage == "en_GB" ? "EN" : "DE")
                        .font(.caption2.weight(.bold))
                        .frame(width: 32, height: 44)
                }
                .disabled(dictation.isRecording || !networkMonitor.isConnected)
                .accessibilityLabel("Dictation language")

                Button { toggleDictation() } label: {
                    Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 40, height: 44)
                }
                .disabled(viewModel.isSending || !networkMonitor.isConnected)
                .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate message")

                Button { sendMessage() } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(viewModel.canSend && networkMonitor.isConnected ? Color.accentColor : Color.secondary, in: Circle())
                }
                .disabled(!viewModel.canSend || !networkMonitor.isConnected)
                .accessibilityLabel("Send message")
            }
            Button("Open Fitness Coach",systemImage:"figure.run.circle") {
                handOffToFitnessCoach()
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
            .disabled(viewModel.fitnessCoachDraftForHandoff() == nil)
            .accessibilityHint("Moves this unsent message to your private Fitness Coach")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func toggleDictation() {
        if dictation.isRecording { dictation.stop(); return }
        let existing = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationPrefix = existing.isEmpty ? "" : existing + " "
        Task { await dictation.start(localeIdentifier: dictationLanguage) }
    }

    private func sendMessage() {
        dictation.stop()
        Task { await viewModel.send() }
    }

    private func handOffToFitnessCoach() {
        guard let draft=viewModel.fitnessCoachDraftForHandoff(),
              let ownerId=appState.currentUser?.id else { return }
        dictation.stop()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
            guard appState.currentUser?.id == ownerId,
                  appState.stageFitnessCoachDraft(draft) != nil else { return }
            appState.openFitness(destination:.coach)
        }
    }

    private func memberName(_ id: String) -> String {
        viewModel.familyMembers.first(where: { $0.id == id })?.name ?? "Family member"
    }

    private func displayDate(_ value: String, allDay: Bool) -> String {
        guard let date = ISODateParser.parse(value) else { return value }
        return date.formatted(
            allDay
                ? Date.FormatStyle(date: .abbreviated, time: .omitted)
                : Date.FormatStyle(date: .abbreviated, time: .shortened)
        )
    }

    private func suggestionIcon(_ prompt: String) -> String {
        if prompt.localizedCaseInsensitiveContains("shopping") { return "cart.badge.plus" }
        if prompt.localizedCaseInsensitiveContains("swimming") { return "calendar.badge.plus" }
        if prompt.localizedCaseInsensitiveContains("remind") { return "checklist" }
        return "sparkles"
    }

    private func statusIcon(_ status: AssistantActionStatus) -> String {
        switch status {
        case .executed: return "checkmark.circle.fill"
        case .declined: return "xmark.circle"
        case .failed, .expired: return "exclamationmark.circle.fill"
        case .pending, .executing: return "clock"
        }
    }

    private func statusColor(_ status: AssistantActionStatus) -> Color {
        switch status {
        case .executed: return .green
        case .declined: return .secondary
        case .failed, .expired: return .red
        case .pending, .executing: return .secondary
        }
    }

    private func resultLinkTitle(_ kind: AssistantActionKind) -> String {
        switch kind {
        case .calendarEvent: return "Open event"
        case .createTask, .completeTask: return "Open task"
        case .shoppingItem: return "Open shopping item"
        case .homeLights: return "Open House"
        }
    }

    private func openResult(for action: AssistantActionState) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            switch action.kind {
            case .calendarEvent:
                appState.highlightedCalendarResultId = action.resultId
                if case .calendar(let preview) = action.preview {
                    appState.preferredCalendarDate = ISODateParser.parse(preview.startTime)
                }
                appState.selectedTab = .calendar
            case .createTask:
                appState.preferredTaskShowCompleted = false
                appState.highlightedTaskResultId = action.resultId
                appState.openLists(.tasks)
            case .completeTask:
                appState.preferredTaskShowCompleted = true
                appState.highlightedTaskResultId = action.resultId
                appState.openLists(.tasks)
            case .shoppingItem:
                appState.highlightedShoppingResultId = action.resultId
                appState.preferredMealsSection = 2
                appState.preferredTescoSubpage = 1
                appState.openLists(.meals)
            case .homeLights:
                appState.openFamily(.house)
            }
        }
    }
}

private struct AssistantActionEditView: View {
    @Environment(\.dismiss) private var dismiss
    let familyMembers: [FamilyMemberDTO]
    let onSave: (AssistantActionPreview) async -> Bool

    @State private var preview: AssistantActionPreview
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        preview: AssistantActionPreview,
        familyMembers: [FamilyMemberDTO],
        onSave: @escaping (AssistantActionPreview) async -> Bool
    ) {
        _preview = State(initialValue: preview)
        self.familyMembers = familyMembers
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                switch preview {
                case .calendar:
                    calendarFields
                case .task:
                    taskFields
                case .shopping:
                    shoppingFields
                }

                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Check details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving || !isValid)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var calendarFields: some View {
        if case .calendar(let value) = preview {
            Section("Event") {
                TextField("Title", text: binding(\.title, in: value))
                TextField("Notes", text: optionalBinding(\.description, in: value), axis: .vertical)
                    .lineLimit(2...5)
                Toggle("All day", isOn: binding(\.allDay, in: value))
                DatePicker(
                    "Starts",
                    selection: dateBinding(value.startTime) { updated in updateCalendar { $0.startTime = updated } },
                    displayedComponents: value.allDay ? [.date] : [.date, .hourAndMinute]
                )
                Toggle("End time", isOn: Binding(
                    get: { value.endTime != nil },
                    set: { enabled in updateCalendar { $0.endTime = enabled ? ($0.endTime ?? $0.startTime) : nil } }
                ))
                if let end = value.endTime {
                    DatePicker(
                        "Ends",
                        selection: dateBinding(end) { updated in updateCalendar { $0.endTime = updated } },
                        displayedComponents: value.allDay ? [.date] : [.date, .hourAndMinute]
                    )
                }
                assigneePicker(value.assignedTo) { selected in updateCalendar { $0.assignedTo = selected } }
                Picker(
                    "Repeat",
                    selection: Binding(
                        get: { AssistantRecurrenceOption(rule: value.recurrenceRule) },
                        set: { option in
                            updateCalendar {
                                $0.recurrenceRule = option.rule(preserving: $0.recurrenceRule)
                                if $0.recurrenceRule == nil { $0.termTimeOnly = false }
                            }
                        }
                    )
                ) {
                    ForEach(AssistantRecurrenceOption.common) { option in
                        Text(option.title).tag(option)
                    }
                    if AssistantRecurrenceOption(rule: value.recurrenceRule) == .custom {
                        Text(AssistantRecurrenceOption.custom.title).tag(AssistantRecurrenceOption.custom)
                    }
                }
                if value.recurrenceRule != nil {
                    Toggle("Only during school term", isOn: binding(\.termTimeOnly, in: value))
                        .disabled(value.assignedTo == nil)
                    if value.assignedTo == nil {
                        Text("Choose a family member to use term-time repeats.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var taskFields: some View {
        if case .task(let value) = preview {
            Section("Task") {
                TextField("Title", text: taskBinding(\.title, in: value))
                TextField("Notes", text: taskOptionalBinding(\.description, in: value), axis: .vertical)
                    .lineLimit(2...5)
                Toggle("Due date", isOn: Binding(
                    get: { value.dueDate != nil },
                    set: { enabled in updateTask { $0.dueDate = enabled ? ($0.dueDate ?? ISODateParser.string(from: Date())) : nil } }
                ))
                if let due = value.dueDate {
                    DatePicker(
                        "Due",
                        selection: dateBinding(due) { updated in updateTask { $0.dueDate = updated } },
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Picker("Priority", selection: taskBinding(\.priority, in: value)) {
                    Text("Low").tag(1)
                    Text("Normal").tag(2)
                    Text("High").tag(3)
                }
                Picker("Category", selection: taskBinding(\.category, in: value)) {
                    Text("Bins").tag("bins")
                    Text("Household").tag("household")
                    Text("Shopping").tag("shopping")
                    Text("Admin").tag("admin")
                    Text("Other").tag("other")
                }
                assigneePicker(value.assignedTo) { selected in updateTask { $0.assignedTo = selected } }
                Picker(
                    "Repeat",
                    selection: Binding(
                        get: { AssistantRecurrenceOption(rule: value.recurrenceRule) },
                        set: { option in
                            updateTask { $0.recurrenceRule = option.rule(preserving: $0.recurrenceRule) }
                        }
                    )
                ) {
                    ForEach(AssistantRecurrenceOption.common) { option in
                        Text(option.title).tag(option)
                    }
                    if AssistantRecurrenceOption(rule: value.recurrenceRule) == .custom {
                        Text(AssistantRecurrenceOption.custom.title).tag(AssistantRecurrenceOption.custom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var shoppingFields: some View {
        if case .shopping(let value) = preview {
            Section("Shopping item") {
                TextField("Item", text: shoppingBinding(\.name, in: value))
                TextField("Quantity", text: shoppingOptionalBinding(\.quantity, in: value))
                TextField("Category", text: shoppingOptionalBinding(\.category, in: value))
            }
        }
    }

    private func assigneePicker(
        _ selected: String?,
        onChange: @escaping @MainActor @Sendable (String?) -> Void
    ) -> some View {
        let selection = Binding<String?>(
            get: { selected },
            set: { value in
                // SwiftUI performs Picker binding writes on its main UI
                // executor. Preserve the synchronous state update while making
                // that framework contract explicit to strict concurrency.
                MainActor.assumeIsolated {
                    onChange(value)
                }
            }
        )
        return Picker("For", selection: selection) {
            Text("Everyone").tag(String?.none)
            ForEach(familyMembers) { member in Text(member.name).tag(Optional(member.id)) }
        }
    }

    private var isValid: Bool {
        !preview.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            if await onSave(preview) {
                HapticManager.success()
                dismiss()
            } else {
                errorMessage = "Those changes could not be saved. Check the details and try again."
            }
            isSaving = false
        }
    }

    private func updateCalendar(_ update: (inout CalendarActionPreview) -> Void) {
        guard case .calendar(var value) = preview else { return }
        update(&value); preview = .calendar(value)
    }

    private func updateTask(_ update: (inout TaskActionPreview) -> Void) {
        guard case .task(var value) = preview else { return }
        update(&value); preview = .task(value)
    }

    private func updateShopping(_ update: (inout ShoppingActionPreview) -> Void) {
        guard case .shopping(var value) = preview else { return }
        update(&value); preview = .shopping(value)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<CalendarActionPreview, T>, in value: CalendarActionPreview) -> Binding<T> {
        Binding(get: { value[keyPath: keyPath] }, set: { new in updateCalendar { $0[keyPath: keyPath] = new } })
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<CalendarActionPreview, String?>, in value: CalendarActionPreview) -> Binding<String> {
        Binding(get: { value[keyPath: keyPath] ?? "" }, set: { new in updateCalendar { $0[keyPath: keyPath] = new.isEmpty ? nil : new } })
    }

    private func taskBinding<T>(_ keyPath: WritableKeyPath<TaskActionPreview, T>, in value: TaskActionPreview) -> Binding<T> {
        Binding(get: { value[keyPath: keyPath] }, set: { new in updateTask { $0[keyPath: keyPath] = new } })
    }

    private func taskOptionalBinding(_ keyPath: WritableKeyPath<TaskActionPreview, String?>, in value: TaskActionPreview) -> Binding<String> {
        Binding(get: { value[keyPath: keyPath] ?? "" }, set: { new in updateTask { $0[keyPath: keyPath] = new.isEmpty ? nil : new } })
    }

    private func shoppingBinding<T>(_ keyPath: WritableKeyPath<ShoppingActionPreview, T>, in value: ShoppingActionPreview) -> Binding<T> {
        Binding(get: { value[keyPath: keyPath] }, set: { new in updateShopping { $0[keyPath: keyPath] = new } })
    }

    private func shoppingOptionalBinding(_ keyPath: WritableKeyPath<ShoppingActionPreview, String?>, in value: ShoppingActionPreview) -> Binding<String> {
        Binding(get: { value[keyPath: keyPath] ?? "" }, set: { new in updateShopping { $0[keyPath: keyPath] = new.isEmpty ? nil : new } })
    }

    private func dateBinding(_ value: String, onChange: @escaping (String) -> Void) -> Binding<Date> {
        Binding(
            get: { ISODateParser.parse(value) ?? Date() },
            set: { onChange(ISODateParser.string(from: $0)) }
        )
    }
}
