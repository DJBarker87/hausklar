import Foundation
import SwiftData

/// Represents a tracked child in the family.
@Model
final class Child {
    @Attribute(.unique) var id: String
    var name: String
    var dateOfBirth: Date
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String = "",
        dateOfBirth: Date = Date(),
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.dateOfBirth = dateOfBirth
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
