import Foundation

@MainActor
final class FitnessCoachViewModel: ObservableObject {
    static let maximumInMemoryTurns = 8
    static let maximumVisibleStoredMessages = 100

    @Published var status: FitnessCoachStatus?
    @Published var recommendations: [FitnessCoachRecommendation] = []
    @Published var preferences: FitnessCoachPreferences?
    @Published var preferenceDraft = FitnessCoachPreferences.balanced
    @Published var isSavingPreferences = false
    @Published var preferencesError: String?
    @Published var messages: [FitnessCoachChatMessage] = []
    @Published var intent: FitnessCoachIntent = .discussion
    @Published var inputText = ""
    @Published var isLoadingStatus = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var runtimeUnavailableMessage: String?
    @Published var needsConsentReload = false
    @Published var feedbackSelections: [String: FitnessCoachFeedback] = [:]
    @Published private(set) var decidingProposalIds: Set<String> = []
    @Published private(set) var savingFeedbackIds: Set<String> = []
    @Published private(set) var hasCurrentConsent = false
    @Published private(set) var memorySettings: FitnessCoachMemorySettings?
    @Published private(set) var conversations: [FitnessCoachConversation] = []
    @Published private(set) var currentConversationId: String?
    @Published private(set) var memories: [FitnessCoachMemory] = []
    @Published private(set) var isLoadingMemory = false
    @Published private(set) var isUpdatingMemory = false
    @Published var memoryError: String?
    @Published var memoryNotice: String?
    @Published private(set) var rememberingCandidateKeys: Set<String> = []
    @Published private(set) var rememberedCandidateKeys: Set<String> = []
    @Published private(set) var contextPreferences: FitnessCoachContextPreferences?
    @Published private(set) var reminders: [FitnessCoachReminder] = []
    @Published private(set) var isLoadingContext = false
    @Published private(set) var isUpdatingContext = false
    @Published var contextError: String?

    private let service: FitnessCoachService
    private let ephemeralMessages: Bool
    private var lastFailedMessage: String?
    private var pendingContextIds: [String] = []

    init(
        service: FitnessCoachService = .shared,
        ephemeralMessages: Bool = false
    ) {
        self.service = service
        self.ephemeralMessages = ephemeralMessages
    }

    var advertisedIntents: [FitnessCoachIntent] {
        let values = status?.intents
        return values?.isEmpty == false ? FitnessCoachIntent.allCases.filter { values?.contains($0) == true } : FitnessCoachIntent.allCases
    }

