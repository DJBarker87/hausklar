import Foundation
import SwiftData

/// A meal in the family's recipe library.
@Model
final class Meal {
    @Attribute(.unique) var id: String
    var name: String
    var mealDescription: String?
    var recipeURL: String?
    /// JSON-encoded array of tags: quick, vegetarian, etc.
    var tags: String?
    /// JSON-encoded array of {name, quantity, category} ingredients.
    var ingredients: String?
    var lastMadeAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String = "",
        mealDescription: String? = nil,
        recipeURL: String? = nil,
        tags: String? = nil,
        ingredients: String? = nil,
        lastMadeAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.mealDescription = mealDescription
        self.recipeURL = recipeURL
        self.tags = tags
        self.ingredients = ingredients
        self.lastMadeAt = lastMadeAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
