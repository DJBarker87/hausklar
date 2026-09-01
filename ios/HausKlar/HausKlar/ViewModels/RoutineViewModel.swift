import Foundation
import SwiftUI
import os

// MARK: - DTOs

struct RoutineItemDTO: Codable, Identifiable {
    let id: String
    let personId: String
    let name: String
    let color: String
    let daysOfWeek: [Int]
    let sortOrder: Int
    let timeOfDay: String?
    let location: String?
    let preparationNote: String?
    let prepTemplateId: String?
    let reminderMinutes: Int?
    let calendarProjection: Bool?
    let termOnly: Bool?
    let createdAt: String
    let updatedAt: String
    let createdBy: String?
}

struct CreateRoutineItemRequest: Encodable {
    let personId: String
    let name: String
    let color: String
    let daysOfWeek: [Int]
    let sortOrder: Int
    let timeOfDay: String?
    let location: String?
    let preparationNote: String?
    let prepTemplateId: String?
    let reminderMinutes: Int?
    let calendarProjection: Bool
    let termOnly: Bool
}

struct UpdateRoutineItemRequest: Encodable {
    let name: String?
    let color: String?
    let daysOfWeek: [Int]?
    let sortOrder: Int?
    let timeOfDay: String?
    let location: String?
    let preparationNote: String?
    let prepTemplateId: String?
    let reminderMinutes: Int?
    let calendarProjection: Bool?
    let termOnly: Bool?
}

struct TermDateDTO: Codable, Identifiable, Equatable {
    let id: String
    let personId: String
    let label: String?
    let startDate: String
    let endDate: String
    let createdAt: String
    let updatedAt: String
    let createdBy: String?
}

struct CreateTermDateRequest: Encodable {
    let personId: String
    let label: String?
    let startDate: String
    let endDate: String
}

struct UpdateTermDateRequest: Encodable {
    let label: String?
    let startDate: String?
    let endDate: String?
}

struct TermOverrideDTO: Codable {
    let personId: String
    let mode: String  // "auto", "force_on", "force_off"
    let expiresOn: String?
}

struct SetOverrideRequest: Encodable {
    let isActive: Bool
    let expiresOn: String
}

struct DuplicateRoutineItemRequest: Encodable {
    let targetPersonId: String
}

struct ActiveRoutineDTO: Codable, Identifiable {
    var id: String { "\(routineItemId)-\(date)" }
    let routineItemId: String
    let personId: String
    let personName: String
    let name: String
    let color: String
    let date: String
    let timeOfDay: String?
    let location: String?
    let preparationNote: String?
    let prepTemplateId: String?
    let reminderMinutes: Int?
}

enum HandoffKindDTO: String, Codable, CaseIterable {
    case pickup
    case workDeparture = "work_departure"

    var title: String {
        switch self {
        case .pickup: "Pickup"
        case .workDeparture: "Leaving work"
        }
    }
}

struct HandoffScheduleItemDTO: Codable, Identifiable, Equatable {
    let id: String
    let kind: HandoffKindDTO
    let weekday: Int
    let timeOfDay: String
    let termPersonId: String
    let ownerUserId: String
    let createdAt: String
    let updatedAt: String
}

struct HandoffScheduleResponseDTO: Codable, Equatable {
    let items: [HandoffScheduleItemDTO]
}

struct HandoffScheduleItemRequest: Encodable, Equatable {
    let kind: HandoffKindDTO
    let weekday: Int
    let timeOfDay: String
    let termPersonId: String
    let ownerUserId: String?
}

struct HandoffScheduleUpdateRequest: Encodable, Equatable {
    let items: [HandoffScheduleItemRequest]
    let clientId: String
    let clientTimestamp: String
}

struct HandoffOccurrenceDTO: Codable, Identifiable, Equatable {
    let id: String
    let handoffId: String
    let kind: HandoffKindDTO
    let date: String
    let timeOfDay: String
    let termPersonId: String
    var termPersonName: String? = nil
    let ownerUserId: String
    let ownerName: String
    let label: String
    let isOverride: Bool
}

struct HandoffOccurrenceUpdateRequest: Encodable, Equatable {
    let timeOfDay: String
    let ownerUserId: String?
    let isCancelled: Bool
    let clientId: String
    let clientTimestamp: String
}

struct SchoolClubDTO: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let childId: String
    let childName: String
    let weekday: Int
    let startTime: String
    let endTime: String
    let activeFrom: String
    let activeUntil: String?
    let location: String?
    let color: String
    let createdAt: String
    let updatedAt: String
    let createdBy: String?
    let clientId: String?
    let clientTimestamp: String?
}

struct SchoolClubCreateRequest: Encodable, Equatable {
    let id: String
    let name: String
    let childId: String
    let weekday: Int
    let startTime: String
    let endTime: String
    let clientId: String
    let clientTimestamp: String
}

