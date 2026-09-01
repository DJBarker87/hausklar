import Foundation

struct BirthdayFullDTO: Codable, Identifiable, Equatable {
    let id: String
    let personName: String
    let dateOfBirth: String?
    let birthMonth: Int
    let birthDay: Int
    let yearKnown: Bool
    let relationship: String
    let reminderDaysBefore: Int
    let age: Int?
    let turningAge: Int?
    let nextBirthday: String
    let daysUntil: Int
    let preparationDue: Bool
}

private struct BirthdayMutationBody: Encodable {
    let personName: String
    let dateOfBirth: String?
    let birthMonth: Int
    let birthDay: Int
    let relationship: String
    let reminderDaysBefore: Int
    let allowDuplicate: Bool
}

struct BirthdayImportDraftDTO: Codable, Identifiable, Equatable {
    let lineNumber: Int
    let sourceLine: String
    let personName: String?
    let dateOfBirth: String?
    let birthMonth: Int?
    let birthDay: Int?
    let duplicateId: String?
    let issue: String?

    var id: Int { lineNumber }
    var canImport: Bool {
        personName != nil && birthMonth != nil && birthDay != nil && duplicateId == nil && issue == nil
    }
}

private struct BirthdayImportPreviewBody: Encodable { let text: String }
private struct BirthdayImportPreviewDTO: Decodable { let drafts: [BirthdayImportDraftDTO] }

struct BirthdayPreparationLinkedItemDTO: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let completed: Bool
}

struct BirthdayPreparationDTO: Codable, Equatable {
    let birthday: BirthdayFullDTO
    let occurrenceYear: Int
    let cardStatus: String
    let cardMessage: String?
    let celebrationStatus: String
    let notes: String?
    let tasks: [BirthdayPreparationLinkedItemDTO]
    let calendarEvent: BirthdayPreparationLinkedItemDTO?
    let giftsTotal: Int
    let giftsRemaining: Int
}

private struct BirthdayPreparationUpdateBody: Encodable {
    let cardStatus: String?
    let cardMessage: String?
    let celebrationStatus: String?
    let notes: String?
}

private struct BirthdayPreparationTaskBody: Encodable {
    let title: String
    let assignedTo: String?
    let dueDaysBefore: Int
}

private struct BirthdayPreparationEventBody: Encodable {
    let title: String?
    let location: String?
}

@MainActor
final class BirthdaysViewModel: ObservableObject {
    @Published var birthdays: [BirthdayFullDTO] = []
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var showingEditor = false
    @Published var editingBirthday: BirthdayFullDTO?
    @Published var duplicateNeedsConfirmation = false
    @Published var recentlyDeleted: BirthdayFullDTO?
    @Published var preparations: [String: BirthdayPreparationDTO] = [:]
    @Published var preparingBirthdayId: String?

    @Published var formName = ""
    @Published var formDateOfBirth = Date()
    @Published var formHasBirthYear = true
    @Published var formRelationship = "friend"
    @Published var formReminderDays = 14

    @Published var showingImport = false
    @Published var importText = ""
    @Published var importDrafts: [BirthdayImportDraftDTO] = []
    @Published var selectedImportLines: Set<Int> = []
    @Published var isReviewingImport = false

    let relationships = ["family", "friend", "school"]

    private let apiClient = APIClient.shared

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    func loadBirthdays() async {
        let hadContent = !birthdays.isEmpty
        if !hadContent { isLoading = true }
        defer { isLoading = false }
        do {
            let fetched: [BirthdayFullDTO] = try await apiClient.get("/birthdays/")
            birthdays = fetched.sorted { $0.daysUntil < $1.daysUntil }
            errorMessage = nil
        } catch where hadContent {
            // Keep the useful list on screen. A refresh problem needs no family interruption.
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Birthdays could not be opened.")
        }
    }

    func prepareNew() {
        editingBirthday = nil
        formName = ""
        formDateOfBirth = Date()
        formHasBirthYear = true
        formRelationship = "friend"
        formReminderDays = 14
        duplicateNeedsConfirmation = false
        errorMessage = nil
        showingEditor = true
    }

    func prepareEdit(_ birthday: BirthdayFullDTO) {
        editingBirthday = birthday
        formName = birthday.personName
        formHasBirthYear = birthday.yearKnown
        if let value = birthday.dateOfBirth.flatMap({ Self.dateOnlyFormatter.date(from: $0) }) {
            formDateOfBirth = value
        } else {
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = TimeZone(secondsFromGMT: 0)
            components.year = 2000
            components.month = birthday.birthMonth
            components.day = birthday.birthDay
            formDateOfBirth = components.date ?? Date()
        }
        formRelationship = birthday.relationship
        formReminderDays = birthday.reminderDaysBefore
        duplicateNeedsConfirmation = false
        errorMessage = nil
        showingEditor = true
    }

