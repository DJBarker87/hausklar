import SwiftUI

struct FitnessCoachWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var consent = AIConsentViewModel()
    @StateObject private var viewModel = FitnessCoachViewModel()
    @State private var editingPreferences = false
    @State private var memoryManagerExpanded = false
    @State private var editingMemoryId: String?
    @State private var memoryDraft = ""
    @State private var memoryCategoryDraft = ""
    @State private var conversationToDelete: FitnessCoachConversation?
    @State private var confirmingClearAll = false
    @State private var showingPersonalise = false
    @State private var showingRecommendationHistory = false
    @FocusState private var composerFocused:Bool

    var body: some View {
        List {
            consentSection
            if consent.hasConsent {
                conversationSection
                if viewModel.isLoadingStatus || viewModel.runtimeUnavailableMessage != nil || viewModel.errorMessage != nil {
                    coachStatusSection
                }
                recommendationsSection
            }
        }
        .navigationTitle("Coach")
        .toolbar {
            ToolbarItemGroup(placement:.topBarTrailing) {
                Button { showingPersonalise=true } label: { Image(systemName:"slider.horizontal.3") }
                    .accessibilityLabel("Personalise Coach")
                if consent.hasConsent,viewModel.memoryEnabled {
                    Button {
                        Task { await viewModel.startNewConversation(isOnline: networkMonitor.isConnected) }
                    } label: { Image(systemName: "square.and.pencil") }
                    .disabled(!networkMonitor.isConnected || viewModel.isUpdatingMemory)
                    .accessibilityLabel("New private Coach chat")
                } else if consent.hasConsent,!viewModel.messages.isEmpty {
                    Button { viewModel.clearConversation() } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Clear in-memory coaching conversation")
                }
            }
        }
        .task {
            consumeStagedDraftIfPossible()
            await viewModel.loadPreferences(isOnline: networkMonitor.isConnected)
            await viewModel.loadContextState(isOnline: networkMonitor.isConnected)
            await viewModel.loadMemoryState(isOnline: networkMonitor.isConnected)
            await consent.load()
            if consent.hasConsent {
                await viewModel.activateAfterConsent(isOnline: networkMonitor.isConnected)
            } else {
                viewModel.deactivateForMissingConsent()
            }
        }
        .onChange(of: viewModel.needsConsentReload) { _,required in
            guard required else { return }
            Task {
                await consent.load()
                if consent.hasConsent {
                    await viewModel.activateAfterConsent(isOnline: networkMonitor.isConnected)
                } else {
                    viewModel.deactivateForMissingConsent()
                }
            }
        }
        .onChange(of: networkMonitor.isConnected) { _,connected in
            guard connected else { return }
            Task {
                await viewModel.loadPreferences(isOnline: true)
                await viewModel.loadContextState(isOnline: true)
                await viewModel.loadMemoryState(isOnline: true)
                if consent.hasConsent { await viewModel.activateAfterConsent(isOnline: true) }
            }
        }
        .onChange(of:appState.fitnessCoachDraftNonce) { _,_ in consumeStagedDraftIfPossible() }
        .onChange(of:viewModel.inputText) { _,value in
            if value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                consumeStagedDraftIfPossible()
            }
        }
        .refreshable {
            await viewModel.loadRemote()
        }
        .sheet(isPresented:$showingPersonalise) {
            NavigationStack {
                List {
                    contextPreferencesSection
                    privateRemindersSection
                    preferencesSection
                    memoryControlSection
                    if viewModel.memoryEnabled || !viewModel.conversations.isEmpty || !viewModel.memories.isEmpty {
                        conversationMemorySection
                    }
                }
                .navigationTitle("Personalise")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { showingPersonalise=false } } }
            }
        }
        .confirmationDialog(
            "Delete this saved chat?",isPresented: Binding(
                get: { conversationToDelete != nil },set: { if !$0 { conversationToDelete=nil } }
            ),presenting: conversationToDelete
        ) { conversation in
            Button("Delete chat",role: .destructive) {
                Task {
                    await viewModel.deleteConversation(conversation,isOnline: networkMonitor.isConnected)
                    conversationToDelete=nil
                }
            }
            Button("Cancel",role: .cancel) { conversationToDelete=nil }
        } message: { _ in
            Text("This deletes the stored transcript. Confirmed memories are managed separately.")
        }
        .confirmationDialog("Clear all Coach memory?",isPresented: $confirmingClearAll) {
            Button("Clear memories and saved chats",role: .destructive) {
                Task { _ = await viewModel.clearAllMemory(isOnline: networkMonitor.isConnected) }
            }
            Button("Cancel",role: .cancel) {}
        } message: {
            Text("This permanently clears confirmed memories and every saved Coach conversation for this account.")
        }
    }

    @ViewBuilder private var contextPreferencesSection:some View {
        Section {
            if let preferences=viewModel.contextPreferences {
                contextToggle(
                    "Family Calendar",detail:"The next seven days",
                    option:.familyCalendar,value:preferences.familyCalendar
                )
                contextToggle(
                    "Household meal plan",detail:"Planned family meals",
                    option:.householdMeals,value:preferences.householdMeals
                )
                contextToggle(
                    "Relevant weather",detail:"Useful conditions for outdoor plans",
                    option:.weather,value:preferences.weather
                )
            } else if viewModel.isLoadingContext {
                HStack { ProgressView(); Text("Loading context choices…") }
                    .foregroundStyle(.secondary)
            } else {
                Text("Context choices are unavailable right now.").foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await viewModel.loadContextState(isOnline:networkMonitor.isConnected) }
                }
            }
            if let error=viewModel.contextError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("What Coach can consider")
        } footer: {
            Text("Fitness is always included. These optional family details are considered only after you press Send.")
        }
    }

    private func contextToggle(
        _ title:String,detail:String,option:FitnessCoachContextOption,value:Bool
    ) -> some View {
        Toggle(isOn:Binding(
            get:{ value },
            set:{ enabled in
                Task {
                    await viewModel.setContext(
                        option,enabled:enabled,isOnline:networkMonitor.isConnected
                    )
                }
            }
        )) {
            VStack(alignment:.leading,spacing:2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight:44)
        .disabled(!networkMonitor.isConnected || viewModel.isUpdatingContext)
    }

    @ViewBuilder private var privateRemindersSection:some View {
        Section("Private reminders") {
            if viewModel.reminders.isEmpty,!viewModel.isLoadingContext {
                Text("No reminders yet.").foregroundStyle(.secondary)
            }
            ForEach(viewModel.reminders) { reminder in
                HStack(spacing:10) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(reminder.title)
                        Text(FitnessDisplay.date(reminder.remindAtUtc))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                    Button(role:.destructive) {
                        Task {
                            await viewModel.deleteReminder(
                                reminder,isOnline:networkMonitor.isConnected
                            )
                        }
                    } label: {
                        Image(systemName:"trash").frame(minWidth:44,minHeight:44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!networkMonitor.isConnected || viewModel.isUpdatingContext)
                    .accessibilityLabel("Delete reminder \(reminder.title)")
                }
            }
        }
    }

    @ViewBuilder private var preferencesSection: some View {
        Section {
            if let saved = viewModel.preferences,!editingPreferences {
                LabeledContent("Style",value: saved.personalityPreset.label)
                Text("Directness \(saved.directness)/5 · \(saved.challengeBias.label) challenge · \(saved.detailLevel.label) detail")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Personalise") { editingPreferences = true }
            } else if viewModel.preferences == nil,!editingPreferences {
                Text(viewModel.preferencesError ?? "Loading your saved coach style…")
                    .foregroundStyle(.secondary)
                if networkMonitor.isConnected {
                    Button("Try again") { Task { await viewModel.loadPreferences(isOnline: true) } }
                }
            }
            if editingPreferences {
                Picker("Preset",selection: Binding(
                    get: { viewModel.preferenceDraft.personalityPreset },
                    set: { viewModel.selectPreset($0) }
                )) {
                    ForEach(FitnessCoachPersonalityPreset.allCases) { Text($0.label).tag($0) }
                }
                Stepper(
                    "Directness \(viewModel.preferenceDraft.directness)/5",
                    value: Binding(
                        get: { viewModel.preferenceDraft.directness },
                        set: { viewModel.preferenceDraft.directness=$0; viewModel.markPreferencesCustom() }
                    ),in: 1...5
                )
                Picker("Challenge",selection: Binding(
                    get: { viewModel.preferenceDraft.challengeBias },
                    set: { viewModel.preferenceDraft.challengeBias=$0; viewModel.markPreferencesCustom() }
                )) { ForEach(FitnessCoachChallengeBias.allCases) { Text($0.label).tag($0) } }
                Picker("Detail",selection: Binding(
                    get: { viewModel.preferenceDraft.detailLevel },
                    set: { viewModel.preferenceDraft.detailLevel=$0; viewModel.markPreferencesCustom() }
                )) { ForEach(FitnessCoachDetailLevel.allCases) { Text($0.label).tag($0) } }
                TextField("Custom instruction",text: Binding(
                    get: { viewModel.preferenceDraft.customInstruction ?? "" },
                    set: { viewModel.preferenceDraft.customInstruction=String($0.prefix(500)); viewModel.markPreferencesCustom() }
                ),axis: .vertical)
                Text("\(viewModel.preferenceDraft.customInstruction?.count ?? 0)/500")
                    .font(.caption2).foregroundStyle(.secondary)
                if let error=viewModel.preferencesError { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Save style") {
                        Task { if await viewModel.savePreferences(isOnline: networkMonitor.isConnected) { editingPreferences=false } }
                    }
                    .disabled(!networkMonitor.isConnected || viewModel.isSavingPreferences || !viewModel.preferenceDraft.isValid)
                    Button("Cancel",role: .cancel) {
                        viewModel.preferenceDraft=viewModel.preferences ?? .balanced
                        editingPreferences=false
                    }
                }
            }
        } header: {
            Text("Your coach’s style")
        } footer: {
            Text("Private to your account.")
        }
    }

    @ViewBuilder private var memoryControlSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.memoryEnabled },
                set: { enabled in
                    Task {
                        await viewModel.setMemoryEnabled(
                            enabled,isOnline: networkMonitor.isConnected
                        )
                    }
                }
            )) {
                VStack(alignment: .leading,spacing: 3) {
                    Text("Private Coach memory")
                    Text(viewModel.memoryEnabled ? "On for this signed-in account" : "Off — chats stay in memory only")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .disabled(!networkMonitor.isConnected || viewModel.isUpdatingMemory)
            if viewModel.isLoadingMemory {
                HStack { ProgressView(); Text("Loading private memory…") }
                    .foregroundStyle(.secondary)
            }
            if let notice=viewModel.memoryNotice {
                Label(notice,systemImage: "checkmark.shield.fill")
                    .font(.caption).foregroundStyle(.teal)
            }
            if let error=viewModel.memoryError {
                Label(error,systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Continuity")
        } footer: {
            Text("Optional and off by default. Turn this on only if you want resumable chats and details you explicitly choose to remember.")
        }
    }

    @ViewBuilder private var consentSection: some View {
        if consent.isLoading {
            Section { HStack { Spacer(); ProgressView("Checking your AI privacy choice…"); Spacer() } }
        } else if let status = consent.status,!status.consented {
            Section {
                Label("Allow Fitness Coach to use OpenAI?",systemImage: "brain.head.profile")
                    .font(.headline).foregroundStyle(.teal)
                Text(status.disclosure).foregroundStyle(.secondary)
                Label("Only when you deliberately send a message",systemImage: "checkmark.shield")
                Label("No unattended or nightly AI processing",systemImage: "moon.zzz")
                Label("Every proposed change is reviewed before saving",systemImage: "doc.text.magnifyingglass")
                if let privacyURL = SafeExternalURL.web("https://hausklar.example.invalid/privacy-policy") {
                    Link("Read the privacy policy",destination: privacyURL)
                }
                if let error = consent.errorMessage {
                    Label(error,systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button {
                    Task {
                        await consent.grant()
                        if consent.hasConsent {
                            await viewModel.activateAfterConsent(isOnline: networkMonitor.isConnected)
                        }
                    }
                } label: {
                    if consent.isSaving { ProgressView() } else { Label("Allow and continue",systemImage: "hand.raised.fill") }
                }
                .disabled(consent.isSaving || !networkMonitor.isConnected)
            } header: {
                Text("Your choice")
            } footer: {
                Text("This is the same account permission used by Bismarck. After you accept the current privacy notice, HausKlar does not ask again for every message or Fitness visit.")
            }
        } else if consent.status == nil {
            Section {
                Label(consent.errorMessage ?? "AI privacy settings could not be loaded.",systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try again") { Task { await consent.load() } }
            }
        }
    }

    @ViewBuilder private var coachStatusSection: some View {
        Section {
            if viewModel.isLoadingStatus {
                HStack { ProgressView(); Text("Getting Coach ready…") }
                    .foregroundStyle(.secondary)
            }
            if let unavailable = viewModel.runtimeUnavailableMessage {
                Label(unavailable,systemImage: networkMonitor.isConnected ? "bolt.slash" : "wifi.slash")
                    .foregroundStyle(.secondary)
                if networkMonitor.isConnected {
                    Button("Check again") { Task { await viewModel.loadRemote() } }
                }
            } else if viewModel.status?.status == .available {
                Label("Fitness Coach available",systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let error = viewModel.errorMessage {
                Label(error,systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Button("Try last message again") {
                    Task { await viewModel.retry(isOnline: networkMonitor.isConnected) }
                }
                .disabled(viewModel.isSending)
            }
        }
    }

    @ViewBuilder private var conversationMemorySection: some View {
        Section {
            Button {
                Task { await viewModel.startNewConversation(isOnline: networkMonitor.isConnected) }
            } label: {
                Label("New chat",systemImage: "square.and.pencil")
            }
            .frame(minHeight: 44)
            .disabled(
                !viewModel.memoryEnabled || !networkMonitor.isConnected || viewModel.isUpdatingMemory
            )

            if !viewModel.memoryEnabled {
                Text("Memory is off. Existing items remain available to review, edit or delete; new chats and memories are not stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if viewModel.conversations.isEmpty,!viewModel.isLoadingMemory {
                Text("No saved chats yet. The first successful message can create one automatically.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.conversations.prefix(10)) { conversation in
                HStack(spacing: 10) {
                    Button {
                        Task {
                            await viewModel.resumeConversation(
                                conversation,isOnline: networkMonitor.isConnected
                            )
                        }
                    } label: {
                        VStack(alignment: .leading,spacing: 3) {
                            HStack {
                                Text(conversation.title.isEmpty ? "Coach chat" : conversation.title)
                                    .font(.subheadline.weight(.semibold))
                                if viewModel.currentConversationId == conversation.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
                                }
                            }
                            Text(FitnessDisplay.date(conversation.lastMessageAt ?? conversation.updatedAt))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity,minHeight: 44,alignment: .leading)
                    }
                    .buttonStyle(.plain).disabled(!networkMonitor.isConnected || viewModel.isLoadingMemory)
                    Button(role: .destructive) { conversationToDelete=conversation } label: {
                        Image(systemName: "trash").frame(minWidth: 44,minHeight: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Delete saved Coach chat")
                }
            }

            DisclosureGroup(isExpanded: $memoryManagerExpanded) {
                if viewModel.memories.isEmpty {
                    Text("No confirmed memories. Suggestions remain temporary until you choose Remember.")
                        .foregroundStyle(.secondary).padding(.vertical,6)
                }
                ForEach(viewModel.memories) { memory in
                    VStack(alignment: .leading,spacing: 8) {
                        if editingMemoryId == memory.id {
                            TextField("Memory",text: $memoryDraft,axis: .vertical)
                            TextField("Category (optional)",text: $memoryCategoryDraft)
                            HStack {
                                Button("Save") {
                                    Task {
                                        if await viewModel.updateMemory(
                                            memory,content: memoryDraft,category: memoryCategoryDraft,
                                            isOnline: networkMonitor.isConnected
                                        ) {
                                            editingMemoryId=nil
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    !networkMonitor.isConnected || viewModel.isUpdatingMemory
                                        || memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                )
                                Button("Cancel",role: .cancel) { editingMemoryId=nil }
                                    .buttonStyle(.bordered)
                            }
                        } else {
                            Text(memory.content)
                            if let category=memory.category,!category.isEmpty {
                                Text(category.replacingOccurrences(of: "_",with: " ").capitalized)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Edit",systemImage: "pencil") {
                                    editingMemoryId=memory.id; memoryDraft=memory.content
                                    memoryCategoryDraft=memory.category ?? ""
                                }
                                .buttonStyle(.bordered)
                                .disabled(!networkMonitor.isConnected || viewModel.isUpdatingMemory)
                                Button("Forget",role: .destructive) {
                                    Task {
                                        await viewModel.forgetMemory(
                                            memory,isOnline: networkMonitor.isConnected
                                        )
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!networkMonitor.isConnected || viewModel.isUpdatingMemory)
                            }
                        }
                    }
                    .padding(.vertical,6)
                }
                if !viewModel.memories.isEmpty || !viewModel.conversations.isEmpty {
                    Button("Clear all memories and saved chats",role: .destructive) {
                        confirmingClearAll=true
                    }
                    .frame(minHeight: 44)
                    .disabled(!networkMonitor.isConnected || viewModel.isUpdatingMemory)
                }
            } label: {
                Label("Manage confirmed memory (\(viewModel.memories.count))",systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.semibold))
            }
        } header: {
            Text("Private continuity")
        } footer: {
            Text("Turning memory off stops new storage. Existing items remain editable until you remove them.")
        }
    }

    @ViewBuilder private var conversationSection: some View {
        Section {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:8) {
                    ForEach(viewModel.advertisedIntents) { intent in
                        Button {
                            viewModel.chooseIntent(intent)
                            composerFocused=true
                        } label: {
                            Label(intent.label,systemImage:intent.icon)
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight:44)
                                .padding(.horizontal,10)
                        }
                        .buttonStyle(.bordered)
                        .tint(viewModel.intent == intent ? .accentColor : .secondary)
                        .accessibilityHint("Starts this question in the composer")
                    }
                }
                .padding(.vertical,2)
            }
            .listRowInsets(EdgeInsets(top:4,leading:12,bottom:4,trailing:12))

            HStack(alignment:.bottom,spacing:8) {
                TextField(
                    "Ask about training, food or recovery",
                    text:$viewModel.inputText,
                    axis:.vertical
                )
                .lineLimit(2...4)
                .focused($composerFocused)
                .textFieldStyle(.plain)
                .padding(.horizontal,12)
                .padding(.vertical,10)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:12,style:.continuous)
                )
                .submitLabel(.send)
                .onSubmit {
                    guard viewModel.canSend,networkMonitor.isConnected else { return }
                    Task { await viewModel.send(isOnline:true) }
                }
                Button {
                    Task { await viewModel.send(isOnline:networkMonitor.isConnected) }
                } label: {
                    Group {
                        if viewModel.isSending { ProgressView().tint(.white) }
                        else { Image(systemName:"arrow.up").font(.body.bold()) }
                    }
                    .foregroundStyle(.white)
                    .frame(width:44,height:44)
                    .background(
                        viewModel.canSend && networkMonitor.isConnected
                            ? Color.accentColor : Color.secondary,
                        in:Circle()
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    !viewModel.canSend || !networkMonitor.isConnected
                        || viewModel.inputText.count > 2_000
                )
                .accessibilityLabel(viewModel.isSending ? "Sending message" : "Send message")
            }
            if viewModel.inputText.count > 2_000 {
                Text("Keep the message under 2,000 characters.")
                    .font(.caption).foregroundStyle(.red)
            } else if !networkMonitor.isConnected {
                Text("Reconnect to send. Your draft stays here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if viewModel.messages.isEmpty {
                Text("Try a starter above, or ask your own question.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(viewModel.messages) { message in
                FitnessCoachMessageView(
                    message: message,
                    isOnline: networkMonitor.isConnected,
                    isDeciding: message.proposal.map { viewModel.decidingProposalIds.contains($0.id) } ?? false,
                    memoryEnabled: viewModel.memoryEnabled,
                    rememberingCandidateKeys: viewModel.rememberingCandidateKeys,
                    rememberedCandidateKeys: viewModel.rememberedCandidateKeys,
                    decide: { action in
                        guard let proposal = message.proposal else { return }
                        Task {
                            await viewModel.decide(
                                messageId: message.id,proposal: proposal,action: action,
                                isOnline: networkMonitor.isConnected
                            )
                        }
                    },undo: {
                        guard let proposal=message.proposal else { return }
                        Task {
                            await viewModel.undo(
                                messageId:message.id,proposal:proposal,
                                isOnline:networkMonitor.isConnected
                            )
                        }
                    },edit: {
                        guard let proposal=message.proposal else { return }
                        if viewModel.seedEdit(of:proposal) { composerFocused=true }
                    },remember: { candidate in
                        Task {
                            await viewModel.remember(candidate,isOnline: networkMonitor.isConnected)
                        }
                    }
                )
            }
        } header: {
            Text("Ask your Fitness coach")
        } footer: {
            Text("Reminders and coaching only — not medical advice.")
        }
    }

    @ViewBuilder private var recommendationsSection: some View {
        Section {
            if viewModel.recommendations.isEmpty {
                Text("Useful recommendations appear here after a coaching response.")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Recommendation history",isExpanded:$showingRecommendationHistory) {
            ForEach(viewModel.recommendations.prefix(12)) { recommendation in
                VStack(alignment: .leading,spacing: 8) {
                    Text(recommendation.recommendationText).font(.headline)
                    HStack {
                        if let createdAt = recommendation.createdAt {
                            Text(FitnessDisplay.date(createdAt))
                        }
                        Text(recommendation.status.replacingOccurrences(of: "_",with: " ").capitalized)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let outcome = recommendation.outcomeReview {
                        Text("Outcome: \(outcome)").font(.caption)
                    }
                    Picker(
                        "Outcome",
                        selection: Binding(
                            get: { viewModel.feedbackSelections[recommendation.id] ?? recommendation.userFeedback ?? .accepted },
                            set: { viewModel.selectFeedback($0,for: recommendation.id) }
                        )
                    ) {
                        ForEach(FitnessCoachFeedback.allCases) { Text($0.label).tag($0) }
                    }
                    Button {
                        Task { await viewModel.saveFeedback(for: recommendation,isOnline: networkMonitor.isConnected) }
                    } label: {
                        if viewModel.savingFeedbackIds.contains(recommendation.id) {
                            ProgressView()
                        } else {
                            Label("Save outcome",systemImage: "checkmark.circle")
                        }
                    }
                    .disabled(!networkMonitor.isConnected || viewModel.savingFeedbackIds.contains(recommendation.id))
                }
            }
            }
        } footer: {
            Text("Past recommendation outcomes stay secondary to the current conversation and next action.")
        }
    }

    private func consumeStagedDraftIfPossible() {
        guard let nonce=appState.fitnessCoachDraftNonce,
              let handoff=appState.consumeFitnessCoachHandoff(
                nonce:nonce,currentDraft:viewModel.inputText
              ) else { return }
        viewModel.applyDraftHandoff(handoff)
        composerFocused=true
    }
}

private struct FitnessCoachMessageView: View {
    let message: FitnessCoachChatMessage
    let isOnline: Bool
    let isDeciding: Bool
    let memoryEnabled: Bool
    let rememberingCandidateKeys: Set<String>
    let rememberedCandidateKeys: Set<String>
    let decide: (FitnessCoachProposalAction) -> Void
    let undo: () -> Void
    let edit: () -> Void
    let remember: (FitnessCoachMemoryCandidate) -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading,spacing: 9) {
            Text(message.role == .assistant ? "Coach" : "You")
                .font(.caption.bold()).foregroundStyle(.secondary)
            Text(message.content)
                .padding(11)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.14) : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if message.role == .assistant {
                if let recommendation = message.recommendation {
                    Text(recommendation.recommendationText)
                        .font(.subheadline)
                        .padding(10)
                        .background(Color.teal.opacity(0.1),in: RoundedRectangle(cornerRadius: 10))
                }
                if let proposal = message.proposal {
                    FitnessCoachProposalView(
                        proposal:proposal,decision:message.proposalDecision,
                        undoResult:message.proposalUndo,isOnline:isOnline,
                        isDeciding:isDeciding,decide:decide,undo:undo,edit:edit
                    )
                }
                if memoryEnabled,!message.memoryCandidates.isEmpty {
                    GroupBox("Possible memory — not saved") {
                        VStack(alignment: .leading,spacing: 10) {
                            ForEach(Array(message.memoryCandidates.enumerated()),id: \.offset) { _,candidate in
                                VStack(alignment: .leading,spacing: 5) {
                                    if let category=candidate.category,!category.isEmpty {
                                        Text(category.replacingOccurrences(of: "_",with: " ").capitalized)
                                            .font(.caption.bold()).foregroundStyle(.secondary)
                                    }
                                    Text(candidate.content).font(.subheadline)
                                    Button {
                                        remember(candidate)
                                    } label: {
                                        if rememberingCandidateKeys.contains(candidate.key) {
                                            ProgressView()
                                        } else if rememberedCandidateKeys.contains(candidate.key) {
                                            Label("Remembered",systemImage: "checkmark.circle.fill")
                                        } else {
                                            Label("Remember",systemImage: "brain.head.profile")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: 44)
                                    .disabled(
                                        !isOnline || rememberingCandidateKeys.contains(candidate.key)
                                            || rememberedCandidateKeys.contains(candidate.key)
                                    )
                                }
                            }
                            Text("HausKlar stores none of these suggestions unless you confirm one.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity,alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity,alignment: message.role == .user ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct FitnessCoachProposalView: View {
    @EnvironmentObject private var appState:AppState
    let proposal: FitnessCoachProposal
    let decision: FitnessCoachProposalDecision?
    let undoResult: FitnessCoachProposalUndo?
    let isOnline: Bool
    let isDeciding: Bool
    let decide: (FitnessCoachProposalAction) -> Void
    let undo: () -> Void
    let edit: () -> Void
    @State private var showingAllDestinations=false

    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Label(proposal.kind.label,systemImage:"doc.text.magnifyingglass")
                .font(.headline)
            if let review=proposal.humanReview,review.isComplete {
                ForEach(Array(review.change.enumerated()),id:\.offset) { _,change in
                    HStack(alignment:.top,spacing:8) {
                        Image(systemName:"checkmark.circle")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(change).frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
                Label(
                    review.visibility.rawValue,
                    systemImage:review.visibility == .privateToYou ? "person.example_e864bc8d" : "house.fill"
                )
                .font(.subheadline.weight(.semibold))
            } else {
                Text("Ask Coach to make this suggestion again before saving it.")
                    .foregroundStyle(.secondary)
            }
            if let decision {
                Label(decision.message,systemImage: decision.status == .confirmed ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(decision.status == .confirmed ? .green : .secondary)
                if decision.status == .confirmed {
                    confirmationActions
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { decisionButtons }
                    VStack(alignment: .leading) { decisionButtons }
                }
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08),in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var confirmationActions: some View {
        if let undoResult {
            Label(
                undoResult.message,
                systemImage:undoResult.succeeded ? "arrow.uturn.backward.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption).foregroundStyle(undoResult.succeeded ? .green : .orange)
        }
        if undoResult?.succeeded != true {
            ViewThatFits(in:.horizontal) {
                HStack { destinationActions; undoButton }
                VStack(alignment:.leading) { destinationActions; undoButton }
            }
        }
    }

    @ViewBuilder private var destinationActions: some View {
        if let destinations=decision?.nextDestinations {
            let routable=destinations.filter { $0.kind.isKnown }
            let visible=showingAllDestinations ? routable : Array(routable.prefix(3))
            ForEach(visible) { destination in
                Button {
                    _=appState.openFitnessCoachDestination(destination)
                } label: {
                    Label(destination.label,systemImage:destinationIcon(destination.kind))
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight:44)
            }
            if routable.count > 3 {
                Button {
                    withAnimation(.snappy) { showingAllDestinations.toggle() }
                } label: {
                    Label(
                        showingAllDestinations
                            ? "Show fewer results"
                            : "More results (\(routable.count - 3))",
                        systemImage:showingAllDestinations ? "chevron.up" : "ellipsis.circle"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func destinationIcon(_ kind:FitnessCoachProposalDestinationKind) -> String {
        switch kind {
        case .plannedSession:"calendar"
        case .nutritionTarget:"target"
        case .mealTemplate:"fork.knife"
        case .goal:"flag"
        case .analysisChart:"chart.xyaxis.line"
        case .calendarEvent:"calendar"
        case .foodLog:"fork.knife"
        case .shopping:"cart"
        case .task:"checklist"
        case .fitnessReminder:"bell"
        case .unknown:"questionmark.circle"
        }
    }

    private var undoButton: some View {
        Button("Undo",systemImage:"arrow.uturn.backward",role:.destructive,action:undo)
            .buttonStyle(.bordered)
            .disabled(!isOnline || isDeciding)
    }

    @ViewBuilder private var decisionButtons: some View {
        Button {
            decide(.confirm)
        } label: {
            if isDeciding {
                HStack(spacing: 8) { ProgressView(); Text("Saving…") }
            } else {
                Label("Confirm",systemImage: "checkmark")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isOnline || isDeciding || !proposal.canConfirm)
        .accessibilityLabel(isDeciding ? "Confirming proposal" : "Confirm proposal")
        Button("Edit",systemImage:"pencil",action:edit)
            .buttonStyle(.bordered)
            .disabled(isDeciding || !proposal.canEdit)
        Button("Discard",role: .destructive) { decide(.decline) }
            .buttonStyle(.bordered)
            .disabled(!isOnline || isDeciding || proposal.isExpired)
    }
}

private struct FitnessCoachStartConfirmedSessionButton:View {
    let sessionId:String
    @StateObject private var training=FitnessTrainingViewModel()
    @StateObject private var hub=FitnessHubViewModel()
    @State private var showingStrength=false

    var body:some View {
        Button("Start",systemImage:"play.fill") {
            guard let plan=training.plans.first(where:{ $0.id == sessionId }) else { return }
            Task { if await hub.start(plan) { showingStrength=true } }
        }
        .buttonStyle(.bordered)
        .disabled(training.plans.first(where:{ $0.id == sessionId }) == nil || hub.isLoading)
        .task { if training.plans.isEmpty { await training.load() } }
        .navigationDestination(isPresented:$showingStrength) { FitnessStrengthView() }
        .accessibilityHint("Starts the exact confirmed planned session")
    }
}

struct FitnessCoachSavedDestinationView:View {
    @EnvironmentObject private var networkMonitor:NetworkMonitor
    let destination:FitnessCoachProposalDestination
    @StateObject private var training=FitnessTrainingViewModel()
    @StateObject private var nutrition=FitnessNutritionViewModel()
    @StateObject private var analysis=FitnessAnalysisViewModel()
    @StateObject private var coach=FitnessCoachViewModel()
    @State private var editingPlan:FitnessPlannedSession?

    var body:some View {
        List {
            switch destination.kind {
            case .plannedSession:plannedSession
            case .goal:goal
            case .nutritionTarget:nutritionTarget
            case .mealTemplate:mealTemplate
            case .analysisChart:analysisChart
            case .foodLog:foodLog
            case .fitnessReminder:fitnessReminder
            case .calendarEvent,.shopping,.task,.unknown:
                unavailable("This result belongs in another HausKlar module.")
            }
        }
        .navigationTitle(destination.label)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item:$editingPlan) { FitnessPlannedSessionEditorSheet(viewModel:training,session:$0) }
        .task {
            switch destination.kind {
            case .plannedSession,.goal:await training.load()
            case .nutritionTarget,.mealTemplate:await nutrition.load()
            case .analysisChart:await analysis.load()
            case .foodLog:await nutrition.loadLogHome()
            case .fitnessReminder:
                await coach.loadContextState(isOnline:networkMonitor.isConnected)
            case .calendarEvent,.shopping,.task,.unknown:break
            }
        }
    }

    @ViewBuilder private var plannedSession:some View {
        if let plan=training.plans.first(where:{ $0.id == destination.target }) {
            Section("Confirmed session") {
                Text(plan.title).font(.headline)
                LabeledContent("Sport",value:plan.sportKey.capitalized)
                LabeledContent("Status",value:plan.status.replacingOccurrences(of:"_",with:" ").capitalized)
                if let date=plan.scheduledStart ?? plan.timeWindowStart ?? plan.plannedFor {
                    LabeledContent("When",value:date.formatted(date:.abbreviated,time:.shortened))
                }
                Button("Edit or move",systemImage:"calendar.badge.clock") { editingPlan=plan }
            }
            Section {
                if plan.sportKey == "strength" {
                    FitnessCoachStartConfirmedSessionButton(sessionId:plan.id)
                } else if plan.sportKey == "running" {
                    NavigationLink { FitnessRunPlansView() } label: {
                        Label("Open run details",systemImage:"figure.run")
                    }
                }
                NavigationLink { FitnessTrainingView() } label: {
                    Label("Open in Plan",systemImage:"calendar")
                }
            }
        } else { unavailable("That confirmed session is not in the local Fitness store yet.") }
    }
    @ViewBuilder private var goal:some View {
        if let value=training.goals.first(where:{ $0.id == destination.target }) {
            Section("Confirmed goal") {
                Text(value.title).font(.headline)
                LabeledContent("Measure",value:value.metric.replacingOccurrences(of:"_",with:" ").capitalized)
                if let target=value.targetValue { LabeledContent("Target",value:"\(target.formatted()) \(value.unit ?? "")") }
                NavigationLink { FitnessTrainingView() } label: {
                    Label("Open in Plan",systemImage:"calendar")
                }
            }
        } else { unavailable("That goal is not in the local Fitness store yet.") }
    }
    @ViewBuilder private var nutritionTarget:some View {
        if let value=nutrition.targets.first(where:{ $0.id == destination.target }) {
            Section("Confirmed nutrition target") {
                Text(value.metric.title).font(.headline)
                LabeledContent("Mode",value:value.mode.title)
                NavigationLink { FitnessLogHomeView() } label: { Label("Open Log",systemImage:"fork.knife") }
            }
        } else { unavailable("That nutrition target is not in the local Food store yet.") }
    }
    @ViewBuilder private var mealTemplate:some View {
        if let value=nutrition.templates.first(where:{ $0.id == destination.target }) {
            Section("Confirmed meal template") {
                Text(value.name).font(.headline)
                LabeledContent("Meal",value:value.meal.title)
                LabeledContent("Items",value:"\(value.items.count)")
                NavigationLink { FitnessLogHomeView() } label: { Label("Open Log",systemImage:"fork.knife") }
            }
        } else { unavailable("That meal template is not in the local Food store yet.") }
    }
    @ViewBuilder private var analysisChart:some View {
        if let value=analysis.savedCharts.first(where:{ $0.id == destination.target }) {
            Section("Confirmed analysis") {
                Text(value.name).font(.headline)
                LabeledContent("Measure",value:value.measureKey.replacingOccurrences(of:"_",with:" ").capitalized)
                NavigationLink { FitnessAnalysisView() } label: {
                    Label("Open analysis",systemImage:"chart.xyaxis.line")
                }
            }
        } else { unavailable("That saved analysis is not available locally yet.") }
    }
    @ViewBuilder private var foodLog:some View {
        if let value=nutrition.day.entries.first(where:{ $0.id == destination.target }) {
            Section("Diary entry") {
                Text(value.foodName).font(.headline)
                LabeledContent("Meal",value:value.meal.title)
                LabeledContent("Logged",value:value.loggedAt.formatted(date:.abbreviated,time:.shortened))
                if let kcal=value.kcal {
                    LabeledContent("Energy",value:"\(kcal.formatted(.number.precision(.fractionLength(0)))) kcal")
                }
                NavigationLink { FitnessLogHomeView() } label: {
                    Label("Open diary",systemImage:"fork.knife")
                }
            }
        } else { unavailable("That diary entry is not available locally yet.") }
    }
    @ViewBuilder private var fitnessReminder:some View {
        if let value=coach.reminders.first(where:{ $0.id == destination.target }) {
            Section("Reminder") {
                Text(value.title).font(.headline)
                LabeledContent("When",value:FitnessDisplay.date(value.remindAtUtc))
                if let notes=value.notes,!notes.isEmpty { Text(notes).foregroundStyle(.secondary) }
            }
        } else { unavailable("That reminder is not available yet.") }
    }
    private func unavailable(_ message:String) -> some View {
        Section {
            if training.isLoading || nutrition.isLoading || analysis.isLoading || coach.isLoadingContext {
                ProgressView("Loading saved result…")
            }
            else { ContentUnavailableView("Saved result unavailable",systemImage:"arrow.triangle.2.circlepath",description:Text(message)) }
        }
    }
}
