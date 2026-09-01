import Foundation

struct TomorrowEventDTO: Codable, Identifiable {
    let id: String
    let title: String
    let startTime: String
    let allDay: Bool
    let location: String?
    let assignedTo: String?
    let eventType: String?

    var isSchoolMilestone: Bool { eventType == "school_milestone" }
}

struct TomorrowTaskDTO: Codable, Identifiable {
    let id: String
    let title: String
    let dueDate: String?
    let priority: Int
    let assigneeNames: [String]
}

struct LoadPromptDTO: Codable {
    let taskId: String
    let title: String
    let dueDate: String?
    let priority: Int
}

struct TomorrowCardDTO: Codable {
    let targetDate: String
    let visible: Bool
    let acknowledged: Bool
    let events: [TomorrowEventDTO]
    let tasks: [TomorrowTaskDTO]
    let loadPrompt: LoadPromptDTO?
}

struct TomorrowAcknowledgementRequest: Encodable {
    let targetDate: String
}

struct LoadAssignmentRequest: Encodable {
    let assigneeId: String
}
