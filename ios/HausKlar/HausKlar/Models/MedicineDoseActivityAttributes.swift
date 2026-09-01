import ActivityKit
import Foundation

/// Live Activity attributes for the next-safe-dose countdown during an active illness.
/// Shared between the app (lifecycle) and the widget extension (UI).
struct MedicineDoseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var nextSafeAt: Date
        var isSafeNow: Bool
        var lastGivenAt: Date?
    }

    var childId: String?
    var medicineTypeId: String?
    var childName: String
    var medicineName: String
}

struct NapActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
    }

    var napId: String
    var childId: String
    var childName: String
    var isBedtime: Bool
}
