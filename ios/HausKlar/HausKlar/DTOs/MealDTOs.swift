import Foundation
import os

private let mealDTODecodingLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "MealDTOs"
)
import SwiftUI

// MARK: - Meal DTOs

struct MealDTO: Codable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let recipeUrl: String?
    let tags: String?
    let ingredients: String?
    let lastMadeAt: String?
    let prepMinutes: Int?
    let servings: Int?
    let allergyNotes: String?
    let preferenceNotes: String?
    let notForUs: Bool?
    let source: String?
}

struct MealIngredientDTO: Codable, Identifiable {
    var id: String { "\(name)-\(quantity ?? "")-\(category ?? "")" }
    let name: String
    let quantity: String?
    let category: String?
}

struct MealIngredientDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var quantity: String = ""
    var category: String = ""
}

struct MealPlanDTO: Codable, Identifiable {
    let id: String
    let mealId: String
    let date: String
    let mealType: String
    let mealName: String?
    let notes: String?
    let tiredHousehold: Bool
}

struct ShoppingItemDTO: Codable, Identifiable {
    let id: String
    let name: String
    let quantity: String?
    let category: String?
    let checked: Bool
}

struct MealShoppingItemCreateRequest: Encodable {
    let name: String
    let quantity: String?
    let category: String?
}

struct MealContextDTO: Codable {
    let schoolDay: Bool
    let clubDay: Bool
    let highExertion: Bool
    let lateHome: Bool
    let holidayMode: Bool
    let dayOfWeek: Int
    let dinnerTimeBucket: String
}

struct RecommendedMealDTO: Codable, Identifiable {
    var id: String { mealId }
    let mealId: String
    let mealName: String
    let tags: [String]
    let score: Double
    let reasons: [String]
    let lastServedAt: String?
}

struct RecommendationsResponseDTO: Codable {
    let context: MealContextDTO
    let recommendations: [RecommendedMealDTO]
    let date: String
}

struct RecommendationsContextPreviewDTO: Codable {
    let date: String
    let context: MealContextDTO
}

struct GrocerySuggestionDTO: Codable, Identifiable {
    var id: String { groceryItemId }
    let groceryItemId: String
    let itemName: String
    let suggestedQty: Double
    let unit: String
    let confidence: String
    let reason: String
}

struct GrocerySuggestionsResponseDTO: Codable {
    let suggestions: [GrocerySuggestionDTO]
    let generatedAt: String
}

struct StockLevelDTO: Codable, Identifiable {
    var id: String { groceryItemId }
    let groceryItemId: String
    let itemName: String
    let category: String?
    let totalPurchased: Double
    let totalConsumed: Double
    let totalWasted: Double
    let remaining: Double
    let unit: String
    let earliestUseBy: String?
    let daysUntilExpiry: Int?
}

struct ExpiringItemDTO: Codable, Identifiable {
    var id: String { "\(groceryItemId)-\(useByDate)" }
    let groceryItemId: String
    let itemName: String
    let useByDate: String
    let remainingQty: Double
    let unit: String
    let daysLeft: Int
    let alertLevel: String
}

struct CriticalLowStockDTO: Codable, Identifiable {
    var id: String { groceryItemId }
    let groceryItemId: String
    let itemName: String
    let remaining: Double
    let unit: String
    let threshold: Double
    let reason: String
}

struct FreezerItemDTO: Codable, Identifiable {
    var id: String { groceryItemId }
    let groceryItemId: String
    let itemName: String
    let qty: Double
    let unit: String
}

struct GroceryItemListDTO: Codable, Identifiable {
    let id: String
    let name: String
    let category: String?
    let defaultUnit: String
    let isUseByTracked: Bool
    let aliases: [String]?
    let tescoHint: String?
    let defaultQuantity: Double?
}

struct PurchaseLineDTO: Codable, Identifiable {
    let id: String
    let purchaseBatchId: String
    let groceryItemId: String
    let groceryItemName: String?
    let qty: Double
    let unit: String
    let useByDate: String?
    let storage: String?
}

struct PurchaseBatchDTO: Codable, Identifiable {
    let id: String
    let purchasedAt: String
    let source: String
    let notes: String?
    let lines: [PurchaseLineDTO]
}

struct TescoImportMatchDTO: Codable, Identifiable {
    var id: String { rawLine }
    let rawLine: String
    let matchedItemId: String?
    let matchedItemName: String?
    let confidence: String
    let needsReview: Bool
}

struct TescoHistoryPreviewDTO: Codable, Equatable {
    let filename: String
    let sha256: String
    let orderCount: Int
    let lineCount: Int
    let firstPurchasedAt: String?
    let lastPurchasedAt: String?
    let sampleItems: [String]
    let issues: [String]
    let alreadyImported: Bool
    let canConfirm: Bool
}