struct SchoolClubUpdateRequest: Encodable, Equatable {
    let name: String
    let childId: String
    let weekday: Int
    let startTime: String
    let endTime: String
    let clientId: String
    let clientTimestamp: String
}

struct SchoolClubCancellationRequest: Encodable, Equatable {
    let clientId: String
    let clientTimestamp: String
}

struct SchoolClubCancellationResponseDTO: Codable, Equatable {
    let clubId: String
    let occurrenceDate: String
    let cancelled: Bool
}

struct ToastImportChangesDTO: Codable, Equatable {
    let added: Int
    let changed: Int
    let removed: Int
    let unchanged: Int
}

struct ToastImportPreviewDTO: Codable, Equatable {
    let sha256: String
    let sourceTitle: String
    let childId: String
    let childName: String
    let validFrom: String
    let validTo: String
    let baseStartTime: String
    let bookedDays: Int
    let until1630: Int
    let until1730: Int
    let changes: ToastImportChangesDTO
    let alreadyImported: Bool
    let canConfirm: Bool
}

struct ToastImportResultDTO: Codable, Equatable {
    let importId: String
    let imported: Bool
    let preview: ToastImportPreviewDTO
}

struct ToastImportStatusDTO: Codable, Identifiable, Equatable {
    var id: String { importId }
    let importId: String
    let childId: String
    let childName: String
    let sourceTitle: String
    let validFrom: String
    let validTo: String
    let bookedDays: Int
    let importedAt: String
}

// MARK: - Suggestions

struct RoutineSuggestion: Identifiable {
    let id = UUID()
    let name: String
    let defaultColor: String
}

// MARK: - ViewModel

@MainActor
final class RoutineViewModel: ObservableObject {

    // MARK: - Family Members (fetched from API)

    @Published var familyMembers: [FamilyMemberDTO] = []

    /// People list for the routine person picker (children first, then adults).
    var people: [(id: String, name: String)] {
        let children = familyMembers.filter { $0.memberType == "child" }
        let adults = familyMembers.filter { $0.memberType == "user" }
        return children.map { ($0.id, $0.name) } + adults.map { ($0.id, $0.name) }
    }

    var childIds: Set<String> {
        Set(familyMembers.filter { $0.memberType == "child" }.map { $0.id })
    }

    // MARK: - Suggestions (kids only)

    static let suggestions: [RoutineSuggestion] = [
        RoutineSuggestion(name: "Toast Club", defaultColor: "#FFA94D"),
        RoutineSuggestion(name: "PE", defaultColor: "#FF6B6B"),
        RoutineSuggestion(name: "Book Change", defaultColor: "#4ECDC4"),
        RoutineSuggestion(name: "Fencing", defaultColor: "#7C6BFF"),
        RoutineSuggestion(name: "Chess", defaultColor: "#546E7A"),
        RoutineSuggestion(name: "Football", defaultColor: "#6BCB77"),
        RoutineSuggestion(name: "Swimming", defaultColor: "#45B7D1"),
        RoutineSuggestion(name: "Little Gym", defaultColor: "#FF6B9D"),
    ]

    // MARK: - Color Palette

    static let colorPalette: [String] = [
        "#FF6B6B", "#FFA94D", "#FFD93D", "#6BCB77",
        "#4ECDC4", "#45B7D1", "#7C6BFF", "#FF6B9D",
        "#546E7A", "#8D6E63", "#78909C", "#AA1 0AA",
        "#EF5350", "#FF7043", "#26A69A", "#5C6BC0",
    ]

    // MARK: - Day Names

    static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    // MARK: - State

    @Published var items: [RoutineItemDTO] = []
    @Published var termDates: [TermDateDTO] = []
    @Published var prepTemplates: [PrepPackTemplateDTO] = []
    @Published var overrideMode: String = "auto"  // "auto", "force_on", "force_off"
    @Published var overrideExpiresOn = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @Published var selectedPersonId: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Item form
    @Published var showingAddItem = false
    @Published var editingItem: RoutineItemDTO?
    @Published var formItemName = ""
    @Published var formItemColor = "#FF6B6B"
    @Published var formItemDays: Set<Int> = []
    @Published var formItemSortOrder = 0
    @Published var formItemHasTime = false
    @Published var formItemTime = Date()
    @Published var formItemLocation = ""
    @Published var formItemPreparation = ""
    @Published var formItemPrepTemplateId = ""
    @Published var formItemReminderMinutes: Int?
    @Published var formItemCalendarProjection = true
    @Published var formItemTermOnly = true

    // Term date form
    @Published var showingAddTerm = false
    @Published var editingTerm: TermDateDTO?
    @Published var formTermLabel = ""
    @Published var formTermStart = Date()
    @Published var formTermEnd = Date()