    var canSend: Bool {
        hasCurrentConsent
            && status?.status == .available
            && !isSending
            && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var memoryEnabled: Bool {
        memorySettings?.enabled ?? preferences?.coachMemoryEnabled ?? false
    }

    /// Owner-private communication style is ordinary authenticated account data;
    /// loading or saving it does not invoke Hermes and does not require AI consent.
    func loadPreferences(isOnline: Bool) async {
        guard isOnline else {
            if preferences == nil { preferencesError = "Reconnect to load your saved coach style." }
            return
        }
        do {
            let value = try await service.preferences()
            preferences = value
            preferenceDraft = value
            if memorySettings == nil,let enabled=value.coachMemoryEnabled {
                memorySettings=FitnessCoachMemorySettings(
                    enabled: enabled,enabledAt: value.coachMemoryEnabledAt
                )
            }
            preferencesError = nil
        } catch {
            preferencesError = error.localizedDescription
        }
    }

    func selectPreset(_ preset: FitnessCoachPersonalityPreset) {
        preferenceDraft.personalityPreset = preset
        let defaults = preset.defaults
        preferenceDraft.directness = defaults.directness
        preferenceDraft.challengeBias = defaults.challenge
        preferenceDraft.detailLevel = defaults.detail
    }

    func markPreferencesCustom() { preferenceDraft.personalityPreset = .custom }

    func savePreferences(isOnline: Bool) async -> Bool {
        guard isOnline,preferenceDraft.isValid,!isSavingPreferences else { return false }
        isSavingPreferences = true
        preferencesError = nil
        defer { isSavingPreferences = false }
        do {
            var value = preferenceDraft
            value.customInstruction = value.customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.customInstruction?.isEmpty == true { value.customInstruction = nil }
            let saved = try await service.updatePreferences(value)
            preferences = saved
            preferenceDraft = saved
            HapticManager.success()
            return true
        } catch {
            preferencesError = error.localizedDescription
            return false
        }
    }

    func loadContextState(isOnline: Bool) async {
        guard isOnline,!isLoadingContext else { return }
        isLoadingContext=true
        contextError=nil
        defer { isLoadingContext=false }

        var failures:[String]=[]
        do {
            contextPreferences=try await service.contextPreferences()
        } catch {
            failures.append("Your Coach context choices couldn't be loaded.")
        }
        do {
            reminders=try await service.reminders()
        } catch {
            failures.append("Your reminders couldn't be loaded.")
        }
        contextError=failures.isEmpty ? nil : failures.joined(separator:" ")
    }

    func setContext(
        _ option:FitnessCoachContextOption,
        enabled:Bool,
        isOnline:Bool
    ) async {
        guard isOnline,!isUpdatingContext,let current=contextPreferences else { return }
        let updated=FitnessCoachContextPreferences(
            familyCalendar:option == .familyCalendar ? enabled : current.familyCalendar,
            householdMeals:option == .householdMeals ? enabled : current.householdMeals,
            weather:option == .weather ? enabled : current.weather
        )
        guard updated != current else { return }
        isUpdatingContext=true
        contextError=nil
        defer { isUpdatingContext=false }
        do {
            contextPreferences=try await service.updateContextPreferences(updated)
            HapticManager.selection()
        } catch {
            contextError="That context choice couldn't be saved."
            HapticManager.error()
        }
    }

    func deleteReminder(_ reminder:FitnessCoachReminder,isOnline:Bool) async {
        guard isOnline,!isUpdatingContext else { return }
        isUpdatingContext=true
        contextError=nil
        defer { isUpdatingContext=false }
        do {
            try await service.deleteReminder(reminder.id)
            reminders.removeAll { $0.id == reminder.id }
            HapticManager.success()
        } catch {
            contextError="That reminder couldn't be removed."
            HapticManager.error()
        }
    }

    /// Memory and conversation endpoints are authenticated owner resources.
    /// They are intentionally network-only and never enter the Fitness outbox.
    func loadMemoryState(isOnline: Bool) async {
        guard isOnline,!isLoadingMemory else {
            if !isOnline,memorySettings == nil {
                memoryError="Reconnect to load your private Coach memory choice."
            }
            return
        }
        isLoadingMemory=true; memoryError=nil
        defer { isLoadingMemory=false }
        do {
            let settings=try await service.memorySettings()
            memorySettings=settings
            async let conversationValues=service.conversations()
            async let memoryValues=service.memories()
            conversations=try await conversationValues
            memories=try await memoryValues
        } catch {
            memoryError=error.localizedDescription
        }
    }

    func setMemoryEnabled(_ enabled: Bool,isOnline: Bool) async {
        guard isOnline,!isUpdatingMemory,enabled != memoryEnabled else { return }
        isUpdatingMemory=true; memoryError=nil; memoryNotice=nil
        defer { isUpdatingMemory=false }
        do {
            memorySettings=try await service.updateMemorySettings(enabled: enabled)
            if enabled {
                // Pre-opt-in turns remain ephemeral and are never presented as
                // part of the first stored conversation.
                messages=[]; currentConversationId=nil; lastFailedMessage=nil; inputText=""
                memoryNotice="Private Coach memory is on. A fresh chat has started; the earlier temporary chat was not saved."
                async let conversationValues=service.conversations()
                async let memoryValues=service.memories()
                conversations=try await conversationValues
                memories=try await memoryValues
            } else {
                // Keep the visible chat in process memory, matching the original
                // no-transcript behavior, but stop addressing a stored chat.
                // Existing server records remain visible until explicitly removed.
                currentConversationId=nil
                async let conversationValues=service.conversations()
                async let memoryValues=service.memories()
                conversations=try await conversationValues
                memories=try await memoryValues
                memoryNotice="Coach memory is off. Existing saved items remain available to review or clear."
            }
            HapticManager.success()
        } catch {
            memoryError=error.localizedDescription; HapticManager.error()
        }
    }

    func startNewConversation(isOnline: Bool) async {
        guard memoryEnabled,isOnline,!isUpdatingMemory else { return }
        isUpdatingMemory=true; memoryError=nil; memoryNotice=nil
        defer { isUpdatingMemory=false }
        do {
            let conversation=try await service.createConversation()
            currentConversationId=conversation.id
            messages=[]; lastFailedMessage=nil; errorMessage=nil; inputText=""
            conversations=[conversation] + conversations.filter { $0.id != conversation.id }
            HapticManager.selection()
        } catch {
            memoryError=error.localizedDescription
        }
    }

    func resumeConversation(_ conversation: FitnessCoachConversation,isOnline: Bool) async {
        guard isOnline,!isLoadingMemory else { return }
        isLoadingMemory=true; memoryError=nil; memoryNotice=nil
        defer { isLoadingMemory=false }
        do {
            let detail=try await service.conversation(conversation.id)
            currentConversationId=memoryEnabled ? detail.id : nil
            messages=detail.messages.sorted { $0.sequence < $1.sequence }.suffix(
                Self.maximumVisibleStoredMessages
            ).map { stored in
                FitnessCoachChatMessage(
                    id: UUID(uuidString: stored.id) ?? UUID(),
                    role: stored.role,content: stored.content
                )
            }
            if let lastIntent=detail.messages.reversed().compactMap(\.intent).first {
                intent=lastIntent
            }
            lastFailedMessage=nil; errorMessage=nil
            if !memoryEnabled {
                memoryNotice="Read-only saved copy. New replies stay temporary while Coach memory is off."
            }
        } catch {
            memoryError=error.localizedDescription
        }
    }

    func deleteConversation(_ conversation: FitnessCoachConversation,isOnline: Bool) async {
        guard isOnline,!isUpdatingMemory else { return }
        isUpdatingMemory=true; memoryError=nil
        defer { isUpdatingMemory=false }
        do {
            try await service.deleteConversation(conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            if currentConversationId == conversation.id {
                currentConversationId=nil; messages=[]; lastFailedMessage=nil
            }
            HapticManager.success()
        } catch {
            memoryError=error.localizedDescription
        }
    }

    func remember(_ candidate: FitnessCoachMemoryCandidate,isOnline: Bool) async {
        guard memoryEnabled,isOnline,!rememberingCandidateKeys.contains(candidate.key) else { return }
        rememberingCandidateKeys.insert(candidate.key); memoryError=nil
        defer { rememberingCandidateKeys.remove(candidate.key) }
        do {
            let saved=try await service.remember(candidate)
            memories=[saved] + memories.filter { $0.id != saved.id }
            rememberedCandidateKeys.insert(candidate.key)
            memoryNotice="Remembered only after your confirmation."
            HapticManager.success()
        } catch {
            memoryError=error.localizedDescription
        }
    }

    func updateMemory(
        _ memory: FitnessCoachMemory,content: String,category: String?,isOnline: Bool
    ) async -> Bool {
        let trimmed=content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Disabling continuity stops new storage. It must not lock the owner
        // out of maintaining records that are already persisted.
        guard isOnline,!isUpdatingMemory,!trimmed.isEmpty else { return false }
        isUpdatingMemory=true; memoryError=nil
        defer { isUpdatingMemory=false }
        do {
            let trimmedCategory=category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved=try await service.updateMemory(
                id: memory.id,content: trimmed,
                category: trimmedCategory?.isEmpty == false ? trimmedCategory : nil
            )
            if let index=memories.firstIndex(where: { $0.id == saved.id }) { memories[index]=saved }
            HapticManager.success(); return true
        } catch {
            memoryError=error.localizedDescription; return false
        }
    }

    func forgetMemory(_ memory: FitnessCoachMemory,isOnline: Bool) async {
        guard isOnline,!isUpdatingMemory else { return }
        isUpdatingMemory=true; memoryError=nil
        defer { isUpdatingMemory=false }
        do {
            try await service.forgetMemory(memory.id)
            memories.removeAll { $0.id == memory.id }
            memoryNotice="Memory forgotten."
            HapticManager.success()
        } catch {
            memoryError=error.localizedDescription
        }
    }

    func clearAllMemory(isOnline: Bool) async -> Bool {
        guard isOnline,!isUpdatingMemory else { return false }
        isUpdatingMemory=true; memoryError=nil
        defer { isUpdatingMemory=false }
        do {
            let result=try await service.clearMemory()
            conversations=[]; memories=[]; currentConversationId=nil
            messages=[]; lastFailedMessage=nil
            memoryNotice="Cleared \(result.memories) memories and \(result.conversations) saved chats."
            HapticManager.success(); return true
        } catch {
            memoryError=error.localizedDescription; return false
        }
    }

    func activateAfterConsent(isOnline: Bool) async {
        hasCurrentConsent = true
        needsConsentReload = false
        guard isOnline else {
            runtimeUnavailableMessage = "Coach needs a connection. Your Fitness records and local guidance remain available."
            return
        }
        await loadRemote()
    }

    func deactivateForMissingConsent() {
        hasCurrentConsent = false
        status = nil
        runtimeUnavailableMessage = nil
    }

    func loadRemote() async {
        guard hasCurrentConsent else { return }
        isLoadingStatus = true
        errorMessage = nil
        defer { isLoadingStatus = false }
        do {
            status = try await service.status()
            runtimeUnavailableMessage = status?.status == .unavailable
                ? status?.message ?? "The coach is temporarily unavailable."
                : nil
        } catch {
            recordRemoteFailure(error,operation: "Coach status could not be checked.")
        }
        guard hasCurrentConsent else { return }
        await loadRecommendations()
    }

    func chooseIntent(_ value: FitnessCoachIntent) {
        intent = value
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { inputText = value.prompt }
    }

    func send(isOnline: Bool) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,!isSending else { return }
        await submit(text,appendUserMessage: !(lastFailedMessage == text && messages.last?.role == .user),isOnline: isOnline)
    }

    func applyDraftHandoff(_ handoff: FitnessCoachDraftHandoff) {
        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputText = handoff.text
        pendingContextIds = handoff.contextIds
    }

    func retry(isOnline: Bool) async {
        guard let lastFailedMessage,!isSending else { return }
        await submit(lastFailedMessage,appendUserMessage: false,isOnline: isOnline)
    }

    func clearConversation() {
        messages = []
        currentConversationId = nil
        lastFailedMessage = nil
        errorMessage = nil
        pendingContextIds = []
    }

    /// Edit is deliberately a conversation operation: it copies only the
    /// human preview into the composer and performs no proposal mutation.
    @discardableResult
    func seedEdit(of proposal:FitnessCoachProposal) -> Bool {
        guard proposal.canEdit,let review=proposal.humanReview else { return false }
        let change=review.change.joined(separator:"; ")
        inputText=String("Please revise this suggestion: \(change).".prefix(2_000))
        return true
    }

    func decide(
        messageId: UUID,
        proposal: FitnessCoachProposal,
        action: FitnessCoachProposalAction,
        isOnline: Bool
    ) async {
        guard hasCurrentConsent,isOnline,!decidingProposalIds.contains(proposal.id) else { return }
        if action == .confirm, !proposal.canConfirm {
            errorMessage = "This suggestion has changed and can’t be saved. Ask Coach to make it again."
            return
        }
        decidingProposalIds.insert(proposal.id)
        errorMessage = nil
        defer { decidingProposalIds.remove(proposal.id) }
        do {
            let response = try await service.decide(proposalId: proposal.id,decision: action)
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages[index].proposalDecision = response
            }
            if response.status == .confirmed {
                HapticManager.success()
                await syncConfirmedChange()
                await loadContextState(isOnline:true)
                await loadRecommendations()
            } else {
                HapticManager.selection()
            }
        } catch {
            recordRemoteFailure(error,operation: "That choice couldn’t be saved. Try again.")
        }
    }

