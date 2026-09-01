import Foundation

enum UniversalCaptureStage: Equatable {
    case input
    case review
    case complete
}

enum CaptureItemSaveState: Equatable {
    case saving
    case succeeded
    case failed
}

struct CaptureItemResult: Identifiable, Equatable {
    let id: String
    let kind: UniversalCaptureKind
    let title: String
    var state: CaptureItemSaveState
    var resultId: String?
    var message: String?
}

struct CaptureSaveReceipt: Equatable {
    let resultId: String
    let kind: UniversalCaptureKind
}

struct CaptureSessionDraft: Equatable {
    var inputText: String
    var proposals: [EditableCaptureProposal]
    var results: [String: CaptureItemResult]
    var stage: UniversalCaptureStage
    var suggestsBismarck: Bool
}

/// Process-memory only: survives an accidental sheet dismissal without turning
/// family capture text into persistent chat history. Drafts are identity-bound.
@MainActor
enum CaptureSessionDraftStore {
    private(set) static var ownerID: String?
    private(set) static var draft: CaptureSessionDraft?
    private(set) static var recentActions: [CaptureDirectAction] = CaptureDirectAction.allCases

    static func prepare(ownerID: String?) -> CaptureSessionDraft? {
        if self.ownerID != ownerID {
            self.ownerID = ownerID
            draft = nil
            recentActions = CaptureDirectAction.allCases
        }
        return draft
    }

    static func save(_ draft: CaptureSessionDraft, ownerID: String?) {
        guard self.ownerID == ownerID else { return }
        self.draft = draft
    }

    static func clearDraft(ownerID: String?) {
        guard self.ownerID == ownerID else { return }
        draft = nil
    }

    static func record(_ action: CaptureDirectAction, ownerID: String?) {
        guard self.ownerID == ownerID else { return }
        recentActions.removeAll { $0 == action }
        recentActions.insert(action, at: 0)
    }

    static func resetForTests() {
        ownerID = nil
        draft = nil
        recentActions = CaptureDirectAction.allCases
    }
}

@MainActor
final class CaptureViewModel: ObservableObject {
    typealias Parser = @Sendable (String, Bool) async throws -> UniversalCaptureResponseDTO
    typealias MembersLoader = @Sendable () async throws -> [FamilyMemberDTO]
    typealias Saver = @Sendable (
        EditableCaptureProposal,
        [FamilyMemberDTO]
    ) async throws -> CaptureSaveReceipt

    @Published var inputText = ""
    @Published var proposals: [EditableCaptureProposal] = []
    @Published var familyMembers: [FamilyMemberDTO] = []
    @Published var results: [String: CaptureItemResult] = [:]
    @Published var stage: UniversalCaptureStage = .input
    @Published var isParsing = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var suggestsBismarck = false

    private let parser: Parser
    private let membersLoader: MembersLoader
    private let saver: Saver
    private var ownerID: String?
    private var isPrepared = false

    init(
        parser: @escaping Parser = { text, useBismarck in
            try await CaptureViewModel.parseUsingAPI(
                text: text,
                useBismarck: useBismarck
            )
        },
        membersLoader: @escaping MembersLoader = {
            try await CaptureViewModel.loadMembersUsingAPI()
        },
        saver: @escaping Saver = { proposal, familyMembers in
            try await CaptureViewModel.saveUsingAPI(
                proposal: proposal,
                familyMembers: familyMembers
            )
        }
    ) {
        self.parser = parser
        self.membersLoader = membersLoader
        self.saver = saver
    }

    var includedCount: Int {
        proposals.filter {
            $0.isIncluded
                && !$0.trimmedTitle.isEmpty
                && results[$0.id]?.state != .succeeded
        }.count
    }

    var savedCount: Int {
        results.values.filter { $0.state == .succeeded }.count
    }

    var recentDirectActions: [CaptureDirectAction] {
        CaptureSessionDraftStore.recentActions
    }

    func prepare(ownerID: String?, initialText: String) {
        guard !isPrepared else { return }
        self.ownerID = ownerID
        if let draft = CaptureSessionDraftStore.prepare(ownerID: ownerID) {
            inputText = draft.inputText
            proposals = draft.proposals
            results = draft.results
            stage = draft.stage
            suggestsBismarck = draft.suggestsBismarck
        }

        let incoming = initialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !incoming.isEmpty && inputText.trimmingCharacters(in: .whitespacesAndNewlines) != incoming {
            inputText = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? initialText
                : inputText + "\n" + initialText
            stage = .input
        }
        isPrepared = true
        persistDraft()
    }

