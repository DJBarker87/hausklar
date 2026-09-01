import Foundation
import SwiftData

/// Represents a recurring routine item (PE, Swimming, etc.) for a person.
@Model
final class RoutineItem {
    @Attribute(.unique) var id: String
    var personId: String
    var name: String
    var color: String
    var daysOfWeek: String  // JSON array stored as string
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        personId: String = "",
        name: String = "",
        color: String = "#FF6B6B",
        daysOfWeek: String = "[]",
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.personId = personId
        self.name = name
        self.color = color
        self.daysOfWeek = daysOfWeek
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