    func undo(
        messageId: UUID,proposal: FitnessCoachProposal,isOnline: Bool
    ) async {
        guard hasCurrentConsent,isOnline,!decidingProposalIds.contains(proposal.id) else { return }
        decidingProposalIds.insert(proposal.id); errorMessage=nil
        defer { decidingProposalIds.remove(proposal.id) }
        do {
            let response=try await service.undo(proposalId:proposal.id)
            if let index=messages.firstIndex(where:{ $0.id == messageId }) {
                messages[index].proposalUndo=response
            }
            if response.succeeded {
                HapticManager.success()
                await syncConfirmedChange()
                await loadRecommendations()
            } else {
                HapticManager.error()
            }
        } catch {
            recordRemoteFailure(error,operation:"That change couldn’t be undone. Try again.")
        }
    }

    func selectFeedback(_ value: FitnessCoachFeedback,for recommendationId: String) {
        feedbackSelections[recommendationId] = value
    }

    func saveFeedback(for recommendation: FitnessCoachRecommendation,isOnline: Bool) async {
        guard hasCurrentConsent,isOnline,!savingFeedbackIds.contains(recommendation.id) else { return }
        let feedback = feedbackSelections[recommendation.id] ?? recommendation.userFeedback ?? .accepted
        savingFeedbackIds.insert(recommendation.id)
        errorMessage = nil
        defer { savingFeedbackIds.remove(recommendation.id) }
        do {
            try await service.recordFeedback(recommendationId: recommendation.id,feedback: feedback)
            HapticManager.success()
            await loadRecommendations()
        } catch {
            recordRemoteFailure(error,operation: "The recommendation outcome could not be saved.")
        }
    }

