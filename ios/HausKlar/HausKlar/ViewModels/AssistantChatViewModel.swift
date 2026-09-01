import Foundation

struct AIConsentStatusDTO: Codable, Equatable {
    let consented: Bool
    let version: String
    let consentedAt: String?
    let provider: String
    let disclosure: String
    let backgroundProcessing: Bool
}

private struct AIConsentRequestDTO: Encodable {
    let accepted = true
    let version: String
}

@MainActor
final class AIConsentViewModel: ObservableObject {
    @Published private(set) var status: AIConsentStatusDTO?
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    var hasConsent: Bool { status?.consented == true }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            status = try await APIClient.shared.get("/auth/ai-consent")
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "AI privacy settings could not be loaded."
        }
    }

    func grant() async {
        guard let status, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            self.status = try await APIClient.shared.put(
                "/auth/ai-consent",
                body: AIConsentRequestDTO(version: status.version)
            )
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
        } catch {
            errorMessage = "Permission could not be saved."
            HapticManager.error()
        }
    }

    func revoke() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            status = try await APIClient.shared.deleteReturning("/auth/ai-consent")
            HapticManager.selection()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
        } catch {
            errorMessage = "Permission could not be withdrawn."
            HapticManager.error()
        }
    }
}

@MainActor
final class AssistantChatViewModel: ObservableObject {
    @Published var messages: [AssistantChatMessage] = []
    @Published var inputText = ""
    @Published var isSending = false
    @Published var thinkingStatus = "Thinking…".localized
    @Published var errorMessage: String?
    @Published var familyMembers: [FamilyMemberDTO] = []
    @Published private(set) var lastFailedMessage: String?
    private var resolvingActionIDs: Set<String> = []

    let suggestedPrompts = [
        "What needs my attention this week?",
        "Add milk and nappies to the shopping list.",
        "Put swimming on Thursday at 4pm.",
        "Remind Morgan to return the nursery form tomorrow.",
    ]

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var canRetry: Bool { lastFailedMessage != nil && !isSending }

    /// Returns the exact unsent text without sending it or clearing Bismarck.
    /// The destination decides when it is safe to consume the hand-off.
    func fitnessCoachDraftForHandoff() -> String? {
        guard !isSending,
              !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return inputText
    }

    func loadMembers() async {
        guard familyMembers.isEmpty else { return }
        do {
            familyMembers = try await APIClient.shared.get("/family/members")
        } catch is CancellationError {
            return
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Family members could not be loaded.".localized
        }
    }

    func send(_ suggestedText: String? = nil) async {
        let text = (suggestedText ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        let reusesFailedBubble = suggestedText == nil && shouldReuseFailedBubble(for: text)
        await submit(text, appendUserMessage: !reusesFailedBubble)
    }

    func shouldReuseFailedBubble(for text: String) -> Bool {
        lastFailedMessage == text
            && messages.last?.role == .user
            && messages.last?.content == text
    }

    func retryLastMessage() async {
        guard let text = lastFailedMessage, !isSending else { return }
        await submit(text, appendUserMessage: false)
    }

    private func submit(_ text: String, appendUserMessage: Bool) async {
        var context = messages
        if !appendUserMessage,
           context.last?.role == .user,
           context.last?.content == text {
            context.removeLast()
        }

        let history = context.suffix(12).map {
            AssistantHistoryDTO(role: $0.role, content: $0.content)
        }
        if appendUserMessage {
            messages.append(AssistantChatMessage(role: .user, content: text))
        }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            inputText = ""
        }
        isSending = true
        errorMessage = nil
        defer {
            isSending = false
        }

        do {
            let response: AssistantMessageResponseDTO = try await APIClient.shared.post(
                "/assistant/message",
                body: AssistantMessageRequestDTO(
                    message: text,
                    history: Array(history),
                    clientNow: ISODateParser.string(from: Date()),
                    timezone: TimeZone.current.identifier
                ),
                timeoutInterval: 135
            )
            messages.append(
                AssistantChatMessage(
                    role: .assistant,
                    content: response.answer,
                    actions: response.actions.map(AssistantActionState.init)
                )
            )
            lastFailedMessage = nil
            HapticManager.selection()
        } catch let error as APIError {
            recordSendFailure(text, message: error.errorDescription ?? "Bismarck couldn't answer just now.")
        } catch {
            recordSendFailure(text, message: "Bismarck couldn't answer just now. Please try again.".localized)
        }
    }

