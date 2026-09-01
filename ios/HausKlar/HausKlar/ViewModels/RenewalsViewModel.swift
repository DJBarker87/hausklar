import Foundation

struct RenewalSaveValues {
    let title: String
    let category: RenewalCategory
    let dueDate: Date
    let recurrenceMonths: Int?
    let costPence: Int?
    let reminderDaysBefore: Int
    let sourceDocumentId: String?
    let provider: String?
    let reference: String?
    let actionUrl: String?
    let comparisonUrl: String?
    let contactUrl: String?
    let notes: String?
    let includeInHouseholdFinance: Bool
    let paymentHandling: String
    let showInCalendar: Bool
    let showInTasks: Bool
    let responsibleUserId: String?
    let remindersEnabled: Bool
    let escalateAfterDays: Int?
    let checklist: [String]
}

/// Keeps upcoming renewals sorted and exposes the few actions the family uses.
@MainActor
final class RenewalsViewModel: ObservableObject {
    @Published var renewals: [RenewalDTO] = []
    @Published var adults: [FamilyMemberDTO] = []
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var workingId: String?
    @Published var errorMessage: String?
    @Published var removedRenewal: RenewalDTO?
    @Published var libraryOverview = LibraryOverviewDTO.empty
    @Published var libraryErrorMessage: String?

    private let apiClient = APIClient.shared