struct TescoHistoryImportResultDTO: Codable, Equatable {
    let importId: String?
    let imported: Bool
    let importedOrders: Int
    let skippedOrders: Int
    let preview: TescoHistoryPreviewDTO
}

struct TescoHistoryUsualDTO: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let shopCount: Int
    let lastBought: String
    let latestPricePence: Int?
    let previousPricePence: Int?
}

struct TescoHistorySummaryDTO: Codable, Equatable {
    let shopCount: Int
    let lineCount: Int
    let firstPurchasedAt: String?
    let lastPurchasedAt: String?
    let lastImportedAt: String?
    let receiptMonitoring: Bool
    let priceRiseCount: Int
    let usuals: [TescoHistoryUsualDTO]

    static let empty = TescoHistorySummaryDTO(
        shopCount: 0,
        lineCount: 0,
        firstPurchasedAt: nil,
        lastPurchasedAt: nil,
        lastImportedAt: nil,
        receiptMonitoring: false,
        priceRiseCount: 0,
        usuals: []
    )
}

struct MealRatingHistoryDTO: Codable, Identifiable {
    let id: String
    let mealPlanId: String
    let childId: String
    let childName: String?
    let rating: Int
    let createdAt: String
}

struct PurchaseLineSummary: Identifiable {
    let id: String
    let purchaseId: String
    let groceryItemId: String
    let itemName: String
    let qty: Double
    let unit: String
    let storage: String
    let purchasedAt: String
    let useByDate: String?
}

struct SlotAssignmentContext: Identifiable {
    var id: String { "\(date)-\(mealType)-\(childId ?? "none")" }
    let date: String
    let mealType: String
    let childId: String?
    let childName: String?
}

// MARK: - Request Payloads

struct CreateMealRequest: Encodable {
    let name: String
    let description: String?
    let recipeUrl: String?
    let tags: [String]?
    let ingredients: [[String: String]]?
    let prepMinutes: Int?
    let servings: Int?
    let allergyNotes: String?
    let preferenceNotes: String?

    init(
        name: String,
        description: String?,
        recipeUrl: String?,
        tags: [String]?,
        ingredients: [[String: String]]?,
        prepMinutes: Int? = nil,
        servings: Int? = nil,
        allergyNotes: String? = nil,
        preferenceNotes: String? = nil
    ) {
        self.name = name
        self.description = description
        self.recipeUrl = recipeUrl
        self.tags = tags
        self.ingredients = ingredients
        self.prepMinutes = prepMinutes
        self.servings = servings
        self.allergyNotes = allergyNotes
        self.preferenceNotes = preferenceNotes
    }
}

struct UpdateMealRequest: Encodable {
    let name: String?
    let description: String?
    let recipeUrl: String?
    let tags: [String]?
    let ingredients: [[String: String]]?
    let prepMinutes: Int?
    let servings: Int?
    let allergyNotes: String?
    let preferenceNotes: String?
    let notForUs: Bool?
    private let replacingDetails: Bool

    init(
        name: String?,
        description: String?,
        recipeUrl: String?,
        tags: [String]?,
        ingredients: [[String: String]]?,
        prepMinutes: Int?,
        servings: Int?,
        allergyNotes: String?,
        preferenceNotes: String?,
        notForUs: Bool?,
        replacingDetails: Bool = false
    ) {
        self.name = name
        self.description = description
        self.recipeUrl = recipeUrl
        self.tags = tags
        self.ingredients = ingredients
        self.prepMinutes = prepMinutes
        self.servings = servings
        self.allergyNotes = allergyNotes
        self.preferenceNotes = preferenceNotes
        self.notForUs = notForUs
        self.replacingDetails = replacingDetails
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, recipeUrl, tags, ingredients, prepMinutes, servings
        case allergyNotes, preferenceNotes, notForUs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        if replacingDetails {
            try container.encode(description, forKey: .description)
            try container.encode(recipeUrl, forKey: .recipeUrl)
            try container.encode(tags, forKey: .tags)
            try container.encode(ingredients, forKey: .ingredients)
            try container.encode(prepMinutes, forKey: .prepMinutes)
            try container.encode(servings, forKey: .servings)
            try container.encode(allergyNotes, forKey: .allergyNotes)
            try container.encode(preferenceNotes, forKey: .preferenceNotes)
        } else {
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(recipeUrl, forKey: .recipeUrl)
            try container.encodeIfPresent(tags, forKey: .tags)
            try container.encodeIfPresent(ingredients, forKey: .ingredients)
            try container.encodeIfPresent(prepMinutes, forKey: .prepMinutes)
            try container.encodeIfPresent(servings, forKey: .servings)
            try container.encodeIfPresent(allergyNotes, forKey: .allergyNotes)
            try container.encodeIfPresent(preferenceNotes, forKey: .preferenceNotes)
        }
        try container.encodeIfPresent(notForUs, forKey: .notForUs)
    }
}

