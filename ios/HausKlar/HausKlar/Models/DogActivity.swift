import Foundation
import SwiftData

/// Tracks dog activities: walks, feeds, vet visits, and medications.
@Model
final class DogActivity {
    @Attribute(.unique) var id: String
    /// Activity type: walk, feed, vet, medication
    var activityType: String
    var startedAt: Date
    var endedAt: Date?
    var notes: String?
    var doneBy: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        activityType: String = "walk",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        notes: String? = nil,
        doneBy: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.activityType = activityType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
        self.doneBy = doneBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