    func saveBirthday(allowDuplicate: Bool = false) async -> Bool {
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Add a name."
            return false
        }
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: .gmt, from: formDateOfBirth
        )
        guard let month = components.month, let day = components.day else { return false }
        let body = BirthdayMutationBody(
            personName: trimmedName,
            dateOfBirth: formHasBirthYear ? Self.dateOnlyFormatter.string(from: formDateOfBirth) : nil,
            birthMonth: month,
            birthDay: day,
            relationship: formRelationship,
            reminderDaysBefore: formReminderDays,
            allowDuplicate: allowDuplicate
        )

        isSaving = true
        errorMessage = nil
        duplicateNeedsConfirmation = false
        defer { isSaving = false }
        do {
            let saved: BirthdayFullDTO
            if let editingBirthday {
                saved = try await apiClient.put("/birthdays/\(editingBirthday.id)", body: body)
            } else {
                saved = try await apiClient.post("/birthdays/", body: body)
            }
            birthdays.removeAll { $0.id == saved.id }
            birthdays.append(saved)
            birthdays.sort { $0.daysUntil < $1.daysUntil }
            showingEditor = false
            self.editingBirthday = nil
            HapticManager.success()
            return true
        } catch APIError.conflict {
            duplicateNeedsConfirmation = true
            return false
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The birthday could not be saved.")
            HapticManager.error()
            return false
        }
    }

    func deleteBirthday(_ birthday: BirthdayFullDTO) async {
        do {
            try await apiClient.delete("/birthdays/\(birthday.id)")
            birthdays.removeAll { $0.id == birthday.id }
            recentlyDeleted = birthday
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The birthday could not be removed.")
            HapticManager.error()
        }
    }

    func undoDelete() async {
        guard let recentlyDeleted else { return }
        do {
            let restored: BirthdayFullDTO = try await apiClient.post(
                "/birthdays/\(recentlyDeleted.id)/restore"
            )
            birthdays.append(restored)
            birthdays.sort { $0.daysUntil < $1.daysUntil }
            self.recentlyDeleted = nil
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The birthday could not be restored.")
        }
    }

    func loadPreparation(for birthday: BirthdayFullDTO) async {
        if preparations[birthday.id] == nil { preparingBirthdayId = birthday.id }
        defer { if preparingBirthdayId == birthday.id { preparingBirthdayId = nil } }
        do {
            let value: BirthdayPreparationDTO = try await apiClient.get(
                "/birthdays/\(birthday.id)/preparation"
            )
            preparations[birthday.id] = value
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The birthday plan could not be opened.")
        }
    }

    func updatePreparation(
        for birthday: BirthdayFullDTO,
        cardStatus: String? = nil,
        cardMessage: String? = nil,
        celebrationStatus: String? = nil,
        notes: String? = nil
    ) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let value: BirthdayPreparationDTO = try await apiClient.put(
                "/birthdays/\(birthday.id)/preparation",
                body: BirthdayPreparationUpdateBody(
                    cardStatus: cardStatus,
                    cardMessage: cardMessage,
                    celebrationStatus: celebrationStatus,
                    notes: notes
                )
            )
            preparations[birthday.id] = value
            HapticManager.selection()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "That part of the birthday plan could not be saved.")
        }
    }

    func addPreparationTask(
        for birthday: BirthdayFullDTO,
        title: String,
        assignedTo: String? = nil,
        dueDaysBefore: Int = 7
    ) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let value: BirthdayPreparationDTO = try await apiClient.post(
                "/birthdays/\(birthday.id)/preparation/task",
                body: BirthdayPreparationTaskBody(
                    title: trimmed,
                    assignedTo: assignedTo,
                    dueDaysBefore: dueDaysBefore
                )
            )
            preparations[birthday.id] = value
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The task could not be added.")
            return false
        }
    }

    func addPreparationEvent(for birthday: BirthdayFullDTO) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let value: BirthdayPreparationDTO = try await apiClient.post(
                "/birthdays/\(birthday.id)/preparation/event",
                body: BirthdayPreparationEventBody(title: nil, location: nil)
            )
            preparations[birthday.id] = value
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The birthday could not be added to Planner.")
        }
    }

    func previewImport() async {
        let text = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isReviewingImport = true
        errorMessage = nil
        defer { isReviewingImport = false }
        do {
            let preview: BirthdayImportPreviewDTO = try await apiClient.post(
                "/birthdays/import-preview",
                body: BirthdayImportPreviewBody(text: text)
            )
            importDrafts = preview.drafts
            selectedImportLines = Set(preview.drafts.filter(\.canImport).map(\.lineNumber))
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Those birthdays could not be read.")
        }
    }

    func importSelected() async -> Bool {
        let selected = importDrafts.filter { selectedImportLines.contains($0.lineNumber) && $0.canImport }
        guard !selected.isEmpty else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            for draft in selected {
                guard let name = draft.personName, let month = draft.birthMonth, let day = draft.birthDay else { continue }
                let body = BirthdayMutationBody(
                    personName: name,
                    dateOfBirth: draft.dateOfBirth,
                    birthMonth: month,
                    birthDay: day,
                    relationship: "friend",
                    reminderDaysBefore: 14,
                    allowDuplicate: false
                )
                let saved: BirthdayFullDTO = try await apiClient.post("/birthdays/", body: body)
                birthdays.removeAll { $0.id == saved.id }
                birthdays.append(saved)
            }
            birthdays.sort { $0.daysUntil < $1.daysUntil }
            showingImport = false
            importText = ""
            importDrafts = []
            selectedImportLines = []
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Not every selected birthday could be saved.")
            return false
        }
    }

    private func friendlyMessage(for error: Error, fallback: String) -> String {
        (error as? APIError)?.errorDescription ?? fallback
    }
}
