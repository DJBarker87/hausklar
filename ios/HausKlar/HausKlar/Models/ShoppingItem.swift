import Foundation
import SwiftData

/// An item on the shopping list, optionally linked to a meal plan.
@Model
final class ShoppingItem {
    @Attribute(.unique) var id: String
    var name: String
    var quantity: String?
    /// Aisle/section grouping for the shop.
    var category: String?
    /// If generated from a meal plan, references the MealPlan UUID. Nil for manual items.
    var mealPlanId: String?
    var checked: Bool
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String = "",
        quantity: String? = nil,
        category: String? = nil,
        mealPlanId: String? = nil,
        checked: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.category = category
        self.mealPlanId = mealPlanId
        self.checked = checked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
