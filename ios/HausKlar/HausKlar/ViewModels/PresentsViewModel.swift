import Foundation
import UIKit

enum PresentLifecycle: String, Codable, CaseIterable, Identifiable {
    case idea
    case shortlist
    case assigned
    case bought
    case arrived
    case wrapped
    case stashed
    case given

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idea: "Idea"
        case .shortlist: "Shortlist"
        case .assigned: "Assigned"
        case .bought: "Bought"
        case .arrived: "Arrived"
        case .wrapped: "Wrapped"
        case .stashed: "Stashed"
        case .given: "Given"
        }
    }

    var next: PresentLifecycle? {
        guard let index = Self.allCases.firstIndex(of: self),
              index < Self.allCases.index(before: Self.allCases.endIndex) else { return nil }
        return Self.allCases[Self.allCases.index(after: index)]
    }
}

struct PresentChildDTO: Codable, Identifiable {
    let id: String
    let name: String
}

struct PresentScoreDTO: Codable, Identifiable {
    var id: String { userId }
    let userId: String
    let userName: String?
    let score: Int
    let createdAt: String
    let updatedAt: String
}

struct PresentStatusHistoryDTO: Codable, Identifiable {
    let id: String
    let fromStatus: PresentLifecycle?
    let toStatus: PresentLifecycle
    let changedAt: String
    let changedBy: String?
    let changedByName: String?
}

struct PresentIdeaDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let recipientName: String?
    let title: String
    let occasion: String
    let eventYear: Int
    let birthdayId: String?
    let status: PresentLifecycle
    let statusUpdatedAt: String?
    let ownerId: String?
    let ownerName: String?
    let notes: String?
    let assignedTo: String?
    let url: String?
    let retailer: String?
    let budgetMinor: Int?
    let priceMinor: Int?
    let currency: String
    let deadline: String?
    let hidingLocation: String?
    let recipientCanSee: Bool
    let createdAt: String
    let updatedAt: String
    let scores: [PresentScoreDTO]
    let averageScore: Double?
    let statusHistory: [PresentStatusHistoryDTO]
}

private struct CreatePresentIdeaRequest: Encodable {
    let childId: String
    let title: String
    let occasion: String
    let eventYear: Int
    let status: PresentLifecycle
    let ownerId: String?
    let notes: String?
    let url: String?
    let retailer: String?
    let budgetMinor: Int?
    let priceMinor: Int?
    let currency: String
    let deadline: String?
    let hidingLocation: String?
    let recipientCanSee: Bool
    let allowDuplicate: Bool
}

private struct UpdatePresentIdeaRequest: Encodable {
    let title: String
    let occasion: String
    let status: PresentLifecycle
    let ownerId: String?
    let notes: String?
    let url: String?
    let retailer: String?
    let budgetMinor: Int?
    let priceMinor: Int?
    let currency: String
    let deadline: String?
    let hidingLocation: String?
    let recipientCanSee: Bool
}

private struct PresentStatusRequest: Encodable {
    let status: PresentLifecycle
}

private struct PresentDuplicateRequest: Encodable {
    let childId: String
    let title: String
    let url: String?
    let excludeId: String?
}

private struct PresentDuplicateResponse: Decodable {
    let matches: [PresentDuplicateMatch]
}

private struct PresentDuplicateMatch: Decodable, Identifiable {
    let id: String
    let title: String
    let occasion: String
    let eventYear: Int
    let status: PresentLifecycle
}

@MainActor
final class PresentsViewModel: ObservableObject {
    @Published var children: [FamilyMemberDTO] = []
    @Published var adults: [FamilyMemberDTO] = []
    @Published var selectedChildId: String? {
        didSet {
            guard selectedChildId != oldValue, let selectedChildId else { return }
            UserDefaults.standard.set(selectedChildId, forKey: Self.selectedChildKey)
        }
    }
    @Published var ideas: [PresentIdeaDTO] = []
    @Published var showGiven = false
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var showingEditor = false
    @Published var editingIdea: PresentIdeaDTO?
    @Published var presentedIdea: PresentIdeaDTO?
    @Published var recentlyDeleted: PresentIdeaDTO?
    @Published var showingDuplicateWarning = false
    @Published private(set) var duplicateSummary = ""

    @Published var formTitle = ""
    @Published var formOccasion = "christmas"
    @Published var formStatus: PresentLifecycle = .idea
    @Published var formOwnerId = ""
    @Published var formNotes = ""
    @Published var formURL = ""
    @Published var formRetailer = ""
    @Published var formBudget = ""
    @Published var formPrice = ""
    @Published var formHasDeadline = false
    @Published var formDeadline = Date()
    @Published var formHidingLocation = ""
    @Published var formHiddenFromRecipient = true

