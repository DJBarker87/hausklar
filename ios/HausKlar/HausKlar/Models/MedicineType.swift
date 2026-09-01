import Foundation
import SwiftData

/// Defines a type of medicine with safety constraints (min hours between doses, max daily doses).
@Model
final class MedicineType {
    @Attribute(.unique) var id: String
    var name: String
    var minHoursBetweenDoses: Double
    var maxDoses24h: Int
    var notes: String?
    var color: String?
    var defaultDoseAmount: String?
    var childId: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String = "",
        minHoursBetweenDoses: Double = 4.0,
        maxDoses24h: Int = 4,
        notes: String? = nil,
        color: String? = nil,
        defaultDoseAmount: String? = nil,
        childId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.minHoursBetweenDoses = minHoursBetweenDoses
        self.maxDoses24h = maxDoses24h
        self.notes = notes
        self.color = color
        self.defaultDoseAmount = defaultDoseAmount
        self.childId = childId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
