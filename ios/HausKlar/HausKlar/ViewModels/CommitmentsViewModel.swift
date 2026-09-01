import CryptoKit
import Foundation
import os

@MainActor
final class CommitmentsViewModel: ObservableObject {
    @Published private(set) var items: [Commitment] = []
    @Published private(set) var original: Commitment?
    @Published var draft: Commitment?
    @Published private(set) var documents: [CommitmentDocumentOption] = []
    @Published private(set) var members: [FamilyMemberDTO] = []
    @Published private(set) var aiConsent: AIConsentStatusDTO?
    @Published private(set) var outingResults: CommitmentFreeWindowResponse?
    @Published private(set) var childcareGaps: [CommitmentChildcareGap]?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingSupport = false
    @Published private(set) var isFromCache = false
    @Published private(set) var busyAction: String?
    @Published private(set) var conflictNeedsReload = false
    @Published var errorMessage: String?
    @Published var notice: String?

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "CommitmentsViewModel"
    )

    private struct TypedDraftIDs {
        let metadata: CommitmentMutationMetadata
        let sourceId: String
        let eventId: String
    }

    private let service: CommitmentService
    private let now: () -> Date
    private var currentUserId: String?
    private var operations: [String: CommitmentMutationMetadata] = [:]
    private var typedDraftIDs: [String: TypedDraftIDs] = [:]

    init(
        service: CommitmentService = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.now = now
    }

    var urgent: Commitment? { items.first }
    var hasAIConsent: Bool { aiConsent?.consented == true }
    var children: [FamilyMemberDTO] { members.filter { $0.memberType == "child" } }
    var isDirty: Bool { draft != original }
    var mayChangeVisibility: Bool {
        guard let original, let currentUserId else { return false }
        return original.ownerUserId == currentUserId
    }
    var reviewIssues: [String] {
        guard let draft else { return [] }
        var values = draft.reviewIssues
        if draft.visibility == .owner {
            let issue = mayChangeVisibility
                ? "Share this plan with the family before confirming it.".localized
                : "Only the plan owner can share it with the family before confirmation.".localized
            if !values.contains(issue) { values.append(issue) }
        }
        return values
    }
    var canConfirm: Bool {
        guard let draft, !isDirty, busyAction == nil else { return false }
        return draft.canConfirm(currentUserId: currentUserId)
    }

    func supersessionCandidates(
        for kind: CommitmentKind,
        visibility: CommitmentVisibility? = nil,
        excluding excludedID: String? = nil
    ) -> [Commitment] {
        items.filter {
            $0.kind == kind
                && $0.status.isOpen
                && $0.id != excludedID
                && (visibility == nil || $0.visibility == visibility)
        }
    }

    func configure(currentUserId: String?) {
        guard self.currentUserId != currentUserId else { return }
        self.currentUserId = currentUserId
        items = []
        original = nil
        draft = nil
        documents = []
        members = []
        aiConsent = nil
        operations = [:]
        typedDraftIDs = [:]
        errorMessage = nil
        notice = nil
    }

    func loadPending(refresh: Bool = false) async {
        guard currentUserId != nil else {
            items = []
            return
        }
        isLoading = items.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await service.openCommitments(refresh: refresh)
            items = result.value
            isFromCache = result.isFromCache
        } catch is CancellationError {
            return
        } catch {
            if items.isEmpty {
                errorMessage = "Plans to sort could not be loaded. Try again.".localized
            }
            Self.logger.error(
                "Commitment list failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func loadHub(fallbackMembers: [FamilyMemberDTO]) async {
        if members.isEmpty { members = fallbackMembers }
        isLoadingSupport = true
        async let plans: Void = loadPending(refresh: true)
        async let loadedMembers = loadMembers()
        async let loadedDocuments = loadDocuments()
        async let loadedConsent = loadConsent()
        let (memberValues, documentValues, consentValue) = await (
            loadedMembers,
            loadedDocuments,
            loadedConsent
        )
        if !memberValues.isEmpty { members = memberValues }
        documents = documentValues
        aiConsent = consentValue
        _ = await plans
        isLoadingSupport = false
    }

    func select(_ value: Commitment) {
        original = value
        draft = value
        conflictNeedsReload = false
        errorMessage = nil
        notice = nil
    }

    func select(id: String) {
        guard let value = items.first(where: { $0.id == id }) else { return }
        select(value)
    }

    func closeReview() {
        original = nil
        draft = nil
        conflictNeedsReload = false
        errorMessage = nil
    }

    func clearSearchResults() {
        outingResults = nil
        childcareGaps = nil
        errorMessage = nil
    }

    func createFromSource(
        kind: CommitmentKind,
        visibility: CommitmentVisibility,
        title: String,
        reviewedText: String,
        documentId: String?,
        sourceLabel: String,
        providerReference: String,
        supersedesId: String?,
        useHermes: Bool,
        online: Bool
    ) async -> Bool {
        let text = reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard online else {
            errorMessage = "Reconnect to interpret this reviewed source. Nothing has been sent or saved yet.".localized
            HapticManager.error()
            return false
        }
        guard !text.isEmpty else {
            errorMessage = "Review the source text before creating the plan.".localized
            HapticManager.error()
            return false
        }
        let fingerprint = Self.fingerprint([
            kind.rawValue, visibility.rawValue, title, text, documentId ?? "", sourceLabel,
            providerReference, useHermes ? "hermes" : "local",
            supersedesId ?? "",
        ])
        let key = "source:\(fingerprint)"
        let metadata = operation(for: key)
        busyAction = "create-source"
        errorMessage = nil
        notice = nil
        defer { busyAction = nil }
        do {
            let response = try await service.createFromSource(
                kind: kind,
                visibility: visibility,
                title: title,
                reviewedText: text,
                sourceDocumentId: documentId,
                sourceLabel: sourceLabel,
                providerReference: providerReference,
                supersedesId: supersedesId,
                requestHermes: useHermes,
                aiConsentAllowsHermes: hasAIConsent,
                metadata: metadata
            )
            operations.removeValue(forKey: key)
            replace(response.commitment)
            select(response.commitment)
            notice = response.warning ?? (response.processor == "hermes"
                ? "Bismarck helped interpret the reviewed text. Check every result before confirming.".localized
                : "HausKlar made an editable draft. Check every date before confirming.".localized)
            HapticManager.success()
            return true
        } catch let error as APIError {
            // Interpretation is deliberately network-only. It can never be
            // represented honestly as a queued draft.
            if case .offlineQueued = error {
                errorMessage = "Reconnect to interpret this reviewed source. Nothing has been saved yet.".localized
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func searchOutings(
        personIds: [String],
        searchStart: Date,
        searchEnd: Date,
        minimumMinutes: Int,
        name: String,
        availableStart: Date,
        availableEnd: Date,
        durationMinutes: Int,
        location: String,
        bookingURL: String,
        candidateId: String,
        online: Bool
    ) async -> Bool {
        guard online else {
            errorMessage = "Reconnect to search the family calendar. Searches cannot be queued.".localized
            return false
        }
        guard !personIds.isEmpty else {
            errorMessage = "Choose at least one person who needs to be free.".localized
            return false
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              searchEnd > searchStart, availableEnd > availableStart else {
            errorMessage = "Add a place and check that each end time is after its start.".localized
            return false
        }
        if !bookingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           SafeExternalURL.web(bookingURL) == nil {
            errorMessage = "The booking page must be a safe HTTPS link.".localized
            return false
        }
        busyAction = "outing-search"
        errorMessage = nil
        outingResults = nil
        defer { busyAction = nil }
        do {
            outingResults = try await service.queryFreeWindows(
                CommitmentFreeWindowQuery(
                    startTime: ISODateParser.string(from: searchStart),
                    endTime: ISODateParser.string(from: searchEnd),
                    personIds: personIds,
                    minimumMinutes: minimumMinutes,
                    candidates: [
                        CommitmentFreeWindowCandidate(
                            id: candidateId,
                            title: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            availableStart: ISODateParser.string(from: availableStart),
                            availableEnd: ISODateParser.string(from: availableEnd),
                            durationMinutes: durationMinutes,
                            location: location.nilIfBlank,
                            bookingUrl: bookingURL.nilIfBlank
                        )
                    ],
                    timezone: TimeZone.current.identifier
                )
            )
            HapticManager.selection()
            return true
        } catch let error as APIError {
            errorMessage = Self.networkOnlyMessage(
                error,
                fallback: "Free time could not be checked.".localized
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func createOuting(
        _ result: CommitmentViableOuting,
        personIds: [String],
        visibility: CommitmentVisibility
    ) async -> Bool {
        let semanticFingerprint = Self.fingerprint([
            visibility.rawValue,
            result.candidateId,
            result.title,
            result.proposedStart,
            result.proposedEnd,
            result.location ?? "",
            result.bookingUrl ?? "",
            personIds.sorted().joined(separator: ","),
        ])
        let key = "outing:\(semanticFingerprint)"
        let ids = typedIDs(for: key)
        busyAction = "outing-create:\(result.id)"
        errorMessage = nil
        defer { busyAction = nil }
        let sourceKind: CommitmentSourceKind = result.bookingUrl == nil ? .manual : .provider
        do {
            let saved = try await service.create(
                kind: .outing,
                visibility: visibility,
                title: result.title,
                summary: "A possible family outing found against the selected calendars.",
                sources: [
                    CommitmentSource(
                        id: ids.sourceId,
                        kind: sourceKind,
                        documentId: nil,
                        label: result.title,
                        providerReference: result.candidateId,
                        sourceUrl: result.bookingUrl,
                        observedAt: ids.metadata.timestamp
                    )
                ],
                plan: CommitmentPlan(
                    events: [
                        CommitmentEventDraft(
                            id: ids.eventId,
                            title: result.title,
                            description: nil,
                            startTime: result.proposedStart,
                            endTime: result.proposedEnd,
                            allDay: false,
                            location: result.location,
                            personIds: personIds,
                            affectedAdultIds: [],
                            assignedTo: nil,
                            eventType: "outing",
                            documentIds: []
                        )
                    ],
                    tasks: [],
                    preparations: [],
                    externalAction: result.bookingUrl.map {
                        CommitmentExternalAction(
                            kind: .book,
                            label: String(format: "Book %@".localized, result.title),
                            targetType: .https,
                            target: $0,
                            dueAt: nil,
                            requiresCompletionBeforeConfirm: true
                        )
                    }
                ),
                groupKey: nil,
                metadata: ids.metadata
            )
            typedDraftIDs.removeValue(forKey: key)
            replace(saved)
            select(saved)
            HapticManager.success()
            return true
        } catch APIError.offlineQueued {
            queued(
                key: key,
                message: "The outing draft is saved on this iPhone and will appear after it syncs.".localized
            )
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func findChildcareGaps(
        childId: String,
        from: Date,
        to: Date,
        online: Bool
    ) async -> Bool {
        guard online else {
            errorMessage = "Reconnect to compare term dates with calendar coverage. Searches cannot be queued.".localized
            return false
        }
        guard to >= from, !childId.isEmpty else {
            errorMessage = "Choose a child and a valid date range.".localized
            return false
        }
        busyAction = "childcare-search"
        errorMessage = nil
        childcareGaps = nil
        defer { busyAction = nil }
        do {
            childcareGaps = try await service.childcareGaps(
                childId: childId,
                from: ISODateParser.stringDateOnly(from: from),
                to: ISODateParser.stringDateOnly(from: to)
            )
            HapticManager.selection()
            return true
        } catch let error as APIError {
            errorMessage = Self.networkOnlyMessage(
                error,
                fallback: "Childcare gaps could not be checked.".localized
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func createChildcareGap(
        _ gap: CommitmentChildcareGap,
        childId: String,
        visibility: CommitmentVisibility
    ) async -> Bool {
        let semanticFingerprint = Self.fingerprint([
            visibility.rawValue,
            childId,
            gap.date,
            gap.label,
            gap.source,
        ])
        let key = "childcare:\(semanticFingerprint)"
        let ids = typedIDs(for: key)
        let childName = children.first(where: { $0.id == childId })?.name ?? "child".localized
        let title = String(format: "Childcare for %@".localized, childName)
        busyAction = "childcare-create:\(gap.date)"
        errorMessage = nil
        defer { busyAction = nil }
        do {
            let saved = try await service.create(
                kind: .childcare,
                visibility: visibility,
                title: title,
                summary: String(
                    format: "%@ on %@ does not yet have full-day childcare coverage.".localized,
                    gap.label,
                    gap.date
                ),
                sources: [
                    CommitmentSource(
                        id: ids.sourceId,
                        kind: .manual,
                        documentId: nil,
                        label: String(format: "%@ gap check".localized, gap.label),
                        providerReference: gap.source,
                        sourceUrl: nil,
                        observedAt: ids.metadata.timestamp
                    )
                ],
                plan: CommitmentPlan(
                    events: [
                        CommitmentEventDraft(
                            id: ids.eventId,
                            title: title,
                            description: gap.label,
                            startTime: gap.date,
                            endTime: nil,
                            allDay: true,
                            location: nil,
                            personIds: [childId],
                            affectedAdultIds: [],
                            assignedTo: nil,
                            eventType: "childcare",
                            documentIds: []
                        )
                    ],
                    tasks: [],
                    preparations: [],
                    externalAction: nil
                ),
                groupKey: nil,
                metadata: ids.metadata
            )
            typedDraftIDs.removeValue(forKey: key)
            replace(saved)
            select(saved)
            HapticManager.success()
            return true
        } catch APIError.offlineQueued {
            queued(
                key: key,
                message: "The childcare draft is saved on this iPhone and will appear after it syncs.".localized
            )
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func saveDraft() async -> Bool {
        guard let original, let draft, busyAction == nil else { return false }
        if let validation = Self.localValidationIssue(draft) {
            errorMessage = validation
            HapticManager.error()
            return false
        }
        let fingerprint = Self.fingerprint(draft)
        let key = "save:\(original.id):\(original.revision):\(fingerprint)"
        let metadata = operation(for: key)
        busyAction = "save"
        errorMessage = nil
        notice = nil
        defer { busyAction = nil }
        do {
            let updated = try await service.update(
                original: original,
                draft: draft,
                mayChangeVisibility: mayChangeVisibility,
                metadata: metadata
            )
            operations.removeValue(forKey: key)
            replace(updated)
            select(updated)
            notice = "Plan changes saved. Nothing has been added to the calendar yet.".localized
            HapticManager.success()
            return true
        } catch APIError.offlineQueued {
            queuedReviewMutation(
                message: "Your edits are saved on this iPhone. Reopen the plan after they sync before confirming it.".localized
            )
            return true
        } catch let error as APIError {
            handleMutationError(error)
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func markExternalActionDone() async -> Bool {
        guard let original, let draft, !isDirty, draft.plan.externalAction != nil,
              busyAction == nil else { return false }
        let key = "action:\(original.id):\(original.revision)"
        let metadata = operation(for: key)
        busyAction = "action"
        errorMessage = nil
        defer { busyAction = nil }
        do {
            let updated = try await service.completeExternalAction(
                commitment: original,
                metadata: metadata
            )
            operations.removeValue(forKey: key)
            replace(updated)
            select(updated)
            notice = "Outside step marked done. HausKlar did not contact the provider.".localized
            HapticManager.success()
            return true
        } catch APIError.offlineQueued {
            queuedReviewMutation(
                message: "Done is saved on this iPhone. Reopen the plan after it syncs before confirming it.".localized
            )
            return true
        } catch let error as APIError {
            handleMutationError(error)
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func confirm() async -> Bool {
        guard let original, canConfirm else { return false }
        let key = "confirm:\(original.id):\(original.revision)"
        let metadata = operation(for: key)
        busyAction = "confirm"
        errorMessage = nil
        defer { busyAction = nil }
        do {
            let updated = try await service.confirm(original, metadata: metadata)
            operations.removeValue(forKey: key)
            removeFromOpen(updated.id)
            closeReview()
            notice = "Plan confirmed. Its reviewed items are now in Calendar and Tasks.".localized
            NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
            HapticManager.success()
            return true
        } catch APIError.offlineQueued {
            removeFromOpen(original.id)
            queuedReviewMutation(
                message: "Confirmation is saved on this iPhone. Calendar and task items will be created when it syncs.".localized
            )
            return true
        } catch let error as APIError {
            handleMutationError(error)
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func decline(reason: String) async -> Bool {
        guard let original, !isDirty, busyAction == nil else { return false }
        let key = "decline:\(original.id):\(original.revision):\(reason)"
        let metadata = operation(for: key)
        busyAction = "decline"
        errorMessage = nil
        defer { busyAction = nil }
        do {
            let updated = try await service.decline(
                original,
                reason: reason,
                metadata: metadata
            )
            operations.removeValue(forKey: key)
            removeFromOpen(updated.id)
            closeReview()
            notice = "Plan declined. Nothing was added to Calendar or Tasks.".localized
            HapticManager.selection()
            return true
        } catch APIError.offlineQueued {
            removeFromOpen(original.id)
            queuedReviewMutation(
                message: "Decline is saved on this iPhone and will sync when you reconnect.".localized
            )
            return true
        } catch let error as APIError {
            handleMutationError(error)
        } catch {
            errorMessage = error.localizedDescription
        }
        HapticManager.error()
        return false
    }

    func reloadSelectedDiscardingEdits(online: Bool) async {
        guard online, let id = original?.id else {
            errorMessage = "Reconnect before reloading this plan.".localized
            return
        }
        busyAction = "reload"
        errorMessage = nil
        defer { busyAction = nil }
        do {
            let value = try await service.commitment(id: id)
            replace(value)
            select(value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addEvent() {
        guard var draft else { return }
        let start = Calendar.current.date(byAdding: .day, value: 1, to: now()) ?? now()
        let nine = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
        draft.plan.events.append(
            CommitmentEventDraft(
                id: UUID().uuidString.lowercased(),
                title: "New event".localized,
                description: nil,
                startTime: ISODateParser.string(from: nine),
                endTime: nil,
                allDay: false,
                location: nil,
                personIds: [],
                affectedAdultIds: [],
                assignedTo: nil,
                eventType: draft.kind == .childcare ? "childcare" : draft.kind.rawValue,
                documentIds: []
            )
        )
        self.draft = draft
    }

    func removeEvent(id: String) {
        guard var draft else { return }
        draft.plan.events.removeAll { $0.id == id }
        draft.plan.preparations.removeAll { $0.eventId == id }
        self.draft = draft
    }

    func addTask() {
        guard var draft else { return }
        draft.plan.tasks.append(
            CommitmentTaskDraft(
                id: UUID().uuidString.lowercased(),
                title: "New task".localized,
                description: nil,
                dueDate: nil,
                actionableFrom: nil,
                assignedTo: nil,
                priority: 2,
                documentId: nil
            )
        )
        self.draft = draft
    }

    func removeTask(id: String) {
        draft?.plan.tasks.removeAll { $0.id == id }
    }

    func addPreparation() {
        guard var draft, let event = draft.plan.events.first else { return }
        draft.plan.preparations.append(
            CommitmentPreparationDraft(
                id: UUID().uuidString.lowercased(),
                eventId: event.id,
                name: "Preparation".localized,
                items: ["Add what needs preparing".localized],
                leadHours: 24,
                assignedTo: nil
            )
        )
        self.draft = draft
    }

    func removePreparation(id: String) {
        draft?.plan.preparations.removeAll { $0.id == id }
    }

    func setHasExternalAction(_ enabled: Bool) {
        guard var draft else { return }
        draft.plan.externalAction = enabled
            ? CommitmentExternalAction(
                kind: .other,
                label: "Complete the outside step".localized,
                targetType: .manual,
                target: "Follow the instructions in the source".localized,
                dueAt: nil,
                requiresCompletionBeforeConfirm: false
            )
            : nil
        self.draft = draft
    }

    private func loadMembers() async -> [FamilyMemberDTO] {
        do { return try await service.familyMembers() }
        catch { return members }
    }

    private func loadDocuments() async -> [CommitmentDocumentOption] {
        do { return try await service.documentOptions() }
        catch { return documents }
    }

    private func loadConsent() async -> AIConsentStatusDTO? {
        do { return try await service.aiConsent() }
        catch { return nil }
    }

    private func operation(for key: String) -> CommitmentMutationMetadata {
        if let value = operations[key] { return value }
        let value = CommitmentMutationMetadata(
            id: UUID().uuidString.lowercased(),
            timestamp: ISODateParser.string(from: now())
        )
        operations[key] = value
        return value
    }

    private func typedIDs(for key: String) -> TypedDraftIDs {
        if let value = typedDraftIDs[key] { return value }
        let value = TypedDraftIDs(
            metadata: CommitmentMutationMetadata(
                id: UUID().uuidString.lowercased(),
                timestamp: ISODateParser.string(from: now())
            ),
            sourceId: UUID().uuidString.lowercased(),
            eventId: UUID().uuidString.lowercased()
        )
        typedDraftIDs[key] = value
        return value
    }

    private func replace(_ value: Commitment) {
        guard value.status.isOpen else {
            removeFromOpen(value.id)
            return
        }
        items.removeAll { $0.id == value.id }
        items.append(value)
        items.sort {
            if $0.urgency != $1.urgency { return $0.urgency < $1.urgency }
            return $0.updatedAt < $1.updatedAt
        }
    }

    private func removeFromOpen(_ id: String) {
        items.removeAll { $0.id == id }
    }

    private func queued(key: String, message: String) {
        typedDraftIDs.removeValue(forKey: key)
        original = nil
        draft = nil
        notice = message
        errorMessage = nil
        HapticManager.success()
    }

    private func queuedReviewMutation(message: String) {
        original = nil
        draft = nil
        conflictNeedsReload = false
        notice = message
        errorMessage = nil
        HapticManager.success()
    }

    private func handleMutationError(_ error: APIError) {
        if case .conflict = error {
            conflictNeedsReload = true
            errorMessage = "This plan changed on another device. Reload it before continuing.".localized
        } else {
            errorMessage = error.errorDescription
        }
    }

    private static func networkOnlyMessage(_ error: APIError, fallback: String) -> String {
        switch error {
        case .networkError, .offlineQueued:
            "Reconnect and try again. This search cannot be queued.".localized
        default:
            error.errorDescription ?? fallback
        }
    }

    private static func localValidationIssue(_ value: Commitment) -> String? {
        if value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a plan title before saving.".localized
        }
        if value.plan.events.contains(where: { event in
            if event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            guard let start = ISODateParser.parse(event.startTime) else { return true }
            guard let endValue = event.endTime else { return false }
            guard let end = ISODateParser.parse(endValue) else { return true }
            return end <= start
        }) {
            return "Check each event title and time before saving.".localized
        }
        if value.plan.tasks.contains(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return "Check each task title before saving.".localized
        }
        let eventIds = Set(value.plan.events.map(\.id))
        if value.plan.preparations.contains(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.items.isEmpty || !eventIds.contains($0.eventId)
        }) {
            return "Check each preparation group and its event before saving.".localized
        }
        if let action = value.plan.externalAction {
            if action.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || action.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "Check the outside step before saving.".localized
            }
            if action.targetType == .https, SafeExternalURL.web(action.target) == nil {
                return "The outside website must be a safe HTTPS link.".localized
            }
        }
        return nil
    }

    private static func fingerprint<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
