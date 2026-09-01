import Foundation
import SwiftData

/// Records growth measurements (height, weight, head circumference) for a child.
@Model
final class GrowthRecord {
    @Attribute(.unique) var id: String
    var childId: String
    var date: Date
    var heightCm: Double?
    var weightKg: Double?
    var headCircumferenceCm: Double?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        childId: String = "",
        date: Date = Date(),
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        headCircumferenceCm: Double? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.childId = childId
        self.date = date
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.headCircumferenceCm = headCircumferenceCm
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
