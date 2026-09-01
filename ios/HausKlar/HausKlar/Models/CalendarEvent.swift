import Foundation
import SwiftData

/// Represents a calendar event (timed or all-day, optionally recurring).
@Model
final class CalendarEvent {
    @Attribute(.unique) var id: String
    var title: String
    var eventDescription: String?
    var startTime: Date
    var endTime: Date
    var allDay: Bool
    var recurrenceRule: String?
    var location: String?
    /// JSON-encoded array of user/child UUIDs assigned to this event.
    var familyMemberIds: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?
    var assignedTo: String?

    init(
        id: String = UUID().uuidString,
        title: String = "",
        eventDescription: String? = nil,
        startTime: Date = Date(),
        endTime: Date = Date(),
        allDay: Bool = false,
        recurrenceRule: String? = nil,
        location: String? = nil,
        familyMemberIds: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil,
        assignedTo: String? = nil
    ) {
        self.id = id
        self.title = title
        self.eventDescription = eventDescription
        self.startTime = startTime
        self.endTime = endTime
        self.allDay = allDay
        self.recurrenceRule = recurrenceRule
        self.location = location
        self.familyMemberIds = familyMemberIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
        self.assignedTo = assignedTo
    }
}