struct RecipePreviewRequest: Encodable {
    let text: String?
    let recipeUrl: String?
}

struct RecipePreviewDTO: Decodable {
    let name: String
    let recipeUrl: String?
    let ingredients: [MealIngredientDTO]
    let prepMinutes: Int?
    let servings: Int?
    let uncertainFields: [String]
}

struct ShoppingPlanDiffItemDTO: Codable, Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let quantity: String?
    let category: String?
    let mealPlanIds: [String]
    let plannedMeals: [String]
    let alreadyOnList: Bool
    let likelyAtHome: Bool
}

struct ShoppingPlanDiffDTO: Codable {
    let start: String
    let end: String
    let items: [ShoppingPlanDiffItemDTO]
}

struct ApplyShoppingPlanDiffRequest: Encodable {
    let start: String
    let end: String
    let keys: [String]
}

struct ApplyShoppingPlanDiffResponse: Decodable {
    let created: [ShoppingItemDTO]
    let skipped: Int
}

struct RecommendationDecisionRequest: Encodable {
    let action: String
    let date: String?
}

struct RecommendationDecisionResponse: Decodable {
    let action: String
    let meal: MealDTO
    let plan: MealPlanDTO?
    let message: String
}

// EmptyBody is defined in APIContracts.swift and reused here.

struct CreateMealPlanRequest: Encodable {
    let mealId: String
    let date: String
    let mealType: String
    let notes: String?
}

struct MealRatingInputRequest: Encodable {
    let childId: String
    let rating: Int
}

struct SubmitMealRatingsRequest: Encodable {
    let ratings: [MealRatingInputRequest]
    let tiredHousehold: Bool?
}

struct AcceptSuggestionsRequest: Encodable {
    let groceryItemIds: [String]?
}

struct AcceptSuggestionsResponse: Decodable {
    let created: Int
}

struct ShoppingDoneResponse: Decodable {
    let cleared: Int
}

struct AddFreezerItemRequest: Encodable {
    let name: String
    let qty: Double
    let unit: String
}

struct CreateGroceryItemRequest: Encodable {
    let name: String
    let category: String?
    let defaultUnit: String
    let isUseByTracked: Bool
}

struct UpdateGroceryItemRequest: Encodable {
    let name: String?
    let category: String?
    let defaultUnit: String?
    let aliases: [String]?
    let isUseByTracked: Bool?
    let tescoHint: String?
    let defaultQuantity: Double?
}

struct CreatePurchaseLineRequest: Encodable {
    let groceryItemId: String
    let qty: Double
    let unit: String
    let useByDate: String?
    let storage: String
}

struct CreatePurchaseBatchRequest: Encodable {
    let purchasedAt: String
    let source: String
    let notes: String?
    let lines: [CreatePurchaseLineRequest]
}

struct UpdateUseByRequest: Encodable {
    let useByDate: String
}

struct TescoImportRequest: Encodable {
    let rawText: String
}

struct CreateConsumptionRequest: Encodable {
    let groceryItemId: String
    let amount: Double
    let unit: String
    let eventType: String
    let source: String
    let notes: String?
}

struct ConsumptionEventCreatedResponse: Decodable {
    let id: String
}

struct TescoImportResponseDTO: Codable {
    let batchId: String
    let matches: [TescoImportMatchDTO]
}

struct MealPlanWithRatingsDTO: Codable {
    let id: String
    let ratings: [MealRatingHistoryDTO]
}

// MARK: - Shared Formatters

enum MealFormatters {
    struct Formatter: Sendable {
        fileprivate enum Kind: Sendable {
            case dateOnly
            case isoFractional
            case isoWithoutFractional
        }

        fileprivate let kind: Kind

        func string(from date: Date) -> String {
            formatterStore.string(from: date, kind: kind)
        }

        func date(from string: String) -> Date? {
            formatterStore.date(from: string, kind: kind)
        }
    }

    /// Date formatters are mutable Foundation reference types. One locked store
    /// keeps their existing reuse and exact formats without exposing them as
    /// process-wide non-Sendable values.
    private final class FormatterStore: @unchecked Sendable {
        private let lock = NSLock()
        private let dateOnly: DateFormatter
        private let isoFractional: ISO8601DateFormatter
        private let isoWithoutFractional: ISO8601DateFormatter

        init() {
            let dateOnly = DateFormatter()
            dateOnly.dateFormat = "yyyy-MM-dd"
            dateOnly.timeZone = .current
            self.dateOnly = dateOnly

            let isoFractional = ISO8601DateFormatter()
            isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.isoFractional = isoFractional

            let isoWithoutFractional = ISO8601DateFormatter()
            isoWithoutFractional.formatOptions = [.withInternetDateTime]
            self.isoWithoutFractional = isoWithoutFractional
        }

