import Foundation
import SwiftData

/// Logs a reading session for a child's homework tracking.
@Model
final class ReadingLog {
    @Attribute(.unique) var id: String
    var childId: String
    var bookTitle: String
    var minutes: Int
    var date: Date
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        childId: String = "",
        bookTitle: String = "",
        minutes: Int = 0,
        date: Date = Date(),
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.childId = childId
        self.bookTitle = bookTitle
        self.minutes = minutes
        self.date = date
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
