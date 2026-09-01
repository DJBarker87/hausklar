import Foundation
import SwiftData

/// Represents a task or chore assigned to a family member.
@Model
final class FamilyTask {
    @Attribute(.unique) var id: String
    var title: String
    var taskDescription: String?
    var assignedTo: String?
    var dueDate: Date?
    var completedAt: Date?
    /// Category: bins, household, shopping, admin, other
    var category: String?
    /// iCal RRULE format for recurring tasks
    var recurrenceRule: String?
    /// Priority: 1 (low) to 3 (high)
    var priority: Int
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?
    /// JSON-serialized array of assignees for offline storage
    var assigneesJSON: String?

    init(
        id: String = UUID().uuidString,
        title: String = "",
        taskDescription: String? = nil,
        assignedTo: String? = nil,
        dueDate: Date? = nil,
        completedAt: Date? = nil,
        category: String? = nil,
        recurrenceRule: String? = nil,
        priority: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil,
        assigneesJSON: String? = nil
    ) {
        self.id = id
        self.title = title
        self.taskDescription = taskDescription
        self.assignedTo = assignedTo
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.category = category
        self.recurrenceRule = recurrenceRule
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
        self.assigneesJSON = assigneesJSON
    }
}
