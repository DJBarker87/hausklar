import Foundation
import SwiftData

/// Records a specific dose of medicine given to a child.
/// Safety checks use givenAt (actual time), not createdAt (when logged).
@Model
final class MedicineDose {
    @Attribute(.unique) var id: String
    var medicineTypeId: String
    var childId: String
    /// The actual time the dose was given (may be backdated).
    var givenAt: Date
    var givenBy: String?
    var doseAmount: String?
    var medicineName: String?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String,
        medicineTypeId: String = "",
        childId: String,
        givenAt: Date,
        givenBy: String? = nil,
        doseAmount: String? = nil,
        medicineName: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.medicineTypeId = medicineTypeId
        self.childId = childId
        self.givenAt = givenAt
        self.givenBy = givenBy
        self.doseAmount = doseAmount
        self.medicineName = medicineName
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