    func recordSendFailure(_ text: String, message: String) {
        lastFailedMessage = text
        errorMessage = message
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = text
        }
        HapticManager.error()
    }

    func confirm(actionID: String, in messageID: UUID) async {
        guard let location = beginResolution(actionID: actionID, messageID: messageID) else { return }
        defer { resolvingActionIDs.remove(actionID) }
        messages[location.message].actions[location.action].status = .executing
        messages[location.message].actions[location.action].resultMessage = nil
        errorMessage = nil

        do {
            let result: AssistantActionResultDTO = try await APIClient.shared.post(
                "/assistant/actions/\(actionID)/execute",
                body: EmptyBody()
            )
            guard let updated = actionLocation(actionID: actionID, messageID: messageID) else { return }
            messages[updated.message].actions[updated.action].status = result.status
            messages[updated.message].actions[updated.action].resultMessage = result.message
            messages[updated.message].actions[updated.action].resultId = result.resultId
            if result.status == .executed {
                postRefreshNotification(for: result.kind)
                HapticManager.success()
            } else {
                HapticManager.error()
            }
        } catch let error as APIError {
            restorePending(actionID: actionID, messageID: messageID)
            errorMessage = error.errorDescription
            HapticManager.error()
        } catch {
            restorePending(actionID: actionID, messageID: messageID)
            errorMessage = "That action could not be completed.".localized
            HapticManager.error()
        }
    }

    func update(
        actionID: String,
        in messageID: UUID,
        preview: AssistantActionPreview
    ) async -> Bool {
        guard let location = actionLocation(actionID: actionID, messageID: messageID),
              messages[location.message].actions[location.action].status == .pending,
              messages[location.message].actions[location.action].editable,
              messages[location.message].actions[location.action].kind == preview.kind,
              !resolvingActionIDs.contains(actionID)
        else { return false }

        resolvingActionIDs.insert(actionID)
        defer { resolvingActionIDs.remove(actionID) }
        errorMessage = nil

        do {
            let refreshed: AssistantActionDTO = try await APIClient.shared.patch(
                "/assistant/actions/\(actionID)",
                body: AssistantActionUpdateRequest(preview: preview)
            )
            guard let updated = actionLocation(actionID: actionID, messageID: messageID) else { return false }
            messages[updated.message].actions[updated.action] = AssistantActionState(refreshed)
            HapticManager.selection()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
            return false
        } catch {
            errorMessage = "Those changes could not be saved. Please try again.".localized
            HapticManager.error()
            return false
        }
    }

    func decline(actionID: String, in messageID: UUID) async {
        guard let location = beginResolution(actionID: actionID, messageID: messageID) else { return }
        defer { resolvingActionIDs.remove(actionID) }
        messages[location.message].actions[location.action].status = .executing
        messages[location.message].actions[location.action].resultMessage = nil
        errorMessage = nil
        do {
            let result: AssistantActionResultDTO = try await APIClient.shared.post(
                "/assistant/actions/\(actionID)/decline",
                body: EmptyBody()
            )
            guard let updated = actionLocation(actionID: actionID, messageID: messageID) else { return }
            messages[updated.message].actions[updated.action].status = result.status
            messages[updated.message].actions[updated.action].resultMessage = result.message
            HapticManager.selection()
        } catch let error as APIError {
            restorePending(actionID: actionID, messageID: messageID)
            errorMessage = error.errorDescription
        } catch {
            restorePending(actionID: actionID, messageID: messageID)
            errorMessage = "That action could not be dismissed.".localized
        }
    }

    func clear() {
        messages.removeAll()
        inputText = ""
        errorMessage = nil
        lastFailedMessage = nil
    }

    private func actionLocation(actionID: String, messageID: UUID) -> (message: Int, action: Int)? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let actionIndex = messages[messageIndex].actions.firstIndex(where: { $0.id == actionID })
        else { return nil }
        return (messageIndex, actionIndex)
    }

    func beginResolution(actionID: String, messageID: UUID) -> (message: Int, action: Int)? {
        guard !resolvingActionIDs.contains(actionID),
              let location = actionLocation(actionID: actionID, messageID: messageID),
              messages[location.message].actions[location.action].status == .pending
        else { return nil }
        resolvingActionIDs.insert(actionID)
        return location
    }

    private func restorePending(actionID: String, messageID: UUID) {
        guard let location = actionLocation(actionID: actionID, messageID: messageID) else { return }
        messages[location.message].actions[location.action].status = .pending
    }

    private func postRefreshNotification(for kind: AssistantActionKind) {
        let name: Notification.Name?
        switch kind {
        case .calendarEvent: name = .calendarDataChanged
        case .createTask, .completeTask: name = .taskDataChanged
        case .shoppingItem: name = .shoppingDataChanged
        case .homeLights: name = nil
        }
        if let name { NotificationCenter.default.post(name: name, object: nil) }
    }
}
