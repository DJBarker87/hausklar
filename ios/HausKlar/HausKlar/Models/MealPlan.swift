import Foundation
import SwiftData

/// Assigns a meal to a specific date and meal type (breakfast, lunch, dinner).
@Model
final class MealPlan {
    @Attribute(.unique) var id: String
    var mealId: String
    var date: Date
    /// Meal type: breakfast, lunch, dinner
    var mealType: String
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        mealId: String = "",
        date: Date = Date(),
        mealType: String = "dinner",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.mealId = mealId
        self.date = date
        self.mealType = mealType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
