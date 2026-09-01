import Foundation

// MARK: - Insight DTOs
// Contract for GET /insights/ — proactive "needs attention" prompts on the dashboard.

struct InsightDTO: Codable, Identifiable {
    let id: String
    let kind: String
    let message: String
    let detail: String?
    let targetDate: String?
    let sourceDocumentId: String?
    let createdAt: String
    let suggestedTaskTitle: String?

    /// SF Symbol for the insight kind. Unknown kinds fall back to the warning icon.
    var iconName: String {
        switch kind {
        case "missing_event": return "calendar.badge.exclamationmark"
        case "prep": return "backpack"
        case "weather": return "cloud.rain"
        default: return "exclamationmark.triangle"
        }
    }
}

struct InsightDismissResponseDTO: Codable {
    let status: String
}

struct InsightTaskResponseDTO: Codable {
    let status: String
    let taskId: String
    let title: String
}

// MARK: - Event preparation packs

struct PrepPackSuggestionDTO: Codable, Identifiable {
    let id: String
    let templateId: String
    let templateName: String
    let eventId: String
    let eventTitle: String
    let eventAllDay: Bool
    let eventStart: String
    let occurrenceStart: String
    let items: [String]
    let leadHours: Int
    let assignedTo: String?
}

struct PrepPackTemplateDTO: Codable, Identifiable {
    let id: String
    let name: String
    let matchTerms: [String]
    let items: [String]
    let leadHours: Int
    let assignedTo: String?
    let enabled: Bool
}

struct PrepPackActionRequest: Codable {
    let templateId: String
    let eventId: String
    let occurrenceStart: String
    let timezone: String
}

struct PrepPackApplyResponseDTO: Codable {
    let status: String
    let occurrenceId: String
    let taskIds: [String]
    let taskCount: Int
}

struct PrepPackStatusResponseDTO: Codable {
    let status: String
}

struct PrepPackTemplateRequest: Codable {
    let name: String
    let matchTerms: [String]
    let items: [String]
    let leadHours: Int
    let assignedTo: String?
}

struct PrepPackEnabledRequest: Codable {
    let enabled: Bool
}
