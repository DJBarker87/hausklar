import Foundation
import SwiftData

/// Stores birthday information for family, friends, and school contacts.
@Model
final class Birthday {
    @Attribute(.unique) var id: String
    var personName: String
    var dateOfBirth: Date
    /// Relationship: family, friend, school
    var relationship: String?
    /// How many days before the birthday to show a reminder.
    var reminderDaysBefore: Int
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        personName: String = "",
        dateOfBirth: Date = Date(),
        relationship: String? = nil,
        reminderDaysBefore: Int = 7,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.personName = personName
        self.dateOfBirth = dateOfBirth
        self.relationship = relationship
        self.reminderDaysBefore = reminderDaysBefore
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