    var overdueCount: Int {
        renewals.filter { $0.status == .overdue }.count
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let renewalsRequest: [RenewalDTO] = apiClient.get("/renewals/")
            async let membersRequest: [FamilyMemberDTO] = apiClient.get("/family/members")
            async let libraryRequest: LibraryOverviewDTO? = try? await apiClient.get("/library/")
            let (fetched, members) = try await (renewalsRequest, membersRequest)
            renewals = fetched.sorted { $0.daysUntil < $1.daysUntil }
            adults = members.filter { $0.memberType == "user" }
            if let library = await libraryRequest {
                libraryOverview = library
                libraryErrorMessage = nil
            } else {
                libraryErrorMessage = "Library books could not be loaded."
            }
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Couldn’t load renewals.")
        }
    }

    func connectLibraryAccount(
        label: String,
        cardNumber: String,
        pin: String,
        reminderDaysBefore: Int
    ) async -> Bool {
        isSaving = true
        libraryErrorMessage = nil
        defer { isSaving = false }
        do {
            libraryOverview = try await apiClient.post(
                "/library/accounts",
                body: LibraryAccountCreateRequest(
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                    cardNumber: cardNumber.replacingOccurrences(of: " ", with: ""),
                    pin: pin,
                    reminderDaysBefore: reminderDaysBefore
                ),
                timeoutInterval: 25
            )
            HapticManager.success()
            await NotificationService.shared.refreshHausKlarReminders()
            return true
        } catch {
            libraryErrorMessage = friendlyMessage(
                for: error,
                fallback: "That library card could not be connected."
            )
            HapticManager.error()
            return false
        }
    }

    func syncLibraryAccount(_ account: LibraryAccountDTO) async {
        workingId = "library-sync-\(account.id)"
        libraryErrorMessage = nil
        defer { workingId = nil }
        do {
            libraryOverview = try await apiClient.post(
                "/library/accounts/\(account.id)/sync",
                body: EmptyBody(),
                timeoutInterval: 25
            )
            HapticManager.success()
            await NotificationService.shared.refreshHausKlarReminders()
        } catch {
            libraryErrorMessage = friendlyMessage(
                for: error,
                fallback: "Library books could not be refreshed."
            )
            HapticManager.error()
        }
    }

    func disconnectLibraryAccount(_ account: LibraryAccountDTO) async {
        workingId = "library-delete-\(account.id)"
        libraryErrorMessage = nil
        defer { workingId = nil }
        do {
            try await apiClient.delete("/library/accounts/\(account.id)")
            libraryOverview = LibraryOverviewDTO(
                accounts: libraryOverview.accounts.filter { $0.id != account.id },
                loans: libraryOverview.loans.filter { $0.accountId != account.id }
            )
            HapticManager.success()
            await NotificationService.shared.refreshHausKlarReminders()
        } catch {
            libraryErrorMessage = friendlyMessage(
                for: error,
                fallback: "That library card could not be disconnected."
            )
            HapticManager.error()
        }
    }

    func create(_ values: RenewalSaveValues) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let created: RenewalDTO = try await apiClient.post(
                "/renewals/",
                body: RenewalCreateRequest(
                    title: values.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    category: values.category.rawValue,
                    dueDate: Self.dateString(values.dueDate),
                    recurrenceMonths: values.recurrenceMonths,
                    costPence: values.costPence,
                    reminderDaysBefore: values.reminderDaysBefore,
                    sourceDocumentId: values.sourceDocumentId,
                    provider: clean(values.provider),
                    reference: clean(values.reference),
                    actionUrl: clean(values.actionUrl),
                    comparisonUrl: clean(values.comparisonUrl),
                    contactUrl: clean(values.contactUrl),
                    notes: clean(values.notes),
                    includeInHouseholdFinance: values.includeInHouseholdFinance,
                    paymentHandling: values.includeInHouseholdFinance ? values.paymentHandling : "UNSPECIFIED",
                    showInCalendar: values.showInCalendar,
                    showInTasks: values.showInTasks,
                    responsibleUserId: values.responsibleUserId,
                    remindersEnabled: values.remindersEnabled,
                    escalateAfterDays: values.escalateAfterDays,
                    checklist: values.checklist
                )
            )
            replace(created)
            await NotificationService.shared.refreshHausKlarReminders()
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Couldn’t save this renewal.")
            HapticManager.error()
            return false
        }
    }

    func update(_ renewal: RenewalDTO, values: RenewalSaveValues) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let updated: RenewalDTO = try await apiClient.patch(
                "/renewals/\(renewal.id)",
                body: RenewalUpdateRequest(
                    title: values.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    category: values.category.rawValue,
                    dueDate: Self.dateString(values.dueDate),
                    recurrenceMonths: values.recurrenceMonths,
                    costPence: values.costPence,
                    reminderDaysBefore: values.reminderDaysBefore,
                    sourceDocumentId: values.sourceDocumentId,
                    provider: clean(values.provider),
                    reference: clean(values.reference),
                    actionUrl: clean(values.actionUrl),
                    comparisonUrl: clean(values.comparisonUrl),
                    contactUrl: clean(values.contactUrl),
                    notes: clean(values.notes),
                    includeInHouseholdFinance: values.includeInHouseholdFinance,
                    paymentHandling: values.includeInHouseholdFinance ? values.paymentHandling : "UNSPECIFIED",
                    showInCalendar: values.showInCalendar,
                    showInTasks: values.showInTasks,
                    responsibleUserId: values.responsibleUserId,
                    remindersEnabled: values.remindersEnabled,
                    escalateAfterDays: values.escalateAfterDays
                )
            )
            replace(updated)
            await NotificationService.shared.refreshHausKlarReminders()
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Couldn’t update this renewal.")
            HapticManager.error()
            return false
        }
    }

    func preview(documentId: String) async -> RenewalDraftPreviewDTO? {
        workingId = "preview"
        errorMessage = nil
        defer { workingId = nil }
        do {
            return try await apiClient.post(
                "/renewals/draft",
                body: RenewalDraftPreviewRequest(documentId: documentId)
            )
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "That document could not be read.")
            return nil
        }
    }

    func toggleChecklist(_ item: RenewalChecklistItemDTO, in renewal: RenewalDTO) async {
        workingId = item.id
        errorMessage = nil
        defer { workingId = nil }
        do {
            let updated: RenewalChecklistItemDTO = try await apiClient.patch(
                "/renewals/\(renewal.id)/checklist/\(item.id)",
                body: RenewalChecklistItemUpdateRequest(checked: item.checkedAt == nil)
            )
            var changed = renewal
            changed.checklist = (renewal.checklist ?? []).map { $0.id == item.id ? updated : $0 }
            replace(changed)
            HapticManager.light()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Couldn’t update that step.")
            HapticManager.error()
        }
    }

    func addChecklist(title: String, to renewal: RenewalDTO) async -> Bool {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        workingId = "add-checklist"
        errorMessage = nil
        defer { workingId = nil }
        do {
            let item: RenewalChecklistItemDTO = try await apiClient.post(
                "/renewals/\(renewal.id)/checklist",
                body: RenewalChecklistItemCreateRequest(title: cleaned)
            )
            var changed = renewal
            var checklist = renewal.checklist ?? []
            checklist.append(item)
            changed.checklist = checklist
            replace(changed)
            HapticManager.light()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Couldn’t add that step.")
            HapticManager.error()
            return false
        }
    }

    func decide(
        _ renewal: RenewalDTO,
        outcome: String,
        nextDueDate: Date?,
        costPence: Int?,
        notes: String
    ) async -> Bool {
        workingId = renewal.id
        errorMessage = nil
        defer { workingId = nil }
        do {
            let updated: RenewalDTO = try await apiClient.post(
                "/renewals/\(renewal.id)/decision",
                body: RenewalDecisionRequest(
                    outcome: outcome,
                    nextDueDate: nextDueDate.map(Self.dateString),
                    costPence: costPence,
                    notes: clean(notes)
                )
            )
            if outcome == "not_renewing" || nextDueDate == nil {
                renewals.removeAll { $0.id == renewal.id }
                removedRenewal = renewal
            } else {
                replace(updated)
            }
            await NotificationService.shared.refreshHausKlarReminders()
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Couldn’t update this renewal.")
            HapticManager.error()
            return false
        }
    }

    func delete(_ renewal: RenewalDTO) async {
        workingId = renewal.id
        errorMessage = nil
        defer { workingId = nil }
        do {
            try await apiClient.delete("/renewals/\(renewal.id)")
            renewals.removeAll { $0.id == renewal.id }
            removedRenewal = renewal
            await NotificationService.shared.refreshHausKlarReminders()
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Couldn’t remove this renewal.")
            HapticManager.error()
        }
    }

    func restoreRemoved() async {
        guard let removedRenewal else { return }
        workingId = removedRenewal.id
        errorMessage = nil
        defer { workingId = nil }
        do {
            let restored: RenewalDTO = try await apiClient.post(
                "/renewals/\(removedRenewal.id)/restore"
            )
            replace(restored)
            self.removedRenewal = nil
            await NotificationService.shared.refreshHausKlarReminders()
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Couldn’t restore this renewal.")
            HapticManager.error()
        }
    }

    func current(_ renewal: RenewalDTO) -> RenewalDTO {
        renewals.first(where: { $0.id == renewal.id }) ?? renewal
    }

    private func replace(_ renewal: RenewalDTO) {
        if let index = renewals.firstIndex(where: { $0.id == renewal.id }) {
            renewals[index] = renewal
        } else {
            renewals.append(renewal)
        }
        renewals.sort { $0.daysUntil < $1.daysUntil }
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private func friendlyMessage(for error: Error, fallback: String) -> String {
        (error as? APIError)?.errorDescription ?? fallback
    }
}