    let initialIdeaId: String?

    private static let selectedChildKey = "presents.selectedChild"
    private let apiClient: APIClient
    private let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())

    init(
        initialChildId: String? = nil,
        initialIdeaId: String? = nil,
        apiClient: APIClient = .shared
    ) {
        self.apiClient = apiClient
        self.initialIdeaId = initialIdeaId
        self.selectedChildId = initialChildId
            ?? UserDefaults.standard.string(forKey: Self.selectedChildKey)
    }

    var visibleIdeas: [PresentIdeaDTO] {
        showGiven ? ideas : ideas.filter { $0.status != .given }
    }

    var sections: [(PresentLifecycle, [PresentIdeaDTO])] {
        PresentLifecycle.allCases.compactMap { lifecycle in
            let values = visibleIdeas.filter { $0.status == lifecycle }
            return values.isEmpty ? nil : (lifecycle, values)
        }
    }

    var selectedChildName: String {
        children.first(where: { $0.id == selectedChildId })?.name ?? "Recipient"
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let members: [FamilyMemberDTO] = try await apiClient.get(
                "/family/members",
                bypassCache: true
            )
            children = members.filter { $0.memberType == "child" }
            adults = members.filter { $0.memberType == "user" }
            if !children.contains(where: { $0.id == selectedChildId }) {
                selectedChildId = children.first?.id
            }
            await loadIdeas()
        } catch {
            errorMessage = "Gift plans could not be loaded. Pull to try again."
        }
    }

    func selectChild(_ childId: String) async {
        guard selectedChildId != childId else { return }
        selectedChildId = childId
        await loadIdeas(showLoading: true)
    }

    func loadIdeas(showLoading: Bool = false) async {
        guard let childId = selectedChildId else {
            ideas = []
            return
        }
        if showLoading { isLoading = true }
        defer { if showLoading { isLoading = false } }
        do {
            let fetched: [PresentIdeaDTO] = try await apiClient.get(
                "/children/presents/ideas",
                queryItems: [
                    URLQueryItem(name: "child_id", value: childId),
                    URLQueryItem(name: "include_given", value: "true")
                ],
                bypassCache: true
            )
            ideas = fetched
            if let initialIdeaId,
               presentedIdea == nil,
               let target = fetched.first(where: { $0.id == initialIdeaId }) {
                presentedIdea = target
            }
        } catch {
            errorMessage = "Gift plans could not be refreshed."
        }
    }

    func beginAdding() {
        editingIdea = nil
        resetForm()
        showingEditor = true
    }

    func beginEditing(_ idea: PresentIdeaDTO) {
        editingIdea = idea
        formTitle = idea.title
        formOccasion = idea.occasion
        formStatus = idea.status
        formOwnerId = idea.ownerId ?? ""
        formNotes = idea.notes ?? ""
        formURL = idea.url ?? ""
        formRetailer = idea.retailer ?? ""
        formBudget = moneyString(idea.budgetMinor)
        formPrice = moneyString(idea.priceMinor)
        formHidingLocation = idea.hidingLocation ?? ""
        formHiddenFromRecipient = !idea.recipientCanSee
        if let deadline = idea.deadline.flatMap(Self.dateOnlyFormatter.date) {
            formHasDeadline = true
            formDeadline = deadline
        } else {
            formHasDeadline = false
            formDeadline = Date()
        }
        showingEditor = true
    }

    func saveEditor(forceDuplicate: Bool = false) async {
        guard !isSaving, let childId = selectedChildId else { return }
        let title = formTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "Add a gift idea first."
            return
        }
        if let url = normalized(formURL), SafeExternalURL.web(url) == nil {
            errorMessage = "Use a full https link."
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if editingIdea == nil && !forceDuplicate {
                let check: PresentDuplicateResponse = try await apiClient.post(
                    "/children/presents/ideas/check-duplicate",
                    body: PresentDuplicateRequest(
                        childId: childId,
                        title: title,
                        url: normalized(formURL),
                        excludeId: nil
                    )
                )
                if !check.matches.isEmpty {
                    duplicateSummary = check.matches.map {
                        "\($0.title) · \($0.status.title.lowercased())"
                    }.joined(separator: "\n")
                    showingDuplicateWarning = true
                    return
                }
            }

            if let editingIdea {
                let updated: PresentIdeaDTO = try await apiClient.put(
                    "/children/presents/ideas/\(editingIdea.id)",
                    body: updateRequest(title: title)
                )
                replace(updated)
                presentedIdea = presentedIdea?.id == updated.id ? updated : presentedIdea
            } else {
                let created: PresentIdeaDTO = try await apiClient.post(
                    "/children/presents/ideas",
                    body: createRequest(childId: childId, title: title, allowDuplicate: forceDuplicate)
                )
                ideas.insert(created, at: 0)
            }
            showingEditor = false
            self.editingIdea = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The gift could not be saved."
        }
    }

    func setStatus(_ lifecycle: PresentLifecycle, for idea: PresentIdeaDTO) async {
        do {
            let updated: PresentIdeaDTO = try await apiClient.patch(
                "/children/presents/ideas/\(idea.id)/status",
                body: PresentStatusRequest(status: lifecycle)
            )
            replace(updated)
            if presentedIdea?.id == updated.id { presentedIdea = updated }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            errorMessage = "That status change did not save."
        }
    }

    func advance(_ idea: PresentIdeaDTO) async {
        guard let next = idea.status.next else { return }
        await setStatus(next, for: idea)
    }

    func delete(_ idea: PresentIdeaDTO) async {
        do {
            try await apiClient.delete("/children/presents/ideas/\(idea.id)")
            ideas.removeAll { $0.id == idea.id }
            if presentedIdea?.id == idea.id { presentedIdea = nil }
            recentlyDeleted = idea
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorMessage = "The gift could not be removed."
        }
    }

    func undoDelete() async {
        guard let deleted = recentlyDeleted else { return }
        do {
            let restored: PresentIdeaDTO = try await apiClient.post(
                "/children/presents/ideas/\(deleted.id)/restore"
            )
            ideas.insert(restored, at: 0)
            recentlyDeleted = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            errorMessage = "Undo could not be completed."
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func resetForm() {
        formTitle = ""
        formOccasion = "christmas"
        formStatus = .idea
        formOwnerId = ""
        formNotes = ""
        formURL = ""
        formRetailer = ""
        formBudget = ""
        formPrice = ""
        formHasDeadline = false
        formDeadline = Date()
        formHidingLocation = ""
        formHiddenFromRecipient = true
    }

    func deadlineLabel(_ value: String?) -> String? {
        guard let value, let date = Self.dateOnlyFormatter.date(from: value) else { return nil }
        if Calendar.current.isDateInToday(date) { return "Due today" }
        if Calendar.current.isDateInTomorrow(date) { return "Due tomorrow" }
        return "Due \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    func moneyLabel(minor: Int?, currency: String) -> String? {
        guard let minor else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: Double(minor) / 100))
    }

    private func createRequest(
        childId: String,
        title: String,
        allowDuplicate: Bool
    ) -> CreatePresentIdeaRequest {
        CreatePresentIdeaRequest(
            childId: childId,
            title: title,
            occasion: normalized(formOccasion) ?? "gift",
            eventYear: currentYear,
            status: formStatus,
            ownerId: normalized(formOwnerId),
            notes: normalized(formNotes),
            url: normalized(formURL),
            retailer: normalized(formRetailer),
            budgetMinor: minorUnits(formBudget),
            priceMinor: minorUnits(formPrice),
            currency: "GBP",
            deadline: formHasDeadline ? Self.dateOnlyFormatter.string(from: formDeadline) : nil,
            hidingLocation: normalized(formHidingLocation),
            recipientCanSee: !formHiddenFromRecipient,
            allowDuplicate: allowDuplicate
        )
    }

    private func updateRequest(title: String) -> UpdatePresentIdeaRequest {
        UpdatePresentIdeaRequest(
            title: title,
            occasion: normalized(formOccasion) ?? "gift",
            status: formStatus,
            ownerId: normalized(formOwnerId),
            notes: normalized(formNotes),
            url: normalized(formURL),
            retailer: normalized(formRetailer),
            budgetMinor: minorUnits(formBudget),
            priceMinor: minorUnits(formPrice),
            currency: "GBP",
            deadline: formHasDeadline ? Self.dateOnlyFormatter.string(from: formDeadline) : nil,
            hidingLocation: normalized(formHidingLocation),
            recipientCanSee: !formHiddenFromRecipient
        )
    }

    private func replace(_ updated: PresentIdeaDTO) {
        guard let index = ideas.firstIndex(where: { $0.id == updated.id }) else {
            ideas.insert(updated, at: 0)
            return
        }
        ideas[index] = updated
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func minorUnits(_ value: String) -> Int? {
        let cleaned = value.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let decimal = Decimal(string: cleaned), decimal >= 0 else {
            return nil
        }
        return NSDecimalNumber(decimal: decimal * 100).intValue
    }

    private func moneyString(_ minor: Int?) -> String {
        guard let minor else { return "" }
        return String(format: "%.2f", Double(minor) / 100)
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