    func persistDraft() {
        guard isPrepared, stage != .complete else { return }
        let hasContent = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !proposals.isEmpty
        guard hasContent else {
            CaptureSessionDraftStore.clearDraft(ownerID: ownerID)
            return
        }
        CaptureSessionDraftStore.save(
            CaptureSessionDraft(
                inputText: inputText,
                proposals: proposals,
                results: results,
                stage: stage,
                suggestsBismarck: suggestsBismarck
            ),
            ownerID: ownerID
        )
    }

    func discardDraft() {
        inputText = ""
        proposals = []
        results = [:]
        stage = .input
        errorMessage = nil
        suggestsBismarck = false
        CaptureSessionDraftStore.clearDraft(ownerID: ownerID)
    }

    func loadMembers() async {
        guard familyMembers.isEmpty else { return }
        do {
            familyMembers = try await membersLoader()
        } catch is CancellationError {
            return
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Family members could not be loaded.".localized
        }
    }

    func reviewInput() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Enter something to add."
            return
        }

        if let shopping = Self.simpleShoppingProposals(from: text), !shopping.isEmpty {
            proposals = shopping
            results = [:]
            suggestsBismarck = false
            errorMessage = nil
            stage = .review
            CaptureSessionDraftStore.record(.shopping, ownerID: ownerID)
            persistDraft()
            HapticManager.selection()
            return
        }

        isParsing = true
        errorMessage = nil
        defer { isParsing = false }

        do {
            async let membersTask: Void = loadMembers()
            async let responseTask = parser(text, false)
            let (_, response) = try await (membersTask, responseTask)
            proposals = response.proposals.map(EditableCaptureProposal.init)
            results = [:]
            suggestsBismarck = Self.shouldSuggestBismarck(text: text, response: response)
            stage = .review
            persistDraft()
            HapticManager.selection()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "That could not be reviewed just now. Please try again."
        }
    }

    func startDirect(_ action: CaptureDirectAction) {
        guard let kind = action.proposalKind else { return }
        proposals = [EditableCaptureProposal(kind: kind)]
        results = [:]
        suggestsBismarck = false
        errorMessage = nil
        stage = .review
        CaptureSessionDraftStore.record(action, ownerID: ownerID)
        persistDraft()
        HapticManager.selection()
    }

    func recordDocumentAction() {
        CaptureSessionDraftStore.record(.document, ownerID: ownerID)
    }

    func addProposal(_ kind: UniversalCaptureKind) {
        proposals.append(EditableCaptureProposal(kind: kind))
        let proposalIDs = Set(proposals.map(\.id))
        results = results.filter { proposalIDs.contains($0.key) }
        persistDraft()
        HapticManager.selection()
    }

    func removeProposal(id: String) {
        proposals.removeAll { $0.id == id }
        results.removeValue(forKey: id)
        persistDraft()
    }

    func confirm() async {
        let selected = proposals.filter {
            $0.isIncluded
                && !$0.trimmedTitle.isEmpty
                && results[$0.id]?.state != .succeeded
        }
        guard !selected.isEmpty else {
            errorMessage = "Choose at least one item with a title."
            return
        }

        isSaving = true
        errorMessage = nil
        var failures = 0
        var succeededKinds: Set<UniversalCaptureKind> = []

        for proposal in selected {
            results[proposal.id] = CaptureItemResult(
                id: proposal.id,
                kind: proposal.kind,
                title: proposal.trimmedTitle,
                state: .saving
            )
            persistDraft()
            do {
                let receipt = try await saver(proposal, familyMembers)
                results[proposal.id] = CaptureItemResult(
                    id: proposal.id,
                    kind: receipt.kind,
                    title: proposal.trimmedTitle,
                    state: .succeeded,
                    resultId: receipt.resultId,
                    message: "Added"
                )
                succeededKinds.insert(receipt.kind)
            } catch {
                failures += 1
                results[proposal.id] = CaptureItemResult(
                    id: proposal.id,
                    kind: proposal.kind,
                    title: proposal.trimmedTitle,
                    state: .failed,
                    message: "Couldn’t add this. Check it and try again."
                )
            }
            persistDraft()
        }

        isSaving = false
        postRefreshNotifications(for: succeededKinds)

        if failures == 0 {
            stage = .complete
            CaptureSessionDraftStore.clearDraft(ownerID: ownerID)
            HapticManager.success()
        } else {
            errorMessage = failures == 1
                ? "One item still needs attention."
                : "Some items still need attention."
            persistDraft()
            HapticManager.error()
        }
    }

    func returnToInput() {
        proposals = []
        results = [:]
        stage = .input
        errorMessage = nil
        suggestsBismarck = false
        persistDraft()
    }

    func result(for proposalID: String) -> CaptureItemResult? {
        results[proposalID]
    }

    static func shouldSuggestBismarck(
        text: String,
        response: UniversalCaptureResponseDTO
    ) -> Bool {
        guard !response.proposals.isEmpty else { return true }
        if response.proposals.contains(where: { $0.confidence < 0.6 }) { return true }

        let connectedPhrases = [
            " and then ", " after that ", " instead of ", " move ", " change ",
            " reschedule ", " cancel ", " work out ", " what should ", " if we ",
            " can you sort ", " also ",
        ]
        let normalised = " " + text.lowercased() + " "
        return connectedPhrases.contains { normalised.contains($0) }
    }

    static func simpleShoppingProposals(from text: String) -> [EditableCaptureProposal]? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let lower = trimmed.lowercased()
        let prefixes = ["add ", "put "]
        let suffixes = [
            " to the shopping list", " to shopping list", " on the shopping list",
            " to the tesco list", " on the tesco list", " to shopping", " on shopping",
        ]
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }),
              let suffix = suffixes.first(where: { lower.hasSuffix($0) }) else { return nil }

        let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let rawItems = String(trimmed[start..<end])
            .replacingOccurrences(of: ",", with: " and ")
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawItems.isEmpty, rawItems.count <= 10 else { return nil }

        return rawItems.map { item in
            var proposal = EditableCaptureProposal(kind: .shopping)
            proposal.title = item.prefix(1).uppercased() + String(item.dropFirst())
            return proposal
        }
    }

    nonisolated private static func parseUsingAPI(
        text: String,
        useBismarck: Bool
    ) async throws -> UniversalCaptureResponseDTO {
        try await APIClient.shared.post(
            "/capture/parse",
            body: UniversalCaptureParseRequest(
                text: text,
                useHermes: useBismarck,
                clientNow: ISODateParser.string(from: Date()),
                timezone: TimeZone.current.identifier
            ),
            timeoutInterval: useBismarck ? 135 : 30
        )
    }

    nonisolated private static func loadMembersUsingAPI() async throws -> [FamilyMemberDTO] {
        try await APIClient.shared.get("/family/members")
    }

    nonisolated private static func saveUsingAPI(
        proposal: EditableCaptureProposal,
        familyMembers: [FamilyMemberDTO]
    ) async throws -> CaptureSaveReceipt {
        do {
            switch proposal.kind {
            case .event:
                let event: CalendarEventDTO = try await APIClient.shared.post(
                    "/calendar/",
                    body: proposal.eventRequest()
                )
                return CaptureSaveReceipt(resultId: event.id, kind: .event)
            case .task:
                let member = familyMembers.first { $0.id == proposal.assignedTo }
                let task: TaskDTO = try await APIClient.shared.post(
                    "/tasks/",
                    body: proposal.taskRequest(member: member)
                )
                return CaptureSaveReceipt(resultId: task.id, kind: .task)
            case .shopping:
                let item: ShoppingItemDTO = try await APIClient.shared.post(
                    "/meals/shopping",
                    body: proposal.shoppingRequest(clientId: try APIClient.shared.clientId)
                )
                return CaptureSaveReceipt(resultId: item.id, kind: .shopping)
            }
        } catch APIError.offlineQueued {
            // Existing transport owns durability; the stable operation ID is the
            // eventual record ID and keeps review/result handling deterministic.
            return CaptureSaveReceipt(resultId: proposal.operationId, kind: proposal.kind)
        }
    }

    private func postRefreshNotifications(for kinds: Set<UniversalCaptureKind>) {
        if kinds.contains(.event) {
            NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
        }
        if kinds.contains(.task) {
            NotificationCenter.default.post(name: .taskDataChanged, object: nil)
        }
        if kinds.contains(.shopping) {
            NotificationCenter.default.post(name: .shoppingDataChanged, object: nil)
        }
    }
}
