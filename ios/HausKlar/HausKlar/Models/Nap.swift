import Foundation
import SwiftData

/// Tracks a nap session for a child. An active nap has a nil endedAt.
@Model
final class Nap {
    @Attribute(.unique) var id: String
    var childId: String
    var startedAt: Date
    /// Nil while the nap is in progress.
    var endedAt: Date?
    /// Location: cot, buggy, car, sofa, etc.
    var location: String?
    var notes: String?
    var sleepType: String = "nap"
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        childId: String = "",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        location: String? = nil,
        notes: String? = nil,
        sleepType: String = "nap",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.childId = childId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.location = location
        self.notes = notes
        self.sleepType = sleepType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