    private let apiClient = APIClient.shared
    private let logger = Logger(subsystem: "com.hausklar", category: "RoutineViewModel")

    /// `yyyy-MM-dd` formatter for API date strings (term start/end).
    /// Cached as a static to avoid re-allocating on every call.
    private static let apiDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let apiTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Computed

    var selectedPersonName: String {
        people.first(where: { $0.id == selectedPersonId })?.name ?? ""
    }

    var isChildSelected: Bool {
        childIds.contains(selectedPersonId)
    }

    var itemsForSelectedPerson: [RoutineItemDTO] {
        items.filter { $0.personId == selectedPersonId }.sorted {
            ($0.timeOfDay ?? "99:99", $0.sortOrder, $0.name)
                < ($1.timeOfDay ?? "99:99", $1.sortOrder, $1.name)
        }
    }

    var termDatesForSelectedPerson: [TermDateDTO] {
        termDates.filter { $0.personId == selectedPersonId }
    }

    // MARK: - Load

    func loadFamilyMembers() async {
        do {
            let result: [FamilyMemberDTO] = try await apiClient.get("/family/members")
            familyMembers = result
            if selectedPersonId.isEmpty, let first = people.first {
                selectedPersonId = first.id
            }
        } catch {
            logger.error("Failed to load family members: \(error.localizedDescription)")
        }
    }

    func loadAll() async {
        isLoading = true
        errorMessage = nil

        do {
            async let itemsTask: [RoutineItemDTO] = apiClient.get("/routines/items")
            async let termsTask: [TermDateDTO] = apiClient.get("/routines/terms")
            async let templatesTask: [PrepPackTemplateDTO] = apiClient.get("/prep-packs/templates")
            let (loadedItems, loadedTerms, loadedTemplates) = try await (
                itemsTask, termsTask, templatesTask
            )
            items = loadedItems
            termDates = loadedTerms
            prepTemplates = loadedTemplates.filter(\.enabled)
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to load routines.".localized
        }

        await loadOverride()
        isLoading = false
    }

    func loadOverride() async {
        guard !selectedPersonId.isEmpty else { return }
        do {
            let dto: TermOverrideDTO = try await apiClient.get("/routines/override/\(selectedPersonId)")
            overrideMode = dto.mode
            if let expiresOn = dto.expiresOn,
               let expiry = Self.apiDateFormatter.date(from: expiresOn) {
                overrideExpiresOn = expiry
            }
        } catch {
            logger.error("Failed to load override for \(self.selectedPersonId): \(error.localizedDescription)")
            overrideMode = "auto"
        }
    }

    // MARK: - Routine Item Actions

    func createItem() async {
        guard !formItemName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a name.".localized
            return
        }

        let request = CreateRoutineItemRequest(
            personId: selectedPersonId,
            name: formItemName.trimmingCharacters(in: .whitespaces),
            color: formItemColor,
            daysOfWeek: Array(formItemDays).sorted(),
            sortOrder: formItemSortOrder,
            timeOfDay: formItemHasTime ? Self.apiTimeFormatter.string(from: formItemTime) : nil,
            location: formItemLocation.nilIfBlank,
            preparationNote: formItemPreparation.nilIfBlank,
            prepTemplateId: formItemPrepTemplateId.nilIfBlank,
            reminderMinutes: formItemReminderMinutes,
            calendarProjection: formItemCalendarProjection,
            termOnly: formItemTermOnly
        )