        func string(from date: Date, kind: Formatter.Kind) -> String {
            lock.withLock {
                switch kind {
                case .dateOnly: dateOnly.string(from: date)
                case .isoFractional: isoFractional.string(from: date)
                case .isoWithoutFractional: isoWithoutFractional.string(from: date)
                }
            }
        }

        func date(from string: String, kind: Formatter.Kind) -> Date? {
            lock.withLock {
                switch kind {
                case .dateOnly: dateOnly.date(from: string)
                case .isoFractional: isoFractional.date(from: string)
                case .isoWithoutFractional: isoWithoutFractional.date(from: string)
                }
            }
        }
    }

    private static let formatterStore = FormatterStore()
    static let dateOnly = Formatter(kind: .dateOnly)
    static let iso = Formatter(kind: .isoFractional)
    static let isoFallback = Formatter(kind: .isoWithoutFractional)
    static let eventISO = Formatter(kind: .isoWithoutFractional)
}

// MARK: - Shared Helpers

enum MealHelpers {
    static func parseTags(_ tagsString: String?) -> [String] {
        guard let tagsString, !tagsString.isEmpty else { return [] }
        guard let data = tagsString.data(using: .utf8) else {
            mealDTODecodingLogger.error("Meal tags were not valid UTF-8 and were not displayed.")
            return []
        }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            mealDTODecodingLogger.error(
                "Saved meal tags could not be decoded: \(error.localizedDescription, privacy: .private)"
            )
            return []
        }
    }

    static func parseIngredients(_ ingredientsString: String?) -> [MealIngredientDTO] {
        guard let ingredientsString, !ingredientsString.isEmpty else { return [] }
        guard let data = ingredientsString.data(using: .utf8) else {
            mealDTODecodingLogger.error(
                "Meal ingredients were not valid UTF-8 and were not displayed."
            )
            return []
        }
        do {
            return try JSONDecoder().decode([MealIngredientDTO].self, from: data)
        } catch {
            mealDTODecodingLogger.error(
                "Saved meal ingredients could not be decoded: \(error.localizedDescription, privacy: .private)"
            )
            return []
        }
    }

    static func breakfastAssignedChildId(from notes: String?) -> String? {
        guard let notes, notes.hasPrefix("child:") else { return nil }
        return String(notes.dropFirst("child:".count))
    }

    static func daysAgoLabel(_ isoString: String?) -> String? {
        guard let isoString,
              let date = MealFormatters.iso.date(from: isoString) ?? MealFormatters.isoFallback.date(from: isoString) else {
            return nil
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days == 0 {
            return "Made today".localized
        } else if days == 1 {
            return "Made yesterday".localized
        } else {
            return String(format: "Made %d days ago".localized, days)
        }
    }

    static func dayAbbreviation(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    static func dayNumber(_ date: Date) -> String {
        date.formatted(.dateTime.day())
    }

    static func localizedMealType(_ mealType: String) -> String {
        switch mealType.lowercased() {
        case "breakfast": return "Breakfast".localized
        case "lunch": return "Lunch".localized
        case "dinner": return "Dinner".localized
        default: return mealType.capitalized
        }
    }

    static func localizedDinnerTimeBucket(_ bucket: String) -> String {
        switch bucket.lowercased() {
        case "early": return "Early".localized
        case "normal": return "Normal".localized
        case "late": return "Late".localized
        default: return bucket.capitalized
        }
    }

    static func localizedStorage(_ storage: String) -> String {
        switch storage.lowercased() {
        case "fridge": return "Fridge".localized
        case "pantry": return "Pantry".localized
        case "freezer": return "Freezer".localized
        default: return storage.capitalized
        }
    }

    static func localizedSource(_ source: String) -> String {
        switch source.lowercased() {
        case "tesco": return "Tesco".localized
        case "other": return "Other".localized
        default: return source.capitalized
        }
    }

    static func localizedImportConfidence(_ confidence: String) -> String {
        switch confidence.lowercased() {
        case "high": return "High".localized
        case "medium": return "Medium".localized
        case "low": return "Low".localized
        default: return confidence.capitalized
        }
    }

    static func confidenceLabel(_ confidence: String) -> String {
        switch confidence {
        case "must_buy": return "Must buy".localized
        case "likely_low": return "Likely low".localized
        default: return "Optional".localized
        }
    }

    static func alertLabel(_ alert: String) -> String {
        switch alert {
        case "critical": return "Critical".localized
        case "expired": return "Expired".localized
        default: return "Soon".localized
        }
    }

    static var weekDays: [Date] {
        let calendar = Calendar.current
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: Date()) else {
            return []
        }
        return (0..<7).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: weekInterval.start)
        }
    }
}