    private func submit(_ text: String,appendUserMessage: Bool,isOnline: Bool) async {
        guard hasCurrentConsent else {
            needsConsentReload = true
            return
        }
        guard isOnline else {
            runtimeUnavailableMessage = "Coach needs a connection. You can keep using the rest of Fitness offline."
            return
        }
        guard status?.status == .available else {
            runtimeUnavailableMessage = status?.message ?? "Coach is temporarily unavailable."
            return
        }
        guard text.count <= 2_000 else {
            errorMessage = "Keep a coaching message to 2,000 characters or fewer."
            return
        }

        var context = messages
        if !appendUserMessage,context.last?.role == .user,context.last?.content == text { context.removeLast() }
        let history = context.suffix(Self.maximumInMemoryTurns).map {
            FitnessCoachHistoryTurn(role: $0.role,content: $0.content)
        }
        if appendUserMessage {
            append(.init(role: .user,content: text))
        }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines) == text { inputText = "" }
        isSending = true
        errorMessage = nil
        runtimeUnavailableMessage = nil
        defer { isSending = false }

        do {
            let response = try await service.send(
                FitnessCoachMessageRequest(
                    message: text,intent: intent,history: Array(history),
                    timezone: TimeZone.current.identifier,
                    clientNow: ISODateParser.string(from: Date()),
                    conversationId: memoryEnabled && !ephemeralMessages ? currentConversationId : nil,
                    ephemeral: ephemeralMessages,
                    contextIds: pendingContextIds
                )
            )
            if response.status == .unavailable {
                runtimeUnavailableMessage = response.answer.isEmpty
                    ? "The coach is temporarily unavailable. Local guidance remains available."
                    : response.answer
                lastFailedMessage = text
            } else {
                if memoryEnabled && !ephemeralMessages { currentConversationId=response.conversationId }
                append(
                    .init(
                        role: .assistant,content: response.answer,evidence: response.evidence,
                        recommendation: response.recommendation,proposal: response.proposal,
                        memoryCandidates: response.memoryCandidates ?? []
                    )
                )
                lastFailedMessage = nil
                pendingContextIds = []
                if response.recommendation != nil { await loadRecommendations() }
                if memoryEnabled && !ephemeralMessages {
                    do {
                        conversations=try await service.conversations()
                    } catch is CancellationError {
                        return
                    } catch {
                        memoryError="Saved conversations could not be refreshed. Try again."
                    }
                }
                HapticManager.selection()
            }
        } catch {
            lastFailedMessage = text
            recordRemoteFailure(error,operation: "The coach could not answer just now.")
        }
    }

    private func append(_ message: FitnessCoachChatMessage) {
        let limit=memoryEnabled ? Self.maximumVisibleStoredMessages : Self.maximumInMemoryTurns
        messages = Array((messages + [message]).suffix(limit))
    }

    private func syncConfirmedChange() async {
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch is CancellationError {
            return
        } catch {
            errorMessage="The change was saved on this iPhone and will sync automatically."
        }
    }

    private func loadRecommendations() async {
        guard hasCurrentConsent else { return }
        do {
            recommendations = try await service.recommendations()
        } catch {
            if FitnessCoachService.statusCode(error) == 428 {
                requireConsentReload()
            } else if recommendations.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recordRemoteFailure(_ error: Error,operation: String) {
        let statusCode = FitnessCoachService.statusCode(error)
        if statusCode == 428 {
            requireConsentReload()
            errorMessage = "Your current OpenAI permission must be reviewed before Fitness evidence is sent."
        } else if statusCode == 429 {
            runtimeUnavailableMessage = "The coach is busy just now. Wait a moment and try again; this in-memory conversation remains here."
        } else if let statusCode,statusCode >= 500 {
            runtimeUnavailableMessage = "Coach is temporarily unavailable. You can keep using the rest of Fitness."
        } else if let apiError = error as? APIError {
            switch apiError {
            case .networkError:
                runtimeUnavailableMessage = "Coach needs a connection. Your local Fitness records remain available."
            default:
                errorMessage = apiError.errorDescription ?? operation
            }
        } else {
            errorMessage = operation
        }
    }

    private func requireConsentReload() {
        hasCurrentConsent = false
        needsConsentReload = true
        status = nil
    }

}