        do {
            let created: RoutineItemDTO = try await apiClient.post("/routines/items", body: request)
            items.append(created)
            HapticManager.success()
            showingAddItem = false
            resetItemForm()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to create item.".localized
        }
    }

    func updateItem() async {
        guard let editing = editingItem else { return }

        let request = UpdateRoutineItemRequest(
            name: formItemName.trimmingCharacters(in: .whitespaces),
            color: formItemColor,
            daysOfWeek: Array(formItemDays).sorted(),
            sortOrder: formItemSortOrder,
            timeOfDay: formItemHasTime ? Self.apiTimeFormatter.string(from: formItemTime) : nil,
            location: formItemLocation.nilIfBlank,
            preparationNote: formItemPreparation.nilIfBlank,
            prepTemplateId: formItemPrepTemplateId.nilIfBlank,
            reminderMinutes: formItemReminderMinutes,
            calendarProjection: formItemCalendarProjection,
            termOnly: formItemTermOnly
        )

        do {
            let updated: RoutineItemDTO = try await apiClient.put("/routines/items/\(editing.id)", body: request)
            if let index = items.firstIndex(where: { $0.id == editing.id }) {
                items[index] = updated
            }
            HapticManager.success()
            editingItem = nil
            resetItemForm()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to update item.".localized
        }
    }

    func deleteItem(_ id: String) async {
        do {
            try await apiClient.delete("/routines/items/\(id)")
            items.removeAll { $0.id == id }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to delete item.".localized
        }
    }

    func resetItemForm() {
        formItemName = ""
        formItemColor = "#FF6B6B"
        formItemDays = Set(0...4)
        formItemSortOrder = 0
        formItemHasTime = false
        formItemTime = Date()
        formItemLocation = ""
        formItemPreparation = ""
        formItemPrepTemplateId = ""
        formItemReminderMinutes = nil
        formItemCalendarProjection = true
        formItemTermOnly = true
        errorMessage = nil
    }

    func populateItemForm(from item: RoutineItemDTO) {
        formItemName = item.name
        formItemColor = item.color
        formItemDays = Set(item.daysOfWeek)
        formItemSortOrder = item.sortOrder
        formItemHasTime = item.timeOfDay != nil
        if let value = item.timeOfDay, let time = Self.apiTimeFormatter.date(from: value) {
            formItemTime = time
        }
        formItemLocation = item.location ?? ""
        formItemPreparation = item.preparationNote ?? ""
        formItemPrepTemplateId = item.prepTemplateId ?? ""
        formItemReminderMinutes = item.reminderMinutes
        formItemCalendarProjection = item.calendarProjection ?? true
        formItemTermOnly = item.termOnly ?? true
    }

    func applySuggestion(_ suggestion: RoutineSuggestion) {
        formItemName = suggestion.name
        formItemColor = suggestion.defaultColor
    }

    func duplicateItem(_ item: RoutineItemDTO, to targetPersonId: String) async {
        do {
            let duplicate: RoutineItemDTO = try await apiClient.post(
                "/routines/items/\(item.id)/duplicate",
                body: DuplicateRoutineItemRequest(targetPersonId: targetPersonId)
            )
            items.append(duplicate)
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to copy routine.".localized
        }
    }

    // MARK: - Term Date Actions

    func createTerm() async {
        let request = CreateTermDateRequest(
            personId: selectedPersonId,
            label: formTermLabel.isEmpty ? nil : formTermLabel.trimmingCharacters(in: .whitespaces),
            startDate: Self.apiDateFormatter.string(from:formTermStart),
            endDate: Self.apiDateFormatter.string(from:formTermEnd)
        )

        do {
            let created: TermDateDTO = try await apiClient.post("/routines/terms", body: request)
            termDates.append(created)
            HapticManager.success()
            showingAddTerm = false
            resetTermForm()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to create term date.".localized
        }
    }

    func updateTerm() async {
        guard let editing = editingTerm else { return }

        let request = UpdateTermDateRequest(
            label: formTermLabel.isEmpty ? nil : formTermLabel.trimmingCharacters(in: .whitespaces),
            startDate: Self.apiDateFormatter.string(from:formTermStart),
            endDate: Self.apiDateFormatter.string(from:formTermEnd)
        )

        do {
            let updated: TermDateDTO = try await apiClient.put("/routines/terms/\(editing.id)", body: request)
            if let index = termDates.firstIndex(where: { $0.id == editing.id }) {
                termDates[index] = updated
            }
            HapticManager.success()
            editingTerm = nil
            resetTermForm()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to update term date.".localized
        }
    }

    func deleteTerm(_ id: String) async {
        do {
            try await apiClient.delete("/routines/terms/\(id)")
            termDates.removeAll { $0.id == id }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to delete term date.".localized
        }
    }

    func resetTermForm() {
        formTermLabel = ""
        formTermStart = Date()
        formTermEnd = Date()
        errorMessage = nil
    }

    func populateTermForm(from term: TermDateDTO) {
        formTermLabel = term.label ?? ""
        formTermStart = Self.apiDateFormatter.date(from:term.startDate) ?? Date()
        formTermEnd = Self.apiDateFormatter.date(from:term.endDate) ?? Date()
    }

    // MARK: - Override Actions

    func setOverride(active: Bool) async {
        do {
            let dto: TermOverrideDTO = try await apiClient.put(
                "/routines/override/\(selectedPersonId)",
                body: SetOverrideRequest(
                    isActive: active,
                    expiresOn: Self.apiDateFormatter.string(from: overrideExpiresOn)
                )
            )
            overrideMode = dto.mode
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to set override.".localized
        }
    }

    func refreshSchoolDates() async {
        struct RefreshResponse: Decodable {}
        do {
            let _: RefreshResponse = try await apiClient.post("/routines/terms/refresh")
            let loadedTerms: [TermDateDTO] = try await apiClient.get("/routines/terms")
            termDates = loadedTerms
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "School dates could not be imported.".localized
        }
    }

    func clearOverride() async {
        do {
            try await apiClient.delete("/routines/override/\(selectedPersonId)")
            overrideMode = "auto"
        } catch {
            logger.error("Failed to clear override for \(self.selectedPersonId): \(error.localizedDescription)")
            overrideMode = "auto"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
